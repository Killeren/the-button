import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Menu bar extra

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var lastCount = -1
    private var lastPaused = false

    var pendingProvider: () -> [(key: String, title: String)] = { [] }
    var isPaused: () -> Bool = { false }
    var isSoundOn: () -> Bool = { true }
    var isLoginItem: () -> Bool = {
        SMAppService.mainApp.status == .enabled
    }
    var onReveal: ((String) -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleSound: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        update(count: 0, paused: false)
    }

    func update(count: Int, paused: Bool) {
        guard count != lastCount || paused != lastPaused else { return }
        lastCount = count
        lastPaused = paused
        guard let button = statusItem.button else { return }
        let name = paused ? "pause.circle" : "asterisk"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "The Button")?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold)) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.title = count > 0 ? " \(count)" : ""
            button.font = mono(11, .semibold)
        } else {
            button.title = count > 0 ? "\u{2733} \(count)" : "\u{2733}"
        }
        button.toolTip = count > 0
            ? "The Button — \(count) prompt\(count == 1 ? "" : "s") waiting"
            : "The Button"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pending = pendingProvider()
        if pending.isEmpty {
            let none = NSMenuItem(title: "No prompts waiting", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for entry in pending {
                let item = NSMenuItem(title: entry.title, action: #selector(revealClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.key
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause The Button",
                               action: #selector(pauseClicked), keyEquivalent: "")
        pause.target = self
        pause.state = isPaused() ? .on : .off
        menu.addItem(pause)

        let sound = NSMenuItem(title: "Play Sound for New Prompts",
                               action: #selector(soundClicked), keyEquivalent: "")
        sound.target = self
        sound.state = isSoundOn() ? .on : .off
        menu.addItem(sound)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(loginClicked), keyEquivalent: "")
        login.target = self
        login.state = isLoginItem() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit The Button",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { onReveal?(key) }
    }

    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func soundClicked() { onToggleSound?() }

    @objc private func loginClicked() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Login Items"
            alert.informativeText = "\(error.localizedDescription)\n\nNote: with an ad-hoc signed app this setting is tied to the app's current location on disk."
            alert.runModal()
        }
    }
}

// MARK: - Global hotkeys (Carbon RegisterEventHotKey: no permissions needed,
// system-filtered, cannot swallow unrelated input — unlike a CGEventTap)

final class HotKeyCenter {
    var onAllow: (() -> Void)?
    var onDeny: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var allowRef: EventHotKeyRef?
    private var denyRef: EventHotKeyRef?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { center.handle(id) }
            return noErr
        }, 1, &spec, userData, &handlerRef)

        let signature: OSType = 0x5442484B // "TBHK"
        RegisterEventHotKey(UInt32(kVK_Return), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: signature, id: 1),
                            GetApplicationEventTarget(), 0, &allowRef)
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: signature, id: 2),
                            GetApplicationEventTarget(), 0, &denyRef)
    }

    private func handle(_ id: UInt32) {
        if id == 1 { onAllow?() } else if id == 2 { onDeny?() }
    }
}
