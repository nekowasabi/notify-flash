import Cocoa

if CommandLine.arguments.dropFirst().first == "--self-test" {
    let ids = CommandLine.arguments.dropFirst(2)
    guard !ids.isEmpty else { exit(2) }
    let tests = captureSelfTests.merging(glowSelfTests) { _, _ in preconditionFailure("自己テスト ID 重複") }
        .merging(configSelfTests) { _, _ in preconditionFailure("自己テスト ID 重複") }
        .merging(integrationSelfTests()) { _, _ in preconditionFailure("自己テスト ID 重複") }
    for id in ids {
        guard let test = tests[id] else {
            fputs("未登録の自己テスト: \(id)\n", stderr)
            exit(1)
        }
        guard test() else {
            fputs("自己テスト失敗: \(id)\n", stderr)
            exit(1)
        }
    }
    exit(0)
}

func glowRequest(app: String, text: String = "", enabled: Bool, config: Config?) -> (color: String, count: Int)? {
    guard enabled, let config, let color = colorFor(app, text: text, in: config) else { return nil }
    return (color, config.count)
}

func handleBanner(app: String, text: String) {
    print(app)
    guard let request = glowRequest(app: app, text: text, enabled: glowEnabled, config: loadConfig(at: configURL)),
          let color = parseHexColor(request.color) else { return }
    flash(color: color, count: request.count)
}

func integrationSelfTests() -> [String: () -> Bool] {
    let config = Config(count: 3, apps: ["terminal-notifier": "#FF8800"])
    return [
        "I1": {
            guard let first = glowRequest(app: "terminal-notifier", enabled: true, config: config),
                  let second = glowRequest(app: "I1Sentinel", enabled: true,
                                           config: Config(count: 5, apps: ["I1Sentinel": "#ABCDEF"])) else { return false }
            return first.color == "#FF8800" && first.count == 3
                && second.color == "#ABCDEF" && second.count == 5
        },
        "I2": { glowRequest(app: "terminal-notifier", enabled: false, config: config) == nil },
        "I3": {
            ["Slack", "Terminal-Notifier", ""].allSatisfy {
                glowRequest(app: $0, enabled: true, config: config) == nil
            } && glowRequest(app: "terminal-notifier", enabled: true, config: nil) == nil
        }
    ]
}

if CommandLine.arguments.dropFirst().first == "--flash-test" {
    guard CommandLine.arguments.count == 3, let color = parseHexColor(CommandLine.arguments[2]) else { exit(2) }
    NSApplication.shared.setActivationPolicy(.accessory)
    flash(color: color, count: 1)
    let duration = flashSchedule(count: 1, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        .reduce(0) { $0 + $1.on + $1.off }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(duration)) { exit(0) }
    NSApplication.shared.run()
}

let axPrompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axPrompt) {
    fputs("アクセシビリティ権限を付与してください。付与後に自動で捕捉を開始します\n", stderr)
}
NSApplication.shared.setActivationPolicy(.accessory)
ensureDefaultConfig(at: configURL)

final class MenuTarget: NSObject {
    @objc func toggle(_ item: NSMenuItem) {
        glowEnabled.toggle()
        item.state = glowEnabled ? .on : .off
        if !glowEnabled { hideGlow() }
    }

    @objc func openConfig() {
        ensureDefaultConfig(at: configURL)
        NSWorkspace.shared.open(configURL)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "Notify Flash"
// Why: Menu item targets are weak, so retain the target for the application's lifetime.
let menuTarget = MenuTarget()
let menu = NSMenu()
let toggleItem = NSMenuItem(title: "ON/OFF 切替", action: #selector(MenuTarget.toggle(_:)), keyEquivalent: "")
toggleItem.state = .on
toggleItem.target = menuTarget
menu.addItem(toggleItem)
let openConfigItem = NSMenuItem(title: "設定ファイルを開く", action: #selector(MenuTarget.openConfig), keyEquivalent: "")
openConfigItem.target = menuTarget
menu.addItem(openConfigItem)
let quitItem = NSMenuItem(title: "終了", action: #selector(MenuTarget.quit), keyEquivalent: "")
quitItem.target = menuTarget
menu.addItem(quitItem)
statusItem.menu = menu

// Why: .app として open で起動するため、権限が無くても終了せず付与を待って捕捉を始める。
func startCaptureWhenTrusted() {
    guard AXIsProcessTrusted() else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startCaptureWhenTrusted() }
        return
    }
    startCapture()
}
startCaptureWhenTrusted()
NSApplication.shared.run()
