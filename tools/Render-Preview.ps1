<#
.SYNOPSIS
    Renders every page of the WinKit window to PNG files using live,
    read-only data from this PC. Used for README screenshots and for
    reviewing UI changes without clicking through the app.

.EXAMPLE
    powershell -STA -ExecutionPolicy Bypass -File .\tools\Render-Preview.ps1 -Output .\docs\screenshots
#>
[CmdletBinding()]
param(
    [string]$Output,
    [ValidateSet('Light', 'Dark', 'Both')][string]$Theme = 'Both',
    [int]$Width = 1280,
    [int]$Height = 820,
    [switch]$SkipNetwork,
    # Show the Administrator badge, as users see it after the UAC prompt.
    [switch]$AsAdmin,
    # Render with preview mode on, as users see it with the banner.
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Output) { $Output = Join-Path $repo 'docs\screenshots' }
if (-not (Test-Path -LiteralPath $Output)) { New-Item -ItemType Directory -Path $Output -Force | Out-Null }

$script:WKRoot = $repo
foreach ($folder in 'src\core', 'src\modules', 'src\ui', 'src\ui\Pages') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo $folder) -Filter '*.ps1' | Sort-Object Name) { . $file.FullName }
}

$script:WK = Initialize-WKContext -Preview:$Preview
# Keep the user's real history out of screenshots.
$WK.HistoryFile = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-preview-history-$([guid]::NewGuid()).json"
Add-WKHistoryEntry -Kind tweak -RefId 'privacy.advertising-id' -Title 'Disable advertising ID' -Changes @(
    [pscustomobject]@{ type = 'registry'; path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; name = 'Enabled'
                       before = [pscustomobject]@{ exists = $true; kind = 'DWord'; value = 1 }
                       after = [pscustomobject]@{ exists = $true; kind = 'DWord'; value = 0 }; createdKey = $null }) | Out-Null
Add-WKHistoryEntry -Kind dns -RefId 'dns' -Title 'DNS: Cloudflare' -Changes @(
    [pscustomobject]@{ type = 'dns'; interfaceIndex = 7; interfaceGuid = ''; alias = 'Ethernet'
                       before = [pscustomobject]@{ v4 = @(); v6 = @() }
                       after = [pscustomobject]@{ v4 = @('1.1.1.1', '1.0.0.1'); v6 = @() } }) | Out-Null

Write-Host 'Collecting live data (read-only)...'
$health = Get-WKHealthReport
$installed = @(Get-WKInstalledPackageIds)
$states = @(Get-WKAllTweakStates)
$dev = [pscustomobject]@{ Tools = @(Get-WKDevToolStatus); Git = Get-WKGitIdentity; Ssh = Get-WKSshKeyStatus; Wsl = Get-WKWslStatus }
$dns = @(Get-WKDnsOverview)
$latency = if ($SkipNetwork) { @() } else { @(Test-WKCloudLatency) }
$bench = if ($SkipNetwork) { @() } else { @(Test-WKDnsBenchmark) }

if ($AsAdmin) { $WK.IsAdmin = $true }
$window = New-WKWindow
$window.WindowStartupLocation = 'Manual'
$window.Left = -30000
$window.Top = -30000
$window.Width = $Width
$window.Height = $Height
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

# Mark pages as visited so switching pages does not start background tasks.
foreach ($k in $script:WKPages.Keys) { [void]$script:State.Visited.Add($k) }

function Save-WKFrame {
    param([string]$Name)
    $window.UpdateLayout()
    $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
    $root = $window.Content
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $path = Join-Path $Output "$Name.png"
    $fs = [System.IO.File]::Create($path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    Write-Host "  $path"
}

$window.Add_ContentRendered({
    try {
        Show-WKHealth -Report $health
        Set-WKInstalledApps -Ids $installed
        Show-WKTweakStates -States $states
        Show-WKDeveloperStatus -Status $dev
        Show-WKDnsOverview -Adapters $dns
        if ($latency.Count) { Show-WKLatency -Results $latency }
        $script:UI.StatusVersion.Text = "v$($WK.Version)"

        $themes = if ($Theme -eq 'Both') { 'Light', 'Dark' } else { @($Theme) }
        foreach ($t in $themes) {
            Set-WKTheme -Mode $t
            $suffix = $t.ToLowerInvariant()
            foreach ($page in 'overview', 'apps', 'developer', 'tweaks', 'network', 'history', 'settings') {
                Show-WKPage $page
                Save-WKFrame "$page-$suffix"
            }
            # A second frame further down for the longer pages.
            Show-WKPage 'tweaks'
            $script:UI.PageTweaks.Children[0].ScrollToVerticalOffset(520)
            Save-WKFrame "tweaks-scrolled-$suffix"
            $script:UI.PageTweaks.Children[0].ScrollToTop()
            Show-WKPage 'developer'
            $script:UI.PageDeveloper.ScrollToVerticalOffset(600)
            Save-WKFrame "developer-scrolled-$suffix"
            $script:UI.PageDeveloper.ScrollToTop()

            # Dialog and activity panel states.
            Show-WKPage 'overview'
            $script:UI.ActivityToggle.IsChecked = $true
            $script:UI.ActivityLog.Text = "10:41:02  Applying 'Disable advertising ID'`r`n10:41:02    HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled : 1 -> 0`r`n10:41:03  1 change(s) made, 0 failed"
            $script:UI.DlgTitle.Text = 'Apply 10 tweak(s)?'
            $script:UI.DlgMessage.Text = "WinKit will record the current value of every setting first, so each tweak can be undone later.`n`nA System Restore point is created first. This can take a minute."
            $script:UI.DlgButtons.Children.Clear()
            [void]$script:UI.DlgButtons.Children.Add((New-WKButton -Content 'Cancel' -Margin (New-WKThickness 8 0 0 0)))
            [void]$script:UI.DlgButtons.Children.Add((New-WKButton -Content 'Apply' -Style 'PrimaryBtn' -Margin (New-WKThickness 8 0 0 0)))
            $script:UI.DialogLayer.Visibility = 'Visible'
            Save-WKFrame "dialog-$suffix"
            $script:UI.DialogLayer.Visibility = 'Collapsed'
            $script:UI.ActivityToggle.IsChecked = $false
        }

        if ($bench.Count) {
            # Reuse the page code path for the benchmark list.
            $panel = $script:UI.NetDnsBenchList
            $panel.Children.Clear()
            $ok = @($bench | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
            $max = if ($ok.Count) { [double]($ok | Select-Object -Last 1).Ms } else { 1 }
            foreach ($r in $ok) { [void]$panel.Children.Add((New-WKBarRow -Title $r.Name -Ms $r.Ms -Max $max)) }
            Set-WKTheme -Mode Light
            Show-WKPage 'network'
            $script:UI.PageNetwork.ScrollToVerticalOffset(460)
            Save-WKFrame 'network-dns-light'
        }
    }
    catch {
        Write-Host "Render failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
    finally {
        $window.Close()
    }
})

[void]$window.ShowDialog()
Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'winkit-preview-history-*.json') -Force -ErrorAction SilentlyContinue
Write-Host 'Done.'
