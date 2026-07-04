import AppKit
import ApplicationServices

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
}

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

// MARK: - Event model

struct ButtonEvent: Equatable {
    let type: String        // "permission" | "notify" | "clear"
    let message: String
    let sessionId: String
    let claudePid: Int32
    let ancestors: [Int32]
    let tty: String         // e.g. /dev/ttys003 — the session's terminal device
    let cwd: String         // the claude session's working directory
    let toolName: String
    let detail: String      // command / file path being approved
    let ts: Double
}

func loadEvent(from url: URL) -> ButtonEvent? {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ButtonEvent(
        type: obj["type"] as? String ?? "clear",
        message: obj["message"] as? String ?? "",
        sessionId: obj["session_id"] as? String ?? "",
        claudePid: Int32(obj["claude_pid"] as? Int ?? 0),
        ancestors: (obj["ancestors"] as? [Any] ?? []).compactMap { ($0 as? Int).map(Int32.init) },
        tty: obj["tty"] as? String ?? "",
        cwd: obj["cwd"] as? String ?? "",
        toolName: obj["tool_name"] as? String ?? "",
        detail: obj["detail"] as? String ?? "",
        ts: obj["ts"] as? Double ?? 0
    )
}

// MARK: - Process helpers

func processAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// First ancestor of the claude process that is a real GUI app
/// (Terminal, iTerm2, VS Code, Ghostty, ...) — the app hosting the session.
func hostApp(forAncestors pids: [Int32]) -> NSRunningApplication? {
    for pid in pids {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular {
            return app
        }
    }
    return nil
}

/// Activate reliably. Plain activate() from a background accessory app is
/// silently declined under macOS 14+ cooperative activation, so also set the
/// AX "frontmost" attribute, which is not subject to those rules.
func bringToFront(_ app: NSRunningApplication?) {
    guard let app else { return }
    if AXIsProcessTrusted() {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return (-1, "") }
    process.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Keystrokes

// Claude Code dialog keys: Enter confirms the highlighted option (the first,
// "Yes", on a fresh prompt); Esc declines. Both are documented keybindings.
let KEY_RETURN: CGKeyCode = 36
let KEY_ESC: CGKeyCode = 53

func postKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

// MARK: - Background responders (answer without touching window focus)

let resolvedTmux: String? = {
    for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                 "/opt/local/bin/tmux", "/usr/bin/tmux"] {
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    // Last resort: the user's login-shell PATH (covers unusual installs).
    let (status, output) = runProcess("/bin/zsh", ["-lc", "command -v tmux"])
    let found = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return status == 0 && !found.isEmpty ? found : nil
}()

/// The tmux pane owning this tty, if any (default server socket only).
func tmuxPane(forTty tty: String) -> String? {
    guard !tty.isEmpty, let tmux = resolvedTmux else { return nil }
    let (status, output) = runProcess(tmux, ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}"])
    guard status == 0 else { return nil }
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t")
        if parts.count == 2, parts[0] == tty[...] { return String(parts[1]) }
    }
    return nil
}

func tmuxSend(pane: String, allow: Bool) -> Bool {
    guard let tmux = resolvedTmux else { return false }
    return runProcess(tmux, ["send-keys", "-t", pane, allow ? "Enter" : "Escape"]).status == 0
}

/// iTerm2 can write to a session by tty without any focus change.
func respondViaITerm(tty: String, allow: Bool) -> Bool {
    guard !tty.isEmpty else { return false }
    // Allow: bare newline (Enter). Deny: a raw Esc byte, no newline.
    let writeLine = allow
        ? "tell s to write text \"\""
        : "tell s to write text (character id 27) newline NO"
    let script = """
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                        \(writeLine)
                        return "ok"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return "notfound"
    """
    let (status, output) = runProcess("/usr/bin/osascript", ["-e", script])
    return status == 0 && output.contains("ok")
}

/// Terminal.app: select the window+tab whose tty matches, so the keystroke
/// lands in the right session even with many tabs open.
func selectTerminalTab(tty: String) -> Bool {
    guard !tty.isEmpty else { return false }
    let script = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set selected of t to true
                    set frontmost of w to true
                    return "ok"
                end if
            end repeat
        end repeat
    end tell
    return "notfound"
    """
    let (status, output) = runProcess("/usr/bin/osascript", ["-e", script])
    return status == 0 && output.contains("ok")
}

// MARK: - Accessibility window targeting (editors: VS Code, Cursor, ...)

func axAppElement(_ pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.3) // never hang on a busy app
    return element
}

func axWindows(pid: pid_t) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axAppElement(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let array = value as? NSArray else { return [] }
    return array.compactMap { item in
        let element = item as CFTypeRef
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let window = element as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.3)
        return window
    }
}

func axTitle(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

func windowTitles(pid: pid_t) -> [String] {
    axWindows(pid: pid).compactMap(axTitle(of:))
}

func focusedWindowTitle(pid: pid_t) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axAppElement(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
          let ref = value, CFGetTypeID(ref) == AXUIElementGetTypeID()
    else { return nil }
    let window = ref as! AXUIElement
    AXUIElementSetMessagingTimeout(window, 0.3)
    return axTitle(of: window)
}

/// Raise the host app window whose title mentions the session's folder,
/// so the answer keystroke lands in the right editor window.
@discardableResult
func raiseWindow(pid: pid_t, matching needle: String) -> Bool {
    guard !needle.isEmpty else { return false }
    for window in axWindows(pid: pid) {
        if let title = axTitle(of: window), title.localizedCaseInsensitiveContains(needle) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axAppElement(pid), kAXFocusedWindowAttribute as CFString, window)
            return true
        }
    }
    return false
}

// MARK: - Views

final class CardView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PillButton: NSButton {
    private var hovering = false
    private let fillColor: NSColor
    private let labelColor: NSColor
    private let hoverLabelColor: NSColor?
    private let fontSize: CGFloat

    init(title: String, fill: NSColor, text: NSColor,
         hoverText: NSColor? = nil, height: CGFloat = 30, fontSize: CGFloat = 12) {
        fillColor = fill
        labelColor = text
        hoverLabelColor = hoverText
        self.fontSize = fontSize
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = min(7, height / 2)
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        let fill = hovering && fillColor != .clear
            ? (fillColor.blended(withFraction: 0.14, of: .white) ?? fillColor)
            : fillColor
        layer?.backgroundColor = fill.cgColor
        let textColor = hovering ? (hoverLabelColor ?? labelColor) : labelColor
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: mono(fontSize, .semibold),
            .foregroundColor: isEnabled ? textColor : textColor.withAlphaComponent(0.4),
            .paragraphStyle: ps,
        ])
    }

    override var isEnabled: Bool { didSet { refresh() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let panelWidth: CGFloat = 300
    let eventURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/the_button/event.json")
    let axQueue = DispatchQueue(label: "the-button.ax", qos: .userInteractive)

    var panel: NSPanel!
    var card: CardView!
    var titleLabel: NSTextField!
    var messageLabel: NSTextField!
    var detailBox: NSView!
    var detailLabel: NSTextField!
    var buttonRow: NSStackView!
    var allowButton: PillButton!
    var denyButton: PillButton!
    var openButton: PillButton!
    var closeButton: PillButton!

    var current: ButtonEvent?
    var handledTs: Double = 0
    var lastMtime: Date?
    var isShown = false
    var isRepositioning = false
    var isTest = false
    var respondInFlight = false
    var hideProbeInFlight = false
    var cachedHide = true
    var cachedHideKey = ""
    let isDebug = CommandLine.arguments.contains("--debug")

    enum SendOutcome {
        case sent(String)       // delivered in the background (tmux/iTerm2)
        case needsFocus         // must focus the host window and type
        case failed(String)     // do NOT type blind; keep the prompt and explain
    }

    func dbg(_ msg: String) {
        if isDebug { FileHandle.standardError.write(Data(("[tb] " + msg + "\n").utf8)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()

        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }

        if CommandLine.arguments.contains("--test") {
            isTest = true
            current = ButtonEvent(type: "permission",
                                  message: "Claude needs your permission to use Bash",
                                  sessionId: "test", claudePid: getpid(),
                                  ancestors: [], tty: "", cwd: "/tmp/demo-project",
                                  toolName: "Bash",
                                  detail: "git push origin main --force-with-lease",
                                  ts: 1)
            configureUI(for: current!)
        }

        let timer = Timer(timeInterval: 0.25, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    // MARK: UI construction

    func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        card = CardView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.bg.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.border.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let spark = NSTextField(labelWithString: "\u{2733}")
        spark.font = mono(12, .bold)
        spark.textColor = Palette.coral

        let brand = NSTextField(labelWithString: "Claude Code")
        brand.font = mono(11, .semibold)
        brand.textColor = Palette.coral

        let grip = NSTextField(labelWithString: "\u{22EE}\u{22EE}")
        grip.font = mono(10)
        grip.textColor = Palette.dim.withAlphaComponent(0.6)
        grip.toolTip = "Drag anywhere to reposition"

        closeButton = PillButton(title: "\u{2715}", fill: .clear, text: Palette.dim,
                                 hoverText: Palette.cream, height: 18, fontSize: 11)
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        closeButton.toolTip = "Dismiss this prompt (answer it in the terminal)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let header = NSStackView(views: [spark, brand, NSView(), grip, closeButton])
        header.orientation = .horizontal
        header.spacing = 6

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = mono(13, .semibold)
        titleLabel.textColor = Palette.cream
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = mono(11)
        messageLabel.textColor = Palette.dim
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = panelWidth - 28
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = mono(10.5)
        detailLabel.textColor = Palette.code
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.maximumNumberOfLines = 4
        detailLabel.preferredMaxLayoutWidth = panelWidth - 28 - 18
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        detailBox = NSView()
        detailBox.wantsLayer = true
        detailBox.layer?.backgroundColor = Palette.bgRaised.cgColor
        detailBox.layer?.cornerRadius = 6
        detailBox.translatesAutoresizingMaskIntoConstraints = false
        detailBox.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 9),
            detailLabel.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -9),
            detailLabel.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -7),
        ])

        allowButton = PillButton(title: "Allow", fill: Palette.coral, text: Palette.ink)
        allowButton.target = self
        allowButton.action = #selector(allowClicked)

        denyButton = PillButton(title: "Deny", fill: Palette.btn, text: Palette.cream)
        denyButton.target = self
        denyButton.action = #selector(denyClicked)

        openButton = PillButton(title: "Go to Claude", fill: Palette.btn, text: Palette.coral)
        openButton.target = self
        openButton.action = #selector(openClicked)

        buttonRow = NSStackView(views: [allowButton, denyButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8

        let stack = NSStackView(views: [header, titleLabel, messageLabel, detailBox, buttonRow, openButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: panelWidth),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            openButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        panel.contentView = card
    }

    func configureUI(for event: ButtonEvent) {
        setButtonsEnabled(!respondInFlight)
        if event.type == "permission" {
            let tool = event.toolName.isEmpty ? toolName(from: event.message) : event.toolName
            titleLabel.stringValue = tool.map { "Permission: \($0)" } ?? "Permission required"
            if event.detail.isEmpty {
                detailBox.isHidden = true
                messageLabel.isHidden = false
                messageLabel.stringValue = event.message.isEmpty
                    ? "Claude is asking for permission" : event.message
            } else {
                detailLabel.stringValue = event.detail
                detailBox.isHidden = false
                messageLabel.isHidden = true
            }
            buttonRow.isHidden = false
            openButton.isHidden = true
        } else {
            titleLabel.stringValue = "Waiting for you"
            messageLabel.stringValue = event.message.isEmpty
                ? "Claude is waiting for your input" : event.message
            messageLabel.isHidden = false
            detailBox.isHidden = true
            buttonRow.isHidden = true
            openButton.isHidden = false
        }
        resizePanel()
    }

    func resizePanel() {
        card.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: panelWidth, height: card.fittingSize.height))
    }

    func toolName(from message: String) -> String? {
        guard let range = message.range(of: "permission to use ") else { return nil }
        let name = String(message[range.upperBound...])
        return name.isEmpty ? nil : name
    }

    func sessionNeedle(_ event: ButtonEvent) -> String {
        (event.cwd as NSString).lastPathComponent
    }

    func setButtonsEnabled(_ enabled: Bool) {
        allowButton.isEnabled = enabled
        denyButton.isEnabled = enabled
        openButton.isEnabled = enabled
    }

    // MARK: State loop

    @objc func tick() {
        if !isTest {
            let mtime = (try? FileManager.default
                .attributesOfItem(atPath: eventURL.path)[.modificationDate]) as? Date
            if let mtime, mtime != lastMtime {
                lastMtime = mtime
                let event = loadEvent(from: eventURL)
                dbg("file changed, event=\(String(describing: event))")
                if let event {
                    if event.type == "clear" {
                        if shouldApplyClear(event) { current = nil }
                    } else if event.ts == handledTs {
                        // already answered from the panel; ignore re-reads
                    } else {
                        current = event
                        configureUI(for: event)
                    }
                }
            }
            if let event = current, event.claudePid > 0, !processAlive(event.claudePid) {
                dbg("claude pid \(event.claudePid) dead, dropping event")
                current = nil // session is gone; drop the stale prompt
            }
        }

        var show = false
        if let event = current {
            show = !shouldHideForFrontmost(event)
        }
        setVisible(show)
    }

    /// A malformed clear (no session) or one from a different session must
    /// not dismiss a pending prompt (backstop for hook-side races).
    func shouldApplyClear(_ clear: ButtonEvent) -> Bool {
        guard let cur = current else { return true }
        guard !clear.sessionId.isEmpty else { return false }
        return cur.sessionId.isEmpty || cur.sessionId == clear.sessionId
    }

    /// Hide only while the user is actually looking at the session:
    /// same app AND (when the app has several windows we can tell apart)
    /// the focused window is the session's window. AX probing runs off the
    /// main thread with short timeouts so a beachballing editor can never
    /// freeze the panel.
    func shouldHideForFrontmost(_ event: ButtonEvent) -> Bool {
        guard let host = hostApp(forAncestors: event.ancestors),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == host.processIdentifier
        else { return false }

        let needle = sessionNeedle(event)
        guard !needle.isEmpty, AXIsProcessTrusted() else { return true }

        let key = "\(host.processIdentifier)|\(needle)"
        if key != cachedHideKey {
            cachedHideKey = key
            cachedHide = true // conservative until the first probe lands
        }
        if !hideProbeInFlight {
            hideProbeInFlight = true
            let pid = host.processIdentifier
            axQueue.async { [weak self] in
                let titles = windowTitles(pid: pid)
                var hide = true
                if titles.count > 1,
                   titles.contains(where: { $0.localizedCaseInsensitiveContains(needle) }),
                   let focused = focusedWindowTitle(pid: pid) {
                    hide = focused.localizedCaseInsensitiveContains(needle)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.cachedHideKey == key { self.cachedHide = hide }
                    self.hideProbeInFlight = false
                }
            }
        }
        return cachedHide
    }

    func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        if visible {
            positionPanel()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if !self.isShown { self.panel.orderOut(nil) }
            })
        }
    }

    // MARK: Positioning (fraction of the screen, follows the mouse's screen)

    var screenWithMouse: NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
    }

    func positionPanel() {
        guard let screen = screenWithMouse ?? panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let defaults = UserDefaults.standard
        let fx = min(max(defaults.object(forKey: "tb.fx") as? Double ?? 0.97, 0), 1)
        let fy = min(max(defaults.object(forKey: "tb.fy") as? Double ?? 0.85, 0), 1)
        let size = panel.frame.size
        isRepositioning = true
        panel.setFrameOrigin(NSPoint(
            x: vf.minX + (vf.width - size.width) * fx,
            y: vf.minY + (vf.height - size.height) * fy))
        isRepositioning = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRepositioning, panel.isVisible, let screen = panel.screen else { return }
        let vf = screen.visibleFrame
        let frame = panel.frame
        let denomX = vf.width - frame.width
        let denomY = vf.height - frame.height
        guard denomX > 0, denomY > 0 else { return }
        UserDefaults.standard.set(Double((frame.minX - vf.minX) / denomX), forKey: "tb.fx")
        UserDefaults.standard.set(Double((frame.minY - vf.minY) / denomY), forKey: "tb.fy")
    }

    // MARK: Actions

    @objc func allowClicked() { respond(allow: true) }
    @objc func denyClicked() { respond(allow: false) }

    @objc func closeClicked() {
        guard let event = current else { setVisible(false); return }
        markHandled(event) // dismiss this prompt only; the next one shows again
    }

    @objc func openClicked() {
        guard let event = current else { setVisible(false); return }
        let host = hostApp(forAncestors: event.ancestors)
        DispatchQueue.global(qos: .userInitiated).async {
            if host?.bundleIdentifier == "com.apple.Terminal" {
                _ = selectTerminalTab(tty: event.tty)
            }
            DispatchQueue.main.async {
                if let host, host.bundleIdentifier != "com.apple.Terminal", AXIsProcessTrusted() {
                    raiseWindow(pid: host.processIdentifier, matching: self.sessionNeedle(event))
                }
                bringToFront(host)
                // No handled-marking: the frontmost check hides the panel, and
                // it comes back if the user leaves without answering.
            }
        }
    }

    func respond(allow: Bool) {
        guard !respondInFlight, let event = current else { return }
        if isTest { markHandled(event); return }
        respondInFlight = true
        setButtonsEnabled(false)
        let host = hostApp(forAncestors: event.ancestors)
        let previous = NSWorkspace.shared.frontmostApplication

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // The prompt may get answered in the terminal while we work; check
            // right before irreversibly sending anything.
            let stillCurrent = { DispatchQueue.main.sync { self.current?.ts == event.ts } }

            let outcome: SendOutcome
            let bundle = host?.bundleIdentifier
            if let pane = tmuxPane(forTty: event.tty) {
                if !stillCurrent() {
                    outcome = .sent("nothing — prompt was already resolved")
                } else if tmuxSend(pane: pane, allow: allow) {
                    outcome = .sent("tmux pane \(pane)")
                } else {
                    outcome = .failed("Couldn't write to the tmux pane — answer in the terminal.")
                }
            } else if bundle == "com.googlecode.iterm2" {
                if !stillCurrent() {
                    outcome = .sent("nothing — prompt was already resolved")
                } else if respondViaITerm(tty: event.tty, allow: allow) {
                    outcome = .sent("iTerm2 session \(event.tty)")
                } else {
                    outcome = .failed("Couldn't write to the iTerm2 session — allow Automation for TheButton in System Settings.")
                }
            } else if bundle == "com.apple.Terminal" {
                outcome = selectTerminalTab(tty: event.tty)
                    ? .needsFocus
                    : .failed("Couldn't find the Terminal tab — allow Automation for TheButton in System Settings.")
            } else if host != nil {
                outcome = .needsFocus
            } else {
                outcome = .failed("Couldn't identify the app hosting this session — answer in the terminal.")
            }

            DispatchQueue.main.async {
                self.finishRespond(event: event, allow: allow, host: host,
                                   previous: previous, outcome: outcome)
            }
        }
    }

    func finishRespond(event: ButtonEvent, allow: Bool, host: NSRunningApplication?,
                       previous: NSRunningApplication?, outcome: SendOutcome) {
        switch outcome {
        case .sent(let how):
            dbg("answered via \(how)")
            respondInFlight = false
            markHandled(event)
            if let cur = current { configureUI(for: cur) } // a newer prompt is pending

        case .failed(let why):
            dbg("respond failed: \(why)")
            respondInFlight = false
            showIssue(why, for: event)

        case .needsFocus:
            guard AXIsProcessTrusted() else {
                respondInFlight = false
                showAccessibilityHint()
                return
            }
            if let host, host.bundleIdentifier != "com.apple.Terminal" {
                raiseWindow(pid: host.processIdentifier, matching: sessionNeedle(event))
            }
            bringToFront(host)
            // NEVER type blind: verify the host actually became frontmost, and
            // that the prompt still exists, before posting the key.
            waitForFrontmost(host: host, attempts: 12) { [weak self] focused in
                guard let self else { return }
                self.respondInFlight = false
                guard self.current?.ts == event.ts else { return } // resolved meanwhile
                guard focused else {
                    self.showIssue("Couldn't focus \(host?.localizedName ?? "the app") — click again or answer in the terminal.", for: event)
                    return
                }
                postKey(allow ? KEY_RETURN : KEY_ESC)
                self.dbg("answered via keystroke to \(host?.localizedName ?? "?")")
                self.markHandled(event)
                if let previous, previous.processIdentifier != host?.processIdentifier {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        bringToFront(previous)
                    }
                }
            }
        }
    }

    func waitForFrontmost(host: NSRunningApplication?, attempts: Int,
                          then: @escaping (Bool) -> Void) {
        guard let host else { then(false); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.processIdentifier {
            // brief settle so the key arrives after the focus switch completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { then(true) }
            return
        }
        guard attempts > 0 else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.waitForFrontmost(host: host, attempts: attempts - 1, then: then)
        }
    }

    func showIssue(_ text: String, for event: ButtonEvent) {
        guard current?.ts == event.ts else { return }
        configureUI(for: event) // restore buttons/content, then overlay the note
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        resizePanel()
    }

    func showAccessibilityHint() {
        titleLabel.stringValue = "Enable Accessibility"
        messageLabel.stringValue =
            "System Settings → Privacy & Security → Accessibility → enable TheButton, then click again."
        messageLabel.isHidden = false
        detailBox.isHidden = true
        setButtonsEnabled(true)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        resizePanel()
    }

    func markHandled(_ event: ButtonEvent) {
        handledTs = event.ts
        // Only dismiss if the panel still shows THIS event; a newer prompt
        // (e.g. from another session) must not be swallowed.
        if current?.ts == event.ts {
            current = nil
            setVisible(false)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
