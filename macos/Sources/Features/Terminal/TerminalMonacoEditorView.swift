import Foundation
import SwiftUI
import WebKit

@MainActor
final class MonacoEditorModel: ObservableObject {
    weak var webView: WKWebView?

    func showFind() {
        webView?.evaluateJavaScript("window.__gingerttyShowFind && window.__gingerttyShowFind();")
    }
}

struct MonacoEditorWebView: NSViewRepresentable {
    let filePath: String
    let content: String
    let theme: TerminalCodeTheme
    var editorModel: MonacoEditorModel? = nil
    let onContentChanged: (String) -> Void
    let onSaveRequested: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onContentChanged: onContentChanged,
            onSaveRequested: onSaveRequested
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "editorReady")
        contentController.add(context.coordinator, name: "contentChanged")
        contentController.add(context.coordinator, name: "saveRequested")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.lastFilePath = filePath
        context.coordinator.lastContent = content
        context.coordinator.lastThemeType = theme.pierreThemeType
        editorModel?.webView = webView

        guard let resources = Self.monacoResources else {
            webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage), baseURL: nil)
            return webView
        }

        let html = Self.buildHTML(
            filePath: filePath,
            content: content,
            theme: theme,
            workerPaths: resources.workerPaths
        )
        webView.loadHTMLString(html, baseURL: resources.baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        editorModel?.webView = webView

        if context.coordinator.lastFilePath != filePath {
            context.coordinator.lastFilePath = filePath
            context.coordinator.lastContent = content
            context.coordinator.lastThemeType = theme.pierreThemeType
            context.coordinator.isReady = false
            guard let resources = Self.monacoResources else {
                webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage), baseURL: nil)
                return
            }
            let html = Self.buildHTML(
                filePath: filePath,
                content: content,
                theme: theme,
                workerPaths: resources.workerPaths
            )
            webView.loadHTMLString(html, baseURL: resources.baseURL)
            return
        }

        let themeChanged = context.coordinator.lastThemeType != theme.pierreThemeType
        let contentChanged = context.coordinator.lastContent != content
        guard themeChanged || contentChanged else { return }

        context.coordinator.lastContent = content
        context.coordinator.lastThemeType = theme.pierreThemeType

        if context.coordinator.isReady, contentChanged, !themeChanged {
            let setValueJS = "window.__gingerttySetValue && window.__gingerttySetValue(\(Self.escapeJSONString(content)));"
            webView.evaluateJavaScript(setValueJS)
        } else {
            guard let resources = Self.monacoResources else {
                webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage), baseURL: nil)
                return
            }
            let html = Self.buildHTML(
                filePath: filePath,
                content: content,
                theme: theme,
                workerPaths: resources.workerPaths
            )
            webView.loadHTMLString(html, baseURL: resources.baseURL)
        }
    }

    private struct MonacoResources {
        let baseURL: URL
        let workerPaths: WorkerPaths
    }

    private struct WorkerPaths {
        let editor: String
        let json: String
        let css: String
        let html: String
        let typescript: String

        var jsonLiteral: String {
            let dictionary: [String: String] = [
                "editor": editor,
                "json": json,
                "css": css,
                "html": html,
                "typescript": typescript,
            ]
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
            return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
                .replacingOccurrences(of: "</", with: "<\\/")
        }
    }

    private static let resourceMissingMessage = """
    Monaco editor assets are missing from the app bundle.

    Rebuild and reinstall GingerTTY so the bundled Monaco resources are copied into the app.
    """

    private static var monacoResources: MonacoResources? {
        guard let baseURL = Bundle.main.resourceURL?.appendingPathComponent("Monaco", isDirectory: true),
              let workerPaths = resolveWorkerPaths(baseURL: baseURL) else {
            return nil
        }
        return MonacoResources(baseURL: baseURL, workerPaths: workerPaths)
    }

    private static func resolveWorkerPaths(baseURL: URL) -> WorkerPaths? {
        let assetsURL = baseURL.appendingPathComponent("vs/assets", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let names = entries.map(\.lastPathComponent)

        func firstMatch(prefix: String) -> String? {
            names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".js") }
        }

        guard let editor = firstMatch(prefix: "editor.worker-"),
              let json = firstMatch(prefix: "json.worker-"),
              let css = firstMatch(prefix: "css.worker-"),
              let html = firstMatch(prefix: "html.worker-"),
              let typescript = firstMatch(prefix: "ts.worker-") else {
            return nil
        }

        return WorkerPaths(
            editor: "vs/assets/\(editor)",
            json: "vs/assets/\(json)",
            css: "vs/assets/\(css)",
            html: "vs/assets/\(html)",
            typescript: "vs/assets/\(typescript)"
        )
    }

    private static func buildHTML(
        filePath: String,
        content: String,
        theme: TerminalCodeTheme,
        workerPaths: WorkerPaths
    ) -> String {
        let escapedContent = escapeJSTemplateLiteral(content)
        let escapedLanguage = escapeJSString(detectLanguage(from: filePath))
        let workerPathsJSON = workerPaths.jsonLiteral
        let escapedShellBackground = escapeJSString(theme.shellBackgroundHex)
        let escapedShellForeground = escapeJSString(theme.shellForegroundHex)
        let escapedError = escapeJSString(theme.errorHex)
        let escapedMonacoThemeName = escapeJSString(theme.monacoThemeName)
        let monacoThemeDefinition = theme.monacoDefinitionJSON

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { box-sizing: border-box; }
            html, body {
                margin: 0;
                width: 100%;
                height: 100%;
                overflow: hidden;
                background: \(escapedShellBackground);
                color: \(escapedShellForeground);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            #container {
                width: 100%;
                height: 100%;
            }
            #error {
                display: none;
                padding: 16px;
                color: \(escapedError);
                white-space: pre-wrap;
                font-size: 13px;
                line-height: 1.5;
            }
        </style>
        </head>
        <body>
        <div id="container"></div>
        <div id="error"></div>
        <script>
        const workerPaths = \(workerPathsJSON);
        window.MonacoEnvironment = {
            getWorker(_moduleId, label) {
                let workerPath = workerPaths.editor;
                switch (label) {
                    case 'json':
                        workerPath = workerPaths.json;
                        break;
                    case 'css':
                    case 'scss':
                    case 'less':
                        workerPath = workerPaths.css;
                        break;
                    case 'html':
                    case 'handlebars':
                    case 'razor':
                        workerPath = workerPaths.html;
                        break;
                    case 'typescript':
                    case 'javascript':
                        workerPath = workerPaths.typescript;
                        break;
                    default:
                        workerPath = workerPaths.editor;
                        break;
                }
                return new Worker(new URL(workerPath, document.baseURI), {
                    type: 'module',
                    name: label
                });
            }
        };
        </script>
        <script src="vs/loader.js"></script>
        <script>
        const initialContent = `\(escapedContent)`;
        const initialLanguage = '\(escapedLanguage)';
        const shellBackground = '\(escapedShellBackground)';
        const shellForeground = '\(escapedShellForeground)';
        const errorText = '\(escapedError)';
        const monacoThemeName = '\(escapedMonacoThemeName)';
        const monacoThemeDefinition = \(monacoThemeDefinition);
        let editor = null;
        let suppressContentEvents = false;
        let changeTimer = null;

        function showError(message) {
            document.getElementById('container').style.display = 'none';
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = message;
        }

        window.addEventListener('error', (event) => {
            showError('Monaco startup failed.\\n\\n' + (event.error && event.error.message ? event.error.message : event.message));
        });

        window.addEventListener('unhandledrejection', (event) => {
            const reason = event.reason;
            showError('Monaco startup failed.\\n\\n' + (reason && reason.message ? reason.message : String(reason)));
        });

        function postContentChange() {
            if (!editor || suppressContentEvents) return;
            window.webkit.messageHandlers.contentChanged.postMessage(editor.getValue());
        }

        window.__gingerttySetValue = function(value) {
            if (!editor) return;
            if (editor.getValue() === value) return;
            suppressContentEvents = true;
            editor.setValue(value);
            suppressContentEvents = false;
        };

        window.__gingerttyShowFind = function() {
            if (!editor) return;
            editor.focus();
            editor.getAction('actions.find').run();
        };

        if (typeof require === 'undefined') {
            showError('Failed to load Monaco loader from the app bundle.');
        } else {
        require.config({ paths: { vs: 'vs' } });
        require(['vs/editor/editor.main'], function() {
            monaco.editor.defineTheme(monacoThemeName, monacoThemeDefinition);
            const model = monaco.editor.createModel(initialContent, initialLanguage);
            editor = monaco.editor.create(document.getElementById('container'), {
                model,
                theme: monacoThemeName,
                automaticLayout: true,
                minimap: { enabled: false },
                scrollBeyondLastLine: false,
                smoothScrolling: true,
                readOnly: false,
                renderWhitespace: 'selection',
                fontSize: 13,
                fontFamily: 'Menlo, Monaco, "Courier New", monospace',
                lineNumbersMinChars: 4,
                tabSize: 4,
                insertSpaces: true,
                wordWrap: 'off',
            });

            document.body.style.background = shellBackground;
            document.body.style.color = shellForeground;
            document.getElementById('container').style.background = shellBackground;
            document.getElementById('error').style.color = errorText;

            editor.onDidChangeModelContent(() => {
                if (suppressContentEvents) return;
                window.clearTimeout(changeTimer);
                changeTimer = window.setTimeout(postContentChange, 40);
            });

            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
                const currentContent = editor.getValue();
                window.webkit.messageHandlers.saveRequested.postMessage({ content: currentContent });
            });

            editor.focus();
            window.webkit.messageHandlers.editorReady.postMessage({});
        }, function(error) {
            showError('Failed to load Monaco editor.\\n\\n' + (error && error.message ? error.message : String(error)));
        });
        }
        </script>
        </body>
        </html>
        """
    }

    private static func errorHTML(message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body {
                margin: 0;
                width: 100%;
                height: 100%;
                background: #0b1220;
                color: #fca5a5;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            body {
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
                text-align: center;
                white-space: pre-wrap;
                line-height: 1.5;
            }
        </style>
        </head>
        <body>\(message)</body>
        </html>
        """
    }

    private static func detectLanguage(from path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "swift": return "swift"
        case "rb": return "ruby"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "zig": return "zig"
        case "sh", "bash", "zsh": return "shell"
        case "yaml", "yml": return "yaml"
        case "json": return "json"
        case "xml", "plist", "sdef": return "xml"
        case "html", "xib": return "html"
        case "css": return "css"
        case "md": return "markdown"
        case "sql": return "sql"
        default: return ext.isEmpty ? "plaintext" : "plaintext"
        }
    }

    private static func escapeJSString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func escapeJSTemplateLiteral(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func escapeJSONString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string], options: [])
        let arrayLiteral = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onContentChanged: (String) -> Void
        let onSaveRequested: (String?) -> Void

        weak var webView: WKWebView?
        var lastFilePath: String = ""
        var lastContent: String = ""
        var lastThemeType: String = ""
        var isReady = false

        init(
            onContentChanged: @escaping (String) -> Void,
            onSaveRequested: @escaping (String?) -> Void
        ) {
            self.onContentChanged = onContentChanged
            self.onSaveRequested = onSaveRequested
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "editorReady":
                isReady = true
            case "contentChanged":
                guard let content = message.body as? String else { return }
                lastContent = content
                DispatchQueue.main.async { [onContentChanged] in
                    onContentChanged(content)
                }
            case "saveRequested":
                let payload = message.body as? [String: Any]
                let content = payload?["content"] as? String
                if let content {
                    lastContent = content
                }
                DispatchQueue.main.async { [onContentChanged, onSaveRequested] in
                    if let content {
                        onContentChanged(content)
                    }
                    onSaveRequested(content)
                }
            default:
                break
            }
        }
    }
}
