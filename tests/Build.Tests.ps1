Describe 'Release build' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-build-$([guid]::NewGuid())"
        & (Join-Path $root 'build.ps1') -Output $out | Out-Null
        $app = Join-Path $out 'WinKit.ps1'
        $launcher = Join-Path $out 'win.ps1'
    }
    AfterAll {
        Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'produces a script that parses' {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($app, [ref]$tokens, [ref]$errors)
        if ($errors) { throw $errors[0].Message }
    }

    It 'writes a matching checksum file' {
        $hash = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash
        $recorded = ((Get-Content -LiteralPath "$app.sha256" -Raw) -split '\s+')[0]
        if ($hash -ne $recorded) { throw "Checksum file says $recorded, actual $hash" }
    }

    It 'pins the launcher to the exact build' {
        $hash = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash
        $text = Get-Content -LiteralPath $launcher -Raw
        if (-not $text.Contains("'$hash'")) { throw 'Launcher does not contain the build checksum' }
        if ($text -match '\{\{') { throw 'Launcher still contains template placeholders' }
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($errors) { throw "Launcher does not parse: $($errors[0].Message)" }
    }

    It 'is deterministic' {
        $second = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-build-$([guid]::NewGuid())"
        try {
            & (Join-Path $root 'build.ps1') -Output $second | Out-Null
            $a = (Get-FileHash -LiteralPath $app).Hash
            $b = (Get-FileHash -LiteralPath (Join-Path $second 'WinKit.ps1')).Hash
            if ($a -ne $b) { throw 'Two builds of the same source differ' }
        }
        finally { Remove-Item -LiteralPath $second -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'embeds every resource the app loads' {
        $text = Get-Content -LiteralPath $app -Raw
        foreach ($r in 'config/tweaks.json', 'config/apps.json', 'src/ui/MainWindow.xaml', 'VERSION') {
            if (-not $text.Contains("`$script:WKEmbedded['$r']")) { throw "$r is not embedded" }
        }
    }

    It 'starts from the single file using only embedded resources' {
        # Everything except the final Start-WinKit call, run in a clean STA
        # process with no source tree next to it.
        $body = (Get-Content -LiteralPath $app -Raw) -replace 'Start-WinKit @PSBoundParameters\s*$', ''
        $probe = Join-Path $out 'probe.ps1'
        $check = @'
$script:WK = Initialize-WKContext
$w = New-WKWindow
if (-not $w.FindName('PageOverview')) { exit 3 }
if (@($WK.Config.Tweaks.tweaks).Count -lt 30) { exit 4 }
if ($script:WKRoot) { exit 5 }
exit 0
'@
        [System.IO.File]::WriteAllText($probe, $body + "`r`n" + $check, (New-Object System.Text.UTF8Encoding $true))
        $p = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File `"$probe`"" -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "Single-file build failed to start (exit $($p.ExitCode))" }
    }

    It 'loads the embedded XAML into a window' {
        Add-Type -AssemblyName PresentationFramework
        $xaml = [System.IO.File]::ReadAllText((Join-Path $root 'src/ui/MainWindow.xaml'))
        $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
        if (-not $window.FindName('PageOverview')) { throw 'XAML loaded but named elements are missing' }
    }
}
