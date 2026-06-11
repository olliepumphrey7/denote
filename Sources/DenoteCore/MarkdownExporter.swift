import Foundation

public enum MarkdownExporter {
    public static func markdown(from document: EditorDocument) -> String {
        guard let root = ProseMirrorNode(json: document.modelJSON) else {
            return normalisedFallback(document.plainText)
        }

        let renderer = Renderer()
        let output = renderer.renderDocument(root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? normalisedFallback(document.plainText) : output + "\n"
    }

    private static func normalisedFallback(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }
}

private struct ProseMirrorNode {
    let type: String
    let text: String?
    let attrs: [String: Any]
    let marks: [ProseMirrorMark]
    let content: [ProseMirrorNode]

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let node = ProseMirrorNode(object: object) else {
            return nil
        }
        self = node
    }

    init?(object: Any) {
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            return nil
        }

        self.type = type
        self.text = dictionary["text"] as? String
        self.attrs = dictionary["attrs"] as? [String: Any] ?? [:]
        self.marks = (dictionary["marks"] as? [Any] ?? []).compactMap(ProseMirrorMark.init(object:))
        self.content = (dictionary["content"] as? [Any] ?? []).compactMap(ProseMirrorNode.init(object:))
    }
}

private struct ProseMirrorMark {
    let type: String
    let attrs: [String: Any]

    init?(object: Any) {
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            return nil
        }
        self.type = type
        self.attrs = dictionary["attrs"] as? [String: Any] ?? [:]
    }
}

private struct Renderer {
    func renderDocument(_ node: ProseMirrorNode) -> String {
        renderBlocks(node.content, listContext: nil)
    }

    private func renderBlocks(_ nodes: [ProseMirrorNode], listContext: ListContext?) -> String {
        var blocks: [String] = []
        blocks.reserveCapacity(nodes.count)

        for node in nodes {
            let rendered = renderBlock(node, listContext: listContext)
            if rendered.isEmpty == false {
                blocks.append(rendered)
            }
        }

        if listContext != nil {
            return blocks.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n")
    }

    private func renderBlock(_ node: ProseMirrorNode, listContext: ListContext?) -> String {
        switch node.type {
        case "paragraph":
            return renderInline(node.content)
        case "heading":
            let level = min(max(node.attrs["level"] as? Int ?? 1, 1), 6)
            return String(repeating: "#", count: level) + " " + renderInline(node.content)
        case "blockquote":
            return renderBlocks(node.content, listContext: nil)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")
        case "bullet_list":
            return renderList(node, ordered: false, parentContext: listContext)
        case "ordered_list":
            return renderList(node, ordered: true, parentContext: listContext)
        case "list_item":
            return renderListItem(node, context: listContext ?? ListContext(kind: .bullet, level: 0, start: 1, index: 0))
        case "table":
            return renderTable(node)
        case "horizontal_rule":
            return "---"
        default:
            if node.content.isEmpty == false {
                return renderBlocks(node.content, listContext: listContext)
            }
            return node.text ?? ""
        }
    }

    private func renderList(_ node: ProseMirrorNode, ordered: Bool, parentContext: ListContext?) -> String {
        let start = node.attrs["order"] as? Int ?? 1
        let items = node.content.filter { $0.type == "list_item" }
        let level = (parentContext?.level ?? -1) + 1
        let contextKind: ListContext.Kind = ordered ? .ordered : .bullet

        return items.enumerated().map { offset, item in
            renderListItem(item, context: ListContext(kind: contextKind, level: level, start: start, index: offset))
        }.joined(separator: "\n")
    }

    private func renderListItem(_ node: ProseMirrorNode, context: ListContext) -> String {
        let marker: String
        switch context.kind {
        case .bullet:
            marker = "- "
        case .ordered:
            marker = "\(context.start + context.index). "
        }

        let indent = String(repeating: "  ", count: context.level)
        var primaryLines: [String] = []
        var nestedBlocks: [String] = []

        for child in node.content {
            if child.type == "bullet_list" {
                nestedBlocks.append(renderList(child, ordered: false, parentContext: context))
            } else if child.type == "ordered_list" {
                nestedBlocks.append(renderList(child, ordered: true, parentContext: context))
            } else {
                let rendered = renderBlock(child, listContext: context)
                if rendered.isEmpty == false {
                    primaryLines.append(rendered)
                }
            }
        }

        var lines = primaryLines.isEmpty ? [""] : primaryLines.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[0] = indent + marker + lines[0]
        for index in lines.indices.dropFirst() {
            lines[index] = indent + String(repeating: " ", count: marker.count) + lines[index]
        }

        if nestedBlocks.isEmpty == false {
            lines.append(contentsOf: nestedBlocks)
        }
        return lines.joined(separator: "\n")
    }

    private func renderTable(_ node: ProseMirrorNode) -> String {
        let rows = node.content.filter { $0.type == "table_row" }
        guard rows.isEmpty == false else { return "" }

        if tableHasMergedCells(rows) {
            return renderHTMLTable(rows)
        }

        let cells = rows.map { row in
            row.content.filter { $0.type == "table_cell" || $0.type == "table_header" }.map { cell in
                renderBlocks(cell.content, listContext: nil)
                    .replacingOccurrences(of: "\n", with: "<br>")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }
        let width = cells.map(\.count).max() ?? 0
        guard width > 0 else { return "" }

        let paddedRows = cells.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
        var lines = paddedRows.map { "| " + $0.joined(separator: " | ") + " |" }
        lines.insert("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |", at: min(1, lines.count))
        return lines.joined(separator: "\n")
    }

    private func tableHasMergedCells(_ rows: [ProseMirrorNode]) -> Bool {
        rows.contains { row in
            row.content.contains { cell in
                (cell.attrs["colspan"] as? Int ?? 1) > 1 || (cell.attrs["rowspan"] as? Int ?? 1) > 1
            }
        }
    }

    private func renderHTMLTable(_ rows: [ProseMirrorNode]) -> String {
        var output = "<table>\n"
        for row in rows {
            output += "  <tr>"
            for cell in row.content where cell.type == "table_cell" || cell.type == "table_header" {
                let tag = cell.type == "table_header" ? "th" : "td"
                var attrs = ""
                let colspan = cell.attrs["colspan"] as? Int ?? 1
                let rowspan = cell.attrs["rowspan"] as? Int ?? 1
                if colspan > 1 { attrs += " colspan=\"\(colspan)\"" }
                if rowspan > 1 { attrs += " rowspan=\"\(rowspan)\"" }
                let body = escapeHTML(renderPlainText(cell)).replacingOccurrences(of: "\n", with: "<br>")
                output += "<\(tag)\(attrs)>\(body)</\(tag)>"
            }
            output += "</tr>\n"
        }
        output += "</table>"
        return output
    }

    private func renderPlainText(_ node: ProseMirrorNode) -> String {
        if let text = node.text {
            return text
        }
        let separator = node.type == "doc" || node.type == "table_cell" || node.type == "table_header" ? "\n" : ""
        return node.content.map(renderPlainText).joined(separator: separator)
    }

    private func renderInline(_ nodes: [ProseMirrorNode]) -> String {
        nodes.map(renderInlineNode).joined()
    }

    private func renderInlineNode(_ node: ProseMirrorNode) -> String {
        switch node.type {
        case "text":
            return applyMarks(to: node.text ?? "", marks: node.marks)
        case "hard_break":
            return "\n"
        case "image":
            let alt = node.attrs["alt"] as? String ?? ""
            let src = node.attrs["src"] as? String ?? ""
            return "![\(escapeLinkLabel(alt))](\(src))"
        default:
            return renderInline(node.content)
        }
    }

    private func applyMarks(to text: String, marks: [ProseMirrorMark]) -> String {
        var value = escapeMarkdownText(text)

        for mark in marks.reversed() {
            switch mark.type {
            case "strong":
                value = "**\(value)**"
            case "em":
                value = "*\(value)*"
            case "code":
                value = "`\(text.replacingOccurrences(of: "`", with: "\\`"))`"
            case "link":
                let href = mark.attrs["href"] as? String ?? ""
                value = "[\(escapeLinkLabel(value))](\(href.replacingOccurrences(of: ")", with: "\\)")))"
            default:
                break
            }
        }

        return value
    }

    private func escapeMarkdownText(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            if "\\`*_{}[]<>".contains(character) {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }

    private func escapeLinkLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct ListContext {
    enum Kind {
        case bullet
        case ordered
    }

    let kind: Kind
    let level: Int
    let start: Int
    let index: Int
}
