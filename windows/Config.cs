using System.Text.Json;

namespace NotifyFlash;

sealed record Rule(string Contains, string Color);
sealed record Config(int Count, Dictionary<string, string> Apps, List<Rule> Rules, string? Style = null, string? Display = null, double Size = 1)
{
    internal const string DefaultJson = "{\"count\":3,\"apps\":{}}";

    internal static string ResolvePath(IEnumerable<string?> exeDirs, string userProfile)
    {
        foreach (var directory in exeDirs.Where(d => !string.IsNullOrWhiteSpace(d)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var path = Path.Combine(directory!, "config.json");
            if (File.Exists(path)) return path;
        }
        return Path.Combine(userProfile, ".config", "notify-flash", "config.json");
    }

    internal static string CurrentPath() => ResolvePath(
        [AppContext.BaseDirectory, Path.GetDirectoryName(Environment.ProcessPath)],
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    internal static string EnsureCurrentDefault()
    {
        var path = CurrentPath();
        var fallback = ResolvePath([], Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        // Why: A colocated file can disappear after resolution; default creation must still stay in the user profile.
        if (string.Equals(path, fallback, StringComparison.OrdinalIgnoreCase)) EnsureDefault(path);
        return path;
    }

    internal static void EnsureDefault(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // Why: CreateNew preserves a configuration created concurrently by another process.
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            stream.Write(System.Text.Encoding.UTF8.GetBytes(DefaultJson));
        }
        catch (IOException) when (File.Exists(path)) { }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Program.Log("既定の設定ファイルを作成できません: " + e.Message);
        }
    }

    internal static Config? Load(string path)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var count = root.GetProperty("count").GetInt32();
            if (count is < 1 or > 10) count = 3;
            var apps = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var app in root.GetProperty("apps").EnumerateObject())
            {
                var color = app.Value.GetString();
                if (Glow.ParseHex(color) != null) apps[app.Name] = color!;
            }
            var rules = new List<Rule>();
            if (root.TryGetProperty("rules", out var items) && items.ValueKind != JsonValueKind.Null)
                foreach (var item in items.EnumerateArray())
                {
                    var contains = item.GetProperty("contains").GetString();
                    var color = item.GetProperty("color").GetString();
                    if (!string.IsNullOrEmpty(contains) && Glow.ParseHex(color) != null)
                        rules.Add(new Rule(contains, color!));
                }
            string? Text(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            // Why: One multiplier scales every style's lengths (glow radius, gradient depth, band width) alike.
            var size = root.TryGetProperty("size", out var sizeValue) && sizeValue.ValueKind == JsonValueKind.Number
                && sizeValue.GetDouble() is var s and >= 0.25 and <= 5 ? s : 1;
            return new Config(count, apps, rules, Text("style"), Text("display"), size);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
        {
            Console.Error.WriteLine("設定ファイルを読み込めません");
            return null;
        }
    }

    // Why: Rules distinguish notifications relayed through the same sender, so they precede app matching.
    internal string? ColorFor(string app, string text) =>
        Rules.FirstOrDefault(r => text.Contains(r.Contains, StringComparison.Ordinal))?.Color
        ?? Apps.GetValueOrDefault(app);

    static bool WithTemp(Func<string, bool> test)
    {
        var directory = Path.Combine(Path.GetTempPath(), "notify-flash-" + Guid.NewGuid());
        Directory.CreateDirectory(directory);
        try { return test(directory); }
        finally { Directory.Delete(directory, true); }
    }

    static bool WithConfig(string json, Func<Config?, bool> test) => WithTemp(directory =>
    {
        var path = Path.Combine(directory, "config.json");
        File.WriteAllText(path, json);
        return test(Load(path));
    });

    internal static Dictionary<string, Func<bool>> ConfigSelfTests() => new()
    {
        ["A1"] = () => WithConfig("{\"count\":3,\"apps\":{\"terminal-notifier\":\"#FF8800\"}}", c => c?.ColorFor("terminal-notifier", "") == "#FF8800"),
        ["A2"] = () => WithConfig("{\"count\":3,\"apps\":{\"terminal-notifier\":\"#FF8800\"}}", c => c != null && c.ColorFor("Terminal-Notifier", "") == null && c.ColorFor("TERMINAL-NOTIFIER", "") == null),
        ["A3"] = () => WithConfig(DefaultJson, c => c != null && c.ColorFor("terminal-notifier", "") == null),
        ["A4"] = () => WithTemp(d =>
        {
            var path = Path.Combine(d, "missing", "config.json");
            EnsureDefault(path);
            var c = Load(path);
            return File.ReadAllText(path) == DefaultJson && c?.Count == 3 && c.Apps.Count == 0 && c.ColorFor("terminal-notifier", "") == null;
        }),
        ["A5"] = () => WithTemp(d =>
        {
            var path = Path.Combine(d, "config.json");
            File.WriteAllText(path, "{");
            var previous = Console.Error;
            using var errors = new StringWriter();
            try
            {
                Console.SetError(errors);
                return Load(path) == null && File.ReadAllText(path) == "{" && errors.ToString().Contains("設定ファイルを読み込めません");
            }
            finally { Console.SetError(previous); }
        }),
        ["A6"] = () => WithTemp(d =>
        {
            var path = Path.Combine(d, "config.json");
            const string json = "{\"count\":5,\"apps\":{\"Keep\":\"#112233\"}}";
            File.WriteAllText(path, json);
            EnsureDefault(path); EnsureDefault(path);
            return File.ReadAllText(path) == json;
        }),
        ["C1"] = () => WithConfig("{\"count\":3,\"apps\":{\"First\":\"#FF8800\",\"Second\":\"#112233\",\"Bad\":\"#FFF\"}}", c => c?.ColorFor("First", "") == "#FF8800" && c.ColorFor("Second", "") == "#112233" && c.ColorFor("Bad", "") == null),
        ["C2"] = () => new[] { (0, 3), (11, 3), (5, 5), (1, 1), (10, 10) }.All(pair => WithConfig($"{{\"count\":{pair.Item1},\"apps\":{{}}}}", c => c?.Count == pair.Item2)),
        ["C6"] = () => new[] { ("2", 2.0), ("0.5", 0.5), ("0.25", 0.25), ("5", 5.0), ("0.1", 1.0), ("6", 1.0), ("\"big\"", 1.0), ("null", 1.0) }
            .All(pair => WithConfig($"{{\"count\":3,\"apps\":{{}},\"size\":{pair.Item1}}}", c => c?.Size == pair.Item2))
            && WithConfig("{\"count\":3,\"apps\":{}}", c => c?.Size == 1),
        ["R1"] = () => WithConfig("""
            {"count":3,"apps":{"terminal-notifier":"#FF8800"},"rules":[
            {"contains":"","color":"#000000"},{"contains":"Claude","color":"#FFF"},
            {"contains":"Claude","color":"#FFD700"},{"contains":"Claude is","color":"#112233"}]}
            """, c => c?.ColorFor("terminal-notifier", "Ghostty notify-flash\nClaude is waiting for your input") == "#FFD700"
                && c.ColorFor("terminal-notifier", "notify-flash test\nplain") == "#FF8800"
                && c.ColorFor("Unknown", "Claude") == "#FFD700" && c.ColorFor("Unknown", "claude") == null),
        ["P1"] = () => WithTemp(d =>
        {
            var exe = Path.Combine(d, "exe"); var home = Path.Combine(d, "home");
            var fallback = ResolvePath([], home); EnsureDefault(fallback);
            Directory.CreateDirectory(exe);
            var local = Path.Combine(exe, "config.json"); File.WriteAllText(local, DefaultJson);
            return ResolvePath([exe, exe.ToUpperInvariant()], home) == local;
        }),
        ["P2"] = () => WithTemp(d =>
        {
            var home = Path.Combine(d, "home"); var fallback = ResolvePath([], home);
            EnsureDefault(fallback);
            return ResolvePath([Path.Combine(d, "exe")], home) == fallback;
        }),
        ["P3"] = () => WithTemp(d =>
        {
            var exe = Path.Combine(d, "exe"); var home = Path.Combine(d, "home");
            var path = ResolvePath([exe], home); EnsureDefault(path);
            return path == Path.Combine(home, ".config", "notify-flash", "config.json")
                && File.ReadAllText(path) == DefaultJson && !File.Exists(Path.Combine(exe, "config.json"));
        })
    };
}
