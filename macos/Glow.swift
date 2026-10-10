import Cocoa

let glowOpacity: CGFloat = 0.8 // PoC-derived estimate; not calibrated on hardware.

enum GlowStyle: String {
    case soft, breath, orbit, corner

    // Seconds per repetition. Taken from the design mock; not calibrated on hardware.
    var cycle: Double {
        switch self {
        case .soft: return 0.9
        case .breath: return 1.6
        case .orbit: return 1.6
        case .corner: return 1.5
        }
    }
}

func glowStyle(_ name: String?) -> GlowStyle {
    GlowStyle(rawValue: name ?? "") ?? .soft
}

// Why: One multiplier scales every style's lengths (glow radius, gradient depth, band width) alike; out of range falls back to 1 like count.
func glowSize(_ value: Double?) -> CGFloat {
    guard let value, (0.25...5).contains(value) else { return 1 }
    return CGFloat(value)
}

func flashCount(count: Int, reduceMotion: Bool) -> Int {
    reduceMotion ? 1 : max(0, count)
}

func glowDuration(style: GlowStyle, count: Int) -> Double {
    style.cycle * Double(count)
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

// Inner glow: the shadow of a ring lying just outside the screen bleeds inward.
private func innerGlow(_ bounds: CGRect, color: CGColor, radius: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = bounds
    let outer = CGPath(rect: bounds.insetBy(dx: -radius * 3, dy: -radius * 3), transform: nil)
    layer.shadowPath = outer.subtracting(CGPath(rect: bounds, transform: nil))
    layer.shadowColor = color
    layer.shadowOpacity = 1
    layer.shadowRadius = radius
    layer.shadowOffset = .zero
    return layer
}

private func softGlow(_ bounds: CGRect, color: CGColor, size: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = bounds
    layer.addSublayer(innerGlow(bounds, color: color, radius: 40 * size))
    layer.addSublayer(innerGlow(bounds, color: color, radius: 8 * size))
    return layer
}

// Four gradients fading from each edge toward the center. The layer is not flipped: y = 1 is the top.
private func edgeGradients(_ b: CGRect, color: CGColor, depth: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = b
    let clear = color.copy(alpha: 0) ?? color
    let edges: [(CGRect, CGPoint, CGPoint)] = [
        (CGRect(x: 0, y: b.height - depth, width: b.width, height: depth), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
        (CGRect(x: 0, y: 0, width: b.width, height: depth), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
        (CGRect(x: 0, y: 0, width: depth, height: b.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
        (CGRect(x: b.width - depth, y: 0, width: depth, height: b.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
    ]
    for (frame, start, end) in edges {
        let gradient = CAGradientLayer()
        gradient.frame = frame
        gradient.colors = [color, clear]
        gradient.startPoint = start
        gradient.endPoint = end
        layer.addSublayer(gradient)
    }
    return layer
}

// Opacity rises from 0 to peak and falls back once per cycle, repeated count times.
private func pulse(count: Int, cycle: Double, rise: Double, peak: Float) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    var values: [Float] = []
    var times: [NSNumber] = []
    for i in 0..<count {
        let base = Double(i) / Double(count)
        values += [0, peak, 0]
        times += [base, base + rise / Double(count), base + 1 / Double(count)].map { NSNumber(value: $0) }
    }
    animation.values = values
    animation.keyTimes = times
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
    animation.duration = cycle * Double(count)
    return animation
}

private func glowLayer(style: GlowStyle, bounds b: CGRect, color: CGColor, count: Int, size: CGFloat) -> CALayer {
    let black = CGColor(gray: 0, alpha: 1)
    let layer: CALayer
    switch style {
    case .soft:
        layer = softGlow(b, color: color, size: size)
        layer.add(pulse(count: count, cycle: style.cycle, rise: 1.0 / 3, peak: 1), forKey: "glow")
    case .breath:
        layer = edgeGradients(b, color: color, depth: 160 * size)
        layer.add(pulse(count: count, cycle: style.cycle, rise: 0.5, peak: 0.85), forKey: "glow")
    case .orbit:
        layer = CALayer()
        layer.frame = b
        let side = hypot(b.width, b.height)
        let clear = color.copy(alpha: 0) ?? color
        let conic = CAGradientLayer()
        conic.type = .conic
        conic.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        conic.position = CGPoint(x: b.midX, y: b.midY)
        conic.startPoint = CGPoint(x: 0.5, y: 0.5)
        conic.endPoint = CGPoint(x: 0.5, y: 0)
        conic.colors = [color, clear, clear, color, clear, clear, color]
        conic.locations = [0, 0.2, 0.3, 0.5, 0.7, 0.8, 1]
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = style.cycle
        spin.repeatCount = Float(count)
        conic.add(spin, forKey: "spin")
        layer.addSublayer(conic)
        // Why: Gradient edges as the mask keep the band soft without Core Image filters.
        layer.mask = edgeGradients(b, color: black, depth: 36 * size)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 1]
        fade.duration = glowDuration(style: style, count: count)
        layer.add(fade, forKey: "glow")
    case .corner:
        layer = softGlow(b, color: color, size: size)
        let diameter = hypot(b.width, b.height) * 2
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        mask.position = CGPoint(x: b.maxX, y: b.maxY)
        mask.colors = [black, black, CGColor(gray: 0, alpha: 0)]
        mask.locations = [0, 0.75, 1]
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        let spread = CAKeyframeAnimation(keyPath: "transform.scale")
        spread.values = [0.01, 1, 1]
        spread.keyTimes = [0, 0.6, 1]
        spread.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
        spread.duration = style.cycle
        spread.repeatCount = Float(count)
        mask.add(spread, forKey: "spread")
        layer.mask = mask
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.6, 1]
        fade.duration = style.cycle
        fade.repeatCount = Float(count)
        layer.add(fade, forKey: "glow")
    }
    // Why: The model value stays 0 so nothing remains visible if the animation ends before the window hides.
    layer.opacity = 0
    return layer
}

func flash(color: NSColor, count: Int, style: GlowStyle = .soft, size: CGFloat = 1) {
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
        glowWindow = window
    }
    glowWindow?.setFrame(screen.frame, display: false)
    guard let root = glowWindow?.contentView?.layer else { return }
    let n = flashCount(count: count, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    guard n > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    root.sublayers?.forEach { $0.removeFromSuperlayer() }
    let layer = glowLayer(style: style, bounds: CGRect(origin: .zero, size: screen.frame.size),
                          color: color.withAlphaComponent(glowOpacity).cgColor, count: n, size: size)
    root.addSublayer(layer)
    CATransaction.commit()
    glowWindow?.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + glowDuration(style: style, count: n)) {
        guard generation == glowGeneration else { return }
        glowWindow?.orderOut(nil)
        layer.removeFromSuperlayer()
    }
}

func hideGlow() {
    glowGeneration += 1
    glowWindow?.orderOut(nil)
    glowWindow?.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
}

let glowSelfTests: [String: () -> Bool] = [
    "C3": {
        for (count, reduceMotion, expected) in [(3, false, 3), (1, false, 1), (3, true, 1), (0, false, 0)] {
            guard flashCount(count: count, reduceMotion: reduceMotion) == expected else { return false }
        }
        return abs(glowDuration(style: .soft, count: 3) - 2.7) < 1e-9
            && abs(glowDuration(style: .breath, count: 2) - 3.2) < 1e-9
    },
    "C4": {
        glowOpacity == 0.8 && glowStyle(nil) == .soft && glowStyle("bad") == .soft
            && glowStyle("breath") == .breath && glowStyle("orbit") == .orbit && glowStyle("corner") == .corner
            && glowSize(nil) == 1 && glowSize(2) == 2 && glowSize(0.25) == 0.25 && glowSize(5) == 5
            && glowSize(0.1) == 1 && glowSize(6) == 1
    },
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
