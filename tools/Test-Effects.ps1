<#
.SYNOPSIS
    Applies every tweak for real, checks that Windows actually changed, then
    undoes it and checks that everything is back exactly as it was.

.DESCRIPTION
    Registry state alone proves little: the shell caches many settings and a
    few are guarded by Windows. This tool checks the effect the user would
    see, with a separate method for each tweak:

      - taskbar buttons, search box, clock and alignment through UI Automation
      - File Explorer windows it opens itself (extensions, hidden files,
        full path, start folder, context menu)
      - SystemParametersInfo, WinRT settings APIs, services, tasks, power plan
      - every registry value read back through WMI, outside this process

    File Explorer is restarted several times. Windows features (WSL, Sandbox,
    Hyper-V) are only read, because changing them needs a reboot.

    Run from an elevated Windows PowerShell started from the Start menu:
        powershell -ExecutionPolicy Bypass -File .\tools\Test-Effects.ps1
#>
[CmdletBinding()]
param(
    # Only test these tweak ids (wildcards allowed).
    [string[]]$Only = @('*'),
    [string]$OutFile,
    # No desktop (CI runners, Server Core): skip the checks that need the
    # taskbar or File Explorer and do not restart Explorer.
    [switch]$Headless
)

$ErrorActionPreference = 'Continue'
# WinKit moves TEMP to an admin-only folder; files the signed-in user must
# read or write go to the user's own TEMP.
$script:UserTemp = [IO.Path]::GetTempPath()
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\TestHelpers.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not $OutFile) { $OutFile = Join-Path ([IO.Path]::GetTempPath()) 'winkit-effects.txt' }
Set-Content -LiteralPath $OutFile -Value "WinKit effect test $(Get-Date -Format s) on $($WK.Windows.Name) $($WK.Windows.DisplayVersion) build $($WK.Windows.Build).$($WK.Windows.Revision)" -Encoding UTF8

function Out-Line([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $OutFile -Value $Text -Encoding UTF8
}

if (-not $WK.IsAdmin) { Out-Line 'Run this from an elevated PowerShell window.' Red; exit 2 }
if (Test-WKRegistryRedirected) { Out-Line 'This PowerShell runs in an app container with a private registry; start it from the Start menu.' Red; exit 2 }

$WK.HistoryFile = Join-Path ([IO.Path]::GetTempPath()) "winkit-effects-$([guid]::NewGuid()).json"
Initialize-WKNative

$script:Pass = 0
$script:Fail = 0
$script:Notes = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:Pass++; Out-Line "    PASS  $Name $Detail" Green }
    else { $script:Fail++; Out-Line "    FAIL  $Name $Detail" Red }
}

#region Readers that do not use WinKit's own code

$AE = [System.Windows.Automation.AutomationElement]
$Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Wmi = [wmiclass]'\\.\root\default:StdRegProv'

function Read-RealValue([string]$Path, [string]$Name) {
    # Reads through the WMI service, so the value is what Windows sees.
    if ($Path -cmatch '^HKCU\\(.*)$') { $hive = [uint32]2147483651; $sub = "$Sid\$($Matches[1])" }
    elseif ($Path -cmatch '^HKLM\\(.*)$') { $hive = [uint32]2147483650; $sub = $Matches[1] }
    else { return '<bad path>' }
    $enum = $Wmi.EnumValues($hive, $sub)
    if ($enum.ReturnValue -ne 0) { return '<no key>' }
    $names = @($enum.sNames)
    $types = @($enum.Types)
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ("$($names[$i])" -ne $Name) { continue }
        switch ($types[$i]) {
            1 { return 'SZ:' + $Wmi.GetStringValue($hive, $sub, $Name).sValue }
            2 { return 'EXPAND:' + $Wmi.GetExpandedStringValue($hive, $sub, $Name).sValue }
            3 { return 'BIN:' + (@($Wmi.GetBinaryValue($hive, $sub, $Name).uValue) -join ',') }
            4 { return 'DWORD:' + $Wmi.GetDWORDValue($hive, $sub, $Name).uValue }
            7 { return 'MULTI:' + (@($Wmi.GetMultiStringValue($hive, $sub, $Name).sValue) -join '|') }
            11 { return 'QWORD:' + $Wmi.GetQWORDValue($hive, $sub, $Name).uValue }
        }
    }
    # The unnamed default value is not always listed.
    if ($Name -eq '') {
        $s = $Wmi.GetStringValue($hive, $sub, '')
        if ($s.ReturnValue -eq 0) { return 'SZ:' + $s.sValue }
    }
    return '<absent>'
}

function Get-SpiRegistry([string]$Setting) {
    switch ($Setting) {
        'mouse'               { return @(@('HKCU\Control Panel\Mouse', 'MouseSpeed'), @('HKCU\Control Panel\Mouse', 'MouseThreshold1'), @('HKCU\Control Panel\Mouse', 'MouseThreshold2')) }
        'menuDelay'           { return @(, @('HKCU\Control Panel\Desktop', 'MenuShowDelay')) }
        'minAnimate'          { return @(, @('HKCU\Control Panel\Desktop\WindowMetrics', 'MinAnimate')) }
        'clientAreaAnimation' { return @(, @('HKCU\Control Panel\Desktop', 'UserPreferencesMask')) }
        'stickyKeysHotkey'    { return @(, @('HKCU\Control Panel\Accessibility\StickyKeys', 'Flags')) }
    }
    return @()
}

function Get-TouchedValues($Tweak) {
    $list = @()
    foreach ($a in @($Tweak.actions)) {
        if ($a.type -eq 'registry') { $list += , @($a.path, $a.name) }
        elseif ($a.type -eq 'spi') { $list += Get-SpiRegistry $a.setting }
        elseif ($a.type -eq 'shell') {
            if ($a.flag -eq 'showExtensions') { $list += , @('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt') }
            else { $list += , @('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Hidden') }
        }
    }
    return $list
}

function Get-RealSnapshot($Tweak) {
    $map = [ordered]@{}
    foreach ($v in Get-TouchedValues $Tweak) { $map["$($v[0])\$($v[1])"] = Read-RealValue $v[0] $v[1] }
    foreach ($a in @($Tweak.actions)) {
        switch ($a.type) {
            'service' {
                $s = Get-CimInstance Win32_Service -Filter "Name='$($a.name)'"
                # Running state is left out: trigger-started services come and go on their own.
                $map["service:$($a.name)"] = if ($s) { "$($s.StartMode)/delayed=$($s.DelayedAutoStart)" } else { '<none>' }
            }
            'task' {
                $t = Get-ScheduledTask -TaskPath $a.path -TaskName $a.name -ErrorAction SilentlyContinue
                $map["task:$($a.name)"] = if ($t) { "$($t.State)" -replace 'Ready|Running|Queued', 'Enabled' } else { '<none>' }
            }
            'powerplan' {
                $line = & (Get-WKSystemTool 'powercfg.exe') /getactivescheme
                $map['powerplan'] = ([regex]::Match("$line", '[0-9a-fA-F-]{36}')).Value
            }
            'spi' { $map["spi:$($a.setting)"] = Format-WKRegistryData (Get-WKSpiValue -Setting $a.setting) }
        }
    }
    return $map
}

function Get-Taskbar {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'Shell_TrayWnd')
    return $AE::RootElement.FindFirst('Children', $c)
}

function Get-TaskbarState {
    for ($try = 0; $try -lt 30; $try++) {
        $t = Get-Taskbar
        if ($t) {
            $h = @{ Taskbar = $t.Current.BoundingRectangle }
            foreach ($e in $t.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition)) {
                $c = $e.Current
                if ($c.AutomationId -in 'WidgetsButton', 'StartButton', 'SearchButton', 'SearchBoxTextBlock', 'TaskViewButton') {
                    $h[$c.AutomationId] = $c.BoundingRectangle
                }
                if ($c.ClassName -eq 'SystemTray.OmniButton' -and -not $h.ContainsKey('Time')) {
                    # The clock text is only in the raw view.
                    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
                    $child = $walker.GetFirstChild($e)
                    while ($child) {
                        if ($child.Current.AutomationId -eq 'TimeInnerTextBlock') { $h['Time'] = $child.Current.Name }
                        $child = $walker.GetNextSibling($child)
                    }
                }
            }
            if ($h.ContainsKey('StartButton') -and $h.ContainsKey('Time')) { return $h }
        }
        Start-Sleep -Milliseconds 500
    }
    return @{}
}

function Wait-Shell {
    # After a restart the taskbar needs a moment to build its buttons.
    Start-Sleep -Seconds 2
    [void](Get-TaskbarState)
    Start-Sleep -Seconds 2
}

function Get-ExplorerWindows {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'CabinetWClass')
    return @($AE::RootElement.FindAll('Children', $c))
}

function Invoke-AsUser([string]$FilePath, [string]$Arguments) {
    # Windows opened from an elevated process land in a separate Explorer
    # process, and some checks answer differently for administrators, so
    # start things the way the user would: through WinKit's own helper.
    Start-WKAsInteractiveUser -FilePath $FilePath -Arguments $Arguments
}
function Get-AsUser([string]$Code) {
    # Runs PowerShell code as the signed-in user and returns what it printed.
    # The code goes into a script file the user can read: a long
    # -EncodedCommand can exceed what a scheduled task accepts.
    $id = [guid]::NewGuid().ToString('N')
    $out = Join-Path $script:UserTemp "winkit-effects-$id.txt"
    $file = Join-Path $script:UserTemp "winkit-effects-$id.ps1"
    $body = "try { & { $Code } | Out-File -LiteralPath '$out' -Encoding UTF8 } catch { ""error: `$(`$_.Exception.Message)"" | Out-File -LiteralPath '$out' -Encoding UTF8 }"
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding $true))
    try {
        Invoke-AsUser -FilePath (Get-WKPowerShellPath) -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$file`""
        for ($i = 0; $i -lt 120 -and -not (Test-Path -LiteralPath $out); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Milliseconds 300
        $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
    }
    finally {
        foreach ($f in $out, $file) { if (Test-Path -LiteralPath $f) { [System.IO.File]::Delete($f) } }
    }
    return "$text".Trim()
}

function Open-Explorer([string]$Target) {
    $before = @(Get-ExplorerWindows | ForEach-Object { $_.Current.NativeWindowHandle })
    $explorer = Get-WKWindowsPath 'explorer.exe'
    if ($Target) { Invoke-AsUser -FilePath $explorer -Arguments "`"$Target`"" } else { Invoke-AsUser -FilePath $explorer }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $new = @(Get-ExplorerWindows | Where-Object { $before -notcontains $_.Current.NativeWindowHandle })
        if ($new.Count) {
            # A new window can show Home for a moment before it navigates.
            $leaf = if ($Target) { Split-Path -Leaf $Target } else { $null }
            for ($j = 0; $j -lt 40 -and $leaf -and $new[0].Current.Name -notlike "*$leaf*"; $j++) { Start-Sleep -Milliseconds 250 }
            Start-Sleep -Milliseconds 1500
            return $new[0]
        }
    }
    return $null
}

function Close-Explorer($Window) {
    if (-not $Window) { return }
    try { $Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch { }
    Start-Sleep -Milliseconds 400
}

function Get-ItemNames($Window) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    return @($Window.FindAll('Descendants', $c) | ForEach-Object { $_.Current.Name })
}

$script:Sample = Join-Path $script:UserTemp 'WinKitEffects'
New-Item -ItemType Directory -Force -Path $script:Sample | Out-Null
Set-Content -LiteralPath (Join-Path $script:Sample 'visible-sample.txt') -Value 'x'
$hiddenFile = Join-Path $script:Sample 'hidden-sample.txt'
if (-not (Test-Path -LiteralPath $hiddenFile)) { Set-Content -LiteralPath $hiddenFile -Value 'x' }
(Get-Item -LiteralPath $hiddenFile -Force).Attributes = 'Hidden'

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WKTest
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
    public static void RightClick(int x, int y)
    {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(300);
        mouse_event(0x8, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x10, 0, 0, 0, UIntPtr.Zero);
    }
    public static string[] TopWindows()
    {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (IsWindowVisible(h)) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); list.Add(sb.ToString() + "@" + h.ToInt64()); }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static void Key(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); keybd_event(vk, 0, 2, UIntPtr.Zero); }
}
"@
function Get-TopWindows { return [WKTest]::TopWindows() }

function Get-FolderView {
    $w = Open-Explorer $script:Sample
    if (-not $w) { return $null }
    $names = Get-ItemNames $w
    $title = $w.Current.Name
    Close-Explorer $w
    return [pscustomobject]@{ Names = $names; Title = $title }
}

#endregion

#region What the user would see, per tweak

# Each oracle returns $true when the tweak's effect is visible, $false when
# it is not, or a string describing a problem.
$Oracles = @{
    'explorer.file-extensions' = {
        $v = Get-FolderView; if (-not $v) { return 'no window' }
        if ($v.Names -contains 'visible-sample.txt') { return $true }
        if ($v.Names -contains 'visible-sample') { return $false }
        return "items: $($v.Names -join ', ')"
    }
    'explorer.hidden-files' = {
        $v = Get-FolderView; if (-not $v) { return 'no window' }
        return [bool](@($v.Names | Where-Object { $_ -like 'hidden-sample*' }).Count)
    }
    'developer.full-path-title' = {
        $v = Get-FolderView; if (-not $v) { return 'no window' }
        return $v.Title.StartsWith($script:Sample, [StringComparison]::OrdinalIgnoreCase)
    }
    'explorer.open-this-pc' = {
        $w = Open-Explorer $null; if (-not $w) { return 'no window' }
        $title = $w.Current.Name
        Close-Explorer $w
        $thisPc = (New-Object -ComObject Shell.Application).NameSpace(17).Title
        return $title.StartsWith($thisPc, [StringComparison]::OrdinalIgnoreCase)
    }
    'explorer.hide-recent' = {
        $items = @((New-Object -ComObject Shell.Application).NameSpace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}').Items())
        $recent = @($items | Where-Object { -not $_.IsFolder }).Count
        return ($recent -eq 0)
    }
    'explorer.classic-context-menu' = {
        # Right-clicks a file. The classic menu opens a new #32768 window; the
        # Windows 11 menu reuses XAML popups that already exist.
        $w = Open-Explorer $script:Sample; if (-not $w) { return 'no window' }
        try {
            $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
            $item = $null
            for ($i = 0; $i -lt 20 -and -not $item; $i++) { $item = $w.FindFirst('Descendants', $c); if (-not $item) { Start-Sleep -Milliseconds 250 } }
            if (-not $item) { return 'no file in the window' }
            [void][WKTest]::SetForegroundWindow([IntPtr]$w.Current.NativeWindowHandle)
            $r = $item.Current.BoundingRectangle
            $before = @(Get-TopWindows)
            [WKTest]::RightClick([int]($r.X + 30), [int]($r.Y + $r.Height / 2))
            Start-Sleep -Seconds 2
            $new = @(Get-TopWindows | Where-Object { $before -notcontains $_ })
            [WKTest]::Key(0x1B)
            Start-Sleep -Milliseconds 400
            return [bool](@($new | Where-Object { $_ -like '#32768*' }).Count)
        }
        finally { Close-Explorer $w }
    }
    'explorer.taskbar-left' = {
        $s = Get-TaskbarState; if (-not $s.StartButton) { return 'no taskbar' }
        return (($s.StartButton.X - $s.Taskbar.X) -lt 150)
    }
    'explorer.hide-task-view' = { $s = Get-TaskbarState; if (-not $s.StartButton) { return 'no taskbar' }; return (-not $s.ContainsKey('TaskViewButton')) }
    'explorer.search-icon' = {
        $s = Get-TaskbarState; if (-not $s.StartButton) { return 'no taskbar' }
        if (-not $s.SearchButton) { return 'search hidden' }
        return ((-not $s.ContainsKey('SearchBoxTextBlock')) -and $s.SearchButton.Width -lt ($s.Taskbar.Height * 1.3))
    }
    'explorer.clock-seconds' = {
        $s = Get-TaskbarState; if (-not $s.Time) { return 'no clock' }
        $sep = "[:.$([char]0x2236)]"
        return ($s.Time -match "\d{1,2}$sep\d{2}$sep\d{2}")
    }
    'explorer.dark-mode' = {
        $ui = New-Object Windows.UI.ViewManagement.UISettings -ErrorAction SilentlyContinue
        if (-not $ui) { [void][Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]; $ui = New-Object Windows.UI.ViewManagement.UISettings }
        $bg = $ui.GetColorValue([Windows.UI.ViewManagement.UIColorType]::Background)
        return ($bg.R -lt 64)
    }
    'privacy.advertising-id' = {
        $null = [type]'Windows.System.UserProfile.AdvertisingManager, Windows.System.UserProfile, ContentType=WindowsRuntime'
        return ([string]::IsNullOrEmpty([Windows.System.UserProfile.AdvertisingManager]::AdvertisingId))
    }
    'privacy.location' = {
        # Asked as the user: administrators are always told Allowed. Desktop
        # apps get UserPromptRequired or DeniedBySystem once location is off.
        $r = Get-AsUser "`$null = [type]'Windows.Security.Authorization.AppCapabilityAccess.AppCapability, Windows.Security.Authorization.AppCapabilityAccess, ContentType=WindowsRuntime'; [Windows.Security.Authorization.AppCapabilityAccess.AppCapability]::Create('location').CheckAccess()"
        if (-not $r) { return 'no answer' }
        return ("$r" -ne 'Allowed')
    }
    'privacy.tailored-experiences' = {
        $r = Get-AsUser "`$null = [type]'Windows.System.UserProfile.DiagnosticsSettings, Windows.System.UserProfile, ContentType=WindowsRuntime'; [Windows.System.UserProfile.DiagnosticsSettings]::GetDefault().CanUseDiagnosticsToTailorExperiences"
        if (-not $r) { return 'no answer' }
        return ($r -eq 'False')
    }
    'privacy.diagnostic-data' = {
        $r = Get-AsUser "`$null = [type]'Windows.System.Profile.PlatformDiagnosticsAndUsageDataSettings, Windows.System.Profile, ContentType=WindowsRuntime'; [Windows.System.Profile.PlatformDiagnosticsAndUsageDataSettings]::CollectionLevel"
        if (-not $r) { return 'no answer' }
        return ($r -in 'Security', 'Basic')
    }
    'developer.long-paths' = {
        $code = 'Add-Type -Namespace W -Name L -MemberDefinition ''[DllImport("ntdll.dll")] public static extern byte RtlAreLongPathsEnabled();''; [W.L]::RtlAreLongPathsEnabled()'
        $out = & (Get-WKPowerShellPath) -NoProfile -Command $code
        return ("$out".Trim() -eq '1')
    }
    'gaming.mouse-acceleration' = { $m = @([WKNative]::GetMouse()); return ($m[2] -eq 0) }
    'performance.menu-delay' = { return ([WKNative]::GetMenuShowDelay() -le 100) }
    'performance.reduce-animations' = { return ((-not [WKNative]::GetMinAnimate()) -and (-not [WKNative]::GetClientAreaAnimation())) }
    'gaming.sticky-keys' = { return (-not [WKNative]::GetStickyKeysHotkey()) }
}

if ($Headless) {
    foreach ($k in @($Oracles.Keys)) {
        if ($k -like 'explorer.*' -or $k -in 'developer.full-path-title', 'privacy.advertising-id', 'privacy.location', 'privacy.tailored-experiences', 'privacy.diagnostic-data') { $Oracles.Remove($k) }
    }
}

function Invoke-Oracle([string]$Id) {
    if (-not $Oracles.ContainsKey($Id)) { return $null }
    try { return (& $Oracles[$Id]) } catch { return "error: $($_.Exception.Message)" }
}

#endregion

$skip = 'developer.wsl', 'developer.sandbox', 'developer.hyper-v'
$tweaks = @(Get-WKTweak | Where-Object { $id = $_.id; @($Only | Where-Object { $id -like $_ }).Count })

Out-Line ''
Out-Line 'Starting state (read through WinKit and through Windows):' Cyan
foreach ($t in $tweaks) { Out-Line ("  {0,-36} {1}" -f $t.id, (Get-WKTweakState -Tweak $t).State) }

foreach ($t in $tweaks) {
    Out-Line ''
    Out-Line "$($t.id)  [$($t.restart)]  $($t.title)" Cyan
    if ($skip -contains $t.id) {
        $s = Get-WKTweakState -Tweak $t
        Out-Line "    INFO  not changed by this test (needs a reboot); state: $($s.State) $($s.Reason)" Yellow
        continue
    }
    $state0 = Get-WKTweakState -Tweak $t
    if ($state0.State -eq 'Unavailable') {
        Out-Line "    INFO  unavailable here: $($state0.Reason)" Yellow
        continue
    }
    $mode = if ($state0.State -eq 'Applied') { 'Default' } else { 'Apply' }
    $wantEffect = ($mode -eq 'Apply')
    $snap0 = Get-RealSnapshot $t
    $effect0 = Invoke-Oracle $t.id
    Out-Line "    state $($state0.State); effect before: $effect0; testing $mode"

    $undone = $false
    try {
        $r = Invoke-WKTweak -Tweak $t -Mode $mode
        Check 'engine reported no failures' ($r.Failed -eq 0) "(changed $($r.Changed), failed $($r.Failed))"
        $state1 = (Get-WKTweakState -Tweak $t).State
        Check 'WinKit reads the new state' ($state1 -eq $(if ($wantEffect) { 'Applied' } else { 'NotApplied' })) "($state1)"

        # The values Windows sees, read outside this process.
        $snap1 = Get-RealSnapshot $t
        foreach ($a in @($t.actions | Where-Object { $_.type -eq 'registry' })) {
            $key = "$($a.path)\$($a.name)"
            $target = Get-WKActionTarget -Action $a -Mode $mode
            $expected = if ($target.Delete) { '<absent>|<no key>' } else { [regex]::Escape(":$(@($target.Value) -join ',')") + '$' }
            Check "Windows sees $($a.name)" ($snap1[$key] -match $expected) "($($snap0[$key]) -> $($snap1[$key]))"
        }

        if ($Oracles.ContainsKey($t.id)) {
            Start-Sleep -Milliseconds 1500
            $live = Invoke-Oracle $t.id
            if ($t.restart -eq 'explorer') {
                Out-Line "    INFO  without restarting Explorer: $live" DarkGray
                if (-not $Headless) { Restart-WKExplorer; Wait-Shell }
                $after = Invoke-Oracle $t.id
                Check 'visible after Explorer restart' ($after -is [bool] -and $after -eq $wantEffect) "($after)"
            }
            elseif ($t.restart -eq 'none') {
                Check 'visible immediately' ($live -is [bool] -and $live -eq $wantEffect) "($live)"
            }
            else {
                Out-Line "    INFO  needs $($t.restart) to take full effect; now: $live" DarkGray
            }
        }
        else {
            Out-Line "    INFO  no visible check; verified by reading Windows state ($($t.restart))" DarkGray
        }
    }
    finally {
        # Put everything back, the way the History page would.
        $entries = @(Get-WKActiveHistory -RefId $t.id)
        $ok = $true
        foreach ($e in $entries) { if (-not (Undo-WKHistoryEntry -Entry $e)) { $ok = $false } }
        Check 'undo succeeded' $ok "($($entries.Count) history entries)"
        if ($t.restart -eq 'explorer' -and -not $Headless) { Restart-WKExplorer; Wait-Shell } else { Start-Sleep -Milliseconds 1500 }
    }

    $snap2 = Get-RealSnapshot $t
    $diff = @($snap0.Keys | Where-Object { $snap0[$_] -ne $snap2[$_] } | ForEach-Object { "$_ : $($snap0[$_]) -> $($snap2[$_])" })
    Check 'every value is back as it was' ($diff.Count -eq 0) ($diff -join '; ')
    $state2 = (Get-WKTweakState -Tweak $t).State
    Check 'WinKit state is back' ($state2 -eq $state0.State) "($state2)"
    if ($Oracles.ContainsKey($t.id) -and $t.restart -in 'none', 'explorer') {
        $effect2 = Invoke-Oracle $t.id
        Check 'visible effect is back' ("$effect2" -eq "$effect0") "($effect0 -> $effect2)"
    }
}

Remove-Item -LiteralPath $script:Sample -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
Out-Line ''
Out-Line "Passed: $script:Pass  Failed: $script:Fail" $(if ($script:Fail) { 'Red' } else { 'Green' })
Out-Line "Results: $OutFile"
exit $(if ($script:Fail) { 1 } else { 0 })
