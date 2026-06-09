import AppKit
import DenoteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let storage = NoteStorage()
    private var controllers: [NoteWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        try? storage.prepare()

        let restored = storage.readState().notes
            .compactMap { state -> NoteState? in
                guard let existingURL = storage.existingURL(for: state) else { return nil }
                var state = state
                state.path = existingURL.path
                if state.title == "Untitled Note" {
                    state.title = storage.randomNoteTitle()
                }
                if let renamedURL = try? storage.renameNote(at: URL(fileURLWithPath: state.path), id: state.id, title: state.title) {
                    state.path = renamedURL.path
                }
                return state
            }
        if restored.isEmpty {
            newWindow(nil)
        } else {
            restored.forEach { open(noteState: $0) }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "New Small Window", action: #selector(newSmallWindow(_:)), keyEquivalent: ""))
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
    }

    @objc func newWindow(_ sender: Any?) {
        createWindow(preset: .standard)
    }

    @objc func newSmallWindow(_ sender: Any?) {
        createWindow(preset: .small)
    }

    @objc func exportMarkdown(_ sender: Any?) {
        frontController()?.exportMarkdown(sender)
    }

    @objc func exportText(_ sender: Any?) {
        frontController()?.exportText(sender)
    }

    @objc func exportHTML(_ sender: Any?) {
        frontController()?.exportHTML(sender)
    }

    private func createWindow(preset: NoteWindowController.SizePreset) {
        let id = UUID().uuidString
        let title = storage.randomNoteTitle()
        let url = storage.createNoteURL(id: id, title: title)
        let state = NoteState(id: id, path: url.path, title: title, preset: preset.rawValue)
        open(noteState: state)
        saveState()
    }

    private func open(noteState: NoteState) {
        let controller = NoteWindowController(storage: storage, noteState: noteState) { [weak self] controller in
            self?.controllers.removeAll { $0 === controller }
            self?.saveState()
        } onChange: { [weak self] in
            self?.saveState()
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    private func saveState() {
        let notes = controllers.compactMap { $0.currentState() }
        try? storage.writeState(AppState(notes: notes))
    }

    private func frontController() -> NoteWindowController? {
        if let keyController = NSApp.keyWindow?.windowController as? NoteWindowController {
            return keyController
        }
        return controllers.last
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Denote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n"))
        file.addItem(NSMenuItem(title: "New Small Window", action: #selector(newSmallWindow(_:)), keyEquivalent: "N"))
        file.addItem(.separator())
        let exportMarkdown = NSMenuItem(title: "Export as Markdown...", action: #selector(exportMarkdown(_:)), keyEquivalent: "e")
        exportMarkdown.target = self
        file.addItem(exportMarkdown)
        let exportText = NSMenuItem(title: "Export as Text...", action: #selector(exportText(_:)), keyEquivalent: "")
        exportText.target = self
        file.addItem(exportText)
        let exportHTML = NSMenuItem(title: "Export as HTML...", action: #selector(exportHTML(_:)), keyEquivalent: "")
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
        edit.addItem(NSMenuItem(title: "Paste and Merge Formatting", action: #selector(BlockEditorView.pasteAndMergeFormatting(_:)), keyEquivalent: "V"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Standard Size", action: #selector(NoteWindowController.applyStandardSize(_:)), keyEquivalent: ""))
        window.addItem(NSMenuItem(title: "Small Size", action: #selector(NoteWindowController.applySmallSize(_:)), keyEquivalent: ""))
        window.addItem(NSMenuItem(title: "Toggle Always Hover", action: #selector(NoteWindowController.togglePinned(_:)), keyEquivalent: "p"))
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
