# Start an Azure VM interactively by selecting subscription, resource group, and VM

# Ensure Az module is available
if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    Write-Error "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser"
    exit 1
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

# Offer to open VS Code with Remote SSH
$openVSCode = Read-Host "`nOpen VS Code with Remote SSH for '$vmName'? (y/n)"
if ($openVSCode -match '^[Yy]') {

    # Resolve the VM's public IP address
    $vmDetails = Get-AzVM -ResourceGroupName $rgName -Name $vmName
    $nicId = $vmDetails.NetworkProfile.NetworkInterfaces[0].Id
    $nic = Get-AzNetworkInterface -ResourceId $nicId
    $pipConfig = $nic.IpConfigurations[0].PublicIpAddress
    if (-not $pipConfig) {
        Write-Error "No public IP address is associated with '$vmName'. Cannot open Remote SSH."
    } else {
        # Parse resource group and name from the resource ID
        $pipIdParts = $pipConfig.Id -split '/'
        $pipRg   = $pipIdParts[$pipIdParts.IndexOf('resourceGroups') + 1]
        $pipName = $pipIdParts[-1]
        $pip = Get-AzPublicIpAddress -ResourceGroupName $pipRg -Name $pipName
        $vmIp = $pip.IpAddress
        if ([string]::IsNullOrWhiteSpace($vmIp) -or $vmIp -eq 'None') {
            Write-Error "Public IP address for '$vmName' is not yet assigned. Try again in a moment."
        } else {
            Write-Host "VM public IP: $vmIp"

            # Try to find a matching entry in ~/.ssh/config by Host alias or HostName
            $sshConfigPath = "$env:USERPROFILE\.ssh\config"
            $sshUser = $null
            $sshHost = $vmIp  # default to IP for VS Code URI
            if (Test-Path $sshConfigPath) {
                $configLines = Get-Content $sshConfigPath
                $inBlock = $false
                $blockHost = $null
                $blockHostName = $null
                $blockUser = $null
                foreach ($line in ($configLines + @('Host __END__'))) {
                    if ($line -match '^\s*Host\s+(.+)$') {
                        # Save previous block if it matched
                        if ($inBlock -and $blockUser) {
                            $matchIp   = $blockHostName -and ($blockHostName -eq $vmIp)
                            $matchName = $blockHost -and ($blockHost -eq $vmName)
                            if ($matchIp -or $matchName) {
                                $sshUser = $blockUser
                                if ($blockHost) { $sshHost = $blockHost }
                                break
                            }
                        }
                        $blockHost = $Matches[1].Trim()
                        $blockHostName = $null
                        $blockUser = $null
                        $inBlock = $true
                    } elseif ($inBlock) {
                        if ($line -match '^\s*HostName\s+(.+)$') { $blockHostName = $Matches[1].Trim() }
                        if ($line -match '^\s*User\s+(.+)$')     { $blockUser     = $Matches[1].Trim() }
                    }
                }
            }

            if ($sshUser) {
                Write-Host "Found SSH config entry - using User '$sshUser' via host '$sshHost'"
            } else {
                $sshUser = Read-Host "Enter SSH username"
            }
            $remotePath = Read-Host "Enter remote path to open (leave blank for /home/$sshUser)"
            if ([string]::IsNullOrWhiteSpace($remotePath)) { $remotePath = "/home/$sshUser" }

            $remoteUri = "vscode-remote://ssh-remote+$sshUser@$sshHost$remotePath"
            Write-Host "`nLaunching VS Code -> $remoteUri"
            code --folder-uri $remoteUri
        }
    }
}
