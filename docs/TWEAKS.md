# Tweak reference

This file is generated from [`config/tweaks.json`](../config/tweaks.json) by `tools/Update-Docs.ps1`. It lists every change WinKit can make, exactly as the code applies it.

Before any tweak is applied, WinKit reads and stores the current value of every setting it is about to touch. **Undo** writes those stored values back. If a tweak was applied outside WinKit, **Undo** falls back to the Windows default shown below.

## Privacy

### Disable advertising ID

Stops apps from using a per-user advertising identifier to personalize ads across apps.

Id: `privacy.advertising-id` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled` | `0` | `1` |

### Disable tailored experiences

Microsoft will no longer use your diagnostic data to show personalized tips, ads and offers. Shown as Personalized offers in newer versions of Settings.

Id: `privacy.tailored-experiences` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy\TailoredExperiencesWithDiagnosticDataEnabled` | `0` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy\PersonalizedOffersEnabled` | `0` | value removed |

### Stop suggestions and sponsored app installs

Stops Windows from silently installing sponsored apps and turns off Start and Settings suggestions, the welcome screen after updates and the 'finish setting up your device' screen. Sponsored apps that are already installed are not removed.

Id: `privacy.suggested-content` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SilentInstalledAppsEnabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SystemPaneSuggestionsEnabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SoftLandingEnabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-338388Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-338389Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-353694Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-353696Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-338393Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-310093Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement\ScoobeSystemSettingEnabled` | `0` | value removed |

### Hide tips and fun facts on the lock screen

Keeps the lock screen clean by removing Microsoft tips, tricks and promotional overlays. Windows Spotlight always shows its own captions, so this applies when the lock screen uses a picture or slideshow.

Id: `privacy.lock-screen-tips` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\RotatingLockScreenOverlayEnabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-338387Enabled` | `0` | `1` |

### Remove web results from Start search

Start and taskbar search stop showing Bing web results, so what you type is not sent to Bing. Set as a policy, which also hides recent searches in File Explorer.

Id: `privacy.web-search` | Risk: low | Takes effect: After signing out

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions` | `1` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Search\BingSearchEnabled` | `0` | value removed |

### Disable activity history

Windows stops collecting the apps, files and pages you open and does not upload them to Microsoft.

Id: `privacy.activity-history` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\EnableActivityFeed` | `0` | value removed |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\PublishUserActivities` | `0` | value removed |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\UploadUserActivities` | `0` | value removed |

### Send only required diagnostic data

Sets the diagnostic data policy to the lowest level your Windows edition supports and hides feedback prompts. Settings shows this as managed by your organization. Do not use on Windows Insider PCs, which need optional diagnostic data.

Id: `privacy.diagnostic-data` | Risk: medium | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry` | `0` | value removed |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\DoNotShowFeedbackNotifications` | `1` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Siuf\Rules\NumberOfSIUFInPeriod` | `0` | value removed |

### Disable the telemetry services

Turns off the Connected User Experiences and Telemetry service and the Device Management WAP Push message routing service. Do not use on PCs managed by Intune or another MDM, which need the WAP push service to sync.

Id: `privacy.telemetry-service` | Risk: medium | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Service startup | `DiagTrack` | Disabled | Automatic |
| Service startup | `dmwappushservice` | Disabled | Manual |

### Disable telemetry scheduled tasks

Disables the compatibility appraiser, customer experience improvement and feedback tasks that collect usage data in the background. The appraiser also feeds Windows Update's upgrade compatibility checks, so on Windows 10 the Windows 11 upgrade offer can be delayed.

Id: `privacy.telemetry-tasks` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Scheduled task | `\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Application Experience\ProgramDataUpdater` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Application Experience\MareBackup` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Customer Experience Improvement Program\Consolidator` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Feedback\Siuf\DmClient` | Disabled | Enabled |
| Scheduled task | `\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload` | Disabled | Enabled |

### Stop inking and typing personalization

Windows stops building a personal dictionary from what you type and write, does not harvest your contacts for it and does not send typing data to Microsoft.

Id: `privacy.inking-typing` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\InputPersonalization\RestrictImplicitInkCollection` | `1` | `0` |
| Registry (DWord) | `HKCU\Software\Microsoft\InputPersonalization\RestrictImplicitTextCollection` | `1` | `0` |
| Registry (DWord) | `HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore\HarvestContacts` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Personalization\Settings\AcceptedPrivacyPolicy` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Input\TIPC\Enabled` | `0` | value removed |

### Disable online speech recognition

Voice input stays on your device. Voice typing (Win + H) stops working; device-based features such as Narrator keep working.

Id: `privacy.online-speech` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy\HasAccepted` | `0` | value removed |

### Stop tracking app launches

Windows no longer records which apps you open to rank Start and search results. The 'Most used' list will be empty.

Id: `privacy.app-launch-tracking` | Risk: low | Takes effect: After File Explorer restarts

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\Start_TrackProgs` | `0` | `1` |

### Turn off location access

Turns off location for the whole device with the Windows policy for it. Maps, Weather, Find my device and automatic time zone will not know where you are, and Settings shows location as managed by your organization.

Id: `privacy.location` | Risk: medium | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors\DisableLocation` | `1` | value removed |

### Disable Recall snapshots

Prevents Windows from saving periodic snapshots of your screen, for every account on this PC. Recall only exists on Copilot+ PCs.

Id: `privacy.recall` | Risk: low | Takes effect: After signing out | Windows 11 only | Build 26100+

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis` | `1` | value removed |
| Registry (DWord) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis` | `1` | value removed |

## Performance

### Use the High performance power plan

Keeps the CPU ready at higher clock speeds. Best for desktops; on laptops it shortens battery life.

Id: `performance.high-performance-plan` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Power plan | Active scheme | high | balanced |

### Remove the startup app delay

Windows waits after sign-in, until the system is idle, before launching startup apps. This removes the wait. Takes effect from your next sign-in.

Id: `performance.startup-delay` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\StartupDelayInMSec` | `0` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\WaitForIdleState` | `0` | value removed |

### Open menus faster

Shortens the hover delay before cascading menus open from 400 ms to 100 ms.

Id: `performance.menu-delay` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| System setting (SystemParametersInfo) | Menu show delay (ms) | `100` | `400` |

### Turn off window and taskbar animations

Turns off minimize and maximize animations and Windows animation effects, so windows, menus and the taskbar respond without transitions. Apps that follow the setting, such as Settings, stop animating too.

Id: `performance.reduce-animations` | Risk: low | Takes effect: After File Explorer restarts

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| System setting (SystemParametersInfo) | Minimize and maximize animation | Off | On |
| System setting (SystemParametersInfo) | Animation effects | Off | On |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarAnimations` | `0` | `1` |

### Stop Store apps running in the background

Store apps no longer run in the background. Apps that rely on background activity may deliver notifications late. Takes effect after you sign in again.

Id: `performance.background-apps` | Risk: medium | Takes effect: After signing out

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\GlobalUserDisabled` | `1` | `0` |

## Explorer & Taskbar

### Show file name extensions

Always shows extensions like .exe or .pdf, which makes disguised files easy to spot.

Id: `explorer.file-extensions` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Folder option (through the shell) | Show file name extensions | On | Off |

### Show hidden files and folders

Files and folders marked as hidden appear in File Explorer. Protected system files stay hidden.

Id: `explorer.hidden-files` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Folder option (through the shell) | Show hidden files | On | Off |

### Open File Explorer to This PC

File Explorer starts on your drives instead of Home or Quick access.

Id: `explorer.open-this-pc` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\LaunchTo` | `1` | value removed |

### Hide recent and frequent items

Quick access and Home stop listing recently opened files and frequently used folders.

Id: `explorer.hide-recent` | Risk: low | Takes effect: After File Explorer restarts

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ShowRecent` | `0` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ShowFrequent` | `0` | value removed |

### Use the full right-click menu

Brings back the complete context menu so you do not have to click 'Show more options'.

Id: `explorer.classic-context-menu` | Risk: low | Takes effect: After File Explorer restarts | Windows 11 only

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (String) | `HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32\(Default)` | (empty string) | value removed |

### Align taskbar icons to the left

Moves the Start button and taskbar icons to the left edge, like earlier versions of Windows.

Id: `explorer.taskbar-left` | Risk: low | Takes effect: Immediately | Windows 11 only

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarAl` | `0` | `1` |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: TraySettings) so it applies without a restart.

### Hide the Task View button

Removes the Task View button from the taskbar. Win + Tab still works.

Id: `explorer.hide-task-view` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ShowTaskViewButton` | `0` | value removed |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: TraySettings) so it applies without a restart.

### Show search as an icon

Replaces the wide taskbar search box with a compact icon.

Id: `explorer.search-icon` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Search\SearchboxTaskbarModeCache` | `1` | value removed |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Search\SearchboxTaskbarMode` | `1` | `2` |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: TraySettings) so it applies without a restart.

### Show seconds in the taskbar clock

Adds seconds to the system clock. Uses a little more power on battery.

Id: `explorer.clock-seconds` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ShowSecondsInSystemClock` | `1` | value removed |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: TraySettings) so it applies without a restart.

### Use dark mode

Switches Windows and apps that follow the system theme to dark mode.

Id: `explorer.dark-mode` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme` | `0` | `1` |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: ImmersiveColorSet) so it applies without a restart.

## Gaming

### Disable Game Bar capture

Turns off Xbox Game Bar recording and screenshots, including background recording, so capture never runs while you play.

Id: `gaming.game-dvr` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\System\GameConfigStore\GameDVR_Enabled` | `0` | `1` |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\AppCaptureEnabled` | `0` | value removed |

### Disable mouse acceleration

Turns off 'Enhance pointer precision' so the cursor moves exactly as far as your hand does.

Id: `gaming.mouse-acceleration` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| System setting (SystemParametersInfo) | Mouse acceleration (threshold 1, threshold 2, speed) | `0, 0, 0` | `6, 10, 1` |

### Disable the Sticky Keys shortcut

Pressing Shift five times no longer opens the Sticky Keys prompt in the middle of a game.

Id: `gaming.sticky-keys` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| System setting (SystemParametersInfo) | Sticky Keys shortcut (Shift five times) | Off | On |

### Enable hardware-accelerated GPU scheduling

Moves GPU work scheduling from Windows to a dedicated scheduler on the graphics card, which can lower latency. Needs a supported GPU and a recent driver; already on by default on many newer PCs.

Id: `gaming.gpu-scheduling` | Risk: medium | Takes effect: After a restart

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode` | `2` | value removed |

## Developer

### Enable Developer Mode

Lets you install apps from loose files, create symbolic links without elevation and use other developer features.

Id: `developer.developer-mode` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense` | `1` | `0` |

### Enable long file paths

Removes the 260-character path limit for apps that support it, such as PowerShell 7, Node.js and Python. Git also needs git config --global core.longpaths true. File Explorer keeps the old limit.

Id: `developer.long-paths` | Risk: low | Takes effect: After a restart

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` | `1` | `0` |

### Add 'End task' to the taskbar menu

Right-click any taskbar app to force close it without opening Task Manager.

Id: `developer.end-task` | Risk: low | Takes effect: Immediately | Windows 11 only | Build 22631+

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings\TaskbarEndTask` | `1` | value removed |

After the change WinKit notifies Windows (`WM_SETTINGCHANGE`: TraySettings) so it applies without a restart.

### Show the full path in File Explorer

The File Explorer title and tabs show the complete folder path. Applies to windows you open from now on.

Id: `developer.full-path-title` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState\FullPath` | `1` | `0` |

### Start the OpenSSH agent automatically

Runs the Windows OpenSSH agent so keys added with ssh-add are remembered, even across restarts. Git uses it only when configured to use Windows OpenSSH (core.sshCommand).

Id: `developer.ssh-agent` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Service startup | `ssh-agent` | Automatic | Disabled |

### Enable Windows Subsystem for Linux

Turns on the WSL and Virtual Machine Platform features. After restarting, install a distribution (for example with the Install Ubuntu button) to start using Linux. Virtual Machine Platform can slow down other hypervisors such as older VirtualBox versions.

Id: `developer.wsl` | Risk: low | Takes effect: After a restart

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Windows feature | `Microsoft-Windows-Subsystem-Linux` | Enabled | Disabled |
| Windows feature | `VirtualMachinePlatform` | Enabled | Disabled |

### Enable Windows Sandbox

A disposable desktop for testing untrusted software. Available on Pro, Enterprise and Education editions with virtualization turned on in the firmware.

Id: `developer.sandbox` | Risk: low | Takes effect: After a restart

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Windows feature | `Containers-DisposableClientVM` | Enabled | Disabled |

### Enable Hyper-V

Microsoft's hypervisor for running full virtual machines. Available on Pro, Enterprise and Education editions. Older VirtualBox or VMware versions and some game anti-cheat software may stop working or run slower.

Id: `developer.hyper-v` | Risk: medium | Takes effect: After a restart

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Windows feature | `Microsoft-Hyper-V-All` | Enabled | Disabled |

## Security

### Disable AutoPlay

Nothing runs or opens automatically when you connect a USB drive, memory card or phone.

Id: `security.autoplay` | Risk: low | Takes effect: Immediately

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers\DisableAutoplay` | `1` | `0` |

### Disable Remote Assistance

Nobody can be invited to view or control this PC through Remote Assistance. Remote Desktop is not affected.

Id: `security.remote-assistance` | Risk: low | Takes effect: Immediately | Not on Windows Server

| Type | Target | Applied value | Windows default |
| --- | --- | --- | --- |
| Registry (DWord) | `HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance\fAllowToGetHelp` | `0` | `1` |

## Profiles

- **Essentials**: Low-risk fixes that suit almost every PC. Disable advertising ID; Disable tailored experiences; Stop suggestions and sponsored app installs; Hide tips and fun facts on the lock screen; Remove web results from Start search; Remove the startup app delay; Show file name extensions; Disable AutoPlay; Disable Remote Assistance.
- **Privacy**: Share less with Microsoft and advertisers. Disable advertising ID; Disable tailored experiences; Stop suggestions and sponsored app installs; Hide tips and fun facts on the lock screen; Remove web results from Start search; Disable activity history; Send only required diagnostic data; Disable the telemetry services; Disable telemetry scheduled tasks; Stop inking and typing personalization; Disable online speech recognition; Stop tracking app launches; Disable Recall snapshots; Hide recent and frequent items.
- **Gaming**: Fewer interruptions while you play and no background capture. Disable Game Bar capture; Disable mouse acceleration; Disable the Sticky Keys shortcut; Use the High performance power plan; Remove the startup app delay; Stop Store apps running in the background; Stop suggestions and sponsored app installs.
- **Developer**: Developer Mode, long paths, visible extensions and hidden files, and the other settings developers change first. Enable Developer Mode; Enable long file paths; Add 'End task' to the taskbar menu; Show the full path in File Explorer; Start the OpenSSH agent automatically; Show file name extensions; Show hidden files and folders; Open File Explorer to This PC; Use the full right-click menu; Remove web results from Start search.
- **Clean desktop**: A quiet, distraction-free taskbar and Start menu. Hide the Task View button; Show search as an icon; Use the full right-click menu; Stop suggestions and sponsored app installs; Hide tips and fun facts on the lock screen; Remove web results from Start search.
