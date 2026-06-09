import AppKit
import DenoteCore

@MainActor
final class EditorTextView: NSTextView {
    var onTextChanged: (() -> Void)?
    private var paintedAttributes: [NSAttributedString.Key: Any]?

    override func didChangeText() {
        super.didChangeText()
        onTextChanged?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        if (insertString as? String) == " " {
            convertMarkdownTriggerIfNeeded()
        }
    }

    override func insertNewline(_ sender: Any?) {
        if handleListNewline() {
            onTextChanged?()
            return
        }
        super.insertNewline(sender)
    }

    @objc func pasteAndMergeFormatting(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let incoming: NSAttributedString
        if let data = pasteboard.data(forType: .rtf),
           let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            incoming = rich
        } else if let text = pasteboard.string(forType: .string) {
            incoming = NSAttributedString(string: text)
        } else {
            return
        }

        let merged = NSMutableAttributedString(attributedString: incoming)
        let base = effectiveBaseAttributes()
        merged.enumerateAttributes(in: NSRange(location: 0, length: merged.length)) { attrs, range, _ in
            var newAttrs = base
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) {
                    newAttrs[.font] = NSFont.boldSystemFont(ofSize: MarkdownCodec.bodyFontSize)
                } else if traits.contains(.italicFontMask),
                          let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: MarkdownCodec.bodyFontSize), toHaveTrait: .italicFontMask) as NSFont? {
                    newAttrs[.font] = italic
                }
            }
            if let link = attrs[.link] {
                newAttrs[.link] = link
                newAttrs[.foregroundColor] = NSColor.linkColor
                newAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            merged.setAttributes(newAttrs, range: range)
        }
        insertText(merged, replacementRange: selectedRange())
    }

    @objc func applyNormalStyle(_ sender: Any?) {
        guard let storage = textStorage else { return }
        MarkdownCodec.normalise(storage, range: selectedRange())
        typingAttributes = MarkdownCodec.bodyAttributes()
        didChangeText()
    }

    @objc func paintFormat(_ sender: Any?) {
        guard let storage = textStorage else { return }
        if let paintedAttributes {
            let range = MarkdownCodec.paragraphRange(in: storage.string as NSString, for: selectedRange())
            storage.setAttributes(paintedAttributes, range: range)
            self.paintedAttributes = nil
            didChangeText()
        } else {
            let location = min(max(0, selectedRange().location), max(0, storage.length - 1))
            paintedAttributes = storage.attributes(at: location, effectiveRange: nil)
        }
    }

    private func effectiveBaseAttributes() -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, storage.length > 0 else {
            return MarkdownCodec.bodyAttributes()
        }
        let location = min(max(0, selectedRange().location), storage.length - 1)
        var attrs = storage.attributes(at: location, effectiveRange: nil)
        attrs[.font] = NSFont.systemFont(ofSize: MarkdownCodec.bodyFontSize)
        attrs[.foregroundColor] = NSColor.textColor
        return attrs
    }

    private func convertMarkdownTriggerIfNeeded() {
        guard let storage = textStorage else { return }
        let selected = selectedRange()
        let paragraph = MarkdownCodec.paragraphRange(in: storage.string as NSString, for: selected)
        let text = (storage.string as NSString).substring(with: paragraph)
        let trimmedNewline = text.trimmingCharacters(in: .newlines)

        if trimmedNewline == "* " || trimmedNewline == "- " {
            storage.replaceCharacters(in: NSRange(location: paragraph.location, length: 2), with: "\u{2022}\t")
            setSelectedRange(NSRange(location: paragraph.location + 2, length: 0))
        } else if trimmedNewline == "1. " {
            storage.addAttribute(.paragraphStyle, value: listParagraphStyle(), range: paragraph)
        }
    }

    private func handleListNewline() -> Bool {
        guard let storage = textStorage else { return false }
        let selected = selectedRange()
        let paragraph = MarkdownCodec.paragraphRange(in: storage.string as NSString, for: selected)
        let text = (storage.string as NSString).substring(with: paragraph).trimmingCharacters(in: .newlines)

        if text == "\u{2022}\t" {
            storage.replaceCharacters(in: paragraph, with: "")
            typingAttributes = MarkdownCodec.bodyAttributes()
            return true
        }

        if text.hasPrefix("\u{2022}\t") {
            super.insertNewline(self)
            super.insertText("\u{2022}\t", replacementRange: selectedRange())
            return true
        }

        if let match = text.range(of: #"^(\d+)\.\s.+"#, options: .regularExpression) {
            let number = Int(text[text.startIndex..<text.index(match.lowerBound, offsetBy: 1)]) ?? 1
            super.insertNewline(self)
            super.insertText("\(number + 1). ", replacementRange: selectedRange())
            return true
        }

        return false
    }

    private func listParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.headIndent = 22
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        return style
    }
}
