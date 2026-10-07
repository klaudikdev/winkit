# Registry access through the .NET API rather than the PowerShell provider:
# it handles the (Default) value, preserves value kinds exactly, always uses
# the 64-bit view and has no "New-Item -Force wipes the key" surprises.

function ConvertFrom-WKRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # CultureInvariant: under a Turkish culture a plain case-insensitive match
    # would not treat 'i' and 'I' as the same letter.
    $m = [regex]::Match($Path, '^(?<hive>HKCU|HKLM|HKCR|HKU|HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE|HKEY_CLASSES_ROOT|HKEY_USERS):?\\(?<sub>.+)$',
                        [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
    if (-not $m.Success) {
        throw "Unsupported registry path '$Path'."
    }
    $hive = switch ($m.Groups['hive'].Value.ToUpperInvariant()) {
        { $_ -in 'HKCU', 'HKEY_CURRENT_USER' }   { [Microsoft.Win32.RegistryHive]::CurrentUser }
        { $_ -in 'HKLM', 'HKEY_LOCAL_MACHINE' }  { [Microsoft.Win32.RegistryHive]::LocalMachine }
        { $_ -in 'HKCR', 'HKEY_CLASSES_ROOT' }   { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        { $_ -in 'HKU', 'HKEY_USERS' }           { [Microsoft.Win32.RegistryHive]::Users }
    }
    [pscustomobject]@{
        Hive   = $hive
        SubKey = $m.Groups['sub'].Value.Trim('\')
    }
}

function Open-WKRegistryBase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive)
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function ConvertTo-WKRegistryData {
    <#
        Converts a JSON-friendly value into the exact .NET type the registry
        expects for the given kind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind,
        [AllowNull()]$Value
    )

    switch ($Kind) {
        'DWord' {
            $n = [long]$Value
            if ($n -gt [int]::MaxValue) { $n = $n - 4294967296 }   # store 0xFFFFFFFF as -1
            return [int]$n
        }
        'QWord'        { return [long]$Value }
        'String'       { return [string]$Value }
        'ExpandString' { return [string]$Value }
        # The leading comma stops PowerShell from unrolling the array on return.
        'MultiString'  { return , ([string[]]@($Value)) }
        'Binary'       { return , ([byte[]]@($Value)) }
        default        { throw "Unsupported registry value kind '$Kind'." }
    }
}

function Get-WKRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )

    $p = ConvertFrom-WKRegistryPath $Path
    $base = Open-WKRegistryBase $p.Hive
    try {
        $key = $base.OpenSubKey($p.SubKey, $false)
        if (-not $key) {
            return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null }
        }
        try {
            $exists = @($key.GetValueNames()) -contains $Name
            $kind = $null
            $value = $null
            if ($exists) {
                $kind = $key.GetValueKind($Name).ToString()
                $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($value -is [byte[]]) { $value = [int[]]$value }
            }
            return [pscustomobject]@{ KeyExists = $true; Exists = $exists; Kind = $kind; Value = $value }
        }
        finally { $key.Close() }
    }
    finally { $base.Close() }
}

function Test-WKRegistryValueEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()]$Expected
    )

    if (-not $Current.Exists) { return $false }
    $a = ConvertTo-WKRegistryData -Kind $Kind -Value $Current.Value
    $b = ConvertTo-WKRegistryData -Kind $Kind -Value $Expected
    if ($Kind -in 'MultiString', 'Binary') {
        return ((@($a) -join "`0") -eq (@($b) -join "`0"))
    }
    return ("$a" -eq "$b")
}

function Set-WKRegistryValue {
    <#
        Writes a value, creating the key when needed. Returns the path of the
        top-most key that had to be created (or $null) so undo can remove it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind,
        [AllowNull()]$Value
    )

    $p = ConvertFrom-WKRegistryPath $Path
    $base = Open-WKRegistryBase $p.Hive
    try {
        $createdRoot = $null
        $walk = ''
        foreach ($segment in $p.SubKey.Split('\')) {
            $walk = if ($walk) { "$walk\$segment" } else { $segment }
            $probe = $base.OpenSubKey($walk, $false)
            if ($probe) { $probe.Close() } else { $createdRoot = $walk; break }
        }

        $key = $base.CreateSubKey($p.SubKey)
        if (-not $key) { throw "Could not open or create '$Path'." }
        try {
            $key.SetValue($Name, (ConvertTo-WKRegistryData -Kind $Kind -Value $Value), $Kind)
        }
        catch [System.UnauthorizedAccessException] {
            # Windows guards a few taskbar and default-app settings against
            # scripts (the UCPD driver). Leave no empty keys behind.
            $key.Close()
            $key = $null
            if ($createdRoot) { try { $base.DeleteSubKeyTree($createdRoot, $false) } catch { } }
            throw "Windows does not allow programs to change this setting ($Path\$Name). Change it in the Settings app instead."
        }
        finally { if ($key) { $key.Close() } }

        if ($createdRoot) {
            $prefix = $Path.Substring(0, $Path.IndexOf('\'))
            return "$prefix\$createdRoot"
        }
        return $null
    }
    finally { $base.Close() }
}

function Remove-WKRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )

    $p = ConvertFrom-WKRegistryPath $Path
    $base = Open-WKRegistryBase $p.Hive
    try {
        $key = $base.OpenSubKey($p.SubKey, $true)
        if (-not $key) { return }
        try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
    }
    finally { $base.Close() }
}

function Remove-WKRegistryKeyIfEmpty {
    <#
        Removes $Path and its empty parents, but never goes above $StopAt.
        Used on undo to clean up keys the tweak created, and only while they
        are still empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StopAt
    )

    $p = ConvertFrom-WKRegistryPath $Path
    $stop = (ConvertFrom-WKRegistryPath $StopAt).SubKey
    if (-not $p.SubKey.StartsWith($stop, [StringComparison]::OrdinalIgnoreCase)) { return }

    $base = Open-WKRegistryBase $p.Hive
    try {
        $current = $p.SubKey
        while ($current.Length -ge $stop.Length) {
            $key = $base.OpenSubKey($current, $false)
            if (-not $key) {
                # Already gone; keep walking up.
            }
            else {
                $empty = ($key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0)
                $key.Close()
                if (-not $empty) { break }
                $base.DeleteSubKey($current, $false)
            }
            $cut = $current.LastIndexOf('\')
            if ($cut -lt 0) { break }
            $current = $current.Substring(0, $cut)
        }
    }
    finally { $base.Close() }
}
