import AppKit
import Foundation

public enum MarkdownCodec {
    public static let bodyFontSize: CGFloat = 14

    public static func bodyAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        return [
            .font: NSFont.systemFont(ofSize: bodyFontSize),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style
        ]
    }

    public static func attributedString(from markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let parsed = parseLine(line)
            output.append(parsed)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
        }

        return output
    }

    public static func markdown(from attributedString: NSAttributedString) -> String {
        let full = NSRange(location: 0, length: attributedString.length)
        var result = ""

        let plain = attributedString.string as NSString
        plain.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, substringRange, _, _ in
            let nsRange = substringRange
            let paragraph = attributedString.attributedSubstring(from: nsRange)
            result += markdownLine(from: paragraph)
            if nsRange.upperBound < full.upperBound {
                result += "\n"
            }
        }

        if attributedString.length == 0 {
            return ""
        }

        return result
    }

    public static func normalise(_ attributedString: NSMutableAttributedString, range: NSRange) {
        let target = paragraphRange(in: attributedString.string as NSString, for: range)
        attributedString.setAttributes(bodyAttributes(), range: target)
    }

    public static func paragraphRange(in string: NSString, for range: NSRange) -> NSRange {
        string.paragraphRange(for: range.location < string.length ? range : NSRange(location: max(0, string.length - 1), length: 0))
    }

    private static func parseLine(_ line: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 6

        var content = line
        var prefix = ""
        if content.hasPrefix("- ") || content.hasPrefix("* ") {
            prefix = "\u{2022}\t"
            content.removeFirst(2)
            paragraphStyle.headIndent = 22
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        } else if let match = content.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            prefix = String(content[match])
            content.removeSubrange(match)
            paragraphStyle.headIndent = 28
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
        } else if content.hasPrefix("# ") {
            content.removeFirst(2)
            let result = NSMutableAttributedString(string: content, attributes: bodyAttributes())
            result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 22), range: NSRange(location: 0, length: result.length))
            return result
        } else if content.hasPrefix("## ") {
            content.removeFirst(3)
            let result = NSMutableAttributedString(string: content, attributes: bodyAttributes())
            result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: result.length))
            return result
        }

        let result = NSMutableAttributedString(string: prefix, attributes: bodyAttributes())
        result.append(parseInline(content))
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func parseInline(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text, attributes: bodyAttributes())
        applyInline(pattern: #"\*\*([^*]+)\*\*"#, to: output, font: NSFont.boldSystemFont(ofSize: bodyFontSize))
        applyInline(pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#, to: output, font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: bodyFontSize), toHaveTrait: .italicFontMask))
        return output
    }

    private static func applyInline(pattern: String, to attributed: NSMutableAttributedString, font: NSFont) {
        while let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: attributed.string, range: NSRange(location: 0, length: attributed.length)),
              match.numberOfRanges == 2 {
            let inner = match.range(at: 1)
            let value = (attributed.string as NSString).substring(with: inner)
            attributed.replaceCharacters(in: match.range, with: value)
            attributed.addAttribute(.font, value: font, range: NSRange(location: match.range.location, length: (value as NSString).length))
        }
    }

    private static func markdownLine(from attributed: NSAttributedString) -> String {
        var text = attributed.string
        var prefix = ""
        if text.hasPrefix("\u{2022}\t") {
            text.removeFirst(2)
            prefix = "- "
        } else if let match = text.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            prefix = String(text[match])
            text.removeSubrange(match)
        }

        if text.isEmpty {
            return prefix.trimmingCharacters(in: .whitespaces)
        }

        var line = ""
        attributed.enumerateAttributes(in: NSRange(location: prefix.isEmpty ? 0 : (attributed.string as NSString).length - (text as NSString).length, length: (text as NSString).length)) { attrs, range, _ in
            var fragment = (attributed.string as NSString).substring(with: range)
            if prefix == "- ", fragment.hasPrefix("\u{2022}\t") {
                fragment.removeFirst(2)
            }
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) {
                    fragment = "**\(fragment)**"
                } else if traits.contains(.italicFontMask) {
                    fragment = "*\(fragment)*"
                }
            }
            line += fragment
        }
        return prefix + line
    }
}
