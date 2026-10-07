# Verifies the download -> verify -> launch chain without touching the
# network or asking for elevation: the release URL is swapped for a local
# file URI and RunAs is removed from a copy of the generated launcher.

Describe 'Launcher and verified bootstrap' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-launcher-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        $marker = Join-Path $sandbox 'ran.txt'
        $payload = Join-Path $sandbox 'payload.ps1'
        [System.IO.File]::WriteAllText($payload, "Set-Content -LiteralPath '$marker' -Value 'ok'", (New-Object System.Text.UTF8Encoding $true))
        $payloadHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

        function Invoke-Encoded([string]$Script) {
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
            $p = Start-Process -FilePath $powershell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait -PassThru -WindowStyle Hidden
            return $p.ExitCode
        }
    }
    AfterAll {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'KlaudikWinKit\WinKit-0.0.0-test.ps1') -Force -ErrorAction SilentlyContinue
    }

    It 'runs the payload when the hash matches' {
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $boot = New-WKVerifiedBootstrap -Path $payload -Sha256 $payloadHash
        $code = Invoke-Encoded $boot
        Assert-Equal 0 $code 'exit code'
        Assert-True (Test-Path -LiteralPath $marker) 'payload did not run'
    }

    It 'refuses to run a file that changed after verification' {
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $boot = New-WKVerifiedBootstrap -Path $payload -Sha256 ('0' * 64)
        # Read-Host would wait for input; answer it through stdin being empty.
        $boot = $boot.Replace("Read-Host 'Press Enter to close' | Out-Null", '')
        $code = Invoke-Encoded $boot
        Assert-Equal 1 $code 'exit code'
        Assert-True (-not (Test-Path -LiteralPath $marker)) 'tampered payload ran'
    }

    It 'does not load modules from folders the user can write to' {
        # A program running as the user could plant a module in Documents;
        # the elevated bootstrap must never pick it up.
        $modules = Join-Path $sandbox 'Modules'
        $planted = Join-Path $modules 'Planted'
        New-Item -ItemType Directory -Path $planted -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $planted 'Planted.psm1') -Value 'function Invoke-WKPlanted { }'
        $probe = Join-Path $sandbox 'probe.ps1'
        $result = Join-Path $sandbox 'probe.txt'
        $code = "if (Get-Command Invoke-WKPlanted -ErrorAction SilentlyContinue) { 'hijacked' } else { 'clean' }"
        [System.IO.File]::WriteAllText($probe, "Set-Content -LiteralPath '$result' -Value `$($code)", (New-Object System.Text.UTF8Encoding $true))
        $hash = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = "$modules;$saved"
            $null = Invoke-Encoded (New-WKVerifiedBootstrap -Path $probe -Sha256 $hash)
        }
        finally { $env:PSModulePath = $saved }
        Assert-Equal 'clean' ((Get-Content -LiteralPath $result -Raw).Trim()) 'a planted module was visible to the bootstrap'

        $template = Get-Content -LiteralPath (Join-Path $WKRoot 'templates\launcher.ps1') -Raw
        Assert-True ($template.Contains('`$env:PSModulePath = "`$PSHOME\Modules;"')) 'the launcher bootstrap does not lock the module path'
    }

    It 'launcher downloads, verifies and starts the pinned build' {
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $template = Get-Content -LiteralPath (Join-Path $WKRoot 'templates\launcher.ps1') -Raw
        $uri = ([System.Uri]$payload).AbsoluteUri
        $launcher = $template.Replace('{{VERSION}}', '0.0.0-test').Replace('{{SHA256}}', $payloadHash).Replace('{{REPOSITORY}}', 'example/test')
        $launcher = $launcher.Replace('"https://github.com/example/test/releases/download/v$version/WinKit.ps1"', "'$uri'")
        $launcher = $launcher.Replace(' -Verb RunAs', ' -Wait -WindowStyle Hidden')
        Assert-True ($launcher.Contains("'$uri'")) 'URL substitution failed'
        $code = Invoke-Encoded $launcher
        Assert-Equal 0 $code 'exit code'
        Assert-True (Test-Path -LiteralPath $marker) 'launcher did not start the payload'
    }

    It 'launcher deletes a download with the wrong checksum and runs nothing' {
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $template = Get-Content -LiteralPath (Join-Path $WKRoot 'templates\launcher.ps1') -Raw
        $uri = ([System.Uri]$payload).AbsoluteUri
        $launcher = $template.Replace('{{VERSION}}', '0.0.0-bad').Replace('{{SHA256}}', ('F' * 64)).Replace('{{REPOSITORY}}', 'example/test')
        $launcher = $launcher.Replace('"https://github.com/example/test/releases/download/v$version/WinKit.ps1"', "'$uri'")
        $launcher = $launcher.Replace(' -Verb RunAs', ' -Wait -WindowStyle Hidden')
        $null = Invoke-Encoded $launcher
        Assert-True (-not (Test-Path -LiteralPath $marker)) 'payload ran despite a checksum mismatch'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:TEMP 'KlaudikWinKit\WinKit-0.0.0-bad.ps1'))) 'bad download was kept'
    }
}
