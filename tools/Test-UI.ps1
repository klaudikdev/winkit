<#
.SYNOPSIS
    End-to-end UI test. Opens the real WinKit window, drives it the way a
    user would (navigation, buttons, dialogs, background tasks) and checks
    the results.

.DESCRIPTION
    Runs in preview mode with a throwaway data folder, so it never changes
    the PC: every action only reports what it would do. Dialogs are answered
    automatically.

        powershell -STA -ExecutionPolicy Bypass -File .\tools\Test-UI.ps1
#>
[CmdletBinding()]
param([switch]$Visible)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$script:WKRoot = $repo
foreach ($folder in 'src\core', 'src\modules', 'src\ui', 'src\ui\Pages') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo $folder) -Filter '*.ps1' | Sort-Object Name) { . $file.FullName }
}

$script:WK = Initialize-WKContext -Preview
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-uitest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
$WK.HistoryFile = Join-Path $tmp 'history.json'
$WK.SettingsFile = Join-Path $tmp 'settings.json'
$WK.LogFile = Join-Path $tmp 'test.log'

# The real dialog is kept so the dialog behaviour itself can be tested.
$script:RealDialog = (Get-Command Show-WKDialog).ScriptBlock

# Dialogs are answered from a queue; toasts are recorded.
$script:Answers = New-Object System.Collections.Generic.Queue[string]
$script:Dialogs = New-Object System.Collections.Generic.List[string]
$script:Toasts = New-Object System.Collections.Generic.List[string]
function Show-WKDialog {
    param([string]$Title, [string]$Message, [string[]]$Buttons = @('OK'), [string]$Primary, [string]$Danger, [string]$Cancel, [switch]$Action, [switch]$NoDefault)
    $script:Dialogs.Add($Title)
    if ($Action -and $WK.PreviewMode) { $script:PreviewNotes++ }
    if ($script:Answers.Count) { return $script:Answers.Dequeue() }
    return $Buttons[0]
}
function Show-WKToast {
    param([string]$Message, [string]$Kind = 'Success')
    $script:Toasts.Add("[$Kind] $Message")
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Name = $Name; Pass = $Condition; Detail = $Detail })
    $mark = if ($Condition) { 'PASS' } else { 'FAIL' }
    $color = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1} {2}" -f $mark, $Name, $(if (-not $Condition -and $Detail) { "($Detail)" } else { '' })) -ForegroundColor $color
}
function Click($Element) {
    $Element.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function Log { $script:UI.ActivityLog.Text }
function Get-Tile([string]$Id) { $script:State.AppTiles[$Id].Tile }

# Snapshot of real values that preview mode must leave untouched.
$adv = Get-WKRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'
$dnsBefore = (@(Get-WKDnsOverview) | ForEach-Object { Format-WKDnsSetting $_.Setting }) -join ';'

$window = New-WKWindow
if (-not $Visible) {
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -30000
    $window.Top = -30000
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
}
$script:SessionState = New-WKSessionState

# Each step runs once no task is running; it returns $true when done.
$script:Steps = @(
    @{ Name = 'Health scan'; Run = {
        Check 'health score is a number' ($script:UI.OvScore.Text -match '^\d+$') $script:UI.OvScore.Text
        Check 'health checks rendered' ($script:UI.OvChecks.Children.Count -ge 10)
        Check 'system info rendered' ($script:UI.OvInfoLeft.Children.Count -eq 3)
        Check 'save report enabled' $script:UI.OvExport.IsEnabled
        $true } }
    @{ Name = 'Open Apps'; Run = { $script:UI.NavApps.IsChecked = $true; $true } }
    @{ Name = 'Apps loaded'; Run = {
        Check 'Apps page visible' ($script:UI.PageApps.Visibility -eq 'Visible')
        Check 'installed apps detected' $script:State.InstalledLoaded
        $pills = @($script:State.AppTiles.Values | Where-Object { $_.Pill.Visibility -eq 'Visible' }).Count
        Check 'installed badges match' ($pills -eq @($script:State.AppTiles.Keys | Where-Object { $script:State.Installed.Contains($_) }).Count)
        $script:UI.AppsSearch.Text = 'chrome'
        $visible = @($script:State.AppTiles.Values | Where-Object { $_.Tile.Visibility -eq 'Visible' }).Count
        Check 'search filters tiles' ($visible -eq 1) "visible=$visible"
        $script:UI.AppsSearch.Text = ''
        foreach ($chip in $script:UI.AppsFilters.Children) { if ($chip.Tag -eq 'Cloud & DevOps') { $chip.IsChecked = $true } }
        $visible = @($script:State.AppTiles.Values | Where-Object { $_.Tile.Visibility -eq 'Visible' }).Count
        Check 'category filter' ($visible -eq @($WK.Config.Apps.apps | Where-Object { $_.category -eq 'Cloud & DevOps' }).Count) "visible=$visible"
        foreach ($chip in $script:UI.AppsFilters.Children) { if ($chip.Tag -eq 'All') { $chip.IsChecked = $true } }
        (Get-Tile 'Google.Chrome').IsChecked = $true
        (Get-Tile 'VideoLAN.VLC').IsChecked = $true
        Check 'selection counted' ($script:UI.AppsSelCount.Text -like '2 selected*') $script:UI.AppsSelCount.Text
        Check 'install enabled' $script:UI.AppsInstall.IsEnabled
        $script:Answers.Enqueue('Install')
        Click $script:UI.AppsInstall
        $true } }
    @{ Name = 'Install preview'; Run = {
        Check 'install dialog shown' ($script:Dialogs -contains 'Install 2 apps?')
        Check 'preview winget command logged' ((Log) -match '\[Preview\] winget install --id Google\.Chrome --exact --source winget')
        Check 'selection cleared after run' ($script:State.AppSelection.Count -eq 0)
        $true } }
    @{ Name = 'Export and import'; Run = {
        $file = Join-Path $tmp 'apps.json'
        Export-WKAppSelection -Ids @('Google.Chrome', 'Amazon.AWSCLI', 'Not.InCatalog') -Path $file
        $ids = @(Import-WKAppSelection -Path $file)
        Check 'export/import round trip (with I in the id)' ($ids -contains 'Amazon.AWSCLI' -and $ids.Count -eq 3) ($ids -join ',')
        $true } }
    @{ Name = 'Open Tweaks'; Run = { $script:UI.NavTweaks.IsChecked = $true; $true } }
    @{ Name = 'Tweaks loaded'; Run = {
        Check 'tweak states loaded' ($script:State.TweakStates.Count -eq @(Get-WKTweak).Count) "$($script:State.TweakStates.Count)"
        $essentials = $script:UI.TwProfiles.Children | Where-Object { $_.Tag -eq 'essentials' }
        Click $essentials
        Check 'profile selects tweaks' ($script:State.TweakSelection.Count -gt 0) "$($script:State.TweakSelection.Count)"
        foreach ($chip in $script:UI.TwFilters.Children) { if ($chip.Tag -eq 'gaming') { $chip.IsChecked = $true } }
        Check 'category filter hides others' ($script:State.TweakSections['privacy'].Visibility -eq 'Collapsed')
        foreach ($chip in $script:UI.TwFilters.Children) { if ($chip.Tag -eq 'all') { $chip.IsChecked = $true } }
        $script:Answers.Enqueue('Apply')
        Click $script:UI.TwApply
        $true } }
    @{ Name = 'Tweaks preview'; Run = {
        Check 'apply dialog shown' (@($script:Dialogs | Where-Object { $_ -like 'Apply * tweaks?' }).Count -eq 1)
        Check 'preview lists registry changes' ((Log) -match '\[Preview\] HKCU\\')
        Check 'preview finished message' ((Log) -match 'Preview finished, nothing was changed')
        $now = Get-WKRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'
        Check 'registry untouched in preview' ($now.Exists -eq $adv.Exists -and "$($now.Value)" -eq "$($adv.Value)")
        Check 'no history written in preview' (@(Get-WKHistory).Count -eq 0)
        $true } }
    @{ Name = 'Open Developer'; Run = { $script:UI.NavDeveloper.IsChecked = $true; $true } }
    @{ Name = 'Developer loaded'; Run = {
        Check 'toolchain chips' ($script:UI.DevTools.Children.Count -eq @($WK.Config.Developer.tools).Count)
        Check 'stack columns' ($script:UI.DevStacks.Children.Count -eq 4)
        Check 'developer tweak rows' ($script:UI.DevTweaks.Children.Count -gt 5)
        Check 'ssh status text' ([bool]$script:UI.DevSshStatus.Text)
        $true } }
    @{ Name = 'Open Network'; Run = { $script:UI.NavNetwork.IsChecked = $true; $true } }
    @{ Name = 'DNS loaded'; Run = {
        Check 'adapters listed' ($script:UI.NetDnsCurrent.Children.Count -ge 1)
        Click $script:UI.NetDnsBench
        $true } }
    @{ Name = 'DNS benchmark'; Run = {
        Check 'benchmark rows' ($script:UI.NetDnsBenchList.Children.Count -ge 3)
        $script:Answers.Enqueue('Switch')
        Click ($script:UI.NetDnsProviders.Children | Where-Object { $_.Tag -eq 'cloudflare' })
        $true } }
    @{ Name = 'DNS preview'; Run = {
        $after = (@(Get-WKDnsOverview) | ForEach-Object { Format-WKDnsSetting $_.Setting }) -join ';'
        Check 'DNS untouched in preview' ($after -eq $dnsBefore) "$dnsBefore -> $after"
        Check 'DNS preview logged' ((Log) -match '\[Preview\] DNS on ')
        Click $script:UI.NetLatencyRun
        $true } }
    @{ Name = 'Latency'; Run = {
        $rows = $script:UI.NetLatencyLeft.Children.Count + $script:UI.NetLatencyRight.Children.Count
        Check 'latency rows' ($rows -eq @($WK.Config.Network.latencyTargets).Count) "$rows"
        Check 'closest region shown' ($script:UI.NetBest.Visibility -eq 'Visible')
        $true } }
    @{ Name = 'Dialog behaviour'; Run = {
        # Escape must cancel, not confirm: these dialogs restart the PC or
        # delete things when the wrong button comes back.
        $escape = New-Object System.Windows.Threading.DispatcherTimer
        $escape.Interval = [TimeSpan]::FromMilliseconds(250)
        $escape.Add_Tick({
            $this.Stop()
            $source = [System.Windows.PresentationSource]::FromVisual($script:UI.Window)
            $args = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [System.Windows.Input.Key]::Escape)
            $args.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
            $script:UI.Window.RaiseEvent($args)
        })
        $escape.Start()
        $answer = & $script:RealDialog -Title 'Escape test' -Message 'Escape must cancel.' -Buttons 'Cancel', 'Restart now' -Primary 'Restart now'
        Check 'Escape cancels a dialog' ($answer -eq 'Cancel') "returned '$answer'"
        Check 'dialog closes after Escape' ($script:UI.DialogLayer.Visibility -eq 'Collapsed')
        Check 'page content is usable again' ($script:UI.MainArea.IsEnabled)

        # A second dialog opened while one is waiting, plus a close attempt.
        $script:NestedPhase = 0
        $script:NestedInner = $null
        $driver = New-Object System.Windows.Threading.DispatcherTimer
        $driver.Interval = [TimeSpan]::FromMilliseconds(200)
        $driver.Add_Tick({
            switch ($script:NestedPhase) {
                0 {
                    if ($script:UI.DlgTitle.Text -eq 'Outer') {
                        $script:NestedPhase = 1
                        Check 'closing is refused while a dialog waits' (-not $script:UI.Window.Close() -and $script:UI.Window.IsVisible)
                        [void]$script:UI.Window.Dispatcher.BeginInvoke([System.Action] {
                            $script:NestedInner = & $script:RealDialog -Title 'Inner' -Message 'Opened from a completion block.' -Buttons 'Close inner'
                        })
                    }
                }
                1 {
                    if ($script:UI.DlgTitle.Text -eq 'Inner') {
                        $script:NestedPhase = 2
                        Click $script:UI.DlgButtons.Children[0]
                    }
                }
                2 {
                    Check 'the first dialog comes back' ($script:UI.DlgTitle.Text -eq 'Outer') $script:UI.DlgTitle.Text
                    $script:NestedPhase = 3
                    $this.Stop()
                    Click $script:UI.DlgButtons.Children[0]
                }
            }
        })
        $driver.Start()
        $outer = & $script:RealDialog -Title 'Outer' -Message 'Waits for the inner dialog.' -Buttons 'Close outer'
        Check 'nested dialog returned' ($script:NestedInner -eq 'Close inner') "inner='$($script:NestedInner)'"
        Check 'outer dialog returned' ($outer -eq 'Close outer') "outer='$outer'"
        Check 'window still open after the close attempt' $script:UI.Window.IsVisible
        Check 'everything is enabled again' ($script:UI.MainArea.IsEnabled -and $script:UI.Sidebar.IsEnabled)
        $true } }
    @{ Name = 'History and settings'; Run = {
        $script:UI.NavHistory.IsChecked = $true
        Check 'empty history message' ($script:UI.HiEmpty.Visibility -eq 'Visible')
        $script:UI.NavSettings.IsChecked = $true
        $script:UI.SetThemeDark.IsChecked = $true
        $bg = $script:UI.Window.Resources['BgBrush'].Color.ToString()
        Check 'dark theme applied' ($bg -eq '#FF0C101B') $bg
        $script:UI.SetThemeLight.IsChecked = $true
        Check 'light theme applied' ($script:UI.Window.Resources['BgBrush'].Color.ToString() -eq '#FFF5F6FA')
        Check 'settings saved' ((Get-Content -LiteralPath $WK.SettingsFile -Raw) -match '"Theme":\s*"Light"')
        Check 'preview banner shown while previewing' ($script:UI.PreviewBanner.Visibility -eq 'Visible')
        Click $script:UI.PreviewBannerOff
        Check 'banner button turns preview off' (-not $WK.PreviewMode -and -not $script:UI.PreviewToggle.IsChecked)
        Check 'banner hidden when preview is off' ($script:UI.PreviewBanner.Visibility -eq 'Collapsed')
        $script:UI.PreviewToggle.IsChecked = $true
        Check 'banner back when preview is on' ($script:UI.PreviewBanner.Visibility -eq 'Visible')
        Check 'no Cleanup page left' (-not $script:UI.ContainsKey('PageCleanup') -and -not $script:UI.ContainsKey('NavCleanup'))
        Check 'no sidebar promo left' (-not $script:UI.ContainsKey('PromoButton'))
        Check 'no errors logged' (-not ((Log) -match '(?m)failed:|Could not update the view'))
        $true } }
)

$script:StepIndex = 0
$script:StepStarted = Get-Date
$runner = New-Object System.Windows.Threading.DispatcherTimer
$runner.Interval = [TimeSpan]::FromMilliseconds(300)
$runner.Add_Tick({
    if ($script:CurrentTask -or $script:TaskQueue.Count) {
        if (((Get-Date) - $script:StepStarted).TotalSeconds -gt 180) {
            Check "timeout waiting for '$($script:CurrentTask.Name)'" $false
            $script:StepIndex = $script:Steps.Count
        }
        else { return }
    }
    if ($script:StepIndex -ge $script:Steps.Count) {
        $this.Stop()
        $script:UI.Window.Close()
        return
    }
    $step = $script:Steps[$script:StepIndex]
    Write-Host $step.Name -ForegroundColor Cyan
    try { [void](& $step.Run) }
    catch { Check "$($step.Name) threw" $false $_.Exception.Message }
    $script:StepIndex++
    $script:StepStarted = Get-Date
})

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick({ Invoke-WKTick })
$script:Timer.Start()

$window.Add_ContentRendered({
    Write-Host 'First-start notice' -ForegroundColor Cyan
    # Declining closes the window; use a stand-in so the test window stays.
    $real = $script:UI.Window
    $script:UI.Window = New-Object System.Windows.Window
    $WK.Settings.TermsAccepted = $false
    $script:Answers.Enqueue('Quit')
    Check 'declining the notice closes WinKit' (-not (Confirm-WKTerms))
    Check 'declining is not remembered' (-not $WK.Settings.TermsAccepted)
    $script:UI.Window = $real
    $script:Answers.Enqueue('I understand and agree')
    Check 'accepting the notice continues' (Confirm-WKTerms)
    Check 'acceptance is saved' ((Get-Content -LiteralPath $WK.SettingsFile -Raw | ConvertFrom-Json).TermsAccepted -eq $true)
    $shown = $script:Dialogs.Count
    Check 'the notice is shown only once' ((Confirm-WKTerms) -and $script:Dialogs.Count -eq $shown)
    Update-WKHealth
    $runner.Start()
})
[void]$window.ShowDialog()

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($script:Toasts.Count) { Write-Host 'Toasts:' -ForegroundColor DarkGray; $script:Toasts | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
if ($failed.Count) { exit 1 }
