# Thin wrappers over the Windows APIs that the Settings app itself uses to
# apply a change and tell the shell about it. Writing the registry alone is
# not enough for many settings: the running shell caches them, and several
# (mouse, animations, Sticky Keys) only take effect when set through
# SystemParametersInfo.

$script:WKNativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class WKNative
{
    const uint WM_SETTINGCHANGE = 0x001A;
    const uint SMTO_ABORTIFHUNG = 0x0002;
    const uint SPIF_UPDATEINIFILE = 0x01;
    const uint SPIF_SENDCHANGE = 0x02;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);

    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    [StructLayout(LayoutKind.Sequential)]
    public struct SHELLSTATE
    {
        public uint Flags1;
        public uint Win95Unused;
        public uint Win95Unused2;
        public int ParamSort;
        public int SortDirection;
        public uint Version;
        public uint NotUsed;
        public uint Flags2;
    }

    [DllImport("shell32.dll")]
    static extern void SHGetSetSettings(ref SHELLSTATE state, uint mask, bool set);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, int[] data, uint winIni);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, ref int data, uint winIni);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, IntPtr data, uint winIni);

    [StructLayout(LayoutKind.Sequential)]
    struct ANIMATIONINFO { public uint Size; public int MinAnimate; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, ref ANIMATIONINFO data, uint winIni);

    [StructLayout(LayoutKind.Sequential)]
    struct STICKYKEYS { public uint Size; public uint Flags; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, ref STICKYKEYS data, uint winIni);

    // Tell every top-level window, including Explorer and the taskbar, that
    // a setting in the given area changed.
    public static void BroadcastSettingChange(string area)
    {
        UIntPtr result;
        SendMessageTimeout((IntPtr)0xFFFF, WM_SETTINGCHANGE, UIntPtr.Zero, area, SMTO_ABORTIFHUNG, 3000, out result);
    }

    // SHCNE_ASSOCCHANGED: makes Explorer refresh icons and file names.
    public static void NotifyAssociationsChanged()
    {
        SHChangeNotify(0x08000000, 0x0000, IntPtr.Zero, IntPtr.Zero);
    }

    // Folder Options flags: 0x1 = show hidden files, 0x2 = show extensions.
    public static bool GetShellFlag(uint mask)
    {
        SHELLSTATE s = new SHELLSTATE();
        SHGetSetSettings(ref s, mask, false);
        return (s.Flags1 & mask) != 0;
    }

    public static void SetShellFlag(uint mask, bool on)
    {
        SHELLSTATE s = new SHELLSTATE();
        SHGetSetSettings(ref s, mask, false);
        if (on) { s.Flags1 |= mask; } else { s.Flags1 &= ~mask; }
        SHGetSetSettings(ref s, mask, true);
    }

    // SPI_GETMOUSE / SPI_SETMOUSE: threshold1, threshold2, acceleration.
    public static int[] GetMouse()
    {
        int[] v = new int[3];
        SystemParametersInfo(0x0003, 0, v, 0);
        return v;
    }

    public static void SetMouse(int threshold1, int threshold2, int speed)
    {
        int[] v = new int[] { threshold1, threshold2, speed };
        if (!SystemParametersInfo(0x0004, 0, v, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    // SPI_GETMENUSHOWDELAY / SPI_SETMENUSHOWDELAY (milliseconds).
    public static int GetMenuShowDelay()
    {
        int v = 0;
        SystemParametersInfo(0x006A, 0, ref v, 0);
        return v;
    }

    public static void SetMenuShowDelay(int milliseconds)
    {
        if (!SystemParametersInfo(0x006B, (uint)milliseconds, IntPtr.Zero, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    // SPI_GETANIMATION / SPI_SETANIMATION: minimize and maximize animations.
    public static bool GetMinAnimate()
    {
        ANIMATIONINFO a = new ANIMATIONINFO();
        a.Size = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
        SystemParametersInfo(0x0048, a.Size, ref a, 0);
        return a.MinAnimate != 0;
    }

    public static void SetMinAnimate(bool on)
    {
        ANIMATIONINFO a = new ANIMATIONINFO();
        a.Size = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
        a.MinAnimate = on ? 1 : 0;
        if (!SystemParametersInfo(0x0049, a.Size, ref a, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenSCManager(string machine, string database, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenService(IntPtr manager, string name, uint access);

    [StructLayout(LayoutKind.Sequential)]
    struct SERVICE_DELAYED_AUTO_START_INFO { public int Delayed; }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ChangeServiceConfig2(IntPtr service, uint level, ref SERVICE_DELAYED_AUTO_START_INFO info);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool CloseServiceHandle(IntPtr handle);

    // The delayed-start flag of a service, set through the Service Control
    // Manager so it takes effect without a restart. sc.exe clears it when it
    // changes the start type.
    public static void SetServiceDelayedAutoStart(string name, bool delayed)
    {
        IntPtr manager = OpenSCManager(null, null, 0x0001);
        if (manager == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            IntPtr service = OpenService(manager, name, 0x0002);
            if (service == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                SERVICE_DELAYED_AUTO_START_INFO info = new SERVICE_DELAYED_AUTO_START_INFO();
                info.Delayed = delayed ? 1 : 0;
                if (!ChangeServiceConfig2(service, 3, ref info))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(manager); }
    }

    // SPI_GETCLIENTAREAANIMATION / SPI_SETCLIENTAREAANIMATION: the "Animation
    // effects" switch in Settings, used by the Windows 11 taskbar and apps.
    public static bool GetClientAreaAnimation()
    {
        int v = 1;
        SystemParametersInfo(0x1042, 0, ref v, 0);
        return v != 0;
    }

    public static void SetClientAreaAnimation(bool on)
    {
        if (!SystemParametersInfo(0x1043, 0, (IntPtr)(on ? 1 : 0), SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    // SPI_GETSTICKYKEYS / SPI_SETSTICKYKEYS. Only the shortcut bit
    // (SKF_HOTKEYACTIVE, 0x4) is changed; other Sticky Keys options stay.
    public static bool GetStickyKeysHotkey()
    {
        STICKYKEYS k = new STICKYKEYS();
        k.Size = (uint)Marshal.SizeOf(typeof(STICKYKEYS));
        SystemParametersInfo(0x003A, k.Size, ref k, 0);
        return (k.Flags & 0x4) != 0;
    }

    public static void SetStickyKeysHotkey(bool on)
    {
        STICKYKEYS k = new STICKYKEYS();
        k.Size = (uint)Marshal.SizeOf(typeof(STICKYKEYS));
        if (!SystemParametersInfo(0x003A, k.Size, ref k, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (on) { k.Flags |= 0x4; } else { k.Flags &= ~0x4u; }
        if (!SystemParametersInfo(0x003B, k.Size, ref k, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

function Initialize-WKNative {
    [CmdletBinding()]
    param()
    # Types added with Add-Type live for the whole process, so background
    # runspaces see them once the UI thread has loaded them.
    if (-not ('WKNative' -as [type])) {
        Add-Type -TypeDefinition $script:WKNativeSource -Language CSharp
    }
}

function Send-WKSettingChange {
    <# Announces changed settings so the shell and taskbar pick them up without a restart. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Area)
    Initialize-WKNative
    foreach ($a in $Area) { [WKNative]::BroadcastSettingChange($a) }
}
