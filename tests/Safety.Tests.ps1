# Static guarantees that are easy to promise in the README and easy to break
# by accident. If one of these fails, the change needs a very good reason.

Describe 'Safety invariants' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Filter '*.ps1')
        $code = @{}
        foreach ($f in $sources) {
            # Strip comments so documentation can mention what the code must not do.
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            $code[$f.FullName.Substring($root.Length + 1)] = ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object Text) -join ' '
        }
        function Find-Pattern([string]$Pattern) {
            # Lower-case both sides and match case-sensitively: culture-aware
            # IgnoreCase breaks on a Turkish system ('I' lower-cases to a dotless i).
            $needle = $Pattern.Replace('(?i)', '').ToLowerInvariant()
            @($code.Keys | Where-Object { $code[$_].ToLowerInvariant() -cmatch $needle })
        }
    }

    It 'never evaluates strings as code' {
        # Look at actual command invocations, so messages that tell people to
        # run "irm ... | iex" do not count.
        foreach ($f in $sources) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $calls) {
                $name = "$($c.GetCommandName())".ToLowerInvariant()
                if ($name -in 'invoke-expression', 'iex') { throw "Invoke-Expression used in $($f.Name) line $($c.Extent.StartLineNumber)" }
            }
        }
    }

    It 'never downloads and runs files' {
        $hits = Find-Pattern '(?i)DownloadString|DownloadFile|Start-BitsTransfer|Invoke-WebRequest'
        if ($hits.Count) { throw "Downloads found in: $($hits -join ', ')" }
    }

    It 'only calls the GitHub releases API over the network from PowerShell' {
        $hits = Find-Pattern '(?i)Invoke-RestMethod'
        foreach ($h in $hits) {
            if ($h -notlike '*Settings.ps1') { throw "Unexpected Invoke-RestMethod in $h" }
        }
    }

    It 'always pins winget to the official source' {
        # Every winget argument list lives in the Apps module: export,
        # install/uninstall/upgrade of one package, and upgrade --all.
        $apps = $code[($code.Keys | Where-Object { $_ -like '*modules\Apps.ps1' })]
        $pinned = [regex]::Matches($apps, "'--source'\s*,\s*'winget'").Count
        if ($pinned -lt 3) { throw "Expected every winget call to pass --source winget, found $pinned" }
        $hits = Find-Pattern "(?i)'msstore'"
        if ($hits.Count) { throw "The Microsoft Store source is used in: $($hits -join ', ')" }
        $others = @($code.Keys | Where-Object { $_ -notlike '*modules\Apps.ps1' -and $code[$_] -match '(?i)Get-WKWinget\b' })
        foreach ($o in $others) {
            if ($code[$o] -match "(?i)'--id'") { throw "$o builds its own winget command line" }
        }
    }

    It 'never disables security features' {
        $hits = Find-Pattern '(?i)Set-MpPreference|DisableRealtimeMonitoring|Set-NetFirewallProfile|EnableLUA|Remove-MpPreference|Add-MpPreference'
        if ($hits.Count) { throw "Security settings touched in: $($hits -join ', ')" }
    }

    It 'keeps sources ASCII so Windows PowerShell reads them correctly' {
        foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File |
                 Where-Object { $_.Extension -in '.ps1', '.psd1', '.json', '.xaml' -and $_.FullName -notmatch '\\dist\\' }) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($text -cmatch '[^\x09\x0A\x0D\x20-\x7E]') { throw "$($f.Name) contains non-ASCII characters" }
        }
    }
}
