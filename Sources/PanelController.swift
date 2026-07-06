import AppKit
import ApplicationServices

// MARK: - Frontmost gate

/// Is the user currently looking at the window hosting a session?
/// `.lookingAt` is only ever CONFIRMED knowledge (or host-frontmost with no
/// way to tell windows apart — the old conservative behavior). `.unknown`
/// means the host is frontmost but the AX probe hasn't landed yet.
enum GateState { case lookingAt, away, unknown }

final class FrontmostGate {
    private let axQueue = DispatchQueue(label: "the-button.ax", qos: .userInteractive)
    private var cache: [String: GateState] = [:]
    private var probing = Set<String>()
    private var lastFrontPid: pid_t = -1
    var forceShowUntil: [String: Date] = [:]   // fileKey -> deadline (menu reveal)

    func state(for event: ButtonEvent, now: Date) -> GateState {
        if let until = forceShowUntil[event.fileKey] {
            if until > now { return .away }
            forceShowUntil.removeValue(forKey: event.fileKey)
        }
        guard let host = hostApp(forAncestors: event.ancestors),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == host.processIdentifier
        else { return .away }

        if lastFrontPid != front.processIdentifier {
            lastFrontPid = front.processIdentifier
            cache.removeAll()
        }
        // Host frontmost but we can't tell windows apart: the old behavior
        // treated this as "user is looking" (conservative hide).
        guard AXIsProcessTrusted() else { return .lookingAt }

        let needle = event.projectName
        let key = "\(host.processIdentifier)|\(needle)"
        // Probes run continuously (single-flight per key) off the main thread
        // with short AX timeouts, so a beachballing host can never freeze us.
        if !probing.contains(key) {
            probing.insert(key)
            let pid = host.processIdentifier
            axQueue.async { [weak self] in
                let titles = windowTitles(pid: pid)
                var state = GateState.lookingAt // conservative default
                if titles.count > 1, !needle.isEmpty,
                   titles.contains(where: { $0.localizedCaseInsensitiveContains(needle) }),
                   let focused = focusedWindowTitle(pid: pid) {
                    state = focused.localizedCaseInsensitiveContains(needle) ? .lookingAt : .away
                }
                DispatchQueue.main.async {
                    self?.cache[key] = state
                    self?.probing.remove(key)
                }
            }
        }
        return cache[key] ?? .unknown
    }
}

// MARK: - Overflow footer

final class FooterView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Palette.bgRaised.withAlphaComponent(0.85).cgColor
        pill.layer?.cornerRadius = 8
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        label.font = mono(10)
        label.textColor = Palette.dim
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func setCount(_ n: Int) {
        isHidden = n <= 0
        if n > 0 { label.stringValue = "+\(n) more waiting" }
    }
}

// MARK: - Panel controller

final class PanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    var debug: (String) -> Void = { _ in }

    var onAllow: ((ButtonEvent, _ always: Bool) -> Void)?
    var onDeny: ((ButtonEvent, _ note: String?) -> Void)?
    var onDismiss: ((ButtonEvent) -> Void)?
    var onOpen: ((ButtonEvent) -> Void)?

    private let rootView = DragView()
    private let stack = NSStackView()
    private let footer = FooterView()
    private var cards: [String: PromptCardView] = [:]
    private var removing = Set<String>()
    private var gateDebounce: [String: (target: Bool, ticks: Int)] = [:]
    // Refcount, not a bool: overlapping frame animations must all finish before
    // windowDidMove is allowed to re-derive the saved position, or a mid-flight
    // frame from animation B gets written while A's completion clears the flag.
    private var programmaticFrameDepth = 0
    private(set) var isShown = false
    private var lastVisibleTarget: [ButtonEvent] = []

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
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
        panel.appearance = NSAppearance(named: .darkAqua) // brand-dark regardless of system
        panel.delegate = self

        rootView.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stack)
        stack.addArrangedSubview(footer)
        footer.setCount(0)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        panel.contentView = rootView
    }

    // MARK: render

    func render(snapshot: EventStore.Snapshot,
                gateHidden: (ButtonEvent) -> Bool,
                promoted: Set<String>,
                paused: Bool) {
        // Visible selection: permissions claim slots first, oldest first;
        // promoted (menu-revealed) keys jump the queue.
        var permissions = snapshot.permissions
        if !promoted.isEmpty {
            permissions.sort { a, b in
                let pa = promoted.contains(a.fileKey), pb = promoted.contains(b.fileKey)
                if pa != pb { return pa }
                return false // stable: keeps oldest-first within each group
            }
        }
        var target = Array(permissions.prefix(Metrics.maxCards))
        if target.count < Metrics.maxCards {
            target += snapshot.notifies.prefix(Metrics.maxCards - target.count)
        }
        let overflow = snapshot.all.count - target.count
        lastVisibleTarget = target
        let targetKeys = Set(target.map { $0.fileKey })

        var layoutChanged = false

        // Removals (celebrating cards remove themselves when done).
        for (key, card) in cards where !targetKeys.contains(key) {
            if card.isCelebrating || removing.contains(key) { continue }
            removing.insert(key)
            layoutChanged = true
            animateOut(card) { [weak self] in
                guard let self else { return }
                self.stack.removeArrangedSubview(card)
                card.removeFromSuperview()
                self.cards.removeValue(forKey: key)
                self.removing.remove(key)
                self.gateDebounce.removeValue(forKey: key)
                self.relayout(animated: true)
            }
        }

        // Inserts / updates, in order. Footer stays the last arranged view.
        for (index, event) in target.enumerated() {
            if let card = cards[event.fileKey] {
                card.update(with: event)
                let current = stack.arrangedSubviews.firstIndex(of: card)
                if let current, current != index, index < stack.arrangedSubviews.count {
                    stack.insertArrangedSubview(card, at: min(index, stack.arrangedSubviews.count - 1))
                    layoutChanged = true
                }
            } else {
                let card = makeCard(for: event)
                cards[event.fileKey] = card
                stack.insertArrangedSubview(card, at: min(index, max(0, stack.arrangedSubviews.count - 1)))
                card.widthAnchor.constraint(equalToConstant: Metrics.panelWidth).isActive = true
                animateIn(card)
                layoutChanged = true
            }
        }

        // Gate hiding, debounced 2 ticks (0.5s) against AX probe flapping.
        for (key, card) in cards {
            guard let event = target.first(where: { $0.fileKey == key }) else { continue }
            let wantHidden = gateHidden(event)
            if card.isHidden == wantHidden {
                gateDebounce.removeValue(forKey: key)
                continue
            }
            var entry = gateDebounce[key] ?? (target: wantHidden, ticks: 0)
            if entry.target != wantHidden { entry = (target: wantHidden, ticks: 0) }
            entry.ticks += 1
            gateDebounce[key] = entry
            if entry.ticks >= 2 {
                gateDebounce.removeValue(forKey: key)
                card.isHidden = wantHidden
                layoutChanged = true
            }
        }

        footer.setCount(overflow)

        let anyVisible = cards.values.contains { !$0.isHidden }
        setVisible(anyVisible && !paused)
        if layoutChanged { relayout(animated: isShown) }
    }

    private func makeCard(for event: ButtonEvent) -> PromptCardView {
        let card = PromptCardView(event: event)
        card.onAllow = { [weak self, weak card] always in
            guard let card else { return }
            self?.onAllow?(card.event, always)
        }
        card.onDeny = { [weak self, weak card] note in
            guard let card else { return }
            self?.onDeny?(card.event, note)
        }
        card.onDismiss = { [weak self, weak card] in
            guard let card else { return }
            self?.onDismiss?(card.event)
        }
        card.onOpen = { [weak self, weak card] in
            guard let card else { return }
            self?.onOpen?(card.event)
        }
        return card
    }

    func card(forFile key: String) -> PromptCardView? { cards[key] }

    /// Celebration path: checkmark, then remove the card and relayout.
    func celebrate(_ key: String) {
        guard let card = cards[key] else { return }
        card.showDelivered { [weak self, weak card] in
            guard let self else { return }
            if let card {
                self.animateOut(card) {
                    self.stack.removeArrangedSubview(card)
                    card.removeFromSuperview()
                    self.cards.removeValue(forKey: key)
                    self.relayout(animated: true)
                }
            }
        }
        relayout(animated: true) // delivered state changed the card height
    }

    func topActionableEvent() -> ButtonEvent? {
        for event in lastVisibleTarget where event.type == "permission" {
            if let card = cards[event.fileKey], !card.isHidden, !card.isCelebrating { return event }
        }
        return lastVisibleTarget.first { $0.type == "permission" }
    }

    func reveal(fileKey: String) {
        if !isShown { setVisible(true) }
        panel.orderFrontRegardless()
        cards[fileKey]?.isHidden = false
        relayout(animated: true)
        cards[fileKey]?.flash()
    }

    func tickElapsed(now: Date) {
        for card in cards.values { card.tickElapsed(now: now) }
    }

    // MARK: animations

    private func animateIn(_ card: PromptCardView) {
        guard !Anim.reduceMotion else { return }
        card.wantsLayer = true
        card.layoutSubtreeIfNeeded()
        guard let layer = card.layer else { return }
        layer.add(Anim.spring("transform",
                              from: centeredScale(0.97, dy: 6, in: card.bounds),
                              to: CATransform3DIdentity), forKey: "appearT")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "appearO")
    }

    private func animateOut(_ card: PromptCardView, then: @escaping () -> Void) {
        guard !Anim.reduceMotion, card.layer != nil else { then(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            card.animator().alphaValue = 0
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Anim.dur(0.20)
                ctx.allowsImplicitAnimation = true
                card.isHidden = true
                self.stack.layoutSubtreeIfNeeded()
            }, completionHandler: then)
        })
    }

    // MARK: sizing / positioning

    /// All programmatic frame changes go through here: top edge pinned,
    /// clamped to the screen, wrapped so windowDidMove can't re-derive the
    /// saved position fractions from a resize (drift bug).
    private func targetFrame(contentHeight h: CGFloat) -> NSRect {
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: Metrics.panelWidth, height: h)
        f.origin.y = top - h
        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if f.minY < vf.minY + 8 { f.origin.y = vf.minY + 8 }
            if f.maxY > vf.maxY - 8 { f.origin.y = vf.maxY - 8 - h }
        }
        return f
    }

    func relayout(animated: Bool) {
        rootView.layoutSubtreeIfNeeded()
        let height = max(1, rootView.fittingSize.height)
        let frame = targetFrame(contentHeight: height)
        guard frame != panel.frame else { return }
        programmaticFrameDepth += 1
        if animated && !Anim.reduceMotion && isShown {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.programmaticFrameDepth = max(0, (self?.programmaticFrameDepth ?? 1) - 1)
                self?.panel.invalidateShadow()
            })
        } else {
            panel.setFrame(frame, display: true)
            programmaticFrameDepth = max(0, programmaticFrameDepth - 1)
            panel.invalidateShadow()
        }
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        if visible {
            relayout(animated: false)
            positionPanel()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Anim.dur(0.18)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Anim.dur(0.15)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if !self.isShown { self.panel.orderOut(nil) }
            })
        }
    }

    // Position as a fraction of the screen; follows the mouse's screen.
    private var screenWithMouse: NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
    }

    private func positionPanel() {
        guard let screen = screenWithMouse ?? panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let defaults = UserDefaults.standard
        let fx = min(max(defaults.object(forKey: "tb.fx") as? Double ?? 0.97, 0), 1)
        let fy = min(max(defaults.object(forKey: "tb.fy") as? Double ?? 0.85, 0), 1)
        let size = panel.frame.size
        programmaticFrameDepth += 1
        panel.setFrameOrigin(NSPoint(
            x: vf.minX + (vf.width - size.width) * fx,
            y: vf.minY + (vf.height - size.height) * fy))
        programmaticFrameDepth = max(0, programmaticFrameDepth - 1)
    }

    func windowDidMove(_ notification: Notification) {
        guard programmaticFrameDepth == 0, panel.isVisible, let screen = panel.screen else { return }
        let vf = screen.visibleFrame
        let frame = panel.frame
        let denomX = vf.width - frame.width
        let denomY = vf.height - frame.height
        guard denomX > 0, denomY > 0 else { return }
        UserDefaults.standard.set(Double((frame.minX - vf.minX) / denomX), forKey: "tb.fx")
        UserDefaults.standard.set(Double((frame.minY - vf.minY) / denomY), forKey: "tb.fy")
    }
}
