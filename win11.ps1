#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows System Configuration Setup Script
.DESCRIPTION
    Exported from: WS151
    Source OS:     Windows 10 Pro 25H2 (Build 26200.7840)
    CPU:           2x Intel Xeon E5-2620 v4 @ 2.10GHz (12C/12T)
    RAM:           32 GB
    Export Date:   2026-02-13
#>

param(
    [switch]$DryRun,        # Preview only, no actual installation
    [switch]$SkipPrefetch,  # Skip parallel prefetch of installers
    [int]$MaxDownloadJobs = 3
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference = "None"
$PSDefaultParameterValues["*:Confirm"] = $false
if ($MaxDownloadJobs -lt 1) { $MaxDownloadJobs = 1 }
$script:WingetInstalledCache = @{}
$script:UseOfflineInstall = $false
$script:UseDownloadDir = $false
$script:WingetDownloadDir = Join-Path $env:ProgramData "WinGet\\Downloads"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "DWord"
    )
    if ($DryRun) {
        Write-Host "  [DRY RUN] $Path\$Name = $Value" -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    try {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -ErrorAction SilentlyContinue
    }
    Write-Host "  [SET] $Name = $Value" -ForegroundColor Green
}

function Test-WingetInstalled {
    param(
        [string]$WingetId,
        [string]$QueryName
    )

    if (-not $WingetId -and -not $QueryName) { return $false }

    $key = if ($WingetId) { "id:$WingetId" } else { "q:$QueryName" }
    if ($script:WingetInstalledCache.ContainsKey($key)) {
        return [bool]$script:WingetInstalledCache[$key]
    }

    $args = @("list", "--accept-source-agreements")
    if ($WingetId) {
        $args += @("--id", $WingetId, "-e")
    } else {
        $args += @($QueryName)
    }

    $output = & winget @args 2>$null
    if ($LASTEXITCODE -ne 0) {
        $args = @("list")
        if ($WingetId) {
            $args += @("--id", $WingetId, "-e")
        } else {
            $args += @($QueryName)
        }
        $output = & winget @args 2>$null
        if ($LASTEXITCODE -ne 0) {
            $script:WingetInstalledCache[$key] = $false
            return $false
        }
    }

    $pattern = if ($WingetId) { [regex]::Escape($WingetId) } else { [regex]::Escape($QueryName) }
    $found = $false
    foreach ($line in $output) {
        if ($line -match $pattern) {
            $found = $true
            break
        }
    }
    $script:WingetInstalledCache[$key] = $found
    return $found
}

function Test-WingetOfflineSupported {
    try {
        $help = & winget install --help 2>$null
        return ($help -match "--offline")
    } catch {
        return $false
    }
}

function Test-WingetInstallDownloadDirSupported {
    try {
        $help = & winget install --help 2>$null
        return ($help -match "--download-directory")
    } catch {
        return $false
    }
}

function Test-WingetAvailable {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function Test-WingetModuleAvailable {
    $mod = Get-Module -ListAvailable -Name Microsoft.WinGet.Client -ErrorAction SilentlyContinue
    return ($null -ne $mod)
}

function Test-WslNoLaunchSupported {
    try {
        $help = & wsl --help 2>$null
        return ($help -match "--no-launch")
    } catch {
        return $false
    }
}

function Test-WindowsOptionalFeatureEnabled {
    param([string]$FeatureName)
    $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    return ($f -and $f.State -eq "Enabled")
}

function Test-WslDistroInstalled {
    param([string]$DistroName)
    if (-not $DistroName) { return $false }
    $list = & wsl -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($line in $list) {
        if ($line.Trim() -eq $DistroName) { return $true }
    }
    return $false
}

function Install-IfMissing {
    param(
        [string]$Name,
        [string]$WingetId,
        [string]$ChocoId
    )
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would install: $Name ($WingetId)" -ForegroundColor Yellow
        return
    }
    if (-not $WingetId) {
        Write-Host "  [WARN] Missing WingetId for $Name; skip install" -ForegroundColor Yellow
        return
    }
    if ($WingetId -and (Test-WingetInstalled -WingetId $WingetId)) {
        Write-Host "  Already installed: $Name" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Installing: $Name ..." -ForegroundColor Green
    $baseArgs = @(
        "install",
        "--id", $WingetId,
        "-e",
        "--source", "winget",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent",
        "--disable-interactivity"
    )

    if ($script:UseOfflineInstall) {
        $offlineArgs = $baseArgs + @("--offline")
        if ($script:UseDownloadDir) {
            $offlineArgs += @("--download-directory", $script:WingetDownloadDir)
        }
        & winget @offlineArgs
        if ($LASTEXITCODE -eq 0) { return }
        Write-Host "  [WARN] Offline install failed; retrying online..." -ForegroundColor Yellow
    }

    & winget @baseArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] $Name install failed (exit $LASTEXITCODE). Continuing..." -ForegroundColor Yellow
    }
}

function Uninstall-WingetPackage {
    param(
        [string]$Name,
        [string]$WingetId,
        [string]$QueryName
    )
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would uninstall: $Name" -ForegroundColor Yellow
        return
    }
    if ($WingetId -and -not (Test-WingetInstalled -WingetId $WingetId)) {
        Write-Host "  Not installed: $Name" -ForegroundColor DarkGray
        return
    }
    if (-not $WingetId -and $QueryName -and -not (Test-WingetInstalled -QueryName $QueryName)) {
        Write-Host "  Not installed: $Name" -ForegroundColor DarkGray
        return
    }

    $args = @(
        "uninstall"
    )
    if ($WingetId) {
        $args += @("--id", $WingetId, "-e")
    } elseif ($QueryName) {
        $args += @($QueryName)
    } else {
        return
    }
    $args += @(
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent",
        "--disable-interactivity"
    )

    & winget @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] $Name uninstall failed (exit $LASTEXITCODE). Continuing..." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Uninstalled: $Name" -ForegroundColor Green
        if ($WingetId) { $script:WingetInstalledCache["id:$WingetId"] = $false }
        if ($QueryName) { $script:WingetInstalledCache["q:$QueryName"] = $false }
    }
}

function Remove-AppxPackages {
    param([string[]]$Patterns)

    if (-not $Patterns -or $Patterns.Count -eq 0) { return }

    foreach ($pattern in $Patterns) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would remove Appx packages matching: $pattern" -ForegroundColor Yellow
            continue
        }

        $pkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern -or $_.PackageFamilyName -like $pattern }
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                Write-Host "  [SET] Removed Appx: $($pkg.Name)" -ForegroundColor Green
            } catch {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue
                    Write-Host "  [SET] Removed Appx (current user): $($pkg.Name)" -ForegroundColor Green
                } catch {
                    Write-Host "  [WARN] Failed to remove Appx: $($pkg.Name)" -ForegroundColor Yellow
                }
            }
        }

        $provPkgs = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern -or $_.PackageName -like $pattern }
        foreach ($p in $provPkgs) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Write-Host "  [SET] Removed provisioned Appx: $($p.DisplayName)" -ForegroundColor Green
            } catch {
                Write-Host "  [WARN] Failed to remove provisioned Appx: $($p.DisplayName)" -ForegroundColor Yellow
            }
        }
    }
}

function Remove-RunEntriesByPattern {
    param(
        [string]$Path,
        [string[]]$Patterns
    )

    if (-not (Test-Path $Path)) { return }
    if (-not $Patterns -or $Patterns.Count -eq 0) { return }

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if (-not $item) { return }

    foreach ($prop in $item.PSObject.Properties) {
        foreach ($pat in $Patterns) {
            if ($prop.Name -match $pat) {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would remove startup entry: $($prop.Name) ($Path)" -ForegroundColor Yellow
                } else {
                    Remove-ItemProperty -Path $Path -Name $prop.Name -Force -ErrorAction SilentlyContinue
                    Write-Host "  [SET] Removed startup entry: $($prop.Name)" -ForegroundColor Green
                }
            }
        }
    }
}

function Set-RandomSolidColorBackground {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would set random solid-color background" -ForegroundColor Yellow
        return
    }

    $r = Get-Random -Minimum 0 -Maximum 256
    $g = Get-Random -Minimum 0 -Maximum 256
    $b = Get-Random -Minimum 0 -Maximum 256

    $colorKey = "HKCU:\Control Panel\Colors"
    Set-RegValue -Path $colorKey -Name "Background" -Value "$r $g $b" -Type String

    $desktopKey = "HKCU:\Control Panel\Desktop"
    Set-RegValue -Path $desktopKey -Name "Wallpaper" -Value "" -Type String
    Set-RegValue -Path $desktopKey -Name "WallpaperStyle" -Value "0" -Type String
    Set-RegValue -Path $desktopKey -Name "TileWallpaper"  -Value "0" -Type String

    try {
        Remove-ItemProperty -Path $desktopKey -Name "TranscodedImageCache" -ErrorAction SilentlyContinue
        Get-ItemProperty -Path $desktopKey -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty PSObject |
            Where-Object { $_.Name -like "TranscodedImageCache*" } |
            ForEach-Object { Remove-ItemProperty -Path $desktopKey -Name $_.Name -ErrorAction SilentlyContinue }
    } catch { }

    try {
        Start-Process -FilePath "RUNDLL32.EXE" -ArgumentList "USER32.DLL,UpdatePerUserSystemParameters" -NoNewWindow | Out-Null
    } catch { }

    Write-Host "  [SET] Background color RGB($r,$g,$b)" -ForegroundColor Green
}

function Disable-OptionalFeatureIfPresent {
    param([string]$FeatureName)

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would disable optional feature: $FeatureName" -ForegroundColor Yellow
        return $true
    }

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if (-not $feature) { return $false }

    if ($feature.State -eq "Enabled") {
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop | Out-Null
            Write-Host "  [SET] Disabled feature: $FeatureName" -ForegroundColor Green
        } catch {
            Write-Host "  [WARN] Failed to disable feature: $FeatureName" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Already disabled: $FeatureName" -ForegroundColor DarkGray
    }

    return $true
}

function Test-WingetDownloadSupported {
    try {
        $null = & winget download --help 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Start-WingetDownloadJobs {
    param(
        [array]$Packages,
        [string]$DownloadDir,
        [int]$MaxParallel = 3
    )

    if (-not $Packages -or $Packages.Count -eq 0) { return }
    if ($MaxParallel -lt 1) { $MaxParallel = 1 }

    $queue = New-Object System.Collections.Queue
    foreach ($pkg in $Packages) { [void]$queue.Enqueue($pkg) }

    $running = @()
    $ok = 0
    $fail = 0
    $logDir = Join-Path $DownloadDir "_logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $MaxParallel) {
            $pkg = $queue.Dequeue()
            $id = $pkg.WingetId
            $name = $pkg.Name
            Write-Host "  Downloading: $name ($id)" -ForegroundColor DarkGray
            $safeId = ($id -replace "[^A-Za-z0-9._-]", "_")
            $logPath = Join-Path $logDir "$safeId.log"
            $args = @(
                "download",
                "--id", $id,
                "-e",
                "--source", "winget",
                "--download-directory", $DownloadDir,
                "--accept-source-agreements",
                "--accept-package-agreements",
                "--silent",
                "--disable-interactivity"
            )
            $proc = Start-Process -FilePath "winget" -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $logPath
            $running += [pscustomobject]@{ Proc = $proc; Id = $id; Log = $logPath }
        }

        if ($running.Count -eq 0) { break }
        try {
            Wait-Process -Id ($running.Proc.Id) -Any -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Start-Sleep -Milliseconds 300
        }

        $still = @()
        foreach ($r in $running) {
            if ($r.Proc.HasExited) {
                $exit = $r.Proc.ExitCode
                if ($exit -ne 0) {
                    $fail++
                    Write-Host "  [WARN] Download failed for $($r.Id) (exit $exit). Log: $($r.Log)" -ForegroundColor Yellow
                } else {
                    $ok++
                    Write-Host "  [OK] Downloaded $($r.Id)" -ForegroundColor DarkGray
                }
            } else {
                $still += $r
            }
        }
        $running = $still
    }

    Write-Host "  Prefetch complete: $ok ok, $fail failed" -ForegroundColor DarkGray
}

# ============================================================
# 1. Bootstrap WinGet
# ============================================================
Write-Step "Bootstrapping WinGet"

if (-not $DryRun) {
    if (Test-WingetAvailable) {
        Write-Host "  WinGet already available; skipping bootstrap" -ForegroundColor DarkGray
    } else {
        $progressPreference = 'silentlyContinue'
        Write-Host "  Trusting PSGallery to avoid prompts ..."
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Write-Host "  Installing WinGet PowerShell module from PSGallery ..."
        Install-PackageProvider -Name NuGet -Force | Out-Null
        if (-not (Test-WingetModuleAvailable)) {
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
        }
        Write-Host "  Using Repair-WinGetPackageManager to bootstrap WinGet ..."
        Repair-WinGetPackageManager -AllUsers
        Write-Host "  [OK] WinGet ready" -ForegroundColor Green
    }
} else {
    Write-Host "  [DRY RUN] Would bootstrap WinGet via PSGallery module" -ForegroundColor Yellow
}

# ============================================================
# 2. Prefetch Installers (Parallel Download)
# ============================================================
$apps = @(
    @{ Name = "Git";                          WingetId = "Git.Git" },
    @{ Name = "Google Chrome";                WingetId = "Google.Chrome" },
    @{ Name = "Mozilla Firefox";              WingetId = "Mozilla.Firefox" },
    @{ Name = "Node.js (v24.x)";              WingetId = "OpenJS.NodeJS" },
    @{ Name = "Visual Studio Community 2022"; WingetId = "Microsoft.VisualStudio.2022.Community" }
)

$dotnetPkgs = @(
    @{ Name = ".NET SDK 9.0";              WingetId = "Microsoft.DotNet.SDK.9" },
    @{ Name = ".NET Runtime 8.0";          WingetId = "Microsoft.DotNet.Runtime.8" },
    @{ Name = ".NET Desktop Runtime 8.0";  WingetId = "Microsoft.DotNet.DesktopRuntime.8" },
    @{ Name = ".NET Desktop Runtime 9.0";  WingetId = "Microsoft.DotNet.DesktopRuntime.9" },
    @{ Name = "ASP.NET Core Runtime 8.0";  WingetId = "Microsoft.DotNet.AspNetCore.8" },
    @{ Name = "ASP.NET Core Runtime 9.0";  WingetId = "Microsoft.DotNet.AspNetCore.9" }
)

$vcRedistPkgs = @(
    @{ Name = "VC++ 2015-2022 Redist (x64)"; WingetId = "Microsoft.VCRedist.2015+.x64" },
    @{ Name = "VC++ 2015-2022 Redist (x86)"; WingetId = "Microsoft.VCRedist.2015+.x86" }
)

$winSdkPkgs = @(
    @{ Name = "Windows SDK 10.0.26100"; WingetId = "Microsoft.WindowsSDK.10.0.26100" }
)

Write-Step "Prefetching installers (parallel download)"

if ($DryRun) {
    Write-Host "  [DRY RUN] Would prefetch installers in parallel (max $MaxDownloadJobs)" -ForegroundColor Yellow
} elseif ($SkipPrefetch) {
    Write-Host "  [SKIP] Prefetch disabled via -SkipPrefetch" -ForegroundColor DarkGray
} elseif (-not (Test-WingetDownloadSupported)) {
    Write-Host "  [SKIP] winget download not supported; skipping prefetch" -ForegroundColor DarkGray
} else {
    $offlineSupported = Test-WingetOfflineSupported
    $downloadDirSupported = Test-WingetInstallDownloadDirSupported
    if (-not $offlineSupported) {
        Write-Host "  [SKIP] Offline install not supported; skipping prefetch to avoid redownload" -ForegroundColor DarkGray
    } elseif (-not $downloadDirSupported) {
        Write-Host "  [SKIP] Install does not support --download-directory; skipping prefetch" -ForegroundColor DarkGray
    } else {
        New-Item -ItemType Directory -Path $script:WingetDownloadDir -Force | Out-Null
        $prefetchPkgs = @()
        $allPkgs = @()
        $allPkgs += $apps
        $allPkgs += $dotnetPkgs
        $allPkgs += $vcRedistPkgs
        $allPkgs += $winSdkPkgs
        foreach ($pkg in $allPkgs) {
            if (Test-WingetInstalled -WingetId $pkg.WingetId) {
                Write-Host "  Skip prefetch: $($pkg.Name) (already installed)" -ForegroundColor DarkGray
            } else {
                $prefetchPkgs += $pkg
            }
        }
        if ($prefetchPkgs.Count -gt 0) {
            Start-WingetDownloadJobs -Packages $prefetchPkgs -DownloadDir $script:WingetDownloadDir -MaxParallel $MaxDownloadJobs
            $script:UseOfflineInstall = $true
            $script:UseDownloadDir = $true
            Write-Host "  Offline install enabled (prefetch cache)" -ForegroundColor DarkGray
        } else {
            Write-Host "  [SKIP] All packages already installed; no prefetch needed" -ForegroundColor DarkGray
        }
    }
}

# ============================================================
# 3. Core Applications
# ============================================================
Write-Step "Installing core applications"

# Remove Windows Widgets
Write-Host "  Removing Windows Widgets ..."
Uninstall-WingetPackage -Name "Windows Web Experience Pack (Widgets)" -WingetId "Microsoft.WindowsWebExperiencePack" -QueryName "Windows Web Experience Pack"

foreach ($app in $apps) {
    Install-IfMissing -Name $app.Name -WingetId $app.WingetId -ChocoId $app.ChocoId
}

# ============================================================
# 4. .NET SDKs & Runtimes
# ============================================================
Write-Step "Installing .NET SDKs and Runtimes"

foreach ($pkg in $dotnetPkgs) {
    Install-IfMissing -Name $pkg.Name -WingetId $pkg.WingetId -ChocoId $pkg.ChocoId
}

# ============================================================
# 5. Visual C++ Redistributables
# ============================================================
Write-Step "Installing Visual C++ Redistributables"

foreach ($pkg in $vcRedistPkgs) {
    Install-IfMissing -Name $pkg.Name -WingetId $pkg.WingetId -ChocoId $pkg.ChocoId
}

# ============================================================
# 6. Windows SDK
# ============================================================
Write-Step "Installing Windows SDK"

foreach ($pkg in $winSdkPkgs) {
    Install-IfMissing -Name $pkg.Name -WingetId $pkg.WingetId -ChocoId $pkg.ChocoId
}

function Disable-AllPageFiles {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would disable all paging files" -ForegroundColor Yellow
        return
    }

    $mmKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    if (-not (Test-Path $mmKey)) {
        New-Item -Path $mmKey -Force | Out-Null
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } | Out-Null
        }
    } catch {
        Write-Host "  [WARN] Failed to disable automatic pagefile management" -ForegroundColor Yellow
    }

    try {
        $pfs = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pfs) { $pfs | Remove-CimInstance -ErrorAction SilentlyContinue }
    } catch {
        Write-Host "  [WARN] Failed to remove pagefile settings" -ForegroundColor Yellow
    }

    try {
        Set-RegValue -Path $mmKey -Name "PagingFiles" -Value @("") -Type MultiString
        Set-RegValue -Path $mmKey -Name "ExistingPageFiles" -Value @("") -Type MultiString
        Set-RegValue -Path $mmKey -Name "TempPageFile" -Value 0
    } catch {
        Write-Host "  [WARN] Failed to update registry pagefile values" -ForegroundColor Yellow
    }

    Write-Host "  [SET] All paging files disabled (reboot required)" -ForegroundColor Green
}

# ============================================================
# 7. WSL (Windows Subsystem for Linux)
# ============================================================
Write-Step "Configuring WSL"

if ($DryRun) {
    Write-Host "  [DRY RUN] Would enable WSL2 and install Ubuntu (if missing)" -ForegroundColor Yellow
} else {
    $needWslFeature = -not (Test-WindowsOptionalFeatureEnabled -FeatureName "Microsoft-Windows-Subsystem-Linux")
    $needVmFeature = -not (Test-WindowsOptionalFeatureEnabled -FeatureName "VirtualMachinePlatform")

    if ($needWslFeature -or $needVmFeature) {
        wsl --install --no-distribution 2>$null
    } else {
        Write-Host "  WSL features already enabled" -ForegroundColor DarkGray
    }

    $hasUbuntu = Test-WslDistroInstalled -DistroName "Ubuntu"
    if (-not $hasUbuntu) {
        $wslArgs = @("--install", "-d", "Ubuntu")
        if (Test-WslNoLaunchSupported) {
            $wslArgs += "--no-launch"
        }
        & wsl @wslArgs 2>$null
    } else {
        Write-Host "  Ubuntu already installed" -ForegroundColor DarkGray
    }

    if (Test-WslDistroInstalled -DistroName "Ubuntu") {
        wsl --set-default Ubuntu
        wsl --set-default-version 2
    }
}

# ============================================================
# 8. Remove Microsoft 365 / Copilot / PC Manager / Edge / Solitaire
# ============================================================
Write-Step "Removing Microsoft 365, Copilot, PC Manager, Edge, Solitaire"

# Microsoft 365 / Office
$officeWingetIds = @(
    "Microsoft.Office",
    "Microsoft.Microsoft365",
    "Microsoft.MicrosoftOffice"
)
foreach ($id in $officeWingetIds) {
    Uninstall-WingetPackage -Name "Microsoft 365" -WingetId $id
}
Uninstall-WingetPackage -Name "Microsoft 365" -QueryName "Microsoft 365"

$officeAppxPatterns = @(
    "Microsoft.MicrosoftOfficeHub",
    "Microsoft.Office.Desktop",
    "Microsoft.Office.Word",
    "Microsoft.Office.Excel",
    "Microsoft.Office.PowerPoint",
    "Microsoft.Office.Outlook",
    "Microsoft.Office.OneNote",
    "Microsoft.Office.Sway"
)
Remove-AppxPackages -Patterns $officeAppxPatterns

# Microsoft PC Manager
$pcManagerWingetIds = @(
    "Microsoft.MicrosoftPCManager",
    "Microsoft.PCManager"
)
foreach ($id in $pcManagerWingetIds) {
    Uninstall-WingetPackage -Name "Microsoft PC Manager" -WingetId $id
}
Uninstall-WingetPackage -Name "Microsoft PC Manager" -QueryName "Microsoft PC Manager"

$pcManagerAppxPatterns = @(
    "Microsoft.MicrosoftPCManager",
    "Microsoft.PCManager",
    "*PCManager*"
)
Remove-AppxPackages -Patterns $pcManagerAppxPatterns

# Copilot (policy + taskbar button + app packages)
$copilotPolicyKey = "HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot"
Set-RegValue -Path $copilotPolicyKey -Name "TurnOffWindowsCopilot" -Value 1
$copilotPolicyUserKey = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"
Set-RegValue -Path $copilotPolicyUserKey -Name "TurnOffWindowsCopilot" -Value 1

$copilotUiKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Set-RegValue -Path $copilotUiKey -Name "ShowCopilotButton" -Value 0
Set-RegValue -Path $copilotUiKey -Name "TaskbarCopilot"    -Value 0

$copilotWingetIds = @(
    "Microsoft.Copilot",
    "Microsoft.Windows.Copilot",
    "Microsoft.WindowsCopilot"
)
foreach ($id in $copilotWingetIds) {
    Uninstall-WingetPackage -Name "Copilot" -WingetId $id
}
Uninstall-WingetPackage -Name "Copilot" -QueryName "Copilot"

$copilotAppxPatterns = @(
    "Microsoft.Copilot",
    "Microsoft.Windows.Copilot",
    "Microsoft.WindowsCopilot",
    "Microsoft.BingChat"
)
Remove-AppxPackages -Patterns $copilotAppxPatterns

# Remove Copilot/PC Manager auto-start entries
$startupPatterns = @(
    "Copilot",
    "PCManager",
    "MicrosoftPCManager"
)
Remove-RunEntriesByPattern -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Patterns $startupPatterns
Remove-RunEntriesByPattern -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Patterns $startupPatterns

# Edge
Uninstall-WingetPackage -Name "Microsoft Edge" -WingetId "Microsoft.Edge"
Uninstall-WingetPackage -Name "Microsoft Edge" -WingetId "Microsoft.Edge.Stable"
if (-not $DryRun) {
    $edgeBase = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application"
    if (Test-Path $edgeBase) {
        $setup = Get-ChildItem -Path $edgeBase -Filter setup.exe -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($setup) {
            & $setup.FullName --uninstall --system-level --force-uninstall --verbose-logging --msedge | Out-Null
        }
    }
}

# Solitaire (Microsoft Solitaire Collection)
Remove-AppxPackages -Patterns @("Microsoft.MicrosoftSolitaireCollection")

# ============================================================
# 9. Windows Features - Disable Media Features
# ============================================================
Write-Step "Disabling Media Features"

$mediaFeatureNames = @(
    "WindowsMediaPlayer",
    "MediaPlayback"
)

$foundMedia = $false
foreach ($name in $mediaFeatureNames) {
    if (Disable-OptionalFeatureIfPresent -FeatureName $name) {
        $foundMedia = $true
    }
}

if (-not $DryRun -and -not $foundMedia) {
    Write-Host "  [SKIP] Media Features not found" -ForegroundColor DarkGray
}

# ============================================================
# 10. Enable Remote Desktop
# ============================================================
Write-Step "Enabling Remote Desktop"

if ($DryRun) {
    Write-Host "  [DRY RUN] Would enable Remote Desktop and firewall rules" -ForegroundColor Yellow
} else {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
    $rdpRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match "Remote Desktop" -or $_.Group -match "RemoteDesktop" }
    if ($rdpRules) {
        $rdpRules | Enable-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "  [SET] Remote Desktop enabled" -ForegroundColor Green
}

# ============================================================
# 11. User Settings - Theme & Personalization
# ============================================================
Write-Step "Applying theme and personalization"

$themeKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
# Light theme (apps + system)
Set-RegValue -Path $themeKey -Name "AppsUseLightTheme"    -Value 1
Set-RegValue -Path $themeKey -Name "SystemUsesLightTheme" -Value 1
# No accent color on title bars/start
Set-RegValue -Path $themeKey -Name "ColorPrevalence"      -Value 0
# Transparency effects enabled
Set-RegValue -Path $themeKey -Name "EnableTransparency"   -Value 1

# Wallpaper style: Fit (WallpaperStyle=10, TileWallpaper=0)
$desktopKey = "HKCU:\Control Panel\Desktop"
Set-RegValue -Path $desktopKey -Name "WallpaperStyle" -Value "10" -Type String
Set-RegValue -Path $desktopKey -Name "TileWallpaper"  -Value "0"  -Type String

# Window colorization
$dwmKey = "HKCU:\Software\Microsoft\Windows\DWM"
Set-RegValue -Path $dwmKey -Name "EnableWindowColorization" -Value 0
Set-RegValue -Path $dwmKey -Name "ColorizationColorBalance" -Value 89

# ============================================================
# Random solid-color background (built-in)
Set-RandomSolidColorBackground

# ============================================================
# 12. User Settings - Desktop Icons
# ============================================================
Write-Step "Configuring desktop icons"

$iconKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
# 0 = Show, 1 = Hide
# Recycle Bin - Show
Set-RegValue -Path $iconKey -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 0
# This PC - Show
Set-RegValue -Path $iconKey -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0
# Network - Show
Set-RegValue -Path $iconKey -Name "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" -Value 0
# User folder - Show
Set-RegValue -Path $iconKey -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0
# Control Panel - Show
Set-RegValue -Path $iconKey -Name "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}" -Value 0
# OneDrive - Hide
Set-RegValue -Path $iconKey -Name "{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Value 1

# ============================================================
# 13. User Settings - Taskbar
# ============================================================
Write-Step "Configuring taskbar"

$taskbarKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
# Taskbar alignment: 0 = Left, 1 = Center
Set-RegValue -Path $taskbarKey -Name "TaskbarAl"          -Value 0
# Taskbar date/clock widget: 0 = Hide
Set-RegValue -Path $taskbarKey -Name "TaskbarDa"          -Value 0
# Small taskbar icons: 0 = Normal size
Set-RegValue -Path $taskbarKey -Name "TaskbarSmallIcons"   -Value 0
# Combine taskbar buttons: 0 = Always, 1 = When full, 2 = Never
Set-RegValue -Path $taskbarKey -Name "TaskbarGlomLevel"    -Value 1

# Search box mode: 0 = Hidden, 1 = Icon, 2 = Box, 3 = Icon+Label
$searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
Set-RegValue -Path $searchKey -Name "SearchboxTaskbarMode" -Value 3

# Disable "Search highlights"
$searchPolicyKey = "HKLM:\Software\Policies\Microsoft\Windows\Windows Search"
Set-RegValue -Path $searchPolicyKey -Name "AllowSearchHighlights" -Value 0
Set-RegValue -Path $searchPolicyKey -Name "EnableDynamicContentInWSB" -Value 0
$searchSettingsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
Set-RegValue -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -Value 0

# ============================================================
# 14. User Settings - Window Snapping
# ============================================================
Write-Step "Configuring window snapping"

# Disable "Show snap layouts when I drag a window to the top of my screen"
$snapKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Set-RegValue -Path $snapKey -Name "EnableSnapBar" -Value 0

# ============================================================
# 15. User Settings - Performance Options (Custom, font smoothing only)
# ============================================================
Write-Step "Configuring performance options"

$visualFxKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
Set-RegValue -Path $visualFxKey -Name "VisualFXSetting" -Value 3

$fxValues = @(
    "AnimateMinMax",
    "ComboBoxAnimation",
    "ControlAnimations",
    "CursorShadow",
    "DragFullWindows",
    "DropShadow",
    "ListviewAlphaSelect",
    "ListviewShadow",
    "MenuAnimation",
    "SelectionFade",
    "TaskbarAnimations",
    "TooltipAnimation",
    "TooltipFade",
    "TranslucentSelectionRectangle",
    "WindowAnimation"
)

foreach ($fx in $fxValues) {
    $fxPath = Join-Path $visualFxKey $fx
    Set-RegValue -Path $fxPath -Name "Value" -Value 0
}

# Keep "Smooth edges of screen fonts"
$desktopKey = "HKCU:\Control Panel\Desktop"
Set-RegValue -Path $desktopKey -Name "FontSmoothing" -Value "2" -Type String
Set-RegValue -Path $desktopKey -Name "FontSmoothingType" -Value 2
Set-RegValue -Path $desktopKey -Name "FontSmoothingGamma" -Value 1500

# Additional effect toggles (best-effort)
Set-RegValue -Path $desktopKey -Name "DragFullWindows" -Value "0" -Type String
Set-RegValue -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String
Set-RegValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAnimations" -Value 0
Set-RegValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewAlphaSelect" -Value 0
Set-RegValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewShadow" -Value 0

# ============================================================
# 16. System - Virtual Memory
# ============================================================
Write-Step "Disabling virtual memory (pagefile)"

Disable-AllPageFiles

# ============================================================
# 17. User Settings - Start Menu
# ============================================================
Write-Step "Configuring Start Menu"

$startKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"
# Disable "Show frequently used apps"
Set-RegValue -Path $startKey -Name "ShowFrequentList" -Value 0

# ============================================================
# 18. User Settings - File Explorer
# ============================================================
Write-Step "Configuring File Explorer"

$explorerKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
# Show file extensions
Set-RegValue -Path $explorerKey -Name "HideFileExt"     -Value 0
# Show hidden files (1 = Show, 2 = Hide)
Set-RegValue -Path $explorerKey -Name "Hidden"          -Value 1
# Hide protected OS files
Set-RegValue -Path $explorerKey -Name "ShowSuperHidden" -Value 0
# Don't use separate process for folders
Set-RegValue -Path $explorerKey -Name "SeparateProcess" -Value 0

# ============================================================
# 19. User Settings - Input & Regional
# ============================================================
Write-Step "Configuring regional and input settings"

# Timezone: China Standard Time (UTC+08:00)
if (-not $DryRun) {
    Set-TimeZone -Id "China Standard Time"
    Write-Host "  [SET] Timezone = China Standard Time (UTC+08:00)" -ForegroundColor Green
} else {
    Write-Host "  [DRY RUN] Would set timezone to China Standard Time" -ForegroundColor Yellow
}

# Locale: zh-CN
$intlKey = "HKCU:\Control Panel\International"
Set-RegValue -Path $intlKey -Name "LocaleName"  -Value "zh-CN"  -Type String
Set-RegValue -Path $intlKey -Name "sLanguage"   -Value "CHS"    -Type String
Set-RegValue -Path $intlKey -Name "sShortDate"  -Value "yyyy/M/d" -Type String
Set-RegValue -Path $intlKey -Name "sTimeFormat" -Value "H:mm:ss"  -Type String

# Keyboard: speed max, delay normal
$kbKey = "HKCU:\Control Panel\Keyboard"
Set-RegValue -Path $kbKey -Name "KeyboardDelay" -Value "1" -Type String
Set-RegValue -Path $kbKey -Name "KeyboardSpeed" -Value "31" -Type String

# Mouse: default settings, no swap
$mouseKey = "HKCU:\Control Panel\Mouse"
Set-RegValue -Path $mouseKey -Name "MouseSpeed"      -Value "1"  -Type String
Set-RegValue -Path $mouseKey -Name "MouseThreshold1" -Value "6"  -Type String
Set-RegValue -Path $mouseKey -Name "MouseThreshold2" -Value "10" -Type String
Set-RegValue -Path $mouseKey -Name "SwapMouseButtons" -Value "0" -Type String
Set-RegValue -Path $mouseKey -Name "MouseSensitivity" -Value "10" -Type String

# ============================================================
# 20. User Settings - Display
# ============================================================
Write-Step "Configuring display"

# DPI scaling = 200% (192 DPI)
Write-Host "  [INFO] Current DPI: 192 (200% scaling)" -ForegroundColor DarkGray
Write-Host "  [INFO] Display scaling must be set manually via Settings > Display" -ForegroundColor DarkGray

# ============================================================
# 21. User Settings - Privacy & Misc
# ============================================================
Write-Step "Configuring privacy settings"

# Disable tailored experiences with diagnostic data
$privacyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
Set-RegValue -Path $privacyKey -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0

# ============================================================
# 22. Power Plan
# ============================================================
Write-Step "Setting power plan"

if (-not $DryRun) {
    # Balanced plan GUID
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    Write-Host "  [SET] Power plan = Balanced" -ForegroundColor Green
} else {
    Write-Host "  [DRY RUN] Would set power plan to Balanced" -ForegroundColor Yellow
}

# ============================================================
# 23. Network - Prefer IPv4 over IPv6
# ============================================================
Write-Step "Setting IPv4 priority over IPv6"

if (-not $DryRun) {
    netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 60 4
    Write-Host "  [SET] IPv4 preferred (prefix policy ::ffff:0:0/96 priority 60 label 4)" -ForegroundColor Green
} else {
    Write-Host "  [DRY RUN] Would set IPv4 priority via netsh prefix policy" -ForegroundColor Yellow
}

# ============================================================
# 24. Network Configuration (Reference Only)
# ============================================================
Write-Step "Network Configuration (Reference Only)"

Write-Host @"
  NOTE: Network settings are environment-specific and not auto-applied.
  Current configuration for reference:

  Adapter:     Intel 82574L Gigabit Network Connection
  IPv4:        192.168.213.151
  Gateway:     192.168.213.1
  DNS:         82.156.176.197, 114.114.114.114
  IPv6:        240e:604:203:e00:213::151
"@ -ForegroundColor DarkGray

# ============================================================
# 25. System PATH
# ============================================================
Write-Step "Verifying System PATH entries"

$requiredPaths = @(
    "C:\Program Files\nodejs\",
    "C:\Program Files\dotnet\",
    "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\"
)

$currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
foreach ($p in $requiredPaths) {
    if ($currentPath -notlike "*$p*") {
        if (-not $DryRun) {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$p", "Machine")
            $currentPath = "$currentPath;$p"
            Write-Host "  Added to PATH: $p" -ForegroundColor Green
        } else {
            Write-Host "  [DRY RUN] Would add to PATH: $p" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Already in PATH: $p" -ForegroundColor DarkGray
    }
}

$userPaths = @(
    "$env:USERPROFILE\AppData\Roaming\npm",
    "$env:USERPROFILE\.dotnet\tools"
)

$currentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
foreach ($p in $userPaths) {
    if ($currentUserPath -notlike "*$p*") {
        if (-not $DryRun) {
            [Environment]::SetEnvironmentVariable("PATH", "$currentUserPath;$p", "User")
            $currentUserPath = "$currentUserPath;$p"
            Write-Host "  Added to User PATH: $p" -ForegroundColor Green
        } else {
            Write-Host "  [DRY RUN] Would add to User PATH: $p" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Already in User PATH: $p" -ForegroundColor DarkGray
    }
}

# ============================================================
# 26. Key Services Verification
# ============================================================
Write-Step "Verifying key services"

$criticalServices = @(
    "WSLService",
    "WSearch",
    "WinDefend",
    "Dnscache",
    "Dhcp",
    "EventLog",
    "mpssvc"
)

foreach ($svc in $criticalServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        if ($s.Status -ne 'Running') {
            Write-Host "  [WARN] $svc ($($s.DisplayName)) is $($s.Status)" -ForegroundColor Yellow
            if (-not $DryRun) {
                Start-Service -Name $svc -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "  [OK]   $svc" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [MISS] $svc not found" -ForegroundColor Red
    }
}

# ============================================================
# 27. Restart Explorer to apply UI changes
# ============================================================
Write-Step "Applying UI changes"

if (-not $DryRun) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer
    Write-Host "  Explorer restarted to apply settings" -ForegroundColor Green
} else {
    Write-Host "  [DRY RUN] Would restart Explorer to apply UI changes" -ForegroundColor Yellow
}

# ============================================================
# Done
# ============================================================
Write-Host "`n"
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Please reboot to apply all changes." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
