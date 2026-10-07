# Window plumbing: background tasks, dialogs, toasts, theming and navigation.

#region Background tasks

function New-WKSessionState {
    <#
        Builds the initial session state for background runspaces: every
        WinKit function plus the shared context, so jobs call the same code
        the UI does.
    #>
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    foreach ($f in Get-ChildItem -Path function: | Where-Object { $_.Name -match '-WK' }) {
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.Definition)
        $iss.Commands.Add($entry)
    }
    $shared = @{
        WK             = $WK
        WKPowerSchemes = $script:WKPowerSchemes
        WKWingetCodes  = $script:WKWingetCodes
        WKWingetOk     = $script:WKWingetOk
        WKWingetRestart = $script:WKWingetRestart
        WKPrivilegedSids = $script:WKPrivilegedSids
        WKForbiddenUndoPaths = $script:WKForbiddenUndoPaths
        WKUndoRegistryRoots = $script:WKUndoRegistryRoots
        WKNativeSource = $script:WKNativeSource
        WKShellFlags   = $script:WKShellFlags
        WKSpiSettings  = $script:WKSpiSettings
    }
    foreach ($name in $shared.Keys) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($name, $shared[$name], '')))
    }
    return $iss
}

function Start-WKTask {
    <#
        Runs $Script in a background runspace. When it finishes, $OnDone runs
        on the UI thread with the script's output, or $OnFail if it threw.
        Only one task runs at a time so system changes never overlap.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnDone,
        [scriptblock]$OnFail,
        # Background refreshes wait their turn; user actions get a notice instead.
        [switch]$Queue
    )

    if ($script:CurrentTask) {
        $item = @{ Name = $Name; Script = $Script; Arguments = $Arguments; OnDone = $OnDone; OnFail = $OnFail; Quiet = [bool]$Queue }
        if ($Queue) {
            # The same refresh asked for twice only needs to run once.
            if ($script:CurrentTask.Name -eq $Name -or @($script:TaskQueue | Where-Object { $_.Name -eq $Name }).Count) { return $true }
            $script:TaskQueue.Add($item)
            return $true
        }
        if (-not (Test-WKCanStartAction)) { return $false }
        # Only background refreshes are running or waiting; the user's action
        # goes next.
        $script:TaskQueue.Insert(0, $item)
        $script:UI.StatusText.Text = "$Name will start in a moment..."
        Update-WKPreviewLock
        return $true
    }

    $runspace = [runspacefactory]::CreateRunspace($script:SessionState)
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($Script.ToString())
    foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }

    $script:CurrentTask = @{
        Name     = $Name
        PS       = $ps
        Runspace = $runspace
        Handle   = $ps.BeginInvoke()
        OnDone   = $OnDone
        OnFail   = $OnFail
        Started  = Get-Date
        # Queued tasks are background refreshes the user did not ask for;
        # they do not get the busy animation.
        Quiet    = [bool]$Queue
    }
    Set-WKBusy -Busy $true -Text $Name -Quiet:([bool]$Queue)
    return $true
}

function Test-WKCanStartAction {
    <#
        False, with a notice, while an action the user started is running or
        waiting. Call it before asking for confirmation, so nobody confirms
        something that is then refused.
    #>
    $busy = if ($script:CurrentTask -and -not $script:CurrentTask.Quiet) { $script:CurrentTask.Name }
            else { @($script:TaskQueue | Where-Object { -not $_.Quiet } | ForEach-Object { $_.Name }) | Select-Object -First 1 }
    if ($busy) {
        Show-WKToast "Please wait until '$busy' finishes." -Kind Warning
        return $false
    }
    return $true
}

function Update-WKPreviewLock {
    # Preview mode must not change between confirming an action and its end.
    $locked = ($script:CurrentTask -and -not $script:CurrentTask.Quiet) -or @($script:TaskQueue | Where-Object { -not $_.Quiet }).Count -gt 0
    $script:UI.PreviewToggle.IsEnabled = -not $locked
    $script:UI.PreviewBannerOff.IsEnabled = -not $locked
}

function Complete-WKTask {
    $task = $script:CurrentTask
    $output = @()
    $failed = $false
    try {
        $output = @($task.PS.EndInvoke($task.Handle))
        foreach ($e in $task.PS.Streams.Error) {
            Write-WKLog $e.Exception.Message -Level Error
        }
    }
    catch {
        $failed = $true
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        Write-WKLog "$($task.Name) failed: $($inner.Message)" -Level Error
        Show-WKToast "$($task.Name) failed. See Activity for details." -Kind Error
    }
    finally {
        $task.PS.Dispose()
        $task.Runspace.Dispose()
        $script:CurrentTask = $null
        Set-WKBusy -Busy $false
    }

    $handler = if ($failed) { $task.OnFail } else { $task.OnDone }
    if ($handler) {
        # Run the completion outside the timer tick: a dialog it opens must
        # not stop the timer that drives logging and the other tasks.
        $script:DoneQueue.Enqueue(@{ Handler = $handler; Output = $output })
        [void]$script:UI.Window.Dispatcher.BeginInvoke([System.Action]{ Invoke-WKDoneHandler })
    }
}

function Invoke-WKDoneHandler {
    if (-not $script:DoneQueue.Count) { return }
    $item = $script:DoneQueue.Dequeue()
    try { & $item.Handler $item.Output }
    catch { Write-WKLog "Could not update the view: $($_.Exception.Message)" -Level Error }
}

function Set-WKBusy {
    param([bool]$Busy, [string]$Text, [switch]$Quiet)
    $story = $script:UI.Window.FindResource('BusyAnimation')
    if ($Busy) {
        $script:UI.StatusText.Text = "$Text..."
        Update-WKPreviewLock
        if ($Quiet) { return }
        $script:UI.BusyBar.Visibility = 'Visible'
        $story.Begin($script:UI.Window, $true)
        Set-WKBrush $script:UI.StatusDot ([System.Windows.Shapes.Shape]::FillProperty) 'AccentBrush'
    }
    else {
        $story.Stop($script:UI.Window)
        $script:UI.BusyBar.Visibility = 'Hidden'
        Update-WKPreviewLock
        Update-WKStatusIdle
    }
}

function Update-WKStatusIdle {
    if ($script:CurrentTask) { return }
    if ($WK.PreviewMode) {
        $script:UI.StatusText.Text = 'Preview mode: nothing will be changed'
        Set-WKBrush $script:UI.StatusDot ([System.Windows.Shapes.Shape]::FillProperty) 'WarnBrush'
    }
    else {
        $script:UI.StatusText.Text = 'Ready'
        Set-WKBrush $script:UI.StatusDot ([System.Windows.Shapes.Shape]::FillProperty) 'GoodBrush'
    }
}

function Invoke-WKTick {
    # Runs every 120 ms on the UI thread; an error here must never reach WPF.
    try { Invoke-WKTickCore }
    catch { try { Write-WKLog "Internal error: $($_.Exception.Message)" -Level Error } catch { } }
}

function Invoke-WKTickCore {
    # Drain log entries produced by any thread.
    $entry = $null
    $lines = New-Object System.Text.StringBuilder
    while ($WK.LogQueue.TryDequeue([ref]$entry)) {
        Write-WKConsole $entry
        [void]$lines.AppendLine(('{0:HH:mm:ss}  {1}' -f $entry.Time, $entry.Message))
        if ($script:CurrentTask -and $entry.Level -eq 'Step') {
            $script:UI.StatusText.Text = $entry.Message
        }
    }
    if ($lines.Length) {
        $log = $script:UI.ActivityLog
        $log.AppendText($lines.ToString())
        # LineCount is -1 while the panel is collapsed, so trim by length.
        if ($log.Text.Length -gt 400000) { $log.Text = ($log.Text -split "`r?`n" | Select-Object -Last 2000) -join [Environment]::NewLine }
        $log.ScrollToEnd()
    }

    if ($script:CurrentTask -and $script:CurrentTask.Handle.IsCompleted) {
        Complete-WKTask
    }
    if (-not $script:CurrentTask -and -not $script:DoneQueue.Count -and $script:TaskQueue.Count) {
        $next = $script:TaskQueue[0]
        $script:TaskQueue.RemoveAt(0)
        [void](Start-WKTask -Name $next.Name -Script $next.Script -Arguments $next.Arguments -OnDone $next.OnDone -OnFail $next.OnFail -Queue:([bool]$next.Quiet))
    }
}

#endregion

#region Dialogs and toasts

function Show-WKDialog {
    <#
        Modal in-window dialog. Returns the label of the button pressed.
        Escape returns -Cancel, which defaults to the first button. Dialogs
        nest: a second one replaces the first until it is answered, then the
        first comes back.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Buttons = @('OK'),
        [string]$Primary,
        [string]$Danger,
        [string]$Cancel,
        # The dialog confirms an action that changes the PC.
        [switch]$Action,
        # Enter must not trigger the primary button (for example a restart).
        [switch]$NoDefault
    )

    if (-not $Cancel) { $Cancel = $Buttons[0] }
    if ($Action -and $WK.PreviewMode) { $Message += "`n`nPreview mode is on: nothing will be changed." }

    $outer = $null
    if ($script:DialogFrame) {
        $outer = @{
            Frame   = $script:DialogFrame
            Cancel  = $script:DialogCancel
            Title   = $script:UI.DlgTitle.Text
            Message = $script:UI.DlgMessage.Text
            Buttons = @($script:UI.DlgButtons.Children)
        }
    }

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:DialogFrame = $frame
    $script:DialogResult = $Cancel
    $script:DialogCancel = $Cancel

    $script:UI.DlgTitle.Text = $Title
    $script:UI.DlgMessage.Text = $Message
    $script:UI.DlgButtons.Children.Clear()

    $focus = $null
    foreach ($label in $Buttons) {
        $style = if ($label -eq $Primary) { 'PrimaryBtn' } elseif ($label -eq $Danger) { 'DangerBtn' } else { 'Btn' }
        $b = New-WKButton -Content $label -Style $style -Tag @{ Label = $label; Frame = $frame } -Margin (New-WKThickness 8 0 0 0)
        $b.MinWidth = 90
        $b.Add_Click({
            $script:DialogResult = $this.Tag.Label
            $this.Tag.Frame.Continue = $false
        })
        [void]$script:UI.DlgButtons.Children.Add($b)
        if ($label -eq $Primary -and -not $NoDefault) { $b.IsDefault = $true; $focus = $b }
        if (-not $focus -and $label -eq $Cancel) { $focus = $b }
    }

    # Keep keyboard and mouse input inside the dialog.
    $script:UI.Sidebar.IsEnabled = $false
    $script:UI.MainArea.IsEnabled = $false
    $script:UI.DialogLayer.Visibility = 'Visible'
    if ($focus) { [void]$focus.Focus() }

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $result = $script:DialogResult

    if ($outer) {
        $script:UI.DlgTitle.Text = $outer.Title
        $script:UI.DlgMessage.Text = $outer.Message
        $script:UI.DlgButtons.Children.Clear()
        foreach ($b in $outer.Buttons) { [void]$script:UI.DlgButtons.Children.Add($b) }
        $script:DialogFrame = $outer.Frame
        $script:DialogCancel = $outer.Cancel
        $script:DialogResult = $outer.Cancel
    }
    else {
        $script:UI.DialogLayer.Visibility = 'Collapsed'
        $script:UI.Sidebar.IsEnabled = $true
        $script:UI.MainArea.IsEnabled = $true
        $script:DialogFrame = $null
    }
    return $result
}

function Show-WKToast {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Success', 'Info', 'Warning', 'Error')][string]$Kind = 'Success'
    )
    $glyph = @{ Success = 'E73E'; Info = 'E946'; Warning = 'E7BA'; Error = 'E711' }[$Kind]
    $script:UI.ToastIcon.Text = Get-WKGlyph $glyph
    $script:UI.ToastText.Text = $Message
    $script:UI.Toast.Visibility = 'Visible'

    if (-not $script:ToastTimer) {
        $script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToastTimer.Add_Tick({
            $script:UI.Toast.Visibility = 'Collapsed'
            $script:ToastTimer.Stop()
        })
    }
    $script:ToastTimer.Stop()
    $script:ToastTimer.Interval = [TimeSpan]::FromSeconds([math]::Min(9, 3 + $Message.Length / 30))
    $script:ToastTimer.Start()
}

#endregion

#region Theme

$script:WKPalettes = @{
    Light = @{
        BgBrush = '#F5F6FA'; SidebarBrush = '#FFFFFF'; SurfaceBrush = '#FFFFFF'; HoverBrush = '#F0F2F8'
        LineBrush = '#E3E7EF'; TrackBrush = '#E9ECF4'; ScrollBrush = '#C9CFDC'; TextBrush = '#0F172A'
        MutedBrush = '#5B6B80'; AccentBrush = '#1D3BD1'; AccentHoverBrush = '#1631B4'; AccentSoftBrush = '#ECEFFD'; AccentFillBrush = '#1D3BD1'
        OnAccentBrush = '#FFFFFF'; GoodBrush = '#15803D'; GoodSoftBrush = '#E7F6EC'; WarnBrush = '#B45309'
        WarnSoftBrush = '#FDF3E3'; BadBrush = '#C62828'; BadSoftBrush = '#FDECEC'; InfoBrush = '#0369A1'
        InfoSoftBrush = '#E5F2FA'; OverlayBrush = '#800B1020'
    }
    Dark = @{
        BgBrush = '#0C101B'; SidebarBrush = '#111624'; SurfaceBrush = '#151B2B'; HoverBrush = '#1C2336'
        LineBrush = '#242C42'; TrackBrush = '#232B40'; ScrollBrush = '#3A4460'; TextBrush = '#E7EAF3'
        MutedBrush = '#8C94A9'; AccentBrush = '#5B78FF'; AccentHoverBrush = '#4F6BF5'; AccentSoftBrush = '#1B2347'; AccentFillBrush = '#3D5AF1'
        OnAccentBrush = '#FFFFFF'; GoodBrush = '#4ADE80'; GoodSoftBrush = '#11291B'; WarnBrush = '#FBBF24'
        WarnSoftBrush = '#2D2410'; BadBrush = '#F87171'; BadSoftBrush = '#2F1618'; InfoBrush = '#38BDF8'
        InfoSoftBrush = '#0E2433'; OverlayBrush = '#B3000000'
    }
}

function Get-WKSystemTheme {
    $v = Get-WKRegistryValue -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme'
    if ($v.Exists -and [int]$v.Value -eq 0) { return 'Dark' }
    return 'Light'
}

function Set-WKTheme {
    param([ValidateSet('System', 'Light', 'Dark')][string]$Mode)
    $resolved = if ($Mode -eq 'System') { Get-WKSystemTheme } else { $Mode }
    $palette = $script:WKPalettes[$resolved]
    $resources = $script:UI.Window.Resources
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        # ::new instead of New-Object: a PSObject wrapper stored through the
        # dictionary indexer is not accepted by WPF as a Brush.
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $resources[$key] = $brush.PSObject.BaseObject
    }
    $script:ResolvedTheme = $resolved
}

#endregion

#region Navigation

$script:WKPages = [ordered]@{
    overview  = @{ Page = 'PageOverview';  Nav = 'NavOverview';  Title = 'Overview' }
    apps      = @{ Page = 'PageApps';      Nav = 'NavApps';      Title = 'Apps' }
    developer = @{ Page = 'PageDeveloper'; Nav = 'NavDeveloper'; Title = 'Developer' }
    tweaks    = @{ Page = 'PageTweaks';    Nav = 'NavTweaks';    Title = 'Tweaks' }
    network   = @{ Page = 'PageNetwork';   Nav = 'NavNetwork';   Title = 'Network' }
    history   = @{ Page = 'PageHistory';   Nav = 'NavHistory';   Title = 'History' }
    settings  = @{ Page = 'PageSettings';  Nav = 'NavSettings';  Title = 'Settings & about' }
}

function Show-WKPage {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($key in $script:WKPages.Keys) {
        $p = $script:WKPages[$key]
        $script:UI[$p.Page].Visibility = if ($key -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    $page = $script:WKPages[$Name]
    $script:UI.TitleText.Text = "Klaudik WinKit  /  $($page.Title)"
    if (-not $script:UI[$page.Nav].IsChecked) { $script:UI[$page.Nav].IsChecked = $true }
    $script:CurrentPage = $Name

    $first = -not $script:State.Visited.Contains($Name)
    [void]$script:State.Visited.Add($Name)
    switch ($Name) {
        'apps'      { if ($first) { Update-WKAppsInstalled } }
        'developer' { if ($first) { Update-WKDeveloperPage } }
        'tweaks'    { if ($first) { Update-WKTweakStates } }
        'network'   { if ($first) { Update-WKDnsOverview } }
        'history'   { Update-WKHistoryPage }
    }
}

#endregion
