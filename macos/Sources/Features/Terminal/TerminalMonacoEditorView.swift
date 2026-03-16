import Foundation
import SwiftUI
import WebKit

enum TerminalFileViewerLayoutMode: Equatable {
    case editorOnly
    case markdownSplitPreview

    static func forFilePath(_ filePath: String?) -> Self {
        guard let filePath else { return .editorOnly }
        let normalized = filePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(".md")
            || normalized.hasSuffix(".markdown")
            ? .markdownSplitPreview
            : .editorOnly
    }
}

private struct MonacoEmbeddedResources {
    struct ResourceSet {
        let baseURL: URL
        let workerPaths: WorkerPaths
    }

    struct WorkerPaths {
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

        func absoluteJSON(baseURL: URL) -> String {
            let dictionary: [String: String] = [
                "editor": baseURL.appendingPathComponent(editor).absoluteString,
                "json": baseURL.appendingPathComponent(json).absoluteString,
                "css": baseURL.appendingPathComponent(css).absoluteString,
                "html": baseURL.appendingPathComponent(html).absoluteString,
                "typescript": baseURL.appendingPathComponent(typescript).absoluteString,
            ]
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
            return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
                .replacingOccurrences(of: "</", with: "<\\/")
        }
    }

    static let resourceMissingMessage = """
    Monaco editor assets are missing from the app bundle.

    Rebuild and reinstall GingerTTY so the bundled Monaco resources are copied into the app.
    """

    static var resources: ResourceSet? {
        guard let baseURL = Bundle.main.resourceURL?.appendingPathComponent("Monaco", isDirectory: true),
              let workerPaths = resolveWorkerPaths(baseURL: baseURL) else {
            return nil
        }
        return ResourceSet(baseURL: baseURL, workerPaths: workerPaths)
    }

    static func errorHTML(message: String, theme: TerminalCodeTheme) -> String {
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
                background: \(theme.shellBackgroundHex);
                color: \(theme.errorHex);
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

    static func detectLanguage(from path: String) -> String {
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
        default: return "plaintext"
        }
    }

    static func escapeJSString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    static func escapeJSTemplateLiteral(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    static func escapeJSONString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string], options: [])
        let arrayLiteral = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
            .replacingOccurrences(of: "</", with: "<\\/")
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
}

@MainActor
final class MonacoEditorModel: ObservableObject {
    weak var webView: WKWebView?

    func showFind() {
        webView?.evaluateJavaScript("window.__gingerttyShowFind && window.__gingerttyShowFind();")
    }
}

struct MonacoMarkdownPreviewWebView: NSViewRepresentable {
    let content: String
    let theme: TerminalCodeTheme
    var documentURL: URL? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "previewReady")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.lastContent = content
        context.coordinator.lastThemeName = theme.monacoThemeName
        context.coordinator.lastIsDark = theme.isDark
        context.coordinator.lastBackgroundHex = theme.shellBackgroundHex
        context.coordinator.lastForegroundHex = theme.shellForegroundHex
        context.coordinator.lastMutedHex = theme.mutedHex
        context.coordinator.lastErrorHex = theme.errorHex
        context.coordinator.lastDocumentBaseURL = documentURL?.deletingLastPathComponent().absoluteString

        Self.loadPreview(into: webView, content: content, theme: theme, documentURL: documentURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let documentBaseURL = documentURL?.deletingLastPathComponent().absoluteString
        let documentChanged = context.coordinator.lastDocumentBaseURL != documentBaseURL

        if documentChanged {
            context.coordinator.lastDocumentBaseURL = documentBaseURL
            context.coordinator.lastContent = content
            context.coordinator.lastThemeName = theme.monacoThemeName
            context.coordinator.lastIsDark = theme.isDark
            context.coordinator.lastBackgroundHex = theme.shellBackgroundHex
            context.coordinator.lastForegroundHex = theme.shellForegroundHex
            context.coordinator.lastMutedHex = theme.mutedHex
            context.coordinator.lastErrorHex = theme.errorHex
            context.coordinator.isReady = false
            Self.loadPreview(into: webView, content: content, theme: theme, documentURL: documentURL)
            return
        }

        let themeChanged =
            context.coordinator.lastThemeName != theme.monacoThemeName
            || context.coordinator.lastIsDark != theme.isDark
            || context.coordinator.lastBackgroundHex != theme.shellBackgroundHex
            || context.coordinator.lastForegroundHex != theme.shellForegroundHex
            || context.coordinator.lastMutedHex != theme.mutedHex
            || context.coordinator.lastErrorHex != theme.errorHex
        let contentChanged = context.coordinator.lastContent != content

        guard themeChanged || contentChanged else { return }

        context.coordinator.lastContent = content
        context.coordinator.lastThemeName = theme.monacoThemeName
        context.coordinator.lastIsDark = theme.isDark
        context.coordinator.lastBackgroundHex = theme.shellBackgroundHex
        context.coordinator.lastForegroundHex = theme.shellForegroundHex
        context.coordinator.lastMutedHex = theme.mutedHex
        context.coordinator.lastErrorHex = theme.errorHex

        guard context.coordinator.isReady else {
            Self.loadPreview(into: webView, content: content, theme: theme, documentURL: documentURL)
            return
        }

        if themeChanged {
            let setThemeJS = """
            window.__gingerttySetTheme && window.__gingerttySetTheme(
                \(MonacoEmbeddedResources.escapeJSONString(theme.monacoThemeName)),
                \(theme.isDark ? "true" : "false"),
                \(MonacoEmbeddedResources.escapeJSONString(theme.shellBackgroundHex)),
                \(MonacoEmbeddedResources.escapeJSONString(theme.shellForegroundHex)),
                \(MonacoEmbeddedResources.escapeJSONString(theme.mutedHex)),
                \(MonacoEmbeddedResources.escapeJSONString(theme.errorHex))
            );
            """
            webView.evaluateJavaScript(setThemeJS)
        }

        if contentChanged {
            let setValueJS = """
            window.__gingerttySetMarkdownContent && window.__gingerttySetMarkdownContent(
                \(MonacoEmbeddedResources.escapeJSONString(content))
            );
            """
            webView.evaluateJavaScript(setValueJS)
        }
    }

    // Monaco's public bundle exposes colorize() but not the internal markdown
    // renderer, so the preview does a small local markdown-to-HTML pass and
    // delegates fenced code highlighting back to Monaco.
    private static func buildHTML(
        content: String,
        theme: TerminalCodeTheme,
        resources: MonacoEmbeddedResources.ResourceSet
    ) -> String {
        let escapedContent = MonacoEmbeddedResources.escapeJSTemplateLiteral(content)
        let workerPathsJSON = resources.workerPaths.absoluteJSON(baseURL: resources.baseURL)
        let loaderURL = resources.baseURL.appendingPathComponent("vs/loader.js").absoluteString
        let escapedMonacoBaseURL = MonacoEmbeddedResources.escapeJSString(resources.baseURL.absoluteString)
        let escapedShellBackground = MonacoEmbeddedResources.escapeJSString(theme.shellBackgroundHex)
        let escapedShellForeground = MonacoEmbeddedResources.escapeJSString(theme.shellForegroundHex)
        let escapedMuted = MonacoEmbeddedResources.escapeJSString(theme.mutedHex)
        let escapedError = MonacoEmbeddedResources.escapeJSString(theme.errorHex)
        let escapedMonacoThemeName = MonacoEmbeddedResources.escapeJSString(theme.monacoThemeName)
        let linkColor = theme.isDark ? "#58A6FF" : "#0969DA"
        let codeBackground = theme.isDark ? "#161B22" : "#F6F8FA"
        let borderColor = theme.isDark ? "#30363D" : "#D0D7DE"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            :root {
                color-scheme: \(theme.isDark ? "dark" : "light");
                --gg-bg: \(escapedShellBackground);
                --gg-fg: \(escapedShellForeground);
                --gg-muted: \(escapedMuted);
                --gg-error: \(escapedError);
                --gg-link: \(linkColor);
                --gg-border: \(borderColor);
                --gg-code-bg: \(codeBackground);
            }
            * { box-sizing: border-box; }
            html, body {
                margin: 0;
                width: 100%;
                height: 100%;
                overflow: hidden;
                background: var(--gg-bg);
                color: var(--gg-fg);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            body {
                display: flex;
                flex-direction: column;
            }
            #preview {
                flex: 1;
                overflow: auto;
                padding: 24px;
                font-size: 14px;
                line-height: 1.65;
                background: var(--gg-bg);
                color: var(--gg-fg);
            }
            #error {
                display: none;
                padding: 16px;
                color: var(--gg-error);
                white-space: pre-wrap;
                font-size: 13px;
                line-height: 1.5;
            }
            #preview > :first-child { margin-top: 0; }
            #preview > :last-child { margin-bottom: 0; }
            a {
                color: var(--gg-link);
                text-decoration: none;
            }
            a:hover { text-decoration: underline; }
            img {
                max-width: 100%;
                height: auto;
            }
            p, ul, ol, blockquote, table, pre {
                margin: 0 0 16px 0;
            }
            h1, h2, h3, h4, h5, h6 {
                margin: 24px 0 12px 0;
                line-height: 1.25;
            }
            h1:first-child, h2:first-child, h3:first-child, h4:first-child {
                margin-top: 0;
            }
            hr {
                border: 0;
                border-top: 1px solid var(--gg-border);
                margin: 24px 0;
            }
            ul, ol {
                padding-left: 24px;
            }
            blockquote {
                border-left: 3px solid var(--gg-border);
                margin-left: 0;
                padding-left: 16px;
                color: var(--gg-muted);
            }
            code {
                font-family: Menlo, Monaco, "Courier New", monospace;
                font-size: 12px;
                background: var(--gg-code-bg);
                border-radius: 6px;
                padding: 0.15em 0.35em;
            }
            .code-shell {
                border: 1px solid var(--gg-border);
                border-radius: 10px;
                overflow: hidden;
                margin-bottom: 16px;
                background: var(--gg-code-bg);
            }
            .code-header {
                padding: 8px 12px;
                font-size: 12px;
                color: var(--gg-muted);
                border-bottom: 1px solid var(--gg-border);
                text-transform: uppercase;
                letter-spacing: 0.04em;
            }
            .code-block {
                margin: 0;
                padding: 12px;
                overflow: auto;
                background: var(--gg-code-bg);
            }
            .code-block code {
                display: block;
                padding: 0;
                border-radius: 0;
                background: transparent;
            }
            .code-loading {
                padding: 12px;
                color: var(--gg-muted);
                font-size: 12px;
            }
            table {
                width: 100%;
                border-collapse: collapse;
                border-spacing: 0;
            }
            th, td {
                border: 1px solid var(--gg-border);
                padding: 8px 10px;
                vertical-align: top;
            }
            th {
                text-align: left;
                background: var(--gg-code-bg);
            }
        </style>
        </head>
        <body>
        <div id="preview"></div>
        <div id="error"></div>
        <script>
        const workerPaths = \(workerPathsJSON);
        const monacoBaseURL = '\(escapedMonacoBaseURL)';
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
                return new Worker(workerPath, {
                    type: 'module',
                    name: label
                });
            }
        };
        </script>
        <script src="\(loaderURL)"></script>
        <script>
        let markdownContent = `\(escapedContent)`;
        let monacoThemeName = '\(escapedMonacoThemeName)';
        let shellBackground = '\(escapedShellBackground)';
        let shellForeground = '\(escapedShellForeground)';
        let mutedText = '\(escapedMuted)';
        let errorText = '\(escapedError)';
        let isDarkTheme = \(theme.isDark ? "true" : "false");
        let isReady = false;
        let renderTimer = null;
        let renderVersion = 0;

        function showError(message) {
            document.getElementById('preview').style.display = 'none';
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = message;
        }

        function showPreview() {
            document.getElementById('error').style.display = 'none';
            document.getElementById('preview').style.display = 'block';
        }

        function escapeHTML(value) {
            return value
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        }

        function sanitizeURL(value) {
            const trimmed = value.trim();
            if (!trimmed) return null;
            if (trimmed.startsWith('#')) return trimmed;
            if (/^(https?|mailto|file):/i.test(trimmed)) return trimmed;
            if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) return null;
            return trimmed;
        }

        function restoreInlineTokens(text, tokens) {
            return text.replace(/__GINGER_INLINE_(\\d+)__/g, (_, index) => tokens[Number(index)] ?? '');
        }

        function renderInline(text) {
            const tokens = [];
            const storeToken = (html) => `__GINGER_INLINE_${tokens.push(html) - 1}__`;
            let working = text;

            working = working.replace(/`([^`]+)`/g, (_, code) => storeToken(`<code>${escapeHTML(code)}</code>`));
            working = escapeHTML(working);

            working = working.replace(/!\\[([^\\]]*)\\]\\(([^)]+)\\)/g, (_, alt, url) => {
                const safeURL = sanitizeURL(url);
                if (!safeURL) return alt;
                return storeToken(`<img src="${escapeHTML(safeURL)}" alt="${escapeHTML(alt)}">`);
            });

            working = working.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, (_, label, url) => {
                const safeURL = sanitizeURL(url);
                if (!safeURL) return label;
                return storeToken(`<a href="${escapeHTML(safeURL)}">${renderInline(label)}</a>`);
            });

            working = working.replace(/\\*\\*([^*]+)\\*\\*/g, (_, body) => storeToken(`<strong>${renderInline(body)}</strong>`));
            working = working.replace(/__([^_]+)__/g, (_, body) => storeToken(`<strong>${renderInline(body)}</strong>`));
            working = working.replace(/~~([^~]+)~~/g, (_, body) => storeToken(`<del>${renderInline(body)}</del>`));
            working = working.replace(/(^|[\\s(])\\*([^*]+)\\*(?=[\\s).,!?:;]|$)/g, (_, prefix, body) => `${prefix}${storeToken(`<em>${renderInline(body)}</em>`)}`);
            working = working.replace(/(^|[\\s(])_([^_]+)_(?=[\\s).,!?:;]|$)/g, (_, prefix, body) => `${prefix}${storeToken(`<em>${renderInline(body)}</em>`)}`);

            return restoreInlineTokens(working, tokens);
        }

        function isBlank(line) {
            return line.trim().length === 0;
        }

        function isCodeToken(line) {
            return /^@@CODEBLOCK:code-\\d+@@$/.test(line.trim());
        }

        function isHorizontalRule(line) {
            return /^ {0,3}([-*_])(?:\\s*\\1){2,}\\s*$/.test(line);
        }

        function isHeading(line) {
            return /^\\s*#{1,6}\\s+/.test(line);
        }

        function listMatch(line) {
            return line.match(/^\\s*(?:[-*+]|\\d+\\.)\\s+(.*)$/);
        }

        function isTableSeparator(line) {
            return /^\\s*\\|?(?:\\s*:?-+:?\\s*\\|)+\\s*:?-+:?\\s*\\|?\\s*$/.test(line);
        }

        function splitPipeRow(line) {
            let trimmed = line.trim();
            if (trimmed.startsWith('|')) trimmed = trimmed.slice(1);
            if (trimmed.endsWith('|')) trimmed = trimmed.slice(0, -1);
            return trimmed.split('|').map((cell) => cell.trim());
        }

        function startsNewBlock(lines, index) {
            const line = lines[index];
            return isCodeToken(line)
                || isHorizontalRule(line)
                || isHeading(line)
                || /^\\s*>/.test(line)
                || !!listMatch(line)
                || (line.includes('|') && index + 1 < lines.length && isTableSeparator(lines[index + 1]));
        }

        function renderParagraph(lines) {
            return `<p>${renderInline(lines.join('\\n').trim()).replace(/\\n/g, '<br>')}</p>`;
        }

        function renderTable(lines, start) {
            const headers = splitPipeRow(lines[start]);
            const separators = splitPipeRow(lines[start + 1]);
            const alignments = separators.map((cell) => {
                if (/^:\\s*-+\\s*:$/.test(cell)) return 'center';
                if (/^-+\\s*:$/.test(cell)) return 'right';
                if (/^:\\s*-+$/.test(cell)) return 'left';
                return null;
            });

            let index = start + 2;
            const rows = [];
            while (index < lines.length && !isBlank(lines[index]) && lines[index].includes('|')) {
                rows.push(splitPipeRow(lines[index]));
                index += 1;
            }

            const headHTML = headers.map((cell, cellIndex) => {
                const alignment = alignments[cellIndex] ? ` style="text-align:${alignments[cellIndex]}"` : '';
                return `<th${alignment}>${renderInline(cell)}</th>`;
            }).join('');
            const bodyHTML = rows.map((row) => {
                const cells = row.map((cell, cellIndex) => {
                    const alignment = alignments[cellIndex] ? ` style="text-align:${alignments[cellIndex]}"` : '';
                    return `<td${alignment}>${renderInline(cell)}</td>`;
                }).join('');
                return `<tr>${cells}</tr>`;
            }).join('');

            const html = `<table><thead><tr>${headHTML}</tr></thead>${bodyHTML ? `<tbody>${bodyHTML}</tbody>` : ''}</table>`;
            return { html, nextIndex: index };
        }

        function renderList(lines, start) {
            const ordered = /^\\s*\\d+\\./.test(lines[start]);
            const tag = ordered ? 'ol' : 'ul';
            const items = [];
            let index = start;

            while (index < lines.length) {
                const match = listMatch(lines[index]);
                if (!match) break;
                items.push(`<li>${renderInline(match[1].trim())}</li>`);
                index += 1;
                if (index < lines.length && isBlank(lines[index])) break;
            }

            return { html: `<${tag}>${items.join('')}</${tag}>`, nextIndex: index };
        }

        function renderBlockquote(lines, start) {
            const quoteLines = [];
            let index = start;
            while (index < lines.length && /^\\s*>/.test(lines[index])) {
                quoteLines.push(lines[index].replace(/^\\s*>\\s?/, ''));
                index += 1;
            }
            return { html: `<blockquote>${renderBlocks(quoteLines)}</blockquote>`, nextIndex: index };
        }

        function extractCodeBlocks(markdown) {
            const codeBlocks = [];
            const normalized = markdown.replace(/\\r\\n?/g, '\\n');
            const text = normalized.replace(/(^|\\n)```([^\\n`]*)\\n([\\s\\S]*?)\\n```(?=\\n|$)/g, (match, prefix, language, code) => {
                const id = `code-${codeBlocks.length}`;
                codeBlocks.push({ id, language: language.trim(), code });
                return `${prefix}@@CODEBLOCK:${id}@@`;
            });
            return { text, codeBlocks };
        }

        function renderBlocks(lines) {
            const blocks = [];
            let index = 0;

            while (index < lines.length) {
                const line = lines[index];
                if (isBlank(line)) {
                    index += 1;
                    continue;
                }

                if (isCodeToken(line)) {
                    const id = line.trim().replace('@@CODEBLOCK:', '').replace('@@', '');
                    blocks.push(`<div class="code-shell"><div class="code-placeholder" data-code-id="${id}"><div class="code-loading">Rendering code block...</div></div></div>`);
                    index += 1;
                    continue;
                }

                const headingMatch = line.match(/^\\s*(#{1,6})\\s+(.*)$/);
                if (headingMatch) {
                    const level = headingMatch[1].length;
                    blocks.push(`<h${level}>${renderInline(headingMatch[2].trim())}</h${level}>`);
                    index += 1;
                    continue;
                }

                if (isHorizontalRule(line)) {
                    blocks.push('<hr>');
                    index += 1;
                    continue;
                }

                if (line.includes('|') && index + 1 < lines.length && isTableSeparator(lines[index + 1])) {
                    const table = renderTable(lines, index);
                    blocks.push(table.html);
                    index = table.nextIndex;
                    continue;
                }

                if (/^\\s*>/.test(line)) {
                    const blockquote = renderBlockquote(lines, index);
                    blocks.push(blockquote.html);
                    index = blockquote.nextIndex;
                    continue;
                }

                if (listMatch(line)) {
                    const list = renderList(lines, index);
                    blocks.push(list.html);
                    index = list.nextIndex;
                    continue;
                }

                const paragraphLines = [line];
                index += 1;
                while (index < lines.length && !isBlank(lines[index]) && !startsNewBlock(lines, index)) {
                    paragraphLines.push(lines[index]);
                    index += 1;
                }
                blocks.push(renderParagraph(paragraphLines));
            }

            return blocks.join('\\n');
        }

        function renderMarkdownToHTML(markdown) {
            const extracted = extractCodeBlocks(markdown);
            return {
                html: renderBlocks(extracted.text.split('\\n')),
                codeBlocks: extracted.codeBlocks,
            };
        }

        function applyTheme() {
            document.documentElement.style.setProperty('--gg-bg', shellBackground);
            document.documentElement.style.setProperty('--gg-fg', shellForeground);
            document.documentElement.style.setProperty('--gg-muted', mutedText);
            document.documentElement.style.setProperty('--gg-error', errorText);
            document.documentElement.style.colorScheme = isDarkTheme ? 'dark' : 'light';
            document.body.style.background = shellBackground;
            document.body.style.color = shellForeground;
            document.getElementById('preview').style.background = shellBackground;
            document.getElementById('error').style.color = errorText;
            if (isReady) {
                monaco.editor.setTheme(monacoThemeName);
            }
        }

        function scheduleRender(delay = 60) {
            if (!isReady) return;
            window.clearTimeout(renderTimer);
            renderTimer = window.setTimeout(() => {
                void renderPreview();
            }, delay);
        }

        async function renderPreview() {
            if (!isReady) return;
            const currentVersion = ++renderVersion;
            try {
                const rendered = renderMarkdownToHTML(markdownContent);
                const previewEl = document.getElementById('preview');
                previewEl.innerHTML = rendered.html;
                showPreview();

                await Promise.all(rendered.codeBlocks.map(async (block) => {
                    const target = previewEl.querySelector(`[data-code-id="${block.id}"]`);
                    if (!target) return;

                    const language = block.language || 'plaintext';
                    const languageLabel = escapeHTML(language || 'plain text');

                    try {
                        const colored = await monaco.editor.colorize(block.code, language);
                        if (currentVersion !== renderVersion) return;
                        target.innerHTML = `<div class="code-header">${languageLabel}</div><pre class="code-block"><code>${colored}</code></pre>`;
                    } catch (error) {
                        if (currentVersion !== renderVersion) return;
                        target.innerHTML = `<div class="code-header">${languageLabel}</div><pre class="code-block"><code>${escapeHTML(block.code)}</code></pre>`;
                    }
                }));
            } catch (error) {
                showError('Markdown preview failed.\\n\\n' + (error && error.message ? error.message : String(error)));
            }
        }

        window.__gingerttySetMarkdownContent = function(value) {
            markdownContent = value;
            scheduleRender();
        };

        window.__gingerttySetTheme = function(themeName, darkMode, background, foreground, muted, errorColor) {
            monacoThemeName = themeName;
            isDarkTheme = darkMode;
            shellBackground = background;
            shellForeground = foreground;
            mutedText = muted;
            errorText = errorColor;
            applyTheme();
            scheduleRender();
        };

        window.addEventListener('error', (event) => {
            showError('Markdown preview failed.\\n\\n' + (event.error && event.error.message ? event.error.message : event.message));
        });

        window.addEventListener('unhandledrejection', (event) => {
            const reason = event.reason;
            showError('Markdown preview failed.\\n\\n' + (reason && reason.message ? reason.message : String(reason)));
        });

        applyTheme();

        if (typeof require === 'undefined') {
            showError('Failed to load Monaco loader from the app bundle.');
        } else {
            require.config({ paths: { vs: monacoBaseURL + 'vs' } });
            require(['vs/editor/editor.main'], function() {
                isReady = true;
                applyTheme();
                scheduleRender(0);
                window.webkit.messageHandlers.previewReady.postMessage({});
            }, function(error) {
                showError('Failed to load Monaco preview renderer.\\n\\n' + (error && error.message ? error.message : String(error)));
            });
        }
        </script>
        </body>
        </html>
        """
    }

    private static func loadPreview(
        into webView: WKWebView,
        content: String,
        theme: TerminalCodeTheme,
        documentURL: URL?
    ) {
        guard let resources = MonacoEmbeddedResources.resources else {
            webView.loadHTMLString(
                MonacoEmbeddedResources.errorHTML(
                    message: MonacoEmbeddedResources.resourceMissingMessage,
                    theme: theme
                ),
                baseURL: nil
            )
            return
        }

        let html = buildHTML(content: content, theme: theme, resources: resources)
        let baseURL = documentURL?.deletingLastPathComponent() ?? resources.baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastContent: String = ""
        var lastThemeName: String = ""
        var lastIsDark = false
        var lastBackgroundHex: String = ""
        var lastForegroundHex: String = ""
        var lastMutedHex: String = ""
        var lastErrorHex: String = ""
        var lastDocumentBaseURL: String?
        var isReady = false

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "previewReady" {
                isReady = true
            }
        }
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
        context.coordinator.lastThemeName = theme.monacoThemeName
        editorModel?.webView = webView

        guard let resources = Self.monacoResources else {
            webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage, theme: theme), baseURL: nil)
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
            context.coordinator.lastThemeName = theme.monacoThemeName
            context.coordinator.isReady = false
            guard let resources = Self.monacoResources else {
                webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage, theme: theme), baseURL: nil)
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

        let themeChanged = context.coordinator.lastThemeName != theme.monacoThemeName
        let contentChanged = context.coordinator.lastContent != content
        guard themeChanged || contentChanged else { return }

        context.coordinator.lastContent = content
        context.coordinator.lastThemeName = theme.monacoThemeName

        if context.coordinator.isReady {
            if contentChanged && !themeChanged {
                let setValueJS = "window.__gingerttySetValue && window.__gingerttySetValue(\(Self.escapeJSONString(content)));"
                webView.evaluateJavaScript(setValueJS)
                return
            }

            if themeChanged && !contentChanged {
                let setThemeJS = "window.__gingerttySetTheme && window.__gingerttySetTheme(\(Self.escapeJSONString(theme.monacoThemeName)));"
                webView.evaluateJavaScript(setThemeJS)
                return
            }
        }

        guard let resources = Self.monacoResources else {
            webView.loadHTMLString(Self.errorHTML(message: Self.resourceMissingMessage, theme: theme), baseURL: nil)
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

    private typealias MonacoResources = MonacoEmbeddedResources.ResourceSet
    private typealias WorkerPaths = MonacoEmbeddedResources.WorkerPaths

    private static let resourceMissingMessage = MonacoEmbeddedResources.resourceMissingMessage

    private static var monacoResources: MonacoResources? {
        MonacoEmbeddedResources.resources
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

        window.__gingerttySetTheme = function(themeName) {
            if (!editor) return;
            monaco.editor.setTheme(themeName);
        };

        if (typeof require === 'undefined') {
            showError('Failed to load Monaco loader from the app bundle.');
        } else {
        require.config({ paths: { vs: 'vs' } });
        require(['vs/editor/editor.main'], function() {
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
            monaco.editor.setTheme(monacoThemeName);

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

    private static func errorHTML(message: String, theme: TerminalCodeTheme) -> String {
        MonacoEmbeddedResources.errorHTML(message: message, theme: theme)
    }

    private static func detectLanguage(from path: String) -> String {
        MonacoEmbeddedResources.detectLanguage(from: path)
    }

    private static func escapeJSString(_ string: String) -> String {
        MonacoEmbeddedResources.escapeJSString(string)
    }

    private static func escapeJSTemplateLiteral(_ string: String) -> String {
        MonacoEmbeddedResources.escapeJSTemplateLiteral(string)
    }

    private static func escapeJSONString(_ string: String) -> String {
        MonacoEmbeddedResources.escapeJSONString(string)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onContentChanged: (String) -> Void
        let onSaveRequested: (String?) -> Void

        weak var webView: WKWebView?
        var lastFilePath: String = ""
        var lastContent: String = ""
        var lastThemeName: String = ""
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
