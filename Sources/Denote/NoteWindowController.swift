import AppKit
import DenoteCore

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
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
    private let noteID: String
    private var noteURL: URL
    private let onClose: (NoteWindowController) -> Void
    private let onChange: () -> Void
    private let editorView = BlockEditorView()
    private let voiceTranscriber = VoiceTranscriber()
    private let titleLabel = DraggableTitleLabel()
    private let titleButton = NSButton()
    private let titleField = NSTextField()
    private weak var sizeButton: NSButton?
    private weak var pinButton: NSButton?
    private weak var micButton: NSButton?
    private var titlePopover: NSPopover?
    private var noteTitle: String
    private var preset: SizePreset
    private var isPinned: Bool
    private var autosaveTimer: Timer?

    init(storage: NoteStorage, noteState: NoteState, onClose: @escaping (NoteWindowController) -> Void, onChange: @escaping () -> Void) {
        self.storage = storage
        self.noteID = noteState.id
        self.noteURL = URL(fileURLWithPath: noteState.path)
        self.noteTitle = noteState.title
        self.preset = SizePreset.storedValue(noteState.preset)
        self.isPinned = noteState.isPinned
        self.onClose = onClose
        self.onChange = onChange

        let rect: NSRect
        if let frame = noteState.frame {
            rect = Self.visibleRect(from: NSRectFromString(frame), fallbackSize: preset.size)
        } else {
            rect = NSRect(origin: .zero, size: preset.size)
        }

        let window = NSWindow(
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
        if noteState.frame == nil {
            window.center()
        }
        setupContent()
        setupVoiceTranscription()
        setupToolbar()
        applyPinnedState()
        loadContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func currentState() -> NoteState? {
        guard let window else { return nil }
        guard editorView.currentDocument().isBlank == false else { return nil }
        return NoteState(id: noteID, path: noteURL.path, title: noteTitle, frame: NSStringFromRect(window.frame), preset: preset.rawValue, isPinned: isPinned)
    }

    func windowWillClose(_ notification: Notification) {
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
        noteTitle = trimmed.isEmpty ? storage.randomNoteTitle() : trimmed
        updateTitleButton()
        window?.title = noteTitle
        if editorView.currentDocument().isBlank == false {
            noteURL = (try? storage.renameNote(at: noteURL, id: noteID, title: noteTitle)) ?? noteURL
        } else {
            noteURL = storage.createNoteURL(id: noteID, title: noteTitle)
        }
        saveNow()
        onChange()
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

        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        titleButton.imagePosition = .imageOnly
        titleButton.contentTintColor = .secondaryLabelColor
        titleButton.controlSize = .small
        titleButton.target = self
        titleButton.action = #selector(showTitlePopover(_:))
        titleButton.toolTip = "Rename \(noteTitle)"
        updateTitleButton()
    }

    private func loadContent() {
        if let document = storage.loadDocument(from: noteURL) {
            editorView.load(document: document)
            return
        }

        let markdown = storage.loadMarkdown(from: noteURL)
        if noteTitle == "Untitled Note", let firstLine = markdown.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            noteTitle = String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#* -\t")))
            updateTitleButton()
            window?.title = noteTitle
            noteURL = (try? storage.renameNote(at: noteURL, id: noteID, title: noteTitle)) ?? noteURL
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
        editorView.restoreViewportAnchor()
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
        titleButton.toolTip = "Rename \(noteTitle)"
        titleField.stringValue = noteTitle
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
        [.sizePreset, .pin, .flexibleSpace, .noteTitle, .voiceTranscription, .flexibleSpace, .export]
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
        item.toolTip = "Rename \(noteTitle)"
        item.visibilityPriority = .high

        configureTitleControls()
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 210, height: 22))
        container.material = .headerView
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 11
        container.layer?.masksToBounds = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        if titleLabel.superview !== container {
            titleLabel.removeFromSuperview()
            container.addSubview(titleLabel)
        }
        if titleButton.superview !== container {
            titleButton.removeFromSuperview()
            container.addSubview(titleButton)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            container.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
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
