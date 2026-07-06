import AppKit

// MARK: - Building blocks

/// The whole card is a drag handle; NSVisualEffectView reports opaque and
/// would otherwise swallow window dragging.
final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PillButton: NSButton {
    private var hovering = false
    private let fillColor: NSColor
    private let labelColor: NSColor
    private let hoverLabelColor: NSColor?
    private let fontSize: CGFloat

    init(title: String, fill: NSColor, text: NSColor,
         hoverText: NSColor? = nil, height: CGFloat = 30, fontSize: CGFloat = 12,
         corners: CACornerMask? = nil) {
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
        if let corners { layer?.maskedCorners = corners }
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
    override var title: String { didSet { refresh() } }

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

    override func mouseDown(with event: NSEvent) {
        animatePress()
        super.mouseDown(with: event) // blocks in the tracking loop until mouseUp
        animateRelease()
    }

    func animatePress() {
        guard !Anim.reduceMotion, let layer else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.toValue = centeredScale(0.96, in: bounds)
        a.duration = 0.08
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "press")
    }

    func animateRelease() {
        guard !Anim.reduceMotion, let layer else { return }
        layer.removeAnimation(forKey: "press")
        layer.add(Anim.spring("transform",
                              from: centeredScale(0.96, in: bounds),
                              to: CATransform3DIdentity,
                              stiffness: 420, damping: 20), forKey: "release")
    }
}

// MARK: - Prompt card

final class PromptCardView: NSView, NSTextFieldDelegate {
    enum State { case normal, busy, delivered }

    let fileKey: String
    private(set) var event: ButtonEvent
    private(set) var state: State = .normal
    var isCelebrating: Bool { state == .delivered }

    var onAllow: ((_ always: Bool) -> Void)?
    var onDeny: ((_ note: String?) -> Void)?
    var onDismiss: (() -> Void)?
    var onOpen: (() -> Void)?

    private let isWaitingStyle: Bool

    private let effectView = DraggableEffectView()
    private let tintView = DragView()
    private let contentStack = NSStackView()

    // permission style
    private var projectLabel: NSTextField!
    private var ttyLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var detailBox: NSView!
    private var detailLabel: NSTextField!
    private var errorLabel: NSTextField!
    private var buttonRow: NSStackView!
    private var allowButton: PillButton!
    private var allowMoreButton: PillButton!
    private var denyButton: PillButton!
    private var denyMoreButton: PillButton!
    private var noteRow: NSStackView!
    private var noteField: NSTextField!
    private var noteSendButton: PillButton!
    private var deliveredView: NSImageView!
    // waiting style
    private var waitLabel: NSTextField!
    private var openButton: PillButton!
    private var closeButton: PillButton!

    private var lastElapsedText = ""

    override var mouseDownCanMoveWindow: Bool { true }

    init(event: ButtonEvent) {
        self.event = event
        self.fileKey = event.fileKey
        self.isWaitingStyle = event.type != "permission"
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.borderWidth = 1
        layer?.borderColor = Palette.hairline.cgColor

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active // accessory panels are never "active"
        effectView.maskImage = roundedMask(radius: Metrics.cardRadius)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = Palette.bg.withAlphaComponent(0.55).cgColor
        tintView.layer?.cornerRadius = Metrics.cardRadius
        tintView.layer?.masksToBounds = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        let insetY: CGFloat = isWaitingStyle ? 9 : Metrics.contentInsetY
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.contentInsetX),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.contentInsetX),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: insetY),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insetY),
        ])

        if isWaitingStyle { buildWaiting() } else { buildPermission() }
        toolTip = "Drag anywhere to reposition"
        apply(event: event)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: layout builders

    private func label(_ text: String = "", font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        return l
    }

    private func buildHeader() -> NSStackView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = sessionAccent(for: event.sessionId).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        projectLabel = label(font: mono(10, .semibold), color: Palette.dim)
        projectLabel.lineBreakMode = .byTruncatingTail
        ttyLabel = label(font: mono(9.5), color: Palette.dim.withAlphaComponent(0.7))
        elapsedLabel = label(font: mono(9.5), color: Palette.dim.withAlphaComponent(0.8))

        closeButton = PillButton(title: "\u{2715}", fill: .clear, text: Palette.dim,
                                 hoverText: Palette.cream, height: 18, fontSize: 11)
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        closeButton.toolTip = "Dismiss this prompt (answer it in the terminal)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let header = NSStackView(views: [dot, projectLabel, ttyLabel, NSView(), elapsedLabel, closeButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        return header
    }

    private func buildPermission() {
        let header = buildHeader()

        iconView = NSImageView()
        iconView.contentTintColor = Palette.coral
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel = label(font: mono(13, .semibold), color: Palette.cream)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let toolRow = NSStackView(views: [iconView, titleLabel])
        toolRow.orientation = .horizontal
        toolRow.spacing = 6

        messageLabel = label(font: mono(11), color: Palette.dim)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = Metrics.panelWidth - Metrics.contentInsetX * 2
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        detailLabel = label(font: mono(10.5), color: Palette.code)
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.maximumNumberOfLines = 4
        detailLabel.preferredMaxLayoutWidth = Metrics.panelWidth - Metrics.contentInsetX * 2 - 18
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        detailBox = NSView()
        detailBox.wantsLayer = true
        detailBox.layer?.backgroundColor = Palette.bgRaised.withAlphaComponent(0.75).cgColor
        detailBox.layer?.cornerRadius = 6
        detailBox.translatesAutoresizingMaskIntoConstraints = false
        detailBox.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 9),
            detailLabel.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -9),
            detailLabel.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -7),
        ])

        errorLabel = label(font: mono(10), color: Palette.coral)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.preferredMaxLayoutWidth = Metrics.panelWidth - Metrics.contentInsetX * 2
        errorLabel.isHidden = true

        // Split buttons: main action + a ▾ half sharing one pill silhouette.
        let leftCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let rightCorners: CACornerMask = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]

        allowButton = PillButton(title: "Allow", fill: Palette.coral, text: Palette.ink,
                                 corners: leftCorners)
        allowButton.target = self
        allowButton.action = #selector(allowClicked)

        allowMoreButton = PillButton(title: "\u{25BE}", fill: Palette.coral, text: Palette.ink,
                                     corners: rightCorners)
        allowMoreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        allowMoreButton.toolTip = "Allow options"
        allowMoreButton.target = self
        allowMoreButton.action = #selector(allowMenuClicked)

        denyButton = PillButton(title: "Deny", fill: Palette.btn, text: Palette.cream,
                                corners: leftCorners)
        denyButton.target = self
        denyButton.action = #selector(denyClicked)

        denyMoreButton = PillButton(title: "\u{25BE}", fill: Palette.btn, text: Palette.cream,
                                    corners: rightCorners)
        denyMoreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        denyMoreButton.toolTip = "Deny options"
        denyMoreButton.target = self
        denyMoreButton.action = #selector(denyMenuClicked)

        buttonRow = NSStackView(views: [allowButton, allowMoreButton, denyButton, denyMoreButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 1
        buttonRow.setCustomSpacing(10, after: allowMoreButton)
        allowButton.widthAnchor.constraint(equalTo: denyButton.widthAnchor).isActive = true

        deliveredView = NSImageView()
        let checkConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .bold)
        deliveredView.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                      accessibilityDescription: "Sent")?
            .withSymbolConfiguration(checkConfig)
        deliveredView.contentTintColor = Palette.coral
        deliveredView.isHidden = true

        noteField = NSTextField(string: "")
        noteField.placeholderAttributedString = NSAttributedString(
            string: "why? (sent back to Claude)",
            attributes: [.font: mono(11), .foregroundColor: Palette.dim.withAlphaComponent(0.6)])
        noteField.font = mono(11)
        noteField.textColor = Palette.cream
        noteField.drawsBackground = true
        noteField.backgroundColor = Palette.bgRaised.withAlphaComponent(0.9)
        noteField.isBordered = false
        noteField.focusRingType = .none
        noteField.wantsLayer = true
        noteField.layer?.cornerRadius = 6
        noteField.delegate = self
        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.heightAnchor.constraint(equalToConstant: 24).isActive = true

        noteSendButton = PillButton(title: "Send", fill: Palette.btn, text: Palette.coral,
                                    height: 24, fontSize: 11)
        noteSendButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        noteSendButton.target = self
        noteSendButton.action = #selector(noteSendClicked)

        noteRow = NSStackView(views: [noteField, noteSendButton])
        noteRow.orientation = .horizontal
        noteRow.spacing = 6
        noteRow.isHidden = true

        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(toolRow)
        contentStack.addArrangedSubview(messageLabel)
        contentStack.addArrangedSubview(detailBox)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(noteRow)
        contentStack.addArrangedSubview(buttonRow)
        contentStack.addArrangedSubview(deliveredView)

        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            detailBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            noteRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        deliveredView.translatesAutoresizingMaskIntoConstraints = false
        deliveredView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor).isActive = true
    }

    private func buildWaiting() {
        let clock = NSImageView()
        clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Waiting")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        clock.contentTintColor = Palette.dim
        clock.setContentHuggingPriority(.required, for: .horizontal)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = sessionAccent(for: event.sessionId).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        waitLabel = label(font: mono(11), color: Palette.dim)
        waitLabel.lineBreakMode = .byTruncatingTail
        waitLabel.maximumNumberOfLines = 1

        openButton = PillButton(title: "Go to Claude", fill: Palette.btn, text: Palette.coral,
                                height: 22, fontSize: 10.5)
        openButton.widthAnchor.constraint(equalToConstant: 104).isActive = true
        openButton.target = self
        openButton.action = #selector(openClicked)

        closeButton = PillButton(title: "\u{2715}", fill: .clear, text: Palette.dim,
                                 hoverText: Palette.cream, height: 18, fontSize: 11)
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let row = NSStackView(views: [dot, clock, waitLabel, NSView(), openButton, closeButton])
        row.orientation = .horizontal
        row.spacing = 6
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    // MARK: content

    func update(with newEvent: ButtonEvent) {
        let tsChanged = newEvent.ts != event.ts
        let modeChanged = newEvent.mode != event.mode
        event = newEvent
        guard tsChanged || modeChanged else { return }
        if tsChanged, !Anim.reduceMotion, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            layer.add(fade, forKey: "contentSwap")
            lastElapsedText = ""
        }
        apply(event: newEvent)
    }

    private func apply(event: ButtonEvent) {
        if isWaitingStyle {
            waitLabel.stringValue = "Waiting — \(event.projectName.isEmpty ? "Claude" : event.projectName)"
            waitLabel.toolTip = event.message
            return
        }
        projectLabel.stringValue = event.projectName.isEmpty ? "session" : event.projectName
        ttyLabel.stringValue = event.ttyTail
        iconView.image = toolSymbolImage(for: event)

        let tool = event.toolName.isEmpty ? parsedToolName(from: event.message) : event.toolName
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
        // Split-button extras only make sense while the hook can act on them.
        let decide = event.isDecide
        allowMoreButton.isHidden = !decide
        denyMoreButton.isHidden = !decide
        let leftCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                        .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        allowButton.layer?.maskedCorners = decide ? leftCorners : allCorners
        denyButton.layer?.maskedCorners = decide ? leftCorners : allCorners
        if !decide, !noteRow.isHidden { noteRow.isHidden = true }
    }

    private func parsedToolName(from message: String) -> String? {
        guard let range = message.range(of: "permission to use ") else { return nil }
        let name = String(message[range.upperBound...])
        return name.isEmpty ? nil : name
    }

    func tickElapsed(now: Date) {
        guard !isWaitingStyle, event.ts > 0 else { return }
        let s = max(0, Int(now.timeIntervalSince1970 - event.ts))
        let text: String
        switch s {
        case ..<5: text = ""
        case ..<100: text = "\(s)s"
        case ..<5400: text = "\(s / 60)m"
        default: text = "\(s / 3600)h \(s % 3600 / 60)m"
        }
        if text != lastElapsedText {
            lastElapsedText = text
            elapsedLabel.stringValue = text
        }
    }

    // MARK: states

    func setBusy(_ busy: Bool) {
        state = busy ? .busy : .normal
        for b in [allowButton, allowMoreButton, denyButton, denyMoreButton, noteSendButton, closeButton] {
            b?.isEnabled = !busy
        }
    }

    func showError(_ text: String) {
        guard !isWaitingStyle else { return }
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        shake()
    }

    private func clearError() {
        if errorLabel != nil, !errorLabel.isHidden { errorLabel.isHidden = true }
    }

    func showDelivered(then: @escaping () -> Void) {
        guard !isWaitingStyle else { then(); return }
        state = .delivered
        clearError()
        buttonRow.isHidden = true
        noteRow.isHidden = true
        deliveredView.isHidden = false
        if !Anim.reduceMotion, let dl = deliveredView.layer {
            dl.add(Anim.spring("transform",
                               from: centeredScale(0.4, in: deliveredView.bounds),
                               to: CATransform3DIdentity,
                               stiffness: 420, damping: 18), forKey: "pop")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            dl.add(fade, forKey: "fadeIn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Anim.reduceMotion ? 0.15 : 0.45)) {
            then()
        }
    }

    func shake() {
        guard !Anim.reduceMotion, let layer else { return }
        let k = CAKeyframeAnimation(keyPath: "transform.translation.x")
        k.values = [0, -6, 5, -3, 2, 0]
        k.duration = 0.32
        k.isAdditive = true
        layer.add(k, forKey: "shake")
    }

    func flash() {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = Palette.hairline.cgColor
        a.toValue = Palette.coral.cgColor
        a.duration = 0.25
        a.autoreverses = true
        a.repeatCount = 2
        layer.add(a, forKey: "revealFlash")
    }

    func pressAnswerButton(allow: Bool) {
        guard !isWaitingStyle else { return }
        (allow ? allowButton : denyButton)?.animatePress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            (allow ? self?.allowButton : self?.denyButton)?.animateRelease()
        }
    }

    // MARK: actions

    @objc private func allowClicked() { clearError(); onAllow?(false) }
    @objc private func denyClicked() { clearError(); onDeny?(nil) }
    @objc private func closeClicked() { onDismiss?() }
    @objc private func openClicked() { onOpen?() }

    @objc private func allowMenuClicked() {
        let menu = NSMenu()
        let once = NSMenuItem(title: "Allow once   ⏎", action: #selector(menuAllowOnce), keyEquivalent: "")
        once.target = self
        menu.addItem(once)
        if let preview = alwaysAllowPreview() {
            let always = NSMenuItem(title: "Always allow — \(preview)", action: #selector(menuAllowAlways), keyEquivalent: "")
            always.target = self
            menu.addItem(always)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: allowMoreButton.bounds.height + 4),
                   in: allowMoreButton)
    }

    @objc private func denyMenuClicked() {
        let menu = NSMenu()
        let plain = NSMenuItem(title: "Deny   ⎋", action: #selector(menuDenyPlain), keyEquivalent: "")
        plain.target = self
        menu.addItem(plain)
        let withNote = NSMenuItem(title: "Deny with note…", action: #selector(menuDenyWithNote), keyEquivalent: "")
        withNote.target = self
        menu.addItem(withNote)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: denyMoreButton.bounds.height + 4),
                   in: denyMoreButton)
    }

    private func alwaysAllowPreview() -> String? {
        guard !event.ruleTool.isEmpty else { return nil }
        if event.ruleContent.isEmpty { return "\(event.ruleTool) (this project)" }
        let content = event.ruleContent.count > 36
            ? String(event.ruleContent.prefix(36)) + "…"
            : event.ruleContent
        return "\(event.ruleTool)(\(content))"
    }

    @objc private func menuAllowOnce() { clearError(); onAllow?(false) }
    @objc private func menuAllowAlways() { clearError(); onAllow?(true) }
    @objc private func menuDenyPlain() { clearError(); onDeny?(nil) }

    @objc private func menuDenyWithNote() {
        clearError()
        noteRow.isHidden = false
        window?.makeKey()
        window?.makeFirstResponder(noteField)
    }

    @objc private func noteSendClicked() { sendNote() }

    private func sendNote() {
        let note = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        noteRow.isHidden = true
        onDeny?(note.isEmpty ? nil : note)
    }

    // NSTextFieldDelegate: Enter sends, Esc collapses.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            sendNote()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            noteRow.isHidden = true
            return true
        }
        return false
    }
}
