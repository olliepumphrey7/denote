import AppKit
import EphemeralNotesCore
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

let markdown = "- one\n- **two**\nplain *three*"
let attributed = MarkdownCodec.attributedString(from: markdown)
let renderedMarkdown = MarkdownCodec.markdown(from: attributed)
check(renderedMarkdown == markdown, "Markdown round trip preserves bullets and emphasis; got \(renderedMarkdown.debugDescription)")

let normalised = NSMutableAttributedString(string: "Hello", attributes: [
    .font: NSFont.boldSystemFont(ofSize: 20),
    .foregroundColor: NSColor.red
])
MarkdownCodec.normalise(normalised, range: NSRange(location: 0, length: 1))
let attrs = normalised.attributes(at: 0, effectiveRange: nil)
guard let font = attrs[.font] as? NSFont else {
    fputs("Check failed: normal style applies a font\n", stderr)
    exit(1)
}
check(!NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Normal style removes bold")
check(font.pointSize == MarkdownCodec.bodyFontSize, "Normal style uses body font size")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let storage = NoteStorage(notesDirectory: root.appendingPathComponent("notes"), appSupportDirectory: root.appendingPathComponent("support"))
let state = AppState(notes: [NoteState(id: "abc", path: "/tmp/abc.md", frame: "{{0, 0}, {10, 10}}", preset: "small", isPinned: true)])
try storage.writeState(state)
check(storage.readState() == state, "State round trip works")

let documentURL = storage.createNoteURL(id: "document-check", title: "Bright Beacon")
check(documentURL.lastPathComponent == "Bright Beacon.note.json", "Note URL is title-only; got \(documentURL.lastPathComponent)")
let document = EditorDocument(html: "<table><tr><td colspan=\"2\">Merged</td></tr></table>", plainText: "Merged")
try storage.save(document: document, to: documentURL)
check(storage.loadDocument(from: documentURL) == document, "Editor document round trip works")
let renamedURL = try storage.renameNote(at: documentURL, id: "document-check", title: "Quiet Harbor")
check(renamedURL.lastPathComponent == "Quiet Harbor.note.json", "Renamed note URL is title-only; got \(renamedURL.lastPathComponent)")
check(storage.loadDocument(from: renamedURL) == document, "Renamed note keeps document contents")

print("All checks passed.")
