# System overview and health checks. Everything here is read-only.

function Get-WKSystemInfo {
    [CmdletBinding()]
    param()

    # A damaged WMI repository should cost one detail, not the whole page.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display|Remote Display|Virtual' } |
              ForEach-Object { $_.Name.Trim() })
    $sysDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue

    $boot = if ($os -and $os.LastBootUpTime) { $os.LastBootUpTime } else { (Get-Date).AddMilliseconds(-[Environment]::TickCount) }
    $uptime = (Get-Date) - $boot
    $win = $WK.Windows

    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        UserName       = $env:USERNAME
        OS             = $win.Name
        Version        = "$($win.DisplayVersion) (build $($win.Build).$($win.Revision))"
        Manufacturer   = "$($cs.Manufacturer)".Trim()
        Model          = "$($cs.Model)".Trim()
        Cpu            = ("$($cpu.Name)" -replace '\s+', ' ').Trim()
        Cores          = "$($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
        MemoryBytes    = [double]$cs.TotalPhysicalMemory
        MemoryFreeBytes = if ($os) { [double]$os.FreePhysicalMemory * 1KB } else { [double]0 }
        Gpu            = if ($gpus.Count) { $gpus -join ', ' } else { 'Unknown' }
        SystemDrive    = $env:SystemDrive
        DiskSizeBytes  = [double]$sysDrive.Size
        DiskFreeBytes  = [double]$sysDrive.FreeSpace
        Uptime         = $uptime
        BootTime       = $boot
    }
}

function New-WKCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('Good', 'Info', 'Warning', 'Critical')][string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [string]$ActionLabel,
        [string]$ActionTarget
    )
    [pscustomobject]@{
        Id           = $Id
        Title        = $Title
        Status       = $Status
        Detail       = $Detail
        ActionLabel  = $ActionLabel
        ActionTarget = $ActionTarget
    }
}

function Test-WKPendingReboot {
    [CmdletBinding()]
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    # Only Windows servicing. Queued file renames are left out: app updaters
    # (browsers, for example) leave them behind all the time.
    foreach ($k in $keys) { if (Test-Path -LiteralPath $k) { return $true } }
    return $false
}

function Get-WKStartupItemCount {
    [CmdletBinding()]
    param()

    $count = 0
    $runKeys = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
               'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    $approvedKeys = @{
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'              = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'              = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'  = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
    }

    foreach ($path in $runKeys) {
        $p = ConvertFrom-WKRegistryPath $path
        $base = Open-WKRegistryBase $p.Hive
        try {
            $key = $base.OpenSubKey($p.SubKey, $false)
            if (-not $key) { continue }
            try {
                foreach ($name in $key.GetValueNames()) {
                    if (-not $name) { continue }
                    # Task Manager marks disabled entries with an odd first byte.
                    $approved = Get-WKRegistryValue -Path $approvedKeys[$path] -Name $name
                    if ($approved.Exists -and @($approved.Value).Count -gt 0 -and (@($approved.Value)[0] % 2) -eq 1) { continue }
                    $count++
                }
            }
            finally { $key.Close() }
        }
        finally { $base.Close() }
    }

    $folders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    $folderApproval = @{
        ([Environment]::GetFolderPath('Startup'))       = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        ([Environment]::GetFolderPath('CommonStartup')) = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }
    foreach ($f in $folders) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $approved = Get-WKRegistryValue -Path $folderApproval[$f] -Name $item.Name
            if ($approved.Exists -and @($approved.Value).Count -gt 0 -and (@($approved.Value)[0] % 2) -eq 1) { continue }
            $count++
        }
    }
    return $count
}

function Get-WKAntivirusStatus {
    [CmdletBinding()]
    param()

    try {
        $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop)
    }
    catch { return $null }

    $result = foreach ($p in $products) {
        # productState: bits 12-15 are the scanner state (1 = on; 0 = off,
        # 2 = snoozed, 3 = expired), the low byte is 0x00 when signatures are
        # up to date and 0x10 when they are not.
        $state = [int]$p.productState
        [pscustomobject]@{
            Name     = $p.displayName
            Enabled  = ((($state -shr 12) -band 0xF) -eq 1)
            UpToDate = (($state -band 0xFF) -eq 0)
        }
    }
    return @($result)
}

function Get-WKLastUpdateDate {
    <#
        Date of the most recent Windows update (cumulative, security or
        servicing stack). Get-HotFix lists exactly those; the Windows Update
        history would also count daily Defender definitions and Store apps.
    #>
    [CmdletBinding()]
    param()

    $hotfix = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } |
              Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hotfix) { return $hotfix.InstalledOn }

    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $total = $searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            $dates = foreach ($e in $searcher.QueryHistory(0, [Math]::Min($total, 200))) {
                # ResultCode 2 = succeeded. KB2267602 is the Defender definition update.
                if ($e.ResultCode -eq 2 -and $e.Title -notmatch 'KB2267602' -and "$($e.ClientApplicationID)" -notmatch 'Store') { $e.Date }
            }
            $latest = $dates | Sort-Object -Descending | Select-Object -First 1
            if ($latest) { return ([datetime]$latest).ToLocalTime() }
        }
    }
    catch { }
    return $null
}
function Get-WKHealthReport {
    <# Background entry point: collects system info and scores the PC. #>
    [CmdletBinding()]
    param()

    Write-WKLog 'Checking system health' -Level Step
    $info = Get-WKSystemInfo
    $checks = New-Object System.Collections.Generic.List[object]

    # Disk space
    $freePct = if ($info.DiskSizeBytes) { [math]::Round(100 * $info.DiskFreeBytes / $info.DiskSizeBytes) } else { 100 }
    $detail = "$(Format-WKBytes $info.DiskFreeBytes) free of $(Format-WKBytes $info.DiskSizeBytes) ($freePct%) on $($info.SystemDrive)"
    $status = if ($freePct -lt 10) { 'Critical' } elseif ($freePct -lt 20) { 'Warning' } else { 'Good' }
    $checks.Add((New-WKCheck -Id 'disk' -Title 'Free disk space' -Status $status -Detail $detail -ActionLabel 'Open Storage settings' -ActionTarget 'uri:ms-settings:storagesense'))

    # Memory pressure
    $usedPct = if ($info.MemoryBytes) { [math]::Round(100 * (1 - $info.MemoryFreeBytes / $info.MemoryBytes)) } else { 0 }
    $status = if ($usedPct -ge 90) { 'Warning' } else { 'Good' }
    $checks.Add((New-WKCheck -Id 'memory' -Title 'Memory usage' -Status $status -Detail "$usedPct% of $(Format-WKBytes $info.MemoryBytes) in use"))

    # Startup apps
    $startup = Get-WKStartupItemCount
    $status = if ($startup -gt 12) { 'Warning' } elseif ($startup -gt 8) { 'Info' } else { 'Good' }
    $checks.Add((New-WKCheck -Id 'startup' -Title 'Startup apps' -Status $status -Detail "$(Format-WKCount $startup 'app') start when you sign in" -ActionLabel 'Manage' -ActionTarget 'uri:ms-settings:startupapps'))

    # Pending restart
    if (Test-WKPendingReboot) {
        $checks.Add((New-WKCheck -Id 'reboot' -Title 'Restart pending' -Status 'Warning' -Detail 'Windows is waiting for a restart to finish installing updates'))
    }
    else {
        $checks.Add((New-WKCheck -Id 'reboot' -Title 'Restart pending' -Status 'Good' -Detail 'No restart is pending'))
    }

    # Uptime
    $days = [math]::Floor($info.Uptime.TotalDays)
    $status = if ($days -ge 14) { 'Info' } else { 'Good' }
    $checks.Add((New-WKCheck -Id 'uptime' -Title 'Uptime' -Status $status -Detail ("Running for {0}d {1}h since the last restart" -f $days, $info.Uptime.Hours)))

    # Windows Update
    $last = Get-WKLastUpdateDate
    if ($last) {
        $age = [math]::Floor(((Get-Date) - $last).TotalDays)
        $status = if ($age -gt 60) { 'Critical' } elseif ($age -gt 35) { 'Warning' } else { 'Good' }
        $detail = if ($age -lt 1) { "Last update installed today" } else { "Last update installed $(Format-WKCount $age 'day') ago ($($last.ToString('d', [System.Globalization.CultureInfo]::GetCultureInfo('en-US'))))" }
    }
    else {
        $status = 'Info'
        $detail = 'Could not determine when updates were last installed'
    }
    $checks.Add((New-WKCheck -Id 'updates' -Title 'Windows Update' -Status $status -Detail $detail -ActionLabel 'Open Windows Update' -ActionTarget 'uri:ms-settings:windowsupdate'))

    # Antivirus
    $av = Get-WKAntivirusStatus
    if ($null -eq $av) {
        $checks.Add((New-WKCheck -Id 'antivirus' -Title 'Antivirus' -Status 'Info' -Detail 'Security Center is not available on this system'))
    }
    else {
        $active = @($av | Where-Object Enabled)
        if (-not $active.Count) {
            $checks.Add((New-WKCheck -Id 'antivirus' -Title 'Antivirus' -Status 'Critical' -Detail 'No antivirus has real-time protection turned on' -ActionLabel 'Open Windows Security' -ActionTarget 'uri:windowsdefender:'))
        }
        elseif (@($active | Where-Object { -not $_.UpToDate }).Count) {
            $checks.Add((New-WKCheck -Id 'antivirus' -Title 'Antivirus' -Status 'Warning' -Detail "$($active[0].Name) definitions are out of date" -ActionLabel 'Open Windows Security' -ActionTarget 'uri:windowsdefender:'))
        }
        else {
            $checks.Add((New-WKCheck -Id 'antivirus' -Title 'Antivirus' -Status 'Good' -Detail "$($active[0].Name) is on and up to date"))
        }
    }

    # Firewall
    try {
        # The effective settings, including Group Policy, not just the local ones.
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
        $off = @($profiles | Where-Object { "$($_.Enabled)" -notin 'True', '1' } | ForEach-Object Name)
        # Security suites often turn Windows Firewall off and protect the PC
        # with their own; Security Center knows about them.
        $other = $null
        if ($off.Count) {
            try {
                $other = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop |
                           Where-Object { ((([int]$_.productState) -shr 12) -band 0xF) -eq 1 }) | Select-Object -First 1
            }
            catch { }
        }
        if ($other) {
            $checks.Add((New-WKCheck -Id 'firewall' -Title 'Firewall' -Status 'Good' -Detail "$($other.displayName) is protecting this PC"))
        }
        elseif ($off.Count) {
            $checks.Add((New-WKCheck -Id 'firewall' -Title 'Firewall' -Status 'Critical' -Detail "Firewall is off for: $($off -join ', ')" -ActionLabel 'Open firewall settings' -ActionTarget 'uri:windowsdefender://network'))
        }
        else {
            $checks.Add((New-WKCheck -Id 'firewall' -Title 'Firewall' -Status 'Good' -Detail 'On for all network profiles'))
        }
    }
    catch {
        $checks.Add((New-WKCheck -Id 'firewall' -Title 'Firewall' -Status 'Info' -Detail 'Firewall status could not be read'))
    }

    # Drive health
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        $bad = @($disks | Where-Object { $_.HealthStatus -and "$($_.HealthStatus)" -ne 'Healthy' })
        if ($bad.Count) {
            $names = ($bad | ForEach-Object { "$($_.FriendlyName) ($($_.HealthStatus))" }) -join ', '
            $checks.Add((New-WKCheck -Id 'drives' -Title 'Drive health' -Status 'Critical' -Detail "Back up your data: $names"))
        }
        else {
            $checks.Add((New-WKCheck -Id 'drives' -Title 'Drive health' -Status 'Good' -Detail "$(Format-WKCount $disks.Count 'drive') reported as healthy"))
        }
    }
    catch {
        $checks.Add((New-WKCheck -Id 'drives' -Title 'Drive health' -Status 'Info' -Detail 'Drive health could not be read'))
    }

    # Privacy posture
    $privacy = @(Get-WKTweak | Where-Object { $_.category -eq 'privacy' })
    $applied = 0
    $counted = 0
    foreach ($t in $privacy) {
        $s = Get-WKTweakState -Tweak $t
        if ($s.State -eq 'Unavailable') { continue }
        $counted++
        if ($s.State -eq 'Applied') { $applied++ }
    }
    $status = if ($counted -and $applied / $counted -lt 0.3) { 'Info' } else { 'Good' }
    $checks.Add((New-WKCheck -Id 'privacy' -Title 'Privacy settings' -Status $status -Detail "Privacy protections turned on: $applied of $counted" -ActionLabel 'Review' -ActionTarget 'page:tweaks'))

    $penalty = 0
    foreach ($c in $checks) {
        switch ($c.Status) {
            'Critical' { $penalty += 22 }
            'Warning'  { $penalty += 9 }
            'Info'     { $penalty += 2 }
        }
    }
    $score = [math]::Max(0, [math]::Min(100, 100 - $penalty))
    $grade = if ($score -ge 90) { 'Excellent' } elseif ($score -ge 75) { 'Good' } elseif ($score -ge 50) { 'Fair' } else { 'Needs attention' }

    Write-WKLog "Health score: $score ($grade)" -Level Success
    [pscustomobject]@{
        Score     = $score
        Grade     = $grade
        Checks    = $checks.ToArray()
        System    = $info
        CheckedAt = Get-Date
    }
}
