# Shared application state.
#
# $WK is a synchronized hashtable so the UI thread and background runspaces
# can read settings and push log entries without extra locking.

function Get-WKResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Release builds embed every resource; development runs read from disk.
    if ($script:WKEmbedded -and $script:WKEmbedded.ContainsKey($Name)) {
        return $script:WKEmbedded[$Name]
    }
    if (-not $script:WKRoot) { throw "Resource '$Name' is not embedded and no source root is set." }

    $path = Join-Path $script:WKRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Resource not found: $Name" }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

$script:WKPrivilegedSids = @(
    'S-1-5-18',                                                        # SYSTEM
    'S-1-5-19',                                                        # LOCAL SERVICE
    'S-1-5-20',                                                        # NETWORK SERVICE
    'S-1-5-32-544',                                                    # Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'   # TrustedInstaller
)

function New-WKProtectedAcl {
    # SYSTEM and Administrators may write; the current user may read (to open logs).
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in $admins, $system) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')))
    }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'ReadAndExecute', $inherit, $none, 'Allow')))
    return $acl
}

function Test-WKProtectedDirectory {
    <# True when $Path is a real folder owned by, and writable only by, SYSTEM and Administrators. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $dir = New-Object System.IO.DirectoryInfo $Path
    if (-not $dir.Exists -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    $acl = $dir.GetAccessControl()
    $trusted = 'S-1-5-32-544', 'S-1-5-18'
    if ($trusted -notcontains $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }

    $rights = [System.Security.AccessControl.FileSystemRights]
    $write = $rights::WriteData -bor $rights::AppendData -bor $rights::WriteExtendedAttributes -bor $rights::WriteAttributes -bor
             $rights::Delete -bor $rights::DeleteSubdirectoriesAndFiles -bor $rights::ChangePermissions -bor $rights::TakeOwnership
    # Also GENERIC_ALL and GENERIC_WRITE, which other tools can put in an ACE.
    $write = [int]$write -bor 0x10000000 -bor 0x40000000
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $trusted -contains $rule.IdentityReference.Value) { continue }
        if ([int]$rule.FileSystemRights -band [int]$write) { return $false }
    }
    return $true
}

function Protect-WKDirectory {
    <#
        Makes sure $Path is a folder only SYSTEM and Administrators can write
        to. A folder that is not already protected, or a link in its place, is
        renamed aside (a rename moves the link itself, never its target) and a
        new folder is created with the protected ACL applied at creation, so
        nothing can slip in between a check and a permission change.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $ErrorActionPreference = 'Stop'
    if ([System.IO.File]::Exists($Path)) { throw "'$Path' is a file, expected a folder." }
    if (Test-WKProtectedDirectory -Path $Path) { return }

    $existing = New-Object System.IO.DirectoryInfo $Path
    if ($existing.Exists -or ([int]$existing.Attributes -ne -1)) {
        # Unique even when this runs twice within a second.
        $aside = '{0}.untrusted-{1:yyyyMMddHHmmss}-{2}' -f $Path, (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 8)
        [System.IO.Directory]::Move($Path, $aside)
    }

    [void][System.IO.Directory]::CreateDirectory($Path, (New-WKProtectedAcl))
    if (-not (Test-WKProtectedDirectory -Path $Path)) {
        throw "Could not create a protected folder at '$Path'."
    }
}

function Get-WKDataDirectory {
    <#
        WinKit runs elevated and trusts its history and settings, so they live
        where only administrators can write: %ProgramData%\Klaudik\WinKit\<user SID>.
        A non-elevated development run uses %LOCALAPPDATA% instead.
    #>
    [CmdletBinding()]
    param([bool]$IsAdmin)

    $ErrorActionPreference = 'Stop'
    if (-not $IsAdmin) {
        $dev = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Klaudik\WinKit'
        if (-not (Test-Path -LiteralPath $dev)) { New-Item -ItemType Directory -Path $dev -Force | Out-Null }
        return $dev
    }

    $path = [Environment]::GetFolderPath('CommonApplicationData')
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($segment in 'Klaudik', 'WinKit', $sid) {
        $path = Join-Path $path $segment
        Protect-WKDirectory -Path $path
    }
    foreach ($child in 'logs', 'tmp') { Protect-WKDirectory -Path (Join-Path $path $child) }
    return $path
}
function Initialize-WKContext {
    [CmdletBinding()]
    param(
        [switch]$Preview
    )

    $isAdmin = Test-WKAdmin
    $dataDir = Get-WKDataDirectory -IsAdmin $isAdmin
    $logDir = Join-Path $dataDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    $ctx = [hashtable]::Synchronized(@{})
    $ctx.Version        = (Get-WKResource 'VERSION').Trim()
    $ctx.ProductName    = 'Klaudik WinKit'
    $ctx.Website        = 'https://klaudik.com'
    $ctx.Repository     = 'https://github.com/klaudikdev/winkit'
    $ctx.ReleasesApi    = 'https://api.github.com/repos/klaudikdev/winkit/releases/latest'
    $ctx.DataDir        = $dataDir
    $ctx.LogDir         = $logDir
    $ctx.LogFile        = Join-Path $logDir ('winkit-{0:yyyyMMdd}.log' -f (Get-Date))
    $ctx.HistoryFile    = Join-Path $dataDir 'history.json'
    $ctx.SettingsFile   = Join-Path $dataDir 'settings.json'
    $ctx.IsAdmin        = $isAdmin
    $ctx.Windows        = Get-WKWindowsInfo
    $ctx.PreviewMode    = [bool]$Preview
    $ctx.RestorePointDone = $false
    $ctx.LogQueue       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $ctx.LogLock        = New-Object object

    $ctx.Config = @{
        Tweaks    = Get-WKResource 'config/tweaks.json'    | ConvertFrom-Json
        Profiles  = Get-WKResource 'config/profiles.json'  | ConvertFrom-Json
        Apps      = Get-WKResource 'config/apps.json'      | ConvertFrom-Json
        Network   = Get-WKResource 'config/network.json'   | ConvertFrom-Json
        Developer = Get-WKResource 'config/developer.json' | ConvertFrom-Json
    }

    $ctx.Settings = Read-WKSettings -Path $ctx.SettingsFile

    if ($isAdmin) {
        # Programs WinKit starts as administrator (the C# compiler behind
        # Add-Type, winget) write to TEMP. The user's own TEMP can be changed
        # by any program the user runs, so use a folder only admins can write.
        $tmp = Join-Path $dataDir 'tmp'
        foreach ($old in @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) })) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        $env:TEMP = $tmp
        $env:TMP = $tmp
    }
    return $ctx
}

function Read-WKSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $settings = @{
        Theme              = 'System'
        CreateRestorePoint = $true
        # Set once the user has accepted the notice shown on first start.
        TermsAccepted      = $false
    }
    if (Test-Path -LiteralPath $Path) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($settings.ContainsKey($p.Name)) { $settings[$p.Name] = $p.Value }
            }
        }
        catch {
            # A corrupt settings file must never stop the app; defaults are fine.
        }
    }
    # Values edited by hand or written by another version must not stop the app.
    if ($settings.Theme -notin 'System', 'Light', 'Dark') { $settings.Theme = 'System' }
    if ($settings.CreateRestorePoint -isnot [bool]) { $settings.CreateRestorePoint = $true }
    if ($settings.TermsAccepted -isnot [bool]) { $settings.TermsAccepted = $false }
    return $settings
}

function Save-WKSettings {
    [CmdletBinding()]
    param()

    $json = ConvertTo-Json -InputObject $WK.Settings -Depth 4
    [System.IO.File]::WriteAllText($WK.SettingsFile, $json, (New-Object System.Text.UTF8Encoding $false))
}
