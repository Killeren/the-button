import AppKit
import ApplicationServices

// MARK: - Host app discovery

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

/// Terminal.app, Allow only: `do script ""` writes a bare newline to the
/// tab's tty — lands in the running claude process with NO tab selection and
/// NO focus change. (Deny still needs the focus path: `do script` always
/// appends a newline, and ESC+newline risks being parsed as a Meta sequence.)
func terminalWriteNewline(tty: String) -> Bool {
    guard !tty.isEmpty else { return false }
    let script = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    do script "" in t
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

// MARK: - Decide-mode answers

enum DecideAnswer {
    /// `always` persists a project-local allow rule — the hook builds and
    /// writes it (it holds the original tool_input), so the app just asks.
    static func allow(always: Bool = false) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "allow"]
        if always { payload["always"] = true }
        return payload
    }

    static func deny(message: String?) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "deny"]
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        payload["message"] = trimmed.isEmpty ? "Denied by the user via The Button." : trimmed
        return payload
    }

    static let ask: [String: Any] = ["behavior": "ask"]

    /// Does this prompt carry enough info for an "Always allow" rule?
    static func canAlwaysAllow(_ event: ButtonEvent) -> Bool { !event.ruleTool.isEmpty }

    @discardableResult
    static func write(_ payload: [String: Any], for event: ButtonEvent) -> Bool {
        guard event.isDecide else { return false }
        return atomicWriteJSON(payload, to: URL(fileURLWithPath: event.answerPath))
    }
}

// MARK: - Keystroke fallback (FIFO-serialized)

/// Delivers answers by typing at the session's terminal. Jobs run strictly
/// one at a time: two concurrent focus dances from two cards would fight
/// over the frontmost app and could type into the wrong window.
final class Responder {
    enum Outcome {
        case delivered(String)      // how it was sent, for --debug
        case failed(String)         // do NOT type blind; keep the prompt and explain
        case needsAccessibility
    }

    var debug: (String) -> Void = { _ in }

    private struct Job {
        let event: ButtonEvent
        let allow: Bool
        let stillCurrent: () -> Bool          // evaluated on main
        let completion: (Outcome) -> Void     // called on main
    }

    private var jobs: [Job] = []
    private var active = false

    func deliver(_ event: ButtonEvent, allow: Bool,
                 stillCurrent: @escaping () -> Bool,
                 completion: @escaping (Outcome) -> Void) {
        jobs.append(Job(event: event, allow: allow,
                        stillCurrent: stillCurrent, completion: completion))
        pump()
    }

    private func pump() {
        guard !active, !jobs.isEmpty else { return }
        active = true
        let job = jobs.removeFirst()
        run(job)
    }

    private func finish(_ job: Job, _ outcome: Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        job.completion(outcome)
        active = false
        pump()
    }

    private enum SendPlan {
        case sent(String)
        case needsFocus
        case failed(String)
    }

    private func run(_ job: Job) {
        let event = job.event
        let allow = job.allow
        let host = hostApp(forAncestors: event.ancestors)
        let previous = NSWorkspace.shared.frontmostApplication

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // The prompt may get answered in the terminal while we work; check
            // right before irreversibly sending anything.
            let stillCurrent = { DispatchQueue.main.sync { job.stillCurrent() } }

            let plan: SendPlan
            let bundle = host?.bundleIdentifier
            if let pane = tmuxPane(forTty: event.tty) {
                if !stillCurrent() {
                    plan = .sent("nothing — prompt was already resolved")
                } else if tmuxSend(pane: pane, allow: allow) {
                    plan = .sent("tmux pane \(pane)")
                } else {
                    plan = .failed("Couldn't write to the tmux pane — answer in the terminal.")
                }
            } else if bundle == "com.googlecode.iterm2" {
                if !stillCurrent() {
                    plan = .sent("nothing — prompt was already resolved")
                } else if respondViaITerm(tty: event.tty, allow: allow) {
                    plan = .sent("iTerm2 session \(event.tty)")
                } else {
                    plan = .failed("Couldn't write to the iTerm2 session — allow Automation for TheButton in System Settings.")
                }
            } else if bundle == "com.apple.Terminal" {
                if allow {
                    // Background delivery: no tab switch, no focus change.
                    if !stillCurrent() {
                        plan = .sent("nothing — prompt was already resolved")
                    } else if terminalWriteNewline(tty: event.tty) {
                        plan = .sent("Terminal.app do-script newline \(event.tty)")
                    } else {
                        plan = .failed("Couldn't find the Terminal tab — allow Automation for TheButton in System Settings.")
                    }
                } else {
                    plan = selectTerminalTab(tty: event.tty)
                        ? .needsFocus
                        : .failed("Couldn't find the Terminal tab — allow Automation for TheButton in System Settings.")
                }
            } else if host != nil {
                plan = .needsFocus
            } else {
                plan = .failed("Couldn't identify the app hosting this session — answer in the terminal.")
            }

            DispatchQueue.main.async {
                self.executePlan(plan, job: job, host: host, previous: previous)
            }
        }
    }

    private func executePlan(_ plan: SendPlan, job: Job,
                             host: NSRunningApplication?, previous: NSRunningApplication?) {
        switch plan {
        case .sent(let how):
            debug("answered via \(how)")
            finish(job, .delivered(how))

        case .failed(let why):
            debug("respond failed: \(why)")
            finish(job, .failed(why))

        case .needsFocus:
            guard AXIsProcessTrusted() else {
                finish(job, .needsAccessibility)
                return
            }
            let event = job.event
            // The window raise + activate are blocking AX calls (up to ~0.3s
            // per window); run them off-main so a busy host can't freeze the UI
            // or starve the heartbeat, then hop back for the frontmost poll.
            DispatchQueue.global(qos: .userInitiated).async {
                if let host, host.bundleIdentifier != "com.apple.Terminal" {
                    raiseWindow(pid: host.processIdentifier, matching: event.projectName)
                }
                bringToFront(host)
                DispatchQueue.main.async { self.focusThenType(job: job, host: host, previous: previous) }
            }
        }
    }

    private func focusThenType(job: Job, host: NSRunningApplication?, previous: NSRunningApplication?) {
            // NEVER type blind: verify the host actually became frontmost, and
            // that the prompt still exists, before posting the key.
            waitForFrontmost(host: host, attempts: 36) { [weak self] focused in
                guard let self else { return }
                guard job.stillCurrent() else {
                    self.finish(job, .delivered("nothing — prompt was already resolved"))
                    return
                }
                guard focused else {
                    self.finish(job, .failed("Couldn't focus \(host?.localizedName ?? "the app") — click again or answer in the terminal."))
                    return
                }
                postKey(job.allow ? KEY_RETURN : KEY_ESC)
                self.debug("answered via keystroke to \(host?.localizedName ?? "?")")
                if let previous, previous.processIdentifier != host?.processIdentifier {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        bringToFront(previous)
                    }
                }
                self.finish(job, .delivered("keystroke to \(host?.localizedName ?? "?")"))
            }
    }

    private func waitForFrontmost(host: NSRunningApplication?, attempts: Int,
                                  then: @escaping (Bool) -> Void) {
        guard let host else { then(false); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.processIdentifier {
            // brief settle so the key arrives after the focus switch completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then(true) }
            return
        }
        guard attempts > 0 else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFrontmost(host: host, attempts: attempts - 1, then: then)
        }
    }
}
