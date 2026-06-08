# Run Scripts From Anywhere and via PowerToys Run

This repository includes:
- `codespace_start.ps1`
- `az_vm_start.ps1`

Use the one-time setup below to:
1. Run these scripts from any directory in PowerShell.
2. Launch them in an interactive terminal from PowerToys Run.

## One-Time Setup

Run this in PowerShell from the repository root:

```powershell
$scriptDir = (Get-Location).Path
$requiredScripts = @("codespace_start.ps1", "az_vm_start.ps1")
$missingScripts = @(
    $requiredScripts | Where-Object {
        -not (Test-Path -Path (Join-Path $scriptDir $_) -PathType Leaf)
    }
)

if ($missingScripts.Count -gt 0) {
    throw "Run this command from the repository root. Missing: $($missingScripts -join ', ')"
}

$shimDir = Join-Path $env:USERPROFILE "bin"

New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

@"
@echo off
pwsh -NoLogo -NoExit -ExecutionPolicy Bypass -File "$scriptDir\codespace_start.ps1"
"@ | Set-Content -Path (Join-Path $shimDir "codespace.cmd") -Encoding Ascii

@"
@echo off
pwsh -NoLogo -NoExit -ExecutionPolicy Bypass -File "$scriptDir\az_vm_start.ps1"
"@ | Set-Content -Path (Join-Path $shimDir "azvm.cmd") -Encoding Ascii

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @($userPath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$needed = @($scriptDir, $shimDir) | Where-Object { $parts -notcontains $_ }
if ($needed.Count -gt 0) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $needed) -join ";"), "User")
}

# Make available in current terminal now
$env:Path = "$shimDir;$scriptDir;$env:Path"

# Optional: only if script execution is blocked in your profile
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

## How to Launch

### From any PowerShell directory

Run either:
- `codespace_start` or `az_vm_start`
- `codespace` or `azvm`

### From PowerToys Run

Type and run:
- `codespace`
- `azvm`

Both commands open `pwsh` with `-NoExit`, so prompts stay interactive.

## If It Does Not Show Up in PowerToys Run

Restart PowerToys Run (or sign out and sign back in) so it picks up updated PATH entries.
