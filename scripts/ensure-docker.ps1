<#
.SYNOPSIS
    Ensures Docker Desktop is configured (AutoStart enabled, Resource Saver / Auto-Pause disabled),
    started, unpaused, and responsive on Windows 11.
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

function Add-PathIfMissing {
    param([string]$Directory)
    if ((Test-Path -LiteralPath $Directory) -and (($env:PATH -split ';') -notcontains $Directory)) {
        $env:PATH = "$Directory;$env:PATH"
    }
}

Add-PathIfMissing "C:\Program Files\Docker\Docker\resources\bin"
Add-PathIfMissing "C:\ProgramData\DockerDesktop\version-bin"
Add-PathIfMissing "C:\ProgramData\chocolatey\bin"

function Update-JsonConfigFile {
    param(
        [string]$FilePath,
        [System.Collections.IDictionary]$DesiredPairs
    )
    $configObj = [ordered]@{}
    if (Test-Path -LiteralPath $FilePath) {
        try {
            $rawContent = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($rawContent)) {
                $parsed = $rawContent | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $parsed.PSObject.Properties) {
                    $configObj[$prop.Name] = $prop.Value
                }
            }
        } catch {
            $configObj = [ordered]@{}
        }
    }
    $modified = $false
    foreach ($key in $DesiredPairs.Keys) {
        if (-not $configObj.Contains($key) -or $configObj[$key] -ne $DesiredPairs[$key]) {
            $configObj[$key] = $DesiredPairs[$key]
            $modified = $true
        }
    }
    if ($modified -or -not (Test-Path -LiteralPath $FilePath)) {
        $jsonOut = $configObj | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($FilePath, $jsonOut, [System.Text.UTF8Encoding]::new($false))
    }
}

function Set-DockerDesktopConfig {
    $dockerAppData = Join-Path $env:APPDATA "Docker"
    if (-not (Test-Path -LiteralPath $dockerAppData)) {
        New-Item -ItemType Directory -Path $dockerAppData -Force | Out-Null
    }

    $storeSettings = [ordered]@{
        AutoStart                             = $true
        UseResourceSaver                      = $false
        AutoPauseTimedActivity                = $false
        AutoPauseTimeoutSeconds               = 0
        DisplayedOnboarding                   = $true
        WslEngineEnabled                      = $true
        EnableIntegrationWithDefaultWslDistro = $true
        LicenseTermsVersion                   = 2
    }
    Update-JsonConfigFile -FilePath (Join-Path $dockerAppData "settings-store.json") -DesiredPairs $storeSettings

    $legacySettings = [ordered]@{
        autoStart                             = $true
        useResourceSaver                      = $false
        autoPauseTimedActivity                = $false
        autoPauseTimeoutSeconds               = 0
        displayedOnboarding                   = $true
        wslEngineEnabled                      = $true
        enableIntegrationWithDefaultWslDistro = $true
        licenseTermsVersion                   = 2
    }
    Update-JsonConfigFile -FilePath (Join-Path $dockerAppData "settings.json") -DesiredPairs $legacySettings

    $dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $dockerExe) {
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        if (Test-Path -LiteralPath $runKey) {
            Set-ItemProperty -Path $runKey -Name "Docker Desktop" -Value "`"$dockerExe`"" -ErrorAction SilentlyContinue
        }
    }

    $env:BUILDX_BAKE_ENTITLEMENTS_FS = "0"
    if ([Environment]::GetEnvironmentVariable("BUILDX_BAKE_ENTITLEMENTS_FS", "User") -ne "0") {
        [Environment]::SetEnvironmentVariable("BUILDX_BAKE_ENTITLEMENTS_FS", "0", "User")
    }
}

function Test-DockerDaemonReady {
    $dockerCmd = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        return $false
    }
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & docker.exe info 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    return ($exitCode -eq 0)
}

function Resume-ContainerIfPaused {
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $pausedIds = (& docker.exe ps -q --filter "status=paused" 2>$null)
    if ($pausedIds) {
        foreach ($cid in ($pausedIds -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($cid)) {
                Write-Host "[Docker] Unpausing container '$cid'..." -ForegroundColor Cyan
                $null = & docker.exe unpause $cid.Trim() 2>$null
            }
        }
    }
    $ErrorActionPreference = $prevPref
}

Set-DockerDesktopConfig

if (Test-DockerDaemonReady) {
    Resume-ContainerIfPaused
    exit 0
}

$compSys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
if ($compSys -and (-not $compSys.HypervisorPresent)) {
    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    if ($vmp -and $vmp.InstallState -eq 1) {
        Write-Warning "[Reboot Required] 'VirtualMachinePlatform' and 'WSL 2' are enabled in Windows, but the Hypervisor is not active yet because Windows has not been restarted since enabling them."
        Write-Warning "Please restart Windows 11 once so 'VirtualMachinePlatform' (vmcompute) finishes loading at boot. Docker Desktop will start automatically after reboot."
        exit 2
    }
}

Write-Host "[Docker] Docker daemon is not responding or is paused. Starting/unpausing Docker Desktop..." -ForegroundColor Yellow

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if ($isAdmin) {
    $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Set-Service -Name "com.docker.service" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    }
}

$dockerCmd = Get-Command docker.exe -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Start-Process -FilePath $dockerCmd.Source -ArgumentList "desktop", "start" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    $ErrorActionPreference = $prevPref
}

$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path -LiteralPath $dockerDesktopExe) {
    Start-Process -FilePath $dockerDesktopExe -ErrorAction SilentlyContinue | Out-Null
}

$elapsed = 0
$pollInterval = 2
while ($elapsed -lt $TimeoutSeconds) {
    if (Test-DockerDaemonReady) {
        Resume-ContainerIfPaused
        Write-Host "[Docker] Docker Desktop is running and ready." -ForegroundColor Green
        exit 0
    }
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval
}

Write-Warning "[Docker] Docker daemon did not become ready within ${TimeoutSeconds}s. If WSL2 was just installed, please restart Windows once."
exit 1
