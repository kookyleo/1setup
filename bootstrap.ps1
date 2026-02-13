# Bootstrap launcher for win11.ps1 (download + execute)
# Usage:
#   irm https://raw.githubusercontent.com/<owner>/<repo>/<branch>/bootstrap.ps1 | iex
#
# For parameters, use:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $(irm https://raw.githubusercontent.com/<owner>/<repo>/<branch>/bootstrap.ps1) } -DryRun"

param(
    [string]$SourceUrl = "https://raw.githubusercontent.com/kookyleo/1setup/main/win11.ps1",
    [switch]$DryRun,
    [switch]$SkipPrefetch,
    [int]$MaxDownloadJobs = 3
)

try {
    # Ensure TLS 1.2 for older PowerShell
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    Write-Host "Downloading: $SourceUrl" -ForegroundColor Cyan
    $script = Invoke-RestMethod -Uri $SourceUrl -UseBasicParsing
} catch {
    Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $script) {
    Write-Host "Downloaded script is empty." -ForegroundColor Red
    exit 1
}

$sb = [ScriptBlock]::Create($script)
$args = @{}
if ($DryRun) { $args.DryRun = $true }
if ($SkipPrefetch) { $args.SkipPrefetch = $true }
if ($MaxDownloadJobs) { $args.MaxDownloadJobs = $MaxDownloadJobs }

& $sb @args
