# Tweak engine.
#
# Tweaks are data (config/tweaks.json). Each one is a list of actions; every
# action knows how to read its current state, move to a target state and
# describe what it did. Before anything is written, the previous state is
# captured and stored in the history so it can be restored exactly.

$script:WKPowerSchemes = @{
    high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    saver    = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}

function Get-WKTweak {
    [CmdletBinding()]
    param([string]$Id)
    $all = @($WK.Config.Tweaks.tweaks)
    if ($Id) { return $all | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
    return $all
}

function Get-WKOptionalProperty {
    [CmdletBinding()]
    param($Object, [string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return [pscustomobject]@{ Present = $true; Value = $p.Value } }
    return [pscustomobject]@{ Present = $false; Value = $null }
}

function Test-WKTweakCompatible {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tweak)

    $win = $WK.Windows
    $versions = Get-WKOptionalProperty $Tweak 'windows'
    if ($versions.Present -and @($versions.Value) -notcontains $win.Major) {
        return "Only available on Windows $(@($versions.Value) -join ' and ')"
    }
    $minBuild = Get-WKOptionalProperty $Tweak 'minBuild'
    if ($minBuild.Present -and $win.Build -lt [int]$minBuild.Value) {
        return "Requires Windows build $($minBuild.Value) or newer"
    }
    $server = Get-WKOptionalProperty $Tweak 'server'
    if ($server.Present -and -not $server.Value -and $win.IsServer) {
        return 'Not available on Windows Server, where Windows uses different defaults'
    }
    return $null
}

#region Service, task, power plan and feature primitives

function Get-WKServiceStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $path = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
    $start = Get-WKRegistryValue -Path $path -Name 'Start'
    if (-not $start.Exists) { return $null }
    switch ([int]$start.Value) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 {
            $delayed = Get-WKRegistryValue -Path $path -Name 'DelayedAutostart'
            if ($delayed.Exists -and [int]$delayed.Value -eq 1) { return 'AutomaticDelayed' }
            return 'Automatic'
        }
        3 { return 'Manual' }
        4 { return 'Disabled' }
    }
    return $null
}

function Set-WKServiceStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')][string]$Startup
    )

    $mode = @{ Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }[$Startup]
    if ($Name -cnotmatch '^[A-Za-z0-9_.-]+$') { throw "'$Name' is not a valid service name." }
    $path = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
    $delayed = Get-WKRegistryValue -Path $path -Name 'DelayedAutostart'
    $result = Invoke-WKProcess -FilePath (Get-WKSystemTool 'sc.exe') -ArgumentList @('config', $Name, 'start=', $mode) -Quiet
    if ($result.ExitCode -ne 0) {
        throw "sc.exe could not change '$Name' (exit $($result.ExitCode)): $($result.Output -join ' ')"
    }
    # sc.exe clears the delayed-start flag even for services that do not start
    # automatically. Keep it, so undo restores the service exactly.
    # The flag is set through the Service Control Manager, which caches it;
    # writing the registry value alone would only apply after a restart.
    # sc.exe may clear it in the manager's cache even when the registry value
    # still reads the same, so always set it back.
    if ($Startup -in 'Manual', 'Disabled' -and $delayed.Exists -and $delayed.Kind -eq 'DWord') {
        Initialize-WKNative
        [WKNative]::SetServiceDelayedAutoStart($Name, ([int]$delayed.Value -eq 1))
    }

    if ($Startup -eq 'Disabled') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
    elseif ($Startup -like 'Automatic*') {
        try { Start-Service -Name $Name -ErrorAction Stop }
        catch { Write-WKLog "  The $Name service is set to start automatically but could not be started now: $($_.Exception.Message)" -Level Warning }
    }
}

function Get-WKTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    # The Task Scheduler COM API answers in milliseconds; Get-ScheduledTask
    # takes about half a second per call.
    try {
        if (-not $script:WKTaskService) {
            $script:WKTaskService = New-Object -ComObject Schedule.Service
            $script:WKTaskService.Connect()
        }
        $task = $script:WKTaskService.GetFolder($Path.TrimEnd('\')).GetTask($Name)
        if ($task.Enabled) { return 'Enabled' }
        return 'Disabled'
    }
    catch {
        # Missing folder or task.
        return $null
    }
}

function Set-WKTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    if ($State -eq 'Disabled') {
        Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    }
    else {
        Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    }
}

function Get-WKActivePowerScheme {
    [CmdletBinding()]
    param()
    $out = (& (Get-WKSystemTool 'powercfg.exe') /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1].ToLowerInvariant()
    }
    return $null
}

function Test-WKPowerSchemeAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Guid)
    $list = (& (Get-WKSystemTool 'powercfg.exe') /list) -join ' '
    return ($list -match [regex]::Escape($Guid))
}

function Set-WKPowerScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Guid)
    & (Get-WKSystemTool 'powercfg.exe') /setactive $Guid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg could not activate scheme $Guid (exit $LASTEXITCODE)." }
}

function Resolve-WKPowerScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:WKPowerSchemes.ContainsKey($Name)) { return $script:WKPowerSchemes[$Name] }
    return $Name
}

function Get-WKFeatureState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # One WMI query returns every optional feature in well under a second and
    # works without elevation; Get-WindowsOptionalFeature goes through DISM
    # and takes several seconds per feature.
    if (-not $script:WKFeatureCache -or ((Get-Date) - $script:WKFeatureCacheTime).TotalSeconds -gt 30) {
        # Built aside and stored only when the query succeeded, so one WMI
        # failure does not leave an empty cache behind.
        $cache = @{}
        foreach ($f in Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop) {
            $cache[$f.Name] = [int]$f.InstallState
        }
        $script:WKFeatureCache = $cache
        $script:WKFeatureCacheTime = Get-Date
    }
    if (-not $script:WKFeatureCache.ContainsKey($Name)) { return $null }
    # InstallState: 1 enabled, 2 disabled, 3 absent (not available on this edition).
    switch ($script:WKFeatureCache[$Name]) {
        1 { return 'Enabled' }
        2 { return 'Disabled' }
        3 { return $null }
    }
    # Any other value (for example a change waiting for a restart): ask DISM,
    # which reports pending states explicitly.
    if ($WK.IsAdmin) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
            switch ("$($feature.State)") {
                'Enabled'        { return 'Enabled' }
                'EnablePending'  { return 'Enabled' }
                'Disabled'       { return 'Disabled' }
                'DisablePending' { return 'Disabled' }
            }
        }
        catch { }
    }
    return $null
}

function Set-WKFeatureState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    if ($State -eq 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop | Out-Null
    }
    else {
        Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop | Out-Null
    }
    $script:WKFeatureCache = $null
}

$script:WKShellFlags = @{ showHidden = 1; showExtensions = 2 }
$script:WKSpiSettings = 'mouse', 'menuDelay', 'minAnimate', 'clientAreaAnimation', 'stickyKeysHotkey'

function Get-WKSpiValue {
    <# Reads a setting the way Windows applies it, through SystemParametersInfo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Setting)
    Initialize-WKNative
    switch ($Setting) {
        'mouse'      { return , ([int[]][WKNative]::GetMouse()) }
        'menuDelay'  { return [WKNative]::GetMenuShowDelay() }
        'minAnimate' { return [WKNative]::GetMinAnimate() }
        'clientAreaAnimation' { return [WKNative]::GetClientAreaAnimation() }
        'stickyKeysHotkey'    { return [WKNative]::GetStickyKeysHotkey() }
    }
    throw "Unknown system setting '$Setting'."
}

function Set-WKSpiValue {
    <# Applies a setting live and persists it, like the Settings app does. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)]$Value
    )
    Initialize-WKNative
    switch ($Setting) {
        'mouse'      { $v = @($Value); [WKNative]::SetMouse([int]$v[0], [int]$v[1], [int]$v[2]); return }
        'menuDelay'  { [WKNative]::SetMenuShowDelay([int]$Value); return }
        'minAnimate' { [WKNative]::SetMinAnimate([bool]$Value); return }
        'clientAreaAnimation' { [WKNative]::SetClientAreaAnimation([bool]$Value); return }
        'stickyKeysHotkey'    { [WKNative]::SetStickyKeysHotkey([bool]$Value); return }
    }
    throw "Unknown system setting '$Setting'."
}

function Test-WKValueEqual {
    [CmdletBinding()]
    param($A, $B)
    return ((@($A) -join ',') -eq (@($B) -join ','))
}

function Get-WKShellFlagValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Flag)
    if (-not $script:WKShellFlags.ContainsKey($Flag)) { throw "Unknown shell setting '$Flag'." }
    Initialize-WKNative
    return [WKNative]::GetShellFlag([uint32]$script:WKShellFlags[$Flag])
}

function Set-WKShellFlagValue {
    <# Changes a Folder Options setting through the shell, which updates open windows too. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Flag,
        [Parameter(Mandatory)][bool]$Value
    )
    if (-not $script:WKShellFlags.ContainsKey($Flag)) { throw "Unknown shell setting '$Flag'." }
    Initialize-WKNative
    [WKNative]::SetShellFlag([uint32]$script:WKShellFlags[$Flag], $Value)
}

function Invoke-WKTweakRefresh {
    <#
        Tells Windows that settings behind a tweak changed, the same way the
        Settings app does, so the shell picks them up without a restart where
        it can.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tweak)
    $notify = Get-WKOptionalProperty $Tweak 'notify'
    if (-not $notify.Present) { return }
    try { Send-WKSettingChange -Area @($notify.Value) }
    catch { Write-WKLog "  Could not notify Windows about the change: $($_.Exception.Message)" -Level Warning }
}

#endregion

#region Action state

function Get-WKActionTarget {
    <#
        Describes the state an action should end up in. Mode 'Apply' is the
        tweak itself, 'Default' is the Windows default used when there is no
        history to roll back to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Default')][string]$Mode
    )

    switch ($Action.type) {
        'registry' {
            if ($Mode -eq 'Apply') { return [pscustomobject]@{ Delete = $false; Value = $Action.value } }
            $d = Get-WKOptionalProperty $Action 'defaultValue'
            if ($d.Present) { return [pscustomobject]@{ Delete = $false; Value = $d.Value } }
            return [pscustomobject]@{ Delete = $true; Value = $null }
        }
        'service'   { if ($Mode -eq 'Apply') { return $Action.startup } else { return $Action.defaultStartup } }
        'task'      { if ($Mode -eq 'Apply') { return $Action.state } else { return $Action.defaultState } }
        'feature'   { if ($Mode -eq 'Apply') { return $Action.state } else { return $Action.defaultState } }
        'powerplan' {
            if ($Mode -eq 'Apply') { return (Resolve-WKPowerScheme $Action.scheme) }
            return (Resolve-WKPowerScheme $Action.defaultScheme)
        }
        'shell' { if ($Mode -eq 'Apply') { return [bool]$Action.value } else { return [bool]$Action.defaultValue } }
        'spi' {
            $v = if ($Mode -eq 'Apply') { $Action.value } else { $Action.defaultValue }
            # The mouse setting is three numbers; keep it an array.
            if ($Action.setting -ceq 'mouse') { return , ([int[]]@($v)) }
            return $v
        }
        default { throw "Unknown action type '$($Action.type)'." }
    }
}

function Get-WKActionState {
    <#
        Returns whether the action can run on this PC and whether the system
        is already in the requested state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [ValidateSet('Apply', 'Default')][string]$Mode = 'Apply'
    )

    $target = Get-WKActionTarget -Action $Action -Mode $Mode
    $state = [pscustomobject]@{ Applicable = $true; Matches = $false; Current = $null; Reason = $null }

    switch ($Action.type) {
        'registry' {
            $current = Get-WKRegistryValue -Path $Action.path -Name $Action.name
            $state.Current = $current
            if ($current.Exists -and $current.Kind -notin 'DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary') {
                # A value of an unusual type could not be restored exactly.
                $state.Applicable = $false
                $state.Reason = "The existing value has an unexpected type ($($current.Kind))"
                return $state
            }
            if ($target.Delete) { $state.Matches = -not $current.Exists }
            else {
                # Compare kinds first: converting a string to a DWORD would throw.
                $state.Matches = $current.Exists -and ($current.Kind -eq $Action.kind) -and
                                 (Test-WKRegistryValueEqual -Current $current -Kind $Action.kind -Expected $target.Value)
            }
        }
        'service' {
            $current = Get-WKServiceStartup -Name $Action.name
            $state.Current = $current
            if (-not $current) { $state.Applicable = $false; $state.Reason = "Service '$($Action.name)' is not installed" }
            else { $state.Matches = ($current -eq $target) }
        }
        'task' {
            $current = Get-WKTaskState -Path $Action.path -Name $Action.name
            $state.Current = $current
            if (-not $current) { $state.Applicable = $false; $state.Reason = "Task '$($Action.name)' does not exist" }
            else { $state.Matches = ($current -eq $target) }
        }
        'feature' {
            $current = $null
            try { $current = Get-WKFeatureState -Name $Action.name } catch { $current = $null }
            $state.Current = $current
            if (-not $current) { $state.Applicable = $false; $state.Reason = "Feature '$($Action.name)' is not available on this edition of Windows" }
            else { $state.Matches = ($current -eq $target) }
        }
        'powerplan' {
            $current = Get-WKActivePowerScheme
            $state.Current = $current
            if (-not (Test-WKPowerSchemeAvailable -Guid $target)) {
                $state.Applicable = $false
                $state.Reason = 'This power plan is hidden on this device (common on Modern Standby laptops)'
            }
            else { $state.Matches = ($current -eq $target) }
        }
        'shell' {
            $current = Get-WKShellFlagValue -Flag $Action.flag
            $state.Current = $current
            $state.Matches = ([bool]$current -eq [bool]$target)
        }
        'spi' {
            $current = Get-WKSpiValue -Setting $Action.setting
            $state.Current = $current
            $state.Matches = Test-WKValueEqual $current $target
        }
    }
    return $state
}

function Get-WKTweakState {
    <#
        Applied     - every applicable action is in the tweak's target state
        Partial     - some are
        NotApplied  - none are
        Unavailable - the tweak cannot run on this PC
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tweak)

    $reason = Test-WKTweakCompatible -Tweak $Tweak
    if ($reason) { return [pscustomobject]@{ Id = $Tweak.id; State = 'Unavailable'; Reason = $reason } }

    $applicable = 0
    $matched = 0
    $lastReason = $null
    foreach ($action in @($Tweak.actions)) {
        try {
            $s = Get-WKActionState -Action $action
        }
        catch {
            $lastReason = $_.Exception.Message
            continue
        }
        if (-not $s.Applicable) { $lastReason = $s.Reason; continue }
        $applicable++
        if ($s.Matches) { $matched++ }
    }

    $state = if ($applicable -eq 0) { 'Unavailable' }
             elseif ($matched -eq $applicable) { 'Applied' }
             elseif ($matched -eq 0) { 'NotApplied' }
             else { 'Partial' }

    [pscustomobject]@{
        Id     = $Tweak.id
        State  = $state
        Reason = if ($state -eq 'Unavailable') { $lastReason } else { $null }
    }
}

function Get-WKAllTweakStates {
    [CmdletBinding()]
    param()
    foreach ($t in Get-WKTweak) { Get-WKTweakState -Tweak $t }
}

#endregion

#region Applying and undoing

function Format-WKChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Change)

    switch ($Change.type) {
        'registry' {
            $name = if ($Change.name) { $Change.name } else { '(Default)' }
            $from = if ($Change.before.exists) { Format-WKRegistryData $Change.before.value } else { '(not set)' }
            $to = if ($Change.after.exists) { Format-WKRegistryData $Change.after.value } else { '(removed)' }
            return "$($Change.path)\$name : $from -> $to"
        }
        'service'   { return "Service $($Change.name) startup: $($Change.before) -> $($Change.after)" }
        'task'      { return "Task $($Change.path)$($Change.name): $($Change.before) -> $($Change.after)" }
        'feature'   { return "Windows feature $($Change.name): $($Change.before) -> $($Change.after)" }
        'powerplan' { return "Power plan: $($Change.before) -> $($Change.after)" }
        'shell'     { return "Folder option $($Change.flag): $($Change.before) -> $($Change.after)" }
        'spi'       { return "System setting $($Change.setting): $(Format-WKRegistryData $Change.before) -> $(Format-WKRegistryData $Change.after)" }
        'dns'       { return "DNS on $($Change.alias): $(Format-WKDnsSetting $Change.before) -> $(Format-WKDnsSetting $Change.after)" }
        default     { return ($Change | ConvertTo-Json -Compress -Depth 5) }
    }
}

function Format-WKRegistryData {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '(null)' }
    if ($Value -is [array]) { return '[' + (@($Value) -join ', ') + ']' }
    if ($Value -is [string]) { return '"' + $Value + '"' }
    return "$Value"
}

function Format-WKActionPlan {
    <# Human-readable description of what an action will do, for the details view. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    switch ($Action.type) {
        'registry' {
            $name = if ($Action.name) { $Action.name } else { '(Default)' }
            return "Registry  $($Action.path)\$name = $(Format-WKRegistryData $Action.value) ($($Action.kind))"
        }
        'service'   { return "Service   $($Action.name) startup type -> $($Action.startup)" }
        'task'      { return "Task      $($Action.path)$($Action.name) -> $($Action.state)" }
        'feature'   { return "Feature   $($Action.name) -> $($Action.state)" }
        'powerplan' { return "Power     Activate the '$($Action.scheme)' power plan" }
        'shell'     { return "Folder    $($Action.flag) = $($Action.value) (through the shell, like Folder Options)" }
        'spi'       { return "System    $($Action.setting) = $(Format-WKRegistryData $Action.value) (SystemParametersInfo, applied immediately)" }
    }
}

function Invoke-WKTweakAction {
    <#
        Moves one action to its target state. Returns a change record, or
        $null when nothing had to change (or in preview mode).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Default')][string]$Mode,
        [switch]$Preview
    )

    $state = Get-WKActionState -Action $Action -Mode $Mode
    if (-not $state.Applicable) {
        Write-WKLog "  Skipped: $($state.Reason)"
        return $null
    }
    if ($state.Matches) { return $null }

    $target = Get-WKActionTarget -Action $Action -Mode $Mode

    switch ($Action.type) {
        'registry' {
            $before = $state.Current
            $change = [pscustomobject]@{
                type       = 'registry'
                path       = $Action.path
                name       = $Action.name
                before     = [pscustomobject]@{ exists = $before.Exists; kind = $before.Kind; value = $before.Value }
                after      = $null
                createdKey = $null
            }
            if ($target.Delete) {
                $change.after = [pscustomobject]@{ exists = $false; kind = $null; value = $null }
                if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
                Remove-WKRegistryValue -Path $Action.path -Name $Action.name
                # Some tweaks work by the mere presence of a key (the classic
                # context menu); the Windows default is no key at all.
                $owned = Get-WKOptionalProperty $Action 'ownedKey'
                if ($owned.Present) {
                    try { Remove-WKRegistryKeyIfEmpty -Path $Action.path -StopAt $owned.Value }
                    catch { Write-WKLog "  Could not remove the empty key $($owned.Value): $($_.Exception.Message)" -Level Warning }
                }
            }
            else {
                $change.after = [pscustomobject]@{ exists = $true; kind = $Action.kind; value = $target.Value }
                if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
                $change.createdKey = Set-WKRegistryValue -Path $Action.path -Name $Action.name -Kind $Action.kind -Value $target.Value
            }
        }
        'service' {
            # Boot and System start types belong to drivers; undo could not restore them.
            if ($state.Current -notin 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled') {
                Write-WKLog "  Skipped: service $($Action.name) uses start type $($state.Current), which WinKit does not change"
                return $null
            }
            $change = [pscustomobject]@{ type = 'service'; name = $Action.name; before = $state.Current; after = $target }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Set-WKServiceStartup -Name $Action.name -Startup $target
        }
        'task' {
            $change = [pscustomobject]@{ type = 'task'; path = $Action.path; name = $Action.name; before = $state.Current; after = $target }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Set-WKTaskState -Path $Action.path -Name $Action.name -State $target
        }
        'feature' {
            $change = [pscustomobject]@{ type = 'feature'; name = $Action.name; before = $state.Current; after = $target }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Write-WKLog "  Changing Windows feature $($Action.name), this can take a minute"
            Set-WKFeatureState -Name $Action.name -State $target
        }
        'powerplan' {
            $change = [pscustomobject]@{ type = 'powerplan'; before = $state.Current; after = $target }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Set-WKPowerScheme -Guid $target
        }
        'shell' {
            $change = [pscustomobject]@{ type = 'shell'; flag = $Action.flag; before = [bool]$state.Current; after = [bool]$target }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Set-WKShellFlagValue -Flag $Action.flag -Value ([bool]$target)
        }
        'spi' {
            $change = [pscustomobject]@{ type = 'spi'; setting = $Action.setting; before = $state.Current; after = $target }
            # Only change what undo will accept back; an unusual current value
            # (for example a custom menu delay) is left alone.
            if (-not (Test-WKSystemChange -Change $change)) {
                Write-WKLog "  Skipped: the current $($Action.setting) value ($(Format-WKRegistryData $state.Current)) is unusual, so it was left as it is"
                return $null
            }
            if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; return $null }
            Set-WKSpiValue -Setting $Action.setting -Value $target
        }
    }

    Write-WKLog "  $(Format-WKChange $change)"
    return $change
}

function Undo-WKChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Change)

    switch ($Change.type) {
        'registry' {
            if ($Change.before.exists) {
                Set-WKRegistryValue -Path $Change.path -Name $Change.name -Kind $Change.before.kind -Value $Change.before.value | Out-Null
            }
            else {
                Remove-WKRegistryValue -Path $Change.path -Name $Change.name
            }
            if ($Change.createdKey) {
                # Cleanup only; the value itself is already restored.
                try { Remove-WKRegistryKeyIfEmpty -Path $Change.path -StopAt $Change.createdKey }
                catch { Write-WKLog "  Could not remove the empty key $($Change.createdKey): $($_.Exception.Message)" -Level Warning }
            }
        }
        # A Windows update can remove a service, task, feature or power plan
        # after WinKit changed it. Then there is nothing left to restore.
        'service' {
            if ($null -eq (Get-WKServiceStartup -Name $Change.name)) { Write-WKLog "  Service $($Change.name) no longer exists; nothing to restore"; return }
            Set-WKServiceStartup -Name $Change.name -Startup $Change.before
        }
        'task' {
            if ($null -eq (Get-WKTaskState -Path $Change.path -Name $Change.name)) { Write-WKLog "  Task $($Change.path)$($Change.name) no longer exists; nothing to restore"; return }
            Set-WKTaskState -Path $Change.path -Name $Change.name -State $Change.before
        }
        'feature' {
            if ($null -eq (Get-WKFeatureState -Name $Change.name)) { Write-WKLog "  Windows feature $($Change.name) is no longer available; nothing to restore"; return }
            Set-WKFeatureState -Name $Change.name -State $Change.before
        }
        'powerplan' {
            if (-not (Test-WKPowerSchemeAvailable -Guid $Change.before)) { Write-WKLog "  Power plan $($Change.before) no longer exists; nothing to restore"; return }
            Set-WKPowerScheme -Guid $Change.before
        }
        'shell'     { Set-WKShellFlagValue -Flag $Change.flag -Value ([bool]$Change.before) }
        'spi'       { Set-WKSpiValue -Setting $Change.setting -Value $Change.before }
        'dns'       { Set-WKDnsSetting -InterfaceGuid $Change.interfaceGuid -InterfaceIndex $Change.interfaceIndex -Setting $Change.before }
        default     { throw "Unknown change type '$($Change.type)'." }
    }
    Write-WKLog "  Restored $(Format-WKChange $Change)"
}

function Invoke-WKTweak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tweak,
        [ValidateSet('Apply', 'Default')][string]$Mode = 'Apply',
        [switch]$Preview
    )

    $verb = if ($Mode -eq 'Apply') { 'Applying' } else { 'Restoring Windows default for' }
    Write-WKLog "$verb '$($Tweak.title)'" -Level Step

    $incompatible = Test-WKTweakCompatible -Tweak $Tweak
    if ($incompatible) {
        Write-WKLog "  Skipped: $incompatible"
        return [pscustomobject]@{ Changed = 0; Failed = 0; Skipped = $true }
    }

    $changes = New-Object System.Collections.Generic.List[object]
    $failed = 0
    $title = if ($Mode -eq 'Apply') { $Tweak.title } else { "Windows default: $($Tweak.title)" }
    $entry = $null
    foreach ($action in @($Tweak.actions)) {
        try {
            $c = Invoke-WKTweakAction -Action $action -Mode $Mode -Preview:$Preview
            if (-not $c) { continue }
            $changes.Add($c)
            # Record each change right away, so it can be undone even if
            # WinKit is closed or crashes before the tweak finishes.
            if ($entry) { Add-WKHistoryChange -Id $entry.id -Change $c }
            else { $entry = Add-WKHistoryEntry -Kind tweak -RefId $Tweak.id -Title $title -Changes @($c) -Mode $Mode }
        }
        catch {
            $failed++
            Write-WKLog "  Failed: $($_.Exception.Message)" -Level Error
        }
    }

    if ($changes.Count -gt 0) {
        Invoke-WKTweakRefresh -Tweak $Tweak
    }
    elseif ($failed -eq 0 -and -not $Preview) {
        Write-WKLog '  Already in the requested state'
    }

    [pscustomobject]@{ Changed = $changes.Count; Failed = $failed; Skipped = $false }
}

function Invoke-WKTweakBatch {
    <#
        Entry point used by the UI. Runs in a background runspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Undo')][string]$Operation,
        [switch]$Preview,
        [switch]$SkipRestorePoint
    )

    $result = [pscustomobject]@{
        Status  = 'Done'
        Message = $null
        Changed = 0
        Failed  = 0
        Restart = @()
    }

    # Windows Server has no System Restore.
    if (-not $Preview -and -not $SkipRestorePoint -and $WK.Settings.CreateRestorePoint -and -not $WK.RestorePointDone -and -not $WK.Windows.IsServer) {
        try {
            New-WKRestorePoint -Description 'Before Klaudik WinKit changes'
        }
        catch {
            $result.Status = 'RestorePointFailed'
            $result.Message = $_.Exception.Message
            Write-WKLog "Restore point could not be created: $($_.Exception.Message)" -Level Warning
            return $result
        }
    }

    $restart = @{}
    foreach ($id in $Ids) {
        $tweak = Get-WKTweak -Id $id
        if (-not $tweak) { Write-WKLog "Unknown tweak '$id'" -Level Warning; continue }

        if ($Operation -eq 'Apply') {
            $r = Invoke-WKTweak -Tweak $tweak -Mode Apply -Preview:$Preview
        }
        else {
            # Undo rolls back what WinKit applied. Entries that restored Windows
            # defaults are not "applied" changes; reverting them would turn the
            # tweak back on.
            $entries = @(Get-WKActiveHistory -RefId $id | Where-Object { $_.PSObject.Properties['mode'] -eq $null -or $_.mode -ne 'Default' })
            if ($entries.Count -gt 0) {
                $changed = 0
                $failedEntries = 0
                foreach ($e in $entries) {
                    if ($Preview) {
                        Write-WKLog "[Preview] Would revert '$($e.title)'" -Level Step
                        foreach ($c in @($e.changes)) { Write-WKLog "  [Preview] Restore $(Format-WKChange $c)" }
                        continue
                    }
                    if (Undo-WKHistoryEntry -Entry $e) { $changed += @($e.changes).Count }
                    else {
                        # Older entries recorded the state before this one; stop so
                        # a retry later restores them in the right order.
                        $failedEntries++
                        break
                    }
                }
                $r = [pscustomobject]@{ Changed = $changed; Failed = $failedEntries; Skipped = $false }
            }
            elseif ((Get-WKTweakState -Tweak $tweak).State -eq 'Applied') {
                # Applied outside WinKit, so there is nothing recorded to roll
                # back to: use the Windows defaults.
                $r = Invoke-WKTweak -Tweak $tweak -Mode Default -Preview:$Preview
            }
            else {
                # Partly applied, but not by WinKit. Those values may be the
                # user's own choices; leave them alone.
                Write-WKLog "Nothing to undo for '$($tweak.title)': WinKit did not change it" -Level Step
                $r = [pscustomobject]@{ Changed = 0; Failed = 0; Skipped = $true }
            }
        }

        $result.Changed += $r.Changed
        $result.Failed += $r.Failed
        if ($r.Changed -gt 0 -and $tweak.restart -and $tweak.restart -ne 'none') { $restart[$tweak.restart] = $true }
    }

    $result.Restart = @($restart.Keys)
    $summary = if ($Preview) { 'Preview finished, nothing was changed' }
               else { "$(Format-WKCount $result.Changed 'change') made, $($result.Failed) failed" }
    $level = if ($result.Failed -gt 0) { 'Warning' } else { 'Success' }
    Write-WKLog $summary -Level $level
    return $result
}

#endregion
