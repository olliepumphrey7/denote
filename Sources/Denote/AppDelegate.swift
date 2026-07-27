import AppKit
import DenoteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let storage = NoteStorage()
    private let hotKeyManager = GlobalHotKeyManager()
    private var noteController: NoteWindowController?
    private var menuBarController: MenuBarController?
    private var settingsController: ShortcutSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        try? storage.prepare()

        let savedState = storage.readState()
        let initialState = restoredState(from: savedState) ?? newNoteState(
            preservingWindowStateFrom: savedState.notes.last
        )
        let controller = NoteWindowController(
            storage: storage,
            noteState: initialState,
            onChange: { [weak self] in
                self?.saveState()
                self?.menuBarController?.refreshIfVisible()
            }
        )
        noteController = controller

        menuBarController = MenuBarController(
            storage: storage,
            activeNoteURL: { [weak controller] in
                controller?.currentNoteURL ?? initialStateURLFallback()
            },
            shortcutTitle: { [weak self] in
                guard let self else { return KeyboardShortcut.defaultShortcut.displayName }
                let suffix = self.hotKeyManager.isRegistered ? "" : " (unavailable)"
                return self.hotKeyManager.shortcut.displayName + suffix
            },
            onToggleWindow: { [weak controller] in
                controller?.toggleVisibility()
            },
            onNewNote: { [weak self] in
                self?.newNote(nil)
            },
            onOpenNote: { [weak self] url in
                self?.openNote(at: url)
            },
            onOpenSettings: { [weak self] in
                self?.showSettings(nil)
            }
        )

        hotKeyManager.onPressed = { [weak controller, weak menuBarController] in
            menuBarController?.closePopover()
            controller?.toggleVisibility()
        }

        controller.showAndActivate()
        saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        noteController?.saveCurrentNote()
        saveState()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openNote(at: URL(fileURLWithPath: filename))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { _ = openNote(at: $0) }
    }

    @objc func newNote(_ sender: Any?) {
        noteController?.createNewNote()
        saveState()
        menuBarController?.refreshIfVisible()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = ShortcutSettingsWindowController(hotKeyManager: hotKeyManager)
        }
        settingsController?.showSettings()
        menuBarController?.refreshIfVisible()
    }

    @objc func toggleNoteWindow(_ sender: Any?) {
        noteController?.toggleVisibility()
    }

    @objc func exportMarkdown(_ sender: Any?) {
        noteController?.exportMarkdown(sender)
    }

    @objc func exportText(_ sender: Any?) {
        noteController?.exportText(sender)
    }

    @objc func exportHTML(_ sender: Any?) {
        noteController?.exportHTML(sender)
    }

    @objc func pasteWithoutFormatting(_ sender: Any?) {
        noteController?.pasteWithoutFormatting(sender)
    }

    @discardableResult
    private func openNote(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json",
              storage.loadDocument(from: url) != nil else {
            return false
        }

        noteController?.displayNote(at: url)
        saveState()
        menuBarController?.refreshIfVisible()
        return true
    }

    private func restoredState(from appState: AppState) -> NoteState? {
        for storedState in appState.notes.reversed() {
            guard let existingURL = storage.existingURL(for: storedState) ?? storedState.switcherPaths
                .map({ URL(fileURLWithPath: $0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                continue
            }

            var state = storedState
            state.path = existingURL.path
            state.title = NoteStorage.noteTitle(from: existingURL)
            if state.title == "Untitled Note" {
                state.title = storage.randomNoteTitle()
            }
            if let renamedURL = try? storage.renameNote(
                at: URL(fileURLWithPath: state.path),
                id: state.id,
                title: state.title
            ) {
                state.path = renamedURL.path
            }
            state.switcherPaths = []
            state.floatingAnchor = nil
            return state
        }
        return nil
    }

    private func newNoteState(preservingWindowStateFrom oldState: NoteState?) -> NoteState {
        let id = UUID().uuidString
        let title = storage.randomNoteTitle()
        let url = storage.createNoteURL(id: id, title: title)
        return NoteState(
            id: id,
            path: url.path,
            title: title,
            frame: oldState?.frame,
            preset: oldState?.preset ?? NoteWindowController.SizePreset.standard.rawValue,
            isPinned: oldState?.isPinned ?? false
        )
    }

    private func saveState() {
        let notes = noteController?.currentState().map { [$0] } ?? []
        try? storage.writeState(AppState(notes: notes, showsHoverIcons: false))
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Denote",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let newNote = NSMenuItem(
            title: "New Note",
            action: #selector(newNote(_:)),
            keyEquivalent: "n"
        )
        newNote.target = self
        file.addItem(newNote)
        file.addItem(.separator())
        let exportMarkdown = NSMenuItem(
            title: "Export as Markdown…",
            action: #selector(exportMarkdown(_:)),
            keyEquivalent: "e"
        )
        exportMarkdown.target = self
        file.addItem(exportMarkdown)
        let exportText = NSMenuItem(
            title: "Export as Text…",
            action: #selector(exportText(_:)),
            keyEquivalent: ""
        )
        exportText.target = self
        file.addItem(exportText)
        let exportHTML = NSMenuItem(
            title: "Export as HTML…",
            action: #selector(exportHTML(_:)),
            keyEquivalent: ""
        )
        exportHTML.target = self
        file.addItem(exportHTML)
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pasteWithoutFormatting = NSMenuItem(
            title: "Paste Without Formatting",
            action: #selector(pasteWithoutFormatting(_:)),
            keyEquivalent: "V"
        )
        pasteWithoutFormatting.target = self
        edit.addItem(pasteWithoutFormatting)
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        let showHide = NSMenuItem(
            title: "Show or Hide Note",
            action: #selector(toggleNoteWindow(_:)),
            keyEquivalent: ""
        )
        showHide.target = self
        window.addItem(showHide)
        window.addItem(NSMenuItem(
            title: "Toggle Window Size",
            action: #selector(NoteWindowController.toggleSizePreset(_:)),
            keyEquivalent: ""
        ))
        window.addItem(NSMenuItem(
            title: "Toggle Always Hover",
            action: #selector(NoteWindowController.togglePinned(_:)),
            keyEquivalent: "p"
        ))
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}

private func initialStateURLFallback() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent("Denote")
        .appendingPathComponent("Untitled Note.note.json")
}
