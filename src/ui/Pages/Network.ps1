function Initialize-WKNetworkPage {
    $script:UI.NetLatencyRun.Add_Click({ Start-WKLatencyTest })
    $script:UI.NetBestPromo.Add_Click({ Open-WKExternal $WK.Website })
    $script:UI.NetDnsBench.Add_Click({ Start-WKDnsBenchmark })
    $script:UI.NetDnsFlush.Add_Click({
        if ($WK.PreviewMode) { Write-WKLog '[Preview] Clear-DnsClientCache' -Level Step; Show-WKToast 'Preview: the cache was not flushed.' -Kind Info; return }
        try { Clear-WKDnsCache; Show-WKToast 'DNS cache flushed.' } catch { Show-WKToast $_.Exception.Message -Kind Error }
    })

    foreach ($p in @($WK.Config.Network.dnsProviders)) {
        $b = New-WKButton -Content $p.name -Tag $p.id -Margin (New-WKThickness 0 0 8 8) -ToolTip "$($p.description)`n$(@($p.ipv4) -join ', ')"
        $b.Add_Click({ Set-WKDnsInteractive -ProviderId $this.Tag })
        [void]$script:UI.NetDnsProviders.Children.Add($b)
    }
    $auto = New-WKButton -Content 'Automatic (DHCP)' -Style 'GhostBtn' -Tag 'automatic' -Margin (New-WKThickness 0 0 8 8) -ToolTip 'Use the DNS servers your router or network provides'
    $auto.Add_Click({ Set-WKDnsInteractive -ProviderId $this.Tag })
    [void]$script:UI.NetDnsProviders.Children.Add($auto)
}

function New-WKBarRow {
    <# A label, a proportional bar and a value, used by both benchmarks. #>
    param(
        [string]$Title,
        [string]$Subtitle,
        $Ms,
        [double]$Max,
        [switch]$Highlight
    )

    $row = New-WKGrid -Columns '176', '*', '64'
    $row.Margin = New-WKThickness 0 5 0 5

    $label = New-WKStack -Horizontal
    $label.VerticalAlignment = 'Center'
    [void]$label.Children.Add((New-WKText -Text $Title -SemiBold -Size 12.5))
    if ($Subtitle) { [void]$label.Children.Add((New-WKText -Text $Subtitle -Brush 'MutedBrush' -Size 12 -Trim -Margin (New-WKThickness 6 0 0 0))) }
    Add-WKGridChild $row $label 0

    $track = New-Object System.Windows.Controls.Border
    $track.Height = 8
    $track.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $track.Margin = New-WKThickness 8 0 10 0
    Set-WKBrush $track ([System.Windows.Controls.Border]::BackgroundProperty) 'TrackBrush'
    $fillHost = New-WKGrid -Columns '*'
    if ($null -ne $Ms) {
        $fraction = [math]::Max(0.03, [math]::Min(1.0, [double]$Ms / [math]::Max(1.0, $Max)))
        $fillHost.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength($fraction, 'Star')
        $rest = New-Object System.Windows.Controls.ColumnDefinition
        $rest.Width = New-Object System.Windows.GridLength((1 - $fraction), 'Star')
        [void]$fillHost.ColumnDefinitions.Add($rest)
        $fill = New-Object System.Windows.Controls.Border
        $fill.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $key = if ($Highlight) { 'AccentBrush' } elseif ($Ms -lt 60) { 'GoodBrush' } elseif ($Ms -lt 150) { 'WarnBrush' } else { 'BadBrush' }
        Set-WKBrush $fill ([System.Windows.Controls.Border]::BackgroundProperty) $key
        Add-WKGridChild $fillHost $fill 0
    }
    $track.Child = $fillHost
    $track.VerticalAlignment = 'Center'
    Add-WKGridChild $row $track 1

    $valueText = if ($null -ne $Ms) { "$Ms ms" } else { 'no reply' }
    $value = New-WKText -Text $valueText -SemiBold -Size 12.5 -Brush $(if ($null -ne $Ms) { 'TextBrush' } else { 'MutedBrush' })
    $value.HorizontalAlignment = 'Right'
    $value.VerticalAlignment = 'Center'
    Add-WKGridChild $row $value 2
    return $row
}

function Start-WKLatencyTest {
    [void](Start-WKTask -Name 'Measuring cloud latency' -Queue -Script {
        @(Test-WKCloudLatency)
    } -OnDone {
        param($out)
        Show-WKLatency -Results @($out | Where-Object { $_ -and $_.PSObject.Properties['Ms'] })
    })
}

function Show-WKLatency {
    param([object[]]$Results)

    $left = $script:UI.NetLatencyLeft
    $right = $script:UI.NetLatencyRight
    $left.Children.Clear()
    $right.Children.Clear()

    $ok = @($Results | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
    $failed = @($Results | Where-Object { $null -eq $_.Ms })
    $ordered = @($ok) + @($failed)
    if (-not $ordered.Count) { return }
    $max = if ($ok.Count) { [double]($ok | Select-Object -Last 1).Ms } else { 1 }

    $best = $ok | Select-Object -First 1
    if ($best) {
        $script:UI.NetBest.Visibility = 'Visible'
        $script:UI.NetBestText.Text = "Closest region: $($best.Provider) $($best.Location) ($($best.Region)) at $($best.Ms) ms"
    }

    $half = [math]::Ceiling($ordered.Count / 2)
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $r = $ordered[$i]
        $row = New-WKBarRow -Title $r.Provider -Subtitle $r.Location -Ms $r.Ms -Max $max -Highlight:($best -and $r -eq $best)
        $row.ToolTip = "$($r.Provider) $($r.Region) ($($r.Host))"
        if ($i -lt $half) { [void]$left.Children.Add($row) } else { [void]$right.Children.Add($row) }
    }
}

function Update-WKDnsOverview {
    [void](Start-WKTask -Name 'Reading DNS settings' -Queue -Script {
        @(Get-WKDnsOverview)
    } -OnDone {
        param($out)
        Show-WKDnsOverview -Adapters @($out | Where-Object { $_ -and $_.PSObject.Properties['Alias'] })
    })
}

function Show-WKDnsOverview {
    param([object[]]$Adapters)
    $panel = $script:UI.NetDnsCurrent
    $panel.Children.Clear()
    if (-not $Adapters.Count) {
        [void]$panel.Children.Add((New-WKText -Text 'No connected network adapter found.' -Brush 'MutedBrush'))
        return
    }
    foreach ($a in $Adapters) {
        $row = New-WKGrid -Columns 'Auto', '*', 'Auto'
        $row.Margin = New-WKThickness 0 4 0 4
        $iconCode = if ($a.Alias -match 'Wi-?Fi|Wireless|WLAN') { 'E701' } else { 'E839' }
        $icon = New-WKIcon -Code $iconCode -Brush 'MutedBrush' -Size 15
        Add-WKGridChild $row $icon 0
        $text = New-WKStack -Horizontal -Margin (New-WKThickness 12 0 0 0)
        [void]$text.Children.Add((New-WKText -Text $a.Alias -SemiBold))
        $servers = if (@($a.Effective).Count) { @($a.Effective) -join ', ' } else { 'none' }
        [void]$text.Children.Add((New-WKText -Text $servers -Brush 'MutedBrush' -Size 12.5 -Trim -Margin (New-WKThickness 10 1 0 0)))
        Add-WKGridChild $row $text 1
        $kind = if ($a.Provider -eq 'Automatic') { 'Neutral' } elseif ($a.Provider -eq 'Custom') { 'Info' } else { 'Accent' }
        Add-WKGridChild $row (New-WKPill -Text $a.Provider -Kind $kind) 2
        [void]$panel.Children.Add($row)
    }
}

function Set-WKDnsInteractive {
    param([string]$ProviderId)
    $name = if ($ProviderId -eq 'automatic') { 'automatic (DHCP)' } else { (@($WK.Config.Network.dnsProviders) | Where-Object { $_.id -eq $ProviderId }).name }
    $answer = Show-WKDialog -Title "Switch DNS to $name?" -Buttons 'Cancel', 'Switch' -Primary 'Switch' -Action `
        -Message 'All connected network adapters are updated. The previous servers are saved in History, so you can switch back at any time.'
    if ($answer -ne 'Switch') { return }

    [void](Start-WKTask -Name 'Changing DNS' -Arguments @{ Id = $ProviderId; Preview = [bool]$WK.PreviewMode } -Script {
        param($Id, $Preview)
        $r = Set-WKDnsProvider -ProviderId $Id -Preview:$Preview
        # The preview flag travels with the result: the toggle may have
        # changed while the task ran.
        [pscustomobject]@{ Preview = [bool]$Preview; Result = $r }
    } -OnDone {
        param($out)
        $done = @($out | Where-Object { $_ -and $_.PSObject.Properties['Preview'] }) | Select-Object -Last 1
        if (-not $done -or $done.Preview) { $script:UI.ActivityToggle.IsChecked = $true; Show-WKToast 'Preview finished. Nothing was changed; see Activity for details.' -Kind Info }
        elseif ($done.Result -and $done.Result.Failed) { $script:UI.ActivityToggle.IsChecked = $true; Show-WKToast 'DNS could not be changed on every adapter. See Activity for details.' -Kind Warning }
        elseif ($done.Result -and -not $done.Result.Changed) { Show-WKToast 'Nothing to change. DNS was already set this way.' -Kind Info }
        else { Show-WKToast 'DNS updated.' }
        Update-WKDnsOverview
    } -OnFail {
        param($err)
        $script:UI.ActivityToggle.IsChecked = $true
        Show-WKToast "DNS was not changed: $err" -Kind Error
        Update-WKDnsOverview
    })
}

function Start-WKDnsBenchmark {
    [void](Start-WKTask -Name 'Benchmarking DNS' -Script {
        @(Test-WKDnsBenchmark)
    } -OnDone {
        param($out)
        $results = @($out | Where-Object { $_ -and $_.PSObject.Properties['Ms'] })
        $panel = $script:UI.NetDnsBenchList
        $panel.Children.Clear()
        [void]$panel.Children.Add((New-WKText -Text 'MEDIAN LOOKUP TIME' -Style 'Caption' -Margin (New-WKThickness 0 12 0 6)))
        $ok = @($results | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
        $max = if ($ok.Count) { [double]($ok | Select-Object -Last 1).Ms } else { 1 }
        $best = $ok | Where-Object { $_.Id -ne 'current' } | Select-Object -First 1
        foreach ($r in @($ok) + @($results | Where-Object { $null -eq $_.Ms })) {
            $row = New-WKBarRow -Title $r.Name -Ms $r.Ms -Max $max -Highlight:($best -and $r.Id -eq $best.Id)
            [void]$panel.Children.Add($row)
        }
        if ($best) { Show-WKToast "$($best.Name) answered fastest from your connection." -Kind Info }
    })
}
