import Cocoa

let glowBorderWidth: CGFloat = 6 // PoC-derived estimate; not calibrated on hardware.
let glowOpacity: CGFloat = 0.8 // PoC-derived estimate; not calibrated on hardware.
let glowOnMilliseconds = 150 // PoC-derived estimate; not calibrated on hardware.
let glowOffMilliseconds = 250 // PoC-derived estimate; not calibrated on hardware.

func flashSchedule(count: Int, reduceMotion: Bool) -> [(on: Int, off: Int)] {
    Array(repeating: (on: glowOnMilliseconds, off: glowOffMilliseconds), count: reduceMotion ? 1 : max(0, count))
}

func axToScreenPoint(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: p.x, y: primaryHeight - p.y)
}

func pickScreen(point: CGPoint?, frames: [CGRect]) -> Int {
    guard let point = point else { return 0 }
    return frames.firstIndex(where: { $0.contains(point) }) ?? 0
}

func parseHexColor(_ s: String) -> NSColor? {
    let bytes = Array(s.utf8)
    guard bytes.count == 7, bytes[0] == 35,
          bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
          let rgb = UInt32(s.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                   green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

private var glowWindow: NSWindow?
private var glowGeneration = 0

private func glowAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func focusedScreenIndex() -> Int {
    let frames = NSScreen.screens.map(\.frame)
    guard let primary = frames.first,
          let appValue = glowAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
          CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return pickScreen(point: nil, frames: frames) }
    let app = unsafeBitCast(appValue, to: AXUIElement.self)
    guard let windowValue = glowAttribute(app, kAXFocusedWindowAttribute),
          CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return pickScreen(point: nil, frames: frames) }
    let window = unsafeBitCast(windowValue, to: AXUIElement.self)
    guard let positionValue = glowAttribute(window, kAXPositionAttribute),
          let sizeValue = glowAttribute(window, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return pickScreen(point: nil, frames: frames) }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
        return pickScreen(point: nil, frames: frames)
    }
    let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    return pickScreen(point: axToScreenPoint(center, primaryHeight: primary.height), frames: frames)
}

func flash(color: NSColor, count: Int) {
    glowGeneration += 1
    let generation = glowGeneration
    glowWindow?.orderOut(nil)
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let screen = screens[focusedScreenIndex()]
    if glowWindow == nil {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.borderWidth = glowBorderWidth
        glowWindow = window
    }
    glowWindow?.setFrame(screen.frame, display: false)
    glowWindow?.contentView?.layer?.borderColor = color.withAlphaComponent(glowOpacity).cgColor
    let schedule = flashSchedule(count: count, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    var offset = 0
    for step in schedule {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offset)) {
            guard generation == glowGeneration else { return }
            glowWindow?.orderFrontRegardless()
        }
        offset += step.on
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offset)) {
            guard generation == glowGeneration else { return }
            glowWindow?.orderOut(nil)
        }
        offset += step.off
    }
}

func hideGlow() {
    glowGeneration += 1
    glowWindow?.orderOut(nil)
}

let glowSelfTests: [String: () -> Bool] = [
    "C3": {
        for (count, reduceMotion, expectedCount) in [(3, false, 3), (1, false, 1), (3, true, 1)] {
            let schedule = flashSchedule(count: count, reduceMotion: reduceMotion)
            guard schedule.count == expectedCount,
                  schedule.allSatisfy({ $0.on == 150 && $0.off == 250 }) else { return false }
        }
        return true
    },
    "C4": { glowBorderWidth == 6 && glowOpacity == 0.8 },
    "S1": {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 800, width: 1000, height: 600)]
        let above = axToScreenPoint(CGPoint(x: 500, y: -300), primaryHeight: 800)
        let primary = axToScreenPoint(CGPoint(x: 500, y: 400), primaryHeight: 800)
        let horizontal = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 100, height: 100)]
        return above == CGPoint(x: 500, y: 1100) && pickScreen(point: above, frames: frames) == 1
            && primary == CGPoint(x: 500, y: 400) && pickScreen(point: primary, frames: frames) == 0
            && pickScreen(point: CGPoint(x: 250, y: 50), frames: horizontal) == 1
    },
    "S2": {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 800, width: 1000, height: 600)]
        return pickScreen(point: nil, frames: frames) == 0
            && pickScreen(point: CGPoint(x: -1, y: 400), frames: frames) == 0
            && pickScreen(point: CGPoint(x: 500, y: 2000), frames: frames) == 0
    }
]
