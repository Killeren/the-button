import AppKit

// MARK: - Claude Code palette

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

enum Palette {
    static let coral    = NSColor(hex: 0xD97757) // Claude brand coral
    static let bg       = NSColor(hex: 0x262624) // warm dark background
    static let bgRaised = NSColor(hex: 0x33322F)
    static let btn      = NSColor(hex: 0x3A3937)
    static let cream    = NSColor(hex: 0xF0EEE6) // primary text
    static let code     = NSColor(hex: 0xDCD9CF) // detail/code text
    static let dim      = NSColor(hex: 0xA8A69E) // secondary text
    static let border   = NSColor(hex: 0x45443F)
    static let ink      = NSColor(hex: 0x1F1D1A) // text on coral
    static let hairline = NSColor.white.withAlphaComponent(0.12)
}

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

enum Metrics {
    static let panelWidth: CGFloat = 320
    static let cardGap: CGFloat = 8      // 0 = single-plate fallback if island shadows artifact
    static let cardRadius: CGFloat = 14
    static let maxCards = 4
    static let contentInsetX: CGFloat = 14
    static let contentInsetY: CGFloat = 12
}

// MARK: - Motion

enum Anim {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func dur(_ d: TimeInterval) -> TimeInterval { reduceMotion ? 0.01 : d }

    static func spring(_ keyPath: String, from: Any?, to: Any?,
                       stiffness: CGFloat = 380, damping: CGFloat = 26) -> CAAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.stiffness = stiffness
        s.damping = damping
        s.mass = 1
        s.fromValue = from
        s.toValue = to
        s.duration = s.settlingDuration
        return s
    }
}

/// Scale about the view's center: NSView layers anchor at (0,0), so a bare
/// scale would grow from the bottom-left corner.
func centeredScale(_ scale: CGFloat, dy: CGFloat = 0, in bounds: NSRect) -> CATransform3D {
    let w = bounds.width / 2, h = bounds.height / 2
    var t = CATransform3DMakeTranslation(w, h + dy, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    t = CATransform3DTranslate(t, -w, -h, 0)
    return t
}

// MARK: - Session identity

/// Stable across launches (String.hashValue is per-launch randomized).
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

func sessionAccent(for sessionId: String) -> NSColor {
    guard !sessionId.isEmpty else { return Palette.coral }
    let hue = CGFloat(fnv1a(sessionId) % 360) / 360.0
    return NSColor(hue: hue, saturation: 0.55, brightness: 0.90, alpha: 1)
}

// MARK: - Tool icons

func toolSymbolName(for event: ButtonEvent) -> String {
    if event.type != "permission" { return "clock" }
    let t = event.toolName.lowercased()
    if t.hasPrefix("mcp__") { return "puzzlepiece.extension" }
    switch true {
    case t.contains("bash") || t.contains("shell"):        return "terminal"
    case t == "edit" || t == "write" || t == "multiedit"
        || t == "notebookedit":                            return "pencil"
    case t == "read":                                      return "doc.text"
    case t.hasPrefix("web"):                               return "globe"
    case t == "grep" || t == "glob":                       return "magnifyingglass"
    case t == "task" || t.contains("agent"):               return "sparkles"
    case t.isEmpty:                                        return "shield.lefthalf.filled"
    default:                                               return "shield.lefthalf.filled"
    }
}

func toolSymbolImage(for event: ButtonEvent) -> NSImage? {
    let image = NSImage(systemSymbolName: toolSymbolName(for: event),
                        accessibilityDescription: event.toolName)
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    return image?.withSymbolConfiguration(config)
}

// MARK: - Vibrancy helpers

/// Stretched-cap mask image: the documented-safe way to round an
/// NSVisualEffectView (layer cornerRadius does not clip the blur).
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}
