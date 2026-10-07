function Initialize-WKDeveloperPage {
    $script:State.StackBoxes = @{}
    $appsById = @{}
    foreach ($a in @($WK.Config.Apps.apps)) { $appsById[$a.id] = $a }

    foreach ($stack in @($WK.Config.Developer.stacks)) {
        $col = New-WKStack -Margin (New-WKThickness 0 0 18 0)
        [void]$col.Children.Add((New-WKText -Text $stack.name -SemiBold))
        [void]$col.Children.Add((New-WKText -Text $stack.description -Brush 'MutedBrush' -Size 12.5 -Wrap -Margin (New-WKThickness 0 2 0 10)))
        foreach ($id in @($stack.packages)) {
            $name = if ($appsById.ContainsKey($id)) { $appsById[$id].name } else { $id }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Margin = New-WKThickness 0 4 0 4
            $cb.Tag = $id
            $label = New-WKStack -Horizontal
            [void]$label.Children.Add((New-WKText -Text $name))
            $mark = New-WKText -Text 'installed' -Brush 'GoodBrush' -Size 11.5 -Margin (New-WKThickness 7 1 0 0)
            $mark.Visibility = 'Collapsed'
            [void]$label.Children.Add($mark)
            $cb.Content = $label
            $cb.ToolTip = "winget id: $id"
            [void]$col.Children.Add($cb)
            if (-not $script:State.StackBoxes.ContainsKey($id)) { $script:State.StackBoxes[$id] = @() }
            $script:State.StackBoxes[$id] += @{ Box = $cb; Mark = $mark }
        }
        [void]$script:UI.DevStacks.Children.Add($col)
    }

    $script:UI.DevInstall.Add_Click({
        $ids = @($script:State.StackBoxes.Keys | Where-Object {
            $id = $_
            @($script:State.StackBoxes[$id] | Where-Object { $_.Box.IsChecked }).Count -gt 0
        })
        if (-not $ids.Count) { Show-WKToast 'Select at least one tool to install.' -Kind Info; return }
        Invoke-WKPackageTask -Verb install -Ids $ids
    })
    $script:UI.DevToolsRefresh.Add_Click({ Update-WKDeveloperPage })
    $script:UI.DevGitSave.Add_Click({ Save-WKGitIdentityInteractive })
    $script:UI.DevSshGenerate.Add_Click({ New-WKSshKeyInteractive })
    $script:UI.DevSshCopy.Add_Click({
        if ($script:State.Ssh -and $script:State.Ssh.PublicKey) {
            # Another app (a clipboard manager, Remote Desktop) can hold the clipboard.
            try {
                [System.Windows.Clipboard]::SetText($script:State.Ssh.PublicKey)
                Show-WKToast 'Public key copied. Paste it into GitHub, GitLab or your server.'
            }
            catch { Show-WKToast 'The clipboard is in use by another app. Try again in a moment.' -Kind Warning }
        }
    })
    $script:UI.DevSshFolder.Add_Click({
        $dir = Join-Path $env:USERPROFILE '.ssh'
        if (Test-Path -LiteralPath $dir) { Open-WKExternal $dir } else { Show-WKToast 'The .ssh folder does not exist yet.' -Kind Info }
    })
    $script:UI.DevWslEnable.Add_Click({ Start-WKTweakOperation -Ids @('developer.wsl') -Operation Apply })
    $script:UI.DevWslInstall.Add_Click({
        if (-not (Test-WKCanStartAction)) { return }
        $answer = Show-WKDialog -Title 'Install Ubuntu?' -Buttons 'Cancel', 'Install' -Primary 'Install' -Action `
            -Message 'A console window opens and runs "wsl --install -d Ubuntu". It downloads Ubuntu from Microsoft and asks you to create a Linux user name and password when it finishes.'
        if ($answer -ne 'Install') { return }
        if ($WK.PreviewMode) { Write-WKLog '[Preview] wsl.exe --install -d Ubuntu' -Level Step; Show-WKToast 'Preview: nothing was started.' -Kind Info; return }
        try { Start-WKWslInstall -Distro Ubuntu } catch { Show-WKToast $_.Exception.Message -Kind Error }
    })

    # Developer settings reuse the tweak rows in compact form.
    $devTweaks = @(Get-WKTweak | Where-Object { $_.category -eq 'developer' -and $_.id -ne 'developer.wsl' })
    for ($i = 0; $i -lt $devTweaks.Count; $i++) {
        $row = New-WKTweakRow -Tweak $devTweaks[$i] -Compact
        [void]$script:UI.DevTweaks.Children.Add($row)
        if ($i -lt $devTweaks.Count - 1) { [void]$script:UI.DevTweaks.Children.Add((New-WKDivider)) }
    }
}

function Update-WKStackInstalledMarks {
    if (-not $script:State.StackBoxes) { return }
    foreach ($id in $script:State.StackBoxes.Keys) {
        foreach ($entry in $script:State.StackBoxes[$id]) {
            $entry.Mark.Visibility = if ($script:State.Installed.Contains($id)) { 'Visible' } else { 'Collapsed' }
        }
    }
}

function Clear-WKStackSelection {
    if (-not $script:State.StackBoxes) { return }
    foreach ($id in $script:State.StackBoxes.Keys) {
        foreach ($entry in $script:State.StackBoxes[$id]) { $entry.Box.IsChecked = $false }
    }
}

function Update-WKDeveloperPage {
    [void](Start-WKTask -Name 'Checking developer tools' -Queue -Script {
        [pscustomobject]@{
            Tools = @(Get-WKDevToolStatus)
            Git   = Get-WKGitIdentity
            Ssh   = Get-WKSshKeyStatus
            Wsl   = Get-WKWslStatus
        }
    } -OnDone {
        param($out)
        $r = $out | Where-Object { $_ -and $_.PSObject.Properties['Tools'] } | Select-Object -Last 1
        if ($r) { Show-WKDeveloperStatus -Status $r }
    } -OnFail {
        foreach ($text in $script:UI.DevGitStatus, $script:UI.DevSshStatus, $script:UI.DevWslStatus) {
            $text.Text = 'Could not be checked. Press Refresh to try again.'
        }
    })
    if (-not $script:State.InstalledLoaded) { Update-WKAppsInstalled }
    Update-WKTweakStates
}

function Show-WKDeveloperStatus {
    param($Status)

    $panel = $script:UI.DevTools
    $panel.Children.Clear()
    foreach ($t in $Status.Tools) {
        if ($t.Command -eq 'wsl') {
            # wsl.exe ships with Windows; WSL counts as installed once a distribution is.
            $t.Installed = [bool]($Status.Wsl.Ready -and @($Status.Wsl.Distros).Count)
        }
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $chip.Padding = New-WKThickness 10 6 12 6
        $chip.Margin = New-WKThickness 0 0 8 8
        $chip.BorderThickness = New-WKThickness 1 1 1 1
        Set-WKBrush $chip ([System.Windows.Controls.Border]::BorderBrushProperty) 'LineBrush'
        $sp = New-WKStack -Horizontal
        if ($t.Installed) {
            Set-WKBrush $chip ([System.Windows.Controls.Border]::BackgroundProperty) 'SurfaceBrush'
            [void]$sp.Children.Add((New-WKIcon -Code 'E73E' -Brush 'GoodBrush' -Size 11))
            [void]$sp.Children.Add((New-WKText -Text $t.Name -SemiBold -Margin (New-WKThickness 7 0 0 0)))
            if ($t.Version) { [void]$sp.Children.Add((New-WKText -Text $t.Version -Brush 'MutedBrush' -Size 11.5 -Margin (New-WKThickness 6 1 0 0))) }
            $chip.ToolTip = $t.Path
        }
        else {
            Set-WKBrush $chip ([System.Windows.Controls.Border]::BackgroundProperty) 'HoverBrush'
            [void]$sp.Children.Add((New-WKIcon -Code 'E711' -Brush 'MutedBrush' -Size 10))
            [void]$sp.Children.Add((New-WKText -Text $t.Name -Brush 'MutedBrush' -Margin (New-WKThickness 7 0 0 0)))
            $chip.ToolTip = if ($t.Command -eq 'wsl') { 'No Linux distribution is installed' } else { "'$($t.Command)' was not found on PATH" }
        }
        $chip.Child = $sp
        [void]$panel.Children.Add($chip)
    }

    # Git
    $git = $Status.Git
    if (-not $git.Available) {
        $script:UI.DevGitStatus.Text = 'Git is not installed yet. Select it in "Essentials" above.'
        $script:UI.DevGitSave.IsEnabled = $false
    }
    else {
        $script:UI.DevGitSave.IsEnabled = $true
        $script:UI.DevGitStatus.Text = if ($git.Name) { 'Used for every commit you make on this PC.' } else { 'Not configured yet. Commits will fail until you set a name and email.' }
        if (-not $script:UI.DevGitName.Text)   { $script:UI.DevGitName.Text = "$($git.Name)" }
        if (-not $script:UI.DevGitEmail.Text)  { $script:UI.DevGitEmail.Text = "$($git.Email)" }
        if (-not $script:UI.DevGitBranch.Text) { $script:UI.DevGitBranch.Text = if ($git.DefaultBranch) { $git.DefaultBranch } else { 'main' } }
    }

    # SSH
    $ssh = $Status.Ssh
    $script:State.Ssh = $ssh
    if (-not $ssh.OpenSshAvailable) {
        $script:UI.DevSshStatus.Text = 'OpenSSH Client is not installed. Add it in Settings > System > Optional features.'
    }
    elseif ($ssh.KeyExists) {
        $agent = if ($ssh.AgentStatus -eq 'Running') { 'ssh-agent is running.' } else { 'Tip: enable "Start the OpenSSH agent automatically" below.' }
        $script:UI.DevSshStatus.Text = "Ed25519 key found. $agent"
    }
    else {
        $script:UI.DevSshStatus.Text = 'No Ed25519 key yet. Generate one to push to GitHub or log in to servers.'
    }
    $script:UI.DevSshKey.Text = if ($ssh.PublicKey) { $ssh.PublicKey } elseif ($ssh.KeyExists) { 'Public key file is missing.' } else { 'No key yet' }
    $script:UI.DevSshGenerate.IsEnabled = $ssh.OpenSshAvailable -and -not $ssh.KeyExists
    $script:UI.DevSshCopy.IsEnabled = [bool]$ssh.PublicKey

    # WSL
    $wsl = $Status.Wsl
    if ($wsl.Ready -and @($wsl.Distros).Count) {
        $script:UI.DevWslStatus.Text = "Ready. Installed distributions: $(@($wsl.Distros) -join ', ')"
        $script:UI.DevWslEnable.Visibility = 'Collapsed'
        $script:UI.DevWslInstall.Content = 'Install Ubuntu'
    }
    elseif ($wsl.FeatureState -eq 'Applied' -or $wsl.Ready) {
        $script:UI.DevWslStatus.Text = 'WSL is enabled. Install a Linux distribution to start using it. If you just enabled it, restart your PC first.'
        $script:UI.DevWslEnable.Visibility = 'Collapsed'
    }
    else {
        $script:UI.DevWslStatus.Text = 'Not enabled. Enabling turns on two Windows features and needs a restart; you can also install Ubuntu directly, which does both.'
        $script:UI.DevWslEnable.Visibility = 'Visible'
    }
}

function Save-WKGitIdentityInteractive {
    $name = $script:UI.DevGitName.Text.Trim()
    $email = $script:UI.DevGitEmail.Text.Trim()
    $branch = $script:UI.DevGitBranch.Text.Trim()
    if (-not $name) { Show-WKToast 'Enter your name first.' -Kind Info; [void]$script:UI.DevGitName.Focus(); return }
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Show-WKToast 'Enter a valid email address.' -Kind Info; [void]$script:UI.DevGitEmail.Focus(); return }
    if (-not $branch) { $branch = 'main' }
    if ($WK.PreviewMode) {
        Write-WKLog "[Preview] git config --global user.name `"$name`"; user.email `"$email`"; init.defaultBranch `"$branch`"" -Level Step
        Show-WKToast 'Preview: Git config was not changed.' -Kind Info
        return
    }
    try {
        Set-WKGitIdentity -Name $name -Email $email -DefaultBranch $branch
        Show-WKToast 'Git identity saved.'
        $script:UI.DevGitStatus.Text = 'Used for every commit you make on this PC.'
    }
    catch { Show-WKToast $_.Exception.Message -Kind Error }
}

function New-WKSshKeyInteractive {
    $email = $script:UI.DevGitEmail.Text.Trim()
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Show-WKToast 'Enter your email address under Git identity first. It becomes the key comment.' -Kind Info
        [void]$script:UI.DevGitEmail.Focus()
        return
    }
    if (-not (Test-WKCanStartAction)) { return }
    $answer = Show-WKDialog -Title 'Generate an SSH key?' -Buttons 'Cancel', 'Generate' -Primary 'Generate' -Action `
        -Message "ssh-keygen opens in its own window. Choose a passphrase there; WinKit never sees it.`n`nThe key is saved to $(Get-WKSshKeyPath). Existing keys are never overwritten."
    if ($answer -ne 'Generate') { return }
    if ($WK.PreviewMode) {
        Write-WKLog "[Preview] ssh-keygen -t ed25519 -C $email" -Level Step
        Show-WKToast 'Preview: no key was created.' -Kind Info
        return
    }

    [void](Start-WKTask -Name 'Waiting for ssh-keygen' -Arguments @{ Comment = $email } -Script {
        param($Comment)
        New-WKSshKey -Comment $Comment
    } -OnDone {
        Update-WKDeveloperPage
    } -OnFail {
        Update-WKDeveloperPage
    })
}
