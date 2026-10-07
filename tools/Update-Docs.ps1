<#
.SYNOPSIS
    Regenerates docs/TWEAKS.md from config/tweaks.json so the documentation
    always lists exactly what the code changes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\TestHelpers.ps1')

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Tweak reference')
[void]$sb.AppendLine()
[void]$sb.AppendLine('This file is generated from [`config/tweaks.json`](../config/tweaks.json) by `tools/Update-Docs.ps1`. It lists every change WinKit can make, exactly as the code applies it.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Before any tweak is applied, WinKit reads and stores the current value of every setting it is about to touch. **Undo** writes those stored values back. If a tweak was applied outside WinKit, **Undo** falls back to the Windows default shown below.')
[void]$sb.AppendLine()

$restartText = @{ none = 'Immediately'; explorer = 'After File Explorer restarts'; signout = 'After signing out'; reboot = 'After a restart' }
foreach ($cat in @($WK.Config.Tweaks.categories)) {
    $tweaks = @(Get-WKTweak | Where-Object { $_.category -eq $cat.id })
    if (-not $tweaks.Count) { continue }
    [void]$sb.AppendLine("## $($cat.name)")
    [void]$sb.AppendLine()
    foreach ($t in $tweaks) {
        [void]$sb.AppendLine("### $($t.title)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine($t.description)
        [void]$sb.AppendLine()
        $meta = "Id: ``$($t.id)`` | Risk: $($t.risk) | Takes effect: $($restartText[[string]$t.restart])"
        if ($t.PSObject.Properties['windows']) { $meta += " | Windows $(@($t.windows) -join ', ') only" }
        if ($t.PSObject.Properties['minBuild']) { $meta += " | Build $($t.minBuild)+" }
        if ($t.PSObject.Properties['server'] -and -not $t.server) { $meta += ' | Not on Windows Server' }
        [void]$sb.AppendLine($meta)
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Type | Target | Applied value | Windows default |')
        [void]$sb.AppendLine('| --- | --- | --- | --- |')
        foreach ($a in @($t.actions)) {
            switch ($a.type) {
                'registry' {
                    $name = if ($a.name) { $a.name } else { '(Default)' }
                    $fmt = { param($v) if ("$v" -eq '') { '(empty string)' } else { "``$v``" } }
                    $default = if ($a.PSObject.Properties['defaultValue']) { & $fmt $a.defaultValue } else { 'value removed' }
                    [void]$sb.AppendLine("| Registry ($($a.kind)) | ``$($a.path)\$name`` | $(& $fmt $a.value) | $default |")
                }
                'service'   { [void]$sb.AppendLine("| Service startup | ``$($a.name)`` | $($a.startup) | $($a.defaultStartup) |") }
                'task'      { [void]$sb.AppendLine("| Scheduled task | ``$($a.path)$($a.name)`` | $($a.state) | $($a.defaultState) |") }
                'feature'   { [void]$sb.AppendLine("| Windows feature | ``$($a.name)`` | $($a.state) | $($a.defaultState) |") }
                'powerplan' { [void]$sb.AppendLine("| Power plan | Active scheme | $($a.scheme) | $($a.defaultScheme) |") }
                'shell' {
                    $label = @{ showExtensions = 'Show file name extensions'; showHidden = 'Show hidden files' }[[string]$a.flag]
                    [void]$sb.AppendLine("| Folder option (through the shell) | $label | $(if ($a.value) { 'On' } else { 'Off' }) | $(if ($a.defaultValue) { 'On' } else { 'Off' }) |")
                }
                'spi' {
                    $label = @{
                        mouse               = 'Mouse acceleration (threshold 1, threshold 2, speed)'
                        menuDelay           = 'Menu show delay (ms)'
                        minAnimate          = 'Minimize and maximize animation'
                        clientAreaAnimation = 'Animation effects'
                        stickyKeysHotkey    = 'Sticky Keys shortcut (Shift five times)'
                    }[[string]$a.setting]
                    $fmt = { param($v) if ($v -is [bool]) { if ($v) { 'On' } else { 'Off' } } else { "``$(@($v) -join ', ')``" } }
                    [void]$sb.AppendLine("| System setting (SystemParametersInfo) | $label | $(& $fmt $a.value) | $(& $fmt $a.defaultValue) |")
                }
            }
        }
        [void]$sb.AppendLine()
        if ($t.PSObject.Properties['notify']) {
            [void]$sb.AppendLine("After the change WinKit notifies Windows (``WM_SETTINGCHANGE``: $(@($t.notify) -join ', ')) so it applies without a restart.")
            [void]$sb.AppendLine()
        }
    }
}

[void]$sb.AppendLine('## Profiles')
[void]$sb.AppendLine()
foreach ($p in @($WK.Config.Profiles.profiles)) {
    $names = @($p.tweaks | ForEach-Object { (Get-WKTweak -Id $_).title })
    [void]$sb.AppendLine("- **$($p.name)**: $($p.description) $($names -join '; ').")
}

$path = Join-Path $WKRoot 'docs\TWEAKS.md'
[System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $path"
