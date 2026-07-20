import AppKit
import DenoteCore
import QuartzCore

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private struct SwitcherLayout {
        let size: NSSize
        let anchor: NSPoint
        let placement: NoteSwitcherPlacement
    }

    enum SizePreset: String {
        case standard
        case small

        static func storedValue(_ value: String) -> SizePreset {
            value == "small" || value == "minimised" ? .small : .standard
        }

        var size: NSSize {
            switch self {
            case .standard: NSSize(width: 660, height: 600)
            case .small: NSSize(width: 420, height: 220)
            }
        }

        var next: SizePreset {
            switch self {
            case .standard: .small
            case .small: .standard
            }
        }

        var label: String {
            switch self {
            case .standard: "Standard"
            case .small: "Small"
            }
        }

        var symbolName: String {
            switch self {
            case .standard: "rectangle.compress.vertical"
            case .small: "rectangle"
            }
        }
    }

    private let storage: NoteStorage
    private var noteID: String
    private var noteURL: URL
    private let onClose: (NoteWindowController) -> Void
    private let onChange: () -> Void
    private let editorView = BlockEditorView()
    private let voiceTranscriber = VoiceTranscriber()
    private let initialButton = InitialBadgeButton()
    private let titleLabel = DraggableTitleLabel()
    private let titleButton = NSButton()
    private let titleField = NSTextField()
    private weak var sizeButton: NSButton?
    private weak var pinButton: NSButton?
    private weak var micButton: NSButton?
    private weak var titleSwitcherView: NSVisualEffectView?
    private weak var orbitSwitcherView: OrbitSwitcherOverlayView?
    private var orbitWindow: NSPanel?
    private var titlePopover: NSPopover?
    private var orbitHideTimer: Timer?
    private var isInitialHovered = false
    private var isOrbitItemHovered = false
    private var noteSlots: [NoteSwitcherItem] = []
    private var floatingWindow: NSPanel?
    private var floatingView: FloatingSwitcherView?
    private var floatingHideTimer: Timer?
    private var isFloatingExpanded = false
    private var floatingAnchorOnScreen: NSPoint?
    private var floatingSwitcherAnchor = NSPoint(x: 24, y: 24)
    private var floatingPlacement: NoteSwitcherPlacement = .balanced
    private var localClickAwayMonitor: Any?
    private var globalClickAwayMonitor: Any?
    private var noteTitle: String
    private var preset: SizePreset
    private var isPinned: Bool
    private var showsHoverIcon: Bool
    private var autosaveTimer: Timer?

    init(
        storage: NoteStorage,
        noteState: NoteState,
        showsHoverIcon: Bool,
        onClose: @escaping (NoteWindowController) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.storage = storage
        self.noteID = noteState.id
        self.noteURL = URL(fileURLWithPath: noteState.path)
        self.noteTitle = noteState.title
        self.preset = SizePreset.storedValue(noteState.preset)
        self.isPinned = noteState.isPinned
        self.showsHoverIcon = showsHoverIcon
        self.floatingAnchorOnScreen = noteState.floatingAnchor.map(NSPointFromString)
        self.onClose = onClose
        self.onChange = onChange
        self.noteSlots = noteState.switcherPaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NoteSwitcherItem(title: NoteStorage.noteTitle(from: url), url: url)
        }
        var includesCurrentNote = false
        for slot in self.noteSlots where slot.url.standardizedFileURL == self.noteURL.standardizedFileURL {
            includesCurrentNote = true
            break
        }
        if includesCurrentNote == false {
            self.noteSlots.insert(NoteSwitcherItem(title: self.noteTitle, url: self.noteURL), at: 0)
        }

        let rect: NSRect
        if let frame = noteState.frame {
            rect = Self.visibleRect(from: NSRectFromString(frame), fallbackSize: preset.size)
        } else {
            rect = NSRect(origin: .zero, size: preset.size)
        }

        let window = NoteWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 320, height: SizePreset.small.size.height)
        window.title = noteTitle
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        super.init(window: window)
        window.delegate = self
        window.onMiniaturize = { [weak self] in
            guard let self, self.showsHoverIcon else { return false }
            self.collapseToFloatingInitial()
            return true
        }
        if noteState.frame == nil {
            window.center()
        }
        setupContent()
        setupVoiceTranscription()
        setupToolbar()
        applyPinnedState()
        loadContent()
        if showsHoverIcon {
            DispatchQueue.main.async { [weak self] in self?.ensureFloatingControl() }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func currentState() -> NoteState? {
        guard let window else { return nil }
        guard editorView.currentDocument().isBlank == false || noteSlots.count > 1 else { return nil }
        return NoteState(
            id: noteID,
            path: noteURL.path,
            title: noteTitle,
            frame: NSStringFromRect(window.frame),
            preset: preset.rawValue,
            isPinned: isPinned,
            switcherPaths: noteSlots.map(\.url.path),
            floatingAnchor: floatingAnchorOnScreen.map(NSStringFromPoint)
        )
    }

    func windowWillClose(_ notification: Notification) {
        orbitHideTimer?.invalidate()
        floatingHideTimer?.invalidate()
        stopClickAwayMonitoring()
        closeOrbit(animated: false)
        removeFloatingControl()
        saveNow()
        onClose(self)
    }

    @objc func toggleSizePreset(_ sender: Any?) {
        setPreset(preset.next)
    }

    @objc func togglePinned(_ sender: Any?) {
        isPinned.toggle()
        applyPinnedState()
        updatePinButton()
        onChange()
    }

    func setHoverIconEnabled(_ enabled: Bool) {
        guard enabled != showsHoverIcon else { return }
        showsHoverIcon = enabled
        if enabled {
            ensureFloatingControl()
        } else {
            if window?.isVisible == false { restoreFromFloatingInitial() }
            removeFloatingControl()
        }
    }

    @objc func pasteAndMergeFormatting(_ sender: Any?) {
        editorView.pasteAndMergeFormatting(sender)
    }

    @objc func pasteWithoutFormatting(_ sender: Any?) {
        editorView.pasteWithoutFormatting(sender)
    }

    @objc func applyNormalStyle(_ sender: Any?) {
        editorView.applyNormalStyle(sender)
    }

    @objc func toggleVoiceTranscription(_ sender: Any?) {
        voiceTranscriber.toggleRecording()
    }

    @objc func exportMarkdown(_ sender: Any?) {
        export(content: MarkdownExporter.markdown(from: editorView.currentDocument()), fileExtension: "md")
    }

    @objc func exportText(_ sender: Any?) {
        export(content: editorView.currentDocument().plainText, fileExtension: "txt")
    }

    @objc func exportHTML(_ sender: Any?) {
        export(content: Self.fullHTMLDocument(body: editorView.currentDocument().html, title: noteTitle), fileExtension: "html")
    }

    @objc func showExportMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let markdown = NSMenuItem(title: "Markdown...", action: #selector(exportMarkdown(_:)), keyEquivalent: "")
        markdown.target = self
        menu.addItem(markdown)
        let text = NSMenuItem(title: "Text...", action: #selector(exportText(_:)), keyEquivalent: "")
        text.target = self
        menu.addItem(text)
        let html = NSMenuItem(title: "HTML...", action: #selector(exportHTML(_:)), keyEquivalent: "")
        html.target = self
        menu.addItem(html)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func titleChanged(_ sender: NSTextField) {
        updateTitle(from: sender.stringValue)
        titlePopover?.close()
    }

    @objc private func showTitlePopover(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 78)

        let viewController = NSViewController()
        let container = NSView(frame: NSRect(origin: .zero, size: popover.contentSize))
        let nameLabel = NSTextField(labelWithString: "Name:")

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .right
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = noteTitle
        titleField.font = NSFont.systemFont(ofSize: 15)
        titleField.target = self
        titleField.action = #selector(titleChanged(_:))
        titleField.delegate = self
        titleField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(nameLabel)
        container.addSubview(titleField)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            nameLabel.widthAnchor.constraint(equalToConstant: 58),
            nameLabel.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            titleField.heightAnchor.constraint(equalToConstant: 28)
        ])

        viewController.view = container
        popover.contentViewController = viewController
        titlePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.titleField)
            self.titleField.currentEditor()?.selectAll(nil)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === titleField else { return }
        updateTitle(from: titleField.stringValue)
    }

    private func updateTitle(from rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldURL = noteURL
        noteTitle = trimmed.isEmpty ? storage.randomNoteTitle() : trimmed
        if editorView.currentDocument().isBlank == false {
            noteURL = (try? storage.renameNote(at: noteURL, id: noteID, title: noteTitle)) ?? noteURL
        } else {
            noteURL = storage.createNoteURL(id: noteID, title: noteTitle)
        }
        updateCurrentSlot(from: oldURL)
        updateTitleButton()
        window?.title = noteTitle
        saveNow()
        onChange()
        refreshOpenSwitchers()
    }

    private func setupContent() {
        guard let window else { return }
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.distribution = .fill

        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.onDocumentChanged = { [weak self] in self?.scheduleAutosave() }

        container.addArrangedSubview(editorView)
        window.contentView = container
    }

    private func setupVoiceTranscription() {
        voiceTranscriber.onTranscript = { [weak self] text in
            guard let self else { return }
            self.editorView.insertText(text)
            self.scheduleAutosave()
        }
        voiceTranscriber.onStateChanged = { [weak self] state in
            self?.updateMicButton(for: state)
        }
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "NoteToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        window?.toolbar = toolbar
    }

    private func configureTitleControls() {
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        initialButton.onHoverChanged = { [weak self] hovered in
            self?.setInitialHovered(hovered)
        }
        initialButton.onStep = { [weak self] direction in self?.stepSwitcher(by: direction) }
        initialButton.target = self
        initialButton.action = #selector(revealOrbit(_:))

        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        titleButton.imagePosition = .imageOnly
        titleButton.contentTintColor = .secondaryLabelColor
        titleButton.controlSize = .small
        titleButton.target = self
        titleButton.action = #selector(showTitlePopover(_:))
        updateTitleButton()
    }

    @objc private func revealOrbit(_ sender: Any?) {
        orbitHideTimer?.invalidate()
        showOrbit(animated: orbitSwitcherView == nil)
    }

    private func setInitialHovered(_ hovered: Bool) {
        isInitialHovered = hovered
        if hovered {
            orbitHideTimer?.invalidate()
            showOrbit(animated: orbitSwitcherView == nil)
        } else {
            scheduleOrbitClose()
        }
    }

    private func setOrbitItemHovered(_ hovered: Bool) {
        isOrbitItemHovered = hovered
        if hovered {
            orbitHideTimer?.invalidate()
        } else {
            scheduleOrbitClose()
        }
    }

    private func showOrbit(animated: Bool) {
        guard let window else { return }
        let anchorInWindow = initialButton.convert(
            NSPoint(x: initialButton.bounds.midX, y: initialButton.bounds.midY),
            to: nil
        )
        let anchorOnScreen = window.convertPoint(toScreen: anchorInWindow)
        let layout = switcherLayout(around: anchorOnScreen)
        let panelSize = layout.size
        let localAnchor = layout.anchor
        let panelFrame = NSRect(
            x: anchorOnScreen.x - localAnchor.x,
            y: anchorOnScreen.y - localAnchor.y,
            width: panelSize.width,
            height: panelSize.height
        )

        if let orbitSwitcherView, let orbitWindow {
            orbitWindow.setFrame(panelFrame, display: true)
            orbitSwitcherView.frame = NSRect(origin: .zero, size: panelSize)
            orbitSwitcherView.configure(
                items: noteSlots,
                activeURL: noteURL,
                anchor: localAnchor,
                placement: layout.placement,
                animated: animated
            )
            return
        }

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = window.level
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]

        let overlay = OrbitSwitcherOverlayView(frame: NSRect(origin: .zero, size: panelSize))
        overlay.autoresizingMask = [.width, .height]
        overlay.onSelect = { [weak self] item in
            self?.switchToNote(item)
            self?.showOrbit(animated: false)
        }
        overlay.onAdd = { [weak self] sender in self?.showSwitcherMenu(relativeTo: sender) }
        overlay.onStep = { [weak self] direction in self?.stepSwitcher(by: direction) }
        overlay.onHoverChanged = { [weak self] hovered in self?.setOrbitItemHovered(hovered) }
        panel.contentView = overlay
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        orbitWindow = panel
        orbitSwitcherView = overlay
        refreshClickAwayMonitoring()
        overlay.configure(
            items: noteSlots,
            activeURL: noteURL,
            anchor: localAnchor,
            placement: layout.placement,
            animated: animated
        )
    }

    private func switcherLayout(around screenAnchor: NSPoint, usesFullDisplay: Bool = false) -> SwitcherLayout {
        let screen = NSScreen.screens.first(where: {
            (usesFullDisplay ? $0.frame : $0.visibleFrame).contains(screenAnchor)
        }) ?? window?.screen ?? NSScreen.main
        let availableFrame = usesFullDisplay ? screen?.frame : screen?.visibleFrame
        let displayFrame = availableFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let roomAbove = displayFrame.maxY - screenAnchor.y
        let roomBelow = screenAnchor.y - displayFrame.minY
        let placement: NoteSwitcherPlacement
        if roomAbove < 160, roomBelow > roomAbove {
            placement = .below
        } else if roomBelow < 160, roomAbove > roomBelow {
            placement = .above
        } else {
            placement = .balanced
        }

        let size = placement == .balanced ? NSSize(width: 240, height: 246) : NSSize(width: 240, height: 220)
        let roomRight = displayFrame.maxX - screenAnchor.x
        let anchorX: CGFloat = roomRight < 210 ? 200 : 40
        let anchorY: CGFloat
        switch placement {
        case .balanced: anchorY = size.height / 2
        case .above: anchorY = 22
        case .below: anchorY = size.height - 22
        }
        return SwitcherLayout(size: size, anchor: NSPoint(x: anchorX, y: anchorY), placement: placement)
    }

    private func scheduleOrbitClose() {
        guard isInitialHovered == false, isOrbitItemHovered == false else { return }
        orbitHideTimer?.invalidate()
        orbitHideTimer = Timer.scheduledTimer(withTimeInterval: 0.34, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isInitialHovered == false,
                      self.isOrbitItemHovered == false else { return }
                self.closeOrbit(animated: true)
            }
        }
    }

    private func closeOrbit(animated: Bool) {
        guard let overlay = orbitSwitcherView, let panel = orbitWindow else { return }
        orbitSwitcherView = nil
        orbitWindow = nil
        refreshClickAwayMonitoring()
        let removePanel = { [weak self, weak panel] in
            guard let panel else { return }
            self?.window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard animated else {
            removePanel()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().alphaValue = 0
        }
        Timer.scheduledTimer(withTimeInterval: 0.16, repeats: false) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let panel else { return }
                self?.window?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
    }

    private func stepSwitcher(by direction: Int) {
        guard noteSlots.count > 1,
              let currentIndex = noteSlots.firstIndex(where: {
                  $0.url.standardizedFileURL == noteURL.standardizedFileURL
              }) else { return }
        let nextIndex = (currentIndex + direction + noteSlots.count) % noteSlots.count
        switchToNote(noteSlots[nextIndex])
        if orbitSwitcherView != nil { showOrbit(animated: true) }
    }

    private func showSwitcherMenu(relativeTo sender: NSView) {
        let menu = NSMenu()
        let assignedPaths = Set(noteSlots.map { $0.url.standardizedFileURL.path })
        let available = storage.recentNotes(limit: 10_000).filter {
            assignedPaths.contains($0.url.standardizedFileURL.path) == false
        }

        let addHeader = NSMenuItem(title: noteSlots.count < 5 ? "Add Note" : "Replace a Slot", action: nil, keyEquivalent: "")
        addHeader.isEnabled = false
        menu.addItem(addHeader)
        if available.isEmpty {
            let empty = NSMenuItem(title: "No other notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for note in available {
                let item = NSMenuItem(title: note.title, action: noteSlots.count < 5 ? #selector(addSwitcherNote(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.representedObject = note.url
                if noteSlots.count >= 5 {
                    let replacements = NSMenu()
                    for slot in noteSlots where slot.url.standardizedFileURL != noteURL.standardizedFileURL {
                        let replacement = NSMenuItem(title: "Replace \(slot.title)", action: #selector(replaceSwitcherNote(_:)), keyEquivalent: "")
                        replacement.target = self
                        replacement.representedObject = ["new": note.url, "old": slot.url]
                        replacements.addItem(replacement)
                    }
                    item.submenu = replacements
                }
                menu.addItem(item)
            }
        }

        let removable = noteSlots.filter { $0.url.standardizedFileURL != noteURL.standardizedFileURL }
        if removable.isEmpty == false {
            menu.addItem(.separator())
            let removeHeader = NSMenuItem(title: "Remove from Switcher", action: nil, keyEquivalent: "")
            removeHeader.isEnabled = false
            menu.addItem(removeHeader)
            for slot in removable {
                let item = NSMenuItem(title: slot.title, action: #selector(removeSwitcherNote(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = slot.url
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY - 3), in: sender)
    }

    @objc private func addSwitcherNote(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, noteSlots.count < 5 else { return }
        noteSlots.append(NoteSwitcherItem(title: NoteStorage.noteTitle(from: url), url: url))
        onChange()
        refreshOpenSwitchers()
    }

    @objc private func replaceSwitcherNote(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: URL],
              let newURL = payload["new"], let oldURL = payload["old"],
              let index = noteSlots.firstIndex(where: { $0.url.standardizedFileURL == oldURL.standardizedFileURL }) else { return }
        noteSlots[index] = NoteSwitcherItem(title: NoteStorage.noteTitle(from: newURL), url: newURL)
        onChange()
        refreshOpenSwitchers()
    }

    @objc private func removeSwitcherNote(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        noteSlots.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        onChange()
        refreshOpenSwitchers()
    }

    private func refreshOpenSwitchers() {
        if orbitSwitcherView != nil { showOrbit(animated: false) }
        updateFloatingView(expanded: isFloatingExpanded, animated: false)
    }

    private func switchToNote(_ note: NoteSwitcherItem) {
        guard note.url.standardizedFileURL != noteURL.standardizedFileURL else { return }
        autosaveTimer?.invalidate()
        saveNow()

        noteID = UUID().uuidString
        noteURL = note.url
        noteTitle = note.title
        updateTitleButton()
        window?.title = noteTitle
        loadContent()
        onChange()
        updateFloatingView(expanded: isFloatingExpanded, animated: false)
    }

    private func loadContent() {
        if let document = storage.loadDocument(from: noteURL) {
            editorView.load(document: document)
            return
        }

        let markdown = storage.loadMarkdown(from: noteURL)
        if noteTitle == "Untitled Note", let firstLine = markdown.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let oldURL = noteURL
            noteTitle = String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#* -\t")))
            noteURL = (try? storage.renameNote(at: noteURL, id: noteID, title: noteTitle)) ?? noteURL
            updateCurrentSlot(from: oldURL)
            updateTitleButton()
            window?.title = noteTitle
        }
        editorView.load(document: EditorDocument(html: Self.html(fromMarkdown: markdown), plainText: markdown))
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveNow()
            }
        }
    }

    private func saveNow() {
        let document = editorView.currentDocument()
        try? storage.save(document: document, to: noteURL)
        onChange()
    }

    private func setPreset(_ newPreset: SizePreset) {
        preset = newPreset
        guard let window else { return }
        editorView.captureViewportAnchor()
        var frame = window.frame
        frame.origin.y += frame.height - newPreset.size.height
        frame.size = newPreset.size
        window.setFrame(frame, display: true, animate: true)
        restoreViewportAnchorAfterResize()
        updateSizeButton()
        onChange()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        editorView.captureViewportAnchor()
    }

    func windowDidResize(_ notification: Notification) {
        if orbitSwitcherView != nil { showOrbit(animated: false) }
        editorView.restoreViewportAnchor()
    }

    func windowDidMove(_ notification: Notification) {
        if orbitSwitcherView != nil { showOrbit(animated: false) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        restoreViewportAnchorAfterResize()
        onChange()
    }

    private func restoreViewportAnchorAfterResize() {
        editorView.restoreViewportAnchor()
        DispatchQueue.main.async { [weak self] in
            self?.editorView.restoreViewportAnchor()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.editorView.restoreViewportAnchor()
        }
    }

    private func applyPinnedState() {
        window?.level = isPinned ? .floating : .normal
        updatePinButton()
    }

    private func collapseToFloatingInitial() {
        guard let window else { return }
        saveNow()
        closeOrbit(animated: false)
        ensureFloatingControl()
        window.orderOut(nil)
        updateFloatingView(expanded: false, animated: false)
        floatingWindow?.orderFront(nil)
    }

    private func ensureFloatingControl() {
        if floatingWindow != nil {
            floatingWindow?.orderFront(nil)
            updateFloatingView(expanded: isFloatingExpanded, animated: false)
            return
        }
        guard let window else { return }
        let defaultAnchor = NSPoint(x: window.frame.minX + 38, y: window.frame.maxY - 30)
        let screenAnchor = visibleFloatingAnchor(floatingAnchorOnScreen ?? defaultAnchor)
        floatingAnchorOnScreen = screenAnchor
        let origin = NSPoint(x: screenAnchor.x - 24, y: screenAnchor.y - 24)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: 48, height: 48)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let view = FloatingSwitcherView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 48, height: 48))
        view.autoresizingMask = [.width, .height]
        view.onActivate = { [weak self] in self?.toggleFromFloatingControl() }
        view.onHoverChanged = { [weak self] hovered in self?.setFloatingHovered(hovered) }
        view.onSelect = { [weak self] item in
            guard let self else { return }
            self.switchToNote(item)
            self.restoreFromFloatingInitial()
        }
        view.onAdd = { [weak self] sender in self?.showSwitcherMenu(relativeTo: sender) }
        view.onStep = { [weak self] direction in
            self?.stepSwitcher(by: direction)
            self?.updateFloatingView(expanded: true, animated: true)
        }
        view.onDragging = { [weak self] point in
            guard let self else { return }
            let anchor = self.visibleFloatingAnchor(point)
            self.floatingAnchorOnScreen = anchor
            self.updateFloatingView(
                expanded: self.isFloatingExpanded,
                animated: false,
                anchorOnScreen: anchor
            )
        }
        view.onMoved = { [weak self] point in
            guard let self else { return }
            let anchor = self.visibleFloatingAnchor(point)
            self.floatingAnchorOnScreen = anchor
            self.updateFloatingView(
                expanded: self.isFloatingExpanded,
                animated: false,
                anchorOnScreen: anchor
            )
            self.onChange()
            self.updateFloatingContrast()
        }
        panel.contentView = view
        floatingWindow = panel
        floatingView = view
        isFloatingExpanded = false
        floatingSwitcherAnchor = NSPoint(x: 24, y: 24)
        floatingPlacement = .balanced
        updateFloatingView(expanded: false, animated: false)
        panel.orderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.updateFloatingContrast() }
    }

    private func toggleFromFloatingControl() {
        if window?.isVisible == true {
            collapseToFloatingInitial()
        } else {
            restoreFromFloatingInitial()
        }
    }

    private func restoreFromFloatingInitial() {
        floatingHideTimer?.invalidate()
        rememberFloatingAnchor()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateFloatingView(expanded: false, animated: false)
        floatingWindow?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func removeFloatingControl() {
        floatingHideTimer?.invalidate()
        rememberFloatingAnchor()
        floatingWindow?.orderOut(nil)
        floatingWindow = nil
        floatingView = nil
        isFloatingExpanded = false
        floatingSwitcherAnchor = NSPoint(x: 24, y: 24)
        floatingPlacement = .balanced
        refreshClickAwayMonitoring()
    }

    private func setFloatingHovered(_ hovered: Bool) {
        if hovered {
            floatingHideTimer?.invalidate()
            updateFloatingView(expanded: true, animated: isFloatingExpanded == false)
        } else {
            scheduleFloatingCollapse(after: 0.7)
        }
    }

    private func scheduleFloatingCollapse(after delay: TimeInterval) {
        floatingHideTimer?.invalidate()
        floatingHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.floatingWindow else { return }
                let proximityFrame = panel.frame.insetBy(dx: -30, dy: -30)
                if proximityFrame.contains(NSEvent.mouseLocation) {
                    self.scheduleFloatingCollapse(after: 0.35)
                } else {
                    self.updateFloatingView(expanded: false, animated: true)
                }
            }
        }
    }

    private func updateFloatingView(expanded: Bool, animated: Bool, anchorOnScreen explicitAnchor: NSPoint? = nil) {
        guard let panel = floatingWindow, let floatingView else { return }
        let currentAnchor = NSPoint(
            x: panel.frame.minX + floatingSwitcherAnchor.x,
            y: panel.frame.minY + floatingSwitcherAnchor.y
        )
        let anchorOnScreen = explicitAnchor ?? currentAnchor
        if expanded != isFloatingExpanded || expanded || explicitAnchor != nil {
            let layout = switcherLayout(around: anchorOnScreen, usesFullDisplay: true)
            let size = expanded ? layout.size : NSSize(width: 48, height: 48)
            let targetAnchor = expanded ? layout.anchor : NSPoint(x: 24, y: 24)
            let frame = NSRect(
                x: anchorOnScreen.x - targetAnchor.x,
                y: anchorOnScreen.y - targetAnchor.y,
                width: size.width,
                height: size.height
            )
            panel.setFrame(frame, display: true, animate: false)
            isFloatingExpanded = expanded
            floatingSwitcherAnchor = targetAnchor
            floatingPlacement = expanded ? layout.placement : .balanced
            floatingAnchorOnScreen = anchorOnScreen
        }
        floatingView.configure(
            activeTitle: noteTitle,
            activeURL: noteURL,
            items: noteSlots,
            expanded: expanded,
            anchor: floatingSwitcherAnchor,
            placement: floatingPlacement,
            showsMinimize: window?.isVisible == true,
            animated: animated
        )
        refreshClickAwayMonitoring()
    }

    private func refreshClickAwayMonitoring() {
        let shouldMonitor = orbitWindow != nil || isFloatingExpanded
        if shouldMonitor {
            guard localClickAwayMonitor == nil else { return }
            localClickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                Task { @MainActor in self?.dismissSwitchersIfClickAway(at: NSEvent.mouseLocation) }
                return event
            }
            globalClickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.dismissSwitchersIfClickAway(at: NSEvent.mouseLocation) }
            }
        } else {
            stopClickAwayMonitoring()
        }
    }

    private func stopClickAwayMonitoring() {
        if let localClickAwayMonitor { NSEvent.removeMonitor(localClickAwayMonitor) }
        if let globalClickAwayMonitor { NSEvent.removeMonitor(globalClickAwayMonitor) }
        localClickAwayMonitor = nil
        globalClickAwayMonitor = nil
    }

    private func dismissSwitchersIfClickAway(at screenPoint: NSPoint) {
        if let panel = orbitWindow, let overlay = orbitSwitcherView {
            let localPoint = NSPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
            if overlay.isInteractive(at: localPoint) == false && initialButtonScreenFrame().contains(screenPoint) == false {
                closeOrbit(animated: true)
            }
        }
        if isFloatingExpanded, let panel = floatingWindow, let floatingView {
            let localPoint = NSPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
            if floatingView.isInteractive(at: localPoint) == false {
                updateFloatingView(expanded: false, animated: true)
            }
        }
    }

    private func initialButtonScreenFrame() -> NSRect {
        guard let window else { return .zero }
        let rectInWindow = initialButton.convert(initialButton.bounds, to: nil)
        let origin = window.convertPoint(toScreen: rectInWindow.origin)
        return NSRect(origin: origin, size: rectInWindow.size)
    }

    private func updateFloatingContrast() {
        guard let panel = floatingWindow, let floatingView else { return }
        let anchorOnScreen = NSPoint(
            x: panel.frame.minX + floatingSwitcherAnchor.x,
            y: panel.frame.minY + floatingSwitcherAnchor.y
        )
        floatingView.applyContrast(over: Self.sampledScreenColor(at: anchorOnScreen, below: panel))
    }

    private static func sampledScreenColor(at appKitPoint: NSPoint, below panel: NSWindow) -> NSColor? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let sampleRect = CGRect(x: appKitPoint.x - 4, y: primaryTop - appKitPoint.y - 4, width: 9, height: 9)
        guard let image = CGWindowListCreateImage(
            sampleRect,
            .optionOnScreenBelowWindow,
            CGWindowID(panel.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
    }

    private func rememberFloatingAnchor() {
        guard let panel = floatingWindow else { return }
        floatingAnchorOnScreen = NSPoint(
            x: panel.frame.minX + floatingSwitcherAnchor.x,
            y: panel.frame.minY + floatingSwitcherAnchor.y
        )
        onChange()
    }

    private func visibleFloatingAnchor(_ point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.min { lhs, rhs in
                Self.distanceSquared(from: point, to: lhs.frame) < Self.distanceSquared(from: point, to: rhs.frame)
            }
            ?? window?.screen
            ?? NSScreen.main
        let displayFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return NSPoint(
            x: min(max(point.x, displayFrame.minX + 20), displayFrame.maxX - 20),
            y: min(max(point.y, displayFrame.minY + 20), displayFrame.maxY - 20)
        )
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        return pow(point.x - nearestX, 2) + pow(point.y - nearestY, 2)
    }

    private func updatePinButton() {
        guard let pinButton else { return }
        let label = isPinned ? "Always Hover On" : "Always Hover Off"
        pinButton.state = isPinned ? .on : .off
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: label)
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = label
    }

    private func updateSizeButton() {
        guard let sizeButton else { return }
        let label = "Window Size: \(preset.label)"
        sizeButton.image = NSImage(systemSymbolName: preset.symbolName, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "rectangle", accessibilityDescription: label)
            ?? NSImage()
        sizeButton.toolTip = label
    }

    private func updateMicButton(for state: VoiceTranscriber.State = .idle) {
        guard let micButton else { return }
        let label: String
        let symbol: String
        let tint: NSColor
        let isEnabled: Bool

        switch state {
        case .idle:
            label = "Start Transcription"
            symbol = "mic"
            tint = .secondaryLabelColor
            isEnabled = true
        case .recording:
            label = "Stop Recording"
            symbol = "stop.circle.fill"
            tint = .systemRed
            isEnabled = true
        case .transcribing:
            label = "Transcribing..."
            symbol = "waveform"
            tint = .controlAccentColor
            isEnabled = false
        case .failed(let message):
            label = "Transcription Failed: \(message)"
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
            isEnabled = true
        }

        micButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        micButton.contentTintColor = tint
        micButton.toolTip = label
        micButton.isEnabled = isEnabled
    }

    private func updateTitleButton() {
        titleLabel.stringValue = noteTitle
        initialButton.title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "•"
        initialButton.toolTip = nil
        titleButton.toolTip = nil
        titleField.stringValue = noteTitle
    }

    private func updateCurrentSlot(from oldURL: URL) {
        if let index = noteSlots.firstIndex(where: { $0.url.standardizedFileURL == oldURL.standardizedFileURL }) {
            noteSlots[index] = NoteSwitcherItem(title: noteTitle, url: noteURL)
        } else if noteSlots.count < 5 {
            noteSlots.append(NoteSwitcherItem(title: noteTitle, url: noteURL))
        }
    }

    private func export(content: String, fileExtension: String) {
        saveNow()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.safeFileName(noteTitle)).\(fileExtension)"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        NoteStorage.safeFileName(value)
    }

    private static func fullHTMLDocument(body: String, title: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>\(escapeHTML(title))</title>
          <style>
            body { font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; line-height: 1.48; }
            table { border-collapse: collapse; }
            td, th { border: 1px solid #c7c7c7; padding: 5px 8px; vertical-align: top; }
          </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func html(fromMarkdown markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: .newlines)
            .map { line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return "<ul><li>\(String(line.dropFirst(2)))</li></ul>"
                }
                return line.isEmpty ? "<p><br></p>" : "<p>\(line)</p>"
            }
            .joined()
    }

    private static func visibleRect(from rect: NSRect, fallbackSize: NSSize) -> NSRect {
        guard let visibleFrame = NSScreen.screens.map(\.visibleFrame).first(where: { $0.intersects(rect) }) else {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: fallbackSize)
            return NSRect(
                x: screenFrame.midX - fallbackSize.width / 2,
                y: screenFrame.midY - fallbackSize.height / 2,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }

        var adjusted = rect
        adjusted.size.width = max(min(adjusted.width, visibleFrame.width), fallbackSize.width)
        adjusted.size.height = max(min(adjusted.height, visibleFrame.height), fallbackSize.height)
        if adjusted.maxX < visibleFrame.minX + 80 { adjusted.origin.x = visibleFrame.minX + 40 }
        if adjusted.minX > visibleFrame.maxX - 80 { adjusted.origin.x = visibleFrame.maxX - adjusted.width - 40 }
        if adjusted.maxY < visibleFrame.minY + 80 { adjusted.origin.y = visibleFrame.minY + 40 }
        if adjusted.minY > visibleFrame.maxY - 80 { adjusted.origin.y = visibleFrame.maxY - adjusted.height - 40 }
        return adjusted
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension NoteWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sizePreset, .noteTitle, .voiceTranscription, .pin, .export, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sizePreset, .pin, .noteTitle, .flexibleSpace, .voiceTranscription, .export]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sizePreset:
            return sizePresetItem(id: itemIdentifier)
        case .noteTitle:
            return titleItem(id: itemIdentifier)
        case .voiceTranscription:
            return voiceTranscriptionItem(id: itemIdentifier)
        case .pin:
            return pinItem(id: itemIdentifier)
        case .export:
            return exportItem(id: itemIdentifier)
        default:
            return nil
        }
    }

    private func sizePresetItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Size"
        item.paletteLabel = "Toggle Window Size"
        item.visibilityPriority = .high

        let button = NSButton(image: NSImage(), target: self, action: #selector(toggleSizePreset(_:)))
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])

        sizeButton = button
        updateSizeButton()
        item.toolTip = button.toolTip
        item.view = button
        return item
    }

    private func pinItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Always Hover"
        item.paletteLabel = "Always Hover"
        item.visibilityPriority = .high

        let button = NSButton(image: NSImage(), target: self, action: #selector(togglePinned(_:)))
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        pinButton = button
        updatePinButton()
        item.toolTip = button.toolTip
        item.view = button
        return item
    }

    private func voiceTranscriptionItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Transcribe"
        item.paletteLabel = "Transcribe"
        item.visibilityPriority = .high

        let button = NSButton(image: NSImage(), target: self, action: #selector(toggleVoiceTranscription(_:)))
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        micButton = button
        updateMicButton()
        item.toolTip = button.toolTip
        item.view = button
        return item
    }

    private func titleItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Note Title"
        item.paletteLabel = "Note Title"
        item.visibilityPriority = .high

        configureTitleControls()
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 210, height: 22))
        container.material = .headerView
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 11
        container.layer?.masksToBounds = true
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleSwitcherView = container
        initialButton.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        if initialButton.superview !== container {
            initialButton.removeFromSuperview()
            container.addSubview(initialButton)
        }
        if titleLabel.superview !== container {
            titleLabel.removeFromSuperview()
            container.addSubview(titleLabel)
        }
        if titleButton.superview !== container {
            titleButton.removeFromSuperview()
            container.addSubview(titleButton)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 190),
            container.heightAnchor.constraint(equalToConstant: 22),
            initialButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            initialButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            initialButton.widthAnchor.constraint(equalToConstant: 20),
            initialButton.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: initialButton.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 2),
            titleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleButton.widthAnchor.constraint(equalToConstant: 20),
            titleButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        item.view = container
        return item
    }

    private func exportItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Export"
        item.paletteLabel = "Export"
        item.toolTip = "Export"

        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export") ?? NSImage(), target: self, action: #selector(showExportMenu(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown

        item.view = button
        item.visibilityPriority = .standard
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let sizePreset = NSToolbarItem.Identifier("sizePreset")
    static let noteTitle = NSToolbarItem.Identifier("noteTitle")
    static let voiceTranscription = NSToolbarItem.Identifier("voiceTranscription")
    static let pin = NSToolbarItem.Identifier("pin")
    static let export = NSToolbarItem.Identifier("export")
}

private final class DraggableTitleLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
