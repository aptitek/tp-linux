<#
.SYNOPSIS
    Automated Windows 11 Setup & Auto-Update Script for TP Linux Workspace.
    Uses Chocolatey to install and keep up to date:
      - Docker Desktop (docker-desktop) + WSL 2 backend + Auto-Start & No-Auto-Pause
      - Git for Windows (git) + /usr/bin/bash & /bin/bash compatibility junctions
      - Mise-en-place (mise)
      - Visual Studio Code (vscode) + all recommended extensions (.vscode/extensions.json)
      - Taskfile / go-task (go-task)
    Also registers a Windows Scheduled Task ('TP-Linux-AutoUpdate') to keep all tools
    automatically up to date on startup and daily.
#>
[CmdletBinding()]
param(
    [switch]$ElevatedPhase,
    [string]$TargetUser = $env:USERNAME,
    [string]$LogFile = "",
    [switch]$SkipContainerStart
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-StatusLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    Write-Host $Message -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try {
            Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Invoke-BoundedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = 300
    )
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Write-StatusLog "[Warn] '$FilePath $($ArgumentList -join ' ')' timed out after ${TimeoutSeconds}s; terminating process..." Yellow
        try { $proc.Kill() } catch {}
        return 124
    }
    $proc.Refresh()
    return $proc.ExitCode
}

function Clear-InstallerLocks {
    Write-StatusLog "[Locks] Releasing any stale MSI / DISM / TiWorker locks..." Cyan
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-ElevatedPhase' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    foreach ($procName in @("Dism.exe", "DismHost.exe", "TiWorker.exe", "msiexec.exe")) {
        $null = Invoke-BoundedProcess -FilePath "taskkill.exe" -ArgumentList @("/F", "/IM", $procName, "/T") -TimeoutSeconds 15
    }
    Get-Process -Name "rundll32" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $extraPaths = @(
        "C:\ProgramData\chocolatey\bin",
        "C:\Program Files\Git\cmd",
        "C:\Program Files\Git\bin",
        "C:\Program Files\Git\usr\bin",
        "C:\Program Files\Docker\Docker\resources\bin",
        "C:\ProgramData\DockerDesktop\version-bin",
        "C:\Program Files\Microsoft VS Code\bin",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin",
        "$env:LOCALAPPDATA\mise\shims",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
        "$env:USERPROFILE\.local\bin",
        "$env:USERPROFILE\AppData\Local\mise\shims"
    )
    $combined = @()
    foreach ($part in (($machinePath -split ';') + ($userPath -split ';') + $extraPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($part) -and ($combined -notcontains $part)) {
            $combined += $part
        }
    }
    $env:PATH = ($combined -join ';')
}

function Ensure-ChocolateyInstalled {
    Update-SessionPath
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-StatusLog "[Choco] Chocolatey is already installed." Green
        return
    }
    Write-StatusLog "[Choco] Installing Chocolatey..." Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Update-SessionPath
}

function Install-Wsl2Prerequisites {
    Write-StatusLog "[WSL2] Ensuring VirtualMachinePlatform, HypervisorPlatform & WSL 2 are enabled..." Cyan

        foreach ($feature in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "HypervisorPlatform")) {
            $wmiFeat = Get-CimInstance Win32_OptionalFeature -Filter "Name='$feature'" -ErrorAction SilentlyContinue
            if ($wmiFeat -and $wmiFeat.InstallState -eq 1) {
                Write-StatusLog "[WSL2] Feature '$feature' is already enabled." Green
            }
            else {
                Write-StatusLog "[WSL2] Enabling Windows feature '$feature' via DISM..." Cyan
                $rc = Invoke-BoundedProcess -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:$feature", "/all", "/norestart") -TimeoutSeconds 180
                Write-StatusLog "[WSL2] DISM '$feature' finished (exit code: $rc)." Green
            }
        }

        Write-StatusLog "[WSL2] Ensuring Hypervisor boot launch type is set to 'auto' (bcdedit)..." Cyan
        $null = Invoke-BoundedProcess -FilePath "bcdedit.exe" -ArgumentList @("/set", "hypervisorlaunchtype", "auto") -TimeoutSeconds 30

        Write-StatusLog "[WSL2] Updating / installing WSL 2 kernel (via direct web download)..." Cyan
        $null = Invoke-BoundedProcess -FilePath "wsl.exe" -ArgumentList @("--update", "--web-download") -TimeoutSeconds 180
        $null = Invoke-BoundedProcess -FilePath "wsl.exe" -ArgumentList @("--set-default-version", "2") -TimeoutSeconds 30
        Write-StatusLog "[WSL2] WSL 2 configuration complete." Green
    }

    function Install-ChocoToolchain {
        Ensure-ChocolateyInstalled

        $null = Invoke-BoundedProcess -FilePath "choco.exe" -ArgumentList @("feature", "enable", "-n=allowGlobalConfirmation") -TimeoutSeconds 30

        Write-StatusLog "[Choco] Installing / upgrading git (with Unix tools on PATH)..." Cyan
        $rcGit = Invoke-BoundedProcess -FilePath "choco.exe" -ArgumentList @("upgrade", "git", "-y", "--no-progress", "--ignore-pending-reboot", "--params", "'/GitAndUnixToolsOnPath /NoAutoCrlf'") -TimeoutSeconds 600
        Write-StatusLog "[Choco] git finished (exit code: $rcGit)." Green

        foreach ($pkg in @("mise", "go-task", "vscode")) {
            Write-StatusLog "[Choco] Installing / upgrading $pkg..." Cyan
            $rcPkg = Invoke-BoundedProcess -FilePath "choco.exe" -ArgumentList @("upgrade", $pkg, "-y", "--no-progress", "--ignore-pending-reboot") -TimeoutSeconds 600
            Write-StatusLog "[Choco] $pkg finished (exit code: $rcPkg)." Green
        }

        $dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        $cachedMsi = Get-ChildItem -Path "$env:TEMP\chocolatey\docker-desktop" -Filter "DockerDesktop.msi" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

        if (-not (Test-Path -LiteralPath $dockerExe) -and $cachedMsi) {
            $msiLog = Join-Path $env:TEMP "docker-desktop-msi.log"
            Write-StatusLog "[Docker] Installing Docker Desktop from cached MSI ($($cachedMsi.FullName))..." Cyan
            $rcMsi = Invoke-BoundedProcess -FilePath "msiexec.exe" -ArgumentList @(
                "/i", "`"$($cachedMsi.FullName)`"",
                "/passive", "/norestart",
                "/l*v", "`"$msiLog`"",
                "REMOVEEXISTINGINSTALL=1",
                "ENGINE=wsl",
                "ALWAYSRUNSERVICE=1",
                "DISABLEANALYTICS=1"
            ) -TimeoutSeconds 600
            Write-StatusLog "[Docker] DockerDesktop.msi finished (exit code: $rcMsi)." Green
        }

        if (-not (Test-Path -LiteralPath $dockerExe)) {
            Write-StatusLog "[Choco] Installing docker-desktop via Chocolatey..." Cyan
            $rcDocker = Invoke-BoundedProcess -FilePath "choco.exe" -ArgumentList @(
                "upgrade", "docker-desktop", "-y", "--force", "--no-progress", "--ignore-pending-reboot",
                "--install-arguments=`"'/passive /norestart ENGINE=wsl ALWAYSRUNSERVICE=1 DISABLEANALYTICS=1'`""
            ) -TimeoutSeconds 900
            Write-StatusLog "[Choco] docker-desktop finished (exit code: $rcDocker)." Green
        }
        else {
            Write-StatusLog "[Choco] Ensuring docker-desktop is up to date..." Cyan
            $rcDocker = Invoke-BoundedProcess -FilePath "choco.exe" -ArgumentList @(
                "upgrade", "docker-desktop", "-y", "--no-progress", "--ignore-pending-reboot",
                "--install-arguments=`"'/passive /norestart ENGINE=wsl ALWAYSRUNSERVICE=1 DISABLEANALYTICS=1'`""
            ) -TimeoutSeconds 900
            Write-StatusLog "[Choco] docker-desktop check finished (exit code: $rcDocker)." Green
        }

        Update-SessionPath
    }

    function Ensure-PosixBashJunctions {
        $gitUsrBin = "C:\Program Files\Git\usr\bin"
        $gitBin = "C:\Program Files\Git\bin"

        if (Test-Path -LiteralPath $gitUsrBin) {
            if (-not (Test-Path -LiteralPath "C:\usr")) {
                New-Item -ItemType Directory -Path "C:\usr" -Force | Out-Null
            }
            if (-not (Test-Path -LiteralPath "C:\usr\bin")) {
                New-Item -ItemType Junction -Path "C:\usr\bin" -Target $gitUsrBin -Force | Out-Null
                Write-StatusLog "[Bash] Created junction C:\usr\bin -> $gitUsrBin (/usr/bin/bash ready)." Green
            }
        }

        if (Test-Path -LiteralPath $gitBin) {
            if (-not (Test-Path -LiteralPath "C:\bin")) {
                New-Item -ItemType Junction -Path "C:\bin" -Target $gitBin -Force | Out-Null
                Write-StatusLog "[Bash] Created junction C:\bin -> $gitBin (/bin/bash ready)." Green
            }
        }

        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $machineDirs = @($machinePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $requiredMachineDirs = @(
            "C:\ProgramData\chocolatey\bin",
            "C:\Program Files\Git\cmd",
            "C:\Program Files\Git\bin",
            "C:\Program Files\Git\usr\bin",
            "C:\Program Files\Docker\Docker\resources\bin",
            "C:\Program Files\Microsoft VS Code\bin"
        )
        $pathChanged = $false
        foreach ($dir in $requiredMachineDirs) {
            if ((Test-Path -LiteralPath $dir) -and ($machineDirs -notcontains $dir)) {
                $machineDirs += $dir
                $pathChanged = $true
            }
        }
        if ($pathChanged) {
            [Environment]::SetEnvironmentVariable("Path", ($machineDirs -join ';'), "Machine")
            Write-StatusLog "[PATH] Updated Machine PATH with Git, Docker, VS Code, and Chocolatey binaries." Green
        }
    }

    function Configure-DockerGroupAndService {
        param([string]$UserAccount)
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($UserAccount)) {
            Add-LocalGroupMember -Group "docker-users" -Member $UserAccount -ErrorAction SilentlyContinue
        }

        $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name "com.docker.service" -StartupType Automatic -ErrorAction SilentlyContinue
            if ($svc.Status -ne "Running") {
                Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
            }
        }
        $ErrorActionPreference = $prevPref
    }

    function Register-AutoUpdateScheduledTask {
        Write-StatusLog "[AutoUpdate] Configuring automatic Chocolatey & WSL updates via Scheduled Task..." Cyan
        $autoUpdateDir = "C:\ProgramData\tp-linux"
        if (-not (Test-Path -LiteralPath $autoUpdateDir)) {
            New-Item -ItemType Directory -Path $autoUpdateDir -Force | Out-Null
        }

        $autoUpdateScript = Join-Path $autoUpdateDir "auto-update.ps1"
        $scriptLines = @(
            '$ErrorActionPreference = "Continue"',
            '$env:PATH = "C:\ProgramData\chocolatey\bin;C:\Program Files\Git\cmd;C:\Program Files\Git\usr\bin;$env:PATH"',
            'if (Get-Command choco.exe -ErrorAction SilentlyContinue) {',
            '    choco.exe upgrade chocolatey git docker-desktop mise vscode go-task -y --no-progress --ignore-pending-reboot',
            '}',
            'if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {',
            '    wsl.exe --update --web-download',
            '}',
            'if (Get-Command mise.exe -ErrorAction SilentlyContinue) {',
            '    mise.exe upgrade',
            '}'
        )
        [System.IO.File]::WriteAllLines($autoUpdateScript, $scriptLines, [System.Text.UTF8Encoding]::new($false))

        $taskName = "TP-Linux-AutoUpdate"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$autoUpdateScript`""
        $triggerBoot = New-ScheduledTaskTrigger -AtStartup
        $triggerDaily = New-ScheduledTaskTrigger -Daily -At "12:00PM"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($triggerBoot, $triggerDaily) -Settings $settings -Principal $principal -Force | Out-Null
        Write-StatusLog "[AutoUpdate] Scheduled Task '$taskName' registered (runs at startup and daily at 12:00)." Green
    }

    function Invoke-ElevatedProvisioning {
        Clear-InstallerLocks

        $sudoCmd = Get-Command sudo.exe -ErrorAction SilentlyContinue
        if ($sudoCmd) {
            $null = Invoke-BoundedProcess -FilePath "sudo.exe" -ArgumentList @("config", "--enable", "normal") -TimeoutSeconds 15
        }
        Install-Wsl2Prerequisites
        Install-ChocoToolchain
        Ensure-PosixBashJunctions
        Configure-DockerGroupAndService -UserAccount $TargetUser
        Register-AutoUpdateScheduledTask
        Write-StatusLog "[Elevated] Elevated provisioning completed successfully." Green
    }

    function Invoke-UserFallbackToolchain {
        Update-SessionPath
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            $wingetMap = @(
                @{ Cmd = "git"; Id = "Git.Git" },
                @{ Cmd = "mise"; Id = "jdx.mise" },
                @{ Cmd = "task"; Id = "Task.Task" },
                @{ Cmd = "code"; Id = "Microsoft.VisualStudioCode" },
                @{ Cmd = "docker"; Id = "Docker.DockerDesktop" }
            )
            foreach ($entry in $wingetMap) {
                if (-not (Get-Command $entry.Cmd -ErrorAction SilentlyContinue)) {
                    Write-StatusLog "[Fallback] Installing $($entry.Id) via winget..." Yellow
                    & winget.exe install -e --id $entry.Id --accept-source-agreements --accept-package-agreements
                    Update-SessionPath
                }
            }
        }
        $ErrorActionPreference = $prevPref
    }

    function Install-VsCodeExtensionsAndSettings {
        Update-SessionPath
        $codeCmd = Get-Command code.cmd -ErrorAction SilentlyContinue
        if (-not $codeCmd) {
            $codeCmd = Get-Command code.exe -ErrorAction SilentlyContinue
        }
        $extensionsJsonPath = Join-Path $RepoRoot ".vscode\extensions.json"
        if ($codeCmd -and (Test-Path -LiteralPath $extensionsJsonPath)) {
            $extData = Get-Content -LiteralPath $extensionsJsonPath -Raw | ConvertFrom-Json
            $installedRaw = & $codeCmd.Source --list-extensions 2>$null
            $installedList = @($installedRaw | ForEach-Object { "$_".Trim().ToLowerInvariant() })

            foreach ($ext in $extData.recommendations) {
                if ($installedList -notcontains $ext.ToLowerInvariant()) {
                    Write-StatusLog "[VS Code] Installing extension: $ext..." Cyan
                    $prevPref = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    & $codeCmd.Source --install-extension $ext --force | Out-Null
                    $ErrorActionPreference = $prevPref
                }
            }
        }
    }

    function Initialize-MiseAndGuardrails {
        Update-SessionPath
        $env:MISE_DISABLE_TOOLS = "dockle"
        [Environment]::SetEnvironmentVariable("MISE_DISABLE_TOOLS", "dockle", "User")
        $miseCmd = Get-Command mise.exe -ErrorAction SilentlyContinue
        if (-not $miseCmd) {
            return
        }
        Push-Location $RepoRoot
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            Write-StatusLog "[Mise] Trusting and installing workspace tools from mise.toml..." Cyan
            & $miseCmd.Source trust -a
            & $miseCmd.Source settings set disable_tools "dockle"
            & $miseCmd.Source install
        }
        finally {
            $ErrorActionPreference = $prevPref
            Pop-Location
        }
        Update-SessionPath
    }

    if ($ElevatedPhase) {
        Invoke-ElevatedProvisioning
        exit 0
    }

    if (Test-IsAdministrator) {
        Invoke-ElevatedProvisioning
    }
    else {
        Write-Host "[Setup] Requesting Administrator privileges (UAC) to install Chocolatey packages, WSL2, and Auto-Update task..." -ForegroundColor Cyan
        $tempLog = Join-Path $env:TEMP "tp-linux-elevated-setup.log"
        if (Test-Path -LiteralPath $tempLog) {
            Remove-Item -LiteralPath $tempLog -Force -ErrorAction SilentlyContinue
        }
        try {
            $argList = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$PSCommandPath`"",
                "-ElevatedPhase",
                "-TargetUser", "`"$env:USERNAME`"",
                "-LogFile", "`"$tempLog`""
            )
            $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList -Wait -PassThru
            if (Test-Path -LiteralPath $tempLog) {
                Get-Content -LiteralPath $tempLog | Write-Host
            }
            if ($proc.ExitCode -ne 0) {
                Write-Warning "[Setup] Elevated setup exited with code $($proc.ExitCode). Running user-level fallback..."
                Invoke-UserFallbackToolchain
            }
        }
        catch {
            Write-Warning "[Setup] UAC elevation was cancelled or unavailable ($($_.Exception.Message)). Running user-level fallback..."
            Invoke-UserFallbackToolchain
        }
    }

    Update-SessionPath
    Install-VsCodeExtensionsAndSettings
    Initialize-MiseAndGuardrails

    $ensureDockerScript = Join-Path $RepoRoot "scripts\ensure-docker.ps1"
        if (Test-Path -LiteralPath $ensureDockerScript) {
            $prevPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ensureDockerScript -TimeoutSeconds $(if ($SkipContainerStart) { 5 } else { 120 })
                $dockerReadyCode = $LASTEXITCODE
                if (-not $SkipContainerStart -and $dockerReadyCode -eq 0) {
                    $taskCmd = Get-Command task.exe -ErrorAction SilentlyContinue
                    if ($taskCmd) {
                        Push-Location $RepoRoot
                        try {
                            Write-StatusLog "[Task] Building and starting tp-linux container via 'task up'..." Cyan
                            & $taskCmd.Source up
                        }
                        finally {
                            Pop-Location
                        }
                    }
                }
                elseif ($dockerReadyCode -eq 2) {
                    $runOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
                    if (Test-Path -LiteralPath $runOnceKey) {
                        Set-ItemProperty -Path $runOnceKey -Name "TP-Linux-PostReboot" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ErrorAction SilentlyContinue
                    }
                }
                $ErrorActionPreference = $prevPref
            }

            Write-Host ""
            Write-Host "=============================================================================" -ForegroundColor Green
            Write-Host " TP Linux Windows 11 Setup Complete!" -ForegroundColor Green
            Write-Host " -> Open this folder in VS Code and click 'Reopen in Container' (Dev Containers)." -ForegroundColor Green
            Write-Host " -> Open 'tp.ipynb' (Bash kernel ready) and press Ctrl+J for Fish shell." -ForegroundColor Green
            Write-Host "=============================================================================" -ForegroundColor Green
