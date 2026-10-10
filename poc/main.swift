import Cocoa

let ncBundleID = "com.apple.notificationcenterui"
let maxDepth = 10

func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

// The identifying attribute is unknown, so print every attribute instead of a guessed list.
func describe(_ v: CFTypeRef) -> String {
    switch CFGetTypeID(v) {
    case CFStringGetTypeID(): return "\"\(v as! String)\""
    case CFAttributedStringGetTypeID(): return "attr\"\(CFAttributedStringGetString((v as! CFAttributedString)) as String)\""
    case CFNumberGetTypeID(), CFBooleanGetTypeID(): return "\(v)"
    case AXValueGetTypeID(): return "\(v)".components(separatedBy: "{value = ").last.map { "{" + $0 } ?? "\(v)"
    case CFArrayGetTypeID(): return "<array \(CFArrayGetCount((v as! CFArray)))>"
    default: return "<\(CFCopyTypeIDDescription(CFGetTypeID(v)) as String)>"
    }
}

func dump(_ e: AXUIElement, depth: Int = 0) {
    let pad = String(repeating: "  ", count: depth)
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(e, &names) == .success, let list = names as? [String] else {
        print(pad + "(element gone or unreadable)")
        return
    }
    // Attributes can answer without being listed; probe the ones that might carry the app identity.
    let probes = ["AXDescription", "AXStackingIdentifier", "AXBundleIdentifier"].filter { !list.contains($0) && value(e, $0) != nil }
    let attrs = (list + probes).filter { $0 != kAXChildrenAttribute }
        .map { n in "\(n)=\(value(e, n).map(describe) ?? "nil")" }
    print(pad + "- " + attrs.joined(separator: " | "))
    var actions: CFArray?
    if AXUIElementCopyActionNames(e, &actions) == .success, let a = actions as? [String], !a.isEmpty {
        print(pad + "  actions: \(a)")
    }
    guard depth < maxDepth, let kids = value(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    // NC's menu bar is ~380 lines of the Apple menu and unrelated to banners.
    for k in kids where value(k, kAXRoleAttribute) as? String != kAXMenuBarRole { dump(k, depth: depth + 1) }
}

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let prompt = args.contains("--prompt")
let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
print("AX trusted: \(trusted) (prompt=\(prompt))")
if !trusted {
    print("""
    Accessibility permission is not granted to the app hosting this process.
      1. Run once with --prompt to show the system dialog, or open
         System Settings > Privacy & Security > Accessibility.
      2. Enable the terminal app you run this from (Terminal / iTerm / Ghostty ...).
         TCC attributes the permission to that app, not to this binary.
      3. Quit and reopen the terminal app, then rerun.
    """)
    exit(1)
}

guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: ncBundleID).first else {
    print("no running process with bundle id \(ncBundleID)")
    exit(2)
}
let pid = nc.processIdentifier
print("NotificationCenter pid=\(pid) name=\(nc.localizedName ?? "?")")

let root = AXUIElementCreateApplication(pid)
print("=== initial tree")
dump(root)

var observer: AXObserver?
let callback: AXObserverCallback = { _, element, notification, _ in
    print("=== \(Date()) \(notification)")
    dump(element)
}
guard AXObserverCreate(pid, callback, &observer) == .success, let obs = observer else {
    print("AXObserverCreate failed")
    exit(3)
}
for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification] {
    print("subscribe \(n): AXError \(AXObserverAddNotification(obs, root, n as CFString, nil).rawValue)")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
print("listening\(seconds.map { " for \($0)s" } ?? ", Ctrl-C to stop")")
if let s = seconds {
    CFRunLoopRunInMode(.defaultMode, s, false)
} else {
    CFRunLoopRun()
}
