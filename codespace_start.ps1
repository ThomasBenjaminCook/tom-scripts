#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoOwnersEnvVarName = 'REPO_OWNERS'
$RepoOwnersDelimiter = ','
$RepositoryFetchLimit = 1000
$RepositoryDisplayLimit = 10
$FzfCommandName = 'fzf'
$FzfInstallHint = 'Install fzf with: winget install --id junegunn.fzf --source winget'

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Error $Message
    exit 1
}

function Test-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        Fail "$Name was not found. $InstallHint"
    }
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-GhText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $output = (& gh @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($output)) {
            Fail $FailureMessage
        }

        Fail "$FailureMessage`n$output"
    }

    return $output
}

function Invoke-GhJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $output = Invoke-GhText -Arguments $Arguments -FailureMessage $FailureMessage
    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return $output | ConvertFrom-Json
}

function Get-LocalTimestamp {
    param(
        [string]$Timestamp
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return 'unknown'
    }

    $parsedTimestamp = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Timestamp, [ref]$parsedTimestamp)) {
        return $parsedTimestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    }

    return $Timestamp
}

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 90
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $cleanText = ($Text -replace '\s+', ' ').Trim()
    if ($cleanText.Length -le $MaxLength) {
        return $cleanText
    }

    return $cleanText.Substring(0, $MaxLength - 3) + '...'
}

function Test-GhCodespaceScope {
    $authStatus = Invoke-GhText -Arguments @('auth', 'status') -FailureMessage 'GitHub CLI is not authenticated. Run: gh auth login'
    $scopeLine = ($authStatus -split "`r?`n" | Where-Object { $_ -match 'Token scopes:' } | Select-Object -First 1)

    if ([string]::IsNullOrWhiteSpace($scopeLine) -or $scopeLine -notmatch '(^|[^A-Za-z])codespace([^A-Za-z]|$)') {
        Fail "GitHub CLI is missing the 'codespace' scope. Run: gh auth refresh -h github.com -s codespace"
    }
}

function Get-RepositoryOwnersFromEnvironment {
    $ownersRaw = [Environment]::GetEnvironmentVariable($RepoOwnersEnvVarName)
    if ([string]::IsNullOrWhiteSpace($ownersRaw)) {
        Fail "Environment variable '$RepoOwnersEnvVarName' is not set. Configure it as a '$RepoOwnersDelimiter'-delimited list. Example value: 'owner-one,owner-two'."
    }

    $owners = @(
        $ownersRaw -split $RepoOwnersDelimiter |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($owners.Count -eq 0) {
        Fail "Environment variable '$RepoOwnersEnvVarName' did not contain any valid owners. Use '$RepoOwnersDelimiter' as the delimiter."
    }

    return $owners
}

function Select-RepositoryOwner {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Owners
    )

    while ($true) {
        Write-Host "`nAvailable repository owners from REPO_OWNERS"
        for ($i = 0; $i -lt $Owners.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $Owners[$i])
        }
        Write-Host '  Q. Quit'

        $selection = Read-Host "`nSelect repository owner number"
        if ($selection -match '^[Qq]$') {
            exit 0
        }

        if ($selection -notmatch '^\d+$') {
            Write-Host 'Invalid selection.'
            continue
        }

        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $Owners.Count) {
            Write-Host 'Invalid selection.'
            continue
        }

        return $Owners[$selectedIndex]
    }
}

function Get-OrganizationRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization
    )

    $repositories = Invoke-GhJson -Arguments @(
        'repo', 'list', $Organization,
        '--limit', $RepositoryFetchLimit,
        '--json', 'name,nameWithOwner,description,isPrivate,isArchived,updatedAt'
    ) -FailureMessage "Failed to list repositories for $Organization."

    $repositoryList = @($repositories | Sort-Object name)
    if ($repositoryList.Count -eq 0) {
        Fail "No repositories were returned for $Organization."
    }

    return $repositoryList
}

function Get-RepositorySearchScore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Repository,

        [string]$SearchText
    )

    if ([string]::IsNullOrWhiteSpace($SearchText)) {
        return 0
    }

    $search = $SearchText.ToLowerInvariant()
    $score = 0

    $candidates = @(
        @{ Value = [string]$Repository.nameWithOwner; Exact = 500; Prefix = 250; Contains = 100 },
        @{ Value = [string]$Repository.name; Exact = 450; Prefix = 225; Contains = 90 },
        @{ Value = [string]$Repository.description; Exact = 80; Prefix = 40; Contains = 20 }
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) {
            continue
        }

        $value = $candidate.Value.ToLowerInvariant()
        if ($value -eq $search) {
            $score += $candidate.Exact
            continue
        }

        if ($value.StartsWith($search)) {
            $score += $candidate.Prefix
            continue
        }

        if ($value.Contains($search)) {
            $score += $candidate.Contains
        }
    }

    return $score
}

function ConvertTo-RepositoryPickerLine {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Repository
    )

    $visibility = if ($Repository.isPrivate) { 'private' } else { 'public' }
    $archived = if ($Repository.isArchived) { 'archived' } else { '-' }
    $updatedAt = Get-LocalTimestamp -Timestamp $Repository.updatedAt
    $description = Get-ShortText -Text $Repository.description

    return @(
        $Repository.nameWithOwner,
        $visibility,
        $archived,
        $updatedAt,
        $description
    ) -join "`t"
}

function Select-RepositoryWithFzf {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Repositories,

        [Parameter(Mandatory = $true)]
        [string]$OwnerName
    )

    Write-Host "`nLoaded $($Repositories.Count) repositories for $OwnerName."

    $pickerLines = @(
        $Repositories | ForEach-Object { ConvertTo-RepositoryPickerLine -Repository $_ }
    )

    $selection = $pickerLines | & $FzfCommandName `
        --height $RepositoryDisplayLimit `
        --layout=reverse `
        --border `
        --prompt='Repository > ' `
        --header='Type to filter, use arrows to choose, Enter to open, Esc to quit' `
        --delimiter "`t" `
        --with-nth=1,2,3,4,5 `
        --nth=1,5 `
        --tiebreak=index

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($selection)) {
        exit 0
    }

    $selectedRepositoryName = ($selection -split "`t", 2)[0]
    $selectedRepository = $Repositories | Where-Object { $_.nameWithOwner -eq $selectedRepositoryName } | Select-Object -First 1
    if (-not $selectedRepository) {
        Fail "The selected repository '$selectedRepositoryName' was not found in the loaded repository list."
    }

    return $selectedRepository
}

function Select-RepositoryLegacy {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Repositories,

        [Parameter(Mandatory = $true)]
        [string]$OwnerName
    )

    Write-Host "`nLoaded $($Repositories.Count) repositories for $OwnerName."
    Write-Host "Tip: install $FzfCommandName for interactive search with arrow-key selection. $FzfInstallHint"

    while ($true) {
        $searchText = Read-Host "`nEnter repository search text (blank shows all, q quits)"
        if ($searchText -match '^[Qq]$') {
            exit 0
        }

        $matches = if ([string]::IsNullOrWhiteSpace($searchText)) {
            $Repositories
        } else {
            @(
                $Repositories | Where-Object {
                    $_.name -like "*$searchText*" -or
                    $_.nameWithOwner -like "*$searchText*" -or
                    ($_.description -and $_.description -like "*$searchText*")
                }
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($searchText)) {
            $exactMatch = @(
                $matches | Where-Object {
                    $_.name -eq $searchText -or $_.nameWithOwner -eq $searchText
                }
            )

            if ($exactMatch.Count -eq 1) {
                return $exactMatch[0]
            }
        }

        if ($matches.Count -eq 0) {
            Write-Host "No repositories matched '$searchText'."
            continue
        }

        $sortedMatches = @(
            $matches |
                Sort-Object `
                    @{ Expression = { Get-RepositorySearchScore -Repository $_ -SearchText $searchText }; Descending = $true }, `
                    @{ Expression = { $_.name.ToLowerInvariant() }; Descending = $false }
        )

        $visibleMatches = @($sortedMatches | Select-Object -First $RepositoryDisplayLimit)

        Write-Host "`nRepositories:"
        for ($i = 0; $i -lt $visibleMatches.Count; $i++) {
            $repo = $visibleMatches[$i]
            $visibility = if ($repo.isPrivate) { 'private' } else { 'public' }
            $archived = if ($repo.isArchived) { ' | archived' } else { '' }
            $description = Get-ShortText -Text $repo.description
            $updatedAt = Get-LocalTimestamp -Timestamp $repo.updatedAt
            $descriptionSuffix = if ([string]::IsNullOrWhiteSpace($description)) { '' } else { " - $description" }
            Write-Host ("  {0}. {1} [{2}{3}] | updated {4}{5}" -f ($i + 1), $repo.nameWithOwner, $visibility, $archived, $updatedAt, $descriptionSuffix)
        }

        if ($matches.Count -gt $visibleMatches.Count) {
            Write-Host "Showing the first $($visibleMatches.Count) of $($matches.Count) matches. Refine your search to narrow the list."
        }

        $selection = Read-Host "`nSelect repository number, or press Enter to search again"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            continue
        }

        if ($selection -notmatch '^\d+$') {
            Write-Host 'Invalid selection.'
            continue
        }

        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $visibleMatches.Count) {
            Write-Host 'Invalid selection.'
            continue
        }

        return $visibleMatches[$selectedIndex]
    }
}

function Select-Repository {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Repositories,

        [Parameter(Mandatory = $true)]
        [string]$OwnerName
    )

    if (Test-CommandAvailable -Name $FzfCommandName) {
        return Select-RepositoryWithFzf -Repositories $Repositories -OwnerName $OwnerName
    }

    return Select-RepositoryLegacy -Repositories $Repositories -OwnerName $OwnerName
}

function Get-RepositoryCodespaces {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryFullName
    )

    $response = Invoke-GhJson -Arguments @(
        'api', "repos/$RepositoryFullName/codespaces"
    ) -FailureMessage "Failed to list codespaces for $RepositoryFullName."

    return @($response.codespaces)
}

function Select-CodespaceAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryFullName,

        [object[]]$Codespaces
    )

    $codespaceList = @($Codespaces)

    while ($true) {
        Write-Host "`nCodespaces for ${RepositoryFullName}:"

        if ($codespaceList.Count -eq 0) {
            Write-Host '  No existing codespaces found.'
        } else {
            for ($i = 0; $i -lt $codespaceList.Count; $i++) {
                $codespace = $codespaceList[$i]
                $displayName = if ([string]::IsNullOrWhiteSpace($codespace.display_name)) { $codespace.name } else { $codespace.display_name }
                $machineName = if ($codespace.machine) {
                    if ([string]::IsNullOrWhiteSpace($codespace.machine.display_name)) {
                        $codespace.machine.name
                    } else {
                        $codespace.machine.display_name
                    }
                } else {
                    'unknown machine'
                }
                $lastUsed = Get-LocalTimestamp -Timestamp $codespace.last_used_at
                Write-Host ("  {0}. {1} [{2}] | {3} | last used {4}" -f ($i + 1), $displayName, $codespace.state, $machineName, $lastUsed)
            }
        }

        Write-Host '  C. Create a new codespace'
        Write-Host '  Q. Quit'

        $selection = Read-Host "`nChoose an existing codespace number, C to create, or Q to quit"
        if ($selection -match '^[Qq]$') {
            exit 0
        }

        if ($selection -match '^[Cc]$') {
            return @{
                Action = 'Create'
            }
        }

        if ($selection -notmatch '^\d+$') {
            Write-Host 'Invalid selection.'
            continue
        }

        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $codespaceList.Count) {
            Write-Host 'Invalid selection.'
            continue
        }

        return @{
            Action = 'Open'
            Codespace = $codespaceList[$selectedIndex]
        }
    }
}

function Select-ConnectionMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName
    )

    while ($true) {
        Write-Host "`nHow do you want to open '$TargetName'?"
        Write-Host '  1. SSH'
        Write-Host '  2. VS Code'
        Write-Host '  Q. Quit'

        $selection = Read-Host "`nSelect connection mode"
        if ($selection -match '^[Qq]$') {
            exit 0
        }

        switch ($selection) {
            '1' { return 'SSH' }
            '2' { return 'VSCode' }
            default { Write-Host 'Invalid selection.' }
        }
    }
}

function Get-AvailableMachines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryFullName
    )

    $response = Invoke-GhJson -Arguments @(
        'api', "repos/$RepositoryFullName/codespaces/machines"
    ) -FailureMessage "Failed to list machine types for $RepositoryFullName."

    $machines = @($response.machines)
    if ($machines.Count -eq 0) {
        Fail "No machine types were returned for $RepositoryFullName."
    }

    return $machines
}

function Select-MachineType {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Machines
    )

    while ($true) {
        Write-Host "`nAvailable machine types:"
        for ($i = 0; $i -lt $Machines.Count; $i++) {
            $machine = $Machines[$i]
            $prebuild = if ([string]::IsNullOrWhiteSpace($machine.prebuild_availability)) { 'unknown' } else { $machine.prebuild_availability }
            Write-Host ("  {0}. {1} ({2}) | prebuild: {3}" -f ($i + 1), $machine.name, $machine.display_name, $prebuild)
        }
        Write-Host '  Q. Quit'

        $selection = Read-Host "`nSelect machine number"
        if ($selection -match '^[Qq]$') {
            exit 0
        }

        if ($selection -notmatch '^\d+$') {
            Write-Host 'Invalid selection.'
            continue
        }

        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $Machines.Count) {
            Write-Host 'Invalid selection.'
            continue
        }

        return $Machines[$selectedIndex]
    }
}

function New-RepositoryCodespace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryFullName,

        [Parameter(Mandatory = $true)]
        [string]$MachineName
    )

    Write-Host "`nCreating a new codespace for $RepositoryFullName with machine type '$MachineName'..."

    $codespace = Invoke-GhJson -Arguments @(
        'api', '--method', 'POST', "repos/$RepositoryFullName/codespaces",
        '-f', "machine=$MachineName"
    ) -FailureMessage "Failed to create a new codespace for $RepositoryFullName."

    if (-not $codespace -or [string]::IsNullOrWhiteSpace($codespace.name)) {
        Fail "Codespace creation for $RepositoryFullName did not return a codespace name."
    }

    Write-Host "Created codespace: $($codespace.name)"
    return $codespace.name
}

function Open-CodespaceInVsCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodespaceName
    )

    Test-RequiredCommand -Name 'code' -InstallHint "Install Visual Studio Code and ensure the 'code' command is on PATH."

    Write-Host "`nOpening VS Code in codespace '$CodespaceName'..."
    & gh codespace code -c $CodespaceName
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to open VS Code for codespace '$CodespaceName'."
    }
}

function Open-CodespaceInSsh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodespaceName
    )

    Test-RequiredCommand -Name 'ssh' -InstallHint "Install OpenSSH Client and ensure the 'ssh' command is on PATH."

    Write-Host "`nOpening SSH session in codespace '$CodespaceName'..."
    & gh codespace ssh -c $CodespaceName
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to open an SSH session for codespace '$CodespaceName'."
    }
}

Test-RequiredCommand -Name 'gh' -InstallHint 'Install GitHub CLI from https://cli.github.com/'
Test-GhCodespaceScope

$repositoryOwners = Get-RepositoryOwnersFromEnvironment
$selectedOwner = Select-RepositoryOwner -Owners $repositoryOwners

Write-Host "`nUsing repository owner: $selectedOwner"

$repositories = Get-OrganizationRepositories -Organization $selectedOwner
$selectedRepository = Select-Repository -Repositories $repositories -OwnerName $selectedOwner

Write-Host "`nUsing repository: $($selectedRepository.nameWithOwner)"

$codespaces = Get-RepositoryCodespaces -RepositoryFullName $selectedRepository.nameWithOwner
$codespaceAction = Select-CodespaceAction -RepositoryFullName $selectedRepository.nameWithOwner -Codespaces $codespaces

$codespaceName = if ($codespaceAction.Action -eq 'Open') {
    $codespaceAction.Codespace.name
} else {
    $machines = Get-AvailableMachines -RepositoryFullName $selectedRepository.nameWithOwner
    $selectedMachine = Select-MachineType -Machines $machines
    New-RepositoryCodespace -RepositoryFullName $selectedRepository.nameWithOwner -MachineName $selectedMachine.name
}

$connectionMode = Select-ConnectionMode -TargetName $codespaceName
if ($connectionMode -eq 'SSH') {
    Open-CodespaceInSsh -CodespaceName $codespaceName
} else {
    Open-CodespaceInVsCode -CodespaceName $codespaceName
}
