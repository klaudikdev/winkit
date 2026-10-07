function Initialize-WKHistoryPage {
    $script:UI.HiLogs.Add_Click({ Open-WKExternal $WK.LogDir })
    $script:UI.HiSystemRestore.Add_Click({
        try { Start-Process -FilePath (Get-WKSystemTool 'rstrui.exe') } catch { Show-WKToast 'System Restore could not be opened.' -Kind Error }
    })
    $script:UI.HiRestorePoint.Add_Click({
        if ($WK.PreviewMode) { Write-WKLog '[Preview] Checkpoint-Computer' -Level Step; Show-WKToast 'Preview: no restore point was created.' -Kind Info; return }
        [void](Start-WKTask -Name 'Creating a restore point' -Script {
            try { New-WKRestorePoint -Description 'Klaudik WinKit (manual)'; $true }
            catch { Write-WKLog $_.Exception.Message -Level Error; $false }
        } -OnDone {
            param($out)
            if ($out | Select-Object -Last 1) { Show-WKToast 'Restore point created.' }
            else {
                $a = Show-WKDialog -Title 'Restore point could not be created' -Buttons 'Cancel', 'Turn on System Protection' -Primary 'Turn on System Protection' `
                    -Message "System Protection may be off for drive $($env:SystemDrive). Turn it on and try again?"
                if ($a -eq 'Turn on System Protection') {
                    [void](Start-WKTask -Name 'Turning on System Protection' -Script { Enable-WKSystemProtection } -OnDone {
                        Show-WKToast 'System Protection is on. Press "Create restore point" again.' -Kind Info
                    })
                }
            }
        })
    })
}

function Update-WKHistoryPage {
    # Newest first, in the order the changes were made.
    $all = @(Get-WKHistory)
    $entries = for ($i = $all.Count - 1; $i -ge 0; $i--) { $all[$i] }
    $entries = @($entries)
    # The interface is in English; so are its dates.
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $list = $script:UI.HiList
    $list.Children.Clear()
    $script:UI.HiEmpty.Visibility = if ($entries.Count) { 'Collapsed' } else { 'Visible' }

    $currentDay = $null
    foreach ($e in $entries) {
        $time = Get-Date
        try { $time = [datetime]$e.time } catch { }
        $day = $time.Date
        if ($day -ne $currentDay) {
            $label = if ($day -eq (Get-Date).Date) { 'Today' } elseif ($day -eq (Get-Date).Date.AddDays(-1)) { 'Yesterday' } else { $day.ToString('D', $culture) }
            [void]$list.Children.Add((New-WKText -Text $label.ToUpperInvariant() -Style 'Caption' -Margin (New-WKThickness 2 14 0 8)))
            $currentDay = $day
        }

        $card = New-WKCard -Margin (New-WKThickness 0 0 0 8) -Padding (New-WKThickness 18 14 18 14)
        $outer = New-WKStack
        $row = New-WKGrid -Columns 'Auto', '*', 'Auto'

        $status = if ($e.reverted) { 'Neutral' } elseif ($e.kind -eq 'dns') { 'Network' } else { 'Accent' }
        Add-WKGridChild $row (New-WKStatusIcon -Status $status -Size 34) 0

        $text = New-WKStack -Margin (New-WKThickness 14 0 12 0)
        $text.VerticalAlignment = 'Center'
        [void]$text.Children.Add((New-WKText -Text $e.title -SemiBold))
        $changes = @($e.changes).Count
        $sub = "$($time.ToString('t', $culture))  |  $(Format-WKCount $changes 'change')"
        if ($e.reverted -and $e.revertedAt) {
            try { $sub += "  |  undone $(([datetime]$e.revertedAt).ToString('g', $culture))" } catch { $sub += '  |  undone' }
        }
        [void]$text.Children.Add((New-WKText -Text $sub -Brush 'MutedBrush' -Size 12.5))
        Add-WKGridChild $row $text 1

        $actions = New-WKStack -Horizontal
        $actions.VerticalAlignment = 'Center'
        $details = New-Object System.Windows.Controls.Primitives.ToggleButton
        $details.Style = $script:UI.Window.FindResource('GhostToggle')
        $details.Content = 'Details'
        $details.Margin = New-WKThickness 0 0 8 0
        [void]$actions.Children.Add($details)
        if ($e.reverted) {
            [void]$actions.Children.Add((New-WKPill -Text 'Undone' -Kind Neutral))
        }
        else {
            $undo = New-WKButton -Content 'Undo' -Tag $e.id
            $undo.Add_Click({ Undo-WKHistoryInteractive -Id $this.Tag })
            [void]$actions.Children.Add($undo)
        }
        Add-WKGridChild $row $actions 2
        [void]$outer.Children.Add($row)

        $lines = (@($e.changes) | ForEach-Object { Format-WKChange -Change $_ }) -join "`n"
        $box = New-Object System.Windows.Controls.Border
        $box.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $box.Padding = New-WKThickness 12 9 12 9
        $box.Margin = New-WKThickness 48 12 0 0
        $box.Visibility = 'Collapsed'
        Set-WKBrush $box ([System.Windows.Controls.Border]::BackgroundProperty) 'HoverBrush'
        $mono = New-WKText -Text $lines -Brush 'MutedBrush' -Size 11.5 -Wrap
        $mono.FontFamily = $script:UI.Window.FindResource('MonoFont')
        $box.Child = $mono
        [void]$outer.Children.Add($box)
        $details.Tag = $box
        $details.Add_Checked({ $this.Tag.Visibility = 'Visible' })
        $details.Add_Unchecked({ $this.Tag.Visibility = 'Collapsed' })

        $card.Child = $outer
        [void]$list.Children.Add($card)
    }
}

function Undo-WKHistoryInteractive {
    param([string]$Id)
    if (-not (Test-WKCanStartAction)) { return }
    $entry = @(Get-WKHistory) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $entry) { return }
    $answer = Show-WKDialog -Title "Undo '$($entry.title)'?" -Buttons 'Cancel', 'Undo' -Primary 'Undo' -Action `
        -Message "$(Format-WKCount @($entry.changes).Count 'setting') in this entry go back to the values recorded before the change was made."
    if ($answer -ne 'Undo') { return }

    [void](Start-WKTask -Name 'Undoing change' -Arguments @{ Id = $Id; Preview = [bool]$WK.PreviewMode } -Script {
        param($Id, $Preview)
        $entry = @(Get-WKHistory) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        $ok = $false
        if ($entry -and $Preview) {
            Write-WKLog "[Preview] Would undo '$($entry.title)'" -Level Step
            foreach ($c in @($entry.changes)) { Write-WKLog "  [Preview] Restore $(Format-WKChange $c)" }
            $ok = $true
        }
        elseif ($entry) { $ok = [bool](Undo-WKHistoryEntry -Entry $entry) }
        [pscustomobject]@{ Preview = [bool]$Preview; Ok = $ok }
    } -OnDone {
        param($out)
        $done = @($out | Where-Object { $_ -and $_.PSObject.Properties['Ok'] }) | Select-Object -Last 1
        $ok = $done -and $done.Ok
        if ($done -and $done.Preview) { $script:UI.ActivityToggle.IsChecked = $true; Show-WKToast 'Preview finished. Nothing was changed; see Activity for details.' -Kind Info }
        elseif ($ok) { Show-WKToast 'Change undone.' }
        else { Show-WKToast 'Some settings could not be restored. See Activity.' -Kind Warning }
        Update-WKHistoryPage
        if ($script:State.Visited.Contains('tweaks') -or $script:State.Visited.Contains('developer')) { Update-WKTweakStates }
        if ($script:State.Visited.Contains('network')) { Update-WKDnsOverview }
    })
}
