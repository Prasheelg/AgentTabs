#Requires -Version 5.1
<#
  Agent Tabs
  Lists your projects; click to open Claude Code in a tab inside the launcher
  (a conhost window docked into the tab), or optionally in an external Windows Terminal.
  Each tab can be split into side-by-side / stacked panes, one Claude session per pane.
  Config is stored in %APPDATA%\AgentTabs\config.json
#>

# The launcher runs without a visible console, so a failure before the window appears would be silent:
# log it and say so. (Errors inside UI event handlers don't reach this trap; WinForms reports those.)
trap {
    $log = Join-Path $env:LOCALAPPDATA 'AgentTabs\error.log'
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
        "[$(Get-Date -Format s)] $_`r`n$($_.ScriptStackTrace)`r`n" | Out-File -LiteralPath $log -Append -Encoding UTF8
    } catch { }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Agent Tabs could not start:`n`n$_`n`nDetails: $log",
        'Agent Tabs', 'OK', 'Error') | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Compiling the C# below takes ~0.45 s, so a compiled copy is cached in %LOCALAPPDATA%\AgentTabs\types,
# named after a hash of the source. Windows Defender scans a new DLL for several seconds the first time it's
# loaded, so a missing copy is built and loaded once by a hidden background process (Start-TypeCacheWarmer)
# and only used from the next start on, once it's marked .ready. Until then the source is compiled in memory.
$TypeCache = Join-Path $env:LOCALAPPDATA 'AgentTabs\types'
$script:TypeFiles = @()
function Import-Type($Name, $TypeDefinition) {
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($TypeDefinition))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dll  = Join-Path $TypeCache "$Name-$hash.dll"
    $script:TypeFiles += "$Name-$hash"
    if (Test-Path -LiteralPath "$dll.ready") {
        try { Add-Type -Path $dll; return } catch { }   # fall back to compiling
    }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $TypeDefinition
    try {
        New-Item -ItemType Directory -Force -Path $TypeCache | Out-Null
        [System.IO.File]::WriteAllText("$dll.cs", $TypeDefinition)   # picked up by the warmer
        $script:WarmTypes = $true
    } catch { }
}

# Builds and loads the queued .cs files in a windowless background process, then tidies stale copies.
function Start-TypeCacheWarmer {
    if (-not $script:WarmTypes) { return }
    $keep = ($script:TypeFiles | ForEach-Object { "'$_'" }) -join ','
    $cmd = @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$dir = '$($TypeCache -replace "'", "''")'
foreach (`$cs in Get-ChildItem -LiteralPath `$dir -Filter *.dll.cs) {
    `$dll = `$cs.FullName.Substring(0, `$cs.FullName.Length - 3)
    try {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition ([IO.File]::ReadAllText(`$cs.FullName)) -OutputAssembly `$dll -OutputType Library
        Add-Type -Path `$dll
        New-Item -ItemType File -Force -Path "`$dll.ready" | Out-Null
    } catch { Remove-Item -LiteralPath `$dll -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath `$cs.FullName -ErrorAction SilentlyContinue
}
`$keep = @($keep)
Get-ChildItem -LiteralPath `$dir -File | Where-Object { `$keep -notcontains (`$_.Name -replace '\.dll.*$', '') } |
    Remove-Item -ErrorAction SilentlyContinue
"@
    try {
        $si = New-Object System.Diagnostics.ProcessStartInfo('powershell.exe')
        $si.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
                        [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
        $si.UseShellExecute = $false; $si.CreateNoWindow = $true   # no console window at all
        [void][System.Diagnostics.Process]::Start($si)
    } catch { }
}

# Win32 helpers for docking a console window into a tab page
Import-Type 'dock' -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ConsoleDock {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);

    // Brings a top-level window with this exact title to the front (restoring it if minimised).
    public static bool Activate(string title) {
        IntPtr h = FindWindow(null, title);
        if (h == IntPtr.Zero) return false;
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        return SetForegroundWindow(h);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static System.Collections.Generic.HashSet<uint> SelfAndChildren(uint pid) {
        var set = new System.Collections.Generic.HashSet<uint> { pid };
        IntPtr snap = CreateToolhelp32Snapshot(2, 0);   // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) return set;
        var pe = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
        for (bool ok = Process32FirstW(snap, ref pe); ok; ok = Process32NextW(snap, ref pe))
            if (pe.th32ParentProcessID == pid) set.Add(pe.th32ProcessID);
        CloseHandle(snap);
        return set;
    }

    // The console window of a conhost.exe process (may still be hidden).
    // Windows reports a console window as owned by its client process (cmd.exe), so match children too.
    public static IntPtr FindConsoleWindow(int pid) {
        var pids = SelfAndChildren((uint)pid);
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (!pids.Contains(p)) return true;
            var sb = new StringBuilder(64);
            GetClassName(h, sb, sb.Capacity);
            if (sb.ToString() == "ConsoleWindowClass") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Strip the frame, make it a child of 'parent' and show it.
    public static void Embed(IntPtr child, IntPtr parent) {
        const long WS_POPUP = 0x80000000L, WS_CHILD = 0x40000000L, WS_CAPTION = 0x00C00000L,
                   WS_THICKFRAME = 0x00040000L, WS_MINIMIZEBOX = 0x00020000L, WS_MAXIMIZEBOX = 0x00010000L;
        const long WS_EX_APPWINDOW = 0x00040000L;
        long style = GetWindowLongPtr(child, -16).ToInt64();
        style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
        style |= WS_CHILD;
        SetWindowLongPtr(child, -16, new IntPtr(style));
        long ex = GetWindowLongPtr(child, -20).ToInt64() & ~WS_EX_APPWINDOW;
        SetWindowLongPtr(child, -20, new IntPtr(ex));
        SetParent(child, parent);
        ShowWindow(child, 5);   // SW_SHOW
    }
}
'@

# One launcher per user session: a second start just brings the running one to the front.
$script:Instance = New-Object System.Threading.Mutex($false, 'Local\AgentTabs')
try { $first = $script:Instance.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $first = $true }   # previous one crashed
if (-not $first) {
    [void][ConsoleDock]::Activate('Agent Tabs')
    exit 0
}

# Dark theme: palette, native theming calls, owner-drawn tab strip and icon buttons
Import-Type 'ui' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class Palette {
    // "Midnight Blue": deep navy surfaces, bright blue accent
    public static readonly Color Bg           = Color.FromArgb(15, 20, 30);
    public static readonly Color Surface      = Color.FromArgb(22, 28, 42);
    public static readonly Color Raised       = Color.FromArgb(30, 38, 56);
    public static readonly Color Hover        = Color.FromArgb(40, 50, 72);
    public static readonly Color Border       = Color.FromArgb(42, 52, 73);
    public static readonly Color Text         = Color.FromArgb(230, 234, 242);
    public static readonly Color Muted        = Color.FromArgb(139, 149, 168);
    public static readonly Color Faint        = Color.FromArgb(92, 103, 125);
    public static readonly Color Accent       = Color.FromArgb(76, 141, 255);
    public static readonly Color AccentHover  = Color.FromArgb(109, 163, 255);
    public static readonly Color AccentDown   = Color.FromArgb(54, 116, 224);
    public static readonly Color Running      = Color.FromArgb(61, 214, 140);
    public static readonly Color Selection    = Color.FromArgb(29, 50, 90);
    public static readonly Color ActiveHeader = Color.FromArgb(25, 39, 68);
    public static readonly Color ActiveRim    = Color.FromArgb(78, 124, 210);
    public static readonly Color TabHover     = Color.FromArgb(26, 33, 49);
    public static readonly Color StripBg      = Color.FromArgb(11, 15, 23);
    public static readonly Color SelectionDim = Color.FromArgb(30, 38, 56);
    public static readonly Color Danger       = Color.FromArgb(220, 64, 72);
}

public static class UiNative {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);

    // Dark title bar (Win10 1809+), caption colour on Windows 11; silently ignored elsewhere.
    public static void DarkTitleBar(IntPtr hwnd, Color caption) {
        int on = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
        int c = ColorTranslator.ToWin32(caption);
        DwmSetWindowAttribute(hwnd, 35, ref c, 4);
    }
    // Frosted (acrylic) title bar on Windows 11; elsewhere falls back to a solid caption colour.
    public static void GlassTitleBar(IntPtr hwnd, Color fallback) {
        int on = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
        int acrylic = 3;   // DWMSBT_TRANSIENTWINDOW
        if (DwmSetWindowAttribute(hwnd, 38, ref acrylic, 4) != 0) {
            int c = ColorTranslator.ToWin32(fallback);
            DwmSetWindowAttribute(hwnd, 35, ref c, 4);
        }
    }

    public static void SetCueBanner(IntPtr hwnd, string text) { SendMessage(hwnd, 0x1501, new IntPtr(1), text); }   // EM_SETCUEBANNER
}

public class WindowEventArgs : EventArgs {
    public readonly IntPtr Hwnd;
    public WindowEventArgs(IntPtr hwnd) { Hwnd = hwnd; }
}

// Reports mouse clicks on any window inside 'owner'. An embedded console belongs to another process,
// so a click on it never reaches our controls and doesn't move keyboard focus by itself.
public class ClickWatcher : IDisposable {
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT pt);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extraInfo; }

    readonly Control owner;
    readonly HookProc proc;   // kept in a field so the GC doesn't collect the callback
    IntPtr hook;
    public event EventHandler<WindowEventArgs> Clicked;

    public ClickWatcher(Control owner) {
        this.owner = owner;
        proc = Callback;
        hook = SetWindowsHookEx(14, proc, GetModuleHandle(null), 0);   // WH_MOUSE_LL
    }

    IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
        int msg = wParam.ToInt32();
        if (code >= 0 && (msg == 0x201 || msg == 0x204 || msg == 0x207)) {   // left / right / middle button down
            var info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            IntPtr hwnd = WindowFromPoint(info.pt);
            if (hwnd != IntPtr.Zero && Clicked != null && UiNative.IsChild(owner.Handle, hwnd)) {
                // handle it after the hook returns (and after any activation the click causes)
                owner.BeginInvoke(new Action(() => { if (Clicked != null) Clicked(this, new WindowEventArgs(hwnd)); }));
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    public void Dispose() {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
    }
}

public class CommandEventArgs : EventArgs {
    public readonly string Name;
    public CommandEventArgs(string name) { Name = name; }
}

// Launcher shortcuts that must work while an embedded console has the keyboard (it would swallow them):
// Ctrl+Tab / Ctrl+PgDn = "next", Ctrl+Shift+Tab / Ctrl+PgUp = "prev", Ctrl+1..9 = "tab:N",
// and, while PaneKeys is set (the current tab is split), Ctrl+Arrow = "pane:left|up|right|down".
// Only active while the launcher is the foreground window; matching keys never reach the console.
public class KeyWatcher : IDisposable {
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, int flags);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extraInfo; }

    readonly Control owner;
    readonly HookProc proc;   // kept in a field so the GC doesn't collect the callback
    readonly HashSet<uint> swallowed = new HashSet<uint>();
    IntPtr hook;
    public event EventHandler<CommandEventArgs> Command;
    public bool PaneKeys;

    public KeyWatcher(Control owner) {
        this.owner = owner;
        proc = Callback;
        hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);   // WH_KEYBOARD_LL
    }

    static bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    string Map(uint vk) {
        bool ctrl = IsDown(0x11), alt = IsDown(0x12), shift = IsDown(0x10);
        if (ctrl && !alt && !shift && PaneKeys) {
            if (vk == 0x25) return "pane:left";
            if (vk == 0x26) return "pane:up";
            if (vk == 0x27) return "pane:right";
            if (vk == 0x28) return "pane:down";
        }
        if (!ctrl || alt) return null;   // needs Ctrl, and not Alt (AltGr is Ctrl+Alt)
        if (vk == 0x09) return shift ? "prev" : "next";   // Tab
        if (vk == 0x21) return "prev";                    // PgUp
        if (vk == 0x22) return "next";                    // PgDn
        if (!shift && vk >= 0x31 && vk <= 0x39) return "tab:" + (vk - 0x30);
        return null;
    }

    IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            int msg = wParam.ToInt32();
            // with a docked console focused, Windows reports the console itself as the foreground window
            if ((msg == 0x100 || msg == 0x104) && GetAncestor(GetForegroundWindow(), 2) == owner.Handle) {   // key down; 2 = GA_ROOT
                string cmd = Map(k.vkCode);
                if (cmd != null) {
                    swallowed.Add(k.vkCode);
                    owner.BeginInvoke(new Action(() => { if (Command != null) Command(this, new CommandEventArgs(cmd)); }));
                    return new IntPtr(1);
                }
            } else if ((msg == 0x101 || msg == 0x105) && swallowed.Remove(k.vkCode)) {   // matching key up
                return new IntPtr(1);
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    public void Dispose() {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
    }
}

public enum Glyph { Close, Add, SplitRight, SplitDown, Chevron, More, Search, Home }

public static class Glyphs {
    public static GraphicsPath Round(Rectangle r, int radius, bool bottomCorners) {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        if (bottomCorners) {
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        } else {
            p.AddLine(r.Right, r.Bottom, r.X, r.Bottom);
        }
        p.CloseFigure();
        return p;
    }

    public static void Draw(Graphics g, Glyph glyph, Rectangle r, Color c) {
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        int x = (int)cx, y = (int)cy;
        var old = g.SmoothingMode;
        using (var pen = new Pen(c, 1f)) {
            switch (glyph) {
                case Glyph.Close:
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    pen.Width = 1.3f;
                    g.DrawLine(pen, cx - 4, cy - 4, cx + 4, cy + 4);
                    g.DrawLine(pen, cx - 4, cy + 4, cx + 4, cy - 4);
                    break;
                case Glyph.Add:
                    g.SmoothingMode = SmoothingMode.None;
                    g.DrawLine(pen, x - 5, y, x + 5, y);
                    g.DrawLine(pen, x, y - 5, x, y + 5);
                    break;
                case Glyph.SplitRight:
                case Glyph.SplitDown:
                    g.SmoothingMode = SmoothingMode.None;
                    var box = new Rectangle(x - 7, y - 6, 14, 12);
                    g.DrawRectangle(pen, box);
                    if (glyph == Glyph.SplitRight) g.DrawLine(pen, box.X + 7, box.Y, box.X + 7, box.Bottom);
                    else g.DrawLine(pen, box.X, box.Y + 6, box.Right, box.Y + 6);
                    break;
                case Glyph.Chevron:
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    pen.Width = 1.3f;
                    g.DrawLines(pen, new[] { new PointF(cx - 4, cy - 2), new PointF(cx, cy + 2), new PointF(cx + 4, cy - 2) });
                    break;
                case Glyph.More:
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(c))
                        for (int i = -1; i <= 1; i++) g.FillEllipse(b, cx + i * 5 - 1.5f, cy - 1.5f, 3, 3);
                    break;
                case Glyph.Search:
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    pen.Width = 1.4f;
                    g.DrawEllipse(pen, cx - 6, cy - 6, 9, 9);
                    g.DrawLine(pen, cx + 1.5f, cy + 1.5f, cx + 5, cy + 5);
                    break;
                case Glyph.Home:
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(c))
                        for (int i = 0; i < 2; i++)
                            for (int j = 0; j < 2; j++)
                                using (var sq = Round(new Rectangle(x - 7 + i * 8, y - 7 + j * 8, 6, 6), 2, true)) g.FillPath(b, sq);
                    break;
            }
        }
        g.SmoothingMode = old;
    }

    // Project badges: a rounded square in a colour picked from the name, with the name's first letter.
    static readonly Color[] AvatarColors = {
        Color.FromArgb(217, 119, 87), Color.FromArgb(94, 129, 244), Color.FromArgb(76, 175, 130), Color.FromArgb(171, 104, 214),
        Color.FromArgb(222, 168, 62), Color.FromArgb(56, 178, 172), Color.FromArgb(229, 102, 120), Color.FromArgb(121, 134, 203)
    };

    public static Color AvatarColor(string name) {
        int h = 0;
        foreach (char ch in (name ?? "").ToLowerInvariant()) h = unchecked(h * 31 + ch);
        return AvatarColors[(h & 0x7fffffff) % AvatarColors.Length];
    }

    // 'ring' outlines the badge in the background colour so overlapping badges stay separate.
    public static void DrawAvatar(Graphics g, string name, Rectangle r, Color ring, bool dim) {
        var oldMode = g.SmoothingMode;
        var oldHint = g.TextRenderingHint;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        Color c = AvatarColor(name);
        if (dim) c = Color.FromArgb(150, c);
        using (var path = Round(r, Math.Max(3, r.Width / 4), true)) {
            using (var b = new SolidBrush(c)) g.FillPath(b, path);
            if (ring.A > 0) using (var p = new Pen(ring, 2f)) g.DrawPath(p, path);
        }
        string letter = "?";
        foreach (char ch in name ?? "") if (char.IsLetterOrDigit(ch)) { letter = char.ToUpperInvariant(ch).ToString(); break; }
        using (var f = new Font("Segoe UI Semibold", r.Height * 0.52f, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
        using (var tb = new SolidBrush(Color.FromArgb(dim ? 190 : 255, Color.White)))
            g.DrawString(letter, f, tb, new RectangleF(r.X, r.Y + 0.5f, r.Width, r.Height), sf);
        g.SmoothingMode = oldMode;
        g.TextRenderingHint = oldHint;
    }

    public static Bitmap Avatar(string name, int s) {
        var bmp = new Bitmap(s, s);
        using (var g = Graphics.FromImage(bmp)) DrawAvatar(g, name, new Rectangle(0, 0, s - 1, s - 1), Color.Transparent, false);
        return bmp;
    }

    // "Glass" backdrop: a dark navy gradient lit by two soft glows (blue top-right, violet bottom-left).
    public static void Backdrop(Graphics g, Rectangle r) {
        if (r.Width < 2 || r.Height < 2) return;
        using (var lg = new LinearGradientBrush(r, Color.FromArgb(19, 26, 42), Color.FromArgb(10, 14, 22), 90f)) g.FillRectangle(lg, r);
        Glow(g, new RectangleF(r.Right - r.Width * 0.6f, r.Top - r.Height * 0.6f, r.Width * 0.9f, r.Height * 1.1f), Color.FromArgb(52, Palette.Accent));
        Glow(g, new RectangleF(r.Left - r.Width * 0.3f, r.Bottom - r.Height * 0.6f, r.Width * 0.75f, r.Height * 1.0f), Color.FromArgb(40, 139, 92, 246));
    }

    static void Glow(Graphics g, RectangleF e, Color c) {
        if (e.Width < 2 || e.Height < 2) return;
        using (var path = new GraphicsPath()) {
            path.AddEllipse(e);
            using (var pb = new PathGradientBrush(path)) {
                pb.CenterColor = c;
                pb.SurroundColors = new[] { Color.FromArgb(0, c) };
                g.FillPath(pb, path);
            }
        }
    }

    // Glossy sheen over a rounded shape: a white gradient fading out down the top half,
    // plus a bright 1px highlight along the top edge. 'strength' is the sheen's alpha (0-255).
    public static void Gloss(Graphics g, Rectangle r, int radius, int strength) {
        if (r.Width < 4 || r.Height < 4) return;
        var oldMode = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Round(r, radius, true)) {
            var oldClip = g.Clip;
            g.SetClip(path, CombineMode.Intersect);
            var top = new Rectangle(r.X, r.Y, r.Width, r.Height / 2 + 1);
            using (var lg = new LinearGradientBrush(new Rectangle(top.X, top.Y - 1, top.Width, top.Height + 2),
                       Color.FromArgb(strength, Color.White), Color.FromArgb(0, Color.White), 90f))
                g.FillRectangle(lg, top);
            using (var p = new Pen(Color.FromArgb(Math.Min(255, strength * 2), Color.White)))
                g.DrawLine(p, r.X + radius, r.Y + 1, r.Right - radius, r.Y + 1);
            g.Clip = oldClip;
        }
        g.SmoothingMode = oldMode;
    }

    // Three dots across the middle of a splitter bar.
    public static void Grip(Graphics g, Rectangle r, bool verticalBar, Color c) {
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        using (var b = new SolidBrush(c))
            for (int i = -1; i <= 1; i++) {
                if (verticalBar) g.FillEllipse(b, cx - 1.5f, cy + i * 6 - 1.5f, 3, 3);
                else g.FillEllipse(b, cx + i * 6 - 1.5f, cy - 1.5f, 3, 3);
            }
        g.SmoothingMode = old;
    }

    // App icon: accent rounded square with a white terminal prompt.
    public static Bitmap AppIcon(int s) {
        var bmp = new Bitmap(s, s);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Round(new Rectangle(0, 0, s - 1, s - 1), Math.Max(2, s / 4), true))
            using (var b = new SolidBrush(Palette.Accent))
                g.FillPath(b, path);
            using (var pen = new Pen(Color.White, Math.Max(1.5f, s / 9f))) {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new[] { new PointF(s * .28f, s * .32f), new PointF(s * .48f, s * .5f), new PointF(s * .28f, s * .68f) });
                g.DrawLine(pen, s * .56f, s * .68f, s * .74f, s * .68f);
            }
        }
        return bmp;
    }
}

// Rounded flat button (primary = accent fill) that works as a dialog's Accept/Cancel button.
public class UiButton : Control, IButtonControl {
    bool hot, down;
    public bool Primary { get; set; }
    public DialogResult DialogResult { get; set; }

    public UiButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        Height = 32;
    }

    public void NotifyDefault(bool value) { }
    public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }

    protected override void OnClick(EventArgs e) {
        hot = false; down = false; Invalidate();   // a dialog opened from the click may swallow MouseLeave
        var f = FindForm();
        if (f != null && DialogResult != DialogResult.None) f.DialogResult = DialogResult;
        base.OnClick(e);
    }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode == Keys.Space) PerformClick(); base.OnKeyUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new Rectangle(0, 0, Width - 1, Height - 1);
        // secondary buttons are frosted glass (translucent white over whatever is behind them)
        Color fill, border, text;
        int gloss;
        if (!Enabled) { fill = Color.FromArgb(10, Color.White); border = Color.FromArgb(22, Color.White); text = Palette.Faint; gloss = 0; }
        else if (Primary) { fill = down ? Palette.AccentDown : hot ? Palette.AccentHover : Palette.Accent; border = Color.FromArgb(90, Color.White); text = Color.White; gloss = 70; }
        else { fill = Color.FromArgb(down ? 14 : hot ? 34 : 20, Color.White); border = Color.FromArgb(hot ? 70 : 40, Color.White); text = Palette.Text; gloss = 26; }
        if (Focused && ShowFocusCues && Enabled) border = Primary ? Color.White : Palette.Accent;
        using (var path = Glyphs.Round(r, 6, true)) {
            using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            if (gloss > 0) Glyphs.Gloss(g, r, 6, gloss);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var p = new Pen(border)) g.DrawPath(p, path);
        }
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}

// On/off switch with a label; same Checked / CheckedChanged API as a CheckBox.
public class ToggleSwitch : Control {
    bool isChecked, hot;
    public event EventHandler CheckedChanged;

    public bool Checked {
        get { return isChecked; }
        set {
            if (value == isChecked) return;
            isChecked = value;
            Invalidate();
            if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
        }
    }

    public ToggleSwitch() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        ForeColor = Palette.Text;
        Cursor = Cursors.Hand;
        Height = 22;
    }

    void FitWidth() { Width = 44 + TextRenderer.MeasureText(Text, Font).Width; }
    protected override void OnTextChanged(EventArgs e) { FitWidth(); Invalidate(); base.OnTextChanged(e); }
    protected override void OnFontChanged(EventArgs e) { FitWidth(); base.OnFontChanged(e); }
    protected override void OnClick(EventArgs e) { Checked = !Checked; base.OnClick(e); }
    protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode == Keys.Space) Checked = !Checked; base.OnKeyUp(e); }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var track = new Rectangle(0, (Height - 18) / 2, 34, 18);
        Color fill = isChecked ? (hot ? Palette.AccentHover : Palette.Accent) : Color.FromArgb(hot ? 34 : 20, Color.White);
        using (var path = Glyphs.Round(track, 9, true)) {
            using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            Glyphs.Gloss(g, track, 9, isChecked ? 60 : 24);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (!isChecked || (Focused && ShowFocusCues))
                using (var p = new Pen(Focused && ShowFocusCues ? Palette.Text : Color.FromArgb(60, Color.White))) g.DrawPath(p, path);
        }
        int knobX = isChecked ? track.Right - 15 : track.X + 3;
        var knob = new Rectangle(knobX, track.Y + 3, 12, 12);
        using (var b = new LinearGradientBrush(knob, Color.White, isChecked ? Color.FromArgb(214, 226, 255) : Palette.Muted, 90f))
            g.FillEllipse(b, knob);
        var tr = new Rectangle(44, 0, Width - 44, Height);
        TextRenderer.DrawText(g, Text, Font, tr, ForeColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}

// Small flat icon button (close / split) used in pane headers.
public class GlyphButton : Control {
    Glyph glyph;
    bool hot;
    public bool Danger { get; set; }
    public Glyph Glyph { get { return glyph; } set { glyph = value; Invalidate(); } }

    public GlyphButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        BackColor = Color.Transparent;
        Size = new Size(28, 24);
        Cursor = Cursors.Hand;
    }

    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnClick(EventArgs e) { hot = false; Invalidate(); base.OnClick(e); }   // a dialog may swallow MouseLeave

    protected override void OnPaint(PaintEventArgs e) {
        if (hot && Enabled) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Glyphs.Round(new Rectangle(0, 0, Width - 1, Height - 1), 4, true))
            using (var b = new SolidBrush(Danger ? Palette.Danger : Color.FromArgb(36, Color.White)))
                e.Graphics.FillPath(b, path);
        }
        Color c = !Enabled ? Palette.Faint : hot ? (Danger ? Color.White : Palette.Text) : Palette.Muted;
        Glyphs.Draw(e.Graphics, glyph, ClientRectangle, c);
    }
}

// Pane title: project name plus its folder on one shared text baseline (two Labels in
// different fonts, each centred on its own, don't line up). Long folders shorten in the middle.
public class PaneTitle : Control {
    string subtitle = "";
    public Font SubFont { get; set; }
    public string Subtitle { get { return subtitle; } set { subtitle = value ?? ""; Invalidate(); } }

    public PaneTitle() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        BackColor = Color.Transparent;
    }

    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    static float Ascent(Font f, float dpi) {
        var ff = f.FontFamily;
        return f.SizeInPoints * dpi / 72f * ff.GetCellAscent(f.Style) / ff.GetEmHeight(f.Style);
    }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        Font nf = Font, sf = SubFont ?? Font;
        float dpi = g.DpiY, na = Ascent(nf, dpi), sa = Ascent(sf, dpi);
        float baseline = (Height - nf.GetHeight(dpi)) / 2f + na;   // centre the name; the folder sits on its baseline
        const TextFormatFlags flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(g, Text, nf, new Point(0, (int)Math.Round(baseline - na)), ForeColor, flags);
        int x = TextRenderer.MeasureText(g, Text, nf, Size.Empty, flags).Width + 10;
        if (subtitle.Length > 0 && x < Width - 8) {
            var r = new Rectangle(x, (int)Math.Round(baseline - sa), Width - x - 6, (int)Math.Ceiling(sf.GetHeight(dpi)) + 2);
            TextRenderer.DrawText(g, subtitle, sf, r, Palette.Muted, flags | TextFormatFlags.PathEllipsis);
        }
    }
}

public class StripTab {
    public string Text = "";
    public string ToolTip = "";
    public bool Closable = true;
    public bool Home;            // draw the grid icon instead of project badges
    public string[] Avatars;     // project names of the tab's panes, one badge each (up to 3)
    public object Tag;
}

public class StripTabEventArgs : EventArgs {
    public readonly int Index;
    public readonly Point Location;
    public StripTabEventArgs(int index, Point location) { Index = index; Location = location; }
}

// Tab strip: rounded "pill" tabs with project badges, a glowing accent underline that slides to the
// selected tab, a close button on the selected / hovered tab, "+" after the last tab and an
// "all tabs" list button at the right end; the mouse wheel steps through tabs.
public class TabStripControl : Control {
    public readonly List<StripTab> Tabs = new List<StripTab>();
    public event EventHandler<StripTabEventArgs> TabSelected;
    public event EventHandler<StripTabEventArgs> TabCloseRequested;
    public event EventHandler<StripTabEventArgs> TabContextMenu;
    public event EventHandler<StripTabEventArgs> ListClicked;   // Location = bottom-right of the button
    public event EventHandler AddClicked;

    const int TabTop = 7, TabGap = 4, MinTab = 72, MaxTab = 260, Badge = 18, BadgeStep = 11;
    const TextFormatFlags TextFlags = TextFormatFlags.Left | TextFormatFlags.VerticalCenter |
        TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
    int selected = -1, hover = -1;
    bool hoverClose, hoverAdd, hoverList;
    Rectangle addRect, listRect;
    Font bold;
    readonly ToolTip tip = new ToolTip();
    string tipText;
    readonly System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer();
    float indX = -1, indW;   // underline position, eased toward the selected tab
    bool animating;

    public TabStripControl() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        BackColor = Palette.StripBg;
        Height = 46;
        anim.Interval = 15;
        anim.Tick += (s, e) => StepAnimation();
    }

    public int SelectedIndex {
        get { return selected; }
        set {
            if (value != selected) {
                animating = selected >= 0 && indX >= 0;
                selected = value;
                if (animating) anim.Start();
            }
            Invalidate();
        }
    }

    void StepAnimation() {
        var rects = LayoutTabs();
        if (selected < 0 || selected >= rects.Length) { animating = false; anim.Stop(); return; }
        var t = rects[selected];
        indX += (t.X - indX) * 0.3f;
        indW += (t.Width - indW) * 0.3f;
        if (Math.Abs(t.X - indX) < 0.5f && Math.Abs(t.Width - indW) < 0.5f) {
            indX = t.X; indW = t.Width;
            animating = false; anim.Stop();
        }
        Invalidate();
    }

    static int BadgeWidth(StripTab t) {
        if (t.Home) return Badge;
        int n = t.Avatars == null ? 0 : Math.Min(3, t.Avatars.Length);
        return n == 0 ? 0 : Badge + (n - 1) * BadgeStep;
    }

    Font Bold {
        get {
            if (bold == null) bold = new Font("Segoe UI Semibold", Font.Size, FontStyle.Regular, Font.Unit);
            return bold;
        }
    }
    protected override void OnFontChanged(EventArgs e) { bold = null; base.OnFontChanged(e); }

    Rectangle[] LayoutTabs() {
        int tabH = Height - TabTop * 2 - 2;
        listRect = new Rectangle(Width - 40, TabTop + 1, 30, tabH - 2);
        int n = Tabs.Count, avail = Width - 16 - 36 - 46, total = 0;
        var widths = new int[n];
        for (int i = 0; i < n; i++) {
            int bw = BadgeWidth(Tabs[i]);
            int w = TextRenderer.MeasureText(Tabs[i].Text ?? "", Bold).Width + 26 + (bw > 0 ? bw + 8 : 0) + (Tabs[i].Closable ? 22 : 0);
            widths[i] = Math.Max(96, Math.Min(MaxTab, w));
            total += widths[i] + TabGap;
        }
        if (n > 0 && total > avail) {
            int each = Math.Max(MinTab, avail / n - TabGap);
            for (int i = 0; i < n; i++) widths[i] = Math.Min(widths[i], each);
        }
        var rects = new Rectangle[n];
        int x = 10;
        for (int i = 0; i < n; i++) {
            rects[i] = new Rectangle(x, TabTop, widths[i], tabH);
            x += widths[i] + TabGap;
        }
        addRect = new Rectangle(x + 2, TabTop + 1, 30, tabH - 2);
        return rects;
    }

    static Rectangle CloseRect(Rectangle t) { return new Rectangle(t.Right - 26, t.Y + (t.Height - 20) / 2, 20, 20); }

    static void FillRound(Graphics g, Rectangle r, int radius, Color c) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Glyphs.Round(r, radius, true)) using (var b = new SolidBrush(c)) g.FillPath(b, path);
        g.SmoothingMode = SmoothingMode.None;
    }

    static int HitTab(Rectangle[] rects, Point p) {
        for (int i = 0; i < rects.Length; i++) if (rects[i].Contains(p)) return i;
        return -1;
    }

    bool OnClose(Rectangle[] rects, int i, Point p) { return i >= 0 && Tabs[i].Closable && CloseRect(rects[i]).Contains(p); }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        Glyphs.Backdrop(g, ClientRectangle);
        using (var p = new Pen(Color.FromArgb(40, Color.White))) g.DrawLine(p, 0, Height - 1, Width, Height - 1);
        var rects = LayoutTabs();
        if (!animating && selected >= 0 && selected < rects.Length) { indX = rects[selected].X; indW = rects[selected].Width; }

        for (int i = 0; i < rects.Length; i++) {
            var t = Tabs[i];
            var rc = rects[i];
            bool sel = i == selected, hot = i == hover;
            Color bg = sel ? Palette.Raised : hot ? Palette.TabHover : BackColor;   // approximate colour behind the badges
            if (sel || hot) FillRound(g, rc, 8, Color.FromArgb(sel ? 22 : 10, Color.White));   // frosted glass pill
            if (sel) {
                Glyphs.Gloss(g, rc, 8, 34);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var path = Glyphs.Round(rc, 8, true)) using (var p = new Pen(Color.FromArgb(48, Color.White))) g.DrawPath(p, path);
                g.SmoothingMode = SmoothingMode.None;
            }

            int x = rc.X + 12, cy = rc.Y + rc.Height / 2;
            int bw = BadgeWidth(t);
            if (t.Home) {
                Glyphs.Draw(g, Glyph.Home, new Rectangle(x, cy - Badge / 2, Badge, Badge), sel ? Palette.Accent : Palette.Muted);
            } else if (bw > 0) {
                int n = Math.Min(3, t.Avatars.Length);
                for (int k = n - 1; k >= 0; k--)   // first badge on top
                    Glyphs.DrawAvatar(g, t.Avatars[k], new Rectangle(x + k * BadgeStep, cy - Badge / 2, Badge, Badge), bg, !sel && !hot);
            }
            if (bw > 0) x += bw + 8;

            bool showClose = t.Closable && (sel || hot);
            var tr = new Rectangle(x, rc.Y, rc.Right - x - (t.Closable ? 28 : 12), rc.Height);
            TextRenderer.DrawText(g, t.Text, sel ? Bold : Font, tr, sel || hot ? Palette.Text : Palette.Muted, TextFlags);
            if (showClose) {
                var cr = CloseRect(rc);
                bool hc = hot && hoverClose;
                if (hc) FillRound(g, cr, 5, Palette.Hover);
                Glyphs.Draw(g, Glyph.Close, cr, hc ? Palette.Text : Palette.Muted);
            }
        }

        // glowing underline under the selected tab
        if (selected >= 0 && selected < rects.Length && indX >= 0) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float w = Math.Max(10, indW - 28), x0 = indX + (indW - w) / 2, y0 = Height - 5;
            for (int k = 3; k >= 1; k--)
                using (var b = new SolidBrush(Color.FromArgb(28, Palette.Accent)))
                    g.FillEllipse(b, x0 - k * 3, y0 - k * 2, w + k * 6, 3 + k * 4);
            using (var path = Glyphs.Round(new Rectangle((int)x0, (int)y0, (int)w, 3), 1, true))
            using (var b = new SolidBrush(Palette.Accent))
                g.FillPath(b, path);
            g.SmoothingMode = SmoothingMode.None;
        }

        if (hoverAdd) FillRound(g, addRect, 6, Color.FromArgb(16, Color.White));
        Glyphs.Draw(g, Glyph.Add, addRect, hoverAdd ? Palette.Text : Palette.Muted);
        if (hoverList) FillRound(g, listRect, 6, Color.FromArgb(16, Color.White));
        Glyphs.Draw(g, Glyph.Chevron, listRect, hoverList ? Palette.Text : Palette.Muted);
    }

    static string Shortcut(int i, int count) {
        if (i < 8) return "Ctrl+" + (i + 1);
        return i == count - 1 ? "Ctrl+9" : "";
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        var rects = LayoutTabs();
        int h = HitTab(rects, e.Location);
        bool hc = OnClose(rects, h, e.Location);
        bool ha = h < 0 && addRect.Contains(e.Location);
        bool hl = h < 0 && listRect.Contains(e.Location);
        if (h != hover || hc != hoverClose || ha != hoverAdd || hl != hoverList) {
            hover = h; hoverClose = hc; hoverAdd = ha; hoverList = hl;
            Invalidate();
        }
        string want = null;
        if (h >= 0) {
            string key = Shortcut(h, Tabs.Count);
            want = hc ? "Close tab" : Tabs[h].ToolTip + (key == "" ? "" : "\n" + key);
        } else if (ha) want = "Open a project in a new tab";
        else if (hl) want = "All tabs (Ctrl+Tab / Ctrl+Shift+Tab to cycle)";
        if (want != tipText) { tipText = want; tip.SetToolTip(this, want ?? ""); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        int next = Math.Max(0, Math.Min(Tabs.Count - 1, selected + (e.Delta < 0 ? 1 : -1)));
        if (next != selected && TabSelected != null) TabSelected(this, new StripTabEventArgs(next, e.Location));
    }

    protected override void OnMouseLeave(EventArgs e) {
        hover = -1; hoverClose = false; hoverAdd = false; hoverList = false; tipText = null;
        tip.SetToolTip(this, "");
        Invalidate();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        var rects = LayoutTabs();
        int h = HitTab(rects, e.Location);
        if (h >= 0 && !OnClose(rects, h, e.Location) && TabSelected != null) TabSelected(this, new StripTabEventArgs(h, e.Location));
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        var rects = LayoutTabs();
        int h = HitTab(rects, e.Location);
        var args = new StripTabEventArgs(h, e.Location);
        if (e.Button == MouseButtons.Left) {
            if (OnClose(rects, h, e.Location)) { if (TabCloseRequested != null) TabCloseRequested(this, args); }
            else if (h < 0 && addRect.Contains(e.Location)) {
                hoverAdd = false; Invalidate();
                if (AddClicked != null) AddClicked(this, EventArgs.Empty);
            } else if (h < 0 && listRect.Contains(e.Location)) {
                hoverList = false; Invalidate();
                if (ListClicked != null) ListClicked(this, new StripTabEventArgs(-1, new Point(listRect.Right, listRect.Bottom)));
            }
        } else if (e.Button == MouseButtons.Middle) {
            if (h >= 0 && Tabs[h].Closable && TabCloseRequested != null) TabCloseRequested(this, args);
        } else if (e.Button == MouseButtons.Right) {
            if (h >= 0 && TabContextMenu != null) TabContextMenu(this, args);
        }
    }
}

public class DarkMenuColors : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return Palette.Raised; } }
    public override Color MenuBorder { get { return Palette.Border; } }
    public override Color MenuItemBorder { get { return Palette.Hover; } }
    public override Color MenuItemSelected { get { return Palette.Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Palette.Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Palette.Hover; } }
    public override Color ImageMarginGradientBegin { get { return Palette.Raised; } }
    public override Color ImageMarginGradientMiddle { get { return Palette.Raised; } }
    public override Color ImageMarginGradientEnd { get { return Palette.Raised; } }
    public override Color SeparatorDark { get { return Palette.Border; } }
    public override Color SeparatorLight { get { return Palette.Raised; } }

    public static ToolStripRenderer CreateRenderer() {
        return new ToolStripProfessionalRenderer(new DarkMenuColors()) { RoundedEdges = false };
    }
}
'@

$AppDir     = Join-Path $env:APPDATA 'AgentTabs'
$ConfigPath = Join-Path $AppDir 'config.json'

# The app was called Claude Launcher before; carry its settings over on first run under the new name.
$OldConfig = Join-Path $env:APPDATA 'ClaudeLauncher\config.json'
if (-not (Test-Path -LiteralPath $ConfigPath) -and (Test-Path -LiteralPath $OldConfig)) {
    try {
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
        Copy-Item -LiteralPath $OldConfig -Destination $ConfigPath
    } catch { }
}
$WindowName = 'ClaudeProjects'   # all tabs go into this named Windows Terminal window
$MaxPanes   = 8                  # per tab

# ---------------------------------------------------------------- config
function Load-Config {
    $cfg = @{ roots = @(); projects = @(); hidden = @(); recent = @(); continue = $false; external = $false; remote = $false; glass = $false
              reopen = $true; window = $null; session = $null }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($j.roots)    { $cfg.roots    = @($j.roots) }
            if ($j.projects) { $cfg.projects = @($j.projects) }
            if ($j.hidden)   { $cfg.hidden   = @($j.hidden) }
            if ($j.recent)   { $cfg.recent   = @($j.recent) }
            if ($j.continue) { $cfg.continue = [bool]$j.continue }
            if ($j.external) { $cfg.external = [bool]$j.external }
            if ($j.remote)   { $cfg.remote   = [bool]$j.remote }
            if ($j.glass)    { $cfg.glass    = [bool]$j.glass }
            if ($null -ne $j.reopen) { $cfg.reopen = [bool]$j.reopen }   # on unless turned off
            if ($j.window)   { $cfg.window   = $j.window }
            if ($j.session)  { $cfg.session  = $j.session }
        } catch {
            # unreadable: set it aside (the next save would overwrite it) and start with defaults
            $bad = "$ConfigPath.bad-$(Get-Date -Format yyyyMMdd-HHmmss)"
            try { Move-Item -LiteralPath $ConfigPath -Destination $bad -Force } catch { }
            $script:ConfigWarning = "Settings file was unreadable and has been set aside as $(Split-Path $bad -Leaf) - starting with defaults."
        }
    }
    return $cfg
}

function Save-Config {
    if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    $script:Config.continue = $chkContinue.Checked
    $script:Config.external = $chkExternal.Checked
    $script:Config.remote   = $chkRemote.Checked
    $script:Config.glass    = $chkGlass.Checked
    $script:Config.reopen   = $chkReopen.Checked
    [pscustomobject]@{
        roots    = @($script:Config.roots)
        projects = @($script:Config.projects)
        hidden   = @($script:Config.hidden)
        recent   = @($script:Config.recent)
        continue = [bool]$script:Config.continue
        external = [bool]$script:Config.external
        remote   = [bool]$script:Config.remote
        glass    = [bool]$script:Config.glass
        reopen   = [bool]$script:Config.reopen
        window   = $script:Config.window
        session  = $script:Config.session
    } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath "$ConfigPath.tmp" -Encoding UTF8   # deep enough for nested split layouts
    # swap the finished file in, so a crash mid-write can't leave a truncated config
    if (Test-Path -LiteralPath $ConfigPath) { [System.IO.File]::Replace("$ConfigPath.tmp", $ConfigPath, [NullString]::Value) }   # no backup copy
    else { Move-Item -LiteralPath "$ConfigPath.tmp" -Destination $ConfigPath }
}

$script:Config = Load-Config

# ---------------------------------------------------------------- projects
function Get-Projects {
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($p in $script:Config.projects) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            if (-not $seen.ContainsKey($p)) {
                $seen[$p] = 1
                $list.Add([pscustomobject]@{ Name = (Split-Path $p -Leaf); Path = $p; Source = 'Pinned' })
            }
        }
    }
    foreach ($r in $script:Config.roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('.') } |
            ForEach-Object {
                $full = $_.FullName
                if ($seen.ContainsKey($full) -or ($script:Config.hidden -contains $full)) { return }
                $seen[$full] = 1
                $list.Add([pscustomobject]@{ Name = $_.Name; Path = $full; Source = (Split-Path $r -Leaf) })
            }
    }
    return (Sort-Projects $list)
}

# The most recently opened projects come first (newest at the top), then the rest by name.
$RecentTop = 5
function Sort-Projects($list) {
    $rank = @{}
    foreach ($r in @($script:Config.recent | Select-Object -First $RecentTop)) { $rank[$r] = $rank.Count }
    $script:RecentRank = $rank
    $top  = @($list | Where-Object { $rank.ContainsKey($_.Path) } | Sort-Object { $rank[$_.Path] })
    $rest = @($list | Where-Object { -not $rank.ContainsKey($_.Path) } | Sort-Object Name)
    return @($top) + @($rest)
}

function Note-Recent($proj) {
    if ($script:Restoring) { return }   # reopening last session's tabs isn't a fresh use
    $script:Config.recent = @(@($proj.Path) + @($script:Config.recent | Where-Object { $_ -ne $proj.Path }) | Select-Object -First 20)
    $script:RecentDirty = $true
    $script:SavePending = $true   # Update-Sessions saves once, rather than once per pane of a grid
}

# Re-sorts the list after projects were opened, once the Projects tab is showing.
function Update-RecentOrder {
    if (-not $script:RecentDirty -or -not (Get-SelectedTab).IsHome) { return }
    $script:RecentDirty = $false
    $script:AllProjects = @(Sort-Projects $script:AllProjects)
    Refresh-List
}

function Reload-Projects {
    $script:AllProjects = @(Get-Projects)
    Refresh-List
}

function Test-ProjectMatch($p, $q) {
    return (-not $q) -or
        $p.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $p.Path.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Refresh-List {
    $q = $txtSearch.Text.Trim()
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $script:RecentEnd = -1   # index of the last recent row; a divider is drawn under it
    foreach ($p in $script:AllProjects) {
        if (-not (Test-ProjectMatch $p $q)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
        [void]$item.SubItems.Add($p.Path)
        [void]$item.SubItems.Add($p.Source)
        $item.Tag = $p
        [void]$lv.Items.Add($item)
        if ($script:RecentRank -and $script:RecentRank.ContainsKey($p.Path)) { $script:RecentEnd = $item.Index }
    }
    if ($script:RecentEnd -ge $lv.Items.Count - 1) { $script:RecentEnd = -1 }   # nothing below to divide from
    $lv.EndUpdate()
    if ($lv.Items.Count -gt 0 -and $lv.SelectedItems.Count -eq 0) { $lv.Items[0].Selected = $true }

    if ($script:AllProjects.Count -eq 0) {
        $lblStatus.Text = "No projects yet - click `"Add project$Ell`" or `"Root folders$Ell`" to get started."
    } else {
        $lblStatus.Text = "$($lv.Items.Count) of $($script:AllProjects.Count) projects   $Mid   Enter to open   $Mid   Ctrl+Enter side by side   $Mid   Ctrl+Tab switches tabs"
    }
}

# ---------------------------------------------------------------- theme helpers
# The script stays ASCII so Windows PowerShell 5.1 reads it correctly; typographic characters come from code points.
$Ell = [string][char]0x2026
$Mid = [string][char]0x00B7

$script:UiFont    = New-Object System.Drawing.Font('Segoe UI', 9.5)
$script:BoldFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:SmallFont = New-Object System.Drawing.Font('Segoe UI', 8.5)
$script:CapsFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$script:TitleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$script:Brush = @{}
foreach ($k in 'Bg', 'Surface', 'Raised', 'Selection', 'SelectionDim', 'Accent', 'Running') { $script:Brush[$k] = New-Object System.Drawing.SolidBrush([Palette]::$k) }
$script:BorderPen  = New-Object System.Drawing.Pen([Palette]::Border)
$script:CellFormat = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
$script:Tip = New-Object System.Windows.Forms.ToolTip
[System.Windows.Forms.ToolStripManager]::Renderer = [DarkMenuColors]::CreateRenderer()   # also covers submenus

function New-Btn($text, [switch]$Primary) {
    $b = New-Object UiButton
    $b.Font = $script:UiFont
    $b.Text = $text
    $b.Primary = [bool]$Primary
    $b.Width = [System.Windows.Forms.TextRenderer]::MeasureText($text, $script:UiFont).Width + 36
    $b.Margin = '0,0,8,0'
    return $b
}

function New-Check($text, $checked) {
    $c = New-Object ToggleSwitch
    $c.Font = $script:UiFont
    $c.Text = $text
    $c.Checked = $checked
    $c.Margin = '22,0,0,0'
    return $c
}

# Borderless text box inside a panel that draws the frame (accent while focused). The panel's Tag is the text box.
function New-SearchBox($cue, $width) {
    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Size = New-Object System.Drawing.Size($width, 32)
    $wrap.BackColor = [Palette]::Raised
    $wrap.Padding = '32,8,10,4'
    $box = New-Object System.Windows.Forms.TextBox
    $box.Dock = 'Fill'; $box.BorderStyle = 'None'
    $box.BackColor = [Palette]::Raised; $box.ForeColor = [Palette]::Text
    $box.AccessibleDescription = $cue
    $wrap.Controls.Add($box)
    $wrap.Tag = $box; $box.Tag = $wrap
    $wrap.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($(if ($this.Tag.Focused) { [Palette]::Accent } else { [Palette]::Border }))
        $e.Graphics.DrawRectangle($pen, 0, 0, $this.Width - 1, $this.Height - 1)
        $pen.Dispose()
        [Glyphs]::Draw($e.Graphics, 'Search', (New-Object System.Drawing.Rectangle(6, 0, 22, $this.Height)), [Palette]::Muted)
    })
    $wrap.Add_Click({ [void]$this.Tag.Focus() })
    $box.Add_GotFocus({ $this.Tag.Invalidate() })
    $box.Add_LostFocus({ $this.Tag.Invalidate() })
    $box.Add_HandleCreated({ [UiNative]::SetCueBanner($this.Handle, $this.AccessibleDescription) })
    return $wrap
}

function New-Dialog($title, $w, $h) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.Size = New-Object System.Drawing.Size($w, $h)
    $d.StartPosition = 'CenterParent'
    $d.MinimizeBox = $false; $d.MaximizeBox = $false; $d.ShowInTaskbar = $false; $d.ShowIcon = $false
    $d.SizeGripStyle = 'Hide'
    $d.BackColor = [Palette]::Bg; $d.ForeColor = [Palette]::Text
    $d.Font = $script:UiFont
    $d.Padding = '14,14,14,10'
    $d.Add_HandleCreated({ [UiNative]::DarkTitleBar($this.Handle, [Palette]::Bg) })
    return $d
}

function New-DialogBar {
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 50; $bar.Padding = '0,14,0,0'
    $bar.FlowDirection = 'RightToLeft'; $bar.WrapContents = $false
    return $bar
}

function New-BorderFrame($inner) {
    $f = New-Object System.Windows.Forms.Panel
    $f.Dock = 'Fill'; $f.Padding = '1,1,1,1'; $f.BackColor = [Palette]::Border
    $f.Controls.Add($inner)
    return $f
}

function New-Menu {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Renderer = [DarkMenuColors]::CreateRenderer()
    $m.ShowImageMargin = $false
    $m.BackColor = [Palette]::Raised; $m.ForeColor = [Palette]::Text
    $m.Font = $script:UiFont
    return $m
}

# Menu item that can hold a dark submenu.
function New-MenuItem($text, $tag) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.ForeColor = [Palette]::Text
    $mi.Tag = $tag
    $mi.DropDown.BackColor = [Palette]::Raised
    $mi.DropDown.ShowImageMargin = $false
    return $mi
}

# Fills $parent's submenu with the other session tabs, each offering "Side by side" / "Stacked".
# $kind 'pane' moves the pane $source; 'tab' moves every pane of the tab $source.
function Fill-MoveTargets($parent, $kind, $source, $sourceTab) {
    while ($parent.DropDownItems.Count -gt 0) { $parent.DropDownItems[0].Dispose() }
    $targets = @(Get-SessionTabs | Where-Object { $_ -ne $sourceTab })
    foreach ($t in $targets) {
        $mi = New-MenuItem $t.Strip.Text $null
        foreach ($d in @(@('Side by side', 'Vertical'), @('Stacked', 'Horizontal'))) {
            $sub = New-MenuItem $d[0] @{ Kind = $kind; Source = $source; Dest = $t; Dir = $d[1] }
            $sub.Add_Click({
                $x = $this.Tag
                if ($x.Kind -eq 'pane') { Move-PaneInto $x.Source $x.Dest $x.Dir $null } else { Merge-Tab $x.Source $x.Dest $x.Dir }
            })
            [void]$mi.DropDownItems.Add($sub)
        }
        [void]$parent.DropDownItems.Add($mi)
    }
    $parent.Enabled = $targets.Count -gt 0
}

# Two-line list entry: project name over its path.
function Draw-ProjectItem($e, $items) {
    if ($e.Index -lt 0) { return }
    $p = $items[$e.Index]
    $b = $e.Bounds
    $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $e.Graphics.FillRectangle($(if ($sel) { $script:Brush.Selection } else { $script:Brush.Bg }), $b)
    if ($sel) { $e.Graphics.FillRectangle($script:Brush.Accent, $b.X, $b.Y, 3, $b.Height) }
    $r1 = New-Object System.Drawing.Rectangle(($b.X + 14), ($b.Y + 5), ($b.Width - 20), 20)
    $r2 = New-Object System.Drawing.Rectangle(($b.X + 14), ($b.Y + 23), ($b.Width - 20), 17)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $p.Name, $script:BoldFont, $r1, [Palette]::Text, $script:CellFormat)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $p.Path, $script:SmallFont, $r2, [Palette]::Muted, $script:CellFormat)
}

# ---------------------------------------------------------------- launching
$script:HasWT = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)

function Get-ClaudeCmd($proj) {
    $cmd = 'claude'
    if ($chkContinue.Checked) { $cmd += ' --continue' }
    if ($chkRemote.Checked) {
        # name the Remote Control session after the project; plain characters only, so no quoting is needed
        $name = ($proj.Name -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
        $cmd += " --remote-control $name"
    }
    return $cmd
}

# Avoid a trailing backslash escaping the closing quote (e.g. "C:\")
function Get-QuotableDir($path) {
    $dir = $path.TrimEnd('\')
    if ($dir -match ':$') { $dir += '\.' }
    return $dir
}

# Opens the projects in one Windows Terminal tab (split side by side when there are several),
# or with -Tabs, each in its own tab. One wt.exe call either way, so the tabs land in the same window.
function Open-External($projs, [switch]$Tabs) {
    if ($script:HasWT) {
        $parts = for ($i = 0; $i -lt $projs.Count; $i++) {
            $p = $projs[$i]
            $cmd   = Get-ClaudeCmd $p
            $verb  = if ($i -eq 0 -or $Tabs) { 'new-tab' } else { 'split-pane -V' }
            $title = ($p.Name -replace '[;"]', '')
            $dir   = (Get-QuotableDir $p.Path) -replace ';', '\;'   # wt splits commands on any unescaped ';', even inside quotes
            "$verb --title `"$title`" --suppressApplicationTitle -d `"$dir`" cmd /k $cmd"
        }
        Start-Process -FilePath 'wt.exe' -ArgumentList ("-w $WindowName " + ($parts -join ' ; '))
    } else {
        foreach ($p in $projs) {
            $title = $p.Name -replace '([&|<>^()])', '^$1'   # cmd metacharacters in a folder name would end the title command
            Start-Process -FilePath 'cmd.exe' -ArgumentList "/k title $title & $(Get-ClaudeCmd $p)" -WorkingDirectory $p.Path
        }
    }
    foreach ($p in $projs) { Note-Recent $p }
}

function Get-SelectedProjects {
    $sel = @($lv.SelectedItems)
    if ($sel.Count -eq 0 -and $lv.Items.Count -gt 0) { $sel = @($lv.Items[0]) }
    return @($sel | ForEach-Object { $_.Tag })
}

function Open-Selected {
    $projs = @(Get-SelectedProjects)
    if ($chkExternal.Checked) {
        if ($projs.Count -gt 0) { Open-External $projs -Tabs }
    } else {
        foreach ($p in $projs) { [void](Open-InNewTab $p) }
    }
    Update-RecentOrder
}

function Open-SideBySide {
    $projs = @(Get-SelectedProjects)
    if ($projs.Count -eq 0) { return }
    if ($projs.Count -gt $MaxPanes) {
        [System.Windows.Forms.MessageBox]::Show("Only the first $MaxPanes projects will be opened side by side.",
            'Agent Tabs', 'OK', 'Information') | Out-Null
        $projs = $projs[0..($MaxPanes - 1)]
    }
    if ($chkExternal.Checked) { Open-External $projs } else { Open-Grid $projs }
    Update-RecentOrder
}

# ---------------------------------------------------------------- embedded sessions
# Each session is a conhost.exe window (running cmd /k claude) docked into a pane.
# conhost.exe is started explicitly so Windows 11 doesn't hand the console off to Windows Terminal.
# A tab's body holds either one pane or a tree of SplitContainers with a pane at every leaf.

# Starts the console without waiting for its window: the pane shows "Starting..." and $dockTimer docks
# the window once it appears, so opening several panes doesn't stall the launcher.
$ConsoleTimeout = 10   # seconds for the console window to appear
function Start-Console($proj) {
    try {
        # Process.Start directly: about a third of Start-Process's time, which adds up when opening a grid
        $si = New-Object System.Diagnostics.ProcessStartInfo('conhost.exe', "cmd.exe /k $(Get-ClaudeCmd $proj)")
        $si.UseShellExecute = $true; $si.WindowStyle = 'Hidden'; $si.WorkingDirectory = $proj.Path
        $p = [System.Diagnostics.Process]::Start($si)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start a console for $($proj.Name).`n`n$_", 'Agent Tabs', 'OK', 'Error') | Out-Null
        return $null
    }
    Note-Recent $proj
    $dockTimer.Start()
    return [pscustomobject]@{ Proc = $p; Hwnd = [IntPtr]::Zero }
}

# Docks a started console into its pane once its window exists.
function Dock-Console($pane) {
    [ConsoleDock]::Embed($pane.Hwnd, $pane.View.Handle)
    foreach ($c in @($pane.View.Controls)) { $c.Dispose() }   # the "Starting..." note
    $pane.Fresh = $true   # conhost only paints after a later re-fit
    Fit-Pane $pane
    if ($pane.Tab -eq (Get-SelectedTab) -and (Get-ActivePane $pane.Tab) -eq $pane -and $form.ContainsFocus) { Focus-Pane $pane }
}

function Update-PendingConsoles {
    $waiting = 0
    foreach ($pane in (Get-AllPanes)) {
        if ($pane.Hwnd -ne [IntPtr]::Zero -or $pane.Failed -or $pane.Closing) { continue }   # closed while starting: not a failure
        $h = if ($pane.Proc.HasExited) { [IntPtr]::Zero } else { [ConsoleDock]::FindConsoleWindow($pane.Proc.Id) }
        if ($h -ne [IntPtr]::Zero) { $pane.Hwnd = $h; Dock-Console $pane; continue }
        if ($pane.Proc.HasExited -or ((Get-Date) - $pane.Started).TotalSeconds -gt $ConsoleTimeout) {
            $pane.Failed = $true   # Update-Sessions removes it
            if (-not $pane.Proc.HasExited) { & taskkill.exe /T /F /PID $pane.Proc.Id 2>&1 | Out-Null }
            $script:FailedStarts += @($pane.Project.Name)
            continue
        }
        $waiting++
    }
    if ($waiting -eq 0) { $dockTimer.Stop() }
}

# Pane cards have rounded corners: the card's window region (inset 1px) clips it and the console docked
# in it, and the container behind paints an anti-aliased rounded shape in the card's outline colour,
# which shows as a smooth 1px rim all the way round, curves included.
$CardRadius = 10

function Set-CardRegion($card) {
    if ($card.Width -lt 4 -or $card.Height -lt 4) { return }
    $path = [Glyphs]::Round((New-Object System.Drawing.Rectangle(1, 1, ($card.Width - 2), ($card.Height - 2))), ($CardRadius - 1), $true)
    $old = $card.Region
    $card.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
    if ($old) { $old.Dispose() }
    if ($card.Parent) { $card.Parent.Invalidate() }
}

$GlowSize = 4   # px of soft glow around the active pane (fits in the containers' padding)

function Paint-CardEdges($container, $e) {
    $e.Graphics.SmoothingMode = 'AntiAlias'
    foreach ($c in $container.Controls) {
        if ("$($c.Tag)" -notlike 'card*') { continue }
        if ($c.Tag -eq 'card-active') {
            # soft accent glow, layered outside-in so it fades away from the card
            for ($i = $GlowSize; $i -ge 1; $i--) {
                $r = [System.Drawing.Rectangle]::Inflate($c.Bounds, $i, $i)
                $path = [Glyphs]::Round($r, ($CardRadius + $i), $true)
                $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb((10 + ($GlowSize - $i) * 9), [Palette]::Accent))
                $e.Graphics.FillPath($b, $path)
                $b.Dispose(); $path.Dispose()
            }
        }
        $path = [Glyphs]::Round($c.Bounds, $CardRadius, $true)
        $b = New-Object System.Drawing.SolidBrush($c.BackColor)
        $e.Graphics.FillPath($b, $path)
        $b.Dispose(); $path.Dispose()
    }
}

# Containers that can hold a card (a tab body, either side of a split).
function Add-CardEdges($container) {
    $container.Add_Paint({ param($s, $e) Paint-CardEdges $s $e })
    $container.Add_Resize({ $this.Invalidate() })
}

function New-Tab {
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.BackColor = [Palette]::Bg; $body.Visible = $false
    $body.Padding = '6,6,6,6'   # panes float as cards with a gap around them
    Add-CardEdges $body
    $content.Controls.Add($body)
    $tab = [pscustomobject]@{
        IsHome = $false; Body = $body; Active = $null
        Panes  = (New-Object System.Collections.Generic.List[object])
        Strip  = (New-Object StripTab)
    }
    $tab.Strip.Tag = $tab
    $strip.Tabs.Add($tab.Strip)
    $strip.Invalidate()
    return $tab
}

# A pane: header (name, path, split/close buttons) above the panel the console is docked into.
function New-Pane($tab, $proj, $console) {
    # a card: 1px outline (the frame's own colour showing through its padding; accent when active)
    $frame = New-Object System.Windows.Forms.Panel
    $frame.Dock = 'Fill'; $frame.BackColor = [Palette]::Border; $frame.Padding = '1,1,1,1'
    $frame.Tag = 'card'
    $frame.Add_Resize({ Set-CardRegion $this })

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 34; $header.BackColor = [Palette]::Surface
    $header.Add_Paint({ param($s, $e) [Glyphs]::Gloss($e.Graphics, $s.ClientRectangle, 1, 22) })   # glossy sheen

    $badge = New-Object System.Windows.Forms.PictureBox
    $badge.Dock = 'Left'; $badge.Width = 34; $badge.SizeMode = 'CenterImage'
    $badge.BackColor = [System.Drawing.Color]::Transparent
    $badge.Image = [Glyphs]::Avatar($proj.Name, 20)

    $title = New-Object PaneTitle   # project name and folder on one baseline
    $title.Dock = 'Fill'
    $title.Font = $script:BoldFont; $title.SubFont = $script:SmallFont
    $title.ForeColor = [Palette]::Text
    $title.Text = $proj.Name; $title.Subtitle = $proj.Path

    $btns = New-Object System.Windows.Forms.FlowLayoutPanel
    $btns.Dock = 'Right'; $btns.AutoSize = $true; $btns.WrapContents = $false
    $btns.Padding = '0,5,6,0'; $btns.BackColor = [System.Drawing.Color]::Transparent

    $view = New-Object System.Windows.Forms.Panel
    $view.Dock = 'Fill'; $view.BackColor = [System.Drawing.Color]::Black
    $starting = New-Object System.Windows.Forms.Label   # until the console window is docked
    $starting.Dock = 'Fill'; $starting.TextAlign = 'MiddleCenter'
    $starting.ForeColor = [Palette]::Muted; $starting.Text = "Starting$Ell"
    $view.Controls.Add($starting)

    $pane = [pscustomobject]@{
        Proc = $console.Proc; Hwnd = $console.Hwnd; Project = $proj; Closing = $null; Fresh = $true
        Started = (Get-Date); Failed = $false
        Tab = $tab; Frame = $frame; View = $view; Header = $header; NameLabel = $title
    }

    foreach ($spec in @(@('SplitRight', 'Split right (side by side)'), @('SplitDown', 'Split down (stacked)'),
                        @('More', 'More: pop out to a new tab, move into another tab'), @('Close', 'Close pane'))) {
        $b = New-Object GlyphButton
        $b.Glyph = $spec[0]; $b.Danger = ($spec[0] -eq 'Close'); $b.Margin = '1,0,1,0'; $b.Tag = $pane
        $script:Tip.SetToolTip($b, $spec[1])
        $b.Add_Click({
            switch ("$($this.Glyph)") {
                'SplitRight' { Split-Interactive $this.Tag 'Vertical' }
                'SplitDown'  { Split-Interactive $this.Tag 'Horizontal' }
                'More'       { $paneMenu.Show($this, (New-Object System.Drawing.Point(0, $this.Height))) }
                'Close'      { Close-Pane $this.Tag }
            }
        })
        $btns.Controls.Add($b)
    }

    foreach ($c in @($header, $badge, $title)) {
        $c.Tag = $pane
        $script:Tip.SetToolTip($c, 'Click a pane or press Ctrl+Arrow keys to move between panes. Right-click for more.')
        $c.ContextMenuStrip = $paneMenu
        $c.Add_MouseDown({ Set-ActivePane $this.Tag $true })
    }
    $header.Controls.AddRange(@($title, $btns, $badge))
    $view.Tag = $pane
    $view.Add_Resize({ Fit-Pane $this.Tag })

    $frame.Controls.AddRange(@($view, $header))
    $tab.Panes.Add($pane)
    return $pane
}

function Attach-Pane($pane) {
    if ($pane.Hwnd -ne [IntPtr]::Zero) { Dock-Console $pane }
    Set-ActivePane $pane $true
    Update-TabTitle $pane.Tab
}

function Open-InNewTab($proj) {
    $c = Start-Console $proj
    if (-not $c) { return $null }
    $tab = New-Tab
    $pane = New-Pane $tab $proj $c
    $tab.Body.Controls.Add($pane.Frame)
    Select-Tab $tab
    Attach-Pane $pane
    return $pane
}

# Orientation 'Vertical' = side by side, 'Horizontal' = stacked.
function New-Split($orientation) {
    $sc = New-Object System.Windows.Forms.SplitContainer
    $sc.Size = New-Object System.Drawing.Size(4000, 4000)   # room for the min sizes until it's docked
    $sc.Orientation = $orientation
    $sc.SplitterWidth = 6; $sc.TabStop = $false
    $sc.BackColor = [Palette]::Bg   # the splitter is a gap between cards, with grip dots that light up on hover
    $sc.Add_Paint({
        param($s, $e)
        $c = if ($s.Tag) { [Palette]::Accent } else { [Palette]::Faint }
        [Glyphs]::Grip($e.Graphics, $s.SplitterRectangle, ($s.Orientation -eq 'Vertical'), $c)
    })
    $sc.Add_MouseMove({
        param($s, $e)
        $hot = $s.SplitterRectangle.Contains($e.Location)
        if ($hot -ne [bool]$s.Tag) { $s.Tag = $hot; $s.Invalidate() }
    })
    $sc.Add_MouseLeave({ $this.Tag = $false; $this.Invalidate() })
    $sc.Panel1.BackColor = [Palette]::Bg; $sc.Panel2.BackColor = [Palette]::Bg
    $sc.Panel1.Padding = '4,4,4,4'; $sc.Panel2.Padding = '4,4,4,4'   # room for the active pane's glow
    Add-CardEdges $sc.Panel1
    Add-CardEdges $sc.Panel2
    $sc.Panel1MinSize = 60; $sc.Panel2MinSize = 60
    $sc.Dock = 'Fill'
    $sc.Add_SplitterMoved({ Focus-Pane (Get-ActivePane (Get-SelectedTab)) })
    return $sc
}

# Replaces $target's frame with a split holding it and $pane's frame (the frames keep their consoles).
function Insert-Beside($target, $pane, $orientation) {
    $sc = New-Split $orientation
    $parent = $target.Frame.Parent
    $parent.Controls.Remove($target.Frame)
    $parent.Controls.Add($sc)
    $sc.Panel1.Controls.Add($target.Frame)
    $sc.Panel2.Controls.Add($pane.Frame)
}

# Splits $pane with a new session for $proj.
function Split-Pane($pane, $orientation, $proj) {
    $c = Start-Console $proj
    if (-not $c) { return $null }
    $tab = $pane.Tab
    $new = New-Pane $tab $proj $c
    Insert-Beside $pane $new $orientation

    Select-Tab $tab
    Even-Panes $tab
    Attach-Pane $new
    foreach ($p in $tab.Panes) { Fit-Pane $p }
    return $new
}

function Split-Interactive($pane, $orientation) {
    if (-not $pane) { return }
    if ($pane.Tab.Panes.Count -ge $MaxPanes) {
        [System.Windows.Forms.MessageBox]::Show("A tab can hold up to $MaxPanes panes.", 'Agent Tabs', 'OK', 'Information') | Out-Null
        return
    }
    $proj = Pick-Project $(if ($orientation -eq 'Vertical') { 'Split right' } else { 'Split down' }) $pane.Project
    if ($proj) { [void](Split-Pane $pane $orientation $proj) }
}

# Splits the selected projects from the list into the most recently used session tab.
function Split-FromList($orientation) {
    $tab = $script:LastTab
    if (-not $tab -or -not $strip.Tabs.Contains($tab.Strip)) { return }
    $target = Get-ActivePane $tab
    foreach ($p in @(Get-SelectedProjects)) {
        if ($tab.Panes.Count -ge $MaxPanes) { break }
        $new = Split-Pane $target $orientation $p
        if ($new) { $target = $new }
    }
}

# New tab with the projects in a grid: up to 3 side by side, otherwise two rows.
function Open-Grid($projs) {
    $n = $projs.Count
    $first = Open-InNewTab $projs[0]
    if (-not $first) { return }
    $cols = if ($n -le 3) { $n } else { [int][Math]::Ceiling($n / 2) }
    $row = New-Object System.Collections.Generic.List[object]
    $row.Add($first)
    for ($i = 1; $i -lt $cols; $i++) {
        $p = Split-Pane $row[$row.Count - 1] 'Vertical' $projs[$i]
        if ($p) { $row.Add($p) }
    }
    for ($i = $cols; $i -lt $n; $i++) {
        [void](Split-Pane $row[($i - $cols) % $row.Count] 'Horizontal' $projs[$i])
    }
    Even-Panes $first.Tab
    Set-ActivePane $first $true
}

# Number of panes laid out along $orientation inside $ctl (nested splits of the other direction count as one).
function Get-Span($ctl, $orientation) {
    if ($ctl -is [System.Windows.Forms.SplitContainer] -and $ctl.Orientation -eq $orientation) {
        return (Get-Span $ctl.Panel1.Controls[0] $orientation) + (Get-Span $ctl.Panel2.Controls[0] $orientation)
    }
    return 1
}

function Even-Split($ctl) {
    if (-not ($ctl -is [System.Windows.Forms.SplitContainer])) { return }
    $a = Get-Span $ctl.Panel1.Controls[0] $ctl.Orientation
    $b = Get-Span $ctl.Panel2.Controls[0] $ctl.Orientation
    $len = if ($ctl.Orientation -eq 'Vertical') { $ctl.Width } else { $ctl.Height }
    try { $ctl.SplitterDistance = [int](($len - $ctl.SplitterWidth) * $a / ($a + $b)) } catch { }
    Even-Split $ctl.Panel1.Controls[0]
    Even-Split $ctl.Panel2.Controls[0]
}

function Even-Panes($tab) {
    if ($tab -and $tab.Body.Controls.Count -gt 0) { Even-Split $tab.Body.Controls[0] }
}

# Takes a pane out of its tab without touching its console; its sibling takes over the parent split's
# space, and a tab left empty is removed. The caller re-homes or disposes $pane.Frame.
function Detach-Pane($pane) {
    $tab = $pane.Tab
    [void]$tab.Panes.Remove($pane)
    $pane.Fresh = $true   # a re-parented console only repaints after a later re-fit
    foreach ($p in $tab.Panes) { $p.Fresh = $true }
    $parent = $pane.Frame.Parent
    $parent.Controls.Remove($pane.Frame)
    if ($parent -is [System.Windows.Forms.SplitterPanel]) {
        $sc = $parent.Parent
        $other = if ($sc.Panel1 -eq $parent) { $sc.Panel2 } else { $sc.Panel1 }
        $keep = $other.Controls[0]
        $outer = $sc.Parent
        $other.Controls.Remove($keep)
        $outer.Controls.Remove($sc)
        $outer.Controls.Add($keep)
        $sc.Dispose()
    }
    if ($tab.Panes.Count -eq 0) { Remove-Tab $tab; return }
    if ($tab.Active -eq $pane) { $tab.Active = $null }
    Set-ActivePane (Get-ActivePane $tab) $false
    Update-TabTitle $tab
    foreach ($p in $tab.Panes) { Fit-Pane $p }
}

# Drops a pane whose console has exited.
function Remove-Pane($pane) {
    $tab = $pane.Tab
    Detach-Pane $pane
    $pane.Frame.Dispose()
    if ($tab.Panes.Count -gt 0 -and $tab -eq (Get-SelectedTab)) { Focus-Pane (Get-ActivePane $tab) }
}

# Moves a pane of a split into a tab of its own.
function Pop-OutPane($pane) {
    if (-not $pane -or $pane.Tab.Panes.Count -lt 2) { return }
    Detach-Pane $pane
    $tab = New-Tab
    $pane.Tab = $tab
    $tab.Panes.Add($pane)
    $tab.Body.Controls.Add($pane.Frame)
    Select-Tab $tab
    Set-ActivePane $pane $true
    Update-TabTitle $tab
    Fit-Pane $pane
}

# Moves a pane into another tab, split beside $target (default: that tab's active pane).
function Move-PaneInto($pane, $dst, $orientation, $target) {
    if (-not $target) { $target = Get-ActivePane $dst }
    if (-not $target -or $pane.Tab -eq $dst) { return }
    if ($dst.Panes.Count -ge $MaxPanes) {
        [System.Windows.Forms.MessageBox]::Show("A tab can hold up to $MaxPanes panes.", 'Agent Tabs', 'OK', 'Information') | Out-Null
        return
    }
    Detach-Pane $pane
    $pane.Tab = $dst
    $dst.Panes.Add($pane)
    Insert-Beside $target $pane $orientation
    foreach ($p in $dst.Panes) { $p.Fresh = $true }
    Select-Tab $dst
    Even-Panes $dst
    Set-ActivePane $pane $true
    Update-TabTitle $dst
    foreach ($p in $dst.Panes) { Fit-Pane $p }
}

# Moves every pane of tab $src into tab $dst, one after another along $orientation.
function Merge-Tab($src, $dst, $orientation) {
    if ($src.Panes.Count + $dst.Panes.Count -gt $MaxPanes) {
        [System.Windows.Forms.MessageBox]::Show("A tab can hold up to $MaxPanes panes.", 'Agent Tabs', 'OK', 'Information') | Out-Null
        return
    }
    $target = Get-ActivePane $dst
    foreach ($p in $src.Panes.ToArray()) {
        Move-PaneInto $p $dst $orientation $target
        $target = $p
    }
}

function Remove-Tab($tab) {
    $idx = $strip.Tabs.IndexOf($tab.Strip)
    $wasSelected = ($strip.SelectedIndex -eq $idx)
    [void]$strip.Tabs.Remove($tab.Strip)
    $content.Controls.Remove($tab.Body)
    $tab.Body.Dispose()
    if ($script:LastTab -eq $tab) { $script:LastTab = @(Get-SessionTabs) | Select-Object -Last 1 }
    if ($wasSelected) { Select-Tab $strip.Tabs[[Math]::Max(0, $idx - 1)].Tag }
    elseif ($strip.SelectedIndex -gt $idx) { $strip.SelectedIndex = $strip.SelectedIndex - 1 }
    $strip.Invalidate()
    Update-OpenMarks
}

function Select-Tab($tab) {
    $strip.SelectedIndex = $strip.Tabs.IndexOf($tab.Strip)
    $tab.Body.Visible = $true
    $tab.Body.BringToFront()
    foreach ($t in $strip.Tabs) { if ($t.Tag -ne $tab) { $t.Tag.Body.Visible = $false } }
    if ($tab.IsHome) {
        Update-RecentOrder
        [void]$txtSearch.Focus()
    } else {
        $script:LastTab = $tab
        foreach ($p in $tab.Panes) { Fit-Pane $p }
        Focus-Pane (Get-ActivePane $tab)
    }
}

# Moves to the nearest pane on the given side of the active one ('left', 'right', 'up', 'down').
function Move-PaneFocus($dir) {
    $tab = Get-SelectedTab
    $cur = Get-ActivePane $tab
    if (-not $cur -or $tab.Panes.Count -lt 2) { return }
    $a = $cur.Frame.RectangleToScreen($cur.Frame.ClientRectangle)
    $best = $null; $bestScore = [double]::MaxValue
    foreach ($p in $tab.Panes) {
        if ($p -eq $cur) { continue }
        $r = $p.Frame.RectangleToScreen($p.Frame.ClientRectangle)
        $gap = switch ($dir) {
            'left'  { $a.Left - $r.Right }
            'right' { $r.Left - $a.Right }
            'up'    { $a.Top - $r.Bottom }
            'down'  { $r.Top - $a.Bottom }
        }
        if ($gap -lt -8) { continue }   # not on that side
        # nearest side first, then the one best lined up with the active pane
        $off = if ($dir -in 'left', 'right') { [Math]::Abs(($r.Top + $r.Bottom) - ($a.Top + $a.Bottom)) }
               else { [Math]::Abs(($r.Left + $r.Right) - ($a.Left + $a.Right)) }
        $score = [Math]::Max(0, $gap) * 100000 + $off
        if ($score -lt $bestScore) { $best = $p; $bestScore = $score }
    }
    if ($best) { Set-ActivePane $best $true }
}

# Keyboard commands: "next" / "prev" wrap around; "tab:N" jumps to tab N (9 = last tab); "pane:<dir>" moves between splits.
function Invoke-TabCommand($name) {
    $n = $strip.Tabs.Count
    if ($name -match '^pane:(\w+)$') { Move-PaneFocus $Matches[1] }
    elseif ($name -eq 'next') { Select-Tab $strip.Tabs[($strip.SelectedIndex + 1) % $n].Tag }
    elseif ($name -eq 'prev') { Select-Tab $strip.Tabs[($strip.SelectedIndex - 1 + $n) % $n].Tag }
    elseif ($name -match '^tab:(\d)$') {
        $i = if ($Matches[1] -eq '9') { $n } else { [int]$Matches[1] }
        if ($i -le $n) { Select-Tab $strip.Tabs[$i - 1].Tag }
    }
}

function Get-SelectedTab {
    $i = $strip.SelectedIndex
    if ($i -ge 0 -and $i -lt $strip.Tabs.Count) { return $strip.Tabs[$i].Tag }
    return $homeTab
}

function Get-SessionTabs { @($strip.Tabs | Where-Object { -not $_.Tag.IsHome } | ForEach-Object { $_.Tag }) }

function Get-AllPanes { @(Get-SessionTabs | ForEach-Object { $_.Panes }) }

function Get-ActivePane($tab) {
    if (-not $tab -or $tab.Panes.Count -eq 0) { return $null }
    if ($tab.Active -and $tab.Panes.Contains($tab.Active)) { return $tab.Active }
    return $tab.Panes[0]
}

function Set-ActivePane($pane, $focus) {
    if (-not $pane) { return }
    $tab = $pane.Tab
    $tab.Active = $pane
    $multi = $tab.Panes.Count -gt 1
    foreach ($p in $tab.Panes) {
        $on = ($p -eq $pane)
        $p.Frame.BackColor  = if ($on -and $multi) { [Palette]::ActiveRim } else { [Palette]::Border }
        $p.Frame.Tag        = if ($on -and $multi) { 'card-active' } else { 'card' }
        if ($p.Frame.Parent) { $p.Frame.Parent.Invalidate() }   # repaint the smoothed corners in the new colour
        $p.Header.BackColor = if ($on -and $multi) { [Palette]::ActiveHeader } else { [Palette]::Surface }
        $p.NameLabel.ForeColor = if ($on -or -not $multi) { [Palette]::Text } else { [Palette]::Muted }
    }
    if ($focus) { Focus-Pane $pane }
}

function Update-TabTitle($tab) {
    $tab.Strip.Text    = (@($tab.Panes | ForEach-Object { $_.Project.Name }) -join '  |  ')
    $tab.Strip.ToolTip = (@($tab.Panes | ForEach-Object { $_.Project.Path }) -join "`n")
    $tab.Strip.Avatars = [string[]]@($tab.Panes | ForEach-Object { $_.Project.Name })
    $strip.Invalidate()
    Update-OpenMarks
}

# Projects with an open session get a green dot in the project list.
$script:OpenPaths = @{}
function Update-OpenMarks {
    $script:OpenPaths = @{}
    foreach ($p in (Get-AllPanes)) { $script:OpenPaths[$p.Project.Path] = $true }
    $lv.Invalidate()
}

function Fit-Pane($pane) {
    if (-not $pane -or -not [ConsoleDock]::IsWindow($pane.Hwnd)) { return }
    $r = $pane.View.ClientRectangle
    # conhost only starts painting after it sees a real size change, so nudge it by a pixel first
    [void][ConsoleDock]::MoveWindow($pane.Hwnd, 0, 0, [Math]::Max(1, $r.Width - 1), $r.Height, $false)
    [void][ConsoleDock]::MoveWindow($pane.Hwnd, 0, 0, $r.Width, $r.Height, $true)
}

function Focus-Pane($pane) {
    if ($pane -and [ConsoleDock]::IsWindow($pane.Hwnd)) { [void][ConsoleDock]::SetFocus($pane.Hwnd) }
}

# Ask the console to close (sends CTRL_CLOSE to claude); the timer removes the pane once it exits.
function Close-Pane($pane) {
    if (-not $pane -or $pane.Closing) { return }
    $pane.Closing = (Get-Date).AddSeconds(3)
    $pane.NameLabel.Text = "$($pane.Project.Name) (closing$Ell)"
    if ($pane.Hwnd -eq [IntPtr]::Zero) {   # still starting: nothing to ask yet
        if (-not $pane.Proc.HasExited) { & taskkill.exe /T /F /PID $pane.Proc.Id 2>&1 | Out-Null }
        return
    }
    [void][ConsoleDock]::PostMessage($pane.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
}

function Close-Tab($tab) {
    if (-not $tab -or $tab.IsHome) { return }
    foreach ($p in $tab.Panes.ToArray()) { Close-Pane $p }
}

# Clicking into a console makes its pane the active one and gives it keyboard focus.
function Activate-PaneAt($hwnd) {
    foreach ($p in (Get-SelectedTab).Panes) {
        if ($p.Hwnd -eq $hwnd -or [UiNative]::IsChild($p.Hwnd, $hwnd)) { Set-ActivePane $p $true; return }
    }
}

# Polls sessions: drop panes whose console has exited, force-kill ones that ignore WM_CLOSE.
# Also lets Ctrl+Arrow through to the console unless the current tab is split.
function Update-Sessions {
    if ($script:Keys) { $script:Keys.PaneKeys = ((Get-SelectedTab).Panes.Count -gt 1) }
    foreach ($pane in (Get-AllPanes)) {
        $starting = ($pane.Hwnd -eq [IntPtr]::Zero) -and -not $pane.Failed -and -not $pane.Closing   # $dockTimer reports those
        if ($pane.Proc.HasExited -and -not $starting) {
            Remove-Pane $pane
        } elseif ($pane.Fresh) {
            $pane.Fresh = $false   # first tick after docking: re-fit so conhost paints
            Fit-Pane $pane
        } elseif ($pane.Closing -and (Get-Date) -gt $pane.Closing) {
            & taskkill.exe /T /F /PID $pane.Proc.Id 2>&1 | Out-Null
        }
    }
    if ($script:SavePending) { $script:SavePending = $false; Save-Config }
    if ($script:FailedStarts) {
        $names = $script:FailedStarts -join ', '
        $script:FailedStarts = @()   # cleared first: the timer keeps ticking behind the message box
        [System.Windows.Forms.MessageBox]::Show("Could not start a console for $names.", 'Agent Tabs', 'OK', 'Error') | Out-Null
    }
}

# ---------------------------------------------------------------- session restore
# A tab's layout is saved as a tree: a leaf is @{ path }, a split is @{ split; ratio; a; b } (a = left/top).

function Get-Layout($ctl, $tab) {
    if ($ctl -is [System.Windows.Forms.SplitContainer]) {
        $len = if ($ctl.Orientation -eq 'Vertical') { $ctl.Width } else { $ctl.Height }
        return @{
            split = "$($ctl.Orientation)"
            ratio = [Math]::Round($ctl.SplitterDistance / [Math]::Max(1, $len - $ctl.SplitterWidth), 3)
            a     = (Get-Layout $ctl.Panel1.Controls[0] $tab)
            b     = (Get-Layout $ctl.Panel2.Controls[0] $tab)
        }
    }
    $pane = $tab.Panes | Where-Object { $_.Frame -eq $ctl } | Select-Object -First 1
    return @{ path = $pane.Project.Path }
}

function Save-Session {
    $tabs = @(Get-SessionTabs | Where-Object { $_.Body.Controls.Count -gt 0 } | ForEach-Object {
        @{ layout = (Get-Layout $_.Body.Controls[0] $_); active = (Get-ActivePane $_).Project.Path }
    })
    $script:Config.session = @{ tabs = $tabs; selected = $strip.SelectedIndex }
}

function Get-ProjectAt($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    $p = $script:AllProjects | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    if ($p) { return $p }
    return [pscustomobject]@{ Name = (Split-Path $path -Leaf); Path = $path; Source = 'Pinned' }   # since removed from the list
}

# Saved tree -> tree of projects, dropping folders that no longer exist ($null if none are left).
function Resolve-Layout($node) {
    if (-not $node) { return $null }
    if ($node.split) {
        $a = Resolve-Layout $node.a
        $b = Resolve-Layout $node.b
        if (-not $a) { return $b }
        if (-not $b) { return $a }
        $ratio = [Math]::Min(0.95, [Math]::Max(0.05, [double]$node.ratio))
        return @{ split = "$($node.split)"; ratio = $ratio; a = $a; b = $b }
    }
    $p = Get-ProjectAt $node.path
    if ($p) { return @{ proj = $p } }
    return $null
}

function Get-FirstLeaf($node) {
    while ($node.split) { $node = $node.a }
    return $node.proj
}

# Grows $pane (already showing the tree's first project) into the tree; returns the tree as actually built.
function Build-Layout($node, $pane) {
    if (-not $node.split) { return $node }
    $new = Split-Pane $pane $node.split (Get-FirstLeaf $node.b)
    if (-not $new) { return (Build-Layout $node.a $pane) }   # that side's console failed to start: leave it out
    $a = Build-Layout $node.a $pane
    $b = Build-Layout $node.b $new
    return @{ split = $node.split; ratio = $node.ratio; a = $a; b = $b }
}

function Set-LayoutRatios($ctl, $node) {
    if (-not $node.split -or -not ($ctl -is [System.Windows.Forms.SplitContainer])) { return }
    $len = if ($ctl.Orientation -eq 'Vertical') { $ctl.Width } else { $ctl.Height }
    try { $ctl.SplitterDistance = [int](($len - $ctl.SplitterWidth) * $node.ratio) } catch { }
    Set-LayoutRatios $ctl.Panel1.Controls[0] $node.a
    Set-LayoutRatios $ctl.Panel2.Controls[0] $node.b
}

function Restore-Session {
    $s = $script:Config.session
    if (-not $chkReopen.Checked -or -not $s -or @($s.tabs).Count -eq 0) { return }
    $script:Restoring = $true
    try {
        foreach ($t in @($s.tabs)) {
            $node = Resolve-Layout $t.layout
            if (-not $node) { continue }
            $lblStatus.Text = "Reopening tabs from last time$Ell"
            $first = Open-InNewTab (Get-FirstLeaf $node)
            if (-not $first) { continue }
            $tab = $first.Tab
            $built = Build-Layout $node $first
            Set-LayoutRatios $tab.Body.Controls[0] $built
            foreach ($p in $tab.Panes) { Fit-Pane $p }
            $active = $tab.Panes | Where-Object { $_.Project.Path -eq $t.active } | Select-Object -First 1
            Set-ActivePane $(if ($active) { $active } else { $first }) $false
        }
    } finally {
        $script:Restoring = $false
    }
    $i = [int]$s.selected
    Select-Tab $(if ($i -gt 0 -and $i -lt $strip.Tabs.Count) { $strip.Tabs[$i].Tag } else { $homeTab })
    Refresh-List   # puts the usual status line back
}

# ---------------------------------------------------------------- window placement
function Restore-WindowPlacement {
    $w = $script:Config.window
    if (-not $w -or [int]$w.w -lt $form.MinimumSize.Width -or [int]$w.h -lt $form.MinimumSize.Height) { return }
    $r = New-Object System.Drawing.Rectangle([int]$w.x, [int]$w.y, [int]$w.w, [int]$w.h)
    # only if enough of the title bar is on a screen that's still connected
    $bar = New-Object System.Drawing.Rectangle($r.X, $r.Y, $r.Width, 40)
    $onScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object {
        $hit = [System.Drawing.Rectangle]::Intersect($_.WorkingArea, $bar)
        $hit.Width -ge 120 -and $hit.Height -ge 20
    }
    if (-not $onScreen) { return }
    $form.StartPosition = 'Manual'
    $form.Bounds = $r
    if ($w.max) { $form.WindowState = 'Maximized'; $script:WasMaximized = $true }
}

function Save-WindowPlacement {
    $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $script:Config.window = @{ x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height; max = [bool]$script:WasMaximized }
}

# ---------------------------------------------------------------- actions
function Pick-Folder($desc) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $desc
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog($form) -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Fill-PickList($lb, $q, $default) {
    $lb.BeginUpdate()
    $lb.Items.Clear()
    foreach ($p in $script:AllProjects) { if (Test-ProjectMatch $p $q.Trim()) { [void]$lb.Items.Add($p) } }
    $lb.EndUpdate()
    if ($lb.Items.Count -eq 0) { return }
    $idx = 0
    if ($default) {
        for ($i = 0; $i -lt $lb.Items.Count; $i++) { if ($lb.Items[$i].Path -eq $default.Path) { $idx = $i; break } }
    }
    $lb.SelectedIndex = $idx
}

# Searchable project chooser; returns the chosen project or $null.
function Pick-Project($caption, $default) {
    $dlg = New-Dialog $caption 520 560
    $search = New-SearchBox "Search projects$Ell" 300
    $search.Dock = 'Top'
    $box = $search.Tag
    $gap = New-Object System.Windows.Forms.Panel
    $gap.Dock = 'Top'; $gap.Height = 10

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Dock = 'Fill'; $lb.BorderStyle = 'None'; $lb.IntegralHeight = $false
    $lb.DrawMode = 'OwnerDrawFixed'; $lb.ItemHeight = 44
    $lb.BackColor = [Palette]::Bg; $lb.ForeColor = [Palette]::Text
    $lb.Add_DrawItem({ param($s, $e) Draw-ProjectItem $e $s.Items })

    $bar = New-DialogBar
    $bOk = New-Btn 'Open' -Primary
    $bOk.DialogResult = 'OK'; $bOk.Margin = '0,0,0,0'
    $bCancel = New-Btn 'Cancel'
    $bCancel.DialogResult = 'Cancel'
    $bar.Controls.AddRange(@($bOk, $bCancel))

    $dlg.Controls.AddRange(@((New-BorderFrame $lb), $gap, $search, $bar))
    $dlg.AcceptButton = $bOk
    $dlg.CancelButton = $bCancel

    Fill-PickList $lb '' $default
    $box.Add_TextChanged({ Fill-PickList $lb $box.Text $null })
    $box.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Down' -and $lb.SelectedIndex -lt $lb.Items.Count - 1) { $lb.SelectedIndex = $lb.SelectedIndex + 1; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Up' -and $lb.SelectedIndex -gt 0) { $lb.SelectedIndex = $lb.SelectedIndex - 1; $e.Handled = $true }
    })
    $lb.Add_DoubleClick({ if ($lb.SelectedItem) { $dlg.DialogResult = 'OK' } })
    $dlg.Add_Shown({ [void]$box.Focus() })

    $result = $null
    if ($dlg.ShowDialog($form) -eq 'OK') { $result = $lb.SelectedItem }
    $dlg.Dispose()
    return $result
}

function Add-Project {
    $p = Pick-Folder 'Select a project folder'
    if (-not $p) { return }
    if ($script:Config.projects -notcontains $p) { $script:Config.projects = @($script:Config.projects) + $p }
    $script:Config.hidden = @($script:Config.hidden | Where-Object { $_ -ne $p })
    Save-Config; Reload-Projects
}

function Remove-Selected {
    $sel = @($lv.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $names = ($sel | ForEach-Object { $_.Tag.Name }) -join ', '
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Remove from the list?`n`n$names`n`n(Folders on disk are not touched. Projects found through a root folder can be brought back under Root folders.)",
        'Remove', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    foreach ($it in $sel) {
        $p = $it.Tag
        if ($p.Source -eq 'Pinned') {
            $script:Config.projects = @($script:Config.projects | Where-Object { $_ -ne $p.Path })
        } else {
            $script:Config.hidden = @($script:Config.hidden) + $p.Path
        }
    }
    Save-Config; Reload-Projects
}

function Show-RootsDialog {
    $dlg = New-Dialog 'Root folders' 600 580

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = 'Top'; $lbl.Height = 28
    $lbl.Text = 'Every subfolder of these folders shows up as a project.'
    $lbl.ForeColor = [Palette]::Muted

    $drawPath = {
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $e.Graphics.FillRectangle($(if ($sel) { $script:Brush.Selection } else { $script:Brush.Bg }), $e.Bounds)
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 16), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $script:UiFont, $r, [Palette]::Text, $script:CellFormat)
    }
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Dock = 'Fill'; $lb.BorderStyle = 'None'; $lb.IntegralHeight = $false
    $lb.DrawMode = 'OwnerDrawFixed'; $lb.ItemHeight = 32
    $lb.BackColor = [Palette]::Bg; $lb.ForeColor = [Palette]::Text
    $lb.Add_DrawItem($drawPath)
    foreach ($r in $script:Config.roots) { [void]$lb.Items.Add($r) }

    # projects hidden with "Remove", which can be brought back from here
    $hidPanel = New-Object System.Windows.Forms.Panel
    $hidPanel.Dock = 'Bottom'; $hidPanel.Height = 200; $hidPanel.Padding = '0,16,0,0'
    $hidLbl = New-Object System.Windows.Forms.Label
    $hidLbl.Dock = 'Top'; $hidLbl.Height = 28; $hidLbl.ForeColor = [Palette]::Muted
    $hid = New-Object System.Windows.Forms.ListBox
    $hid.Dock = 'Fill'; $hid.BorderStyle = 'None'; $hid.IntegralHeight = $false
    $hid.DrawMode = 'OwnerDrawFixed'; $hid.ItemHeight = 32
    $hid.BackColor = [Palette]::Bg; $hid.ForeColor = [Palette]::Text
    $hid.Add_DrawItem($drawPath)
    foreach ($h in $script:Config.hidden) { [void]$hid.Items.Add([string]$h) }
    $hidBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $hidBar.Dock = 'Bottom'; $hidBar.Height = 44; $hidBar.Padding = '0,8,0,0'
    $hidBar.FlowDirection = 'RightToLeft'; $hidBar.WrapContents = $false
    $bShow = New-Btn 'Show again'
    $bShow.Margin = '0,0,0,0'
    $script:Tip.SetToolTip($bShow, 'Put the selected project back in the list')
    $hidBar.Controls.Add($bShow)
    $setHidLabel = {
        $hidLbl.Text = if ($hid.Items.Count -gt 0) { "Hidden projects ($($hid.Items.Count)) - removed from the list, but still in a root folder." }
                       else { 'Hidden projects: none. Projects you remove from the list show up here.' }
        $bShow.Enabled = $hid.Items.Count -gt 0
    }
    & $setHidLabel
    $bShow.Add_Click({
        if ($hid.SelectedItem) { $hid.Items.Remove($hid.SelectedItem) }
        elseif ($hid.Items.Count -gt 0) { $hid.Items.RemoveAt(0) }
        & $setHidLabel
    })
    $hid.Add_DoubleClick({ if ($hid.SelectedItem) { $hid.Items.Remove($hid.SelectedItem); & $setHidLabel } })
    $hidPanel.Controls.AddRange(@((New-BorderFrame $hid), $hidLbl, $hidBar))

    $bar = New-DialogBar
    $bOk = New-Btn 'Save' -Primary
    $bOk.DialogResult = 'OK'; $bOk.Margin = '0,0,0,0'
    $bCancel = New-Btn 'Cancel'
    $bCancel.DialogResult = 'Cancel'; $bCancel.Margin = '0,0,24,0'
    $bDel = New-Btn 'Remove'
    $bDel.Add_Click({ if ($lb.SelectedItem) { $lb.Items.Remove($lb.SelectedItem) } })
    $bAdd = New-Btn "Add folder$Ell"
    $bAdd.Add_Click({
        $p = Pick-Folder 'Select a root folder (e.g. C:\work)'
        if ($p -and -not $lb.Items.Contains($p)) { [void]$lb.Items.Add($p) }
    })
    $bar.Controls.AddRange(@($bOk, $bCancel, $bDel, $bAdd))

    $dlg.Controls.AddRange(@((New-BorderFrame $lb), $lbl, $hidPanel, $bar))
    $dlg.AcceptButton = $bOk
    $dlg.CancelButton = $bCancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:Config.roots  = @($lb.Items | ForEach-Object { [string]$_ })
        $script:Config.hidden = @($hid.Items | ForEach-Object { [string]$_ })
        Save-Config; Reload-Projects
    }
    $dlg.Dispose()
}

# ---------------------------------------------------------------- UI
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Agent Tabs'
$form.Size = New-Object System.Drawing.Size(1280, 800)
$form.MinimumSize = New-Object System.Drawing.Size(720, 440)
$form.StartPosition = 'CenterScreen'
$form.Font = $script:UiFont
$form.BackColor = [Palette]::Bg
$form.ForeColor = [Palette]::Text
$form.KeyPreview = $true
$form.Icon = [System.Drawing.Icon]::FromHandle(([Glyphs]::AppIcon(32)).GetHicon())
$form.Add_HandleCreated({ [UiNative]::GlassTitleBar($this.Handle, [Palette]::StripBg) })
# remembered across a minimize, so closing from the taskbar keeps a maximized window maximized
$form.Add_Resize({ if ($this.WindowState -ne 'Minimized') { $script:WasMaximized = ($this.WindowState -eq 'Maximized') } })

# tab strip: "Projects" home tab + one tab per workspace of embedded sessions
$strip = New-Object TabStripControl
$strip.Dock = 'Top'; $strip.Height = 46; $strip.Font = $script:UiFont

$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = [Palette]::Bg

$homePanel = New-Object System.Windows.Forms.Panel
$homePanel.Dock = 'Fill'; $homePanel.Padding = '20,10,20,8'; $homePanel.BackColor = [Palette]::Bg

# header: title, subtitle, search
$hdr = New-Object System.Windows.Forms.Panel
$hdr.Size = New-Object System.Drawing.Size(1000, 70)   # laid out at this width so the search box anchors right
$logo = New-Object System.Windows.Forms.PictureBox
$logo.Size = New-Object System.Drawing.Size(28, 28)
$logo.Location = New-Object System.Drawing.Point(0, 8)
$logo.Image = [Glyphs]::AppIcon(28)
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Projects'; $lblTitle.Font = $script:TitleFont; $lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(34, 4); $lblTitle.ForeColor = [Palette]::Text
$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'Open Claude Code in a project, or select several and work on them side by side.'
$lblSub.AutoSize = $true; $lblSub.Location = New-Object System.Drawing.Point(0, 44); $lblSub.ForeColor = [Palette]::Muted
$searchWrap = New-SearchBox "Search projects$Ell" 340
$searchWrap.Location = New-Object System.Drawing.Point(660, 8)
$searchWrap.Anchor = 'Top, Right'
$txtSearch = $searchWrap.Tag
$hdr.Controls.AddRange(@($logo, $lblTitle, $lblSub, $searchWrap))
$hdr.Dock = 'Top'

# toolbar
$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Top'; $toolbar.Height = 48; $toolbar.Padding = '0,4,0,8'; $toolbar.WrapContents = $false

$btnOpen    = New-Btn 'Open' -Primary
$btnSide    = New-Btn 'Open side by side'
$btnAdd     = New-Btn "Add project$Ell"
$btnRoots   = New-Btn "Root folders$Ell"
$btnRemove  = New-Btn 'Remove'
$btnRefresh = New-Btn 'Refresh'
$btnAdd.Margin = '20,0,8,0'
$btnSide.Enabled = $false
$script:Tip.SetToolTip($btnOpen, 'Open each selected project in its own tab (Enter)')
$script:Tip.SetToolTip($btnSide, 'Open the selected projects together in one split tab (Ctrl+Enter)')
$script:Tip.SetToolTip($btnAdd, 'Pin a single project folder')
$script:Tip.SetToolTip($btnRoots, 'Folders whose subfolders are listed as projects; also brings back hidden projects')
$script:Tip.SetToolTip($btnRemove, 'Remove the selected projects from the list (Del)')
$script:Tip.SetToolTip($btnRefresh, 'Rescan root folders (F5)')
$toolbar.Controls.AddRange(@($btnOpen, $btnSide, $btnAdd, $btnRoots, $btnRemove, $btnRefresh))

# project list (owner-drawn for the dark theme)
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.MultiSelect = $true
$lv.HideSelection = $false
$lv.OwnerDraw = $true
$lv.BorderStyle = 'None'
$lv.HeaderStyle = 'Nonclickable'
$lv.BackColor = [Palette]::Bg
$lv.ForeColor = [Palette]::Text
$lv.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic, Instance').SetValue($lv, $true, $null)
$rowHeight = New-Object System.Windows.Forms.ImageList   # only sets the row height
$rowHeight.ImageSize = New-Object System.Drawing.Size(1, 32)
$lv.SmallImageList = $rowHeight
[void]$lv.Columns.Add('Project', 240)
[void]$lv.Columns.Add('Path', 500)
[void]$lv.Columns.Add('Source', 150)

function Fit-Columns {
    $w = $lv.ClientSize.Width - $lv.Columns[0].Width - $lv.Columns[2].Width - 1
    $lv.Columns[1].Width = [Math]::Max(120, $w)
}

$lv.Add_DrawColumnHeader({
    param($s, $e)
    $b = $e.Bounds
    $e.Graphics.FillRectangle($script:Brush.Surface, $b)
    $pad = if ($e.ColumnIndex -eq 0) { 30 } else { 12 }   # line up with the names, which leave room for the status dot
    $r = New-Object System.Drawing.Rectangle(($b.X + $pad), $b.Y, ($b.Width - $pad - 4), $b.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text.ToUpper(), $script:CapsFont, $r, [Palette]::Muted, $script:CellFormat)
    $e.Graphics.DrawLine($script:BorderPen, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
})
$lv.Add_DrawSubItem({
    param($s, $e)
    $b = $e.Bounds
    $brush = if ($e.Item.Selected) { if ($lv.Focused) { $script:Brush.Selection } else { $script:Brush.SelectionDim } }
             elseif ($e.ItemIndex -eq $script:HotRow) { $script:Brush.Raised }
             else { $script:Brush.Bg }
    $e.Graphics.FillRectangle($brush, $b)
    $pad = 12
    if ($e.ColumnIndex -eq 0) {
        if ($e.Item.Selected) { $e.Graphics.FillRectangle($script:Brush.Accent, $b.X, $b.Y, 3, $b.Height) }
        if ($script:OpenPaths.ContainsKey($e.Item.Tag.Path)) {
            $e.Graphics.SmoothingMode = 'AntiAlias'
            $e.Graphics.FillEllipse($script:Brush.Running, ($b.X + 13), ($b.Y + ($b.Height - 8) / 2), 8, 8)
            $e.Graphics.SmoothingMode = 'None'
        }
        $pad = 30
    }
    $font  = if ($e.ColumnIndex -eq 0) { $script:BoldFont } else { $script:UiFont }
    $color = if ($e.ColumnIndex -eq 0) { [Palette]::Text } else { [Palette]::Muted }
    $r = New-Object System.Drawing.Rectangle(($b.X + $pad), $b.Y, ($b.Width - $pad - 4), $b.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $font, $r, $color, $script:CellFormat)
    if ($e.ItemIndex -eq $script:RecentEnd) { $e.Graphics.DrawLine($script:BorderPen, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1) }
})
# hover highlight
$script:HotRow = -1
function Set-HotRow($i) {
    $old = $script:HotRow
    $script:HotRow = $i
    foreach ($k in @($old, $i)) {
        if ($k -ge 0 -and $k -lt $lv.Items.Count) { $lv.Invalidate($lv.Items[$k].Bounds) }
    }
}
$lv.Add_MouseMove({
    param($s, $e)
    $it = $lv.GetItemAt(4, $e.Y)
    $i = if ($it) { $it.Index } else { -1 }
    if ($i -ne $script:HotRow) { Set-HotRow $i }
})
$lv.Add_MouseLeave({ Set-HotRow -1 })
$lv.Add_GotFocus({ $lv.Invalidate() })
$lv.Add_LostFocus({ $lv.Invalidate() })
$lv.Add_ClientSizeChanged({ Fit-Columns })
$lv.Add_SelectedIndexChanged({ $btnSide.Enabled = (@($lv.SelectedItems).Count -ge 2) })

# footer: status + options
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'; $footer.Height = 38

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'; $lblStatus.TextAlign = 'MiddleLeft'; $lblStatus.AutoEllipsis = $true
$lblStatus.ForeColor = [Palette]::Muted

$opts = New-Object System.Windows.Forms.FlowLayoutPanel
$opts.Dock = 'Right'; $opts.AutoSize = $true; $opts.WrapContents = $false; $opts.Padding = '0,8,0,0'
$chkReopen   = New-Check 'Reopen tabs' ([bool]$script:Config.reopen)
$script:Tip.SetToolTip($chkReopen, 'Reopen the tabs and split layout you had open when the launcher was last closed')
$chkContinue = New-Check 'Resume last chat' ([bool]$script:Config.continue)
$script:Tip.SetToolTip($chkContinue, 'Continue the most recent conversation in each project (claude --continue)')
$chkRemote   = New-Check 'Remote Control' ([bool]$script:Config.remote)
$chkExternal = New-Check 'External terminal' ([bool]$script:Config.external)
$script:Tip.SetToolTip($chkExternal, 'Open projects in Windows Terminal instead of inside the launcher')
$chkGlass    = New-Check 'Glass window' ([bool]$script:Config.glass)
$script:Tip.SetToolTip($chkGlass, 'Make the whole window slightly see-through (consoles included)')
$script:Tip.SetToolTip($chkRemote, 'Start every session with Remote Control on (claude --remote-control <project>)')
$opts.Controls.AddRange(@($chkReopen, $chkContinue, $chkRemote, $chkExternal, $chkGlass))

$footer.Controls.Add($lblStatus)
$footer.Controls.Add($opts)

$listFrame = New-BorderFrame $lv
$listFrame.BackColor = [System.Drawing.Color]::FromArgb(56, 70, 100)   # lighter glass edge around the list
$homePanel.Controls.AddRange(@($listFrame, $toolbar, $hdr, $footer))

# Glass look: the home screen paints the glow backdrop and its chrome is transparent, so the glow
# shows through behind the title, buttons and switches.
function Enable-DoubleBuffer($c) {
    $c.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic, Instance').SetValue($c, $true, $null)
}
$homePanel.Add_Paint({ param($s, $e) [Glyphs]::Backdrop($e.Graphics, $s.ClientRectangle) })
$homePanel.Add_Resize({ $this.Invalidate($true) })
foreach ($c in @($homePanel, $hdr, $toolbar, $footer, $opts)) { Enable-DoubleBuffer $c }
foreach ($c in @($hdr, $toolbar, $footer, $opts, $logo, $lblTitle, $lblSub, $lblStatus)) { $c.BackColor = [System.Drawing.Color]::Transparent }

$homeTab = [pscustomobject]@{
    IsHome = $true; Body = $homePanel; Active = $null
    Panes  = (New-Object System.Collections.Generic.List[object])
    Strip  = (New-Object StripTab)
}
$homeTab.Strip.Text = 'Projects'; $homeTab.Strip.Closable = $false; $homeTab.Strip.ToolTip = 'All projects'
$homeTab.Strip.Home = $true
$homeTab.Strip.Tag = $homeTab
$strip.Tabs.Add($homeTab.Strip)
$script:LastTab = $null

$content.Controls.Add($homePanel)
$form.Controls.Add($content)
$form.Controls.Add($strip)

# right-click menu on the project list
$menu = New-Menu
$miOpen     = $menu.Items.Add('Open')
$miSide     = $menu.Items.Add('Open side by side')
[void]$menu.Items.Add('-')
$miSplitR   = $menu.Items.Add('Split right')
$miSplitD   = $menu.Items.Add('Split down')
[void]$menu.Items.Add('-')
$miExplorer = $menu.Items.Add('Open folder in Explorer')
$miRemove   = $menu.Items.Add('Remove from list')
$miOpen.Font = $script:BoldFont
$miOpen.Add_Click({ Open-Selected })
$miSide.Add_Click({ Open-SideBySide })
$miSplitR.Add_Click({ Split-FromList 'Vertical' })
$miSplitD.Add_Click({ Split-FromList 'Horizontal' })
$miExplorer.Add_Click({ foreach ($it in @($lv.SelectedItems)) { Start-Process explorer.exe -ArgumentList "`"$($it.Tag.Path)`"" } })
$miRemove.Add_Click({ Remove-Selected })
$menu.Add_Opening({
    $miSide.Enabled = (@($lv.SelectedItems).Count -ge 2)
    $t = $script:LastTab
    $ok = $t -and $strip.Tabs.Contains($t.Strip)
    $miSplitR.Enabled = $ok; $miSplitD.Enabled = $ok
    $into = if ($ok) { " into `"$($t.Panes[0].Project.Name)`" tab" } else { ' (open a project first)' }
    $miSplitR.Text = "Split right$into"
    $miSplitD.Text = "Split down$into"
})
$lv.ContextMenuStrip = $menu

# pane menu: the header's "more" button and right-click on a pane header
$paneMenu = New-Menu
$miPaneSplitR = $paneMenu.Items.Add("Split right$Ell")
$miPaneSplitD = $paneMenu.Items.Add("Split down$Ell")
[void]$paneMenu.Items.Add('-')
$miPanePop    = $paneMenu.Items.Add('Pop out to new tab')
$miPaneMove   = New-MenuItem 'Move into tab' $null
[void]$paneMenu.Items.Add($miPaneMove)
[void]$paneMenu.Items.Add('-')
$miPaneFolder = $paneMenu.Items.Add('Open folder in Explorer')
$miPaneClose  = $paneMenu.Items.Add('Close pane')
$miPaneSplitR.Add_Click({ Split-Interactive $script:MenuPane 'Vertical' })
$miPaneSplitD.Add_Click({ Split-Interactive $script:MenuPane 'Horizontal' })
$miPanePop.Add_Click({ Pop-OutPane $script:MenuPane })
$miPaneFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:MenuPane.Project.Path)`"" })
$miPaneClose.Add_Click({ Close-Pane $script:MenuPane })
$paneMenu.Add_Opening({
    $script:MenuPane = $paneMenu.SourceControl.Tag
    $miPanePop.Enabled = ($script:MenuPane.Tab.Panes.Count -gt 1)
    Fill-MoveTargets $miPaneMove 'pane' $script:MenuPane $script:MenuPane.Tab
})

# right-click menu on a session tab (acts on that tab's active pane)
$tabMenu = New-Menu
$miTabSplitR = $tabMenu.Items.Add("Split right$Ell")
$miTabSplitD = $tabMenu.Items.Add("Split down$Ell")
$miTabEven   = $tabMenu.Items.Add('Equalize pane sizes')
[void]$tabMenu.Items.Add('-')
$miTabPop    = $tabMenu.Items.Add('Pop out active pane to new tab')
$miTabMerge  = New-MenuItem 'Add to split group' $null
[void]$tabMenu.Items.Add($miTabMerge)
[void]$tabMenu.Items.Add('-')
$miTabFolder = $tabMenu.Items.Add('Open folder in Explorer')
$miTabClose  = $tabMenu.Items.Add('Close tab')
$miTabSplitR.Add_Click({ Split-Interactive (Get-ActivePane $script:MenuTab) 'Vertical' })
$miTabSplitD.Add_Click({ Split-Interactive (Get-ActivePane $script:MenuTab) 'Horizontal' })
$miTabEven.Add_Click({ Even-Panes $script:MenuTab })
$miTabFolder.Add_Click({
    $p = Get-ActivePane $script:MenuTab
    if ($p) { Start-Process explorer.exe -ArgumentList "`"$($p.Project.Path)`"" }
})
$miTabClose.Add_Click({ Close-Tab $script:MenuTab })
$miTabPop.Add_Click({ Pop-OutPane (Get-ActivePane $script:MenuTab) })
$tabMenu.Add_Opening({
    $miTabEven.Enabled = ($script:MenuTab.Panes.Count -gt 1)
    $miTabPop.Enabled  = ($script:MenuTab.Panes.Count -gt 1)
    Fill-MoveTargets $miTabMerge 'tab' $script:MenuTab $script:MenuTab
})

$strip.add_TabSelected({ param($s, $e) Select-Tab $strip.Tabs[$e.Index].Tag })
$strip.add_TabCloseRequested({ param($s, $e) Close-Tab $strip.Tabs[$e.Index].Tag })
$strip.add_TabContextMenu({
    param($s, $e)
    $script:MenuTab = $strip.Tabs[$e.Index].Tag
    if (-not $script:MenuTab.IsHome) { $tabMenu.Show($strip, $e.Location) }
})
# "all tabs" list at the right end of the strip
$tabList = New-Menu
$strip.add_ListClicked({
    param($s, $e)
    while ($tabList.Items.Count -gt 0) { $tabList.Items[0].Dispose() }
    for ($i = 0; $i -lt $strip.Tabs.Count; $i++) {
        $mi = $tabList.Items.Add($strip.Tabs[$i].Text)
        $mi.Tag = $strip.Tabs[$i].Tag
        if ($i -lt 8) { $mi.ShortcutKeyDisplayString = "Ctrl+$($i + 1)" }
        elseif ($i -eq $strip.Tabs.Count - 1) { $mi.ShortcutKeyDisplayString = 'Ctrl+9' }
        if ($i -eq $strip.SelectedIndex) { $mi.Font = $script:BoldFont }
        $mi.Add_Click({ Select-Tab $this.Tag })
    }
    $tabList.Show($strip, $e.Location, [System.Windows.Forms.ToolStripDropDownDirection]::BelowLeft)
})
$strip.add_AddClicked({
    $p = Pick-Project 'Open in new tab' $null
    if ($p) { [void](Open-InNewTab $p) }
})
$form.Add_Activated({
    $t = Get-SelectedTab
    if (-not $t.IsHome) { Focus-Pane (Get-ActivePane $t) }
})

$sessionTimer = New-Object System.Windows.Forms.Timer
$sessionTimer.Interval = 250
$sessionTimer.Add_Tick({ Update-Sessions })
$sessionTimer.Start()
$dockTimer = New-Object System.Windows.Forms.Timer   # runs only while a console is starting
$dockTimer.Interval = 50
$dockTimer.Add_Tick({ Update-PendingConsoles })

# events
$btnOpen.Add_Click({ Open-Selected })
$btnSide.Add_Click({ Open-SideBySide })
$btnAdd.Add_Click({ Add-Project })
$btnRoots.Add_Click({ Show-RootsDialog })
$btnRemove.Add_Click({ Remove-Selected })
$btnRefresh.Add_Click({ Reload-Projects })
$chkReopen.Add_CheckedChanged({ Save-Config })
$chkContinue.Add_CheckedChanged({ Save-Config })
$chkRemote.Add_CheckedChanged({ Save-Config })
$chkExternal.Add_CheckedChanged({ Save-Config })
$GlassOpacity = 0.94   # lower = more see-through (consoles too)
function Set-GlassWindow { $form.Opacity = if ($chkGlass.Checked) { $GlassOpacity } else { 1.0 } }
$chkGlass.Add_CheckedChanged({ Set-GlassWindow; Save-Config })
Set-GlassWindow
$lv.Add_DoubleClick({ Open-Selected })
$txtSearch.Add_TextChanged({ Refresh-List })

$form.Add_KeyDown({
    param($s, $e)
    # These only arrive while focus is in the launcher itself (not inside a console).
    $tab = Get-SelectedTab
    if ($e.Control -and $e.KeyCode -eq 'W') { Close-Pane (Get-ActivePane $tab); $e.SuppressKeyPress = $true; return }
    if ($e.Control -and $e.KeyCode -eq 'T') {
        $e.SuppressKeyPress = $true
        $p = Pick-Project 'Open in new tab' $null
        if ($p) { [void](Open-InNewTab $p) }
        return
    }
    if (-not $tab.IsHome) { return }
    switch ($e.KeyCode) {
        'Enter'  { if ($e.Control) { Open-SideBySide } else { Open-Selected }; $e.SuppressKeyPress = $true }
        'Escape' { $txtSearch.Clear(); [void]$txtSearch.Focus() }
        'Delete' { if ($lv.Focused) { Remove-Selected } }
        'F5'     { Reload-Projects }
        'Down'   { if ($txtSearch.Focused -and $lv.Items.Count -gt 0) { [void]$lv.Focus(); $e.SuppressKeyPress = $true } }
    }
})

$form.Add_Shown({
    $script:Clicks = New-Object ClickWatcher($form)
    $script:Clicks.add_Clicked({ param($s, $e) Activate-PaneAt $e.Hwnd })
    $script:Keys = New-Object KeyWatcher($form)
    $script:Keys.add_Command({ param($s, $e) Invoke-TabCommand $e.Name })
    Reload-Projects
    Fit-Columns
    Select-Tab $homeTab
    if (-not $script:HasWT -and $chkExternal.Checked) {
        $lblStatus.Text = 'Windows Terminal (wt.exe) not found - projects will open in separate cmd windows.'
    }
    if ($script:ConfigWarning) { $lblStatus.Text = $script:ConfigWarning }
    Start-TypeCacheWarmer
    # reopen last time's tabs once the window has painted
    $restoreTimer = New-Object System.Windows.Forms.Timer
    $restoreTimer.Interval = 150
    $restoreTimer.Add_Tick({
        $this.Stop(); $this.Dispose()
        Restore-Session
        if ($script:ConfigWarning) { $lblStatus.Text = $script:ConfigWarning }
    })
    $restoreTimer.Start()
})

$form.Add_FormClosing({
    param($s, $e)
    $open = @(Get-AllPanes)
    if ($open.Count -gt 0) {
        $msg = "Close $($open.Count) open Claude session(s)?"
        if ($chkReopen.Checked) { $msg += "`n`nYour tabs will reopen the next time you start the launcher." }
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Agent Tabs', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { $e.Cancel = $true; return }
    }
    Save-Session
    Save-WindowPlacement
    try { Save-Config } catch { }   # never block closing
    if ($open.Count -eq 0) { return }
    $sessionTimer.Stop()
    foreach ($p in $open) { Close-Pane $p }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline -and @($open | Where-Object { -not $_.Proc.HasExited }).Count -gt 0) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    foreach ($p in $open) {
        if (-not $p.Proc.HasExited) { & taskkill.exe /T /F /PID $p.Proc.Id 2>&1 | Out-Null }
    }
})

$form.Add_FormClosed({
    if ($script:Clicks) { $script:Clicks.Dispose() }
    if ($script:Keys) { $script:Keys.Dispose() }
})

Restore-WindowPlacement
[void]$form.ShowDialog()
