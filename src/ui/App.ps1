function Show-WKFatal {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($Message, 'Klaudik WinKit', 'OK', 'Error')
    }
    catch { Write-Host $Message -ForegroundColor Red }
}

function Write-WKBanner {
    try { $Host.UI.RawUI.WindowTitle = "Klaudik WinKit $($WK.Version)" } catch { }
    Write-Host ''
    Write-Host '  Klaudik WinKit ' -ForegroundColor White -NoNewline
    Write-Host $WK.Version -ForegroundColor DarkGray
    Write-Host '  Open-source Windows toolkit  |  https://klaudik.com' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  Log file: $($WK.LogFile)" -ForegroundColor DarkGray
    Write-Host '  Keep this window open while WinKit is running.' -ForegroundColor DarkGray
    Write-Host ''
}

function Initialize-WKWindowChrome {
    $w = $script:UI.Window

    $script:UI.MinButton.Add_Click({ $script:UI.Window.WindowState = 'Minimized' })
    $script:UI.MaxButton.Add_Click({
        $script:UI.Window.WindowState = if ($script:UI.Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $script:UI.CloseButton.Add_Click({ $script:UI.Window.Close() })

    $w.Add_StateChanged({
        # A maximized WindowChrome window extends past the screen edge by the
        # resize border; pad the content so nothing is cut off.
        if ($script:UI.Window.WindowState -eq 'Maximized') {
            # Resize border plus the padded border Windows adds around it.
            $edge = [System.Windows.SystemParameters]::WindowResizeBorderThickness.Left + 4
            $script:UI.RootBorder.Margin = New-WKThickness $edge $edge $edge $edge
            $script:UI.MaxButton.Content = Get-WKGlyph 'E923'
            $script:UI.MaxButton.ToolTip = 'Restore'
        }
        else {
            $script:UI.RootBorder.Margin = New-WKThickness 0 0 0 0
            $script:UI.MaxButton.Content = Get-WKGlyph 'E922'
            $script:UI.MaxButton.ToolTip = 'Maximize'
        }
    })

    $w.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape' -and $script:DialogFrame) {
            $script:DialogResult = $script:DialogCancel
            $script:DialogFrame.Continue = $false
            $e.Handled = $true
        }
    })

    $w.Add_Closing({
        param($s, $e)
        # A question is waiting for an answer; closing now would leave the
        # code that asked it suspended forever.
        if ($script:DialogFrame) { $e.Cancel = $true; return }
        # Background refreshes can simply stop; only ask about the user's own actions.
        if ($script:CurrentTask -and -not $script:CurrentTask.Quiet) {
            $a = Show-WKDialog -Title 'A task is still running' -Buttons 'Keep open', 'Close anyway' -Danger 'Close anyway' `
                -Message "'$($script:CurrentTask.Name)' has not finished. Closing now may leave it half done."
            if ($a -ne 'Close anyway') { $e.Cancel = $true; return }
        }
        if ($script:Timer) { $script:Timer.Stop() }
    })

    # Navigation
    foreach ($key in $script:WKPages.Keys) {
        $nav = $script:UI[$script:WKPages[$key].Nav]
        $nav.Add_Checked({
            $name = $this.Name
            $target = $script:WKPages.Keys | Where-Object { $script:WKPages[$_].Nav -eq $name } | Select-Object -First 1
            if ($target -and $script:CurrentPage -ne $target) { Show-WKPage $target }
        })
    }

    # Preview mode
    $script:UI.PreviewToggle.IsChecked = [bool]$WK.PreviewMode
    $script:UI.PreviewBanner.Visibility = if ($WK.PreviewMode) { 'Visible' } else { 'Collapsed' }
    $script:UI.PreviewToggle.Add_Checked({
        $WK.PreviewMode = $true
        $script:UI.PreviewBanner.Visibility = 'Visible'
        Update-WKStatusIdle
    })
    $script:UI.PreviewToggle.Add_Unchecked({
        $WK.PreviewMode = $false
        $script:UI.PreviewBanner.Visibility = 'Collapsed'
        Update-WKStatusIdle
        Show-WKToast 'Preview mode is off. Actions now make real changes, and settings you change can be undone from History.' -Kind Info
    })
    $script:UI.PreviewBannerOff.Add_Click({ $script:UI.PreviewToggle.IsChecked = $false })

    # Elevation badge
    if ($WK.IsAdmin) {
        $script:UI.AdminBadgeText.Text = 'Administrator'
        Set-WKBrush $script:UI.AdminBadge ([System.Windows.Controls.Border]::BackgroundProperty) 'GoodSoftBrush'
        Set-WKBrush $script:UI.AdminBadgeText ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'GoodBrush'
        Set-WKBrush $script:UI.AdminBadgeIcon ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'GoodBrush'
        $script:UI.AdminBadge.ToolTip = 'WinKit is running with administrator rights.'
    }
    else {
        $script:UI.AdminBadgeText.Text = 'Limited'
        Set-WKBrush $script:UI.AdminBadge ([System.Windows.Controls.Border]::BackgroundProperty) 'WarnSoftBrush'
        Set-WKBrush $script:UI.AdminBadgeText ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'WarnBrush'
        Set-WKBrush $script:UI.AdminBadgeIcon ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'WarnBrush'
        $script:UI.AdminBadge.ToolTip = 'Not running as administrator. System-wide changes will fail.'
    }

    # Activity panel
    $script:UI.ActivityToggle.Add_Checked({ $script:UI.ActivityPanel.Visibility = 'Visible'; $script:UI.ActivityLog.ScrollToEnd() })
    $script:UI.ActivityToggle.Add_Unchecked({ $script:UI.ActivityPanel.Visibility = 'Collapsed' })
    $script:UI.ActivityCopy.Add_Click({
        if (-not $script:UI.ActivityLog.Text) { return }
        try { [System.Windows.Clipboard]::SetText($script:UI.ActivityLog.Text); Show-WKToast 'Activity copied to the clipboard.' }
        catch { Show-WKToast 'The clipboard is in use by another app. Try again in a moment.' -Kind Warning }
    })
    $script:UI.ActivityClear.Add_Click({ $script:UI.ActivityLog.Clear() })

    $script:UI.StatusVersion.Text = "v$($WK.Version)"
    Update-WKStatusIdle
}

function Get-WKInteractiveUserSid {
    # The owner of the desktop shell in this session is the person at the PC.
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $shell = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -OperationTimeoutSec 5 -ErrorAction Stop |
                 Where-Object { $_.SessionId -eq $session } | Select-Object -First 1
        if ($shell) { return (Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop).Sid }
    }
    catch { }
    return $null
}

function Test-WKInteractiveUser {
    <#
        When a standard user approves the UAC prompt with someone else's
        administrator account, WinKit runs as that account: per-user tweaks,
        Git, SSH and history would apply to the administrator, not to the
        person using the PC. Say so up front.
    #>
    $desktopSid = Get-WKInteractiveUserSid
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $desktopSid -or $desktopSid -eq $me.User.Value) { return }
    $desktopUser = try { (New-Object System.Security.Principal.SecurityIdentifier $desktopSid).Translate([System.Security.Principal.NTAccount]).Value } catch { $desktopSid }
    Write-WKLog "Running as $($me.Name) while $desktopUser is signed in" -Level Warning
    [void](Show-WKDialog -Title 'WinKit is running as a different account' -Buttons 'OK' -Primary 'OK' `
        -Message "The administrator prompt was approved with $($me.Name), but $desktopUser is signed in.`n`nSystem-wide changes work as usual. Per-user settings such as Explorer and privacy tweaks, Git and SSH apply to $($me.Name), not to $desktopUser. To change them for $desktopUser, run WinKit from an administrator account that is signed in.")
}

$script:WKTermsText = @"
WinKit changes system settings, installs and removes software and runs with administrator rights.

It is provided "as is", without warranty of any kind, under the MIT license. You use it at your own risk and are responsible for the changes you make. Back up important data first, and test on a non-critical PC before using WinKit on computers you depend on.

To the maximum extent permitted by law, Klaudik and the contributors are not liable for any damage, data loss or downtime caused by WinKit or by the third-party apps it installs. Those apps come from the winget repository under their own licenses.
"@

function Confirm-WKTerms {
    <# Shown once, before anything else. Returns $false when the user declines and the window is closing. #>
    if ($WK.Settings.TermsAccepted) { return $true }
    $answer = Show-WKDialog -Title 'Before you start' -Buttons 'Quit', 'I understand and agree' -Primary 'I understand and agree' -Cancel 'Quit' -Message $script:WKTermsText
    if ($answer -ne 'I understand and agree') {
        Write-WKLog 'The notice was declined; WinKit closed without changing anything'
        $script:UI.Window.Close()
        return $false
    }
    $WK.Settings.TermsAccepted = $true
    try { Save-WKSettings } catch { Write-WKLog "Settings could not be saved: $($_.Exception.Message)" -Level Warning }
    return $true
}

function Show-WKServerNotice {
    <# Windows Server works, but the tweak catalog is written for desktop editions. #>
    if (-not $WK.Windows.IsServer) { return }
    Write-WKLog "Running on Windows Server ($($WK.Windows.Name))" -Level Warning
    Show-WKToast 'Windows Server detected. Some tweaks target desktop features and may have no effect on Server.' -Kind Info
}

function New-WKWindow {
    <# Loads the XAML and indexes every named element into $script:UI. #>
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $xaml = Get-WKResource 'src/ui/MainWindow.xaml'
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $script:UI = @{ Window = $window }
    foreach ($m in [regex]::Matches($xaml, 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $m.Groups[1].Value
        $el = $window.FindName($name)
        if ($el) { $script:UI[$name] = $el }
    }

    $script:State = @{
        Visited         = New-Object 'System.Collections.Generic.HashSet[string]'
        AppSelection    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Installed       = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        InstalledLoaded = $false
        TweakSelection  = New-Object 'System.Collections.Generic.HashSet[string]'
        TweakStates     = @{}
        TweakRows       = @{}
        Health          = $null
    }
    $script:TaskQueue = New-Object System.Collections.Generic.List[object]
    $script:DoneQueue = New-Object 'System.Collections.Generic.Queue[object]'
    $script:CurrentTask = $null
    $script:DialogFrame = $null

    Set-WKTheme -Mode $WK.Settings.Theme
    Initialize-WKWindowChrome
    Initialize-WKOverviewPage
    Initialize-WKAppsPage
    Initialize-WKTweaksPage
    Initialize-WKDeveloperPage
    Initialize-WKNetworkPage
    Initialize-WKHistoryPage
    Initialize-WKSettingsPage

    $script:CurrentPage = 'overview'
    [void]$script:State.Visited.Add('overview')
    return $window
}

function Start-WinKit {
    [CmdletBinding()]
    param(
        [switch]$Preview,
        # Development only: run without administrator rights.
        [switch]$NoElevate
    )

    $ErrorActionPreference = 'Continue'

    # Before any cmdlet runs: an elevated process would otherwise load modules
    # from the user's Documents folder, which any program the user runs can
    # write to. Only the folders that ship with Windows are allowed.
    if (-not $NoElevate) {
        $env:PSModulePath = "$PSHOME\Modules;" + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
    }

    # AppLocker and WDAC restrict PowerShell to Constrained Language Mode,
    # where WPF and the Windows APIs WinKit uses are unavailable.
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host 'Klaudik WinKit cannot run here: PowerShell is restricted on this PC (Constrained Language Mode, set by AppLocker or WDAC).' -ForegroundColor Red
        return
    }

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Host 'Klaudik WinKit runs on Windows 10 and Windows 11.' -ForegroundColor Red
        return
    }
    $windows = Get-WKWindowsInfo
    if (-not (Test-WKSupportedWindows -Windows $windows)) {
        Show-WKFatal "Klaudik WinKit needs Windows 10 version 1809 (build 17763) or newer. This PC runs build $($windows.Build)."
        return
    }

    # Checked before asking for administrator rights and again in the elevated
    # process, which may run outside the container.
    if (-not $NoElevate -and (Test-WKRegistryRedirected)) {
        Show-WKFatal ("WinKit was started from inside an app that gives the programs it runs a private copy of the registry, " +
                      "so Windows would never see the changes.`n`nOpen Windows PowerShell or Terminal from the Start menu and run the command there.")
        return
    }
    # Always run in 64-bit Windows PowerShell: PowerShell 7 lacks some of the
    # modules used here, and a 32-bit host sees redirected system folders.
    $wrongHost = ($PSVersionTable.PSEdition -eq 'Core') -or
                 ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
    if ((-not $NoElevate -and -not (Test-WKAdmin)) -or $wrongHost) {
        Write-Host 'Klaudik WinKit needs administrator rights. Approve the Windows prompt to continue.' -ForegroundColor Cyan
        $ok = Start-WKElevated -ScriptPath $script:WKScriptPath -ScriptText $script:WKScriptText -Preview:$Preview
        if ($ok -eq 'Declined') { Write-Host 'WinKit was not started because administrator rights were declined.' -ForegroundColor Yellow }
        return
    }

    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Show-WKFatal 'WinKit must run in a single-threaded apartment. Start it with: powershell.exe -STA'
        return
    }

    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

    # One WinKit per user: two copies would overwrite each other's history.
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, "Local\KlaudikWinKit-$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)")
    $owned = $false
    try { $owned = $script:InstanceMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Show-WKFatal 'WinKit is already running. Switch to the open WinKit window.'
        return
    }

    try {
        $script:WK = Initialize-WKContext -Preview:$Preview
    }
    catch {
        Show-WKFatal "WinKit could not prepare its data folder in %ProgramData%\Klaudik\WinKit.`n`n$($_.Exception.Message)"
        return
    }
    Write-WKBanner

    # Folder options and input settings are applied through Windows APIs, the
    # same way the Settings app does it. Load them once for every runspace.
    try { Initialize-WKNative }
    catch { Write-WKLog "Windows setting helpers could not be loaded: $($_.Exception.Message)" -Level Warning }
    Write-WKLog "WinKit $($WK.Version) started on $($WK.Windows.Name) $($WK.Windows.DisplayVersion) (build $($WK.Windows.Build)), admin: $($WK.IsAdmin)"

    try {
        $window = New-WKWindow
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        Show-WKFatal "The WinKit window could not be created.`n`n$($inner.Message)"
        Write-WKLog "UI failed to load: $($inner.Message)" -Level Error
        return
    }

    # Built after every function exists so background jobs see all of them.
    $script:SessionState = New-WKSessionState

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:Timer.Add_Tick({ Invoke-WKTick })
    $script:Timer.Start()

    # No error in an event handler may close the app; report it instead.
    $window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        try {
            Write-WKLog "Unexpected error: $($e.Exception.Message)" -Level Error
            Show-WKToast 'Something went wrong. See Activity for details.' -Kind Error
        }
        catch { }
    })

    # The window is designed for 1280 x 820 but must fit smaller screens and
    # high scaling, or the title bar and Close button end up off-screen.
    $window.Add_SourceInitialized({
        $area = [System.Windows.SystemParameters]::WorkArea
        $w = $script:UI.Window
        $w.MinWidth = [math]::Min($w.MinWidth, $area.Width)
        $w.MinHeight = [math]::Min($w.MinHeight, $area.Height)
        if ($w.Width -gt $area.Width -or $w.Height -gt $area.Height) {
            $w.Width = [math]::Min($w.Width, $area.Width)
            $w.Height = [math]::Min($w.Height, $area.Height)
            $w.Left = $area.Left + ($area.Width - $w.Width) / 2
            $w.Top = $area.Top + ($area.Height - $w.Height) / 2
        }
    })

    $window.Add_ContentRendered({
        if (-not (Confirm-WKTerms)) { return }
        Update-WKHealth
        Test-WKInteractiveUser
        Show-WKServerNotice
    })
    try { [void]$window.ShowDialog() }
    finally {
        Write-WKLog 'WinKit closed'
        Invoke-WKTick
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
    }
}
