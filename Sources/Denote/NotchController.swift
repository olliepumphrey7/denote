import AppKit
import DenoteCore

@MainActor
final class NotchController: NSObject {
    private struct Metrics {
        let collapsedSize: NSSize
        let expandedSize: NSSize
        let hoverActivationWidth: CGFloat
    }

    private let storage: NoteStorage
    private let activeNoteURL: () -> URL
    private let activeNoteTitle: () -> String
    private let noteWindowIsVisible: () -> Bool
    private let shortcutTitle: () -> String
    private let onToggleWindow: () -> Void
    private let onHideWindow: () -> Void
    private let onNewNote: () -> Void
    private let onOpenNote: (URL) -> Void
    private let onOpenSettings: () -> Void
    private let screenNumber: NSNumber
    private let syntheticMenuBarHeight: CGFloat
    private let usesSyntheticNotch: Bool

    private let panel: NotchPanel
    private let islandView: NotchIslandView
    private var isExpanded = false
    private var collapseWorkItem: DispatchWorkItem?
    private var hoverTimer: DispatchSourceTimer?
    private var pointerWasInside = false

    init(
        screen: NSScreen,
        storage: NoteStorage,
        activeNoteURL: @escaping () -> URL,
        activeNoteTitle: @escaping () -> String,
        noteWindowIsVisible: @escaping () -> Bool,
        shortcutTitle: @escaping () -> String,
        onToggleWindow: @escaping () -> Void,
        onHideWindow: @escaping () -> Void,
        onNewNote: @escaping () -> Void,
        onOpenNote: @escaping (URL) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.storage = storage
        self.activeNoteURL = activeNoteURL
        self.activeNoteTitle = activeNoteTitle
        self.noteWindowIsVisible = noteWindowIsVisible
        self.shortcutTitle = shortcutTitle
        self.onToggleWindow = onToggleWindow
        self.onHideWindow = onHideWindow
        self.onNewNote = onNewNote
        self.onOpenNote = onOpenNote
        self.onOpenSettings = onOpenSettings
        self.screenNumber = Self.screenNumber(for: screen)
        self.syntheticMenuBarHeight = Self.menuBarHeight(for: screen)
        self.usesSyntheticNotch = screen.safeAreaInsets.top <= 0

        panel = NotchPanel()
        islandView = NotchIslandView(
            iconOffset: Self.notchBodyWidth(for: screen) / 2
        )
        super.init()

        panel.hasShadow = usesSyntheticNotch == false
        panel.contentView = islandView
        islandView.onToggleCurrentNote = { [weak self] in
            guard let self else { return }
            self.onToggleWindow()
            self.collapse()
            self.refresh()
        }
        islandView.onNewNote = { [weak self] in
            guard let self else { return }
            self.onNewNote()
            self.collapse()
            self.refresh()
        }
        islandView.onOpenNote = { [weak self] url in
            guard let self else { return }
            self.onOpenNote(url)
            self.collapse()
            self.refresh()
        }
        islandView.onMinimiseCurrentNote = { [weak self] in
            guard let self else { return }
            self.onHideWindow()
            self.collapse()
            self.refresh()
        }
        islandView.onShowContextMenu = { [weak self] event, view in
            self?.showContextMenu(event: event, in: view)
        }

        positionPanel(animated: false)
        refresh()
        panel.orderFrontRegardless()
        startHoverMonitoring()
    }

    func refresh() {
        let activeURL = activeNoteURL().standardizedFileURL
        let isVisible = noteWindowIsVisible()
        var notes = storage.recentNotes(limit: 10_000)

        if isVisible,
           notes.contains(where: { $0.url.standardizedFileURL == activeURL }) == false {
            notes.insert(
                NoteStorage.RecentNote(
                    title: activeNoteTitle(),
                    url: activeURL,
                    modifiedAt: Date()
                ),
                at: 0
            )
        }

        islandView.configure(
            notes: notes,
            activeURL: activeURL,
            noteWindowIsVisible: isVisible
        )
        if panel.isVisible == false {
            panel.orderFrontRegardless()
        }
    }

    func closeTray() {
        collapse()
    }

    func invalidate() {
        collapseWorkItem?.cancel()
        hoverTimer?.cancel()
        hoverTimer = nil
        panel.orderOut(nil)
    }

    private func handleHover(_ isHovering: Bool) {
        collapseWorkItem?.cancel()
        if isHovering {
            expand()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.panelContainsPointIncludingTopEdge(NSEvent.mouseLocation) == false {
                self.collapse()
            }
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func startHoverMonitoring() {
        hoverTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isInside = self.pointerIsInsideInteractiveRegion(NSEvent.mouseLocation)
                guard isInside != self.pointerWasInside else { return }
                self.pointerWasInside = isInside
                self.handleHover(isInside)
            }
        }
        timer.resume()
        hoverTimer = timer
    }

    private func expand() {
        guard isExpanded == false else { return }
        isExpanded = true
        panel.hasShadow = true
        refresh()
        islandView.setExpanded(true, animated: true)
        positionPanel(animated: true)
    }

    private func collapse() {
        collapseWorkItem?.cancel()
        guard isExpanded else { return }
        isExpanded = false
        if usesSyntheticNotch {
            panel.hasShadow = false
        }
        islandView.setExpanded(false, animated: true)
        positionPanel(animated: true)
    }

    private func positionPanel(animated: Bool) {
        guard let screen = targetScreen() else {
            panel.orderOut(nil)
            return
        }
        let metrics = metrics(for: screen)
        let size = isExpanded ? metrics.expandedSize : metrics.collapsedSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if animated, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.88,
                    0.28,
                    1
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first {
            Self.screenNumber(for: $0) == screenNumber
        }
    }

    private func metrics(for screen: NSScreen) -> Metrics {
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchBodyWidth = Self.notchBodyWidth(for: screen)

        let collapsedWidth = hasNotch
            ? min(max(notchBodyWidth + 64, 236), 280)
            : notchBodyWidth + 64
        let collapsedHeight = hasNotch
            ? max(screen.safeAreaInsets.top, 32)
            : syntheticMenuBarHeight
        let expandedWidth = min(max(screen.frame.width * 0.60, 680), 860)
        let expandedHeight: CGFloat = 184

        return Metrics(
            collapsedSize: NSSize(width: collapsedWidth, height: collapsedHeight),
            expandedSize: NSSize(width: expandedWidth, height: expandedHeight),
            hoverActivationWidth: notchBodyWidth
        )
    }

    private func pointerIsInsideInteractiveRegion(_ point: NSPoint) -> Bool {
        guard panelContainsPointIncludingTopEdge(point) else { return false }
        guard isExpanded == false, let screen = targetScreen() else { return true }

        let activationWidth = metrics(for: screen).hoverActivationWidth
        let minimumX = panel.frame.midX - activationWidth / 2
        let maximumX = panel.frame.midX + activationWidth / 2
        return point.x >= minimumX && point.x <= maximumX
    }

    private func panelContainsPointIncludingTopEdge(_ point: NSPoint) -> Bool {
        point.x >= panel.frame.minX
            && point.x <= panel.frame.maxX
            && point.y >= panel.frame.minY
            && point.y <= panel.frame.maxY + 1
    }

    private static func screenNumber(for screen: NSScreen) -> NSNumber {
        screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber ?? 0
    }

    private static func notchBodyWidth(for screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 {
                return width
            }
        }
        return 108
    }

    private static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let targetX = screen.frame.minX
        let targetY = primaryTop - screen.frame.maxY
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return 30
        }

        for window in windows {
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowName as String] as? String == "Menubar",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(
                    dictionaryRepresentation: bounds as CFDictionary
                  ),
                  abs(rect.minX - targetX) < 1,
                  abs(rect.minY - targetY) < 1 else {
                continue
            }
            return max(24, rect.height)
        }
        return 30
    }

    private func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggle = NSMenuItem(
            title: noteWindowIsVisible() ? "Minimise Current Note" : "Open Current Note",
            action: #selector(toggleCurrentFromMenu(_:)),
            keyEquivalent: ""
        )
        configure(toggle)
        menu.addItem(toggle)

        let newNote = NSMenuItem(
            title: "New Note",
            action: #selector(createNewNoteFromMenu(_:)),
            keyEquivalent: "n"
        )
        newNote.keyEquivalentModifierMask = [.command]
        configure(newNote)
        menu.addItem(newNote)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        configure(settings)
        menu.addItem(settings)

        let shortcut = NSMenuItem(
            title: "Shortcut: \(shortcutTitle())",
            action: nil,
            keyEquivalent: ""
        )
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Denote",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        configure(quit)
        menu.addItem(quit)

        menu.popUp(
            positioning: nil,
            at: event.locationInWindow,
            in: view
        )
    }

    private func configure(_ item: NSMenuItem) {
        item.target = self
        item.isEnabled = true
    }

    @objc private func toggleCurrentFromMenu(_ sender: NSMenuItem) {
        onToggleWindow()
        collapse()
        refresh()
    }

    @objc private func createNewNoteFromMenu(_ sender: NSMenuItem) {
        onNewNote()
        collapse()
        refresh()
    }

    @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class NotchIslandView: NSView {
    var onToggleCurrentNote: (() -> Void)?
    var onNewNote: (() -> Void)?
    var onOpenNote: ((URL) -> Void)?
    var onMinimiseCurrentNote: (() -> Void)?
    var onShowContextMenu: ((NSEvent, NSView) -> Void)?

    private let currentButton = IslandIconButton(
        symbolName: "doc.text.fill",
        accessibilityLabel: "Show or minimise current note"
    )
    private let newButton = IslandIconButton(
        symbolName: "plus",
        accessibilityLabel: "New note"
    )
    private let activeDot = NSView()
    private let cardScrollView = HorizontalNotchScrollView()
    private let cardDocumentView = FlippedView()
    private var isExpanded = false

    init(iconOffset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        currentButton.target = self
        currentButton.action = #selector(toggleCurrentNote(_:))
        newButton.target = self
        newButton.action = #selector(createNewNote(_:))

        activeDot.wantsLayer = true
        activeDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        activeDot.layer?.cornerRadius = 3.5
        activeDot.isHidden = true

        cardScrollView.drawsBackground = false
        cardScrollView.hasVerticalScroller = false
        cardScrollView.hasHorizontalScroller = false
        cardScrollView.autohidesScrollers = true
        cardScrollView.scrollerStyle = .overlay
        cardScrollView.horizontalScrollElasticity = .allowed
        cardScrollView.verticalScrollElasticity = .none
        cardScrollView.documentView = cardDocumentView
        cardScrollView.alphaValue = 0
        cardScrollView.isHidden = true

        [currentButton, newButton, activeDot, cardScrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            currentButton.trailingAnchor.constraint(
                equalTo: centerXAnchor,
                constant: -iconOffset
            ),
            currentButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            currentButton.widthAnchor.constraint(equalToConstant: 24),
            currentButton.heightAnchor.constraint(equalToConstant: 24),

            newButton.leadingAnchor.constraint(
                equalTo: centerXAnchor,
                constant: iconOffset
            ),
            newButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            newButton.widthAnchor.constraint(equalToConstant: 24),
            newButton.heightAnchor.constraint(equalToConstant: 24),

            activeDot.widthAnchor.constraint(equalToConstant: 4),
            activeDot.heightAnchor.constraint(equalToConstant: 4),
            activeDot.leadingAnchor.constraint(equalTo: currentButton.leadingAnchor),
            activeDot.topAnchor.constraint(equalTo: currentButton.topAnchor),

            cardScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            cardScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            cardScrollView.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            cardScrollView.heightAnchor.constraint(equalToConstant: 110)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onShowContextMenu?(event, self)
    }

    func configure(
        notes: [NoteStorage.RecentNote],
        activeURL: URL,
        noteWindowIsVisible: Bool
    ) {
        activeDot.isHidden = noteWindowIsVisible == false
        currentButton.setActive(noteWindowIsVisible)

        cardDocumentView.subviews.forEach { $0.removeFromSuperview() }
        let cardWidth: CGFloat = 140
        let cardHeight: CGFloat = 96
        let spacing: CGFloat = 10
        let count = max(notes.count, 1)
        let documentHeight: CGFloat = 104
        cardDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(count) * cardWidth + CGFloat(max(0, count - 1)) * spacing,
            height: documentHeight
        )

        if notes.isEmpty {
            let empty = NSTextField(labelWithString: "No saved notes yet")
            empty.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            empty.textColor = NSColor(calibratedWhite: 0.58, alpha: 1)
            empty.frame = NSRect(x: 8, y: 36, width: 220, height: 22)
            cardDocumentView.addSubview(empty)
            return
        }

        for (index, note) in notes.enumerated() {
            let isActive = note.url.standardizedFileURL == activeURL
            let card = NotchNoteCard(
                note: note,
                showsMinimise: isActive && noteWindowIsVisible
            )
            card.frame = NSRect(
                x: CGFloat(index) * (cardWidth + spacing),
                y: 2,
                width: cardWidth,
                height: cardHeight
            )
            card.target = self
            card.action = #selector(cardPressed(_:))
            cardDocumentView.addSubview(card)
        }
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        if expanded {
            cardScrollView.isHidden = false
        }
        let changes = {
            self.cardScrollView.animator().alphaValue = expanded ? 1 : 0
            self.layer?.cornerRadius = expanded ? 30 : 11
        }
        if animated, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                changes()
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    if expanded == false {
                        self?.cardScrollView.isHidden = true
                    }
                }
            }
        } else {
            cardScrollView.alphaValue = expanded ? 1 : 0
            layer?.cornerRadius = expanded ? 30 : 11
            cardScrollView.isHidden = expanded == false
        }
    }

    @objc private func toggleCurrentNote(_ sender: NSButton) {
        onToggleCurrentNote?()
    }

    @objc private func createNewNote(_ sender: NSButton) {
        onNewNote?()
    }

    @objc private func cardPressed(_ sender: NotchNoteCard) {
        if sender.showsMinimise {
            onMinimiseCurrentNote?()
        } else {
            onOpenNote?(sender.noteURL)
        }
    }
}

@MainActor
private final class IslandIconButton: NSButton {
    private let symbolName: String

    init(symbolName: String, accessibilityLabel: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        setActive(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setActive(_ active: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        contentTintColor = active ? .white : NSColor(calibratedWhite: 0.86, alpha: 1)
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class NotchNoteCard: NSButton {
    let noteURL: URL
    let showsMinimise: Bool
    private var trackingAreaReference: NSTrackingArea?

    init(note: NoteStorage.RecentNote, showsMinimise: Bool) {
        self.noteURL = note.url
        self.showsMinimise = showsMinimise
        super.init(frame: .zero)

        isBordered = false
        title = ""
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        if showsMinimise {
            configureMinimiseContent()
            setAccessibilityLabel("Minimise \(note.title)")
            toolTip = "Minimise \(note.title)"
        } else {
            configureNoteContent(note)
            setAccessibilityLabel("Open \(note.title)")
            toolTip = "Open \(note.title)"
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.34, alpha: 1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
    }

    private func configureMinimiseContent() {
        let cross = NSTextField(labelWithString: "×")
        cross.font = NSFont.systemFont(ofSize: 38, weight: .light)
        cross.textColor = .white
        cross.alignment = .center
        cross.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Minimise")
        label.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cross)
        addSubview(label)
        NSLayoutConstraint.activate([
            cross.centerXAnchor.constraint(equalTo: centerXAnchor),
            cross.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            cross.widthAnchor.constraint(equalToConstant: 70),
            cross.heightAnchor.constraint(equalToConstant: 48),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: cross.bottomAnchor, constant: 4)
        ])
    }

    private func configureNoteContent(_ note: NoteStorage.RecentNote) {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accentColor(for: note.title).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: note.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let time = NSTextField(labelWithString: timeLabel(for: note.modifiedAt))
        time.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        time.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        time.translatesAutoresizingMaskIntoConstraints = false

        let previewText = note.preview.isEmpty ? "No preview yet" : note.preview
        let preview = NSTextField(wrappingLabelWithString: previewText)
        preview.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        preview.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false

        [dot, title, time, preview].forEach { addSubview($0) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            time.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 10)
        ])
    }

    private func accentColor(for title: String) -> NSColor {
        let colors: [NSColor] = [
            .systemBlue,
            .systemPurple,
            .systemOrange,
            .systemGreen,
            .systemYellow
        ]
        let value = title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[value % colors.count]
    }

    private func timeLabel(for date: Date) -> String {
        guard date != .distantPast else { return "Saved note" }
        if Calendar.current.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HorizontalNotchScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let contentView = contentView as NSClipView? else {
            super.scrollWheel(with: event)
            return
        }

        let horizontalDelta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        var origin = contentView.bounds.origin
        origin.x -= horizontalDelta * multiplier
        let maxX = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        origin.x = min(max(origin.x, 0), maxX)
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }
}
