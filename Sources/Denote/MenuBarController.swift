import AppKit
import DenoteCore

@MainActor
final class MenuBarController: NSObject {
    private let storage: NoteStorage
    private let activeNoteURL: () -> URL
    private let shortcutTitle: () -> String
    private let onToggleWindow: () -> Void
    private let onNewNote: () -> Void
    private let onOpenNote: (URL) -> Void
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private var presentedMenu: NSMenu?

    init(
        storage: NoteStorage,
        activeNoteURL: @escaping () -> URL,
        shortcutTitle: @escaping () -> String,
        onToggleWindow: @escaping () -> Void,
        onNewNote: @escaping () -> Void,
        onOpenNote: @escaping (URL) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.storage = storage
        self.activeNoteURL = activeNoteURL
        self.shortcutTitle = shortcutTitle
        self.onToggleWindow = onToggleWindow
        self.onNewNote = onNewNote
        self.onOpenNote = onOpenNote
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: 96)
        super.init()

        guard let button = statusItem.button else { return }
        let symbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Denote")?
            .withSymbolConfiguration(symbol)
        image?.isTemplate = true

        button.image = image
        button.imagePosition = .imageLeading
        button.title = "Denote"
        button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Left-click to show or hide Denote. Right-click for notes and options."
        button.setAccessibilityLabel("Denote")
        button.setAccessibilityHelp(
            "Left-click to show or hide the note window. Right-click for notes and options."
        )
    }

    func refreshIfVisible() {
        // The native menu is rebuilt every time it opens.
    }

    func closePopover() {
        presentedMenu?.cancelTracking()
        presentedMenu = nil
        statusItem.menu = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isContextClick {
            showOptionsMenu()
        } else {
            onToggleWindow()
        }
    }

    private func showOptionsMenu() {
        guard let button = statusItem.button else { return }

        let menu = makeOptionsMenu()
        presentedMenu = menu
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        presentedMenu = nil
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newNote = NSMenuItem(
            title: "New Note",
            action: #selector(createNewNote(_:)),
            keyEquivalent: "n"
        )
        newNote.keyEquivalentModifierMask = [.command]
        configure(newNote)
        menu.addItem(newNote)
        menu.addItem(.separator())

        let activeURL = activeNoteURL().standardizedFileURL
        let notes = storage.recentNotes(limit: 10_000)

        if notes.isEmpty {
            let empty = NSMenuItem(title: "No Saved Notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addNoteItems(Array(notes.prefix(5)), to: menu, activeURL: activeURL)

            let remainingNotes = Array(notes.dropFirst(5))
            if remainingNotes.isEmpty == false {
                let moreMenu = NSMenu(title: "More Notes")
                moreMenu.autoenablesItems = false
                addNoteItems(remainingNotes, to: moreMenu, activeURL: activeURL)

                let moreNotes = NSMenuItem(
                    title: "More Notes (\(remainingNotes.count))",
                    action: nil,
                    keyEquivalent: ""
                )
                moreNotes.submenu = moreMenu
                moreNotes.isEnabled = true
                menu.addItem(moreNotes)
            }
        }

        menu.addItem(.separator())

        let shortcut = NSMenuItem(
            title: "Shortcut: \(shortcutTitle())…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        configure(shortcut)
        menu.addItem(shortcut)

        let quit = NSMenuItem(
            title: "Quit Denote",
            action: #selector(quitDenote(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        configure(quit)
        menu.addItem(quit)

        return menu
    }

    private func addNoteItems(
        _ notes: [NoteStorage.RecentNote],
        to menu: NSMenu,
        activeURL: URL
    ) {
        for note in notes {
            let item = NSMenuItem(
                title: note.title,
                action: #selector(openNoteFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = note.url
            item.state = note.url.standardizedFileURL == activeURL ? .on : .off
            configure(item)
            menu.addItem(item)
        }
    }

    private func configure(_ item: NSMenuItem) {
        item.target = self
        item.isEnabled = true
    }

    @objc private func createNewNote(_ sender: NSMenuItem) {
        onNewNote()
    }

    @objc private func openNoteFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenNote(url)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    @objc private func quitDenote(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
