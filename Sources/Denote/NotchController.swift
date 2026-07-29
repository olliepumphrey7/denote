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
    private let onArchiveNote: (URL) -> Void
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
        onArchiveNote: @escaping (URL) -> Void,
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
        self.onArchiveNote = onArchiveNote
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
        islandView.onArchiveNote = { [weak self] url in
            guard let self else { return }
            self.onArchiveNote(url)
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
    var onArchiveNote: ((URL) -> Void)?
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
            let empty = MousePassthroughTextField(labelWithString: "No saved notes yet")
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
            card.onArchive = { [weak self, weak card] in
                guard let self, let card else { return }
                self.confirmArchive(card)
            }
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

    private func confirmArchive(_ card: NotchNoteCard) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive “\(card.noteTitle)”?"
        alert.informativeText = "Are you sure? The note will be moved to the Archive folder and can be recovered later."
        alert.addButton(withTitle: "Archive Note")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onArchiveNote?(card.noteURL)
    }
}

@MainActor
private final class IslandIconButton: NSButton {
    private let symbolName: String
    private var trackingAreaReference: NSTrackingArea?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class NotchNoteCard: NSButton {
    let noteURL: URL
    let noteTitle: String
    let showsMinimise: Bool
    var onArchive: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private let archiveButton = NSButton()

    init(note: NoteStorage.RecentNote, showsMinimise: Bool) {
        self.noteURL = note.url
        self.noteTitle = note.title
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

        configureNoteContent(note)
        if showsMinimise {
            configureMinimiseOverlay()
            setAccessibilityLabel("Minimise \(note.title)")
            toolTip = "Minimise \(note.title)"
        } else {
            setAccessibilityLabel("Open \(note.title)")
            toolTip = "Open \(note.title)"
        }
        configureArchiveButton()
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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              let scrollView = enclosingScrollView as? HorizontalNotchScrollView else {
            super.mouseDown(with: event)
            return
        }

        let start = event.locationInWindow
        var previous = start
        var isDragging = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                let current = next.locationInWindow
                let totalX = current.x - start.x
                let totalY = current.y - start.y
                if isDragging == false,
                   sqrt(totalX * totalX + totalY * totalY) >= 4 {
                    isDragging = true
                    scrollView.beginCardDrag()
                    NSCursor.closedHand.set()
                }
                if isDragging {
                    scrollView.scrollByDragging(deltaX: current.x - previous.x)
                }
                previous = current

            case .leftMouseUp:
                NSCursor.openHand.set()
                if isDragging {
                    scrollView.endCardDrag()
                }
                if isDragging == false,
                   bounds.contains(convert(next.locationInWindow, from: nil)),
                   let action {
                    NSApp.sendAction(action, to: target, from: self)
                }
                return

            default:
                break
            }
        }
        if isDragging {
            scrollView.endCardDrag()
        }
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        if let scrollView = enclosingScrollView as? HorizontalNotchScrollView {
            scrollView.setHoveredCard(self)
        } else {
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    fileprivate func setHovered(_ hovered: Bool) {
        highlight(false)
        layer?.backgroundColor = NSColor(
            calibratedWhite: hovered ? 0.13 : 0.085,
            alpha: 1
        ).cgColor
        layer?.borderColor = NSColor(
            calibratedWhite: hovered ? 0.34 : 0.19,
            alpha: 1
        ).cgColor

        if hovered {
            archiveButton.isHidden = false
            archiveButton.alphaValue = 0
            archiveButton.animator().alphaValue = 1
            return
        }

        archiveButton.animator().alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.archiveButton.alphaValue < 0.1 else { return }
            self.archiveButton.isHidden = true
        }
    }

    private func configureMinimiseOverlay() {
        let overlay = MousePassthroughView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let cross = MousePassthroughTextField(labelWithString: "×")
        cross.font = NSFont.systemFont(ofSize: 42, weight: .light)
        cross.textColor = .white
        cross.alignment = .center
        cross.translatesAutoresizingMaskIntoConstraints = false

        addSubview(overlay)
        addSubview(cross)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            cross.centerXAnchor.constraint(equalTo: centerXAnchor),
            cross.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            cross.widthAnchor.constraint(equalToConstant: 70),
            cross.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func configureArchiveButton() {
        let image = NSImage(
            systemSymbolName: "archivebox",
            accessibilityDescription: "Archive \(noteTitle)"
        )
        archiveButton.image = image
        archiveButton.imagePosition = .imageOnly
        archiveButton.isBordered = false
        archiveButton.bezelStyle = .inline
        archiveButton.contentTintColor = .white
        archiveButton.wantsLayer = true
        archiveButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        archiveButton.layer?.cornerRadius = 6
        archiveButton.alphaValue = 0
        archiveButton.isHidden = true
        archiveButton.toolTip = "Archive \(noteTitle)"
        archiveButton.setAccessibilityLabel("Archive \(noteTitle)")
        archiveButton.target = self
        archiveButton.action = #selector(archivePressed(_:))
        archiveButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(archiveButton)
        NSLayoutConstraint.activate([
            archiveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            archiveButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            archiveButton.widthAnchor.constraint(equalToConstant: 25),
            archiveButton.heightAnchor.constraint(equalToConstant: 25)
        ])
    }

    @objc private func archivePressed(_ sender: NSButton) {
        onArchive?()
    }

    private func configureNoteContent(_ note: NoteStorage.RecentNote) {
        let dot = MousePassthroughView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accentColor(for: note.title).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = MousePassthroughTextField(labelWithString: note.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let time = MousePassthroughTextField(labelWithString: timeLabel(for: note.modifiedAt))
        time.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        time.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        time.translatesAutoresizingMaskIntoConstraints = false

        let previewText = note.preview.isEmpty ? "No preview yet" : note.preview
        let preview = MousePassthroughTextField(wrappingLabelWithString: previewText)
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
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -38),
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

private final class MousePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class MousePassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func resetCursorRects() {}
}

private final class HorizontalNotchScrollView: NSScrollView {
    private var isDraggingCards = false
    private var isScrollingCards = false
    private var scrollHighlightWorkItem: DispatchWorkItem?

    func setHoveredCard(_ hoveredCard: NotchNoteCard?) {
        guard isDraggingCards == false, isScrollingCards == false else { return }
        updateCardHighlights(hoveredCard)
    }

    func beginCardDrag() {
        isDraggingCards = true
        updateCardHighlights(nil)
    }

    func endCardDrag() {
        updateCardHighlights(nil)
        isDraggingCards = false
    }

    func scrollByDragging(deltaX: CGFloat) {
        var origin = contentView.bounds.origin
        origin.x -= deltaX
        setHorizontalOrigin(origin.x)
    }

    override func scrollWheel(with event: NSEvent) {
        suppressHighlightsWhileScrolling()
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
        setHorizontalOrigin(origin.x)
    }

    private func setHorizontalOrigin(_ proposedX: CGFloat) {
        let maxX = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(proposedX, 0), maxX)
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }

    private func suppressHighlightsWhileScrolling() {
        isScrollingCards = true
        updateCardHighlights(nil)
        scrollHighlightWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isScrollingCards = false
            self.updateCardHighlights(self.cardUnderPointer())
        }
        scrollHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func cardUnderPointer() -> NotchNoteCard? {
        guard let window, let documentView else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInScrollView = convert(pointInWindow, from: nil)
        guard bounds.contains(pointInScrollView) else { return nil }

        let pointInDocument = documentView.convert(pointInWindow, from: nil)
        return documentView.subviews
            .compactMap { $0 as? NotchNoteCard }
            .first { $0.frame.contains(pointInDocument) }
    }

    private func updateCardHighlights(_ hoveredCard: NotchNoteCard?) {
        documentView?.subviews.forEach { view in
            guard let card = view as? NotchNoteCard else { return }
            card.setHovered(card === hoveredCard)
        }
    }
}
