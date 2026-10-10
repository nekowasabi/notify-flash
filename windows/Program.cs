using System.Diagnostics;

namespace NotifyFlash;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        if (args.FirstOrDefault() == "--self-test") return SelfTest(args.Skip(1).ToArray());
        if (args.FirstOrDefault() == "--list-displays")
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Console.WriteLine(Glow.ListDisplays());
            return 0;
        }
        if (args.FirstOrDefault() == "--flash-test")
        {
            if (args.Length is not (2 or 3) || Glow.ParseHex(args[1]) is not Color color) return 2;
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            using var glow = new Glow();
            using var context = new ApplicationContext();
            // Why: Reads "display" and "size" from the config so both can be checked without a real notification.
            var config = Config.Load(Config.CurrentPath());
            glow.Flash(color, 1, Glow.ParseStyle(args.Length == 3 ? args[2] : null), config?.Display, config?.Size ?? 1, context.ExitThread);
            Application.Run(context);
            return 0;
        }
        using var mutex = new Mutex(true, "Local\\NotifyFlash", out bool created);
        if (!created) return 0;
        try
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            using var resident = new Resident();
            Application.Run(resident);
        }
        finally { mutex.ReleaseMutex(); }
        return 0;
    }

    internal static void Log(string message)
    {
        Console.Error.WriteLine(message);
        try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "notify-flash.log"), $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { Console.Error.WriteLine("ログを書き込めません: " + e.Message); }
    }

    internal static (string Color, int Count)? GlowRequest(string app, string title, string body, bool enabled, Config? config)
    {
        if (!enabled || config == null || config.ColorFor(app, title + "\n" + body) is not string color) return null;
        return (color, config.Count);
    }

    static Dictionary<string, Func<bool>> IntegrationSelfTests()
    {
        var config = new Config(3, new() { ["terminal-notifier"] = "#FF8800" }, []);
        return new()
        {
            ["I1"] = () => GlowRequest("terminal-notifier", "", "", true, config) == ("#FF8800", 3)
                && GlowRequest("I1Sentinel", "", "", true, new Config(5, new() { ["I1Sentinel"] = "#ABCDEF" }, [])) == ("#ABCDEF", 5),
            ["I2"] = () => GlowRequest("terminal-notifier", "", "", false, config) == null,
            ["I3"] = () => new[] { "Slack", "Terminal-Notifier", "" }.All(app => GlowRequest(app, "", "", true, config) == null)
                && GlowRequest("terminal-notifier", "", "", true, null) == null
        };
    }

    static int SelfTest(string[] ids)
    {
        if (ids.Length == 0) return 2;
        var tests = new Dictionary<string, Func<bool>>();
        foreach (var group in new[] { Capture.CaptureSelfTests(), Glow.GlowSelfTests(), Config.ConfigSelfTests(), IntegrationSelfTests() })
            foreach (var pair in group) tests.Add(pair.Key, pair.Value);
        foreach (var id in ids)
        {
            if (!tests.TryGetValue(id, out var test))
            {
                Console.Error.WriteLine("未登録の自己テスト: " + id);
                return 1;
            }
            try
            {
                if (test()) { Console.WriteLine("PASS " + id); continue; }
            }
            catch (Exception e) { Console.Error.WriteLine(e.Message); }
            Console.Error.WriteLine("自己テスト失敗: " + id);
            return 1;
        }
        return 0;
    }
}

sealed class Resident : ApplicationContext
{
    readonly Control dispatcher = new();
    readonly Glow glow = new();
    readonly NotifyIcon icon;
    readonly ContextMenuStrip menu = new();
    readonly Capture capture;
    bool enabled = true;

    internal Resident()
    {
        _ = dispatcher.Handle;
        Config.EnsureCurrentDefault();
        var toggle = new ToolStripMenuItem("ON/OFF") { Checked = true };
        toggle.Click += (_, _) =>
        {
            enabled = !enabled; toggle.Checked = enabled;
            if (!enabled) glow.Hide();
        };
        menu.Items.Add(toggle);
        menu.Items.Add("設定ファイルを開く", null, (_, _) =>
        {
            var path = Config.EnsureCurrentDefault();
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception e) { Program.Log("設定ファイルを開けません: " + e.Message); }
        });
        menu.Items.Add("終了", null, (_, _) => ExitThread());
        icon = new NotifyIcon { Icon = SystemIcons.Information, Text = "Notify Flash", ContextMenuStrip = menu, Visible = true };
        capture = new Capture(dispatcher, banner =>
        {
            Program.Log("通知: " + banner.App);
            var config = Config.Load(Config.CurrentPath());
            var request = Program.GlowRequest(banner.App!, banner.Title, banner.Body, enabled, config);
            if (request is { } flash && Glow.ParseHex(flash.Color) is Color color) glow.Flash(color, flash.Count, Glow.ParseStyle(config?.Style), config?.Display, config?.Size ?? 1);
        });
        dispatcher.BeginInvoke((Action)(async () => await capture.Start()));
    }

    protected override void ExitThreadCore()
    {
        capture.Dispose(); glow.Hide(); icon.Visible = false;
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            capture.Dispose(); icon.Dispose(); menu.Dispose(); glow.Dispose(); dispatcher.Dispose();
        }
        base.Dispose(disposing);
    }
}
