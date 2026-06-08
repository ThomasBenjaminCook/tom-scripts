# Start an Azure VM interactively by selecting subscription, resource group, and VM

# Ensure Az module is available
if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    Write-Error "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser"
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
        Write-Error "$Name was not found. $InstallHint"
        exit 1
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
        switch -Regex ($selection) {
            '^[Qq]$' { exit 0 }
            '^1$' { return 'SSH' }
            '^2$' { return 'VSCode' }
            default { Write-Host 'Invalid selection.' }
        }
    }
}

function Get-VmSshConnectionDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$VmIp
    )

    $connectionDetails = [ordered]@{
        Host = $VmIp
        HostName = $VmIp
        User = $null
        HasConfigMatch = $false
    }

    $sshConfigPath = "$env:USERPROFILE\.ssh\config"
    if (-not (Test-Path $sshConfigPath)) {
        return [pscustomobject]$connectionDetails
    }

    $configLines = Get-Content $sshConfigPath
    $currentBlock = $null
    foreach ($line in ($configLines + @('Host __END__'))) {
        if ($line -match '^\s*Host\s+(.+)$') {
            if ($currentBlock) {
                $hostPatterns = @($currentBlock.Host -split '\s+' | Where-Object { $_ })
                $matchesVmIp = -not [string]::IsNullOrWhiteSpace($currentBlock.HostName) -and $currentBlock.HostName -eq $VmIp
                $matchesVmName = $hostPatterns -contains $VmName
                if ($matchesVmIp -or $matchesVmName) {
                    $connectionDetails.Host = if ($hostPatterns.Count -gt 0) { $hostPatterns[0] } else { $VmIp }
                    if (-not [string]::IsNullOrWhiteSpace($currentBlock.HostName)) {
                        $connectionDetails.HostName = $currentBlock.HostName
                    }
                    $connectionDetails.User = $currentBlock.User
                    $connectionDetails.HasConfigMatch = $true
                    break
                }
            }

            $currentBlock = [ordered]@{
                Host = $Matches[1].Trim()
                HostName = $null
                User = $null
            }
            continue
        }

        if (-not $currentBlock) {
            continue
        }

        if ($line -match '^\s*HostName\s+(.+)$') {
            $currentBlock.HostName = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s*User\s+(.+)$') {
            $currentBlock.User = $Matches[1].Trim()
        }
    }

    return [pscustomobject]$connectionDetails
}

# Connect if not already
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged in. Connecting to Azure..."
    Connect-AzAccount
}

# Select subscription
$subs = Get-AzSubscription | Sort-Object Name
if ($subs.Count -eq 0) { Write-Error "No subscriptions found."; exit 1 }

Write-Host "`nAvailable Subscriptions:"
for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "  $($i+1). $($subs[$i].Name) [$($subs[$i].Id)]"
}
$subIdx = [int](Read-Host "`nSelect subscription number") - 1
if ($subIdx -lt 0 -or $subIdx -ge $subs.Count) { Write-Error "Invalid selection."; exit 1 }
Set-AzContext -SubscriptionId $subs[$subIdx].Id | Out-Null
Write-Host "Using subscription: $($subs[$subIdx].Name)"

# Select resource group
$rgs = Get-AzResourceGroup | Sort-Object ResourceGroupName
if ($rgs.Count -eq 0) { Write-Error "No resource groups found in this subscription."; exit 1 }

Write-Host "`nAvailable Resource Groups:"
for ($i = 0; $i -lt $rgs.Count; $i++) {
    Write-Host "  $($i+1). $($rgs[$i].ResourceGroupName)"
}
$rgIdx = [int](Read-Host "`nSelect resource group number") - 1
if ($rgIdx -lt 0 -or $rgIdx -ge $rgs.Count) { Write-Error "Invalid selection."; exit 1 }
$rgName = $rgs[$rgIdx].ResourceGroupName
Write-Host "Using resource group: $rgName"

# Select VM
$vms = Get-AzVM -ResourceGroupName $rgName | Sort-Object Name
if ($vms.Count -eq 0) { Write-Error "No VMs found in resource group '$rgName'."; exit 1 }

Write-Host "`nAvailable VMs in '$rgName':"
for ($i = 0; $i -lt $vms.Count; $i++) {
    Write-Host "  $($i+1). $($vms[$i].Name)"
}
$vmIdx = [int](Read-Host "`nSelect VM number") - 1
if ($vmIdx -lt 0 -or $vmIdx -ge $vms.Count) { Write-Error "Invalid selection."; exit 1 }
$vmName = $vms[$vmIdx].Name

# Start the VM
Write-Host "`nStarting VM '$vmName'... (this may take a minute)"
$result = Start-AzVM -ResourceGroupName $rgName -Name $vmName
Write-Host "Done! Status: $($result.Status)"

# Resolve the VM's public IP address
$vmDetails = Get-AzVM -ResourceGroupName $rgName -Name $vmName
$nicId = $vmDetails.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId
$pipConfig = $nic.IpConfigurations[0].PublicIpAddress
if (-not $pipConfig) {
    Write-Error "No public IP address is associated with '$vmName'. Cannot open an SSH or VS Code session."
    exit 1
}

# Parse resource group and name from the resource ID
$pipIdParts = $pipConfig.Id -split '/'
$pipRg = $pipIdParts[$pipIdParts.IndexOf('resourceGroups') + 1]
$pipName = $pipIdParts[-1]
$pip = Get-AzPublicIpAddress -ResourceGroupName $pipRg -Name $pipName
$vmIp = $pip.IpAddress
if ([string]::IsNullOrWhiteSpace($vmIp) -or $vmIp -eq 'None') {
    Write-Error "Public IP address for '$vmName' is not yet assigned. Try again in a moment."
    exit 1
}

Write-Host "VM public IP: $vmIp"

$sshConnection = Get-VmSshConnectionDetails -VmName $vmName -VmIp $vmIp
if ($sshConnection.HasConfigMatch) {
    if ([string]::IsNullOrWhiteSpace($sshConnection.User)) {
        Write-Host "Found SSH config entry - using host '$($sshConnection.Host)'"
    } else {
        Write-Host "Found SSH config entry - using user '$($sshConnection.User)' via host '$($sshConnection.Host)'"
    }
}

$connectionMode = Select-ConnectionMode -TargetName $vmName
if ($connectionMode -eq 'SSH') {
    Test-RequiredCommand -Name 'ssh' -InstallHint "Install OpenSSH Client and ensure the 'ssh' command is on PATH."

    if ($sshConnection.HasConfigMatch) {
        Write-Host "`nOpening SSH session to '$vmName' via '$($sshConnection.Host)'..."
        & ssh $sshConnection.Host
    } else {
        $sshUser = Read-Host "Enter SSH username"
        if ([string]::IsNullOrWhiteSpace($sshUser)) {
            Write-Error 'SSH username is required.'
            exit 1
        }

        Write-Host "`nOpening SSH session to '$sshUser@$vmIp'..."
        & ssh "$sshUser@$vmIp"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSH exited with code $LASTEXITCODE."
        exit $LASTEXITCODE
    }

    exit 0
}

Test-RequiredCommand -Name 'code' -InstallHint "Install Visual Studio Code and ensure the 'code' command is on PATH."

$sshUser = $sshConnection.User
if ([string]::IsNullOrWhiteSpace($sshUser)) {
    $sshUser = Read-Host "Enter SSH username"
    if ([string]::IsNullOrWhiteSpace($sshUser)) {
        Write-Error 'SSH username is required to open VS Code Remote SSH.'
        exit 1
    }
}

$remotePath = Read-Host "Enter remote path to open (leave blank for /home/$sshUser)"
if ([string]::IsNullOrWhiteSpace($remotePath)) { $remotePath = "/home/$sshUser" }

$remoteUri = "vscode-remote://ssh-remote+$sshUser@$($sshConnection.Host)$remotePath"
Write-Host "`nLaunching VS Code -> $remoteUri"
code --folder-uri $remoteUri
