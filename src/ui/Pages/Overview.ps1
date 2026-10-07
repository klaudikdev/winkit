function Initialize-WKOverviewPage {
    $hour = (Get-Date).Hour
    $greeting = if ($hour -lt 5) { 'Working late' } elseif ($hour -lt 12) { 'Good morning' } elseif ($hour -lt 18) { 'Good afternoon' } else { 'Good evening' }
    $script:UI.OvGreeting.Text = $greeting
    $script:UI.OvSubtitle.Text = "$($WK.Windows.Name) $($WK.Windows.DisplayVersion)  |  build $($WK.Windows.Build).$($WK.Windows.Revision)"
    Set-WKScoreRing -Fraction 0

    $script:UI.OvRescan.Add_Click({ Update-WKHealth })
    $script:UI.OvExport.Add_Click({ Export-WKReportInteractive })
    $script:UI.OvQuickEssentials.Add_Click({
        Show-WKPage 'tweaks'
        Select-WKProfile -Id 'essentials'
    })
    $script:UI.OvQuickDeveloper.Add_Click({ Show-WKPage 'developer' })
    $script:UI.OvQuickLatency.Add_Click({
        Show-WKPage 'network'
        Start-WKLatencyTest
    })
}

function Set-WKScoreRing {
    param([double]$Fraction)

    $size = 168.0
    $stroke = 12.0
    $r = ($size - $stroke) / 2
    $c = $size / 2
    if ($Fraction -le 0) { $script:UI.OvRing.Data = $null; return }
    if ($Fraction -ge 1) {
        $script:UI.OvRing.Data = New-Object System.Windows.Media.EllipseGeometry((New-Object System.Windows.Point($c, $c)), $r, $r)
        return
    }
    # Round caps reach past the arc ends; keep a visible gap so the end of an
    # almost-full ring does not overlap its start.
    $f = [math]::Min(0.955, $Fraction)

    $angle = 2 * [math]::PI * $f - [math]::PI / 2
    $x = $c + $r * [math]::Cos($angle)
    $y = $c + $r * [math]::Sin($angle)
    $large = if ($f -gt 0.5) { 1 } else { 0 }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $data = [string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $c, ($c - $r), $r, $large, $x, $y)
    $script:UI.OvRing.Data = [System.Windows.Media.Geometry]::Parse($data)
}

function Update-WKHealth {
    $script:UI.OvGrade.Text = 'Scanning your PC...'
    [void](Start-WKTask -Name 'Checking system health' -Queue -Script {
        Get-WKHealthReport
    } -OnDone {
        param($out)
        $report = $out | Select-Object -Last 1
        if ($report) { Show-WKHealth -Report $report }
        else { $script:UI.OvGrade.Text = 'No result' }
    } -OnFail {
        $script:UI.OvGrade.Text = 'The scan could not be completed'
    })
}

function Add-WKInfoItem {
    param($Panel, [string]$Label, [string]$Value, [double]$Meter = -1, [switch]$Wrap)

    $sp = New-WKStack -Margin (New-WKThickness 0 0 0 14)
    [void]$sp.Children.Add((New-WKText -Text $Label -Style 'Caption'))
    $v = New-WKText -Text $Value -SemiBold -Trim:(-not $Wrap) -Wrap:$Wrap -Margin (New-WKThickness 0 3 0 0)
    $v.ToolTip = $Value
    [void]$sp.Children.Add($v)
    if ($Meter -ge 0) {
        $bar = New-Object System.Windows.Controls.ProgressBar
        $bar.Style = $script:UI.Window.FindResource('Meter')
        $bar.Maximum = 100
        $bar.Value = $Meter
        $bar.Margin = New-WKThickness 0 7 0 0
        $key = if ($Meter -ge 90) { 'BadBrush' } elseif ($Meter -ge 80) { 'WarnBrush' } else { 'AccentBrush' }
        Set-WKBrush $bar ([System.Windows.Controls.Control]::ForegroundProperty) $key
        [void]$sp.Children.Add($bar)
    }
    [void]$Panel.Children.Add($sp)
}

function Show-WKHealth {
    param([Parameter(Mandatory)]$Report)

    $script:State.Health = $Report
    $s = $Report.System

    $script:UI.OvScore.Text = "$($Report.Score)"
    $script:UI.OvGrade.Text = $Report.Grade
    $script:UI.OvCheckedAt.Text = "Checked at $($Report.CheckedAt.ToString('t'))"
    $ringKey = if ($Report.Score -ge 75) { 'AccentBrush' } elseif ($Report.Score -ge 50) { 'WarnBrush' } else { 'BadBrush' }
    Set-WKBrush $script:UI.OvRing ([System.Windows.Shapes.Shape]::StrokeProperty) $ringKey
    Set-WKScoreRing -Fraction ($Report.Score / 100)
    $script:UI.OvExport.IsEnabled = $true

    $device = "$($s.Manufacturer) $($s.Model)".Trim()
    if ($device) { $script:UI.OvSubtitle.Text = "$($WK.Windows.Name) $($WK.Windows.DisplayVersion) (build $($WK.Windows.Build).$($WK.Windows.Revision))  |  $device" }

    $left = $script:UI.OvInfoLeft
    $right = $script:UI.OvInfoRight
    $left.Children.Clear()
    $right.Children.Clear()

    $memUsed = if ($s.MemoryBytes) { 100 * (1 - $s.MemoryFreeBytes / $s.MemoryBytes) } else { 0 }
    $diskUsed = if ($s.DiskSizeBytes) { 100 * (1 - $s.DiskFreeBytes / $s.DiskSizeBytes) } else { 0 }
    $uptime = $s.Uptime
    $uptimeText = if ($uptime.TotalDays -ge 1) { '{0}d {1}h' -f [math]::Floor($uptime.TotalDays), $uptime.Hours } else { '{0}h {1}m' -f $uptime.Hours, $uptime.Minutes }

    $clean = { param($name) ($name -replace '\((R|TM|C)\)', '' -replace '\s{2,}', ' ').Trim() }
    Add-WKInfoItem $left 'PROCESSOR' (& $clean $s.Cpu)
    Add-WKInfoItem $left 'CORES' $s.Cores
    Add-WKInfoItem $left 'GRAPHICS' (& $clean $s.Gpu) -Wrap
    Add-WKInfoItem $right 'MEMORY' ("{0} of {1} in use" -f (Format-WKBytes ($s.MemoryBytes - $s.MemoryFreeBytes)), (Format-WKBytes $s.MemoryBytes)) $memUsed
    Add-WKInfoItem $right "DRIVE $($s.SystemDrive)" ("{0} free of {1}" -f (Format-WKBytes $s.DiskFreeBytes), (Format-WKBytes $s.DiskSizeBytes)) $diskUsed
    Add-WKInfoItem $right 'UPTIME' $uptimeText

    $list = $script:UI.OvChecks
    $list.Children.Clear()
    $order = @{ Critical = 0; Warning = 1; Info = 2; Good = 3 }
    $checks = @($Report.Checks | Sort-Object { $order[$_.Status] })
    for ($i = 0; $i -lt $checks.Count; $i++) {
        $c = $checks[$i]
        $row = New-WKGrid -Columns 'Auto', '*', 'Auto'
        $row.Margin = New-WKThickness 0 10 0 10
        Add-WKGridChild $row (New-WKStatusIcon -Status $c.Status) 0

        $text = New-WKStack -Margin (New-WKThickness 14 0 12 0)
        $text.VerticalAlignment = 'Center'
        [void]$text.Children.Add((New-WKText -Text $c.Title -SemiBold))
        [void]$text.Children.Add((New-WKText -Text $c.Detail -Brush 'MutedBrush' -Wrap -Size 12.5))
        Add-WKGridChild $row $text 1

        if ($c.ActionLabel -and $c.Status -ne 'Good') {
            $btn = New-WKButton -Content $c.ActionLabel -Style 'GhostBtn' -Tag $c.ActionTarget
            $btn.VerticalAlignment = 'Center'
            $btn.Add_Click({ Invoke-WKCheckAction -Target $this.Tag })
            Add-WKGridChild $row $btn 2
        }
        [void]$list.Children.Add($row)
        if ($i -lt $checks.Count - 1) { [void]$list.Children.Add((New-WKDivider)) }
    }
}

function Invoke-WKCheckAction {
    param([string]$Target)
    if ($Target.StartsWith('page:', [StringComparison]::Ordinal)) { Show-WKPage ($Target.Substring(5)); return }
    if ($Target.StartsWith('uri:', [StringComparison]::Ordinal)) { Open-WKExternal ($Target.Substring(4)) }
}

function Export-WKReportInteractive {
    if (-not $script:State.Health) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Save system report'
    $dialog.Filter = 'Web page (*.html)|*.html'
    $dialog.FileName = 'WinKit-Report-{0:yyyyMMdd}.html' -f (Get-Date)
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $dialog.ShowDialog($script:UI.Window)) { return }
    try {
        Export-WKReport -Health $script:State.Health -Path $dialog.FileName | Out-Null
        Show-WKToast 'Report saved. Opening it now.'
        Open-WKExternal $dialog.FileName
    }
    catch {
        Show-WKToast "Could not save the report: $($_.Exception.Message)" -Kind Error
    }
}
