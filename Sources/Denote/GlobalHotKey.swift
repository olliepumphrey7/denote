import AppKit
import Carbon.HIToolbox

struct KeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifierRawValue: UInt
    let keyName: String

    static let defaultShortcut = KeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        modifierRawValue: NSEvent.ModifierFlags.option.rawValue,
        keyName: "Space"
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection([.control, .option, .shift, .command])
    }

    var displayName: String {
        var value = ""
        if modifierFlags.contains(.control) { value += "⌃" }
        if modifierFlags.contains(.option) { value += "⌥" }
        if modifierFlags.contains(.shift) { value += "⇧" }
        if modifierFlags.contains(.command) { value += "⌘" }
        return value + keyName
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}

private let denoteHotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleHotKeyPress()
    }
    return noErr
}

@MainActor
final class GlobalHotKeyManager {
    private static let defaultsKey = "Denote.globalShortcut.v1"
    private static let hotKeySignature: OSType = 0x444E4F54 // DNOT

    var onPressed: (() -> Void)?
    private(set) var shortcut: KeyboardShortcut
    private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isSuspendedForRecording = false

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            shortcut = stored
        } else {
            shortcut = .defaultShortcut
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            denoteHotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        isRegistered = handlerStatus == noErr && register(shortcut)
    }

    func updateShortcut(_ newShortcut: KeyboardShortcut) -> Bool {
        let previous = shortcut
        isSuspendedForRecording = false
        unregisterCurrent()
        guard register(newShortcut) else {
            isRegistered = register(previous)
            return false
        }

        shortcut = newShortcut
        isRegistered = true
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        return true
    }

    func suspendForRecording() {
        guard isSuspendedForRecording == false else { return }
        isSuspendedForRecording = true
        unregisterCurrent()
    }

    func resumeAfterRecording() {
        guard isSuspendedForRecording else { return }
        isSuspendedForRecording = false
        isRegistered = register(shortcut)
    }

    fileprivate func handleHotKeyPress() {
        onPressed?()
    }

    private func register(_ shortcut: KeyboardShortcut) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            hotKeyRef = nil
            return false
        }
        hotKeyRef = reference
        return true
    }

    private func unregisterCurrent() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        isRegistered = false
    }
}

@MainActor
final class ShortcutSettingsWindowController: NSWindowController {
    private let hotKeyManager: GlobalHotKeyManager
    private let recorder = ShortcutRecorderView()
    private let helpLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")

    init(hotKeyManager: GlobalHotKeyManager) {
        self.hotKeyManager = hotKeyManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Denote Settings"
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .none
        super.init(window: window)
        setupContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showSettings() {
        recorder.shortcut = hotKeyManager.shortcut
        errorLabel.isHidden = true
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func setupContent() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Global keyboard shortcut")
        heading.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        heading.frame = NSRect(x: 24, y: 137, width: 260, height: 22)
        content.addSubview(heading)

        helpLabel.stringValue = "Click the shortcut, then press a new key combination."
        helpLabel.font = NSFont.systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 24, y: 113, width: 360, height: 18)
        content.addSubview(helpLabel)

        recorder.shortcut = hotKeyManager.shortcut
        recorder.frame = NSRect(x: 24, y: 62, width: 228, height: 38)
        recorder.onRecordingChanged = { [weak self] isRecording in
            if isRecording {
                self?.hotKeyManager.suspendForRecording()
            } else {
                self?.hotKeyManager.resumeAfterRecording()
            }
            self?.helpLabel.stringValue = isRecording
                ? "Press a shortcut with Command, Option, Control or Shift."
                : "Click the shortcut, then press a new key combination."
        }
        recorder.onRecorded = { [weak self] shortcut in
            guard let self else { return }
            if self.hotKeyManager.updateShortcut(shortcut) {
                self.errorLabel.isHidden = true
                self.recorder.shortcut = shortcut
            } else {
                self.recorder.shortcut = self.hotKeyManager.shortcut
                self.errorLabel.stringValue = "That shortcut is already in use. Try another combination."
                self.errorLabel.isHidden = false
            }
        }
        content.addSubview(recorder)

        let resetButton = NSButton(
            title: "Use Default",
            target: self,
            action: #selector(resetShortcut(_:))
        )
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 270, y: 67, width: 112, height: 30)
        content.addSubview(resetButton)

        errorLabel.font = NSFont.systemFont(ofSize: 11.5)
        errorLabel.textColor = .systemRed
        errorLabel.frame = NSRect(x: 24, y: 28, width: 370, height: 18)
        errorLabel.isHidden = true
        content.addSubview(errorLabel)
    }

    @objc private func resetShortcut(_ sender: Any?) {
        let defaultShortcut = KeyboardShortcut.defaultShortcut
        if hotKeyManager.updateShortcut(defaultShortcut) {
            recorder.shortcut = defaultShortcut
            errorLabel.isHidden = true
        } else {
            errorLabel.stringValue = "Option–Space is already in use on this Mac."
            errorLabel.isHidden = false
        }
    }
}

@MainActor
private final class ShortcutRecorderView: NSControl {
    var shortcut: KeyboardShortcut = .defaultShortcut {
        didSet {
            needsDisplay = true
            setAccessibilityValue(shortcut.displayName)
        }
    }
    var onRecorded: ((KeyboardShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                installKeyMonitor()
            } else {
                removeKeyMonitor()
            }
            needsDisplay = true
            onRecordingChanged?(isRecording)
        }
    }
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Global keyboard shortcut")
        setAccessibilityHelp("Click, then press a new key combination")
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  self.isRecording,
                  self.window?.isKeyWindow == true else {
                return event
            }
            self.record(event)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = event.modifierFlags
            .intersection([.control, .option, .shift, .command])
        guard modifiers.isEmpty == false else {
            NSSound.beep()
            return
        }

        let value = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifierRawValue: modifiers.rawValue,
            keyName: Self.keyName(for: event)
        )
        shortcut = value
        isRecording = false
        window?.makeFirstResponder(nil)
        onRecorded?(value)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let fill = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.13)
            : NSColor.controlBackgroundColor
        fill.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? "Type shortcut…" : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(
            at: NSPoint(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2
            )
        )
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default:
            let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return characters?.isEmpty == false ? characters! : "Key \(event.keyCode)"
        }
    }
}
