import AppKit
import ApplicationServices

// The Button — floating Allow/Deny panel for Claude Code permission prompts.
//
//   Events.swift          event model, per-prompt store, heartbeat
//   Delivery.swift        decide-mode answers + keystroke fallback routing
//   PromptCardView.swift  one card per pending prompt
//   PanelController.swift frontmost gate + the floating multi-card panel
//   Extras.swift          menu bar item, global hotkeys
//   Theme.swift           palette, metrics, motion, icons
//
// Answer path 1 (decide): hook.py blocks on PermissionRequest; the panel
// writes an answer file; the hook returns the decision to Claude Code.
// No keystrokes, no focus changes, any terminal.
// Answer path 2 (keystroke): tmux / iTerm2 / Terminal.app / AX targeting,
// used when the hook already fell back (or an old hook.py is installed).

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = EventStore()
    let gate = FrontmostGate()
    let responder = Responder()
    let heartbeat = Heartbeat()
    let hotKeys = HotKeyCenter()
    var panelController: PanelController!
    var statusController: StatusItemController!
    var timer: Timer?

    var isTest = false
    let isDebug = CommandLine.arguments.contains("--debug")
    var paused = UserDefaults.standard.bool(forKey: "tb.paused")
    var soundOn = (UserDefaults.standard.object(forKey: "tb.sound") as? Bool) ?? true

    struct AwaitingDecide {
        let allow: Bool
        let deadline: Date
        let answerPath: String
        let hookPid: Int32
    }
    var awaitingDecide: [String: AwaitingDecide] = [:]
    var releasedAsk = Set<String>()
    var knownPermissionKeys = Set<String>()
    var lastSnapshot = EventStore.Snapshot()
    var testDeniedOnce = false

    func dbg(_ msg: String) {
        if isDebug { FileHandle.standardError.write(Data(("[tb] " + msg + "\n").utf8)) }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.debug = { [weak self] in self?.dbg($0) }
        responder.debug = { [weak self] in self?.dbg($0) }

        panelController = PanelController()
        panelController.debug = { [weak self] in self?.dbg($0) }
        panelController.onAllow = { [weak self] event, always in
            self?.answer(event, allow: true, always: always)
        }
        panelController.onDeny = { [weak self] event, note in
            self?.answer(event, allow: false, note: note)
        }
        panelController.onDismiss = { [weak self] event in self?.dismiss(event) }
        panelController.onOpen = { [weak self] event in self?.open(event) }

        statusController = StatusItemController()
        statusController.pendingProvider = { [weak self] in self?.pendingMenuEntries() ?? [] }
        statusController.isPaused = { [weak self] in self?.paused ?? false }
        statusController.isSoundOn = { [weak self] in self?.soundOn ?? true }
        statusController.onReveal = { [weak self] key in self?.reveal(key) }
        statusController.onTogglePause = { [weak self] in self?.togglePause() }
        statusController.onToggleSound = { [weak self] in
            guard let self else { return }
            self.soundOn.toggle()
            UserDefaults.standard.set(self.soundOn, forKey: "tb.sound")
        }

        hotKeys.onAllow = { [weak self] in self?.hotkeyAnswer(allow: true) }
        hotKeys.onDeny = { [weak self] in self?.hotkeyAnswer(allow: false) }
        hotKeys.install()

        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }

        if CommandLine.arguments.contains("--test") {
            setupTest()
        } else if !paused {
            heartbeat.start()
        }

        let t = Timer(timeInterval: 0.25, target: self,
                      selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand every waiting prompt back to the native dialog immediately,
        // then drop the heartbeat so future prompts never wait on us.
        releaseAllDecide()
        heartbeat.stopAndRemove()
    }

    // MARK: main loop

    @objc func tick() {
        let now = Date()
        let snap = store.refresh(now: now)
        lastSnapshot = snap
        let liveKeys = Set(snap.all.map { $0.fileKey })
        releasedAsk.formIntersection(liveKeys)
        gate.forceShowUntil = gate.forceShowUntil.filter { liveKeys.contains($0.key) && $0.value > now }

        if !isTest {
            processDecideReleases(snap: snap, now: now)
            checkAwaiting(snap: snap, now: now)
        }
        soundForNewCards(snap: snap)

        panelController.render(
            snapshot: snap,
            gateHidden: { [weak self] event in self?.gateHidden(event, now: now) ?? false },
            promoted: Set(gate.forceShowUntil.keys),
            paused: paused)
        panelController.tickElapsed(now: now)
        statusController.update(count: snap.permissions.count, paused: paused)
    }

    func gateHidden(_ event: ButtonEvent, now: Date) -> Bool {
        if isTest { return false }
        return gate.state(for: event, now: now) != .away
    }

    /// The user focused the session's window while a decide hook is waiting:
    /// hand the prompt to the native dialog (the hook flips to keystroke mode
    /// and the card gate-hides). Runs over ALL pending prompts, visible or not.
    func processDecideReleases(snap: EventStore.Snapshot, now: Date) {
        for event in snap.permissions where event.isDecide {
            let key = event.fileKey
            guard !releasedAsk.contains(key), awaitingDecide[key] == nil else { continue }
            if gate.state(for: event, now: now) == .lookingAt {
                if DecideAnswer.write(DecideAnswer.ask, for: event) {
                    releasedAsk.insert(key)
                    // The native dialog now owns this prompt and the user is
                    // already at the terminal — retire the card so it can't
                    // later re-appear as a keystroke card and type into a
                    // running turn. They answer it in the terminal.
                    store.markHandled(event)
                    dbg("released \(key) to native dialog (user is looking)")
                }
            }
        }
    }

    /// Confirm decide answers: the hook deletes its event file after emitting
    /// the decision. A mode flip to "keystroke" means the hook gave up right
    /// before our answer landed — deliver by keystroke instead.
    func checkAwaiting(snap: EventStore.Snapshot, now: Date) {
        for (key, waiting) in awaitingDecide {
            guard let event = store.event(forFile: key) else {
                awaitingDecide.removeValue(forKey: key)
                // The hook deletes event + answer together after emitting the
                // decision, so both-gone means delivered. A leftover answer
                // file with a dead hook means the hook died BEFORE consuming
                // it — the native dialog is now waiting in the terminal, so
                // don't fake a success checkmark; let render animate the card
                // out and clean up the orphan answer.
                let answerLeft = !waiting.answerPath.isEmpty
                    && FileManager.default.fileExists(atPath: waiting.answerPath)
                if answerLeft && waiting.hookPid > 0 && !processAlive(waiting.hookPid) {
                    dbg("decide hook \(waiting.hookPid) died before consuming answer for \(key)")
                    try? FileManager.default.removeItem(atPath: waiting.answerPath)
                } else {
                    dbg("decide delivered for \(key)")
                    panelController.celebrate(key)
                }
                continue
            }
            if event.mode == "keystroke" {
                awaitingDecide.removeValue(forKey: key)
                if paused { continue } // don't start a focus dance while paused
                dbg("decide raced hook fallback for \(key); using keystrokes")
                deliverKeystroke(event: event, allow: waiting.allow)
                continue
            }
            if now > waiting.deadline {
                awaitingDecide.removeValue(forKey: key)
                let card = panelController.card(forFile: key)
                card?.setBusy(false)
                if event.hookPid > 0, !processAlive(event.hookPid) {
                    card?.showError("The session's hook died — answer in the terminal.")
                } else {
                    card?.showError("The hook didn't pick up the answer — try again.")
                }
            }
        }
    }

    func soundForNewCards(snap: EventStore.Snapshot) {
        let keys = Set(snap.permissions.map { $0.fileKey })
        let fresh = keys.subtracting(knownPermissionKeys)
        knownPermissionKeys = keys
        if !fresh.isEmpty, soundOn, !paused, !isTest {
            NSSound(named: "Tink")?.play()
        }
    }

    // MARK: answering

    func answer(_ event: ButtonEvent, allow: Bool, always: Bool = false, note: String? = nil) {
        guard !paused else { return }
        let key = event.fileKey
        guard let live = store.event(forFile: key), !store.isHandled(live),
              live.ts == event.ts, awaitingDecide[key] == nil else { return }
        if isTest { simulateAnswer(key: key, allow: allow); return }

        if live.isDecide, processAlive(live.hookPid) {
            let card = panelController.card(forFile: key)
            card?.setBusy(true)
            let payload: [String: Any] = allow
                ? DecideAnswer.allow(always: always)
                : DecideAnswer.deny(message: note)
            if DecideAnswer.write(payload, for: live) {
                awaitingDecide[key] = AwaitingDecide(
                    allow: allow, deadline: Date().addingTimeInterval(2.5),
                    answerPath: live.answerPath, hookPid: live.hookPid)
                dbg("decide answer written for \(key) allow=\(allow) always=\(always)")
            } else {
                card?.setBusy(false)
                card?.showError("Couldn't write the answer file — answer in the terminal.")
            }
            return
        }
        deliverKeystroke(event: live, allow: allow)
    }

    func deliverKeystroke(event: ButtonEvent, allow: Bool) {
        let key = event.fileKey
        panelController.card(forFile: key)?.setBusy(true)
        responder.deliver(event, allow: allow, stillCurrent: { [weak self] in
            self?.store.currentTs(forFile: key) == event.ts
        }, completion: { [weak self] outcome in
            guard let self else { return }
            let card = self.panelController.card(forFile: key)
            switch outcome {
            case .delivered(let how):
                self.dbg("delivered via \(how)")
                self.store.markHandled(event)
                self.panelController.celebrate(key)
            case .failed(let why):
                card?.setBusy(false)
                card?.showError(why)
            case .needsAccessibility:
                card?.setBusy(false)
                card?.showError("Enable Accessibility: System Settings → Privacy & Security → Accessibility → TheButton, then click again.")
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
        })
    }

    /// ✕ = leave the prompt for the terminal. Decide prompts get released to
    /// the native dialog first so they are actually answerable there.
    func dismiss(_ event: ButtonEvent) {
        let key = event.fileKey
        if !isTest, let live = store.event(forFile: key), live.isDecide, processAlive(live.hookPid) {
            DecideAnswer.write(DecideAnswer.ask, for: live)
            releasedAsk.insert(key)
        }
        store.markHandled(event)
    }

    func open(_ event: ButtonEvent) {
        let host = hostApp(forAncestors: event.ancestors)
        // All AppleScript/AX work stays OFF the main thread — a busy host must
        // never stall the tick or the (main-independent) heartbeat.
        DispatchQueue.global(qos: .userInitiated).async {
            if host?.bundleIdentifier == "com.apple.Terminal" {
                _ = selectTerminalTab(tty: event.tty)
            } else if let host, AXIsProcessTrusted() {
                raiseWindow(pid: host.processIdentifier, matching: event.projectName)
            }
            bringToFront(host)
            // No handled-marking: the gate hides the card while the user is
            // there, and it comes back if they leave without answering.
        }
    }

    func hotkeyAnswer(allow: Bool) {
        guard !paused, let event = panelController.topActionableEvent() else { return }
        panelController.card(forFile: event.fileKey)?.pressAnswerButton(allow: allow)
        answer(event, allow: allow)
    }

    func releaseAllDecide() {
        guard !isTest else { return }
        for event in lastSnapshot.permissions where event.isDecide && processAlive(event.hookPid) {
            // Don't clobber a just-written allow/deny answer with "ask".
            if awaitingDecide[event.fileKey] != nil { continue }
            DecideAnswer.write(DecideAnswer.ask, for: event)
            releasedAsk.insert(event.fileKey)
        }
    }

    // MARK: menu bar

    func pendingMenuEntries() -> [(key: String, title: String)] {
        // While paused the panel stays hidden, so don't offer reveal items
        // that would flash it open and then get re-hidden on the next tick.
        if paused { return [] }
        return lastSnapshot.permissions.map { event in
            let tool = event.toolName.isEmpty ? "Permission" : event.toolName
            var detail = event.detail.isEmpty ? event.message : event.detail
            if detail.count > 40 { detail = String(detail.prefix(40)) + "…" }
            let project = event.projectName.isEmpty ? "" : "  (\(event.projectName))"
            return (key: event.fileKey, title: "\(tool) — \(detail)\(project)")
        }
    }

    func reveal(_ key: String) {
        gate.forceShowUntil[key] = Date().addingTimeInterval(4)
        tick()
        panelController.reveal(fileKey: key)
    }

    func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "tb.paused")
        if paused {
            releaseAllDecide()
            heartbeat.stopAndRemove()
        } else if !isTest {
            heartbeat.start()
        }
        tick()
    }

    // MARK: --test

    func setupTest() {
        isTest = true
        let now = Date().timeIntervalSince1970
        var alpha = ButtonEvent(
            type: "permission", message: "Claude needs your permission to use Bash",
            sessionId: "test-session-alpha", claudePid: getpid(), ancestors: [],
            tty: "/dev/ttys003", cwd: "/tmp/demo-project", toolName: "Bash",
            detail: "git push origin main --force-with-lease", ts: now - 45,
            mode: "decide", answerPath: "/dev/null", hookPid: getpid(),
            deadlineTs: now + 590, ruleTool: "Bash",
            ruleContent: "git push origin main --force-with-lease")
        alpha.fileKey = "test-a"
        var beta = ButtonEvent(
            type: "permission", message: "Claude needs your permission to use Edit",
            sessionId: "test-session-beta", claudePid: getpid(), ancestors: [],
            tty: "/dev/ttys007", cwd: NSHomeDirectory() + "/code/api-server", toolName: "Edit",
            detail: "src/routes/billing.ts", ts: now - 8,
            mode: "decide", answerPath: "/dev/null", hookPid: getpid(),
            deadlineTs: now + 590, ruleTool: "Edit", ruleContent: "")
        beta.fileKey = "test-b"
        var gamma = ButtonEvent(
            type: "notify", message: "Claude finished and is waiting for your next prompt",
            sessionId: "test-session-gamma", claudePid: getpid(), ancestors: [],
            tty: "", cwd: "/tmp/docs-site", toolName: "",
            detail: "", ts: now - 120,
            mode: "", answerPath: "", hookPid: 0,
            deadlineTs: 0, ruleTool: "", ruleContent: "")
        gamma.fileKey = "test-c"
        store.testEvents = [alpha, beta, gamma]
    }

    func simulateAnswer(key: String, allow: Bool) {
        let card = panelController.card(forFile: key)
        card?.setBusy(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !allow, key == "test-b", !self.testDeniedOnce {
                self.testDeniedOnce = true
                let card = self.panelController.card(forFile: key)
                card?.setBusy(false)
                card?.showError("Simulated failure — click Deny again to see it succeed.")
                return
            }
            if let event = self.store.event(forFile: key) { self.store.markHandled(event) }
            self.panelController.celebrate(key)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
