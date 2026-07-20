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
let state = AppState(notes: [NoteState(
    id: "abc",
    path: "/tmp/abc.md",
    frame: "{{0, 0}, {10, 10}}",
    preset: "small",
    isPinned: true,
    switcherPaths: ["/tmp/abc.md", "/tmp/meeting.note.json"],
    floatingAnchor: "{120, 240}"
)], showsHoverIcons: false)
try storage.writeState(state)
check(storage.readState() == state, "State round trip works")

let legacyAppStateData = #"{"notes":[]}"#.data(using: .utf8)!
let legacyAppState = try JSONDecoder().decode(AppState.self, from: legacyAppStateData)
check(legacyAppState.showsHoverIcons, "Legacy app state enables hover icons by default")

let legacyStateData = #"{"id":"legacy","path":"/tmp/legacy.note.json","title":"Legacy","preset":"standard","isPinned":false}"#.data(using: .utf8)!
let legacyState = try JSONDecoder().decode(NoteState.self, from: legacyStateData)
check(legacyState.switcherPaths.isEmpty, "Legacy state decodes with an empty switcher")
check(legacyState.floatingAnchor == nil, "Legacy state decodes without a floating anchor")

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

func jsonString(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func text(_ value: String, marks: [[String: Any]] = []) -> [String: Any] {
    var node: [String: Any] = ["type": "text", "text": value]
    if marks.isEmpty == false {
        node["marks"] = marks
    }
    return node
}

func node(_ type: String, attrs: [String: Any] = [:], content: [[String: Any]] = []) -> [String: Any] {
    var value: [String: Any] = ["type": type]
    if attrs.isEmpty == false {
        value["attrs"] = attrs
    }
    if content.isEmpty == false {
        value["content"] = content
    }
    return value
}

func document(_ content: [[String: Any]]) -> EditorDocument {
    EditorDocument(modelJSON: jsonString(["type": "doc", "content": content]), plainText: "fallback")
}

let richMarkdownDocument = document([
    node("heading", attrs: ["level": 1], content: [text("Title & Plan")]),
    node("paragraph", content: [
        text("Hello "),
        text("bold", marks: [["type": "strong"]]),
        text(" and "),
        text("italic", marks: [["type": "em"]]),
        text(" with "),
        text("link", marks: [["type": "link", "attrs": ["href": "https://example.com/docs"]]])
    ]),
    node("bullet_list", content: [
        node("list_item", content: [node("paragraph", content: [text("First")])]),
        node("list_item", content: [
            node("paragraph", content: [text("Second")]),
            node("ordered_list", attrs: ["order": 3], content: [
                node("list_item", content: [node("paragraph", content: [text("Nested")])])
            ])
        ])
    ])
])
let richMarkdown = MarkdownExporter.markdown(from: richMarkdownDocument)
check(richMarkdown == """
# Title & Plan

Hello **bold** and *italic* with [link](https://example.com/docs)

- First
- Second
  3. Nested

""", "Markdown export preserves core rich document structure; got \(richMarkdown.debugDescription)")

let tableDocument = document([
    node("table", content: [
        node("table_row", content: [
            node("table_header", content: [node("paragraph", content: [text("A")])]),
            node("table_header", content: [node("paragraph", content: [text("B")])])
        ]),
        node("table_row", content: [
            node("table_cell", content: [node("paragraph", content: [text("One | escaped")])]),
            node("table_cell", content: [node("paragraph", content: [text("Two")])])
        ])
    ])
])
let tableMarkdown = MarkdownExporter.markdown(from: tableDocument)
check(tableMarkdown == """
| A | B |
| --- | --- |
| One \\| escaped | Two |

""", "Markdown export renders simple tables; got \(tableMarkdown.debugDescription)")

let mergedTableDocument = document([
    node("table", content: [
        node("table_row", content: [
            node("table_cell", attrs: ["colspan": 2], content: [node("paragraph", content: [text("Merged <cell>")])])
        ])
    ])
])
let mergedTableMarkdown = MarkdownExporter.markdown(from: mergedTableDocument)
check(mergedTableMarkdown == """
<table>
  <tr><td colspan="2">Merged &lt;cell&gt;</td></tr>
</table>

""", "Markdown export preserves merged tables as HTML; got \(mergedTableMarkdown.debugDescription)")

let invalidModelDocument = EditorDocument(modelJSON: "{bad json", html: "<p>ignored</p>", plainText: "Plain fallback\n")
check(MarkdownExporter.markdown(from: invalidModelDocument) == "Plain fallback\n", "Invalid model JSON falls back to plain text")

var largeContent: [[String: Any]] = []
largeContent.reserveCapacity(6_000)
for index in 0..<6_000 {
    switch index % 12 {
    case 0:
        largeContent.append(node("heading", attrs: ["level": 2], content: [text("Section \(index)")]))
    case 1:
        largeContent.append(node("bullet_list", content: [
            node("list_item", content: [node("paragraph", content: [text("Item \(index)")])]),
            node("list_item", content: [node("paragraph", content: [text("Item \(index + 1)")])])
        ]))
    case 2:
        largeContent.append(node("table", content: [
            node("table_row", content: [
                node("table_header", content: [node("paragraph", content: [text("A")])]),
                node("table_header", content: [node("paragraph", content: [text("B")])])
            ]),
            node("table_row", content: [
                node("table_cell", content: [node("paragraph", content: [text("\(index)")])]),
                node("table_cell", content: [node("paragraph", content: [text("Value \(index)")])])
            ])
        ]))
    default:
        largeContent.append(node("paragraph", content: [
            text("Paragraph \(index) with "),
            text("bold", marks: [["type": "strong"]]),
            text(" text and a "),
            text("link", marks: [["type": "link", "attrs": ["href": "https://example.com/\(index)"]]])
        ]))
    }
}
let largeDocument = document(largeContent)
let exportStart = DispatchTime.now().uptimeNanoseconds
let largeMarkdown = MarkdownExporter.markdown(from: largeDocument)
let exportElapsed = Double(DispatchTime.now().uptimeNanoseconds - exportStart) / 1_000_000_000
check(largeMarkdown.contains("## Section 0"), "Large Markdown export includes headings")
check(largeMarkdown.contains("| A | B |"), "Large Markdown export includes tables")
check(exportElapsed < 1.5, "Large Markdown export should stay fast; took \(exportElapsed)s")

print("All checks passed.")
