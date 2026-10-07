# Every tweak and DNS change is recorded together with the state it replaced,
# so any entry can be rolled back later, even after a reboot.

function Get-WKHistory {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $WK.HistoryFile)) { return @() }
    # A scanner may hold the file for a moment; retry, then let the error
    # propagate. Treating it as an empty history would overwrite it on save.
    $raw = $null
    for ($attempt = 1; $null -eq $raw; $attempt++) {
        try { $raw = [System.IO.File]::ReadAllText($WK.HistoryFile, [System.Text.Encoding]::UTF8) }
        catch [System.IO.IOException] {
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $raw.Trim()) { return @() }
    try {
        # Windows PowerShell emits a JSON array as one object; assign first so
        # it is not wrapped in a second array.
        $parsed = ConvertFrom-Json -InputObject $raw
        return @($parsed)
    }
    catch {
        # Keep the unreadable file for inspection instead of overwriting it.
        $backup = '{0}.corrupt-{1:yyyyMMddHHmmss}' -f $WK.HistoryFile, (Get-Date)
        Copy-Item -LiteralPath $WK.HistoryFile -Destination $backup -ErrorAction SilentlyContinue
        Write-WKLog "History file could not be parsed and was backed up to $backup" -Level Warning
        return @()
    }
}

function Save-WKHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)

    # A failed save must stop the operation, not pass silently: a change that
    # is not recorded cannot be undone.
    $ErrorActionPreference = 'Stop'
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 10
    $tmp = "$($WK.HistoryFile).tmp"
    # Antivirus scanners briefly lock files they inspect; retry before giving up.
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
            if ([System.IO.File]::Exists($WK.HistoryFile)) {
                # Atomic swap: the old file stays intact until the new one is complete.
                $backup = "$($WK.HistoryFile).bak"
                [System.IO.File]::Replace($tmp, $WK.HistoryFile, $backup)
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            else {
                [System.IO.File]::Move($tmp, $WK.HistoryFile)
            }
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Add-WKHistoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('tweak', 'dns')][string]$Kind,
        [Parameter(Mandatory)][string]$RefId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Changes,
        # 'Apply' for a tweak, 'Default' when Windows defaults were restored
        # without history to roll back to.
        [ValidateSet('Apply', 'Default')][string]$Mode = 'Apply'
    )

    $entry = [pscustomobject]@{
        id         = [guid]::NewGuid().ToString()
        time       = (Get-Date).ToString('o')
        kind       = $Kind
        refId      = $RefId
        mode       = $Mode
        title      = $Title
        changes    = @($Changes)
        reverted   = $false
        revertedAt = $null
    }
    $all = @(Get-WKHistory) + $entry
    Save-WKHistory -Entries $all
    return $entry
}

function Add-WKHistoryChange {
    <#
        Appends one change to an existing entry. A tweak records each change
        as soon as it is made, so a crash halfway through a tweak never leaves
        a change that cannot be undone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Change
    )
    $all = @(Get-WKHistory)
    $entry = $all | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $entry) { throw "History entry $Id was not found." }
    $entry.changes = @($entry.changes) + $Change
    Save-WKHistory -Entries $all
}

function Set-WKHistoryReverted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    $all = @(Get-WKHistory)
    foreach ($e in $all) {
        if ($e.id -eq $Id) {
            $e.reverted = $true
            $e.revertedAt = (Get-Date).ToString('o')
        }
    }
    Save-WKHistory -Entries $all
}

function Get-WKActiveHistory {
    [CmdletBinding()]
    param([string]$RefId)

    # Entries are appended in the order they happen. Newest first is the
    # order changes must be undone in; file order, unlike timestamps, is not
    # affected by clock changes.
    $all = @(Get-WKHistory)
    $active = for ($i = $all.Count - 1; $i -ge 0; $i--) {
        $e = $all[$i]
        if ($e.reverted) { continue }
        if ($RefId -and $e.refId -ne $RefId) { continue }
        $e
    }
    return @($active)
}

$script:WKForbiddenUndoPaths = @(
    'Image File Execution Options',
    'CurrentVersion\Run',
    'CurrentVersion\RunOnce',
    'Winlogon',
    'AppInit_DLLs',
    'Policies\System',
    'SafeBoot',
    'ImagePath',
    'ServiceDll',
    '\Command',
    'shell\open',
    'Debugger',
    'Environment',
    'KnownDLLs',
    'Control\Lsa',
    'Session Manager',
    'InprocServer32',
    'LocalServer32',
    'Windows Defender',
    'WindowsUpdate',
    'SmartScreen'
)

# Where a change of a tweak that is no longer in the catalog may point.
$script:WKUndoRegistryRoots = @(
    'HKCU\Software\Microsoft\',
    'HKCU\Software\Policies\Microsoft\',
    'HKCU\Control Panel\',
    'HKCU\System\GameConfigStore',
    'HKLM\SOFTWARE\Policies\Microsoft\',
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\',
    'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem',
    'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
    'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance'
)
function Test-WKSystemChange {
    <# Settings changed through the shell or SystemParametersInfo; before must be a plain, sane value. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Change)
    if ($Change.type -eq 'shell') {
        return ($Change.flag -cin 'showExtensions', 'showHidden' -and $Change.before -is [bool])
    }
    $v = @($Change.before)
    switch -CaseSensitive ("$($Change.setting)") {
        'mouse'      { return ($v.Count -eq 3 -and @($v | Where-Object { $_ -is [ValueType] -and $_ -ge 0 -and $_ -le 20 }).Count -eq 3) }
        'menuDelay'  { return ($v.Count -eq 1 -and $v[0] -is [ValueType] -and $v[0] -ge 0 -and $v[0] -le 4000) }
        { $_ -in 'minAnimate', 'clientAreaAnimation', 'stickyKeysHotkey' } { return ($v.Count -eq 1 -and $v[0] -is [bool]) }
    }
    return $false
}

function Test-WKChangeShape {
    <#
        Check for a change that no catalog action describes, such as one from
        a tweak a later version removed. Undo runs as administrator, so this
        is an allow-list: the change must point where WinKit tweaks point,
        services and features must be ones the catalog uses, and the places
        used to get code executed are refused outright.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Change)

    $catalog = @(Get-WKTweak | ForEach-Object { @($_.actions) })
    switch ($Change.type) {
        'registry' {
            $path = "$($Change.path)\$($Change.name)"
            foreach ($bad in $script:WKForbiddenUndoPaths) {
                if ($path.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
            }
            if (-not @($script:WKUndoRegistryRoots | Where-Object { "$($Change.path)\".StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { return $false }
            if ($Change.before.exists -and $Change.before.kind -notin 'DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary') { return $false }
            if ($Change.createdKey -and -not "$($Change.path)\".StartsWith("$($Change.createdKey)\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
            return $true
        }
        'service' {
            $known = @($catalog | Where-Object { $_.type -eq 'service' } | ForEach-Object { $_.name })
            return ($known -contains "$($Change.name)" -and $Change.before -in 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')
        }
        'task' {
            return ("$($Change.path)".StartsWith('\Microsoft\Windows\', [StringComparison]::OrdinalIgnoreCase) -and $Change.before -in 'Enabled', 'Disabled')
        }
        'feature' {
            $known = @($catalog | Where-Object { $_.type -eq 'feature' } | ForEach-Object { $_.name })
            return ($known -contains "$($Change.name)" -and $Change.before -in 'Enabled', 'Disabled')
        }
        'powerplan' { return (@($script:WKPowerSchemes.Values) -contains "$($Change.before)") }
        { $_ -in 'shell', 'spi' } { return (Test-WKSystemChange -Change $Change) }
    }
    return $false
}
function Test-WKChangeAllowed {
    <#
        Undo writes values from the history file with administrator rights,
        so every change must describe something WinKit itself can touch: an
        action of the tweak it belongs to, or a well-formed DNS setting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Change
    )

    $kinds = 'DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary'
    $startups = 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled'
    $states = 'Enabled', 'Disabled'

    if ($Entry.kind -eq 'dns') {
        if ($Change.type -ne 'dns') { return $false }
        if ("$($Change.interfaceGuid)" -cnotmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { return $false }
        foreach ($address in @($Change.before.v4) + @($Change.before.v6) | Where-Object { $_ }) {
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse("$address", [ref]$ip)) { return $false }
        }
        return $true
    }

    $tweak = Get-WKTweak -Id $Entry.refId
    # A tweak that a later version dropped or changed still has to be
    # undoable, so fall back to the allow-list check.
    if (-not $tweak) { return (Test-WKChangeShape -Change $Change) }

    foreach ($a in @($tweak.actions)) {
        if ($a.type -ne $Change.type) { continue }
        switch ($a.type) {
            'registry' {
                if ($a.path -ne $Change.path -or $a.name -ne $Change.name) { continue }
                if ($Change.before.exists -and $kinds -notcontains $Change.before.kind) { return $false }
                if ($Change.createdKey -and -not "$($a.path)\".StartsWith("$($Change.createdKey)\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
                return $true
            }
            'service'   { if ($a.name -eq $Change.name) { return ($startups -contains $Change.before) } }
            'task'      { if ($a.path -eq $Change.path -and $a.name -eq $Change.name) { return ($states -contains $Change.before) } }
            'feature'   { if ($a.name -eq $Change.name) { return ($states -contains $Change.before) } }
            'powerplan' { return ("$($Change.before)" -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') }
            'shell'     { if ($a.flag -ceq $Change.flag) { return (Test-WKSystemChange -Change $Change) } }
            'spi'       { if ($a.setting -ceq $Change.setting) { return (Test-WKSystemChange -Change $Change) } }
        }
    }
    # No action of this tweak matches, for example after a later version
    # changed how the tweak works.
    return (Test-WKChangeShape -Change $Change)
}

function Undo-WKHistoryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)

    foreach ($c in @($Entry.changes)) {
        if (-not (Test-WKChangeAllowed -Entry $Entry -Change $c)) {
            Write-WKLog "History entry '$($Entry.title)' contains a change WinKit did not make. Nothing was reverted." -Level Error
            return $false
        }
    }

    Write-WKLog "Reverting: $($Entry.title)" -Level Step
    $failures = 0
    $changes = @($Entry.changes)
    for ($i = $changes.Count - 1; $i -ge 0; $i--) {
        try {
            Undo-WKChange -Change $changes[$i]
        }
        catch {
            $failures++
            Write-WKLog "  Could not revert $(Format-WKChange $changes[$i]): $($_.Exception.Message)" -Level Error
        }
    }
    if ($Entry.kind -eq 'tweak') {
        $tweak = Get-WKTweak -Id $Entry.refId
        if ($tweak) { Invoke-WKTweakRefresh -Tweak $tweak }
    }
    if ($failures -eq 0) {
        Set-WKHistoryReverted -Id $Entry.id
        Write-WKLog "Reverted: $($Entry.title)" -Level Success
        return $true
    }
    Write-WKLog "$(Format-WKCount $failures 'change') in '$($Entry.title)' could not be reverted. The entry stays active so you can retry." -Level Warning
    return $false
}
