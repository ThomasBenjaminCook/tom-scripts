# Start an Azure VM interactively by selecting subscription, resource group, and VM

# Ensure required Az modules are available
$requiredAzModules = @('Az.Compute', 'Az.Network', 'Az.Resources')
$missingAzModules = @($requiredAzModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missingAzModules.Count -gt 0) {
    Write-Error "Required Az PowerShell modules not found ($($missingAzModules -join ', ')). Install with: Install-Module -Name Az -Scope CurrentUser"
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

function Ensure-AzureCliSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    Test-RequiredCommand -Name 'az' -InstallHint "Install Azure CLI and ensure the 'az' command is on PATH."

    & az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Azure CLI is not logged in. Connecting..."
        & az login --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'Azure CLI login failed.'
            exit $LASTEXITCODE
        }
    }

    & az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to select Azure CLI subscription '$SubscriptionId'."
        exit $LASTEXITCODE
    }
}

function Ensure-AzureCliExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtensionName
    )

    Test-RequiredCommand -Name 'az' -InstallHint "Install Azure CLI and ensure the 'az' command is on PATH."

    & az extension show --name $ExtensionName --only-show-errors --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "Azure CLI extension '$ExtensionName' is required. Installing..."
    & az extension add --name $ExtensionName --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install Azure CLI extension '$ExtensionName'."
        exit $LASTEXITCODE
    }
}

function Read-YesNoResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [bool]$DefaultValue = $true
    )

    $suffix = if ($DefaultValue) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $response = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $DefaultValue
        }

        switch -Regex ($response) {
            '^[Yy](es)?$' { return $true }
            '^[Nn]o?$' { return $false }
            default { Write-Host 'Please answer Y or N.' }
        }
    }
}

function Read-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [int]$Minimum = 1
    )

    while ($true) {
        $rawValue = (Read-Host $Prompt).Trim()
        $parsedValue = 0
        if ([int]::TryParse($rawValue, [ref]$parsedValue) -and $parsedValue -ge $Minimum) {
            return $parsedValue
        }

        Write-Host "Enter a whole number greater than or equal to $Minimum."
    }
}

function Get-PowerShellExecutablePath {
    $candidatePaths = @(
        ((Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source),
        (Join-Path $PSHOME 'pwsh.exe'),
        ((Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue).Source),
        (Join-Path $PSHOME 'powershell.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    Write-Error 'Could not locate a PowerShell executable to schedule Bastion cleanup.'
    exit 1
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

function Resolve-SshIdentityFilePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolvedPath = $Path.Trim()
    if (
        ($resolvedPath.StartsWith('"') -and $resolvedPath.EndsWith('"')) -or
        ($resolvedPath.StartsWith("'") -and $resolvedPath.EndsWith("'"))
    ) {
        $resolvedPath = $resolvedPath.Substring(1, $resolvedPath.Length - 2)
    }

    if ($resolvedPath -eq '~') {
        $resolvedPath = $env:USERPROFILE
    } elseif ($resolvedPath.StartsWith('~/') -or $resolvedPath.StartsWith('~\')) {
        $resolvedPath = Join-Path $env:USERPROFILE $resolvedPath.Substring(2)
    }

    return [Environment]::ExpandEnvironmentVariables($resolvedPath)
}

function Get-VmSshConnectionDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [string]$VmIp
    )

    $connectionDetails = [ordered]@{
        Host = $VmIp
        HostName = $VmIp
        User = $null
        IdentityFile = $null
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
                $matchesVmIp = -not [string]::IsNullOrWhiteSpace($VmIp) -and -not [string]::IsNullOrWhiteSpace($currentBlock.HostName) -and $currentBlock.HostName -eq $VmIp
                $matchesVmName = $hostPatterns -contains $VmName
                if ($matchesVmIp -or $matchesVmName) {
                    $connectionDetails.Host = if ($hostPatterns.Count -gt 0) { $hostPatterns[0] } else { $VmIp }
                    if (-not [string]::IsNullOrWhiteSpace($currentBlock.HostName)) {
                        $connectionDetails.HostName = $currentBlock.HostName
                    }
                    $connectionDetails.User = $currentBlock.User
                    $connectionDetails.IdentityFile = Resolve-SshIdentityFilePath -Path $currentBlock.IdentityFile
                    $connectionDetails.HasConfigMatch = $true
                    break
                }
            }

            $currentBlock = [ordered]@{
                Host = $Matches[1].Trim()
                HostName = $null
                User = $null
                IdentityFile = $null
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
            continue
        }

        if ($line -match '^\s*IdentityFile\s+(.+)$') {
            $currentBlock.IdentityFile = $Matches[1].Trim()
        }
    }

    return [pscustomobject]$connectionDetails
}

function Get-AvailableSshIdentityFiles {
    $sshDirectory = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Test-Path $sshDirectory)) {
        return @()
    }

    $candidateFiles = Get-ChildItem -Path $sshDirectory -File | Where-Object {
        $_.Name -notmatch '\.pub$' -and
        $_.Name -notin @('authorized_keys', 'known_hosts', 'known_hosts.old', 'config') -and
        (
            $_.Name -match '^id_' -or
            $_.Extension -in @('.pem', '.key')
        )
    }

    return @($candidateFiles | Sort-Object Name | Select-Object -ExpandProperty FullName)
}

function Select-SshIdentityFile {
    param(
        [string]$DefaultIdentityFile,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $options = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($DefaultIdentityFile) -and (Test-Path $DefaultIdentityFile)) {
        $options.Add($DefaultIdentityFile)
    }

    foreach ($candidate in (Get-AvailableSshIdentityFiles)) {
        if ($options.Contains($candidate)) {
            continue
        }

        $options.Add($candidate)
    }

    while ($true) {
        Write-Host "`nSSH key selection for '$VmName':"
        if ($options.Count -gt 0) {
            for ($index = 0; $index -lt $options.Count; $index++) {
                $label = if ($index -eq 0 -and $options[$index] -eq $DefaultIdentityFile) { ' (from SSH config)' } else { '' }
                Write-Host "  $($index + 1). $($options[$index])$label"
            }
        } else {
            Write-Host '  No SSH keys were auto-detected in ~/.ssh'
        }

        Write-Host '  M. Enter a key path manually'
        Write-Host '  S. Skip key selection'

        $selection = (Read-Host "`nSelect SSH key").Trim()
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -match '^[Ss]$') {
            return $null
        }

        if ($selection -match '^[Mm]$') {
            $manualPath = Resolve-SshIdentityFilePath -Path (Read-Host 'Enter SSH private key path')
            if ([string]::IsNullOrWhiteSpace($manualPath)) {
                Write-Host 'SSH key path cannot be blank.'
                continue
            }

            if (-not (Test-Path $manualPath)) {
                Write-Host "SSH key '$manualPath' was not found."
                continue
            }

            return $manualPath
        }

        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $options.Count) {
            return $options[$selectedIndex - 1]
        }

        Write-Host 'Invalid selection.'
    }
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()

    try {
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Read-TextFileSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return ''
    }

    try {
        $content = [System.IO.File]::ReadAllText($Path)
        if ($null -eq $content) {
            return ''
        }

        return $content.Trim()
    }
    catch {
        return ''
    }
}

function Get-ResourceIdSegmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$SegmentName
    )

    $resourceIdParts = $ResourceId -split '/'
    $segmentIndex = [Array]::IndexOf($resourceIdParts, $SegmentName)
    if ($segmentIndex -lt 0 -or ($segmentIndex + 1) -ge $resourceIdParts.Count) {
        return $null
    }

    return $resourceIdParts[$segmentIndex + 1]
}

function ConvertTo-Hashtable {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    return ($InputObject | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
}

function Get-VirtualNetworkDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VirtualNetworkId
    )

    $virtualNetworkResourceGroupName = Get-ResourceIdSegmentValue -ResourceId $VirtualNetworkId -SegmentName 'resourceGroups'
    $virtualNetworkName = Get-ResourceIdSegmentValue -ResourceId $VirtualNetworkId -SegmentName 'virtualNetworks'
    if ([string]::IsNullOrWhiteSpace($virtualNetworkResourceGroupName) -or [string]::IsNullOrWhiteSpace($virtualNetworkName)) {
        Write-Error "Unable to resolve the virtual network details from '$VirtualNetworkId'."
        exit 1
    }

    $virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $virtualNetworkResourceGroupName -Name $virtualNetworkName
    return [pscustomobject]@{
        ResourceGroupName = $virtualNetworkResourceGroupName
        Name = $virtualNetworkName
        VirtualNetwork = $virtualNetwork
    }
}

function ConvertTo-Ipv4Integer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress
    )

    $address = [System.Net.IPAddress]::Parse($IpAddress)
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Only IPv4 addresses are supported. '$IpAddress' is not IPv4."
    }

    $bytes = $address.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-Ipv4Integer {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Value
    )

    $bytes = [System.BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-Ipv4CidrRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cidr
    )

    $cidrParts = $Cidr.Split('/')
    if ($cidrParts.Count -ne 2) {
        return $null
    }

    $prefixLength = 0
    if (-not [int]::TryParse($cidrParts[1], [ref]$prefixLength) -or $prefixLength -lt 0 -or $prefixLength -gt 32) {
        return $null
    }

    try {
        $ipValue = [uint64](ConvertTo-Ipv4Integer -IpAddress $cidrParts[0])
    }
    catch {
        return $null
    }

    $blockSize = [uint64]1 -shl (32 - $prefixLength)
    $start = [uint64]([math]::Floor($ipValue / $blockSize) * $blockSize)
    $end = $start + $blockSize - 1

    return [pscustomobject]@{
        Cidr = $Cidr
        PrefixLength = $prefixLength
        Start = $start
        End = $end
    }
}

function Test-Ipv4RangesOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Left,

        [Parameter(Mandatory = $true)]
        [psobject]$Right
    )

    return -not ($Left.End -lt $Right.Start -or $Right.End -lt $Left.Start)
}

function Find-AvailableSubnetPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ParentPrefixes,

        [Parameter(Mandatory = $true)]
        [string[]]$ExistingPrefixes,

        [int]$DesiredPrefixLength = 26
    )

    $existingRanges = @(
        $ExistingPrefixes |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Get-Ipv4CidrRange -Cidr $_ } |
            Where-Object { $null -ne $_ }
    )

    $candidateBlockSize = [uint64]1 -shl (32 - $DesiredPrefixLength)
    foreach ($parentPrefix in $ParentPrefixes) {
        $parentRange = Get-Ipv4CidrRange -Cidr $parentPrefix
        if ($null -eq $parentRange -or $parentRange.PrefixLength -gt $DesiredPrefixLength) {
            continue
        }

        for ($candidateStart = $parentRange.Start; ($candidateStart + $candidateBlockSize - 1) -le $parentRange.End; $candidateStart += $candidateBlockSize) {
            $candidateRange = [pscustomobject]@{
                Start = $candidateStart
                End = $candidateStart + $candidateBlockSize - 1
            }

            $overlapsExistingSubnet = $false
            foreach ($existingRange in $existingRanges) {
                if (Test-Ipv4RangesOverlap -Left $candidateRange -Right $existingRange) {
                    $overlapsExistingSubnet = $true
                    break
                }
            }

            if (-not $overlapsExistingSubnet) {
                return "$(ConvertFrom-Ipv4Integer -Value ([uint32]$candidateStart))/$DesiredPrefixLength"
            }
        }
    }

    return $null
}

function Test-TcpPortOpen {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }

        $client.EndConnect($connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-ReachableVnetIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmVnetId
    )

    $reachableVnetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $null = $reachableVnetIds.Add($VmVnetId)

    $vmVnetResourceGroupName = Get-ResourceIdSegmentValue -ResourceId $VmVnetId -SegmentName 'resourceGroups'
    $vmVnetName = Get-ResourceIdSegmentValue -ResourceId $VmVnetId -SegmentName 'virtualNetworks'
    if ([string]::IsNullOrWhiteSpace($vmVnetResourceGroupName) -or [string]::IsNullOrWhiteSpace($vmVnetName)) {
        return @($reachableVnetIds)
    }

    $peerings = @(Get-AzVirtualNetworkPeering -ResourceGroupName $vmVnetResourceGroupName -VirtualNetworkName $vmVnetName -ErrorAction SilentlyContinue)
    foreach ($peering in $peerings) {
        if ($peering.PeeringState -ne 'Connected') {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($peering.RemoteVirtualNetwork.Id)) {
            continue
        }

        $null = $reachableVnetIds.Add($peering.RemoteVirtualNetwork.Id)
    }

    return @($reachableVnetIds)
}

function Get-SubnetAddressPrefixes {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Subnet
    )

    $prefixes = @()
    if ($Subnet.PSObject.Properties.Name -contains 'AddressPrefix' -and -not [string]::IsNullOrWhiteSpace($Subnet.AddressPrefix)) {
        $prefixes += $Subnet.AddressPrefix
    }

    if ($Subnet.PSObject.Properties.Name -contains 'AddressPrefixes') {
        $prefixes += @($Subnet.AddressPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($prefixes | Select-Object -Unique)
}

function Get-AzureBastionSubnetPlan {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$VirtualNetwork
    )

    $bastionSubnet = @($VirtualNetwork.Subnets | Where-Object Name -eq 'AzureBastionSubnet' | Select-Object -First 1)
    if ($bastionSubnet.Count -gt 0) {
        $bastionSubnetPrefixes = Get-SubnetAddressPrefixes -Subnet $bastionSubnet[0]
        $hasValidPrefix = $false
        foreach ($bastionSubnetPrefix in $bastionSubnetPrefixes) {
            $bastionSubnetRange = Get-Ipv4CidrRange -Cidr $bastionSubnetPrefix
            if ($null -ne $bastionSubnetRange -and $bastionSubnetRange.PrefixLength -le 26) {
                $hasValidPrefix = $true
                break
            }
        }

        if (-not $hasValidPrefix) {
            return [pscustomobject]@{
                CanUse = $false
                RequiresCreation = $false
                NewSubnetPrefix = $null
                FailureReason = "The existing AzureBastionSubnet in virtual network '$($VirtualNetwork.Name)' must be /26 or larger."
            }
        }

        return [pscustomobject]@{
            CanUse = $true
            RequiresCreation = $false
            NewSubnetPrefix = $null
            FailureReason = $null
        }
    }

    $existingPrefixes = @(
        $VirtualNetwork.Subnets |
            ForEach-Object { Get-SubnetAddressPrefixes -Subnet $_ }
    )
    $newBastionSubnetPrefix = Find-AvailableSubnetPrefix -ParentPrefixes $VirtualNetwork.AddressSpace.AddressPrefixes -ExistingPrefixes $existingPrefixes -DesiredPrefixLength 26
    if ([string]::IsNullOrWhiteSpace($newBastionSubnetPrefix)) {
        return [pscustomobject]@{
            CanUse = $false
            RequiresCreation = $false
            NewSubnetPrefix = $null
            FailureReason = "Could not find free address space for an AzureBastionSubnet in virtual network '$($VirtualNetwork.Name)'."
        }
    }

    return [pscustomobject]@{
        CanUse = $true
        RequiresCreation = $true
        NewSubnetPrefix = $newBastionSubnetPrefix
        FailureReason = $null
    }
}

function Ensure-AzureBastionSubnet {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$VirtualNetwork,

        [Parameter(Mandatory = $true)]
        [psobject]$SubnetPlan
    )

    if (-not $SubnetPlan.CanUse) {
        Write-Error $SubnetPlan.FailureReason
        exit 1
    }

    if (-not $SubnetPlan.RequiresCreation) {
        return $VirtualNetwork
    }

    Write-Host "Creating AzureBastionSubnet '$($SubnetPlan.NewSubnetPrefix)' in virtual network '$($VirtualNetwork.Name)'..."
    $updatedVirtualNetwork = Add-AzVirtualNetworkSubnetConfig -Name 'AzureBastionSubnet' -VirtualNetwork $VirtualNetwork -AddressPrefix $SubnetPlan.NewSubnetPrefix
    return Set-AzVirtualNetwork -VirtualNetwork $updatedVirtualNetwork
}

function Get-BastionCreateProperties {
    param(
        [Parameter(Mandatory = $true)]
        $Properties,

        [switch]$Developer
    )

    $rawProperties = ConvertTo-Hashtable -InputObject $Properties
    $allowedPropertyNames = @(
        'disableCopyPaste',
        'dnsName',
        'enableFileCopy',
        'enableIpConnect',
        'enableKerberos',
        'enablePrivateOnlyBastion',
        'enableSessionRecording',
        'enableShareableLink',
        'enableTunneling',
        'ipConfigurations',
        'networkAcls',
        'scaleUnits',
        'virtualNetwork'
    )

    $createProperties = @{}
    foreach ($allowedPropertyName in $allowedPropertyNames) {
        if ($rawProperties.ContainsKey($allowedPropertyName)) {
            $createProperties[$allowedPropertyName] = $rawProperties[$allowedPropertyName]
        }
    }

    if ($Developer) {
        $createProperties.Remove('ipConfigurations') | Out-Null
        if (-not $createProperties.ContainsKey('virtualNetwork') -or -not $createProperties.virtualNetwork -or [string]::IsNullOrWhiteSpace($createProperties.virtualNetwork.id)) {
            Write-Error 'The Developer Bastion is missing the virtual network reference required for restoration.'
            exit 1
        }
    }

    return $createProperties
}

function Get-DeveloperBastionRestoreDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BastionName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $bastionResource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.Network/bastionHosts' -Name $BastionName -ExpandProperties
    $skuName = $bastionResource.Sku.Name
    if ([string]::IsNullOrWhiteSpace($skuName)) {
        $skuName = 'Unknown'
    }

    if ($skuName -ne 'Developer') {
        Write-Error "Bastion '$BastionName' in resource group '$ResourceGroupName' is not a Developer Bastion."
        exit 1
    }

    $restoreProperties = Get-BastionCreateProperties -Properties $bastionResource.Properties -Developer
    $restoreTags = if ($null -eq $bastionResource.Tags) { @{} } else { ConvertTo-Hashtable -InputObject $bastionResource.Tags }

    return [pscustomobject]@{
        Name = $bastionResource.Name
        ResourceGroupName = $bastionResource.ResourceGroupName
        Location = $bastionResource.Location
        SkuName = 'Developer'
        Tags = $restoreTags
        Properties = $restoreProperties
        ApiVersion = '2025-07-01'
    }
}

function Restore-DeveloperBastion {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RestoreDetails
    )

    $restoreParameters = @{
        ResourceGroupName = $RestoreDetails.ResourceGroupName
        ResourceType = 'Microsoft.Network/bastionHosts'
        ResourceName = $RestoreDetails.Name
        Location = $RestoreDetails.Location
        Sku = @{ Name = $RestoreDetails.SkuName }
        Properties = $RestoreDetails.Properties
        ApiVersion = $RestoreDetails.ApiVersion
        Force = $true
    }

    if ($RestoreDetails.Tags -and $RestoreDetails.Tags.Count -gt 0) {
        $restoreParameters.Tag = $RestoreDetails.Tags
    }

    New-AzResource @restoreParameters | Out-Null
}

function Get-BastionProvisioningTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmVnetId,

        [Parameter(Mandatory = $true)]
        [string[]]$ReachableVnetIds
    )

    $candidateVnetIds = @($VmVnetId) + @(
        $ReachableVnetIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne $VmVnetId } |
            Sort-Object -Unique
    )

    $failedCandidates = @()
    foreach ($candidateVnetId in $candidateVnetIds) {
        $virtualNetworkDetails = Get-VirtualNetworkDetails -VirtualNetworkId $candidateVnetId
        $subnetPlan = Get-AzureBastionSubnetPlan -VirtualNetwork $virtualNetworkDetails.VirtualNetwork
        if (-not $subnetPlan.CanUse) {
            $failedCandidates += "$($virtualNetworkDetails.Name): $($subnetPlan.FailureReason)"
            continue
        }

        $virtualNetwork = Ensure-AzureBastionSubnet -VirtualNetwork $virtualNetworkDetails.VirtualNetwork -SubnetPlan $subnetPlan
        return [pscustomobject]@{
            VirtualNetwork = $virtualNetwork
            VirtualNetworkName = $virtualNetworkDetails.Name
            VirtualNetworkResourceGroupName = $virtualNetworkDetails.ResourceGroupName
            UsesVmVnet = $candidateVnetId -eq $VmVnetId
            CreatedSubnet = $subnetPlan.RequiresCreation
            CreatedSubnetPrefix = $subnetPlan.NewSubnetPrefix
        }
    }

    $failureDetails = if ($failedCandidates.Count -gt 0) {
        $failedCandidates -join ' '
    } else {
        'No reachable virtual networks were available for evaluation.'
    }

    Write-Error "Could not find a reachable virtual network with a usable AzureBastionSubnet or free '/26' space. $failureDetails"
    exit 1
}

function New-BastionConnectionDetailsObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmResourceId
    )

    return [ordered]@{
        HasBastion = $false
        Id = $null
        Name = $null
        ResourceGroupName = $null
        VmResourceId = $VmResourceId
        SkuName = $null
        IsDeveloper = $false
        VirtualNetworkId = $null
        SupportsNativeClient = $false
        NativeClientUnsupportedReason = $null
    }
}

function Get-BastionConnectionDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmVnetId,

        [Parameter(Mandatory = $true)]
        [string[]]$ReachableVnetIds,

        [Parameter(Mandatory = $true)]
        [string]$VmResourceId
    )

    $connectionDetails = New-BastionConnectionDetailsObject -VmResourceId $VmResourceId

    $bastions = @(Get-AzBastion)
    $bestUnsupportedMatch = $null
    foreach ($bastion in $bastions) {
        $skuName = $bastion.Sku.Name
        if ([string]::IsNullOrWhiteSpace($skuName)) {
            $skuName = 'Unknown'
        }

        if ($skuName -eq 'Developer') {
            $bastionResource = Get-AzResource -ResourceId $bastion.Id -ExpandProperties
            $developerVnetId = $bastionResource.Properties.virtualNetwork.id
            if ([string]::IsNullOrWhiteSpace($developerVnetId) -or $developerVnetId -ne $VmVnetId) {
                continue
            }

            if ($null -eq $bestUnsupportedMatch) {
                $unsupportedDeveloperConnectionDetails = New-BastionConnectionDetailsObject -VmResourceId $VmResourceId
                $unsupportedDeveloperConnectionDetails.HasBastion = $true
                $unsupportedDeveloperConnectionDetails.Id = $bastion.Id
                $unsupportedDeveloperConnectionDetails.Name = $bastion.Name
                $unsupportedDeveloperConnectionDetails.ResourceGroupName = $bastion.ResourceGroupName
                $unsupportedDeveloperConnectionDetails.SkuName = $skuName
                $unsupportedDeveloperConnectionDetails.IsDeveloper = $true
                $unsupportedDeveloperConnectionDetails.VirtualNetworkId = $developerVnetId
                $unsupportedDeveloperConnectionDetails.NativeClientUnsupportedReason = "Developer Bastion supports portal-based connections only. This script's SSH flow requires Azure Bastion native client support, which requires Standard or Premium."
                $bestUnsupportedMatch = [pscustomobject]$unsupportedDeveloperConnectionDetails
            }
            continue
        }

        foreach ($ipConfiguration in @($bastion.IpConfigurations)) {
            if ([string]::IsNullOrWhiteSpace($ipConfiguration.Subnet.Id)) {
                continue
            }

            $bastionVnetId = $ipConfiguration.Subnet.Id -replace '/subnets/[^/]+$'
            if (-not ($ReachableVnetIds -contains $bastionVnetId)) {
                continue
            }

            $matchedConnectionDetails = New-BastionConnectionDetailsObject -VmResourceId $VmResourceId
            $matchedConnectionDetails.HasBastion = $true
            $matchedConnectionDetails.Id = $bastion.Id
            $matchedConnectionDetails.Name = $bastion.Name
            $matchedConnectionDetails.ResourceGroupName = $bastion.ResourceGroupName
            $matchedConnectionDetails.SkuName = $skuName
            $matchedConnectionDetails.VirtualNetworkId = $bastionVnetId
            $matchedConnectionDetails.SupportsNativeClient = $skuName -in @('Standard', 'Premium')
            if (-not $matchedConnectionDetails.SupportsNativeClient) {
                $matchedConnectionDetails.NativeClientUnsupportedReason = "Azure Bastion native client SSH requires Standard or Premium. The detected Bastion uses the '$skuName' SKU."
                if ($null -eq $bestUnsupportedMatch) {
                    $bestUnsupportedMatch = [pscustomobject]$matchedConnectionDetails
                }
                continue
            }

            return [pscustomobject]$matchedConnectionDetails
        }
    }

    if ($null -ne $bestUnsupportedMatch) {
        return $bestUnsupportedMatch
    }

    return [pscustomobject]$connectionDetails
}

function Start-BastionTunnel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BastionName,

        [Parameter(Mandatory = $true)]
        [string]$BastionResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceId,

        [int]$TargetPort = 22
    )

    Ensure-AzureCliExtension -ExtensionName 'bastion'

    $localPort = Get-FreeTcpPort
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) "az-bastion-tunnel-$PID-$localPort.stdout.log"
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "az-bastion-tunnel-$PID-$localPort.stderr.log"
    $argumentList = @(
        'network', 'bastion', 'tunnel',
        '--name', $BastionName,
        '--resource-group', $BastionResourceGroupName,
        '--target-resource-id', $TargetResourceId,
        '--resource-port', $TargetPort,
        '--port', $localPort,
        '--only-show-errors'
    )

    $process = Start-Process -FilePath 'az' -ArgumentList $argumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $isReady = $false

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $process.Refresh()

        if ($process.HasExited) {
            break
        }

        if (Test-TcpPortOpen -ComputerName '127.0.0.1' -Port $localPort) {
            $isReady = $true
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $isReady) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id
            try {
                $process.WaitForExit()
            }
            catch {
            }
        }

        $stderr = Read-TextFileSafe -Path $stderrPath
        $stdout = Read-TextFileSafe -Path $stdoutPath
        $details = $stderr
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $stdout
        }

        if (-not [string]::IsNullOrWhiteSpace($details)) {
            Write-Error "Azure Bastion tunnel did not become ready. $details"
        } else {
            Write-Error 'Azure Bastion tunnel did not become ready.'
        }

        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path $path) {
                try {
                    Remove-Item $path -Force -ErrorAction Stop
                }
                catch {
                }
            }
        }

        exit 1
    }

    return [pscustomobject]@{
        Process = $process
        LocalPort = $localPort
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
    }
}

function Stop-BastionTunnel {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Tunnel
    )

    if ($Tunnel.Process -and -not $Tunnel.Process.HasExited) {
        Stop-Process -Id $Tunnel.Process.Id
    }

    foreach ($path in @($Tunnel.StdOutPath, $Tunnel.StdErrPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            Remove-Item $path -Force
        }
    }
}

function New-TemporaryResourceName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$BaseName,

        [int]$MaxLength = 80
    )

    $normalizedBaseName = ($BaseName.ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-'
    $normalizedBaseName = $normalizedBaseName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalizedBaseName)) {
        $normalizedBaseName = 'resource'
    }

    $suffix = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $maxBaseNameLength = $MaxLength - $Prefix.Length - $suffix.Length - 2
    if ($maxBaseNameLength -lt 1) {
        Write-Error "The prefix '$Prefix' is too long to generate a temporary resource name."
        exit 1
    }

    if ($normalizedBaseName.Length -gt $maxBaseNameLength) {
        $normalizedBaseName = $normalizedBaseName.Substring(0, $maxBaseNameLength).Trim('-')
    }

    if ([string]::IsNullOrWhiteSpace($normalizedBaseName)) {
        $normalizedBaseName = 'resource'
    }

    return "$Prefix-$normalizedBaseName-$suffix"
}

function Start-TemporaryBastionCleanupProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$BastionName,

        [Parameter(Mandatory = $true)]
        [string]$PublicIpName,

        [Parameter(Mandatory = $true)]
        [int]$DelayHours,

        [string]$DeveloperRestoreDetailsBase64
    )

    $powerShellExecutablePath = Get-PowerShellExecutablePath
    $delaySeconds = [int]([TimeSpan]::FromHours($DelayHours).TotalSeconds)
    $contextPath = Join-Path ([System.IO.Path]::GetTempPath()) "az-temp-bastion-cleanup-$PID-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).azcontext.json"
    $cleanupStdOutLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "az-temp-bastion-cleanup-$PID-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).stdout.log"
    $cleanupStdErrLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "az-temp-bastion-cleanup-$PID-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).stderr.log"
    Save-AzContext -Path $contextPath -Force | Out-Null
    $cleanupScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts
Import-Module Az.Network
Import-Module Az.Resources
`$developerRestoreDetailsBase64 = '$DeveloperRestoreDetailsBase64'
try {
    Import-AzContext -Path '$contextPath' | Out-Null
    Start-Sleep -Seconds $delaySeconds
    Set-AzContext -SubscriptionId '$SubscriptionId' | Out-Null
    Remove-AzBastion -ResourceGroupName '$ResourceGroupName' -Name '$BastionName' -Force
    Remove-AzPublicIpAddress -ResourceGroupName '$ResourceGroupName' -Name '$PublicIpName' -Force
    if (-not [string]::IsNullOrWhiteSpace(`$developerRestoreDetailsBase64)) {
        `$developerRestoreDetails = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$developerRestoreDetailsBase64)) | ConvertFrom-Json -AsHashtable
        `$restoreParameters = @{
            ResourceGroupName = `$developerRestoreDetails.ResourceGroupName
            ResourceType = 'Microsoft.Network/bastionHosts'
            ResourceName = `$developerRestoreDetails.Name
            Location = `$developerRestoreDetails.Location
            Sku = @{ Name = `$developerRestoreDetails.SkuName }
            Properties = `$developerRestoreDetails.Properties
            ApiVersion = `$developerRestoreDetails.ApiVersion
            Force = `$true
        }

        if (`$developerRestoreDetails.ContainsKey('Tags') -and `$developerRestoreDetails.Tags -and `$developerRestoreDetails.Tags.Count -gt 0) {
            `$restoreParameters.Tag = `$developerRestoreDetails.Tags
        }

        New-AzResource @restoreParameters | Out-Null
    }
}
finally {
    if (Test-Path '$contextPath') {
        Remove-Item '$contextPath' -Force
    }
}
"@
    $encodedCleanupScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cleanupScript))
    try {
        $cleanupProcess = Start-Process -FilePath $powerShellExecutablePath -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCleanupScript) -RedirectStandardOutput $cleanupStdOutLogPath -RedirectStandardError $cleanupStdErrLogPath -WindowStyle Hidden -PassThru
    }
    catch {
        if (Test-Path $contextPath) {
            Remove-Item $contextPath -Force
        }

        throw
    }

    return [pscustomobject]@{
        ProcessId = $cleanupProcess.Id
        StdOutLogPath = $cleanupStdOutLogPath
        StdErrLogPath = $cleanupStdErrLogPath
        DeleteAfterUtc = (Get-Date).ToUniversalTime().AddHours($DelayHours)
    }
}

function New-TemporaryStandardBastion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$VmVnetId,

        [Parameter(Mandatory = $true)]
        [string[]]$ReachableVnetIds,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [int]$DeleteAfterHours,

        [psobject]$DeveloperBastionToReplace
    )

    $bastionProvisioningTarget = Get-BastionProvisioningTarget -VmVnetId $VmVnetId -ReachableVnetIds $ReachableVnetIds
    $virtualNetwork = $bastionProvisioningTarget.VirtualNetwork
    $bastionResourceGroupName = $bastionProvisioningTarget.VirtualNetworkResourceGroupName
    $developerRestoreDetails = $null
    $developerRestoreDetailsBase64 = $null
    $replacedDeveloperBastion = $false
    $bastionName = if ($DeveloperBastionToReplace -and $DeveloperBastionToReplace.IsDeveloper) { $DeveloperBastionToReplace.Name } else { New-TemporaryResourceName -Prefix 'bastion' -BaseName $VmName }
    $publicIpName = New-TemporaryResourceName -Prefix 'pip-bastion' -BaseName $VmName
    $deleteAfterUtc = (Get-Date).ToUniversalTime().AddHours($DeleteAfterHours)
    $resourceTags = @{
        CreatedBy = 'az_vm_start.ps1'
        Purpose = 'TemporaryBastion'
        SourceVm = $VmName
        DeleteAfterUtc = $deleteAfterUtc.ToString('o')
    }

    $publicIpAddress = $null
    $bastion = $null

    try {
        if ($DeveloperBastionToReplace -and $DeveloperBastionToReplace.IsDeveloper) {
            $developerRestoreDetails = Get-DeveloperBastionRestoreDetails -BastionName $DeveloperBastionToReplace.Name -ResourceGroupName $DeveloperBastionToReplace.ResourceGroupName
            $developerRestoreDetailsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($developerRestoreDetails | ConvertTo-Json -Depth 100 -Compress)))
        }

        if ($bastionProvisioningTarget.UsesVmVnet) {
            Write-Host "Using VM virtual network '$($bastionProvisioningTarget.VirtualNetworkName)' for the temporary Bastion."
        } else {
            Write-Host "VM virtual network '$VmVnetId' has no usable Bastion subnet space. Using reachable virtual network '$($bastionProvisioningTarget.VirtualNetworkName)' instead."
        }

        if ($null -ne $developerRestoreDetails) {
            Write-Host "Replacing Developer Bastion '$($developerRestoreDetails.Name)' in resource group '$($developerRestoreDetails.ResourceGroupName)' with a temporary Standard Bastion."
            Remove-AzBastion -ResourceGroupName $developerRestoreDetails.ResourceGroupName -Name $developerRestoreDetails.Name -Force
            $replacedDeveloperBastion = $true
        }

        Write-Host "Creating Standard public IP '$publicIpName' in resource group '$bastionResourceGroupName'..."
        $publicIpAddress = New-AzPublicIpAddress -ResourceGroupName $bastionResourceGroupName -Name $publicIpName -Location $virtualNetwork.Location -AllocationMethod Static -Sku Standard -Tag $resourceTags -Force

        Write-Host "Creating Standard Azure Bastion '$bastionName' in resource group '$bastionResourceGroupName'..."
        $bastion = New-AzBastion -ResourceGroupName $bastionResourceGroupName -Name $bastionName -PublicIpAddress $publicIpAddress -VirtualNetwork $virtualNetwork -Sku Standard -EnableTunneling $true -Tag $resourceTags

        $cleanupDetails = Start-TemporaryBastionCleanupProcess -SubscriptionId $SubscriptionId -ResourceGroupName $bastionResourceGroupName -BastionName $bastionName -PublicIpName $publicIpName -DelayHours $DeleteAfterHours -DeveloperRestoreDetailsBase64 $developerRestoreDetailsBase64
    }
    catch {
        if ($null -ne $bastion) {
            Remove-AzBastion -ResourceGroupName $bastionResourceGroupName -Name $bastionName -Force -ErrorAction SilentlyContinue | Out-Null
        }

        if ($null -ne $publicIpAddress) {
            Remove-AzPublicIpAddress -ResourceGroupName $bastionResourceGroupName -Name $publicIpName -Force -ErrorAction SilentlyContinue | Out-Null
        }

        if ($replacedDeveloperBastion -and $null -ne $developerRestoreDetails) {
            try {
                Write-Host "Restoring Developer Bastion '$($developerRestoreDetails.Name)' after provisioning failure..."
                Restore-DeveloperBastion -RestoreDetails $developerRestoreDetails
            }
            catch {
                Write-Error "Failed to restore Developer Bastion '$($developerRestoreDetails.Name)' after provisioning failure. $($_.Exception.Message)"
            }
        }

        Write-Error "Failed to provision a temporary Standard Azure Bastion. $($_.Exception.Message)"
        exit 1
    }

    return [pscustomobject]@{
        HasBastion = $true
        Name = $bastionName
        ResourceGroupName = $bastionResourceGroupName
        VmResourceId = $null
        SkuName = 'Standard'
        SupportsNativeClient = $true
        NativeClientUnsupportedReason = $null
        IsTemporary = $true
        ReplacedDeveloperBastion = $replacedDeveloperBastion
        PublicIpName = $publicIpName
        VirtualNetworkName = $bastionProvisioningTarget.VirtualNetworkName
        CleanupProcessId = $cleanupDetails.ProcessId
        CleanupStdOutLogPath = $cleanupDetails.StdOutLogPath
        CleanupStdErrLogPath = $cleanupDetails.StdErrLogPath
        DeleteAfterUtc = $cleanupDetails.DeleteAfterUtc
    }
}

function Get-TemporaryBastionDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$VmVnetId,

        [string]$Reason,

        [psobject]$ExistingBastionConnection
    )

    $virtualNetworkDetails = Get-VirtualNetworkDetails -VirtualNetworkId $VmVnetId
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host $Reason
    }

    if ($ExistingBastionConnection -and $ExistingBastionConnection.IsDeveloper) {
        Write-Host "You can temporarily replace Developer Bastion '$($ExistingBastionConnection.Name)' with a Standard Bastion for SSH. The script will restore the Developer Bastion after the temporary Standard Bastion is deleted."
    } else {
        Write-Host "You can create a temporary Standard Azure Bastion for '$VmName'. The script will prefer virtual network '$($virtualNetworkDetails.Name)' and fall back to a reachable peered virtual network if the VM VNet has no usable Bastion subnet space."
    }

    if (-not (Read-YesNoResponse -Prompt "Create a temporary Standard Azure Bastion for '$VmName'?" -DefaultValue $true)) {
        return [pscustomobject]@{
            ShouldCreate = $false
            DeleteAfterHours = $null
        }
    }

    $deleteAfterHours = Read-PositiveInteger -Prompt 'Delete the temporary Bastion after how many hours?' -Minimum 1
    return [pscustomobject]@{
        ShouldCreate = $true
        DeleteAfterHours = $deleteAfterHours
    }
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

# Resolve VM network details
$vmDetails = Get-AzVM -ResourceGroupName $rgName -Name $vmName
$nicId = $vmDetails.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId
$ipConfiguration = $nic.IpConfigurations[0]
$subnetId = $ipConfiguration.Subnet.Id
$vmVnetId = if ([string]::IsNullOrWhiteSpace($subnetId)) { $null } else { $subnetId -replace '/subnets/[^/]+$' }
$pipConfig = $ipConfiguration.PublicIpAddress
$vmIp = $null

if ($pipConfig) {
    # Parse resource group and name from the resource ID
    $pipRg = Get-ResourceIdSegmentValue -ResourceId $pipConfig.Id -SegmentName 'resourceGroups'
    $pipName = Get-ResourceIdSegmentValue -ResourceId $pipConfig.Id -SegmentName 'publicIPAddresses'
    $pip = Get-AzPublicIpAddress -ResourceGroupName $pipRg -Name $pipName
    $vmIp = $pip.IpAddress
}

if ([string]::IsNullOrWhiteSpace($vmIp) -or $vmIp -eq 'None') {
    $vmIp = $null
}

$sshConnection = Get-VmSshConnectionDetails -VmName $vmName -VmIp $vmIp
$bastionConnection = $null
if (-not [string]::IsNullOrWhiteSpace($vmVnetId)) {
    $reachableVnetIds = Get-ReachableVnetIds -VmVnetId $vmVnetId
    $bastionConnection = Get-BastionConnectionDetails -VmVnetId $vmVnetId -ReachableVnetIds $reachableVnetIds -VmResourceId $vmDetails.Id
}

if ($vmIp) {
    Write-Host "VM public IP: $vmIp"
} else {
    Write-Host "VM public IP: not available"
}

if ($bastionConnection -and $bastionConnection.HasBastion) {
    Write-Host "Found Azure Bastion host '$($bastionConnection.Name)' in resource group '$($bastionConnection.ResourceGroupName)' (SKU: $($bastionConnection.SkuName))"
}

if ($sshConnection.HasConfigMatch -and -not ($bastionConnection -and $bastionConnection.HasBastion)) {
    if ([string]::IsNullOrWhiteSpace($sshConnection.User)) {
        Write-Host "Found SSH config entry - using host '$($sshConnection.Host)'"
    } elseif ([string]::IsNullOrWhiteSpace($sshConnection.IdentityFile)) {
        Write-Host "Found SSH config entry - using user '$($sshConnection.User)' via host '$($sshConnection.Host)'"
    } else {
        Write-Host "Found SSH config entry - using user '$($sshConnection.User)' via host '$($sshConnection.Host)' with key '$($sshConnection.IdentityFile)'"
    }
}

$connectionMode = Select-ConnectionMode -TargetName $vmName
if ($connectionMode -eq 'SSH') {
    Test-RequiredCommand -Name 'ssh' -InstallHint "Install OpenSSH Client and ensure the 'ssh' command is on PATH."

    if ((-not ($bastionConnection -and $bastionConnection.HasBastion -and $bastionConnection.SupportsNativeClient)) -and -not [string]::IsNullOrWhiteSpace($vmVnetId)) {
        $temporaryBastionReason = if ($bastionConnection -and $bastionConnection.HasBastion) {
            "Found Azure Bastion '$($bastionConnection.Name)' for '$vmName', but it uses the '$($bastionConnection.SkuName)' SKU. $($bastionConnection.NativeClientUnsupportedReason)"
        } else {
            "No Azure Bastion host with native client support was found for '$vmName'."
        }

        $temporaryBastionDecision = Get-TemporaryBastionDecision -VmName $vmName -VmVnetId $vmVnetId -Reason $temporaryBastionReason -ExistingBastionConnection $bastionConnection
        if ($temporaryBastionDecision.ShouldCreate) {
            $developerBastionToReplace = if ($bastionConnection -and $bastionConnection.IsDeveloper) { $bastionConnection } else { $null }
            $bastionConnection = New-TemporaryStandardBastion -VmName $vmName -VmVnetId $vmVnetId -ReachableVnetIds $reachableVnetIds -SubscriptionId $subs[$subIdx].Id -DeleteAfterHours $temporaryBastionDecision.DeleteAfterHours -DeveloperBastionToReplace $developerBastionToReplace
            $deleteAfterLocalTime = $bastionConnection.DeleteAfterUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host "Temporary Azure Bastion '$($bastionConnection.Name)' is ready."
            Write-Host "Temporary Bastion virtual network: $($bastionConnection.VirtualNetworkName)"
            if ($bastionConnection.ReplacedDeveloperBastion) {
                Write-Host 'The original Developer Bastion will be restored automatically during cleanup.'
            }
            Write-Host "Scheduled deletion: $deleteAfterLocalTime"
            Write-Host "Cleanup process ID: $($bastionConnection.CleanupProcessId)"
            Write-Host "Cleanup stdout log: $($bastionConnection.CleanupStdOutLogPath)"
            Write-Host "Cleanup stderr log: $($bastionConnection.CleanupStdErrLogPath)"
        }
    }

    if ($bastionConnection -and $bastionConnection.HasBastion -and $bastionConnection.SupportsNativeClient) {
        Ensure-AzureCliSubscription -SubscriptionId $subs[$subIdx].Id

        $sshUser = $sshConnection.User
        if ([string]::IsNullOrWhiteSpace($sshUser)) {
            $sshUser = Read-Host "Enter SSH username"
            if ([string]::IsNullOrWhiteSpace($sshUser)) {
                Write-Error 'SSH username is required.'
                exit 1
            }
        }

        $sshIdentityFile = Select-SshIdentityFile -DefaultIdentityFile $sshConnection.IdentityFile -VmName $vmName

        Write-Host "`nOpening Azure Bastion tunnel to '$vmName' via '$($bastionConnection.Name)'..."
        $bastionTunnel = Start-BastionTunnel -BastionName $bastionConnection.Name -BastionResourceGroupName $bastionConnection.ResourceGroupName -TargetResourceId $vmDetails.Id
        $sshExitCode = 0

        try {
            Write-Host "Opening SSH session to '$sshUser@$vmName' through Azure Bastion..."
            $sshArguments = @()
            if (-not [string]::IsNullOrWhiteSpace($sshIdentityFile)) {
                $sshArguments += @('-i', $sshIdentityFile)
            }
            $sshArguments += @('-p', $bastionTunnel.LocalPort, '-o', "HostKeyAlias=az-bastion-$vmName", "$sshUser@127.0.0.1")
            & ssh @sshArguments
            $sshExitCode = $LASTEXITCODE
        }
        finally {
            Stop-BastionTunnel -Tunnel $bastionTunnel
        }

        if ($sshExitCode -ne 0) {
            Write-Error "SSH exited with code $sshExitCode."
            exit $sshExitCode
        }
    } elseif ($sshConnection.HasConfigMatch) {
        Write-Host "`nOpening SSH session to '$vmName' via '$($sshConnection.Host)'..."
        & ssh $sshConnection.Host
    } elseif ($vmIp) {
        $sshUser = Read-Host "Enter SSH username"
        if ([string]::IsNullOrWhiteSpace($sshUser)) {
            Write-Error 'SSH username is required.'
            exit 1
        }

        $sshIdentityFile = Select-SshIdentityFile -DefaultIdentityFile $sshConnection.IdentityFile -VmName $vmName

        Write-Host "`nOpening SSH session to '$sshUser@$vmIp'..."
        $sshArguments = @()
        if (-not [string]::IsNullOrWhiteSpace($sshIdentityFile)) {
            $sshArguments += @('-i', $sshIdentityFile)
        }
        $sshArguments += "$sshUser@$vmIp"
        & ssh @sshArguments
    } elseif ($bastionConnection -and $bastionConnection.HasBastion) {
        Write-Error "Found Azure Bastion '$($bastionConnection.Name)' for '$vmName', but it uses the '$($bastionConnection.SkuName)' SKU. $($bastionConnection.NativeClientUnsupportedReason) Create a temporary Standard Bastion or upgrade the existing Bastion to Standard or Premium."
        exit 1
    } else {
        Write-Error "No Azure Bastion host, SSH config match, or public IP is available for '$vmName'."
        exit 1
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSH exited with code $LASTEXITCODE."
        exit $LASTEXITCODE
    }

    exit 0
}

Test-RequiredCommand -Name 'code' -InstallHint "Install Visual Studio Code and ensure the 'code' command is on PATH."

if ($bastionConnection -and $bastionConnection.HasBastion -and -not $bastionConnection.SupportsNativeClient -and -not $sshConnection.HasConfigMatch -and -not $vmIp) {
    Write-Error "Found Azure Bastion '$($bastionConnection.Name)' for '$vmName', but it uses the '$($bastionConnection.SkuName)' SKU. $($bastionConnection.NativeClientUnsupportedReason) VS Code mode in this script still requires a direct SSH host."
    exit 1
}

if (-not $sshConnection.HasConfigMatch -and -not $vmIp) {
    Write-Error "No direct SSH host is available for '$vmName'. VS Code mode requires an SSH config match or a public IP."
    exit 1
}

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
