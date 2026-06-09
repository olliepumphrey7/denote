import Foundation

public struct NoteState: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var title: String
    public var frame: String?
    public var preset: String
    public var isPinned: Bool

    public init(id: String, path: String, title: String = "Untitled Note", frame: String? = nil, preset: String = "standard", isPinned: Bool = false) {
        self.id = id
        self.path = path
        self.title = title
        self.frame = frame
        self.preset = preset
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case title
        case frame
        case preset
        case isPinned
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Note"
        frame = try values.decodeIfPresent(String.self, forKey: .frame)
        preset = try values.decodeIfPresent(String.self, forKey: .preset) ?? "standard"
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

public struct EditorDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var modelJSON: String
    public var html: String
    public var plainText: String

    public init(version: Int = 2, modelJSON: String = "", html: String = "", plainText: String = "") {
        self.version = version
        self.modelJSON = modelJSON
        self.html = html
        self.plainText = plainText
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case modelJSON
        case html
        case plainText
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        modelJSON = try values.decodeIfPresent(String.self, forKey: .modelJSON) ?? ""
        html = try values.decodeIfPresent(String.self, forKey: .html) ?? ""
        plainText = try values.decodeIfPresent(String.self, forKey: .plainText) ?? ""
    }

    public var isBlank: Bool {
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return false
        }

        let htmlText = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return htmlText.isEmpty && modelJSONContainsText(modelJSON) == false
    }

    private func modelJSONContainsText(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return Self.containsText(in: object)
    }

    private static func containsText(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            if let text = dictionary["text"] as? String,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }
            return dictionary.values.contains { containsText(in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsText(in: $0) }
        }
        return false
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var notes: [NoteState]

    public init(notes: [NoteState] = []) {
        self.notes = notes
    }
}

public final class NoteStorage: @unchecked Sendable {
    public struct RecentNote: Equatable, Sendable {
        public let title: String
        public let url: URL
    }

    public let notesDirectory: URL
    public let stateURL: URL
    private static let adjectives = [
        "Amber", "Bright", "Calm", "Clever", "Copper", "Gentle", "Golden", "Hidden",
        "Quiet", "Silver", "Steady", "Swift", "True", "Velvet", "Warm", "Wild"
    ]
    private static let nouns = [
        "Archive", "Beacon", "Canvas", "Comet", "Compass", "Harbor", "Lantern", "Map",
        "Meadow", "Memo", "Orbit", "Page", "Signal", "Sketch", "Spark", "Studio"
    ]
    private static let suffixes = [
        "Alpha", "Base", "Draft", "Field", "Focus", "Grid", "Hub", "Lab",
        "Loop", "Point", "Room", "Space", "Stack", "Trail", "View", "Zone"
    ]

    public init(
        notesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Denote"),
        appSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Denote")
    ) {
        self.notesDirectory = notesDirectory
        self.stateURL = appSupportDirectory.appendingPathComponent("state.json")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func existingURL(for state: NoteState) -> URL? {
        let storedURL = URL(fileURLWithPath: state.path)
        if FileManager.default.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let documentsURL = notesDirectory.appendingPathComponent(storedURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: documentsURL.path) {
            return documentsURL
        }

        return nil
    }

    public func recentNotes(limit: Int = 3) -> [RecentNote] {
        guard limit > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: notesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".note.json") }
            .compactMap { url -> (RecentNote, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      let document = loadDocument(from: url),
                      document.isBlank == false else {
                    return nil
                }
                return (RecentNote(title: Self.noteTitle(from: url), url: url), modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    public func randomNoteTitle() -> String {
        let adjective = Self.adjectives.randomElement() ?? "Bright"
        let noun = Self.nouns.randomElement() ?? "Note"
        let suffix = Self.suffixes.randomElement() ?? "Draft"
        return "\(adjective) \(noun) \(suffix)"
    }

    public func createNoteURL(id: String = UUID().uuidString, title: String) -> URL {
        uniqueNoteURL(title: title)
    }

    public func renameNote(at url: URL, id: String, title: String) throws -> URL {
        let target = uniqueNoteURL(title: title, excluding: url)
        if target == url {
            return url
        }

        try prepare()
        if FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: url, to: target)
        }
        return target
    }

    public func readState() -> AppState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            return AppState()
        }
        return state
    }

    public func writeState(_ state: AppState) throws {
        try prepare()
        let data = try JSONEncoder.pretty.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    public func save(markdown: String, to url: URL) throws {
        try prepare()
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    public func loadMarkdown(from url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func save(document: EditorDocument, to url: URL) throws {
        if document.isBlank {
            try deleteNoteIfExists(at: url)
            return
        }

        try prepare()
        let data = try JSONEncoder.pretty.encode(document)
        try data.write(to: url, options: .atomic)
    }

    public func loadDocument(from url: URL) -> EditorDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditorDocument.self, from: data)
    }

    public func deleteNoteIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func uniqueNoteURL(title: String, excluding existingURL: URL? = nil) -> URL {
        let baseName = Self.safeFileName(title)
        var candidate = notesDirectory.appendingPathComponent("\(baseName).note.json")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate != existingURL {
            candidate = notesDirectory.appendingPathComponent("\(baseName) \(index).note.json")
            index += 1
        }
        return candidate
    }

    public static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = cleaned.isEmpty ? "Untitled Note" : cleaned
        return String(fallback.prefix(60))
    }

    public static func noteTitle(from url: URL) -> String {
        let fileName = url.lastPathComponent
        if fileName.hasSuffix(".note.json") {
            return String(fileName.dropLast(".note.json".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
