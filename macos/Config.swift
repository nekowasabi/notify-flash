import Foundation

struct Rule: Codable {
    var contains: String
    var color: String
}

struct Config: Codable {
    var count: Int
    var apps: [String: String]
    var rules: [Rule]? = nil
    var style: String? = nil
    var size: Double? = nil
}

let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/notify-flash/config.json")
var glowEnabled = true

func loadConfig(at url: URL) -> Config? {
    do {
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        if !(1...10).contains(config.count) { config.count = 3 }
        config.apps = config.apps.filter { parseHexColor($0.value) != nil }
        config.rules = config.rules?.filter { !$0.contains.isEmpty && parseHexColor($0.color) != nil }
        return config
    } catch {
        FileHandle.standardError.write(Data("設定ファイルを読み込めません\n".utf8))
        return nil
    }
}

func ensureDefaultConfig(at url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Why: Exclusive creation preserves an existing config even if another process creates it concurrently.
        try Data("{\"count\":3,\"apps\":{}}".utf8).write(to: url, options: .withoutOverwriting)
    } catch {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { return }
        FileHandle.standardError.write(Data("既定の設定ファイルを作成できません\n".utf8))
    }
}

// Why: Claude Code の通知は terminal-notifier 経由で届き送信元名では区別できないため、タイトル・本文の文字列ルールを送信元名より優先する。
func colorFor(_ appName: String, text: String = "", in config: Config) -> String? {
    config.rules?.first { text.contains($0.contains) }?.color ?? config.apps[appName]
}

private func withConfigTest(_ body: (URL) throws -> Bool) -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try body(directory.appendingPathComponent("config.json"))
    } catch {
        return false
    }
}

let configSelfTests: [String: () -> Bool] = [
    "A1": {
        withConfigTest { url in
            try Data("{\"count\":3,\"apps\":{\"terminal-notifier\":\"#FF8800\"}}".utf8).write(to: url)
            guard let config = loadConfig(at: url) else { return false }
            return colorFor("terminal-notifier", in: config) == "#FF8800"
        }
    },
    "A2": {
        withConfigTest { url in
            try Data("{\"count\":3,\"apps\":{\"terminal-notifier\":\"#FF8800\"}}".utf8).write(to: url)
            guard let config = loadConfig(at: url) else { return false }
            return colorFor("Terminal-Notifier", in: config) == nil
                && colorFor("TERMINAL-NOTIFIER", in: config) == nil
        }
    },
    "A3": {
        withConfigTest { url in
            try Data("{\"count\":3,\"apps\":{}}".utf8).write(to: url)
            guard let config = loadConfig(at: url) else { return false }
            return colorFor("terminal-notifier", in: config) == nil
        }
    },
    "A4": {
        withConfigTest { directoryURL in
            let url = directoryURL.deletingLastPathComponent().appendingPathComponent("missing/config.json")
            guard !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return false }
            ensureDefaultConfig(at: url)
            guard try Data(contentsOf: url) == Data("{\"count\":3,\"apps\":{}}".utf8),
                  let config = loadConfig(at: url) else { return false }
            return config.count == 3 && config.apps.isEmpty && colorFor("terminal-notifier", in: config) == nil
        }
    },
    "A5": {
        withConfigTest { url in
            let data = Data("{".utf8)
            try data.write(to: url)
            return try loadConfig(at: url) == nil && Data(contentsOf: url) == data
        }
    },
    "A6": {
        withConfigTest { url in
            let data = Data("{\"count\":5,\"apps\":{\"Keep\":\"#112233\"}}".utf8)
            try data.write(to: url)
            ensureDefaultConfig(at: url)
            ensureDefaultConfig(at: url)
            return try Data(contentsOf: url) == data
        }
    },
    "C1": {
        withConfigTest { url in
            try Data("{\"count\":3,\"apps\":{\"First\":\"#FF8800\",\"Second\":\"#112233\",\"Bad\":\"#FFF\"}}".utf8).write(to: url)
            guard let config = loadConfig(at: url) else { return false }
            return colorFor("First", in: config) == "#FF8800"
                && colorFor("Second", in: config) == "#112233" && colorFor("Bad", in: config) == nil
        }
    },
    "R1": {
        withConfigTest { url in
            try Data("""
            {"count":3,"apps":{"terminal-notifier":"#FF8800"},
             "rules":[{"contains":"","color":"#000000"},{"contains":"Claude","color":"#FFF"},
                      {"contains":"Claude","color":"#FFD700"},{"contains":"Claude is","color":"#112233"}]}
            """.utf8).write(to: url)
            guard let config = loadConfig(at: url) else { return false }
            return colorFor("terminal-notifier", text: "Ghostty notify-flash\nClaude is waiting for your input", in: config) == "#FFD700"
                && colorFor("terminal-notifier", text: "notify-flash test\nplain", in: config) == "#FF8800"
                && colorFor("Unknown", text: "Claude", in: config) == "#FFD700"
                && colorFor("Unknown", text: "claude", in: config) == nil
        }
    },
    "C2": {
        withConfigTest { url in
            for (count, expected) in [(0, 3), (11, 3), (5, 5), (1, 1), (10, 10), (2147483648, 3), (-2147483649, 3), (Int.min, 3), (Int.max, 3)] {
                try Data("{\"count\":\(count),\"apps\":{}}".utf8).write(to: url)
                guard loadConfig(at: url)?.count == expected else { return false }
            }
            for (count, expected) in [("1.0", 1), ("3e0", 3), ("10.0", 10), ("11.0", 3), ("2147483648.0", 3)] {
                try Data("{\"count\":\(count),\"apps\":{}}".utf8).write(to: url)
                guard loadConfig(at: url)?.count == expected else { return false }
            }
            for count in ["1.5", "1e400", "\"3\"", "null"] {
                try Data("{\"count\":\(count),\"apps\":{}}".utf8).write(to: url)
                guard loadConfig(at: url) == nil else { return false }
            }
            return true
        }
    },
    "C6": {
        withConfigTest { url in
            for (size, expected) in [("2", 2.0), ("0.5", 0.5), ("0.25", 0.25), ("5", 5.0), ("0.1", 1.0), ("6", 1.0), ("null", 1.0)] {
                try Data("{\"count\":3,\"apps\":{},\"size\":\(size)}".utf8).write(to: url)
                guard let config = loadConfig(at: url), glowSize(config.size) == CGFloat(expected) else { return false }
            }
            try Data("{\"count\":3,\"apps\":{}}".utf8).write(to: url)
            return loadConfig(at: url).map { glowSize($0.size) } == 1
        }
    }
]
