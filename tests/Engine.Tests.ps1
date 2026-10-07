# Exercises the apply / undo engine against a throwaway key under
# HKCU\Software\KlaudikWinKitTest. No real Windows setting is touched.

Describe 'Tweak engine' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $WK.HistoryFile = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-test-history-$([guid]::NewGuid()).json"
        $root = 'HKCU\Software\KlaudikWinKitTest'
        $rootPs = 'HKCU:\Software\KlaudikWinKitTest'

        function New-TestTweak {
            Register-WKTestTweak ([pscustomobject]@{
                id = 'test.engine'; category = 'privacy'; title = 'Engine test'; risk = 'low'; restart = 'none'
                actions = @(
                    [pscustomobject]@{ type = 'registry'; path = "$root\Deep\New\Key"; name = 'DW'; kind = 'DWord'; value = 4294967295 }
                    [pscustomobject]@{ type = 'registry'; path = "$root\Deep\New\Key"; name = ''; kind = 'String'; value = '' }
                    [pscustomobject]@{ type = 'registry'; path = "$root\Deep\New\Key"; name = 'Multi'; kind = 'MultiString'; value = @('solo') }
                    [pscustomobject]@{ type = 'registry'; path = "$root\Deep\New\Key"; name = 'Bin'; kind = 'Binary'; value = @(1, 2, 255) }
                    [pscustomobject]@{ type = 'registry'; path = "$root\Deep\New\Key"; name = 'Q'; kind = 'QWord'; value = 5000000000 }
                    [pscustomobject]@{ type = 'registry'; path = "$root\Existing"; name = 'Keep'; kind = 'DWord'; value = 7; defaultValue = 1 }
                )
            })
        }

        function Reset-TestKey {
            Remove-Item -LiteralPath $rootPs -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
            Set-WKRegistryValue -Path "$root\Existing" -Name 'Keep' -Kind String -Value 'original' | Out-Null
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $rootPs -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
    }

    It 'applies every value kind exactly' {
        Reset-TestKey
        $t = New-TestTweak
        Assert-Equal 'NotApplied' (Get-WKTweakState $t).State
        $r = Invoke-WKTweak -Tweak $t -Mode Apply
        Assert-Equal 6 $r.Changed 'changed'
        Assert-Equal 0 $r.Failed 'failed'
        Assert-Equal 'Applied' (Get-WKTweakState $t).State

        $v = Get-WKRegistryValue "$root\Deep\New\Key" 'DW'
        Assert-True ($v.Kind -eq 'DWord' -and $v.Value -eq -1) 'DWORD 0xFFFFFFFF'
        $v = Get-WKRegistryValue "$root\Deep\New\Key" ''
        Assert-True ($v.Exists -and $v.Value -eq '') '(Default) value'
        $v = Get-WKRegistryValue "$root\Deep\New\Key" 'Multi'
        Assert-True ($v.Kind -eq 'MultiString' -and (@($v.Value) -join ',') -eq 'solo') 'single-item MultiString'
        $v = Get-WKRegistryValue "$root\Deep\New\Key" 'Bin'
        Assert-Equal '1,2,255' (@($v.Value) -join ',') 'Binary'
        $v = Get-WKRegistryValue "$root\Deep\New\Key" 'Q'
        Assert-True ($v.Kind -eq 'QWord' -and $v.Value -eq 5000000000) 'QWORD'
    }

    It 'records one history entry and does nothing on re-apply' {
        Reset-TestKey
        $t = New-TestTweak
        Invoke-WKTweak -Tweak $t -Mode Apply | Out-Null
        $again = Invoke-WKTweak -Tweak $t -Mode Apply
        Assert-Equal 0 $again.Changed 're-apply'
        $h = @(Get-WKActiveHistory -RefId 'test.engine')
        Assert-Equal 1 $h.Count 'history entries'
        Assert-Equal 6 @($h[0].changes).Count 'recorded changes'
    }

    It 'undo restores the exact previous state and removes created keys' {
        Reset-TestKey
        $t = New-TestTweak
        Invoke-WKTweak -Tweak $t -Mode Apply | Out-Null
        $entry = @(Get-WKActiveHistory -RefId 'test.engine')[0]
        Assert-True (Undo-WKHistoryEntry -Entry $entry) 'undo reported failure'

        Assert-True (-not (Test-Path -LiteralPath "$rootPs\Deep")) 'keys created by the tweak should be gone'
        $v = Get-WKRegistryValue "$root\Existing" 'Keep'
        Assert-True ($v.Kind -eq 'String' -and $v.Value -eq 'original') 'original value and kind'
        Assert-Equal 0 @(Get-WKActiveHistory -RefId 'test.engine').Count 'active entries after undo'
        Assert-Equal 'NotApplied' (Get-WKTweakState $t).State
    }

    It 'does not delete keys that gained other values after the tweak' {
        Reset-TestKey
        $t = New-TestTweak
        Invoke-WKTweak -Tweak $t -Mode Apply | Out-Null
        Set-WKRegistryValue -Path "$root\Deep\New\Key" -Name 'SomebodyElse' -Kind DWord -Value 1 | Out-Null
        $entry = @(Get-WKActiveHistory -RefId 'test.engine')[0]
        Undo-WKHistoryEntry -Entry $entry | Out-Null
        $v = Get-WKRegistryValue "$root\Deep\New\Key" 'SomebodyElse'
        Assert-True $v.Exists 'foreign value must survive undo'
    }

    It 'restores Windows defaults when there is no history' {
        Reset-TestKey
        $t = New-TestTweak
        Invoke-WKTweak -Tweak $t -Mode Apply | Out-Null
        Invoke-WKTweak -Tweak $t -Mode Default | Out-Null
        $v = Get-WKRegistryValue "$root\Existing" 'Keep'
        Assert-True ($v.Kind -eq 'DWord' -and $v.Value -eq 1) 'defaultValue is written'
        Assert-True (-not (Get-WKRegistryValue "$root\Deep\New\Key" 'DW').Exists) 'values without a default are removed'
    }

    It 'writes nothing in preview mode' {
        Remove-Item -LiteralPath $rootPs -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
        Invoke-WKTweak -Tweak (New-TestTweak) -Mode Apply -Preview | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $rootPs)) 'registry was written in preview mode'
        Assert-Equal 0 @(Get-WKHistory).Count 'history was written in preview mode'
    }

    It 'skips tweaks for other Windows versions' {
        $t = New-TestTweak
        $other = if ($WK.Windows.Major -eq 11) { 10 } else { 11 }
        $t | Add-Member -NotePropertyName windows -NotePropertyValue @($other)
        Assert-Equal 'Unavailable' (Get-WKTweakState $t).State
    }

    It 'refuses to undo a change WinKit did not make' {
        Reset-TestKey
        $t = New-TestTweak
        Invoke-WKTweak -Tweak $t -Mode Apply | Out-Null
        $entry = @(Get-WKActiveHistory -RefId 'test.engine')[0]

        # A tampered history file that aims at a code-execution key.
        $forged = [pscustomobject]@{
            type = 'registry'
            path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe'
            name = 'Debugger'
            before = [pscustomobject]@{ exists = $true; kind = 'String'; value = 'C:\evil.exe' }
            after = [pscustomobject]@{ exists = $false; kind = $null; value = $null }
            createdKey = $null
        }
        Assert-True (-not (Test-WKChangeAllowed -Entry $entry -Change $forged)) 'a forged change was accepted'

        $entry.changes = @($forged)
        Assert-True (-not (Undo-WKHistoryEntry -Entry $entry)) 'undo ran a forged change'
        Assert-True (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe')) 'the forged key was created'

        # A real change of a tweak that a later version removed still undoes.
        $orphan = [pscustomobject]@{ kind = 'tweak'; refId = 'gone.from.catalog'; changes = @() }
        $ok = [pscustomobject]@{ type = 'registry'; path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'ShowCopilotButton'
                                 before = [pscustomobject]@{ exists = $true; kind = 'DWord'; value = 1 } }
        Assert-True (Test-WKChangeAllowed -Entry $orphan -Change $ok) 'a plain value from a removed tweak was refused'

        # ...but only where WinKit tweaks point, and never security software.
        $elsewhere = [pscustomobject]@{ type = 'registry'; path = 'HKLM\SOFTWARE\Classes\exefile\shell'; name = 'x'
                                        before = [pscustomobject]@{ exists = $true; kind = 'String'; value = 'y' } }
        Assert-True (-not (Test-WKChangeAllowed -Entry $orphan -Change $elsewhere)) 'a value outside the allowed areas was accepted'
        $defender = [pscustomobject]@{ type = 'registry'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'; name = 'DisableAntiSpyware'
                                       before = [pscustomobject]@{ exists = $true; kind = 'DWord'; value = 1 } }
        Assert-True (-not (Test-WKChangeAllowed -Entry $orphan -Change $defender)) 'a Defender policy was accepted'
        $service = [pscustomobject]@{ type = 'service'; name = 'WinDefend'; before = 'Disabled' }
        Assert-True (-not (Test-WKChangeAllowed -Entry $orphan -Change $service)) 'a service WinKit never touches was accepted'
    }

    It 'reads the state of every shipped tweak without errors' {
        foreach ($t in Get-WKTweak) {
            $s = Get-WKTweakState -Tweak $t
            Assert-True ($s.State -in 'Applied', 'NotApplied', 'Partial', 'Unavailable') "$($t.id) returned '$($s.State)'"
        }
    }

    It 'describes every change in plain text' {
        foreach ($t in Get-WKTweak) {
            foreach ($a in @($t.actions)) {
                Assert-True ([bool](Format-WKActionPlan -Action $a)) "$($t.id) has an action without a description"
            }
        }
    }
}

Describe 'History file' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $WK.HistoryFile = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-test-history-$([guid]::NewGuid()).json"
    }
    AfterAll {
        Get-ChildItem -Path "$($WK.HistoryFile)*" -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    It 'round-trips a single entry as an array' {
        $change = [pscustomobject]@{ type = 'service'; name = 'x'; before = 'Manual'; after = 'Disabled' }
        Add-WKHistoryEntry -Kind tweak -RefId 'a.b' -Title 'One' -Changes @($change) | Out-Null
        $all = @(Get-WKHistory)
        Assert-Equal 1 $all.Count
        Assert-Equal 1 @($all[0].changes).Count
    }

    It 'survives a corrupt file by backing it up' {
        [System.IO.File]::WriteAllText($WK.HistoryFile, '{ not json')
        $all = @(Get-WKHistory)
        Assert-Equal 0 $all.Count
        Assert-True (@(Get-ChildItem -Path "$($WK.HistoryFile).corrupt-*").Count -ge 1) 'backup of the corrupt file'
    }
}
