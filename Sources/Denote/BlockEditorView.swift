import AppKit
import DenoteCore
import WebKit

@MainActor
final class BlockEditorView: NSView {
    var onDocumentChanged: (() -> Void)?

    private let webView: WKWebView
    private var isReady = false
    private var pendingDocument = EditorDocument()
    private var latestDocument = EditorDocument()

    override init(frame frameRect: NSRect) {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        contentController.add(self, name: "editorChanged")
        contentController.add(self, name: "editorReady")
        setupWebView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func load(document: EditorDocument) {
        pendingDocument = document
        latestDocument = document
        if isReady {
            apply(document: document)
        }
    }

    func currentDocument() -> EditorDocument {
        latestDocument
    }

    func focusEditor() {
        webView.evaluateJavaScript("window.editorFocus && window.editorFocus();")
    }

    @objc func pasteAndMergeFormatting(_ sender: Any?) {
        webView.evaluateJavaScript("document.execCommand('paste');")
    }

    @objc func applyNormalStyle(_ sender: Any?) {
        webView.evaluateJavaScript("window.editorApplyNormalStyle && window.editorApplyNormalStyle();")
    }

    @objc func paintFormat(_ sender: Any?) {
        webView.evaluateJavaScript("window.editorPaintFormat && window.editorPaintFormat();")
    }

    private func setupWebView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView.loadHTMLString(Self.editorHTML(), baseURL: Bundle.main.resourceURL)
    }

    private func apply(document: EditorDocument) {
        let payload: [String: String] = [
            "modelJSON": document.modelJSON,
            "html": document.html
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        webView.evaluateJavaScript("window.editorSetDocument(\(encoded));")
    }

    private static func resourceText(_ name: String, extension fileExtension: String) -> String {
        let resourceURL = Bundle.main.resourceURL
        let candidateURLs = [
            resourceURL?.appendingPathComponent("\(name).\(fileExtension)"),
            resourceURL?.appendingPathComponent("Denote_Denote.bundle").appendingPathComponent("\(name).\(fileExtension)")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return ""
    }

    private static func editorHTML() -> String {
        let bundleCSS = resourceText("editor-bundle", extension: "css")
        let bundleJS = resourceText("editor-bundle", extension: "js")
        return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        :root {
          color-scheme: light dark;
          font: -apple-system-body;
          background: Canvas;
          color: CanvasText;
        }

        html, body {
          margin: 0;
          min-height: 100%;
          background: Canvas;
        }

        body {
          font: 14px/1.48 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
        }

        #editor {
          min-height: 100vh;
        }

        .ProseMirror {
          box-sizing: border-box;
          min-height: 100vh;
          padding: 10px 14px 36px;
          outline: none;
          white-space: normal;
          overflow-wrap: break-word;
        }

        .ProseMirror p.is-editor-empty:first-child::before {
          content: "Start writing...";
          color: GrayText;
        }

        p, ul, ol, table, blockquote {
          margin: 0 0 9px;
        }

        ul, ol {
          padding-left: 24px;
        }

        li {
          margin: 2px 0;
        }

        h1, h2, h3 {
          font-weight: 650;
          line-height: 1.22;
          margin: 18px 0 8px;
        }

        h1 { font-size: 24px; }
        h2 { font-size: 19px; }
        h3 { font-size: 16px; }

        table {
          border-collapse: collapse;
          max-width: 100%;
          width: auto;
          display: table;
        }

        td, th {
          border: 1px solid color-mix(in srgb, CanvasText 22%, transparent);
          padding: 5px 8px;
          min-width: 56px;
          vertical-align: top;
        }

        th {
          font-weight: 650;
          background: color-mix(in srgb, CanvasText 7%, transparent);
        }

        blockquote {
          border-left: 3px solid color-mix(in srgb, CanvasText 28%, transparent);
          padding-left: 10px;
          color: color-mix(in srgb, CanvasText 76%, transparent);
        }

        .ProseMirror .tableWrapper {
          overflow-x: auto;
          margin: 0 0 9px;
        }

        .ProseMirror .selectedCell:after {
          background: color-mix(in srgb, Highlight 12%, transparent);
          border: 1px solid color-mix(in srgb, Highlight 38%, transparent);
          box-sizing: border-box;
        }

        \(bundleCSS)
      </style>
    </head>
    <body>
      <main id="editor"></main>
      <script>
        \(bundleJS)
      </script>
    </body>
    </html>
    """
    }
}

extension BlockEditorView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    }
}

extension BlockEditorView: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            if message.name == "editorReady" {
                isReady = true
                apply(document: pendingDocument)
                focusEditor()
                return
            }

            guard message.name == "editorChanged",
                  let body = message.body as? [String: Any] else {
                return
            }

            latestDocument = EditorDocument(
                modelJSON: body["modelJSON"] as? String ?? "",
                html: body["html"] as? String ?? "",
                plainText: body["plainText"] as? String ?? ""
            )
            onDocumentChanged?()
        }
    }
}
