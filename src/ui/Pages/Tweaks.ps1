function Initialize-WKTweaksPage {
    $config = $WK.Config.Tweaks

    foreach ($p in @($WK.Config.Profiles.profiles)) {
        $tile = New-Object System.Windows.Controls.Button
        $tile.Style = $script:UI.Window.FindResource('TileBtn')
        $tile.Margin = New-WKThickness 5 0 5 0
        $tile.Tag = $p.id
        $sp = New-Object System.Windows.Controls.DockPanel
        $sp.LastChildFill = $false
        $count = New-WKText -Text "$(@($p.tweaks).Count) tweaks" -Brush 'AccentBrush' -Size 11.5 -SemiBold -Margin (New-WKThickness 0 8 0 0)
        [System.Windows.Controls.DockPanel]::SetDock($count, 'Bottom')
        [void]$sp.Children.Add($count)
        $iconBox = New-Object System.Windows.Controls.Border
        $iconBox.Width = 34
        $iconBox.Height = 34
        $iconBox.CornerRadius = New-Object System.Windows.CornerRadius(9)
        $iconBox.HorizontalAlignment = 'Left'
        Set-WKBrush $iconBox ([System.Windows.Controls.Border]::BackgroundProperty) 'AccentSoftBrush'
        $icon = New-WKIcon -Code $p.icon -Brush 'AccentBrush' -Size 15
        $icon.HorizontalAlignment = 'Center'
        $iconBox.Child = $icon
        $name = New-WKText -Text $p.name -SemiBold -Margin (New-WKThickness 0 10 0 2)
        $desc = New-WKText -Text $p.description -Brush 'MutedBrush' -Size 12 -Wrap
        foreach ($el in $iconBox, $name, $desc) {
            [System.Windows.Controls.DockPanel]::SetDock($el, 'Top')
            [void]$sp.Children.Add($el)
        }
        $tile.Content = $sp
        $tile.VerticalContentAlignment = 'Stretch'
        $tile.Add_Click({ Select-WKProfile -Id $this.Tag })
        [void]$script:UI.TwProfiles.Children.Add($tile)
    }

    $chips = @(@{ Id = 'all'; Name = 'All' }) + @($config.categories | ForEach-Object { @{ Id = $_.id; Name = $_.name } })
    foreach ($c in $chips) {
        $chip = New-Object System.Windows.Controls.RadioButton
        $chip.Style = $script:UI.Window.FindResource('Chip')
        $chip.GroupName = 'TweakFilter'
        $chip.Content = $c.Name
        $chip.Tag = $c.Id
        if ($c.Id -eq 'all') { $chip.IsChecked = $true }
        $chip.Add_Checked({ Set-WKTweakFilter -Category $this.Tag })
        [void]$script:UI.TwFilters.Children.Add($chip)
    }

    $script:State.TweakSections = @{}
    foreach ($cat in @($config.categories)) {
        $tweaks = @(Get-WKTweak | Where-Object { $_.category -eq $cat.id })
        if (-not $tweaks.Count) { continue }

        $section = New-WKStack -Margin (New-WKThickness 0 16 0 0)
        $head = New-WKStack -Horizontal -Margin (New-WKThickness 2 0 0 10)
        [void]$head.Children.Add((New-WKIcon -Code $cat.icon -Brush 'AccentBrush' -Size 15))
        [void]$head.Children.Add((New-WKText -Text $cat.name -Style 'H2' -Margin (New-WKThickness 10 0 0 0)))
        [void]$head.Children.Add((New-WKText -Text "$($tweaks.Count)" -Brush 'MutedBrush' -Margin (New-WKThickness 8 2 0 0)))
        [void]$section.Children.Add($head)

        $card = New-WKCard -Padding (New-WKThickness 20 6 20 6)
        $rows = New-WKStack
        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            [void]$rows.Children.Add((New-WKTweakRow -Tweak $tweaks[$i]))
            if ($i -lt $tweaks.Count - 1) { [void]$rows.Children.Add((New-WKDivider)) }
        }
        $card.Child = $rows
        [void]$section.Children.Add($card)
        [void]$script:UI.TwList.Children.Add($section)
        $script:State.TweakSections[$cat.id] = $section
    }

    $script:UI.TwClear.Add_Click({ Clear-WKTweakSelection })
    $script:UI.TwApply.Add_Click({ Start-WKTweakOperation -Ids @($script:State.TweakSelection) -Operation Apply })
    $script:UI.TwUndo.Add_Click({ Start-WKTweakOperation -Ids @($script:State.TweakSelection) -Operation Undo })
    $script:UI.TwRefresh.Add_Click({ Update-WKTweakStates })
    Update-WKTweakSelectionText
}

function New-WKTweakRow {
    param(
        [Parameter(Mandatory)]$Tweak,
        [switch]$Compact
    )

    $grid = if ($Compact) { New-WKGrid -Columns '*', 'Auto', 'Auto' } else { New-WKGrid -Columns 'Auto', '*', 'Auto', 'Auto' }
    $grid.Margin = New-WKThickness 0 12 0 12
    $entry = @{ Tweak = $Tweak; CheckBox = $null; Button = $null; Pill = $null }

    $textCol = 0
    if (-not $Compact) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag = $Tweak.id
        $cb.VerticalAlignment = 'Top'
        $cb.Margin = New-WKThickness 0 2 14 0
        [System.Windows.Automation.AutomationProperties]::SetName($cb, "Select: $($Tweak.title)")
        $cb.ToolTip = "Select '$($Tweak.title)'"
        $cb.Add_Checked({ [void]$script:State.TweakSelection.Add($this.Tag); Update-WKTweakSelectionText })
        $cb.Add_Unchecked({ [void]$script:State.TweakSelection.Remove($this.Tag); Update-WKTweakSelectionText })
        Add-WKGridChild $grid $cb 0
        $entry.CheckBox = $cb
        $textCol = 1
    }

    $text = New-WKStack
    $titleLine = New-WKStack -Horizontal
    [void]$titleLine.Children.Add((New-WKText -Text $Tweak.title -SemiBold))
    if ($Tweak.risk -ne 'low') {
        $risk = New-WKPill -Text "$((Get-Culture).TextInfo.ToTitleCase($Tweak.risk)) risk" -Kind Warn -ToolTip 'Read the description before applying. It can be undone like any other tweak.'
        $risk.Margin = New-WKThickness 10 0 0 0
        [void]$titleLine.Children.Add($risk)
    }
    $restartText = @{ explorer = 'Restarts Explorer'; signout = 'Sign-out needed'; reboot = 'Restart needed' }[[string]$Tweak.restart]
    if ($restartText) {
        $rp = New-WKPill -Text $restartText -Kind Info
        $rp.Margin = New-WKThickness 8 0 0 0
        [void]$titleLine.Children.Add($rp)
    }
    [void]$text.Children.Add($titleLine)
    [void]$text.Children.Add((New-WKText -Text $Tweak.description -Brush 'MutedBrush' -Size 12.5 -Wrap -Margin (New-WKThickness 0 3 0 0)))

    $details = New-WKText -Text ((@($Tweak.actions) | ForEach-Object { Format-WKActionPlan -Action $_ }) -join "`n") -Brush 'MutedBrush' -Size 11.5 -Wrap
    $details.FontFamily = $script:UI.Window.FindResource('MonoFont')
    $detailsBox = New-Object System.Windows.Controls.Border
    $detailsBox.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $detailsBox.Padding = New-WKThickness 12 9 12 9
    $detailsBox.Margin = New-WKThickness 0 8 0 0
    $detailsBox.Visibility = 'Collapsed'
    Set-WKBrush $detailsBox ([System.Windows.Controls.Border]::BackgroundProperty) 'HoverBrush'
    $detailsBox.Child = $details

    $toggle = New-Object System.Windows.Controls.Primitives.ToggleButton
    $toggle.Style = $script:UI.Window.FindResource('GhostToggle')
    $toggle.Content = 'What exactly changes?'
    $toggle.FontSize = 12
    $toggle.HorizontalAlignment = 'Left'
    $toggle.Margin = New-WKThickness -8 4 0 0
    $toggle.Tag = $detailsBox
    $toggle.Add_Checked({ $this.Tag.Visibility = 'Visible' })
    $toggle.Add_Unchecked({ $this.Tag.Visibility = 'Collapsed' })
    [void]$text.Children.Add($toggle)
    [void]$text.Children.Add($detailsBox)
    Add-WKGridChild $grid $text $textCol

    # Hidden until the first state read arrives, so nothing looks stuck.
    $pill = New-WKPill -Text 'Checking' -Kind Neutral
    $pill.Visibility = 'Hidden'
    $pill.Margin = New-WKThickness 16 0 0 0
    $pill.VerticalAlignment = 'Top'
    Add-WKGridChild $grid $pill ($textCol + 1)
    $entry.Pill = $pill

    if ($Compact) {
        $btn = New-WKButton -Content 'Apply' -Style 'Btn' -Tag $Tweak.id -Margin (New-WKThickness 12 0 0 0)
        $btn.MinWidth = 76
        $btn.VerticalAlignment = 'Top'
        $btn.Add_Click({
            $state = $script:State.TweakStates[$this.Tag]
            $op = if ($state -and $state.State -in 'Applied', 'Partial') { 'Undo' } else { 'Apply' }
            Start-WKTweakOperation -Ids @($this.Tag) -Operation $op
        })
        Add-WKGridChild $grid $btn 2
        $entry.Button = $btn
    }

    if (-not $script:State.TweakRows.ContainsKey($Tweak.id)) { $script:State.TweakRows[$Tweak.id] = New-Object System.Collections.ArrayList }
    [void]$script:State.TweakRows[$Tweak.id].Add($entry)
    return $grid
}

function Set-WKTweakFilter {
    param([string]$Category)
    foreach ($id in $script:State.TweakSections.Keys) {
        $script:State.TweakSections[$id].Visibility = if ($Category -eq 'all' -or $Category -eq $id) { 'Visible' } else { 'Collapsed' }
    }
}

function Update-WKTweakSelectionText {
    $n = $script:State.TweakSelection.Count
    $script:UI.TwSelCount.Text = if ($n) { "$n selected" } else { 'Pick a profile or select tweaks individually' }
    $script:UI.TwApply.IsEnabled = $n -gt 0
    $script:UI.TwUndo.IsEnabled = $n -gt 0
}

function Clear-WKTweakSelection {
    foreach ($id in @($script:State.TweakSelection)) {
        foreach ($e in $script:State.TweakRows[$id]) { if ($e.CheckBox) { $e.CheckBox.IsChecked = $false } }
    }
    $script:State.TweakSelection.Clear()
    Update-WKTweakSelectionText
}

function Select-WKProfile {
    param([Parameter(Mandatory)][string]$Id)
    $p = @($WK.Config.Profiles.profiles) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $p) { return }
    if (-not $script:State.TweakStates.Count) {
        # The first state read is still running; select once it arrives so
        # tweaks that are already on are left out.
        $script:State.PendingProfile = $Id
        Show-WKToast "Reading current settings. $($p.name) will be selected when that finishes." -Kind Info
        return
    }
    Clear-WKTweakSelection
    $selected = 0
    $already = 0
    foreach ($tid in @($p.tweaks)) {
        $state = $script:State.TweakStates[$tid]
        if ($state -and $state.State -eq 'Unavailable') { continue }
        if ($state -and $state.State -eq 'Applied') { $already++; continue }
        foreach ($e in @($script:State.TweakRows[$tid])) { if ($e.CheckBox) { $e.CheckBox.IsChecked = $true } }
        $selected++
    }
    foreach ($chip in $script:UI.TwFilters.Children) { if ($chip.Tag -eq 'all') { $chip.IsChecked = $true } }
    if (-not $selected) {
        Show-WKToast "$($p.name): every tweak in this profile is already on." -Kind Info
        return
    }
    $msg = "$($p.name): $(Format-WKCount $selected 'tweak') selected."
    if ($already) { $msg += " $already already on." }
    Show-WKToast "$msg Review them, then press Apply." -Kind Info
}

function Show-WKTweakStates {
    param([object[]]$States)

    foreach ($s in $States) {
        $script:State.TweakStates[$s.Id] = $s
        foreach ($e in @($script:State.TweakRows[$s.Id])) {
            $e.Pill.Visibility = 'Visible'
            switch ($s.State) {
                'Applied'     { Set-WKPill -Pill $e.Pill -Text 'Applied' -Kind Good }
                'Partial'     { Set-WKPill -Pill $e.Pill -Text 'Partly applied' -Kind Warn -ToolTip 'Some of the settings in this tweak are already set, others are not.' }
                'NotApplied'  { Set-WKPill -Pill $e.Pill -Text 'Not applied' -Kind Neutral }
                'Unavailable' { Set-WKPill -Pill $e.Pill -Text 'Not available' -Kind Neutral -ToolTip $s.Reason }
            }
            if ($e.CheckBox) {
                $e.CheckBox.IsEnabled = ($s.State -ne 'Unavailable')
                if ($s.State -eq 'Unavailable' -and $e.CheckBox.IsChecked) { $e.CheckBox.IsChecked = $false }
            }
            if ($e.Button) {
                $e.Button.IsEnabled = ($s.State -ne 'Unavailable')
                # A partly applied tweak may hold the user's own choices, so it
                # offers Apply; changes WinKit made can be undone from History.
                $e.Button.Content = if ($s.State -eq 'Applied') { 'Undo' } else { 'Apply' }
            }
        }
    }
}

function Update-WKTweakStates {
    [void](Start-WKTask -Name 'Reading current settings' -Queue -Script {
        @(Get-WKAllTweakStates)
    } -OnDone {
        param($out)
        Show-WKTweakStates -States @($out | Where-Object { $_ -and $_.PSObject.Properties['State'] })
        if ($script:State.PendingProfile) {
            $id = $script:State.PendingProfile
            $script:State.PendingProfile = $null
            Select-WKProfile -Id $id
        }
    } -OnFail {
        foreach ($rows in $script:State.TweakRows.Values) {
            foreach ($e in $rows) {
                $e.Pill.Visibility = 'Visible'
                Set-WKPill -Pill $e.Pill -Text 'Unknown' -Kind Neutral -ToolTip 'This setting could not be read. Press Refresh to try again.'
            }
        }
    })
}

function Start-WKTweakOperation {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Undo')][string]$Operation,
        [switch]$SkipRestorePoint,
        [switch]$NoConfirm
    )

    $ids = @($Ids | Where-Object {
        $s = $script:State.TweakStates[$_]
        -not ($s -and $s.State -eq 'Unavailable')
    })
    if (-not $ids.Count) { Show-WKToast 'Nothing to do: the selected tweaks are not available on this PC.' -Kind Info; return }
    if (-not (Test-WKCanStartAction)) { return }

    if (-not $NoConfirm) {
        $tweaks = @($ids | ForEach-Object { Get-WKTweak -Id $_ })
        $risky = @($tweaks | Where-Object { $_.risk -ne 'low' } | ForEach-Object title)
        $restarts = @($tweaks | ForEach-Object restart | Where-Object { $_ -and $_ -ne 'none' } | Sort-Object -Unique)

        $lines = New-Object System.Collections.Generic.List[string]
        if ($Operation -eq 'Apply') {
            $lines.Add("WinKit will record the current value of every setting first, so each tweak can be undone later.")
        }
        else {
            $lines.Add("Settings changed by WinKit go back to their previous values. Tweaks applied outside WinKit are set to the Windows default.")
        }
        if ($risky.Count -and $Operation -eq 'Apply') { $lines.Add("`nMedium risk: $($risky -join ', ').") }
        if ($restarts -contains 'reboot') { $lines.Add("`nSome changes take effect after a restart.") }
        elseif ($restarts -contains 'signout') { $lines.Add("`nSome changes take effect after you sign out.") }
        if ($WK.Settings.CreateRestorePoint -and -not $WK.RestorePointDone -and -not $WK.PreviewMode -and -not $WK.Windows.IsServer) {
            $lines.Add("`nA System Restore point is created first. This can take a minute.")
        }

        $verb = if ($Operation -eq 'Apply') { 'Apply' } else { 'Undo' }
        $answer = Show-WKDialog -Title "$verb $(Format-WKCount $ids.Count 'tweak')?" -Message ($lines -join "`n") -Buttons 'Cancel', $verb -Primary $verb -Action
        if ($answer -ne $verb) { return }
    }

    $name = if ($Operation -eq 'Apply') { 'Applying tweaks' } else { 'Undoing tweaks' }
    [void](Start-WKTask -Name $name -Arguments @{
            Ids = $ids; Operation = $Operation; Preview = [bool]$WK.PreviewMode; Skip = [bool]$SkipRestorePoint
        } -Script {
            param($Ids, $Operation, $Preview, $Skip)
            $r = Invoke-WKTweakBatch -Ids $Ids -Operation $Operation -Preview:$Preview -SkipRestorePoint:$Skip
            # What was asked for travels with the result, so the completion
            # never depends on state that a later action may have changed.
            $r | Add-Member -NotePropertyName Ids -NotePropertyValue @($Ids)
            $r | Add-Member -NotePropertyName Operation -NotePropertyValue $Operation
            $r | Add-Member -NotePropertyName Preview -NotePropertyValue ([bool]$Preview)
            $r
        } -OnDone {
            param($out)
            $r = $out | Where-Object { $_ -and $_.PSObject.Properties['Status'] } | Select-Object -Last 1
            if (-not $r) { Update-WKTweakStates; return }
            Complete-WKTweakOperation -Result $r
        } -OnFail {
            Update-WKTweakStates
        })
}

function Complete-WKTweakOperation {
    param($Result)
    $op = @{ Ids = @($Result.Ids); Operation = $Result.Operation }

    if ($Result.Status -eq 'RestorePointFailed') {
        $answer = Show-WKDialog -Title 'Restore point could not be created' -Buttons 'Cancel', 'Continue without', 'Turn on and retry' -Primary 'Turn on and retry' `
            -Message "$($Result.Message)`n`nThis usually means System Protection is off for drive $($env:SystemDrive). WinKit's own undo still works either way."
        switch ($answer) {
            'Turn on and retry' {
                [void](Start-WKTask -Name 'Turning on System Protection' -Arguments @{ Ids = $op.Ids; Operation = $op.Operation } -Script {
                    param($Ids, $Operation)
                    Enable-WKSystemProtection
                    [pscustomobject]@{ RetryIds = @($Ids); RetryOperation = $Operation }
                } -OnDone {
                    param($out)
                    $retry = @($out | Where-Object { $_ -and $_.PSObject.Properties['RetryIds'] }) | Select-Object -Last 1
                    if ($retry) { Start-WKTweakOperation -Ids $retry.RetryIds -Operation $retry.RetryOperation -NoConfirm }
                })
            }
            'Continue without' {
                # Do not ask again for the rest of this session.
                $WK.RestorePointDone = $true
                Start-WKTweakOperation -Ids $op.Ids -Operation $op.Operation -SkipRestorePoint -NoConfirm
            }
        }
        return
    }

    Update-WKTweakStates
    if ($script:State.Visited.Contains('history')) { Update-WKHistoryPage }
    if ($op.Ids -contains 'developer.wsl' -and $script:State.Visited.Contains('developer')) { Update-WKDeveloperPage }

    if ($Result.Preview) {
        $script:UI.ActivityToggle.IsChecked = $true
        Show-WKToast 'Preview finished. Nothing was changed; see Activity for details.' -Kind Info
        return
    }
    if ($Result.Failed) { Show-WKToast "$(Format-WKCount $Result.Changed 'change') made, $($Result.Failed) failed. See Activity." -Kind Warning }
    elseif ($Result.Changed) { Show-WKToast "$(Format-WKCount $Result.Changed 'setting') changed." }
    else { Show-WKToast 'Everything was already in the requested state.' -Kind Info }

    Clear-WKTweakSelection
    $restart = @($Result.Restart)
    if ($restart -contains 'reboot') {
        $a = Show-WKDialog -Title 'Restart to finish' -Buttons 'Later', 'Restart now' -Primary 'Restart now' -NoDefault `
            -Message 'Some changes take effect after Windows restarts. Save your work in other apps first: restarting closes them.'
        if ($a -eq 'Restart now') { Restart-Computer -Force }
    }
    elseif ($restart -contains 'explorer' -or $restart -contains 'signout') {
        $note = if ($restart -contains 'signout') { "`n`nA few changes also need you to sign out and back in." } else { '' }
        $a = Show-WKDialog -Title 'Restart File Explorer?' -Buttons 'Later', 'Restart Explorer' -Primary 'Restart Explorer' `
            -Message "Taskbar and File Explorer changes appear after Explorer restarts. Open Explorer windows will close.$note"
        if ($a -eq 'Restart Explorer') {
            [void](Start-WKTask -Name 'Restarting File Explorer' -Script { Restart-WKExplorer })
        }
    }
}
