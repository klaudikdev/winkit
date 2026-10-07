# Architecture

WinKit is a Windows PowerShell 5.1 application with a WPF interface. It ships as a single script so it can run without installation, but it is developed as small files.

```
config/            What WinKit knows about: tweaks, profiles, apps, network
                   endpoints and developer stacks. Plain JSON.
src/core/          Context, logging, registry access, history, restore points,
                   elevation. No UI code.
src/modules/       Features: tweak engine, winget, health checks, network, developer
                   tools, report export. No UI code.
src/ui/            MainWindow.xaml, element factories, task runner, theming,
                   navigation and one file per page.
src/WinKit.ps1     Development entry point: loads the files above from disk.
templates/         The launcher served at klaudik.com/win.
build.ps1          Concatenates everything into dist/WinKit.ps1 with config and
                   XAML embedded, then writes the checksum and the pinned launcher.
tests/             Pester tests (run on Pester 3.4 and 5).
tools/             UI test, elevated test, screenshot renderer, catalog checker,
                   docs generator.
```

## Data-driven tweaks

A tweak is a list of actions of seven types: `registry`, `service`, `task`, `feature`, `powerplan`, `shell` (Folder Options flags set through `SHGetSetSettings`) and `spi` (settings applied through `SystemParametersInfo`). For each type the engine in `src/modules/Tweaks.ps1` knows how to:

- read the current state (`Get-WKActionState`)
- move to the tweak's value or to the Windows default (`Invoke-WKTweakAction`)
- describe the change in plain text (`Format-WKChange`)
- restore a recorded state (`Undo-WKChange`)

Applying a tweak skips actions that are already in the target state and records the rest, with their previous state, as one history entry. Undo walks the entry's changes in reverse. This is why new tweaks never need their own undo code.

Writing the registry is not always enough. Explorer and the taskbar cache many settings, and mouse, animation and accessibility settings only change when set through `SystemParametersInfo`. The `shell` and `spi` actions use the same APIs as the Settings app (`src/core/Native.ps1`), and a tweak can list `notify` areas (for example `TraySettings`) that are broadcast with `WM_SETTINGCHANGE` after it is applied or undone. `tools/Test-Effects.ps1` checks the result a user would see, not just the registry.

Registry access goes through `Microsoft.Win32.RegistryKey` in the 64-bit view rather than the PowerShell provider. That keeps value kinds exact, supports the `(Default)` value and avoids `New-Item -Force` recreating existing keys.

## Threading

WPF requires the UI thread to stay free. Anything that touches the system or the network runs through `Start-WKTask` in `src/ui/Shell.ps1`:

- a new runspace is created from an `InitialSessionState` that contains every `*-WK*` function and the shared `$WK` context
- only one task runs at a time, so system changes never overlap; background refreshes queue behind it
- a `DispatcherTimer` on the UI thread drains the log queue into the Activity panel and calls the task's completion block with its output

History, settings and logs live in `%ProgramData%\Klaudik\WinKit\<user SID>`, which WinKit locks down to SYSTEM and Administrators: an elevated process must not trust data any user can rewrite. A non-elevated development run (`-NoElevate`) uses `%LOCALAPPDATA%\Klaudik\WinKit` instead. `$WK` is a synchronized hashtable; the log is a `ConcurrentQueue`. Completion blocks never rely on closures: anything they need is either returned by the task or stored in `$script:State` before the task starts.

## Culture

WinKit runs on Windows in every display language. Under a Turkish culture, .NET's culture-aware case-insensitive matching maps `I` to a dotless `ı` there, so patterns with letter ranges use `-cmatch`, `RegexOptions.CultureInvariant` or `StringComparison.OrdinalIgnoreCase`. PowerShell's `-eq`, `-contains` and `switch` are culture-invariant and safe.

## Build output

`build.ps1` produces a deterministic file: sources are normalized to LF before being joined, written with CRLF and a UTF-8 BOM, and checked with the PowerShell parser before anything is written. The generated launcher embeds the version and SHA-256 of that file.
