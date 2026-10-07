Describe 'Configuration' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $tweaks = @($WK.Config.Tweaks.tweaks)
        $categories = @($WK.Config.Tweaks.categories | ForEach-Object id)
        $apps = @($WK.Config.Apps.apps)
    }

    It 'has unique tweak ids' {
        $dupes = @($tweaks | Group-Object id | Where-Object Count -gt 1 | ForEach-Object Name)
        Assert-True ($dupes.Count -eq 0) "Duplicate tweak ids: $($dupes -join ', ')"
    }

    It 'gives every tweak the required fields' {
        foreach ($t in $tweaks) {
            foreach ($field in 'id', 'category', 'title', 'description', 'risk', 'restart', 'actions') {
                Assert-True ([bool]$t.PSObject.Properties[$field]) "$($t.id) is missing '$field'"
            }
            Assert-True ($t.id -cmatch '^[a-z]+\.[a-z0-9-]+$') "$($t.id) is not a valid id"
            Assert-True ($categories -contains $t.category) "$($t.id) uses unknown category '$($t.category)'"
            Assert-True ($t.risk -in 'low', 'medium', 'high') "$($t.id) has invalid risk '$($t.risk)'"
            Assert-True ($t.restart -in 'none', 'explorer', 'signout', 'reboot') "$($t.id) has invalid restart '$($t.restart)'"
            Assert-True (@($t.actions).Count -gt 0) "$($t.id) has no actions"
            Assert-True ($t.id.StartsWith("$($t.category).")) "$($t.id) should start with its category"
        }
    }

    It 'only uses supported, fully reversible actions' {
        foreach ($t in $tweaks) {
            foreach ($a in @($t.actions)) {
                switch ($a.type) {
                    'registry' {
                        $null = ConvertFrom-WKRegistryPath $a.path
                        Assert-True ($a.path -match '^(HKCU|HKLM)\\') "$($t.id): only HKCU and HKLM are allowed"
                        Assert-True ($a.kind -in 'DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary') "$($t.id): bad kind '$($a.kind)'"
                        Assert-True ([bool]$a.PSObject.Properties['value']) "$($t.id): registry action without value"
                        $null = ConvertTo-WKRegistryData -Kind $a.kind -Value $a.value
                        if ($a.PSObject.Properties['defaultValue']) { $null = ConvertTo-WKRegistryData -Kind $a.kind -Value $a.defaultValue }
                        if ($a.PSObject.Properties['ownedKey']) {
                            Assert-True ("$($a.path)\".StartsWith("$($a.ownedKey)\", [StringComparison]::OrdinalIgnoreCase)) "$($t.id): ownedKey must contain the action's path"
                        }
                    }
                    'service' {
                        Assert-True ($a.startup -in 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled') "$($t.id): bad startup"
                        Assert-True ($a.defaultStartup -in 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled') "$($t.id): service needs defaultStartup"
                    }
                    'task' {
                        Assert-True ($a.path -match '^\\.*\\$') "$($t.id): task path must start and end with a backslash"
                        Assert-True ($a.state -in 'Enabled', 'Disabled' -and $a.defaultState -in 'Enabled', 'Disabled') "$($t.id): task states"
                    }
                    'feature' {
                        Assert-True ($a.state -in 'Enabled', 'Disabled' -and $a.defaultState -in 'Enabled', 'Disabled') "$($t.id): feature states"
                    }
                    'powerplan' {
                        Assert-True ($a.scheme -in 'high', 'balanced', 'saver' -and $a.defaultScheme -in 'high', 'balanced', 'saver') "$($t.id): power schemes"
                    }
                    'shell' {
                        Assert-True ($a.flag -cin 'showExtensions', 'showHidden') "$($t.id): unknown shell flag '$($a.flag)'"
                        Assert-True ($a.value -is [bool] -and $a.defaultValue -is [bool]) "$($t.id): shell values must be true or false"
                    }
                    'spi' {
                        Assert-True ($a.setting -cin $script:WKSpiSettings) "$($t.id): unknown system setting '$($a.setting)'"
                        Assert-True ([bool]$a.PSObject.Properties['defaultValue']) "$($t.id): system settings need a defaultValue"
                        foreach ($v in $a.value, $a.defaultValue) {
                            $change = [pscustomobject]@{ type = 'spi'; setting = $a.setting; before = $v }
                            Assert-True (Test-WKSystemChange -Change $change) "$($t.id): value '$(@($v) -join ',')' is not valid for $($a.setting)"
                        }
                    }
                    default { throw "$($t.id): unsupported action type '$($a.type)'" }
                }
            }
            if ($t.PSObject.Properties['server']) { Assert-True ($t.server -is [bool]) "$($t.id): server must be true or false" }
            $notify = $t.PSObject.Properties['notify']
            foreach ($area in @(if ($notify) { $notify.Value })) {
                Assert-True ($area -cin 'TraySettings', 'ImmersiveColorSet', 'ShellState', 'Policy', 'Environment') "$($t.id): unexpected notify area '$area'"
            }
        }
    }

    It 'never touches security-critical settings' {
        $forbidden = 'Windows Defender', 'WinDefend', 'MpsSvc', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'NoAutoUpdate', 'WindowsUpdate\\AU', 'EnableLUA', 'ConsentPromptBehavior', 'SmartScreen', 'SecurityHealthService', 'WdNisSvc', 'BFE'
        $json = Get-WKResource 'config/tweaks.json'
        foreach ($f in $forbidden) {
            Assert-True (-not $json.Contains($f)) "tweaks.json must not reference '$f'"
        }
    }

    It 'references only existing tweaks from profiles' {
        $ids = @($tweaks | ForEach-Object id)
        foreach ($p in @($WK.Config.Profiles.profiles)) {
            foreach ($id in @($p.tweaks)) { Assert-True ($ids -contains $id) "Profile '$($p.id)' references unknown tweak '$id'" }
            $dupes = @($p.tweaks | Group-Object | Where-Object Count -gt 1)
            Assert-True ($dupes.Count -eq 0) "Profile '$($p.id)' lists a tweak twice"
        }
    }

    It 'has a valid app catalog' {
        $dupes = @($apps | Group-Object id | Where-Object Count -gt 1 | ForEach-Object Name)
        Assert-True ($dupes.Count -eq 0) "Duplicate app ids: $($dupes -join ', ')"
        $cats = @($WK.Config.Apps.categories)
        foreach ($a in $apps) {
            Assert-True ($cats -contains $a.category) "$($a.id) has unknown category '$($a.category)'"
            Assert-True ($a.id -cmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]+$') "$($a.id) is not a valid winget id"
            Assert-True ([bool]$a.name -and [bool]$a.description) "$($a.id) needs a name and description"
        }
    }

    It 'only offers developer stacks from the catalog' {
        $ids = @($apps | ForEach-Object id)
        foreach ($s in @($WK.Config.Developer.stacks)) {
            foreach ($p in @($s.packages)) { Assert-True ($ids -contains $p) "Stack '$($s.id)' uses '$p', which is not in apps.json" }
        }
    }


    It 'has well-formed network targets' {
        foreach ($t in @($WK.Config.Network.latencyTargets)) {
            Assert-True ($t.host -cmatch '^[a-z0-9.-]+\.[a-z]{2,}$') "Bad host '$($t.host)'"
            Assert-True ($t.port -in 80, 443) "Unexpected port on $($t.host)"
        }
        foreach ($d in @($WK.Config.Network.dnsProviders)) {
            foreach ($ip in @($d.ipv4) + @($d.ipv6)) {
                $parsed = $null
                Assert-True ([System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) "$($d.id): '$ip' is not an IP address"
            }
        }
    }
}
