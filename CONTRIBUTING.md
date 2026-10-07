# Contributing

Thanks for helping improve WinKit. Bug reports, new tweaks, app suggestions and fixes are all welcome.

## Ground rules

Every change that ends up on someone's PC must be:

1. **Reversible.** WinKit records the previous state automatically, but each action also needs a sensible Windows default so it can be undone when there is no history.
2. **Explained.** The title and description must say, in plain language, what the user will notice.
3. **Honest about risk.** Mark anything that can break an app or a workflow as `medium`.
4. **Safe.** No tweak may weaken Defender, the firewall, Windows Update, UAC or SmartScreen. Pull requests that do are closed.

## Adding a tweak

Tweaks are data in [`config/tweaks.json`](config/tweaks.json):

```json
{
  "id": "privacy.example",
  "category": "privacy",
  "title": "Short imperative title",
  "description": "One or two sentences about what changes for the user.",
  "risk": "low",
  "restart": "none",
  "windows": [11],
  "minBuild": 22631,
  "actions": [
    { "type": "registry", "path": "HKCU\\Software\\...", "name": "Value", "kind": "DWord", "value": 0, "defaultValue": 1 }
  ]
}
```

| Field | Values |
| --- | --- |
| `id` | `<category>.<kebab-case-name>`, unique |
| `risk` | `low`, `medium`, `high` |
| `restart` | `none`, `explorer`, `signout`, `reboot` |
| `windows`, `minBuild` | optional compatibility limits |
| `server` | optional; `false` when Windows Server uses different defaults, so the tweak is not offered there |
| `notify` | optional list of `WM_SETTINGCHANGE` areas to broadcast after a change: `TraySettings` (taskbar), `ImmersiveColorSet` (theme), `ShellState`, `Policy`, `Environment` |

Action types:

| `type` | Fields |
| --- | --- |
| `registry` | `path` (HKCU or HKLM), `name` (`""` for the default value), `kind` (`DWord`, `QWord`, `String`, `ExpandString`, `MultiString`, `Binary`), `value`, optional `defaultValue` (omit it if the Windows default is "value not present"), optional `ownedKey` (a key that only exists because of this tweak; restoring the Windows default removes it when empty) |
| `service` | `name`, `startup` and `defaultStartup` (`Automatic`, `AutomaticDelayed`, `Manual`, `Disabled`) |
| `task` | `path` (with leading and trailing backslash), `name`, `state` and `defaultState` (`Enabled`, `Disabled`) |
| `feature` | `name` (optional Windows feature), `state` and `defaultState` |
| `powerplan` | `scheme` and `defaultScheme` (`high`, `balanced`, `saver`) |
| `shell` | `flag` (`showExtensions`, `showHidden`), `value` and `defaultValue` (`true`/`false`). Applied through the shell so open windows update |
| `spi` | `setting` (`mouse` as `[threshold1, threshold2, speed]`, `menuDelay` in ms, `minAnimate`, `clientAreaAnimation`, `stickyKeysHotkey`), `value` and `defaultValue`. Applied immediately through `SystemParametersInfo` |

After editing, regenerate the reference and run the tests:

```powershell
.\tools\Update-Docs.ps1
.\tests\Run-Tests.ps1
```

Before opening the pull request, check that the tweak really changes what it promises, on a real machine or a VM, and mention the Windows build you tested on. Add a check for it to `tools/Test-Effects.ps1` and run it from an elevated PowerShell started from the Start menu:

```powershell
.\tools\Test-Effects.ps1 -Only 'privacy.example'
```

Writing a value is not the same as changing Windows: Explorer caches many settings, some are only read at sign-in, and a few are protected by Windows against scripts.

## Adding an app

Add an entry to [`config/apps.json`](config/apps.json) with the exact winget id, then check that it resolves:

```powershell
.\tools\Test-WingetCatalog.ps1
```

We favor well-known, actively maintained apps that install silently. Apps whose installers bundle unrelated offers are not accepted.

## Code

- Target Windows PowerShell 5.1. Do not use PowerShell 7-only syntax (`??`, `?.`, ternaries, `-Parallel`).
- Keep sources ASCII. `build.ps1` refuses anything else because Windows PowerShell reads BOM-less files in the system code page.
- Use `-cmatch` or culture-invariant comparisons for patterns with letter ranges. On Turkish systems a case-insensitive `[A-Za-z]` does not match `I`.
- Anything slow or anything that changes the system runs in a background task (`Start-WKTask`), never on the UI thread.
- Functions are named `Verb-WKNoun`; background runspaces load every function with `-WK` in its name.

Run the full check before pushing (if scripts are blocked, run `Set-ExecutionPolicy -Scope Process Bypass` first):

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
.\tests\Run-Tests.ps1
powershell -STA -ExecutionPolicy Bypass -File .\tools\Test-UI.ps1
```

## Releasing (maintainers)

1. Update `VERSION` and `CHANGELOG.md`.
2. Run `.\tools\Test-WingetCatalog.ps1`, then `.\tools\Test-Elevated.ps1 -IncludeRealTweaks -IncludeDns` and `.\tools\Test-Effects.ps1` from an elevated PowerShell started from the Start menu (not from an app's built-in terminal).
3. Tag the commit `vX.Y.Z` and push the tag. The release workflow builds, tests and publishes `WinKit.ps1`, its checksum and `win.ps1`.
4. Deploy the new `win.ps1` to klaudik.com as described in [docs/HOSTING.md](docs/HOSTING.md).
