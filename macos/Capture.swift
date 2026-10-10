import Cocoa

struct Banner {
    let uuid: String
    let appName: String?
}

func extractAppName(desc: String, title: String, body: String) -> String? {
    let text = title.isEmpty ? body : title
    guard !text.isEmpty, let range = desc.range(of: text) else { return nil }
    var name = String(desc[..<range.lowerBound])
    let trailing = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    while let last = name.last, last.unicodeScalars.allSatisfy({ trailing.contains($0) }) {
        name.removeLast()
    }
    return name.isEmpty ? nil : name
}

struct Seen {
    private var uuids: [String] = []

    mutating func accept(_ banner: Banner) -> Bool {
        guard !banner.uuid.isEmpty, banner.appName != nil, !uuids.contains(banner.uuid) else {
            return false
        }
        uuids.append(banner.uuid)
        if uuids.count > 64 { uuids.removeFirst() }
        return true
    }
}

private var captureObserver: AXObserver?
private var captureSeen = Seen()

private func captureValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func bannerTexts(_ element: AXUIElement, depth: Int = 0) -> (title: String, body: String) {
    var title = ""
    var body = ""
    if captureValue(element, kAXRoleAttribute) as? String == kAXStaticTextRole {
        let text = captureValue(element, kAXValueAttribute) as? String ?? ""
        switch captureValue(element, kAXIdentifierAttribute) as? String {
        case "title": title = text
        case "body": body = text
        default: break
        }
    }
    if depth < 10, let children = captureValue(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            let texts = bannerTexts(child, depth: depth + 1)
            if title.isEmpty { title = texts.title }
            if body.isEmpty { body = texts.body }
        }
    }
    return (title, body)
}

private func captureBanners(_ element: AXUIElement, depth: Int = 0) {
    // shortcut: Traversal uses the PoC's depth limit of 10; increase it if a deeper banner tree is observed.
    if captureValue(element, kAXSubroleAttribute) as? String == "AXNotificationCenterBanner" {
        let uuid = captureValue(element, kAXIdentifierAttribute) as? String ?? ""
        guard !uuid.isEmpty else { return }
        let texts = bannerTexts(element)
        let desc = captureValue(element, kAXDescriptionAttribute) as? String ?? ""
        let banner = Banner(uuid: uuid, appName: extractAppName(desc: desc, title: texts.title, body: texts.body))
        if captureSeen.accept(banner), let name = banner.appName { handleBanner(app: name, text: texts.title + "\n" + texts.body) }
        return
    }
    guard depth < 10, let children = captureValue(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children { captureBanners(child, depth: depth + 1) }
}

func startCapture() {
    guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
        fputs("NotificationCenter が起動していません\n", stderr)
        exit(1)
    }
    let root = AXUIElementCreateApplication(nc.processIdentifier)
    let callback: AXObserverCallback = { _, element, notification, _ in
        // Why: Keep seen UUIDs after destruction so repeated banners cannot request another flash.
        guard notification as String != kAXUIElementDestroyedNotification else { return }
        captureBanners(element)
    }
    let error = AXObserverCreate(nc.processIdentifier, callback, &captureObserver)
    guard error == .success, let observer = captureObserver else {
        fputs("AXObserverCreate が失敗しました: \(error.rawValue)\n", stderr)
        exit(1)
    }
    for notification in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification] {
        let error = AXObserverAddNotification(observer, root, notification as CFString, nil)
        if error != .success {
            fputs("\(notification) の購読が失敗しました: \(error.rawValue)\n", stderr)
        }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
}

let captureSelfTests: [String: () -> Bool] = [
    "E1": { extractAppName(desc: "terminal-notifier、iTerm focusbm, Tool permission requested", title: "iTerm focusbm", body: "") == "terminal-notifier" },
    "E2": { extractAppName(desc: "terminal-notifier、notify-flash test 1, plain sender", title: "notify-flash test 1", body: "") == "terminal-notifier" },
    "E3": { extractAppName(desc: "App、, only body", title: "", body: "only body") == "App" },
    "E4": { extractAppName(desc: "placeholder", title: "", body: "") == nil },
    "E5": { extractAppName(desc: "App、, only body", title: "no-such-title", body: "only body") == nil },
    "E6": { extractAppName(desc: "My Notify、Notify, body", title: "Notify", body: "") == "My" },
    "D1": {
        var seen = Seen()
        let banner = Banner(uuid: "one", appName: "App")
        return [banner, banner, banner].filter { seen.accept($0) }.count == 1
    },
    "D2": {
        var seen = Seen()
        return [Banner(uuid: "one", appName: "App"), Banner(uuid: "two", appName: "App")].filter { seen.accept($0) }.count == 2
    },
    "D3": {
        var seen = Seen()
        return !seen.accept(Banner(uuid: "", appName: "App"))
    },
    "D4": {
        var seen = Seen()
        let banner = Banner(uuid: "one", appName: "App")
        let first = seen.accept(banner)
        // Why: Destroyed is a no-op in the callback; Seen deliberately has no removal API.
        return first && !seen.accept(banner)
    },
    "D5": {
        var seen = Seen()
        let failed = Banner(uuid: "one", appName: extractAppName(desc: "placeholder", title: "missing", body: ""))
        let success = Banner(uuid: "one", appName: extractAppName(desc: "App、title", title: "title", body: ""))
        return !seen.accept(failed) && seen.accept(success)
    }
]
