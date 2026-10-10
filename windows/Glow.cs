using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

namespace NotifyFlash;

enum GlowStyle { Soft, Breath, Orbit, Corner }

sealed class Glow : Form
{
    // Why: Same values as macos/Glow.swift (design mock; lengths in points); not calibrated on Windows hardware.
    internal const double GlowOpacity = 0.8;
    long generation;
    System.Windows.Forms.Timer? timer;
    IntPtr memoryDc, dib, previousBitmap, bits;

    // Static per-pixel intensity of the edge band, computed once per flash so each frame only scales it.
    sealed record Plan(GlowStyle Style, int[] Index, float[] Base, float[] Param);

    internal Glow()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        TopMost = true;
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x80000 | 0x20 | 0x8 | 0x8000000 | 0x80;
            return parameters;
        }
    }

    protected override void WndProc(ref Message m)
    {
        // Why: UpdateLayeredWindow sets the geometry every frame; WinForms rescaling on WM_DPICHANGED would resize the surface.
        if (m.Msg == 0x02E0) return;
        base.WndProc(ref m);
    }

    internal static Color? ParseHex(string? value)
    {
        if (value == null || value.Length != 7 || value[0] != '#' ||
            !value.AsSpan(1).ToArray().All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F')) return null;
        var rgb = int.Parse(value.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return Color.FromArgb((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
    }

    internal static GlowStyle ParseStyle(string? name) => name switch
    {
        "breath" => GlowStyle.Breath,
        "orbit" => GlowStyle.Orbit,
        "corner" => GlowStyle.Corner,
        _ => GlowStyle.Soft
    };

    internal static double Cycle(GlowStyle style) => style switch
    {
        GlowStyle.Breath or GlowStyle.Orbit => 1.6,
        GlowStyle.Corner => 1.5,
        _ => 0.9
    };

    internal static int FlashCount(int count, bool reduceMotion) => reduceMotion ? 1 : Math.Max(0, count);
    internal static double Duration(GlowStyle style, int count) => Cycle(style) * count;

    // ponytail: smoothstep stands in for Core Animation's easeInEaseOut bezier; swap in the exact curve if the difference is visible.
    static double Smooth(double x) => x * x * (3 - 2 * x);

    // One pulse per cycle: opacity rises from 0 to peak at `rise`, then falls back to 0 (macos pulse()).
    internal static double Pulse(double phase, double rise, double peak) =>
        phase < rise ? peak * Smooth(phase / rise) : peak * Smooth((1 - phase) / (1 - rise));

    internal static (double Gain, double Param) FrameAt(GlowStyle style, double t, int count)
    {
        var cycle = Cycle(style);
        var phase = t / cycle % 1;
        switch (style)
        {
            case GlowStyle.Soft: return (Pulse(phase, 1.0 / 3, 1), 0);
            case GlowStyle.Breath: return (Pulse(phase, 0.5, 0.85), 0);
            case GlowStyle.Orbit:
                var u = t / (cycle * count);
                return (u < 0.1 ? u / 0.1 : u < 0.8 ? 1 : (1 - u) / 0.2, 2 * Math.PI * phase);
            default:
                var spread = phase < 0.6 ? 0.01 + 0.99 * (1 - Math.Pow(1 - phase / 0.6, 2)) : 1;
                return (phase < 0.6 ? 1 : (1 - phase) / 0.4, spread);
        }
    }

    // Conic colors [c, clear, clear, c, clear, clear, c] at [0, .2, .3, .5, .7, .8, 1] (macos orbit).
    internal static double Lobe(double u) =>
        u < 0.2 ? 1 - u / 0.2 : u < 0.3 ? 0 : u < 0.5 ? (u - 0.3) / 0.2 : u < 0.7 ? 1 - (u - 0.5) / 0.2 : u < 0.8 ? 0 : (u - 0.8) / 0.2;

    // Radial mask: opaque to 75% of the radius, fading to clear at the radius (macos corner).
    internal static double Radial(double r) => r < 0.75 ? 1 : r < 1 ? (1 - r) / 0.25 : 0;

    static double Erfc(double x)
    {
        var t = 1 / (1 + 0.3275911 * x);
        return t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * Math.Exp(-x * x);
    }

    // Why: A Core Animation shadow blurs with sigma about radius / 2; a ring just outside the screen bleeds inward like a blurred half-plane.
    internal static double ShadowEdge(double distance, double radius) => 0.5 * Erfc(distance / (radius / 2 * Math.Sqrt(2)));
    static double Ramp(double distance, double depth) => Math.Max(0, 1 - distance / depth);
    internal static double Soft(double inner40, double inner8) => 1 - (1 - GlowOpacity * inner40) * (1 - GlowOpacity * inner8);

    static Plan BuildPlan(GlowStyle style, Size size, double scale)
    {
        int w = size.Width, h = size.Height;
        var depth = (int)Math.Ceiling(scale * style switch { GlowStyle.Breath => 160, GlowStyle.Orbit => 36, _ => 64 });
        depth = Math.Max(1, Math.Min(depth, Math.Max(w, h)));
        var near = new double[depth];
        var far = new double[depth];
        for (int d = 0; d < depth; d++)
        {
            var center = d + 0.5;
            (near[d], far[d]) = style switch
            {
                GlowStyle.Breath => (GlowOpacity * Ramp(center, 160 * scale), 0),
                GlowStyle.Orbit => (Ramp(center, 36 * scale), 0),
                _ => (ShadowEdge(center, 40 * scale), ShadowEdge(center, 8 * scale))
            };
        }
        double At(double[] table, int d) => d < depth ? table[d] : 0;
        double Union(double[] table, int x, int y) =>
            1 - (1 - At(table, x)) * (1 - At(table, y)) * (1 - At(table, w - 1 - x)) * (1 - At(table, h - 1 - y));

        var count = w * h - Math.Max(0, w - 2 * depth) * Math.Max(0, h - 2 * depth);
        var index = new int[count];
        var bases = new float[count];
        var param = new float[style is GlowStyle.Orbit or GlowStyle.Corner ? count : 0];
        var diagonal = Math.Sqrt((double)w * w + (double)h * h);
        int i = 0;
        void Add(int x, int y)
        {
            index[i] = y * w + x;
            bases[i] = (float)(style switch
            {
                GlowStyle.Breath => Union(near, x, y),
                GlowStyle.Orbit => GlowOpacity * Union(near, x, y),
                _ => Soft(Union(near, x, y), Union(far, x, y))
            });
            if (style == GlowStyle.Orbit) param[i] = (float)Math.Atan2(y + 0.5 - h / 2.0, x + 0.5 - w / 2.0);
            // Why: macOS spreads from the top-right where its banners appear; Windows toasts appear bottom-right, so the corner moves there.
            else if (style == GlowStyle.Corner) param[i] = (float)(Math.Sqrt(Math.Pow(w - x - 0.5, 2) + Math.Pow(h - y - 0.5, 2)) / diagonal);
            i++;
        }
        for (int y = 0; y < h; y++)
        {
            if (y < depth || y >= h - depth)
                for (int x = 0; x < w; x++) Add(x, y);
            else
            {
                for (int x = 0; x < Math.Min(depth, w); x++) Add(x, y);
                for (int x = Math.Max(depth, w - depth); x < w; x++) Add(x, y);
            }
        }
        return new Plan(style, index, bases, param);
    }

    static uint[] Lut(Color color)
    {
        var lut = new uint[256];
        for (uint a = 0; a < 256; a++)
            lut[a] = a << 24 | color.R * a / 255 << 16 | color.G * a / 255 << 8 | color.B * a / 255;
        return lut;
    }

    unsafe void Render(Plan plan, uint[] lut, double gain, double param)
    {
        var pixels = (uint*)bits;
        var index = plan.Index;
        var bases = plan.Base;
        var values = plan.Param;
        for (int i = 0; i < index.Length; i++)
        {
            var a = bases[i] * gain;
            if (plan.Style == GlowStyle.Orbit)
            {
                var u = (values[i] - param) / (2 * Math.PI);
                a *= Lobe(u - Math.Floor(u));
            }
            else if (plan.Style == GlowStyle.Corner) a *= Radial(values[i] / param);
            pixels[index[i]] = lut[Math.Clamp((int)(a * 255 + 0.5), 0, 255)];
        }
    }

    void CreateSurface(Size size)
    {
        var header = new BitmapInfoHeader
        {
            Size = Marshal.SizeOf<BitmapInfoHeader>(), Width = size.Width, Height = -size.Height, Planes = 1, BitCount = 32
        };
        memoryDc = CreateCompatibleDC(IntPtr.Zero);
        dib = CreateDIBSection(memoryDc, ref header, 0, out bits, IntPtr.Zero, 0);
        previousBitmap = SelectObject(memoryDc, dib);
    }

    void FreeSurface()
    {
        if (memoryDc == IntPtr.Zero) return;
        SelectObject(memoryDc, previousBitmap);
        DeleteObject(dib);
        DeleteDC(memoryDc);
        memoryDc = dib = previousBitmap = bits = IntPtr.Zero;
    }

    void Present(Rectangle bounds)
    {
        var screen = GetDC(IntPtr.Zero);
        var position = new NativePoint { X = bounds.X, Y = bounds.Y };
        var size = new NativeSize { Width = bounds.Width, Height = bounds.Height };
        var source = new NativePoint();
        var blend = new BlendFunction { SourceConstantAlpha = 255, AlphaFormat = 1 };
        UpdateLayeredWindow(Handle, screen, ref position, ref size, memoryDc, ref source, 0, ref blend, 2);
        ReleaseDC(IntPtr.Zero, screen);
    }

    internal static int PickScreen(Point? point, Rectangle[] frames)
    {
        if (point != null)
            for (int i = 0; i < frames.Length; i++)
                if (frames[i].Contains(point.Value)) return i;
        return 0;
    }

    // "DISPLAY2" matches "\\.\DISPLAY2" exactly so the JSON value needs no backslash escapes; otherwise a monitor-name
    // substring such as "HP U32" matches, which survives the DISPLAYn renumbering that happens when monitors reconnect.
    internal static int? PickDisplay(string? name, (string Device, string Monitor)[] displays)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var wanted = name.Trim().TrimStart('\\', '.');
        var index = Array.FindIndex(displays, d => string.Equals(d.Device.TrimStart('\\', '.'), wanted, StringComparison.OrdinalIgnoreCase));
        if (index < 0) index = Array.FindIndex(displays, d => d.Monitor.Contains(wanted, StringComparison.OrdinalIgnoreCase));
        return index < 0 ? null : index;
    }

    static (Screen Screen, string Monitor)[] Displays()
    {
        var names = MonitorNames();
        return Screen.AllScreens.OrderByDescending(s => s.Primary)
            .Select(s => (s, names.TryGetValue(s.DeviceName, out var monitor) ? monitor : "")).ToArray();
    }

    internal static string ListDisplays() => string.Join(Environment.NewLine, Displays().Select(d =>
        $"{d.Screen.DeviceName.TrimStart('\\', '.')} \"{d.Monitor}\"{(d.Screen.Primary ? " primary" : "")} " +
        $"{d.Screen.Bounds.X},{d.Screen.Bounds.Y} {d.Screen.Bounds.Width}x{d.Screen.Bounds.Height}"));

    // GDI device name (\\.\DISPLAYn) -> EDID friendly name, via the display configuration API.
    static Dictionary<string, string> MonitorNames()
    {
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (GetDisplayConfigBufferSizes(2, out uint pathCount, out uint modeCount) != 0) return names;
        var paths = new PathInfo[pathCount];
        var modes = new ModeInfo[modeCount];
        if (QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return names;
        foreach (var path in paths.Take((int)pathCount))
        {
            var source = new SourceName { Header = new DeviceInfoHeader { Type = 1, Size = Marshal.SizeOf<SourceName>(), Adapter = path.SourceAdapter, Id = path.SourceId } };
            var target = new TargetName { Header = new DeviceInfoHeader { Type = 2, Size = Marshal.SizeOf<TargetName>(), Adapter = path.TargetAdapter, Id = path.TargetId } };
            if (DisplayConfigGetDeviceInfo(ref source) == 0 && DisplayConfigGetDeviceInfo(ref target) == 0)
                names[source.GdiName] = target.FriendlyName;
        }
        return names;
    }

    static Rectangle TargetBounds(string? display)
    {
        var displays = string.IsNullOrWhiteSpace(display) ? [] : Displays();
        if (PickDisplay(display, displays.Select(d => (d.Screen.DeviceName, d.Monitor)).ToArray()) is int chosen) return displays[chosen].Screen.Bounds;
        var screens = Screen.AllScreens.OrderByDescending(s => s.Primary).ToArray();
        if (!string.IsNullOrWhiteSpace(display)) Program.Log($"display \"{display}\" が見つからないためフォーカス中の画面を使います");
        Point? point = null;
        var window = GetForegroundWindow();
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (window != IntPtr.Zero && GetMonitorInfo(MonitorFromWindow(window, 2), ref info))
            point = new Point(info.Monitor.Left + (info.Monitor.Right - info.Monitor.Left) / 2,
                info.Monitor.Top + (info.Monitor.Bottom - info.Monitor.Top) / 2);
        return screens[PickScreen(point, screens.Select(s => s.Bounds).ToArray())].Bounds;
    }

    internal void Flash(Color color, int count, GlowStyle style, string? display, double size, Action? completed = null)
    {
        Hide();
        var current = generation;
        // Why: SPI_GETCLIENTAREAANIMATION false means reduced animation; this mapping is unverified on Windows hardware.
        bool reduceMotion = SystemParametersInfo(0x1042, 0, out bool animations, 0) && !animations;
        var n = FlashCount(count, reduceMotion);
        if (n == 0) { completed?.Invoke(); return; }
        var bounds = TargetBounds(display);
        var plan = BuildPlan(style, bounds.Size, MonitorDpi(bounds) / 96.0 * size);
        var lut = Lut(color);
        CreateSurface(bounds.Size);
        Bounds = bounds;
        var duration = Duration(style, n);
        var clock = Stopwatch.StartNew();
        void Frame()
        {
            var t = clock.Elapsed.TotalSeconds;
            if (t >= duration) { Hide(); completed?.Invoke(); return; }
            var (gain, param) = FrameAt(style, t, n);
            Render(plan, lut, gain, param);
            Present(bounds);
        }
        Frame();
        Show();
        timer = new System.Windows.Forms.Timer { Interval = 15 };
        timer.Tick += (_, _) => { if (current == generation) Frame(); };
        timer.Start();
    }

    public new void Hide()
    {
        generation++;
        timer?.Stop(); timer?.Dispose(); timer = null;
        base.Hide();
        FreeSurface();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) Hide();
        base.Dispose(disposing);
    }

    static uint MonitorDpi(Rectangle bounds)
    {
        var monitor = MonitorFromPoint(new NativePoint { X = bounds.Left + bounds.Width / 2, Y = bounds.Top + bounds.Height / 2 }, 2);
        return GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 ? dpi : 96;
    }

    [StructLayout(LayoutKind.Sequential)] struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct NativeSize { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential)] struct BlendFunction { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfoHeader
    {
        public int Size, Width, Height;
        public short Planes, BitCount;
        public int Compression, SizeImage, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)]
    struct PathInfo
    {
        public Luid SourceAdapter; public uint SourceId, SourceModeIndex, SourceStatus;
        public Luid TargetAdapter; public uint TargetId, TargetModeIndex, OutputTechnology, Rotation, Scaling, RefreshNumerator, RefreshDenominator, ScanLineOrdering;
        public int TargetAvailable; public uint TargetStatus, Flags;
    }
    [StructLayout(LayoutKind.Sequential, Size = 64)] struct ModeInfo { public uint InfoType; }
    [StructLayout(LayoutKind.Sequential)] struct DeviceInfoHeader { public int Type, Size; public Luid Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SourceName { public DeviceInfoHeader Header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string GdiName; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TargetName
    {
        public DeviceInfoHeader Header; public uint Flags, OutputTechnology; public ushort ManufactureId, ProductCodeId; public uint ConnectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string FriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);
    [DllImport("user32.dll")]
    static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PathInfo[] paths, ref uint modeCount, [Out] ModeInfo[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SourceName request);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TargetName request);
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr gdiObject);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr gdiObject);
    [DllImport("gdi32.dll")]
    static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfoHeader info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destination, ref NativePoint position, ref NativeSize size,
        IntPtr source, ref NativePoint sourcePosition, int colorKey, ref BlendFunction blend, int flags);

    static bool Near(double a, double b) => Math.Abs(a - b) < 1e-9;

    internal static Dictionary<string, Func<bool>> GlowSelfTests() => new()
    {
        ["C3"] = () => new[] { (3, false, 3), (1, false, 1), (3, true, 1), (0, false, 0) }.All(p => FlashCount(p.Item1, p.Item2) == p.Item3)
            && Near(Duration(GlowStyle.Soft, 3), 2.7) && Near(Duration(GlowStyle.Breath, 2), 3.2),
        ["C4"] = () => GlowOpacity == 0.8 && ParseStyle(null) == GlowStyle.Soft && ParseStyle("bad") == GlowStyle.Soft
            && ParseStyle("breath") == GlowStyle.Breath && ParseStyle("orbit") == GlowStyle.Orbit && ParseStyle("corner") == GlowStyle.Corner,
        ["C5"] = () => Near(Pulse(0, 1.0 / 3, 1), 0) && Near(Pulse(1.0 / 3, 1.0 / 3, 1), 1)
            && Near(FrameAt(GlowStyle.Breath, 0.8, 1).Gain, 0.85) && Near(FrameAt(GlowStyle.Orbit, 0.8, 1).Gain, 1)
            && Near(FrameAt(GlowStyle.Corner, 0.9, 1).Param, 1) && Near(FrameAt(GlowStyle.Corner, 1.5 - 1e-12, 1).Gain, 0)
            && Near(Lobe(0), 1) && Near(Lobe(0.25), 0) && Near(Lobe(0.5), 1) && Near(Radial(0.5), 1) && Near(Radial(1.2), 0)
            && ShadowEdge(0, 40) > 0.49 && ShadowEdge(0, 40) < 0.51 && ShadowEdge(80, 40) < 0.001
            && Soft(1, 1) > Soft(0.5, 0) && Near(Soft(0, 0), 0),
        ["C7"] = () =>
        {
            foreach (var (size, expected) in new[] {
                (new Size(1920, 1080), 0.45240025), (new Size(1920, 1081), 0.45165975),
                (new Size(1080, 1920), 0.45240025), (new Size(1081, 1920), 0.45165975) })
            {
                var plan = BuildPlan(GlowStyle.Breath, size, 5);
                var index = Array.IndexOf(plan.Index, (size.Height / 2) * size.Width + size.Width / 2);
                if (index < 0 || Math.Abs(plan.Base[index] - expected) > 1e-6
                    || plan.Index.Distinct().Count() != plan.Index.Length) return false;
            }
            var normal = BuildPlan(GlowStyle.Breath, new Size(1920, 1080), 1);
            return Array.IndexOf(normal.Index, 540 * 1920 + 960) < 0;
        },
        ["S1"] = () => PickScreen(new Point(500, 1100), [new(0, 0, 1000, 800), new(0, 800, 1000, 600)]) == 1
            && PickScreen(new Point(500, 400), [new(0, 0, 1000, 800), new(0, 800, 1000, 600)]) == 0
            && PickScreen(new Point(250, 50), [new(0, 0, 100, 100), new(200, 0, 100, 100)]) == 1,
        ["S3"] = () =>
        {
            (string, string)[] displays = [(@"\\.\DISPLAY1", "EB321HQU"), (@"\\.\DISPLAY4", "HP U32 4K HDR"), (@"\\.\DISPLAY10", "DISPLAY1 Mirror")];
            return PickDisplay("DISPLAY4", displays) == 1 && PickDisplay(@"\\.\display1", displays) == 0
                && PickDisplay("hp u32", displays) == 1 && PickDisplay("DISPLAY1", displays) == 0
                && PickDisplay("DISPLAY9", displays) == null && PickDisplay(null, displays) == null && PickDisplay("  ", displays) == null;
        },
        ["S2"] = () => PickScreen(null, [new(0, 0, 1000, 800)]) == 0
            && PickScreen(new Point(-1, 400), [new(0, 0, 1000, 800)]) == 0
            && PickScreen(new Point(500, 2000), [new(0, 0, 1000, 800), new(0, 800, 1000, 600)]) == 0
    };
}
