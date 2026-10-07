function Initialize-WKAppsPage {
    $script:State.AppTiles = @{}
    $script:State.AppGroups = @()
    $catalog = $WK.Config.Apps

    # Filter chips
    $filters = @('All', 'Selected', 'Installed') + @($catalog.categories)
    foreach ($f in $filters) {
        $chip = New-Object System.Windows.Controls.RadioButton
        $chip.Style = $script:UI.Window.FindResource('Chip')
        $chip.GroupName = 'AppFilter'
        $chip.Content = $f
        $chip.Tag = $f
        if ($f -eq 'All') { $chip.IsChecked = $true }
        $chip.Add_Checked({
            $script:State.AppFilter = $this.Tag
            Update-WKAppsFilter
        })
        [void]$script:UI.AppsFilters.Children.Add($chip)
    }
    $script:State.AppFilter = 'All'

    # One group per category
    foreach ($cat in @($catalog.categories)) {
        $group = New-WKStack -Margin (New-WKThickness 0 18 0 0)
        $header = New-WKText -Text $cat -Style 'H2' -Margin (New-WKThickness 0 0 0 10)
        [void]$group.Children.Add($header)
        # Columns follow the window width (see Update-WKAppsColumns).
        $wrap = New-Object System.Windows.Controls.Primitives.UniformGrid
        $wrap.Columns = 3
        $wrap.Margin = New-WKThickness 0 0 -12 0
        [void]$group.Children.Add($wrap)
        [void]$script:UI.AppsList.Children.Add($group)
        $script:State.AppGroups += @{ Category = $cat; Panel = $group; Wrap = $wrap }

        foreach ($app in @($catalog.apps | Where-Object { $_.category -eq $cat })) {
            $tile = New-Object System.Windows.Controls.Primitives.ToggleButton
            $tile.Style = $script:UI.Window.FindResource('SelectTile')
            $tile.Margin = New-WKThickness 0 0 12 12
            $tile.Tag = $app.id
            $tile.ToolTip = "$($app.description)`nwinget id: $($app.id)"

            $body = New-WKStack
            $title = New-WKGrid -Columns '*', 'Auto'
            Add-WKGridChild $title (New-WKText -Text $app.name -SemiBold -Trim) 0
            $pill = New-WKPill -Text 'Installed' -Kind Good
            $pill.Visibility = 'Collapsed'
            $pill.Margin = New-WKThickness 6 0 0 0
            Add-WKGridChild $title $pill 1
            [void]$body.Children.Add($title)
            [void]$body.Children.Add((New-WKText -Text $app.description -Brush 'MutedBrush' -Size 12.5 -Trim -Margin (New-WKThickness 0 3 0 0)))
            $tile.Content = $body

            $tile.Add_Checked({ [void]$script:State.AppSelection.Add($this.Tag); Update-WKAppsSelectionText })
            $tile.Add_Unchecked({ [void]$script:State.AppSelection.Remove($this.Tag); Update-WKAppsSelectionText })
            [void]$wrap.Children.Add($tile)

            $script:State.AppTiles[$app.id] = @{
                Tile   = $tile
                Pill   = $pill
                App    = $app
                Search = ("$($app.name) $($app.description) $($app.id) $($app.category)").ToLowerInvariant()
            }
        }
    }

    $script:UI.AppsList.Add_SizeChanged({ Update-WKAppsColumns })
    $script:UI.AppsSearch.Tag = "Search $(@($catalog.apps).Count) apps"
    $script:UI.AppsSearch.Add_TextChanged({ Update-WKAppsFilter })
    $script:UI.AppsClear.Add_Click({ Clear-WKAppSelection })
    $script:UI.AppsInstall.Add_Click({ Invoke-WKAppsAction -Verb install })
    $script:UI.AppsUninstall.Add_Click({ Invoke-WKAppsAction -Verb uninstall })
    $script:UI.AppsUpdateAll.Add_Click({ Invoke-WKAppsUpdateAll })
    $script:UI.AppsRefresh.Add_Click({ Update-WKAppsInstalled })
    $script:UI.AppsExport.Add_Click({ Export-WKAppsInteractive })
    $script:UI.AppsImport.Add_Click({ Import-WKAppsInteractive })
    Update-WKAppsSelectionText
}

function Update-WKAppsColumns {
    $width = $script:UI.AppsList.ActualWidth
    if ($width -le 0) { return }
    $columns = [math]::Max(2, [math]::Floor(($width + 12) / 290))
    foreach ($g in $script:State.AppGroups) {
        if ($g.Wrap.Columns -ne $columns) { $g.Wrap.Columns = $columns }
    }
}

function Update-WKAppsFilter {
    $query = $script:UI.AppsSearch.Text.Trim().ToLowerInvariant()
    $filter = $script:State.AppFilter
    $visibleTotal = 0
    foreach ($g in $script:State.AppGroups) {
        $visible = 0
        foreach ($tile in $g.Wrap.Children) {
            $info = $script:State.AppTiles[$tile.Tag]
            $show = $true
            if ($query -and -not $info.Search.Contains($query)) { $show = $false }
            switch ($filter) {
                'All'       { }
                'Selected'  { if (-not $script:State.AppSelection.Contains($tile.Tag)) { $show = $false } }
                'Installed' { if (-not $script:State.Installed.Contains($tile.Tag)) { $show = $false } }
                default     { if ($info.App.category -ne $filter) { $show = $false } }
            }
            $tile.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
            if ($show) { $visible++ }
        }
        $g.Panel.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
        $visibleTotal += $visible
    }
    $script:UI.AppsEmpty.Visibility = if ($visibleTotal) { 'Collapsed' } else { 'Visible' }
    $script:UI.AppsEmpty.Text = if ($filter -eq 'Installed' -and -not $script:State.InstalledLoaded) { 'Still checking which apps are installed...' } else { 'No apps match your search.' }
}

function Update-WKAppsSelectionText {
    $n = $script:State.AppSelection.Count
    $installed = @($script:State.AppSelection | Where-Object { $script:State.Installed.Contains($_) }).Count
    $script:UI.AppsSelCount.Text = if ($n -eq 0) { 'Select apps to install or remove' }
                                   elseif ($installed) { "$n selected  |  $installed already installed" }
                                   else { "$n selected" }
    $script:UI.AppsInstall.IsEnabled = ($n -gt 0)
    $script:UI.AppsUninstall.IsEnabled = ($installed -gt 0)
    $script:UI.AppsExport.IsEnabled = ($n -gt 0)
}

function Clear-WKAppSelection {
    foreach ($id in @($script:State.AppSelection)) { $script:State.AppTiles[$id].Tile.IsChecked = $false }
    $script:State.AppSelection.Clear()
    Update-WKAppsSelectionText
}

function Set-WKInstalledApps {
    param([string[]]$Ids)
    $script:State.Installed.Clear()
    foreach ($id in $Ids) { [void]$script:State.Installed.Add($id) }
    $script:State.InstalledLoaded = $true
    foreach ($key in $script:State.AppTiles.Keys) {
        $script:State.AppTiles[$key].Pill.Visibility = if ($script:State.Installed.Contains($key)) { 'Visible' } else { 'Collapsed' }
    }
    Update-WKAppsSelectionText
    Update-WKAppsFilter
    Update-WKStackInstalledMarks
}

function Update-WKAppsInstalled {
    [void](Start-WKTask -Name 'Checking installed apps' -Queue -Script {
        $status = Get-WKWingetStatus
        $ids = @()
        if ($status.Available) { $ids = @(Get-WKInstalledPackageIds) }
        [pscustomobject]@{ Status = $status; Ids = $ids }
    } -OnDone {
        param($out)
        $r = $out | Where-Object { $_ -and $_.PSObject.Properties['Status'] } | Select-Object -Last 1
        if (-not $r) { $script:State.InstalledLoaded = $true; Update-WKAppsFilter; return }
        $script:State.Winget = $r.Status
        if (-not $r.Status.Available) {
            $script:UI.AppsNotice.Visibility = 'Visible'
            $script:UI.AppsNoticeText.Text = $r.Status.Message
        }
        else {
            $script:UI.AppsNotice.Visibility = 'Collapsed'
        }
        Set-WKInstalledApps -Ids @($r.Ids)
    } -OnFail {
        $script:State.InstalledLoaded = $true
        Update-WKAppsFilter
    })
}

function Test-WKWingetReady {
    if ($script:State.Winget -and -not $script:State.Winget.Available) {
        [void](Show-WKDialog -Title 'winget is not available' -Message $script:State.Winget.Message -Buttons 'OK')
        return $false
    }
    return $true
}

function Invoke-WKPackageTask {
    <# Shared by the Apps and Developer pages. #>
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Verb,
        [Parameter(Mandatory)][string[]]$Ids
    )

    if (-not (Test-WKCanStartAction)) { return }
    if (-not (Test-WKWingetReady)) { return }
    $names = foreach ($id in $Ids) { if ($script:State.AppTiles.ContainsKey($id)) { $script:State.AppTiles[$id].App.name } else { $id } }
    $list = ($names | Select-Object -First 8) -join ', '
    if ($Ids.Count -gt 8) { $list += " and $($Ids.Count - 8) more" }

    if ($Verb -eq 'install') {
        $answer = Show-WKDialog -Title "Install $(Format-WKCount $Ids.Count 'app')?" -Buttons 'Cancel', 'Install' -Primary 'Install' -Action `
            -Message "$list`n`nPackages come from the official winget repository and install silently one after another. Some installers may briefly show their own window. Installing accepts each app's license terms."
        if ($answer -ne 'Install') { return }
        $taskName = 'Installing apps'
    }
    else {
        $answer = Show-WKDialog -Title "Uninstall $(Format-WKCount $Ids.Count 'app')?" -Buttons 'Cancel', 'Uninstall' -Danger 'Uninstall' -Action `
            -Message "$list`n`nThe apps are removed with their own uninstallers. Your personal files are not touched, but app settings may be lost."
        if ($answer -ne 'Uninstall') { return }
        $taskName = 'Removing apps'
    }

    $started = Start-WKTask -Name $taskName -Arguments @{ Verb = $Verb; Ids = $Ids; Preview = [bool]$WK.PreviewMode } -Script {
        param($Verb, $Ids, $Preview)
        $results = @(Invoke-WKPackageBatch -Verb $Verb -Ids $Ids -Preview:$Preview)
        [pscustomobject]@{ Preview = [bool]$Preview; Results = $results }
    } -OnDone {
        param($out)
        $done = @($out | Where-Object { $_ -and $_.PSObject.Properties['Preview'] }) | Select-Object -Last 1
        $results = @(if ($done) { $done.Results | Where-Object { $_ -and $_.PSObject.Properties['Success'] } })
        $failed = @($results | Where-Object { -not $_.Success })
        if ($done -and $done.Preview) { Show-WKToast 'Preview finished. Nothing was changed; see Activity for details.' -Kind Info; $script:UI.ActivityToggle.IsChecked = $true }
        elseif (-not $results.Count) { Show-WKToast 'Nothing was installed or removed. See Activity for details.' -Kind Warning; $script:UI.ActivityToggle.IsChecked = $true }
        elseif ($failed.Count) { Show-WKToast "$($failed.Count) of $($results.Count) did not finish. See Activity for details." -Kind Warning }
        elseif (@($results | Where-Object { $_.Restart }).Count) { Show-WKToast "All $($results.Count) finished. Restart Windows to complete the installation." -Kind Info }
        else { Show-WKToast "All $($results.Count) finished successfully." }
        Clear-WKAppSelection
        Clear-WKStackSelection
        Update-WKAppsInstalled
        if ($script:State.Visited.Contains('developer')) { Update-WKDeveloperPage }
    } -OnFail {
        Update-WKAppsInstalled
    }
    if ($started -and -not $WK.PreviewMode) { $script:UI.ActivityToggle.IsChecked = $true }
}

function Invoke-WKAppsAction {
    param([ValidateSet('install', 'uninstall')][string]$Verb)
    $ids = @($script:State.AppSelection)
    if ($Verb -eq 'uninstall') { $ids = @($ids | Where-Object { $script:State.Installed.Contains($_) }) }
    if (-not $ids.Count) { return }
    Invoke-WKPackageTask -Verb $Verb -Ids $ids
}

function Invoke-WKAppsUpdateAll {
    if (-not (Test-WKCanStartAction)) { return }
    if (-not (Test-WKWingetReady)) { return }
    $answer = Show-WKDialog -Title 'Update all apps?' -Buttons 'Cancel', 'Update' -Primary 'Update' -Action `
        -Message 'winget updates every installed app it knows about, including apps you did not install with WinKit. This can take a while; close apps you are using to avoid failed updates.'
    if ($answer -ne 'Update') { return }
    $started = Start-WKTask -Name 'Updating apps' -Arguments @{ Preview = [bool]$WK.PreviewMode } -Script {
        param($Preview)
        Invoke-WKUpgradeAll -Preview:$Preview
        [pscustomobject]@{ Preview = [bool]$Preview }
    } -OnDone {
        param($out)
        $done = @($out | Where-Object { $_ -and $_.PSObject.Properties['Preview'] }) | Select-Object -Last 1
        if ($done -and $done.Preview) { Show-WKToast 'Preview finished. Nothing was changed; see Activity for details.' -Kind Info }
        else { Show-WKToast 'Updates finished. See Activity for details.' -Kind Info }
        Update-WKAppsInstalled
    } -OnFail {
        Update-WKAppsInstalled
    }
    if ($started) { $script:UI.ActivityToggle.IsChecked = $true }
}

function Export-WKAppsInteractive {
    if (-not $script:State.AppSelection.Count) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Export app selection'
    $dialog.Filter = 'WinKit app list (*.json)|*.json'
    $dialog.FileName = 'winkit-apps.json'
    if (-not $dialog.ShowDialog($script:UI.Window)) { return }
    try {
        Export-WKAppSelection -Ids @($script:State.AppSelection) -Path $dialog.FileName
        Show-WKToast "Saved $(Format-WKCount $script:State.AppSelection.Count 'app'). Import this file on another PC to install the same set."
    }
    catch { Show-WKToast "Could not save: $($_.Exception.Message)" -Kind Error }
}

function Import-WKAppsInteractive {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Import app selection'
    $dialog.Filter = 'App lists (*.json)|*.json|All files (*.*)|*.*'
    if (-not $dialog.ShowDialog($script:UI.Window)) { return }
    try {
        $ids = @(Import-WKAppSelection -Path $dialog.FileName)
    }
    catch {
        Show-WKToast "Could not read the file: $($_.Exception.Message)" -Kind Error
        return
    }
    $known = 0
    foreach ($id in $ids) {
        if ($script:State.AppTiles.ContainsKey($id)) { $script:State.AppTiles[$id].Tile.IsChecked = $true; $known++ }
    }
    $unknown = $ids.Count - $known
    $msg = "Selected $(Format-WKCount $known 'app') from the list."
    if ($unknown) { $msg += " Skipped $(Format-WKCount $unknown 'package') that are not in the WinKit catalog." }
    Show-WKToast $msg -Kind $(if ($unknown) { 'Info' } else { 'Success' })
}
