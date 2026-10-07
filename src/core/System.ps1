function Test-WKAdmin {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WKWindowsInfo {
    [CmdletBinding()]
    param()

    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    $major = if ($build -ge 22000) { 11 } else { 10 }

    # ProductName still says "Windows 10" on Windows 11, so derive it from the build.
    $name = [string]$cv.ProductName
    if ($major -eq 11) { $name = $name -replace 'Windows 10', 'Windows 11' }

    # WinNT is a workstation; ServerNT and LanmanNT are Windows Server.
    $productType = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -ErrorAction SilentlyContinue).ProductType

    $display = [string]$cv.DisplayVersion
    if (-not $display) { $display = [string]$cv.ReleaseId }

    [pscustomobject]@{
        Name           = $name
        Major          = $major
        Build          = $build
        Revision       = [int]$cv.UBR
        DisplayVersion = $display
        Edition        = [string]$cv.EditionID
        Is64Bit        = [Environment]::Is64BitOperatingSystem
        IsServer       = ($productType -and $productType -cne 'WinNT')
    }
}

function Get-WKSystemTool {
    <#
        Full path of a program in System32. Built from the system directory
        rather than %WINDIR% or PATH, which the user can change for an
        elevated process.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path ([Environment]::SystemDirectory) $Name)
}

function Get-WKWindowsPath {
    [CmdletBinding()]
    param([string]$Child)
    $windows = [Environment]::GetFolderPath('Windows')
    if ($Child) { return (Join-Path $windows $Child) }
    return $windows
}

function Get-WKTrustedCommand {
    <#
        Finds a program that WinKit may run as administrator: only in folders
        from the machine PATH that sit under Program Files or Windows, which
        standard users cannot write to. The user's own PATH is ignored.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $windows = Get-WKWindowsPath
    $roots = @($programFiles, $programFilesX86, $windows) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }

    # Read PATH unexpanded: the process's own variables can be set by the
    # user (HKCU\Environment), so only the system folders are substituted.
    $known = @{
        '%SystemRoot%' = $windows; '%windir%' = $windows; '%SystemDrive%' = [System.IO.Path]::GetPathRoot($windows).TrimEnd('\')
        '%ProgramFiles%' = $programFiles; '%ProgramW6432%' = $programFiles; '%ProgramFiles(x86)%' = $programFilesX86
    }
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
    if (-not $key) { return $null }
    try { $raw = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames') } finally { $key.Close() }

    foreach ($entry in $raw -split ';' | Where-Object { $_.Trim() }) {
        $dir = $entry.Trim()
        foreach ($k in $known.Keys) {
            $i = $dir.IndexOf($k, [StringComparison]::OrdinalIgnoreCase)
            if ($i -ge 0) { $dir = $dir.Substring(0, $i) + $known[$k] + $dir.Substring($i + $k.Length) }
        }
        if ($dir.Contains('%')) { continue }
        try { $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\') + '\' } catch { continue }
        if (-not @($roots | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        if (-not (Test-WKAdminOnlyFolder -Path $full)) { continue }
        foreach ($ext in '.exe', '.cmd') {
            $candidate = Join-Path $full "$Name$ext"
            if ([System.IO.File]::Exists($candidate)) { return $candidate }
        }
    }
    return $null
}

function Test-WKAdminOnlyFolder {
    <# True when standard users cannot add or replace files in $Path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try { $acl = (New-Object System.IO.DirectoryInfo $Path).GetAccessControl() } catch { return $false }
    $rights = [System.Security.AccessControl.FileSystemRights]
    $write = [int]($rights::WriteData -bor $rights::AppendData -bor $rights::Delete -bor $rights::ChangePermissions -bor $rights::TakeOwnership) -bor 0x10000000 -bor 0x40000000
    # Users, Authenticated Users, Everyone, Interactive, and this user.
    $untrusted = @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $untrusted -notcontains $rule.IdentityReference.Value) { continue }
        if ([int]$rule.FileSystemRights -band $write) { return $false }
    }
    return $true
}

function Test-WKSupportedWindows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Windows)
    # Windows 10 1809 is the oldest build winget and the APIs we use support.
    return ($Windows.Build -ge 17763)
}

function Test-WKRegistryRedirected {
    <#
        Some packaged apps run the programs they start in a container with a
        private copy of the user's registry. Changes made there never reach
        Windows, so every tweak would seem to do nothing. Writes a temporary
        value and reads it back through WMI, which runs outside any container.
    #>
    [CmdletBinding()]
    param()

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = 'KlaudikWinKitProbe'
    $token = [guid]::NewGuid().ToString('N')
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\$name", [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Microsoft.Win32.RegistryOptions]::Volatile)
        $key.SetValue('Token', $token)
        $key.Close()
        $key = $null
        $wmi = [wmiclass]'\\.\root\default:StdRegProv'
        $read = $wmi.GetStringValue([uint32]2147483651, "$sid\Software\$name", 'Token')
        # 0 = found. Anything else means WMI sees a different registry.
        return ($read.ReturnValue -ne 0 -or $read.sValue -ne $token)
    }
    catch {
        # WMI unavailable or the probe could not be written: no evidence of a container.
        return $false
    }
    finally {
        if ($key) { $key.Close() }
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("Software\$name", $false) } catch { }
    }
}

function Format-WKBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Bytes)

    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $Bytes, $units[$i]) }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function Format-WKCount {
    <# "1 app", "3 apps". #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$Noun,
        [string]$Plural
    )
    if (-not $Plural) { $Plural = "${Noun}s" }
    if ($Count -eq 1) { return "1 $Noun" }
    return "$Count $Plural"
}

function Update-WKPathEnvironment {
    [CmdletBinding()]
    param()
    # Newly installed tools add themselves to PATH in the registry; pick that up
    # without restarting the app.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Invoke-WKProcess {
    <#
        Runs a console program, streams its output to the log and returns the
        exit code together with the captured lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet
    )

    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]

    & $FilePath @ArgumentList 2>&1 | ForEach-Object {
        # Progress bars redraw with carriage returns; keep only the final state.
        $text = ("$_" -split "`r")[-1].TrimEnd()
        if (-not $text.Trim()) { return }
        if (Test-WKNoiseLine $text) { return }
        $lines.Add($text)
        if (-not $Quiet) { Write-WKLog "  $($text.Trim())" }
    }

    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $lines.ToArray()
    }
}

function Test-WKNoiseLine {
    [CmdletBinding()]
    param([string]$Line)

    $t = $Line.Trim()
    if ($t -match '^[\\/|\-]+$') { return $true }                              # spinner
    if ($t -match ("[{0}-{1}]" -f [char]0x2580, [char]0x259F)) { return $true }  # block progress bars
    if ($t -match '^\d+(\.\d+)?\s*(B|KB|MB|GB)\s*/\s*\d+(\.\d+)?\s*(B|KB|MB|GB)$') { return $true }
    if ($t -match '^\d{1,3}%$') { return $true }
    return $false
}

function Restart-WKExplorer {
    [CmdletBinding()]
    param()

    Write-WKLog 'Restarting File Explorer to apply changes'
    # Only this session's shell; other signed-in users keep theirs.
    $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # Winlogon restarts the shell by itself (AutoRestartShell); give it time.
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) { return }
    }
    # Never start Explorer from this elevated process: it would become an
    # administrator desktop, and everything opened from it would run elevated.
    # Start it as the signed-in user instead.
    try {
        Start-WKAsInteractiveUser -FilePath (Get-WKWindowsPath 'explorer.exe')
        Write-WKLog 'File Explorer was started again'
    }
    catch {
        Write-WKLog "File Explorer did not restart. Press Ctrl+Shift+Esc, choose Run new task, type explorer and press Enter. ($($_.Exception.Message))" -Level Error
    }
}

function Start-WKAsInteractiveUser {
    <#
        Starts a program as the user signed in to this PC, without
        administrator rights, through a one-off scheduled task.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments
    )
    $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if (-not $user) { throw 'Nobody is signed in to this PC.' }
    $name = "KlaudikWinKit-$([guid]::NewGuid().ToString('N'))"
    $action = if ($Arguments) { New-ScheduledTaskAction -Execute $FilePath -Argument $Arguments } else { New-ScheduledTaskAction -Execute $FilePath }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    try {
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        # Removing the task before it has started cancels the launch, so wait
        # until Task Scheduler reports a run (267011 = has not run yet).
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
            if ($info -and $info.LastTaskResult -ne 267011) { break }
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}
