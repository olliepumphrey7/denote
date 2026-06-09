import AppKit
import DenoteCore
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

let blankDocuments = [
    EditorDocument(html: "", plainText: ""),
    EditorDocument(html: "<p><br></p>", plainText: "\n  \n"),
    EditorDocument(modelJSON: #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"   "}]}]}"#, html: "<p>&nbsp;</p>", plainText: "   ")
]
for blank in blankDocuments {
    check(blank.isBlank, "Blank document is detected: \(blank)")
}
let contentDocument = EditorDocument(modelJSON: #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hello"}]}]}"#, html: "<p>Hello</p>", plainText: "")
check(!contentDocument.isBlank, "Model JSON text prevents blank detection")

let blankURL = storage.createNoteURL(id: "blank-check", title: "Blank Check")
try storage.save(document: document, to: blankURL)
check(FileManager.default.fileExists(atPath: blankURL.path), "Nonblank save creates note file")
try storage.save(document: blankDocuments[0], to: blankURL)
check(!FileManager.default.fileExists(atPath: blankURL.path), "Blank save removes existing note file")

let recentStorage = NoteStorage(notesDirectory: root.appendingPathComponent("recent-notes"), appSupportDirectory: root.appendingPathComponent("recent-support"))
let oldURL = recentStorage.createNoteURL(title: "Old Note")
let middleURL = recentStorage.createNoteURL(title: "Middle Note")
let newestURL = recentStorage.createNoteURL(title: "Newest Note")
let extraURL = recentStorage.createNoteURL(title: "Extra Note")
let ignoredBlankURL = recentStorage.createNoteURL(title: "Ignored Blank")
try recentStorage.save(document: EditorDocument(html: "<p>Old</p>", plainText: "Old"), to: oldURL)
try recentStorage.save(document: EditorDocument(html: "<p>Middle</p>", plainText: "Middle"), to: middleURL)
try recentStorage.save(document: EditorDocument(html: "<p>Newest</p>", plainText: "Newest"), to: newestURL)
try recentStorage.save(document: EditorDocument(html: "<p>Extra</p>", plainText: "Extra"), to: extraURL)
try " ".write(to: ignoredBlankURL, atomically: true, encoding: .utf8)

let calendar = Calendar(identifier: .gregorian)
let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .minute, value: 1, to: baseDate)!], ofItemAtPath: oldURL.path)
try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .minute, value: 2, to: baseDate)!], ofItemAtPath: middleURL.path)
try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .minute, value: 3, to: baseDate)!], ofItemAtPath: newestURL.path)
try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .minute, value: 0, to: baseDate)!], ofItemAtPath: extraURL.path)
try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .minute, value: 4, to: baseDate)!], ofItemAtPath: ignoredBlankURL.path)

let recent = recentStorage.recentNotes(limit: 3)
check(recent.map(\.title) == ["Newest Note", "Middle Note", "Old Note"], "Recent notes are sorted and limited; got \(recent.map(\.title))")

print("All checks passed.")
