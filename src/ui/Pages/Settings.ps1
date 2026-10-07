function Initialize-WKSettingsPage {
    $script:UI.SetVersion.Text = "Version $($WK.Version)  |  $($WK.Windows.Name) build $($WK.Windows.Build)"

    switch ($WK.Settings.Theme) {
        'Light' { $script:UI.SetThemeLight.IsChecked = $true }
        'Dark'  { $script:UI.SetThemeDark.IsChecked = $true }
        default { $script:UI.SetThemeSystem.IsChecked = $true }
    }
    foreach ($pair in @(@('SetThemeSystem', 'System'), @('SetThemeLight', 'Light'), @('SetThemeDark', 'Dark'))) {
        $script:UI[$pair[0]].Tag = $pair[1]
        $script:UI[$pair[0]].Add_Checked({
            $WK.Settings.Theme = $this.Tag
            Set-WKTheme -Mode $this.Tag
            Save-WKSettingsQuietly
        })
    }

    $script:UI.SetRestorePoint.IsChecked = [bool]$WK.Settings.CreateRestorePoint
    $script:UI.SetRestorePoint.Add_Checked({ $WK.Settings.CreateRestorePoint = $true; Save-WKSettingsQuietly })
    $script:UI.SetRestorePoint.Add_Unchecked({
        $WK.Settings.CreateRestorePoint = $false
        Save-WKSettingsQuietly
        Show-WKToast 'Restore points are off. WinKit can still undo its own changes from History.' -Kind Info
    })

    $script:UI.SetGithub.Add_Click({ Open-WKExternal $WK.Repository })
    $script:UI.SetIssues.Add_Click({ Open-WKExternal "$($WK.Repository)/issues/new/choose" })
    $script:UI.SetWebsite.Add_Click({ Open-WKExternal $WK.Website })
    $script:UI.SetDataFolder.Add_Click({ Open-WKExternal $WK.DataDir })
    $script:UI.SetCheckUpdate.Add_Click({ Start-WKUpdateCheck })
}

function Save-WKSettingsQuietly {
    try { Save-WKSettings } catch { Write-WKLog "Settings could not be saved: $($_.Exception.Message)" -Level Warning }
}

function Start-WKUpdateCheck {
    $script:UI.SetUpdateStatus.Visibility = 'Visible'
    $script:UI.SetUpdateStatus.Text = 'Checking...'
    [void](Start-WKTask -Name 'Checking for updates' -Queue -OnFail {
        $script:UI.SetUpdateStatus.Text = 'The update check could not be completed.'
    } -Script {
        $protocols = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$protocols -ne 0 -and -not ($protocols -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
        }
        try {
            $release = Invoke-RestMethod -Uri $WK.ReleasesApi -Headers @{ 'User-Agent' = 'Klaudik-WinKit' } -TimeoutSec 15 -ErrorAction Stop
            [pscustomobject]@{ Ok = $true; Tag = [string]$release.tag_name; Url = [string]$release.html_url; Status = 0 }
        }
        catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            [pscustomobject]@{ Ok = $false; Tag = $null; Url = $null; Status = $code }
        }
    } -OnDone {
        param($out)
        $r = $out | Where-Object { $_ -and $_.PSObject.Properties['Ok'] } | Select-Object -Last 1
        if (-not $r -or -not $r.Ok) {
            $script:UI.SetUpdateStatus.Text = switch ($r.Status) {
                404     { 'No release has been published yet.' }
                403     { 'GitHub limits how often it can be asked. Try again in an hour.' }
                429     { 'GitHub limits how often it can be asked. Try again in an hour.' }
                default { 'Could not reach GitHub. Check your connection and try again.' }
            }
            return
        }
        $latest = $null
        $current = $null
        [void][version]::TryParse(($r.Tag -replace '^v', ''), [ref]$latest)
        [void][version]::TryParse($WK.Version, [ref]$current)
        if ($latest -and $current -and $latest -gt $current) {
            $script:UI.SetUpdateStatus.Text = "Version $latest is available. Run the launch command again to get it."
            $a = Show-WKDialog -Title "WinKit $latest is available" -Buttons 'Later', 'View release' -Primary 'View release' `
                -Message "You are running $current. Run the launch command again to get the new version."
            # Only ever open this project's own release pages.
            $releases = "$($WK.Repository)/releases/"
            $url = if ("$($r.Url)".StartsWith($releases, [StringComparison]::Ordinal) -and "$($r.Url)" -cmatch '^https://github\.com/[A-Za-z0-9_.\-/]+$') { $r.Url } else { "$($WK.Repository)/releases/latest" }
            if ($a -eq 'View release') { Open-WKExternal $url }
        }
        else {
            $script:UI.SetUpdateStatus.Text = "You are up to date ($($WK.Version))."
        }
    })
}
