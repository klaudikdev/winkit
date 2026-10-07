# Security

WinKit runs with administrator rights and changes system settings, so we hold it to a high bar. This page explains how it is built to be safe and how to tell us if you find a problem.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead: go to the **Security** tab of this repository and choose **Report a vulnerability**. Include the WinKit version, your Windows build and the steps to reproduce.

We aim to acknowledge reports within three working days and to ship a fix for confirmed issues as soon as possible. We will credit you in the release notes unless you prefer otherwise.

Only the latest release is supported.

## How WinKit is delivered

```
irm https://klaudik.com/win | iex
```

1. `https://klaudik.com/win` serves a small launcher that `build.ps1` generates from [`templates/launcher.ps1`](templates/launcher.ps1) for one specific release. It contains that release's version and the SHA-256 of its `WinKit.ps1`.
2. The launcher downloads `WinKit.ps1` from the GitHub release over HTTPS and compares its SHA-256 with the pinned value. On a mismatch the file is deleted and nothing runs.
3. The launcher starts an elevated Windows PowerShell with a short bootstrap script. Its first line limits module loading to the folders that ship with Windows, before any command runs, so modules planted in your Documents folder are never loaded with administrator rights. The bootstrap then reads the file into memory, hashes those bytes again and executes the same bytes from memory, so a process that modifies the file in `%TEMP%` between the check and the UAC prompt gets nothing but a refusal.

The pinned checksum protects against a tampered or replaced GitHub release file. It does not protect against a compromised klaudik.com, because that server delivers the launcher itself. If you prefer not to trust klaudik.com, download the release from GitHub and verify it yourself (see "Run without the launcher" in the README). Every release publishes `WinKit.ps1.sha256`, and builds are deterministic: running `build.ps1` on the tagged commit reproduces the exact same file and hash.

## What WinKit will and will not do

WinKit **never**:

- disables Microsoft Defender, the Windows firewall, Windows Update, UAC or SmartScreen
- downloads or runs installers itself (apps come only from the official `winget` source)
- runs any code other than the release file it verified (no `Invoke-Expression` after the launcher, no scripts downloaded after start)
- deletes your files or overwrites SSH keys
- collects telemetry

The first three rules are checked by [`tests/Safety.Tests.ps1`](tests/Safety.Tests.ps1) and [`tests/Config.Tests.ps1`](tests/Config.Tests.ps1) on every pull request; the others are guaranteed by the code (for example, SSH key generation refuses to run if a key exists) and checked in review.

Network connections happen only for winget (including the installed-apps check when you first open the Apps or Developer page), the cloud latency test (DNS lookups and TCP handshakes only), the DNS benchmark, the update check against the GitHub API when you press Check for updates, and `wsl --install` when you choose to install a distribution.

## Reversibility

When WinKit changes a registry value, service, scheduled task, Windows feature, power plan, system setting or DNS setting, it records the previous state the moment the change is made, one change at a time, in `%ProgramData%\Klaudik\WinKit\<your SID>`, a folder WinKit locks down to SYSTEM and Administrators (you keep read access for the logs). Undo restores that state exactly, including the registry value type and whether the value existed. Because undo writes with administrator rights, each recorded change is checked against the tweak it belongs to before it is applied (or, for a tweak a later version removed, against an allow-list of the places WinKit tweaks change); anything else, including every Defender, Windows Update and code-execution setting, is refused. Keys that WinKit created are removed on undo only when they are empty. A System Restore point is created before the first tweak of each session unless you turn this off (Windows Server has no System Restore).

## Threat model

WinKit defends the path from the download to the elevated process, and it defends what an elevated WinKit trusts afterwards: the history and settings it reads back, and the programs it runs (`winget`, `git`, `sc`, `powercfg`, `ssh-keygen`, `wsl`) all come from locations a standard user cannot write to:

- `winget` is only taken from Microsoft's signed App Installer package in `C:\Program Files\WindowsApps`, never from a package registered in Developer Mode.
- `git` is only taken from machine `PATH` folders under Program Files or Windows whose permissions keep standard users out; `PATH` is read unexpanded, so variables a user can set do not count.
- PowerShell modules are only loaded from the folders that ship with Windows.
- Temporary files, including the C# compiled for Windows API calls, go to an administrator-only folder instead of your `%TEMP%`.
- Explorer is never started with administrator rights; if it has to be restarted, it is started as you.
- WinKit refuses to run inside app containers that give programs a private copy of the registry, where its changes would never reach Windows.

What it cannot defend against, and neither can any other administrator tool: code already running as you on an account that can elevate. Microsoft does not treat UAC as a security boundary, and such code can tamper with any elevated process it starts. If your account is compromised, no script can fix that.

## Scope

In scope: the launcher, the build output, and any way WinKit could change something it did not describe, fail to undo a change, run code that was not verified, or expose data.

Out of scope: problems in third-party apps installed through winget (report those to the app or to [winget-pkgs](https://github.com/microsoft/winget-pkgs)), and the documented effects of a tweak you chose to apply.
