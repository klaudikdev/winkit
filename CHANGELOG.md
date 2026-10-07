# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-07

First public release.

### Added

- Overview page with a system health score, hardware summary and a shareable HTML report.
- Apps page with 79 curated winget packages, search, categories, bulk install, uninstall and update, plus import and export of selections.
- Developer page with toolchain detection, installable stacks, Git identity, Ed25519 SSH key generation and WSL setup.
- 43 reversible tweaks across privacy, performance, Explorer, gaming, developer and security, with five profiles.
- Network page with latency to 33 cloud regions, a DNS benchmark and DNS switching.
- History page to review and undo every change.
- Preview mode, automatic System Restore points, light and dark themes.
- Hash-pinned launcher for `irm https://klaudik.com/win | iex`.
- Every tweak is verified on a real PC by `tools/Test-Effects.ps1`, which checks the visible result (taskbar, File Explorer, Windows APIs) and that undo restores every value.
- Refuses to run inside app containers that give programs a private copy of the registry, where changes would never reach Windows.

[1.0.0]: https://github.com/klaudikdev/winkit/releases/tag/v1.0.0
