import AppKit
import SwiftUI
import WebKit

// MARK: - WebView Find Bar

@MainActor
final class WebViewFindModel: ObservableObject {
    @Published var isVisible = false
    @Published var searchText = ""
    @Published var matchInfo = ""
    @Published var focusToken = 0
    weak var webView: WKWebView?

    private var isInjected = false

    func show(prefillSelection: Bool = false) {
        isVisible = true
        injectIfNeeded()
        focusToken &+= 1

        guard prefillSelection else { return }
        pullSelectedText { [weak self] selectedText in
            guard let self else { return }
            let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSelection.isEmpty else { return }
            self.searchText = trimmedSelection
            self.findNext()
        }
    }

    func hide() {
        isVisible = false
        searchText = ""
        matchInfo = ""
        run("_pfClear()")
    }

    func findNext() {
        guard !searchText.isEmpty else { return }
        run("_pfNext('\(jsEscape(searchText))')") { [weak self] result in
            self?.matchInfo = result
        }
    }

    func findPrevious() {
        guard !searchText.isEmpty else { return }
        run("_pfPrev('\(jsEscape(searchText))')") { [weak self] result in
            self?.matchInfo = result
        }
    }

    private func run(_ js: String, completion: ((String) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, _ in
            if let s = result as? String { completion?(s) }
        }
    }

    func copySelectionToPasteboard() {
        pullSelectedText { selectedText in
            let trimmed = selectedText.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
            } else {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
        }
    }

    private func pullSelectedText(completion: @escaping (String) -> Void) {
        webView?.evaluateJavaScript(Self.selectionExtractionScript) { result, _ in
            completion(result as? String ?? "")
        }
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    func injectIfNeeded() {
        guard !isInjected else { return }
        isInjected = true
        webView?.evaluateJavaScript(Self.findScript)
    }

    static let selectionExtractionScript = """
    (function() {
        const directSelection = (window.getSelection && window.getSelection().toString()) || '';
        if (directSelection && directSelection.trim().length > 0) {
            return directSelection;
        }

        const active = document.activeElement;
        if (active && typeof active.value === 'string' && active.selectionStart != null && active.selectionEnd != null && active.selectionEnd > active.selectionStart) {
            return active.value.substring(active.selectionStart, active.selectionEnd);
        }

        function selectionFromShadow(root) {
            if (!root) return '';
            for (const node of root.querySelectorAll('*')) {
                if (!node.shadowRoot) continue;
                const nestedSelection = selectionFromShadow(node.shadowRoot);
                if (nestedSelection) return nestedSelection;
                const inner = node.shadowRoot.activeElement;
                if (inner && typeof inner.value === 'string' && inner.selectionStart != null && inner.selectionEnd != null && inner.selectionEnd > inner.selectionStart) {
                    return inner.value.substring(inner.selectionStart, inner.selectionEnd);
                }
            }
            return '';
        }

        return selectionFromShadow(document);
    })();
    """

    // JS that finds text inside shadow DOMs, highlights matches, and scrolls to them
    static let findScript = """
    (function() {
        if (window._pfInit) return;
        window._pfInit = true;

        var matches = [];
        var currentIdx = -1;
        var lastQuery = '';
        const HL_STYLE = 'background: #facc15; color: #000; border-radius: 2px;';
        const HL_ACTIVE = 'background: #f97316; color: #000; border-radius: 2px;';
        const MARK_CLASS = '_pf-hl';

        function getTextNodes(root) {
            const nodes = [];
            const walk = (n) => {
                if (n.shadowRoot) walk(n.shadowRoot);
                if (n.nodeType === 3 && n.textContent.trim().length > 0) {
                    nodes.push(n);
                } else {
                    for (const c of n.childNodes) walk(c);
                }
            };
            walk(root);
            return nodes;
        }

        function clearMarks() {
            // Remove all highlight marks across all shadow roots
            const removeIn = (root) => {
                for (const mark of root.querySelectorAll('.' + MARK_CLASS)) {
                    const parent = mark.parentNode;
                    parent.replaceChild(document.createTextNode(mark.textContent), mark);
                    parent.normalize();
                }
                for (const el of root.querySelectorAll('*')) {
                    if (el.shadowRoot) removeIn(el.shadowRoot);
                }
            };
            removeIn(document);
            matches = [];
            currentIdx = -1;
        }

        function search(query) {
            clearMarks();
            if (!query) return '0/0';
            const lower = query.toLowerCase();
            const textNodes = getTextNodes(document.body);
            for (const node of textNodes) {
                const text = node.textContent;
                const textLower = text.toLowerCase();
                let idx = 0;
                const parts = [];
                let searchFrom = 0;
                while (true) {
                    const found = textLower.indexOf(lower, searchFrom);
                    if (found === -1) break;
                    if (found > idx) parts.push({ text: text.slice(idx, found), match: false });
                    parts.push({ text: text.slice(found, found + query.length), match: true });
                    idx = found + query.length;
                    searchFrom = idx;
                }
                if (parts.length === 0) continue;
                if (idx < text.length) parts.push({ text: text.slice(idx), match: false });
                const frag = document.createDocumentFragment();
                for (const p of parts) {
                    if (p.match) {
                        const mark = document.createElement('span');
                        mark.className = MARK_CLASS;
                        mark.style.cssText = HL_STYLE;
                        mark.textContent = p.text;
                        frag.appendChild(mark);
                        matches.push(mark);
                    } else {
                        frag.appendChild(document.createTextNode(p.text));
                    }
                }
                node.parentNode.replaceChild(frag, node);
            }
            lastQuery = query;
            return matches.length > 0 ? '0/' + matches.length : '0/0';
        }

        function setActive(idx) {
            if (currentIdx >= 0 && currentIdx < matches.length) {
                matches[currentIdx].style.cssText = HL_STYLE;
            }
            currentIdx = idx;
            if (currentIdx >= 0 && currentIdx < matches.length) {
                matches[currentIdx].style.cssText = HL_ACTIVE;
                // Scroll into view, traversing shadow host boundaries
                let el = matches[currentIdx];
                el.scrollIntoView({ block: 'center', behavior: 'smooth' });
            }
        }

        window._pfNext = function(query) {
            if (query !== lastQuery) search(query);
            if (matches.length === 0) return '0/0';
            setActive((currentIdx + 1) % matches.length);
            return (currentIdx + 1) + '/' + matches.length;
        };

        window._pfPrev = function(query) {
            if (query !== lastQuery) search(query);
            if (matches.length === 0) return '0/0';
            setActive((currentIdx - 1 + matches.length) % matches.length);
            return (currentIdx + 1) + '/' + matches.length;
        };

        window._pfClear = function() {
            clearMarks();
            lastQuery = '';
            return '';
        };
    })();
    """
}

struct WebViewFindBar: View {
    @ObservedObject var model: WebViewFindModel

    var body: some View {
        if model.isVisible {
            HStack(spacing: 6) {
                TerminalNativeSearchField(
                    text: $model.searchText,
                    placeholder: "Find…",
                    focusOnAppear: false,
                    focusToken: model.focusToken,
                    selectAllOnFocus: true,
                    onReturn: { model.findNext() },
                    onShiftReturn: { model.findPrevious() },
                    onEscape: { model.hide() },
                    onTextDidChange: { model.findNext() }
                )
                .frame(width: 200)

                if !model.matchInfo.isEmpty {
                    Text(model.matchInfo)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Button {
                    model.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Button {
                    model.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private enum PierreLocalResources {
    static let directoryName = "PierreDiffs"
    static let bundleFileName = "pierre-diffs.bundle.mjs"
    static let moduleImportPath = "./\(bundleFileName)"
    static let missingMessage = """
    Pierre diff assets are missing from the app bundle.

    Rebuild and reinstall GingerTTY so the bundled Pierre resources are copied into the app.
    """

    static var baseURL: URL? {
        guard let baseURL = Bundle.main.resourceURL?.appendingPathComponent(directoryName, isDirectory: true) else {
            return nil
        }

        let bundleURL = baseURL.appendingPathComponent(bundleFileName)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return nil
        }

        return baseURL
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
}

// MARK: - Main Diff View

struct TerminalDiffView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var findModel = WebViewFindModel()

    private var codeTheme: TerminalCodeTheme {
        .forColorScheme(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider()
            diffContent
        }
        .overlay(alignment: .topTrailing) {
            WebViewFindBar(model: findModel)
        }
        .background {
            Button("") { handleFindShortcut() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { findModel.copySelectionToPasteboard() }
                .keyboardShortcut("c", modifiers: .command)
                .hidden()
        }
        .onExitCommand {
            controller.closeDiff()
        }
    }

    private var diffHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeDiff()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            if let file = tab.selectedDiffFile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let file = tab.selectedDiffFile, !file.isBinary {
                HStack(spacing: 4) {
                    Text("+\(file.additions)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.green)
                    Text("-\(file.deletions)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var diffContent: some View {
        Group {
            if tab.isDiffLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading diff…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffText = tab.diffRawText, !diffText.isEmpty {
                PierreDiffWebView(
                    diffText: diffText,
                    fileName: tab.selectedDiffFile?.path ?? "",
                    fileContent: tab.diffFileContent,
                    theme: codeTheme,
                    reviewThread: tab.activeReviewThread,
                    isReviewMode: tab.isReviewMode,
                    draftComments: tab.localReviewComments.filter { $0.filePath == tab.selectedDiffFile?.path },
                    selectedDraftCommentID: tab.selectedReviewCommentID?.uuidString,
                    reloadRevision: tab.diffReloadRevision,
                    findModel: findModel,
                    onLinesSelected: { startLine, endLine, side in
                        tab.pendingSelectionStart = startLine
                        tab.pendingSelectionEnd = endLine
                        tab.pendingSelectionSide = side
                        tab.showCommentBox = true
                        controller.objectWillChange.send()
                    },
                    onAddThreadToChat: { threadID in
                        guard let threadID else { return }
                        _ = controller.addThreadToChat(threadID: threadID)
                    },
                    onReplyToThread: { threadID, body in
                        controller.replyToThread(threadID: threadID, body: body)
                    },
                    onResolveThread: { threadID, resolve in
                        controller.resolveThread(threadID: threadID, resolve: resolve)
                    },
                    onStartReview: { startLine, endLine, side, body in
                        guard let file = tab.selectedDiffFile else { return }
                        let comment = TerminalLocalReviewComment(
                            id: UUID(),
                            filePath: file.path,
                            startLine: startLine,
                            endLine: endLine,
                            side: side,
                            text: body
                        )
                        tab.addReviewComment(comment)
                        controller.objectWillChange.send()
                    },
                    onDeleteDraft: { commentID in
                        if let uuid = UUID(uuidString: commentID) {
                            tab.removeReviewComment(id: uuid)
                            controller.objectWillChange.send()
                        }
                    },
                    onUpdateDraft: { commentID, body in
                        if let uuid = UUID(uuidString: commentID) {
                            tab.updateReviewComment(id: uuid, text: body)
                            controller.objectWillChange.send()
                        }
                    }
                )
            } else {
                VStack {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
        .overlay(alignment: .bottom) {
            if !tab.isReviewMode && tab.showCommentBox {
                InlineCommentBox(
                    text: Binding(
                        get: { tab.pendingCommentText },
                        set: { tab.pendingCommentText = $0 }
                    ),
                    selectedRange: commentRangeLabel,
                    onAdd: { addComment() },
                    onCancel: { cancelComment() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.showCommentBox)
    }

    private var commentRangeLabel: String {
        guard let start = tab.pendingSelectionStart else { return "" }
        let end = tab.pendingSelectionEnd ?? start
        let side = tab.pendingSelectionSide ?? "new"
        if start == end {
            return "Line \(start) (\(side))"
        }
        return "Lines \(start)–\(end) (\(side))"
    }

    private func handleFindShortcut() {
        findModel.show(prefillSelection: true)
    }

    private func addComment() {
        let text = tab.pendingCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let file = tab.selectedDiffFile,
              let start = tab.pendingSelectionStart else { return }

        let comment = TerminalLocalReviewComment(
            id: UUID(),
            filePath: file.path,
            startLine: start,
            endLine: tab.pendingSelectionEnd ?? start,
            side: tab.pendingSelectionSide ?? "new",
            text: text
        )
        tab.addReviewComment(comment)
        cancelComment()
    }

    private func cancelComment() {
        tab.pendingCommentText = ""
        tab.pendingSelectionStart = nil
        tab.pendingSelectionEnd = nil
        tab.pendingSelectionSide = nil
        tab.showCommentBox = false
        controller.objectWillChange.send()
    }

    private var emptyMessage: String {
        if let file = tab.selectedDiffFile {
            if file.isBinary { return "Binary file — no diff available." }
        }
        return "No diff content available."
    }
}

// MARK: - WKWebView wrapper for @pierre/diffs

struct PierreDiffWebView: NSViewRepresentable {
    let diffText: String
    let fileName: String
    let fileContent: String?
    let theme: TerminalCodeTheme
    let reviewThread: TerminalPullRequestReviewThread?
    let isReviewMode: Bool
    let draftComments: [TerminalLocalReviewComment]
    let selectedDraftCommentID: String?
    let reloadRevision: Int
    var findModel: WebViewFindModel? = nil
    let onLinesSelected: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    let onAddThreadToChat: (_ threadID: String?) -> Void
    let onReplyToThread: (_ threadID: String, _ body: String) -> Void
    let onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
    let onStartReview: (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void
    let onDeleteDraft: (_ commentID: String) -> Void
    let onUpdateDraft: (_ commentID: String, _ body: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLinesSelected: onLinesSelected,
            onAddThreadToChat: onAddThreadToChat,
            onReplyToThread: onReplyToThread,
            onResolveThread: onResolveThread,
            onStartReview: onStartReview,
            onDeleteDraft: onDeleteDraft,
            onUpdateDraft: onUpdateDraft
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "lineSelection")
        contentController.add(context.coordinator, name: "addToChat")
        contentController.add(context.coordinator, name: "replyToThread")
        contentController.add(context.coordinator, name: "resolveThread")
        contentController.add(context.coordinator, name: "startReview")
        contentController.add(context.coordinator, name: "deleteDraft")
        contentController.add(context.coordinator, name: "updateDraft")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastDiffText = diffText
        context.coordinator.lastDraftSignature = Self.draftSignature(for: draftComments)
        context.coordinator.lastReviewThreadSignature = Self.reviewThreadSignature(for: reviewThread)
        context.coordinator.lastFileName = fileName
        context.coordinator.lastIsReviewMode = isReviewMode
        context.coordinator.lastThemeType = theme.pierreThemeType
        context.coordinator.lastSelectedDraftCommentID = selectedDraftCommentID
        context.coordinator.lastReloadRevision = reloadRevision
        findModel?.webView = webView

        guard let baseURL = PierreLocalResources.baseURL else {
            webView.loadHTMLString(
                PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                baseURL: nil
            )
            return webView
        }

        let html = Self.buildHTML(
            diffText: diffText, fileName: fileName,
            fileContent: fileContent,
            theme: theme,
            reviewThread: reviewThread, isReviewMode: isReviewMode,
            draftComments: draftComments,
            selectedDraftCommentID: selectedDraftCommentID
        )
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let draftSignature = Self.draftSignature(for: draftComments)
        let reviewThreadSignature = Self.reviewThreadSignature(for: reviewThread)
        let diffChanged = context.coordinator.lastDiffText != diffText
        let draftChanged = context.coordinator.lastDraftSignature != draftSignature
        let reviewThreadChanged = context.coordinator.lastReviewThreadSignature != reviewThreadSignature
        let fileChanged = context.coordinator.lastFileName != fileName
        let reviewModeChanged = context.coordinator.lastIsReviewMode != isReviewMode
        let themeChanged = context.coordinator.lastThemeType != theme.pierreThemeType
        let selectedDraftChanged = context.coordinator.lastSelectedDraftCommentID != selectedDraftCommentID
        let reloadRevisionChanged = context.coordinator.lastReloadRevision != reloadRevision
        if diffChanged
            || draftChanged
            || reviewThreadChanged
            || fileChanged
            || reviewModeChanged
            || themeChanged
            || selectedDraftChanged
            || reloadRevisionChanged {
            context.coordinator.lastDiffText = diffText
            context.coordinator.lastDraftSignature = draftSignature
            context.coordinator.lastReviewThreadSignature = reviewThreadSignature
            context.coordinator.lastFileName = fileName
            context.coordinator.lastIsReviewMode = isReviewMode
            context.coordinator.lastThemeType = theme.pierreThemeType
            context.coordinator.lastSelectedDraftCommentID = selectedDraftCommentID
            context.coordinator.lastReloadRevision = reloadRevision
            guard let baseURL = PierreLocalResources.baseURL else {
                webView.loadHTMLString(
                    PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                    baseURL: nil
                )
                return
            }
            let html = Self.buildHTML(
                diffText: diffText, fileName: fileName,
                fileContent: fileContent,
                theme: theme,
                reviewThread: reviewThread, isReviewMode: isReviewMode,
                draftComments: draftComments,
                selectedDraftCommentID: selectedDraftCommentID
            )
            let preserveScroll = draftChanged
                && !diffChanged
                && !reviewThreadChanged
                && !fileChanged
                && !reviewModeChanged
                && !themeChanged
                && !reloadRevisionChanged
            context.coordinator.reload(
                webView: webView,
                html: html,
                baseURL: baseURL,
                preserveScroll: preserveScroll
            )
        }
    }

    private static func draftSignature(for draftComments: [TerminalLocalReviewComment]) -> String {
        draftComments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    $0.id.uuidString,
                    "\($0.startLine)",
                    "\($0.endLine)",
                    $0.side,
                    $0.text,
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
    }

    private static func reviewThreadSignature(
        for reviewThread: TerminalPullRequestReviewThread?
    ) -> String {
        guard let reviewThread else { return "nil" }
        return [
            reviewThread.id,
            reviewThread.isResolved ? "resolved" : "open",
            reviewThread.isOutdated ? "outdated" : "current",
            "\(reviewThread.comments.count)",
            reviewThread.comments.last?.id ?? "",
            "\(reviewThread.updatedAt.timeIntervalSince1970)",
        ].joined(separator: "|")
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onLinesSelected: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
        var onAddThreadToChat: (_ threadID: String?) -> Void
        var onReplyToThread: (_ threadID: String, _ body: String) -> Void
        var onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
        var onStartReview: (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void
        var onDeleteDraft: (_ commentID: String) -> Void
        var onUpdateDraft: (_ commentID: String, _ body: String) -> Void
        weak var webView: WKWebView?
        var lastDiffText: String?
        var lastDraftSignature: String = ""
        var lastReviewThreadSignature: String = "nil"
        var lastFileName: String = ""
        var lastIsReviewMode = false
        var lastThemeType = "dark"
        var lastSelectedDraftCommentID: String?
        var lastReloadRevision = 0
        private var pendingScrollRestore: Double?

        init(
            onLinesSelected: @escaping (_ startLine: Int, _ endLine: Int, _ side: String) -> Void,
            onAddThreadToChat: @escaping (_ threadID: String?) -> Void,
            onReplyToThread: @escaping (_ threadID: String, _ body: String) -> Void,
            onResolveThread: @escaping (_ threadID: String, _ resolve: Bool) -> Void,
            onStartReview: @escaping (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void,
            onDeleteDraft: @escaping (_ commentID: String) -> Void,
            onUpdateDraft: @escaping (_ commentID: String, _ body: String) -> Void
        ) {
            self.onLinesSelected = onLinesSelected
            self.onAddThreadToChat = onAddThreadToChat
            self.onReplyToThread = onReplyToThread
            self.onResolveThread = onResolveThread
            self.onStartReview = onStartReview
            self.onDeleteDraft = onDeleteDraft
            self.onUpdateDraft = onUpdateDraft
        }

        func reload(
            webView: WKWebView,
            html: String,
            baseURL: URL?,
            preserveScroll: Bool
        ) {
            guard preserveScroll else {
                pendingScrollRestore = nil
                webView.loadHTMLString(html, baseURL: baseURL)
                return
            }

            webView.evaluateJavaScript(
                "(function(){ const c = document.getElementById('container'); return c ? c.scrollTop : 0; })();"
            ) { [weak self, weak webView] result, _ in
                if let number = result as? NSNumber {
                    self?.pendingScrollRestore = number.doubleValue
                } else {
                    self?.pendingScrollRestore = nil
                }
                webView?.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let scrollTop = pendingScrollRestore else { return }
            pendingScrollRestore = nil
            let restoreJS = """
            (function() {
                const c = document.getElementById('container');
                if (c) c.scrollTop = \(scrollTop);
            })();
            """
            webView.evaluateJavaScript(restoreJS)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "addToChat" {
                let body = message.body as? [String: Any]
                let threadID = body?["threadID"] as? String
                DispatchQueue.main.async { [weak self] in
                    self?.onAddThreadToChat(threadID)
                }
                return
            }

            if message.name == "replyToThread",
               let body = message.body as? [String: Any],
               let threadID = body["threadID"] as? String,
               let replyBody = body["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onReplyToThread(threadID, replyBody)
                }
                return
            }

            if message.name == "resolveThread",
               let body = message.body as? [String: Any],
               let threadID = body["threadID"] as? String,
               let resolve = body["resolve"] as? Bool {
                DispatchQueue.main.async { [weak self] in
                    self?.onResolveThread(threadID, resolve)
                }
                return
            }

            if message.name == "startReview",
               let body = message.body as? [String: Any],
               let startLine = body["startLine"] as? Int,
               let endLine = body["endLine"] as? Int,
               let side = body["side"] as? String,
               let text = body["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onStartReview(startLine, endLine, side, text)
                }
                return
            }

            if message.name == "deleteDraft",
               let body = message.body as? [String: Any],
               let commentID = body["commentID"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onDeleteDraft(commentID)
                }
                return
            }

            if message.name == "updateDraft",
               let body = message.body as? [String: Any],
               let commentID = body["commentID"] as? String,
               let commentBody = body["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdateDraft(commentID, commentBody)
                }
                return
            }

            guard message.name == "lineSelection",
                  let body = message.body as? [String: Any],
                  let startLine = body["startLine"] as? Int,
                  let endLine = body["endLine"] as? Int,
                  let side = body["side"] as? String
            else { return }

            DispatchQueue.main.async { [weak self] in
                self?.onLinesSelected(startLine, endLine, side)
            }
        }
    }

    private static func buildHTML(
        diffText: String,
        fileName: String,
        fileContent: String?,
        theme: TerminalCodeTheme,
        reviewThread: TerminalPullRequestReviewThread?,
        isReviewMode: Bool,
        draftComments: [TerminalLocalReviewComment],
        selectedDraftCommentID: String?
    ) -> String {
        let escapedDiff = diffText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let escapedFileContent: String? = fileContent.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
        }

        let lang = Self.detectLanguage(from: fileName)

        // Build annotations JSON from review thread + draft comments
        var annotationItems: [String] = []

        if let thread = reviewThread, let line = thread.line ?? thread.originalLine {
            let side = thread.diffSide?.uppercased() == "LEFT" ? "deletions" : "additions"
            var commentItems: [String] = []
            for comment in thread.comments {
                let escapedAuthor = Self.escapeJS(comment.authorLogin)
                let escapedBody = Self.escapeJS(comment.body)
                let dateStr = Self.escapeJS(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                commentItems.append("{ author: '\(escapedAuthor)', body: '\(escapedBody)', date: '\(dateStr)' }")
            }
            let commentsArray = commentItems.joined(separator: ", ")
            let resolvedStr = thread.isResolved ? "true" : "false"
            let escapedThreadID = Self.escapeJS(thread.id)
            annotationItems.append("""
            {
                lineNumber: \(line),
                side: '\(side)',
                metadata: {
                    type: 'thread',
                    threadID: '\(escapedThreadID)',
                    comments: [\(commentsArray)],
                    isResolved: \(resolvedStr)
                }
            }
            """)
        }

        // Add draft comment annotations (only for current file)
        for draft in draftComments {
            let escapedBody = Self.escapeJS(draft.text)
            let escapedID = Self.escapeJS(draft.id.uuidString)
            let draftSide = draft.side == "old" ? "deletions" : "additions"
            annotationItems.append("""
            {
                lineNumber: \(draft.endLine),
                side: '\(draftSide)',
                metadata: {
                    type: 'draft',
                    commentID: '\(escapedID)',
                    body: '\(escapedBody)',
                    startLine: \(draft.startLine),
                    endLine: \(draft.endLine)
                }
            }
            """)
        }

        let annotationsJS = "const annotations = [\(annotationItems.joined(separator: ",\n"))];";
        let isReviewModeJS = isReviewMode ? "true" : "false"
        let selectedDraftCommentIDJS = selectedDraftCommentID.map { "'\(Self.escapeJS($0))'" } ?? "null"
        let themeType = theme.pierreThemeType
        let backgroundHex = theme.shellBackgroundHex
        let foregroundHex = theme.shellForegroundHex
        let mutedHex = theme.mutedHex
        let errorHex = theme.errorHex
        let moduleImportPath = PierreLocalResources.moduleImportPath

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: \(foregroundHex);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
                background: \(backgroundHex);
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: \(mutedHex);
                font-size: 13px;
                background: \(backgroundHex);
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: \(errorHex);
                font-size: 13px;
                white-space: pre-wrap;
                background: \(backgroundHex);
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading diff…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { FileDiff, parsePatchFiles, DIFFS_TAG_NAME } = await import('\(moduleImportPath)');

            const patchText = `\(escapedDiff)`;
            const parsedPatches = parsePatchFiles(patchText, '\(lang)');
            const isReviewMode = \(isReviewModeJS);
            const selectedDraftCommentID = \(selectedDraftCommentIDJS);

            // Populate full file lines for incremental expansion
            \(escapedFileContent != nil ? "const fullFileContent = `\(escapedFileContent!)`;" : "const fullFileContent = null;")
            if (fullFileContent != null) {
                const SPLIT_RE = /(?<=\\n)/;
                const fileLines = fullFileContent.split(SPLIT_RE);
                for (const patch of parsedPatches) {
                    for (const fd of patch.files) {
                        fd.newLines = fileLines;
                        fd.oldLines = fileLines;
                    }
                }
            }

            \(annotationsJS)

            var annotationElement = null;

            // Inline comment form state
            var activeInlineForm = null;

            function removeInlineForm() {
                if (activeInlineForm && activeInlineForm.parentNode) {
                    activeInlineForm.parentNode.removeChild(activeInlineForm);
                }
                activeInlineForm = null;
            }

            function findInShadow(root, finder) {
                const direct = finder(root);
                if (direct) return direct;
                for (const host of root.querySelectorAll('*')) {
                    if (!host.shadowRoot) continue;
                    const nested = findInShadow(host.shadowRoot, finder);
                    if (nested) return nested;
                }
                return null;
            }

            function findLineAnchor(lineNumber, side) {
                const targetSide = side === 'old' ? 'deletions' : 'additions';
                return findInShadow(document, (root) => {
                    const nodes = Array.from(root.querySelectorAll('[data-line="' + lineNumber + '"]'));
                    if (nodes.length === 0) return null;
                    return nodes.find((node) => {
                        const type = node.getAttribute('data-line-type');
                        if (targetSide === 'deletions') return type === 'deletion';
                        return type !== 'deletion';
                    }) || nodes[0];
                });
            }

            function showInlineCommentForm(startLine, endLine, side, parentEl, anchorEl) {
                removeInlineForm();

                const form = document.createElement('div');
                form.style.cssText = 'padding: 12px 16px; background: #1e293b; border-left: 3px solid #3b82f6; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                const rangeLabel = startLine === endLine
                    ? 'Line ' + startLine + ' (' + side + ')'
                    : 'Lines ' + startLine + '–' + endLine + ' (' + side + ')';

                const header = document.createElement('div');
                header.style.cssText = 'display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;';
                const label = document.createElement('span');
                label.style.cssText = 'font-size: 11px; color: #94a3b8; font-weight: 600;';
                label.textContent = 'Add review comment — ' + rangeLabel;
                header.appendChild(label);
                form.appendChild(header);

                const textarea = document.createElement('textarea');
                textarea.placeholder = 'Leave a comment…';
                textarea.style.cssText = 'width: 100%; min-height: 60px; max-height: 120px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                textarea.addEventListener('keydown', (e) => e.stopPropagation());
                form.appendChild(textarea);

                const btnRow = document.createElement('div');
                btnRow.style.cssText = 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;';

                const cancelBtn = document.createElement('button');
                cancelBtn.textContent = 'Cancel';
                cancelBtn.style.cssText = 'font-size: 12px; padding: 6px 14px; border-radius: 6px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-weight: 500; font-family: inherit;';
                cancelBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    removeInlineForm();
                });
                cancelBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                btnRow.appendChild(cancelBtn);

                const addBtn = document.createElement('button');
                addBtn.textContent = 'Start a review';
                addBtn.style.cssText = 'font-size: 12px; padding: 6px 14px; border-radius: 6px; border: none; background: #238636; color: white; cursor: pointer; font-weight: 600; font-family: inherit;';
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const text = textarea.value.trim();
                    if (!text) return;
                    window.webkit.messageHandlers.startReview.postMessage({
                        startLine: startLine,
                        endLine: endLine,
                        side: side,
                        body: text
                    });
                    removeInlineForm();
                });
                addBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                btnRow.appendChild(addBtn);

                form.appendChild(btnRow);

                if (anchorEl && anchorEl.parentElement) {
                    anchorEl.insertAdjacentElement('afterend', form);
                } else if (parentEl) {
                    parentEl.appendChild(form);
                }
                activeInlineForm = form;

                // Focus textarea
                setTimeout(() => textarea.focus(), 50);
                form.scrollIntoView({ block: 'nearest', behavior: 'smooth' });

                return form;
            }

            function renderAnnotation(annotation) {
                const m = annotation.metadata;

                // Draft comment annotation
                if (m.type === 'draft') {
                    const wrapper = document.createElement('div');
                    wrapper.id = 'draft-annotation-' + m.commentID;
                    if (selectedDraftCommentID && m.commentID === selectedDraftCommentID) {
                        annotationElement = wrapper;
                    }
                    wrapper.style.cssText = 'padding: 10px 16px; background: #1a2332; border-left: 3px solid #238636; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                    const header = document.createElement('div');
                    header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 6px;';

                    const badge = document.createElement('span');
                    badge.style.cssText = 'font-size: 10px; font-weight: 700; color: #238636; background: rgba(35,134,54,0.15); padding: 2px 6px; border-radius: 4px; text-transform: uppercase; letter-spacing: 0.5px;';
                    badge.textContent = 'Pending';
                    header.appendChild(badge);

                    const range = document.createElement('span');
                    range.style.cssText = 'font-size: 11px; color: #64748b;';
                    range.textContent = m.startLine === m.endLine
                        ? 'L' + m.startLine
                        : 'L' + m.startLine + '–L' + m.endLine;
                    header.appendChild(range);

                    const spacer = document.createElement('span');
                    spacer.style.cssText = 'flex: 1;';
                    header.appendChild(spacer);

                    const editBtn = document.createElement('button');
                    editBtn.textContent = 'Edit';
                    editBtn.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 4px; border: 1px solid #1d4ed8; background: transparent; color: #60a5fa; cursor: pointer; font-family: inherit;';

                    const deleteBtn = document.createElement('button');
                    deleteBtn.textContent = 'Delete';
                    deleteBtn.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 4px; border: 1px solid #6b2126; background: transparent; color: #f85149; cursor: pointer; font-family: inherit;';
                    deleteBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        window.webkit.messageHandlers.deleteDraft.postMessage({ commentID: m.commentID });
                    });
                    deleteBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    editBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    header.appendChild(editBtn);
                    header.appendChild(deleteBtn);

                    wrapper.appendChild(header);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = m.body;
                    wrapper.appendChild(body);

                    const editArea = document.createElement('div');
                    editArea.style.cssText = 'display: none; margin-top: 8px;';

                    const textarea = document.createElement('textarea');
                    textarea.value = m.body;
                    textarea.style.cssText = 'width: 100%; min-height: 60px; max-height: 120px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                    textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                    textarea.addEventListener('keydown', (e) => e.stopPropagation());
                    editArea.appendChild(textarea);

                    const actionRow = document.createElement('div');
                    actionRow.style.cssText = 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;';

                    const cancelEditBtn = document.createElement('button');
                    cancelEditBtn.textContent = 'Cancel';
                    cancelEditBtn.style.cssText = 'font-size: 11px; padding: 4px 10px; border-radius: 4px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-family: inherit;';
                    cancelEditBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        textarea.value = m.body;
                        editArea.style.display = 'none';
                        body.style.display = '';
                        editBtn.textContent = 'Edit';
                    });
                    cancelEditBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    actionRow.appendChild(cancelEditBtn);

                    const saveEditBtn = document.createElement('button');
                    saveEditBtn.textContent = 'Save';
                    saveEditBtn.style.cssText = 'font-size: 11px; padding: 4px 10px; border-radius: 4px; border: none; background: #238636; color: white; cursor: pointer; font-family: inherit; font-weight: 600;';
                    saveEditBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        const updated = textarea.value.trim();
                        if (!updated) return;
                        m.body = updated;
                        body.textContent = updated;
                        editArea.style.display = 'none';
                        body.style.display = '';
                        editBtn.textContent = 'Edit';
                        window.webkit.messageHandlers.updateDraft.postMessage({
                            commentID: m.commentID,
                            body: updated
                        });
                    });
                    saveEditBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    actionRow.appendChild(saveEditBtn);

                    editArea.appendChild(actionRow);
                    wrapper.appendChild(editArea);

                    editBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        const editing = editArea.style.display !== 'none';
                        if (editing) {
                            textarea.value = m.body;
                            editArea.style.display = 'none';
                            body.style.display = '';
                            editBtn.textContent = 'Edit';
                        } else {
                            textarea.value = m.body;
                            editArea.style.display = '';
                            body.style.display = 'none';
                            editBtn.textContent = 'Close';
                            setTimeout(() => textarea.focus(), 30);
                        }
                    });

                    return wrapper;
                }

                // Existing review thread annotation
                const threadID = m.threadID;

                const wrapper = document.createElement('div');
                wrapper.id = 'review-thread-annotation-' + threadID;
                annotationElement = wrapper;
                wrapper.style.cssText = 'padding: 12px 16px; background: #1e293b; border-left: 3px solid #3b82f6; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                // Header row
                const header = document.createElement('div');
                header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 8px;';

                const threadLabel = document.createElement('span');
                threadLabel.style.cssText = 'font-size: 11px; color: #94a3b8; font-weight: 600; flex-shrink: 0;';
                threadLabel.textContent = m.isResolved ? 'Resolved Thread' : 'Review Thread';
                header.appendChild(threadLabel);

                const spacer = document.createElement('span');
                spacer.style.cssText = 'flex: 1;';
                header.appendChild(spacer);

                const btnStyle = 'font-size: 11px; padding: 3px 10px; border-radius: 4px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-family: inherit; flex-shrink: 0;';

                // Resolve / Unresolve button
                const resolveBtn = document.createElement('button');
                resolveBtn.textContent = m.isResolved ? 'Unresolve' : 'Resolve';
                resolveBtn.style.cssText = btnStyle;
                if (m.isResolved) {
                    resolveBtn.style.borderColor = '#065f46';
                    resolveBtn.style.color = '#6ee7b7';
                }
                resolveBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.resolveThread.postMessage({
                        threadID: threadID,
                        resolve: !m.isResolved
                    });
                });
                resolveBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(resolveBtn);

                // Add to chat button
                const addBtn = document.createElement('button');
                addBtn.textContent = 'Add to chat';
                addBtn.style.cssText = btnStyle;
                var addToChatTimer = null;
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.addToChat.postMessage({ threadID: threadID });
                    addBtn.disabled = true;
                    addBtn.textContent = 'Added';
                    addBtn.style.borderColor = '#065f46';
                    addBtn.style.color = '#6ee7b7';
                    if (addToChatTimer) clearTimeout(addToChatTimer);
                    addToChatTimer = setTimeout(() => {
                        addBtn.disabled = false;
                        addBtn.textContent = 'Add to chat';
                        addBtn.style.borderColor = '#475569';
                        addBtn.style.color = '#e2e8f0';
                    }, 1200);
                });
                addBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(addBtn);

                wrapper.appendChild(header);

                // Comment bubbles
                for (const c of m.comments) {
                    const commentDiv = document.createElement('div');
                    commentDiv.style.cssText = 'padding: 8px 10px; background: #0f172a; border-radius: 6px; margin-bottom: 6px;';

                    const commentHeader = document.createElement('div');
                    commentHeader.style.cssText = 'display: flex; justify-content: space-between; margin-bottom: 4px;';

                    const author = document.createElement('span');
                    author.style.cssText = 'font-size: 12px; font-weight: 600; color: #e2e8f0;';
                    author.textContent = c.author;
                    commentHeader.appendChild(author);

                    const date = document.createElement('span');
                    date.style.cssText = 'font-size: 11px; color: #64748b;';
                    date.textContent = c.date;
                    commentHeader.appendChild(date);

                    commentDiv.appendChild(commentHeader);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = c.body;
                    commentDiv.appendChild(body);

                    wrapper.appendChild(commentDiv);
                }

                // Reply box
                const replyArea = document.createElement('div');
                replyArea.style.cssText = 'margin-top: 8px; display: flex; flex-direction: column; gap: 8px;';

                const textarea = document.createElement('textarea');
                textarea.placeholder = 'Reply to this thread…';
                textarea.style.cssText = 'width: 100%; min-height: 36px; max-height: 100px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                textarea.addEventListener('keydown', (e) => e.stopPropagation());
                replyArea.appendChild(textarea);

                const sendBtn = document.createElement('button');
                sendBtn.textContent = 'Reply';
                sendBtn.style.cssText = 'align-self: flex-end; font-size: 12px; padding: 8px 14px; border-radius: 6px; border: none; background: #3b82f6; color: white; cursor: pointer; font-weight: 600; font-family: inherit;';
                sendBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const text = textarea.value.trim();
                    if (!text) return;
                    window.webkit.messageHandlers.replyToThread.postMessage({
                        threadID: threadID,
                        body: text
                    });
                    textarea.value = '';
                    textarea.disabled = true;
                    sendBtn.disabled = true;
                    sendBtn.textContent = 'Sent';
                    sendBtn.style.background = '#065f46';
                });
                sendBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                replyArea.appendChild(sendBtn);

                wrapper.appendChild(replyArea);

                return wrapper;
            }

            // Handle line selection — in review mode, show inline form; otherwise post to Swift
            function handleLineSelection(startLine, endLine, side, containerEl) {
                if (isReviewMode) {
                    const anchor = findLineAnchor(endLine, side) || findLineAnchor(startLine, side);
                    showInlineCommentForm(startLine, endLine, side, containerEl, anchor);
                } else {
                    window.webkit.messageHandlers.lineSelection.postMessage({
                        startLine: startLine,
                        endLine: endLine,
                        side: side
                    });
                }
            }

            document.getElementById('loading').classList.add('hidden');

            const container = document.getElementById('container');

            for (const patch of parsedPatches) {
                for (const fileDiff of patch.files) {

                    const instance = new FileDiff({
                        theme: { dark: 'dark-plus', light: 'light-plus' },
                        themeType: '\(themeType)',
                        diffStyle: 'split',
                        overflow: 'scroll',
                        enableLineSelection: true,
                        disableFileHeader: true,
                        lineHoverHighlight: 'both',
                        enableGutterUtility: true,
                        hunkSeparators: 'line-info',
                        expansionLineCount: 20,
                        renderAnnotation: renderAnnotation,
                        onGutterUtilityClick(range) {
                            if (range != null && range.start != null) {
                                const side = range.side === 'deletions' ? 'old' : 'new';
                                handleLineSelection(
                                    Math.min(range.start, range.end),
                                    Math.max(range.start, range.end),
                                    side,
                                    container
                                );
                            }
                        },
                        onLineSelectionEnd(range) {
                            if (range != null && range.start != null) {
                                const side = range.side === 'deletions' ? 'old' : 'new';
                                handleLineSelection(
                                    Math.min(range.start, range.end),
                                    Math.max(range.start, range.end),
                                    side,
                                    container
                                );
                            }
                        },
                        onLineNumberClick(props) {
                            const side = props.annotationSide === 'deletions' ? 'old' : 'new';
                            handleLineSelection(props.lineNumber, props.lineNumber, side, container);
                        },
                    });

                    const fileContainer = document.createElement(DIFFS_TAG_NAME);
                    container.appendChild(fileContainer);
                    instance.render({
                        fileDiff,
                        fileContainer,
                        lineAnnotations: annotations.length > 0 ? annotations : undefined
                    });
                }
            }

            // Scroll to the annotation as soon as it appears in the DOM
            if (annotations.length > 0) {
                function scrollToAnnotation() {
                    const containerEl = document.getElementById('container');
                    const target = annotationElement || findInShadow(document, (root) => {
                        return root.querySelector('[id^="review-thread-annotation-"]')
                            || root.querySelector('[id^="draft-annotation-"]');
                    });
                    if (target && containerEl) {
                        let offsetTop = 0;
                        let el = target;
                        while (el) {
                            offsetTop += el.offsetTop || 0;
                            el = el.offsetParent;
                        }
                        containerEl.scrollTop = Math.max(0, offsetTop - containerEl.clientHeight / 3);
                        return true;
                    }
                    return false;
                }

                // Try immediately first
                if (!scrollToAnnotation()) {
                    // Watch for the annotation to appear via MutationObserver
                    const obs = new MutationObserver(() => {
                        if (scrollToAnnotation()) obs.disconnect();
                    });
                    obs.observe(document.getElementById('container'), { childList: true, subtree: true });
                }
            }
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load diff renderer: ' + err.message;
            console.error('Pierre diffs error:', err);
        }
        </script>
        </body>
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
        case "sh", "bash", "zsh": return "bash"
        case "yaml", "yml": return "yaml"
        case "json": return "json"
        case "xml", "html", "xib", "plist", "sdef": return "xml"
        case "css": return "css"
        case "md": return "markdown"
        case "sql": return "sql"
        default: return ext.isEmpty ? "text" : ext
        }
    }

    static func escapeJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Inline Comment Box

private struct InlineCommentBox: View {
    @Binding var text: String
    let selectedRange: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add review comment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedRange.isEmpty {
                    Text(selectedRange)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Add to review") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Review Comments Uber Box (Editable)

struct ReviewCommentsUberBox: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var errorMessage: String?
    @State private var editableText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review Comments")
                    .font(.headline)

                Spacer()

                Text("\(tab.localReviewComments.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }

            TextEditor(text: $editableText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    tab.clearReviewComments()
                    editableText = ""
                    errorMessage = nil
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button {
                    let result = sendToChat()
                    if let error = result {
                        errorMessage = error
                    } else {
                        errorMessage = nil
                    }
                } label: {
                    Label("Fix in chat", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear { rebuildText() }
        .onReceive(tab.$localReviewComments) { _ in rebuildText() }
    }

    private func rebuildText() {
        var text = ""
        for comment in tab.localReviewComments {
            let fileName = URL(fileURLWithPath: comment.filePath).lastPathComponent
            if comment.startLine == comment.endLine {
                text += "[\(fileName):L\(comment.startLine) (\(comment.side))]\n"
            } else {
                text += "[\(fileName):L\(comment.startLine)-L\(comment.endLine) (\(comment.side))]\n"
            }
            text += "\(comment.text)\n\n"
        }
        editableText = text
    }

    private func sendToChat() -> String? {
        guard let surface = controller.focusedSurface, let surfaceModel = surface.surfaceModel else {
            return "No active terminal session. Open a terminal first."
        }

        let trimmed = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No review comments to send." }

        let message = "Please fix the following review comments:\n\n\(trimmed)\n"
        surfaceModel.sendText(message)
        return nil
    }
}

// MARK: - PR Thread Comments Uber Box (Comments tab)

struct PRThreadCommentsUberBox: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var errorMessage: String?
    @State private var editableText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Comments for Chat")
                    .font(.headline)

                Spacer()

                Text("\(tab.prThreadReviewComments.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }

            TextEditor(text: $editableText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    tab.clearPRThreadComments()
                    editableText = ""
                    errorMessage = nil
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button {
                    let result = sendToChat()
                    if let error = result {
                        errorMessage = error
                    } else {
                        errorMessage = nil
                    }
                } label: {
                    Label("Fix in chat", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear { rebuildText() }
        .onReceive(tab.$prThreadReviewComments) { _ in rebuildText() }
    }

    private func rebuildText() {
        var text = ""
        for comment in tab.prThreadReviewComments {
            let fileName = URL(fileURLWithPath: comment.filePath).lastPathComponent
            if comment.startLine == comment.endLine {
                text += "[\(fileName):L\(comment.startLine) (\(comment.side))]\n"
            } else {
                text += "[\(fileName):L\(comment.startLine)-L\(comment.endLine) (\(comment.side))]\n"
            }
            text += "\(comment.text)\n\n"
        }
        editableText = text
    }

    private func sendToChat() -> String? {
        let result = controller.sendPRThreadCommentsToChat(editableText)
        if result == nil {
            editableText = ""
        }
        return result
    }
}

// MARK: - File Viewer View (full file, not diff)

struct TerminalFileViewerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var editorModel = MonacoEditorModel()
    @State private var markdownPreviewWidth: CGFloat = 0

    private let markdownPreviewMinWidth: CGFloat = 280
    private let markdownEditorMinWidth: CGFloat = 320
    private let fileViewerDividerWidth: CGFloat = 5

    private var codeTheme: TerminalCodeTheme {
        .forColorScheme(colorScheme)
    }

    private var viewerDocumentURL: URL? {
        guard let resolvedPath = tab.viewerResolvedFilePath else { return nil }
        return URL(fileURLWithPath: resolvedPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            fileViewerHeader
            Divider()
            fileViewerContent
        }
        .overlay(alignment: .bottom) {
            if tab.isPlanReviewActive && tab.showCommentBox {
                InlineCommentBox(
                    text: Binding(
                        get: { tab.pendingCommentText },
                        set: { tab.pendingCommentText = $0 }
                    ),
                    selectedRange: fileViewerCommentRangeLabel,
                    onAdd: { addPlanReviewComment() },
                    onCancel: { cancelPlanReviewComment() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.showCommentBox)
        .background {
            Button("") { editorModel.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { editorModel.copySelectionToPasteboard() }
                .keyboardShortcut("c", modifiers: .command)
                .hidden()
            Button("") { controller.saveViewerFile() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
            Button("") { editorModel.undo() }
                .keyboardShortcut("u", modifiers: .command)
                .hidden()
        }
        .onExitCommand {
            controller.closeFileViewer()
        }
    }

    private var fileViewerHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeFileViewer()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            if let path = tab.viewerFilePath {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if tab.isViewerDirty {
                Text("Unsaved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let error = tab.viewerSaveError ?? tab.viewerLoadError,
               !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .trailing)
            }

            if tab.isPlanReviewActive {
                if !tab.planReviewComments.isEmpty {
                    Text("\(tab.planReviewComments.count) comment(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Request Changes") {
                    controller.requestPlanReviewChanges()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!tab.canRequestPlanReviewChanges)

                Button("Approve") {
                    controller.approvePlanReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tab.canApprovePlanReview)
            }

            if tab.isViewerSaving {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileViewerContent: some View {
        Group {
            if tab.isViewerLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading file…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content = tab.viewerFileContent,
                      let path = tab.viewerFilePath {
                if tab.viewerLayoutMode == .markdownSplitPreview {
                    GeometryReader { proxy in
                        let splitLayout = markdownSplitLayout(in: proxy.size.width)

                        HStack(spacing: 0) {
                            editorPane(content: content, path: path)
                                .frame(width: splitLayout.editorWidth)
                                .frame(maxHeight: .infinity)

                            FileViewerResizableDivider(
                                dimension: $markdownPreviewWidth,
                                minValue: markdownPreviewMinWidth,
                                maxValue: splitLayout.previewMaxWidth,
                                inverted: true
                            )

                            previewPane(content: content, width: splitLayout.previewWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editorPane(content: content, path: path)
                }
            } else if let error = tab.viewerLoadError, !error.isEmpty {
                VStack(spacing: 8) {
                    Text("File could not be read.")
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            } else {
                VStack {
                    Text("File content unavailable.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
    }

    private func editorPane(content: String, path: String) -> some View {
        MonacoEditorWebView(
            filePath: path,
            content: content,
            theme: codeTheme,
            editorModel: editorModel,
            onContentChanged: { content in
                controller.updateViewerDraftContent(content)
            },
            onSaveRequested: { content in
                controller.saveViewerFile(contentOverride: content)
            },
            onLinesSelected: tab.isPlanReviewActive ? { startLine, endLine in
                guard let startLine, let endLine else {
                    return
                }
                tab.pendingSelectionStart = startLine
                tab.pendingSelectionEnd = endLine
                tab.pendingSelectionSide = "new"
                tab.showCommentBox = true
                controller.objectWillChange.send()
            } : nil
        )
    }

    private func previewPane(content: String, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            MonacoMarkdownPreviewWebView(
                content: content,
                theme: codeTheme,
                documentURL: viewerDocumentURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func markdownSplitLayout(in totalWidth: CGFloat) -> (editorWidth: CGFloat, previewWidth: CGFloat, previewMaxWidth: CGFloat) {
        let availableWidth = max(totalWidth, markdownEditorMinWidth + markdownPreviewMinWidth + fileViewerDividerWidth)
        let previewMaxWidth = max(markdownPreviewMinWidth, availableWidth - markdownEditorMinWidth - fileViewerDividerWidth)
        let defaultPreviewWidth = max(markdownPreviewMinWidth, (availableWidth - fileViewerDividerWidth) / 2)
        let requestedPreviewWidth = markdownPreviewWidth > 0 ? markdownPreviewWidth : defaultPreviewWidth
        let previewWidth = min(max(requestedPreviewWidth, markdownPreviewMinWidth), previewMaxWidth)
        let editorWidth = max(markdownEditorMinWidth, availableWidth - previewWidth - fileViewerDividerWidth)
        return (editorWidth, previewWidth, previewMaxWidth)
    }

    private var fileViewerCommentRangeLabel: String {
        guard let start = tab.pendingSelectionStart else { return "" }
        let end = tab.pendingSelectionEnd ?? start
        if start == end {
            return "Line \(start)"
        }
        return "Lines \(start)–\(end)"
    }

    private func addPlanReviewComment() {
        let text = tab.pendingCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let start = tab.pendingSelectionStart else { return }

        tab.addPlanReviewComment(
            TerminalPlanReviewComment(
                startLine: start,
                endLine: tab.pendingSelectionEnd ?? start,
                text: text
            )
        )
        cancelPlanReviewComment()
    }

    private func cancelPlanReviewComment() {
        tab.cancelPlanReviewSelection()
        controller.objectWillChange.send()
    }
}

private struct FileViewerResizableDivider: View {
    @Binding var dimension: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat
    var inverted: Bool = false

    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = dimension
                        }
                        let delta = inverted ? -value.translation.width : value.translation.width
                        let newWidth = dragStartWidth + delta
                        dimension = min(max(newWidth, minValue), maxValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - WKWebView wrapper for full file viewing with pierre

// MARK: - Combined (multi-file) Diff View

struct TerminalCombinedDiffView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var findModel = WebViewFindModel()

    private var codeTheme: TerminalCodeTheme {
        .forColorScheme(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            combinedDiffHeader
            Divider()
            combinedDiffContent
        }
        .overlay(alignment: .topTrailing) {
            WebViewFindBar(model: findModel)
        }
        .background {
            Button("") { handleFindShortcut() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { findModel.copySelectionToPasteboard() }
                .keyboardShortcut("c", modifiers: .command)
                .hidden()
        }
        .onExitCommand {
            controller.closeCombinedDiff()
        }
    }

    private var combinedDiffHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeCombinedDiff()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            Text(tab.combinedDiffTitle ?? "All Changes")
                .font(.body.weight(.semibold))
                .lineLimit(1)

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleFindShortcut() {
        findModel.show(prefillSelection: true)
    }

    private var combinedDiffContent: some View {
        Group {
            if tab.isCombinedDiffLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading diff…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffText = tab.combinedDiffRawText, !diffText.isEmpty {
                PierreCombinedDiffWebView(
                    diffText: diffText,
                    theme: codeTheme,
                    reviewThreads: tab.reviewThreads,
                    draftComments: tab.localReviewComments,
                    focusedThreadID: tab.activeReviewThread?.id,
                    fileContentsByPath: tab.combinedDiffFileContents,
                    reloadRevision: tab.diffReloadRevision,
                    findModel: findModel,
                    onAddThreadToChat: { threadID in
                        tab.activeReviewThread = tab.reviewThreads.first(where: { $0.id == threadID })
                        _ = controller.addThreadToChat(threadID: threadID)
                    },
                    onReplyToThread: { threadID, body in
                        if let thread = tab.reviewThreads.first(where: { $0.id == threadID }) {
                            tab.activeReviewThread = thread
                        }
                        controller.replyToThread(threadID: threadID, body: body)
                    },
                    onResolveThread: { threadID, resolve in
                        if let thread = tab.reviewThreads.first(where: { $0.id == threadID }) {
                            tab.activeReviewThread = thread
                        }
                        controller.resolveThread(threadID: threadID, resolve: resolve)
                    },
                    onDeleteDraft: { commentID in
                        if let uuid = UUID(uuidString: commentID) {
                            tab.removeReviewComment(id: uuid)
                            controller.objectWillChange.send()
                        }
                    },
                    onUpdateDraft: { commentID, body in
                        if let uuid = UUID(uuidString: commentID) {
                            tab.updateReviewComment(id: uuid, text: body)
                            controller.objectWillChange.send()
                        }
                    },
                    onOpenFile: { path in
                        controller.openFileViewer(relativePath: path)
                    }
                )
            } else {
                VStack {
                    Text("No changes to display.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
    }
}

// MARK: - WKWebView for combined multi-file diff

struct PierreCombinedDiffWebView: NSViewRepresentable {
    let diffText: String
    let theme: TerminalCodeTheme
    let reviewThreads: [TerminalPullRequestReviewThread]
    let draftComments: [TerminalLocalReviewComment]
    let focusedThreadID: String?
    let fileContentsByPath: [String: String]
    let reloadRevision: Int
    var findModel: WebViewFindModel? = nil
    let onAddThreadToChat: (_ threadID: String) -> Void
    let onReplyToThread: (_ threadID: String, _ body: String) -> Void
    let onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
    let onDeleteDraft: (_ commentID: String) -> Void
    let onUpdateDraft: (_ commentID: String, _ body: String) -> Void
    let onOpenFile: (_ path: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onAddThreadToChat: onAddThreadToChat,
            onReplyToThread: onReplyToThread,
            onResolveThread: onResolveThread,
            onDeleteDraft: onDeleteDraft,
            onUpdateDraft: onUpdateDraft,
            onOpenFile: onOpenFile
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "addToChat")
        contentController.add(context.coordinator, name: "replyToThread")
        contentController.add(context.coordinator, name: "resolveThread")
        contentController.add(context.coordinator, name: "deleteDraft")
        contentController.add(context.coordinator, name: "updateDraft")
        contentController.add(context.coordinator, name: "openFile")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastDiffText = diffText
        context.coordinator.lastThemeType = theme.pierreThemeType
        context.coordinator.lastReviewThreadsSignature = Self.reviewThreadsSignature(for: reviewThreads)
        context.coordinator.lastDraftCommentsSignature = Self.draftCommentsSignature(for: draftComments)
        context.coordinator.lastFocusedThreadID = focusedThreadID
        context.coordinator.lastFileContentsSignature = Self.fileContentsSignature(for: fileContentsByPath)
        context.coordinator.lastReloadRevision = reloadRevision
        findModel?.webView = webView

        guard let baseURL = PierreLocalResources.baseURL else {
            webView.loadHTMLString(
                PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                baseURL: nil
            )
            return webView
        }

        let html = Self.buildCombinedHTML(
            diffText: diffText,
            theme: theme,
            reviewThreads: reviewThreads,
            draftComments: draftComments,
            focusedThreadID: focusedThreadID,
            fileContentsByPath: fileContentsByPath
        )
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let reviewThreadsSignature = Self.reviewThreadsSignature(for: reviewThreads)
        let draftCommentsSignature = Self.draftCommentsSignature(for: draftComments)
        let fileContentsSignature = Self.fileContentsSignature(for: fileContentsByPath)
        if context.coordinator.lastDiffText != diffText
            || context.coordinator.lastThemeType != theme.pierreThemeType
            || context.coordinator.lastReviewThreadsSignature != reviewThreadsSignature
            || context.coordinator.lastDraftCommentsSignature != draftCommentsSignature
            || context.coordinator.lastFocusedThreadID != focusedThreadID
            || context.coordinator.lastFileContentsSignature != fileContentsSignature
            || context.coordinator.lastReloadRevision != reloadRevision {
            context.coordinator.lastDiffText = diffText
            context.coordinator.lastThemeType = theme.pierreThemeType
            context.coordinator.lastReviewThreadsSignature = reviewThreadsSignature
            context.coordinator.lastDraftCommentsSignature = draftCommentsSignature
            context.coordinator.lastFocusedThreadID = focusedThreadID
            context.coordinator.lastFileContentsSignature = fileContentsSignature
            context.coordinator.lastReloadRevision = reloadRevision
            guard let baseURL = PierreLocalResources.baseURL else {
                webView.loadHTMLString(
                    PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                    baseURL: nil
                )
                return
            }
            let html = Self.buildCombinedHTML(
                diffText: diffText,
                theme: theme,
                reviewThreads: reviewThreads,
                draftComments: draftComments,
                focusedThreadID: focusedThreadID,
                fileContentsByPath: fileContentsByPath
            )
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onAddThreadToChat: (_ threadID: String) -> Void
        let onReplyToThread: (_ threadID: String, _ body: String) -> Void
        let onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
        let onDeleteDraft: (_ commentID: String) -> Void
        let onUpdateDraft: (_ commentID: String, _ body: String) -> Void
        let onOpenFile: (_ path: String) -> Void
        var lastDiffText: String?
        var lastThemeType = "dark"
        var lastReviewThreadsSignature = ""
        var lastDraftCommentsSignature = ""
        var lastFocusedThreadID: String?
        var lastFileContentsSignature = ""
        var lastReloadRevision = 0

        init(
            onAddThreadToChat: @escaping (_ threadID: String) -> Void,
            onReplyToThread: @escaping (_ threadID: String, _ body: String) -> Void,
            onResolveThread: @escaping (_ threadID: String, _ resolve: Bool) -> Void,
            onDeleteDraft: @escaping (_ commentID: String) -> Void,
            onUpdateDraft: @escaping (_ commentID: String, _ body: String) -> Void,
            onOpenFile: @escaping (_ path: String) -> Void
        ) {
            self.onAddThreadToChat = onAddThreadToChat
            self.onReplyToThread = onReplyToThread
            self.onResolveThread = onResolveThread
            self.onDeleteDraft = onDeleteDraft
            self.onUpdateDraft = onUpdateDraft
            self.onOpenFile = onOpenFile
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "addToChat",
               let payload = message.body as? [String: Any],
               let threadID = payload["threadID"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onAddThreadToChat(threadID)
                }
                return
            }

            if message.name == "replyToThread",
               let payload = message.body as? [String: Any],
               let threadID = payload["threadID"] as? String,
               let body = payload["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onReplyToThread(threadID, body)
                }
                return
            }

            if message.name == "resolveThread",
               let payload = message.body as? [String: Any],
               let threadID = payload["threadID"] as? String,
               let resolve = payload["resolve"] as? Bool {
                DispatchQueue.main.async { [weak self] in
                    self?.onResolveThread(threadID, resolve)
                }
                return
            }

            if message.name == "deleteDraft",
               let payload = message.body as? [String: Any],
               let commentID = payload["commentID"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onDeleteDraft(commentID)
                }
                return
            }

            if message.name == "updateDraft",
               let payload = message.body as? [String: Any],
               let commentID = payload["commentID"] as? String,
               let body = payload["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdateDraft(commentID, body)
                }
                return
            }

            if message.name == "openFile",
               let payload = message.body as? [String: Any],
               let path = payload["path"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onOpenFile(path)
                }
            }
        }
    }

    private static func draftCommentsSignature(for comments: [TerminalLocalReviewComment]) -> String {
        comments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString)|\($0.filePath)|\($0.startLine)|\($0.endLine)|\($0.side)|\($0.text.count)" }
            .joined(separator: "\n")
    }

    private static func reviewThreadsSignature(for threads: [TerminalPullRequestReviewThread]) -> String {
        threads
            .sorted { $0.id < $1.id }
            .map {
                [
                    $0.id,
                    $0.isResolved ? "resolved" : "open",
                    $0.isOutdated ? "outdated" : "current",
                    "\($0.comments.count)",
                    $0.comments.last?.id ?? "",
                    "\($0.updatedAt.timeIntervalSince1970)",
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
    }

    private static func fileContentsSignature(for fileContentsByPath: [String: String]) -> String {
        fileContentsByPath.keys
            .sorted()
            .map { path in
                "\(path):\(fileContentsByPath[path]?.count ?? 0)"
            }
            .joined(separator: "|")
    }

    private static func jsonLiteral(_ object: Any) -> String {
        let fallback = object is [Any] ? "[]" : "{}"
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func annotationsByPathJSON(
        for reviewThreads: [TerminalPullRequestReviewThread],
        draftComments: [TerminalLocalReviewComment]
    ) -> String {
        var annotationsByPath: [String: [[String: Any]]] = [:]

        // Locally-imported / draft review comments (the ones "sent to GingerTTY").
        for draft in draftComments {
            let annotation: [String: Any] = [
                "lineNumber": draft.endLine,
                "side": draft.side == "old" ? "deletions" : "additions",
                "metadata": [
                    "type": "draft",
                    "commentID": draft.id.uuidString,
                    "body": draft.text,
                    "startLine": draft.startLine,
                    "endLine": draft.endLine,
                ],
            ]
            annotationsByPath[draft.filePath, default: []].append(annotation)
        }

        for thread in reviewThreads {
            guard let path = thread.path,
                  let line = thread.line ?? thread.originalLine else {
                continue
            }

            let side = thread.diffSide?.uppercased() == "LEFT" ? "deletions" : "additions"
            let comments = thread.comments.map { comment in
                [
                    "author": comment.authorLogin,
                    "body": comment.body,
                    "date": comment.createdAt.formatted(date: .abbreviated, time: .shortened),
                ]
            }
            let annotation: [String: Any] = [
                "lineNumber": line,
                "side": side,
                "metadata": [
                    "type": "thread",
                    "threadID": thread.id,
                    "comments": comments,
                    "isResolved": thread.isResolved,
                    "isOutdated": thread.isOutdated,
                ],
            ]
            annotationsByPath[path, default: []].append(annotation)
        }

        return jsonLiteral(annotationsByPath)
    }

    private static func buildCombinedHTML(
        diffText: String,
        theme: TerminalCodeTheme,
        reviewThreads: [TerminalPullRequestReviewThread],
        draftComments: [TerminalLocalReviewComment],
        focusedThreadID: String?,
        fileContentsByPath: [String: String]
    ) -> String {
        let escapedDiff = diffText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let annotationsByPathJSON = annotationsByPathJSON(for: reviewThreads, draftComments: draftComments)
        let fileContentsJSON = jsonLiteral(fileContentsByPath)
        let focusedThreadIDJS = focusedThreadID.map { "'\(PierreDiffWebView.escapeJS($0))'" } ?? "null"
        let themeType = theme.pierreThemeType
        let backgroundHex = theme.shellBackgroundHex
        let foregroundHex = theme.shellForegroundHex
        let mutedHex = theme.mutedHex
        let errorHex = theme.errorHex
        let moduleImportPath = PierreLocalResources.moduleImportPath

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: \(foregroundHex);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
                background: \(backgroundHex);
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: \(mutedHex);
                font-size: 13px;
                background: \(backgroundHex);
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: \(errorHex);
                font-size: 13px;
                white-space: pre-wrap;
                background: \(backgroundHex);
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading diff…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { FileDiff, parsePatchFiles, DIFFS_TAG_NAME } = await import('\(moduleImportPath)');

            const patchText = `\(escapedDiff)`;
            const parsedPatches = parsePatchFiles(patchText);
            const annotationsByPath = \(annotationsByPathJSON);
            const fileContentsByPath = \(fileContentsJSON);
            const focusedThreadID = \(focusedThreadIDJS);

            function normalizePath(path) {
                if (!path) return null;
                let normalized = String(path);
                if (normalized.startsWith('a/') || normalized.startsWith('b/')) {
                    normalized = normalized.substring(2);
                }
                return normalized;
            }

            function findInShadow(root, finder) {
                const direct = finder(root);
                if (direct) return direct;
                for (const host of root.querySelectorAll('*')) {
                    if (!host.shadowRoot) continue;
                    const nested = findInShadow(host.shadowRoot, finder);
                    if (nested) return nested;
                }
                return null;
            }

            function renderAnnotation(annotation) {
                const m = annotation.metadata;

                // Locally-imported / draft comment annotation.
                if (m.type === 'draft') {
                    const wrapper = document.createElement('div');
                    wrapper.id = 'draft-annotation-' + m.commentID;
                    wrapper.style.cssText = 'padding: 10px 16px; background: #1a2332; border-left: 3px solid #238636; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                    const header = document.createElement('div');
                    header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 6px;';

                    const badge = document.createElement('span');
                    badge.style.cssText = 'font-size: 10px; font-weight: 700; color: #238636; background: rgba(35,134,54,0.15); padding: 2px 6px; border-radius: 4px; text-transform: uppercase; letter-spacing: 0.5px;';
                    badge.textContent = 'Pending';
                    header.appendChild(badge);

                    const range = document.createElement('span');
                    range.style.cssText = 'font-size: 11px; color: #64748b;';
                    range.textContent = m.startLine === m.endLine
                        ? 'L' + m.startLine
                        : 'L' + m.startLine + '–L' + m.endLine;
                    header.appendChild(range);

                    const spacer = document.createElement('span');
                    spacer.style.cssText = 'flex: 1;';
                    header.appendChild(spacer);

                    const editBtn = document.createElement('button');
                    editBtn.textContent = 'Edit';
                    editBtn.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 4px; border: 1px solid #1d4ed8; background: transparent; color: #60a5fa; cursor: pointer; font-family: inherit;';

                    const deleteBtn = document.createElement('button');
                    deleteBtn.textContent = 'Delete';
                    deleteBtn.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 4px; border: 1px solid #6b2126; background: transparent; color: #f85149; cursor: pointer; font-family: inherit;';
                    deleteBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        window.webkit.messageHandlers.deleteDraft.postMessage({ commentID: m.commentID });
                    });
                    deleteBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    editBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    header.appendChild(editBtn);
                    header.appendChild(deleteBtn);

                    wrapper.appendChild(header);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = m.body;
                    wrapper.appendChild(body);

                    const editArea = document.createElement('div');
                    editArea.style.cssText = 'display: none; margin-top: 8px;';

                    const textarea = document.createElement('textarea');
                    textarea.value = m.body;
                    textarea.style.cssText = 'width: 100%; min-height: 60px; max-height: 120px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                    textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                    textarea.addEventListener('keydown', (e) => e.stopPropagation());
                    editArea.appendChild(textarea);

                    const actionRow = document.createElement('div');
                    actionRow.style.cssText = 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;';

                    const cancelEditBtn = document.createElement('button');
                    cancelEditBtn.textContent = 'Cancel';
                    cancelEditBtn.style.cssText = 'font-size: 11px; padding: 4px 10px; border-radius: 4px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-family: inherit;';
                    cancelEditBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        textarea.value = m.body;
                        editArea.style.display = 'none';
                        body.style.display = '';
                        editBtn.textContent = 'Edit';
                    });
                    cancelEditBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    actionRow.appendChild(cancelEditBtn);

                    const saveEditBtn = document.createElement('button');
                    saveEditBtn.textContent = 'Save';
                    saveEditBtn.style.cssText = 'font-size: 11px; padding: 4px 10px; border-radius: 4px; border: none; background: #238636; color: white; cursor: pointer; font-family: inherit; font-weight: 600;';
                    saveEditBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        const updated = textarea.value.trim();
                        if (!updated) return;
                        m.body = updated;
                        body.textContent = updated;
                        editArea.style.display = 'none';
                        body.style.display = '';
                        editBtn.textContent = 'Edit';
                        window.webkit.messageHandlers.updateDraft.postMessage({
                            commentID: m.commentID,
                            body: updated
                        });
                    });
                    saveEditBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    actionRow.appendChild(saveEditBtn);

                    editArea.appendChild(actionRow);
                    wrapper.appendChild(editArea);

                    editBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        const editing = editArea.style.display !== 'none';
                        if (editing) {
                            textarea.value = m.body;
                            editArea.style.display = 'none';
                            body.style.display = '';
                            editBtn.textContent = 'Edit';
                        } else {
                            textarea.value = m.body;
                            editArea.style.display = '';
                            body.style.display = 'none';
                            editBtn.textContent = 'Close';
                            setTimeout(() => textarea.focus(), 30);
                        }
                    });

                    return wrapper;
                }

                const threadID = m.threadID;

                const wrapper = document.createElement('div');
                wrapper.id = 'review-thread-annotation-' + threadID;
                wrapper.style.cssText = 'padding: 12px 16px; background: #1e293b; border-left: 3px solid #3b82f6; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                const header = document.createElement('div');
                header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 8px;';

                const threadLabel = document.createElement('span');
                threadLabel.style.cssText = 'font-size: 11px; color: #94a3b8; font-weight: 600; flex-shrink: 0;';
                threadLabel.textContent = m.isResolved ? 'Resolved Thread' : (m.isOutdated ? 'Outdated Thread' : 'Review Thread');
                header.appendChild(threadLabel);

                const spacer = document.createElement('span');
                spacer.style.cssText = 'flex: 1;';
                header.appendChild(spacer);

                const btnStyle = 'font-size: 11px; padding: 3px 10px; border-radius: 4px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-family: inherit; flex-shrink: 0;';

                const resolveBtn = document.createElement('button');
                resolveBtn.textContent = m.isResolved ? 'Unresolve' : 'Resolve';
                resolveBtn.style.cssText = btnStyle;
                if (m.isResolved) {
                    resolveBtn.style.borderColor = '#065f46';
                    resolveBtn.style.color = '#6ee7b7';
                }
                resolveBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.resolveThread.postMessage({
                        threadID: threadID,
                        resolve: !m.isResolved
                    });
                    resolveBtn.disabled = true;
                });
                resolveBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(resolveBtn);

                const addBtn = document.createElement('button');
                addBtn.textContent = 'Add to chat';
                addBtn.style.cssText = btnStyle;
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.addToChat.postMessage({ threadID: threadID });
                    addBtn.disabled = true;
                    addBtn.textContent = 'Added';
                    addBtn.style.borderColor = '#065f46';
                    addBtn.style.color = '#6ee7b7';
                    setTimeout(() => {
                        addBtn.disabled = false;
                        addBtn.textContent = 'Add to chat';
                        addBtn.style.borderColor = '#475569';
                        addBtn.style.color = '#e2e8f0';
                    }, 1200);
                });
                addBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(addBtn);

                wrapper.appendChild(header);

                for (const c of m.comments) {
                    const commentDiv = document.createElement('div');
                    commentDiv.style.cssText = 'padding: 8px 10px; background: #0f172a; border-radius: 6px; margin-bottom: 6px;';

                    const commentHeader = document.createElement('div');
                    commentHeader.style.cssText = 'display: flex; justify-content: space-between; margin-bottom: 4px;';

                    const author = document.createElement('span');
                    author.style.cssText = 'font-size: 12px; font-weight: 600; color: #e2e8f0;';
                    author.textContent = c.author;
                    commentHeader.appendChild(author);

                    const date = document.createElement('span');
                    date.style.cssText = 'font-size: 11px; color: #64748b;';
                    date.textContent = c.date;
                    commentHeader.appendChild(date);

                    commentDiv.appendChild(commentHeader);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = c.body;
                    commentDiv.appendChild(body);
                    wrapper.appendChild(commentDiv);
                }

                const replyArea = document.createElement('div');
                replyArea.style.cssText = 'margin-top: 8px; display: flex; flex-direction: column; gap: 8px;';
                const textarea = document.createElement('textarea');
                textarea.placeholder = 'Reply to this thread…';
                textarea.style.cssText = 'width: 100%; min-height: 36px; max-height: 100px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                textarea.addEventListener('keydown', (e) => e.stopPropagation());
                replyArea.appendChild(textarea);

                const sendBtn = document.createElement('button');
                sendBtn.textContent = 'Reply';
                sendBtn.style.cssText = 'align-self: flex-end; font-size: 12px; padding: 8px 14px; border-radius: 6px; border: none; background: #3b82f6; color: white; cursor: pointer; font-weight: 600; font-family: inherit;';
                sendBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const text = textarea.value.trim();
                    if (!text) return;
                    window.webkit.messageHandlers.replyToThread.postMessage({
                        threadID: threadID,
                        body: text
                    });
                    textarea.disabled = true;
                    sendBtn.disabled = true;
                    sendBtn.textContent = 'Sent';
                    sendBtn.style.background = '#065f46';
                });
                sendBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                replyArea.appendChild(sendBtn);
                wrapper.appendChild(replyArea);

                return wrapper;
            }

            document.getElementById('loading').classList.add('hidden');
            const container = document.getElementById('container');
            const splitRe = /(?<=\\n)/;

            for (const patch of parsedPatches) {
                for (const fileDiff of patch.files) {
                    const candidatePaths = [normalizePath(fileDiff.name), normalizePath(fileDiff.prevName)].filter(Boolean);
                    const dedupedPaths = [...new Set(candidatePaths)];

                    let lineAnnotations = [];
                    for (const candidatePath of dedupedPaths) {
                        const annotationsForPath = annotationsByPath[candidatePath];
                        if (Array.isArray(annotationsForPath)) {
                            lineAnnotations = lineAnnotations.concat(annotationsForPath);
                        }
                    }

                    for (const candidatePath of dedupedPaths) {
                        const fullFileContent = fileContentsByPath[candidatePath];
                        if (typeof fullFileContent === 'string') {
                            const fileLines = fullFileContent.split(splitRe);
                            fileDiff.newLines = fileLines;
                            fileDiff.oldLines = fileLines;
                            break;
                        }
                    }

                    const instance = new FileDiff({
                        theme: { dark: 'dark-plus', light: 'light-plus' },
                        themeType: '\(themeType)',
                        diffStyle: 'split',
                        overflow: 'scroll',
                        lineHoverHighlight: 'both',
                        hunkSeparators: 'line-info',
                        expansionLineCount: 20,
                        disableFileHeader: true,
                        renderAnnotation: renderAnnotation,
                    });

                    const displayPath = dedupedPaths[0] || normalizePath(fileDiff.name) || normalizePath(fileDiff.prevName) || 'file';

                    const section = document.createElement('div');
                    section.style.cssText = 'position: relative;';

                    // Sticky, clickable filename header (opens the full file in the file viewer).
                    const fileHeader = document.createElement('div');
                    fileHeader.style.cssText = 'position: sticky; top: 0; z-index: 30; display: flex; align-items: center; gap: 8px; background: \(backgroundHex); color: \(foregroundHex); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; font-weight: 600; padding: 8px 14px; border-bottom: 1px solid \(mutedHex); cursor: pointer; user-select: none;';
                    const nameSpan = document.createElement('span');
                    nameSpan.textContent = displayPath;
                    fileHeader.appendChild(nameSpan);
                    const openHint = document.createElement('span');
                    openHint.textContent = 'Open file ›';
                    openHint.style.cssText = 'margin-left: auto; font-size: 11px; font-weight: 500; color: \(mutedHex);';
                    fileHeader.appendChild(openHint);
                    fileHeader.addEventListener('mouseenter', () => { fileHeader.style.filter = 'brightness(1.25)'; });
                    fileHeader.addEventListener('mouseleave', () => { fileHeader.style.filter = ''; });
                    fileHeader.addEventListener('click', () => {
                        window.webkit.messageHandlers.openFile.postMessage({ path: displayPath });
                    });
                    section.appendChild(fileHeader);

                    const fileContainer = document.createElement(DIFFS_TAG_NAME);
                    section.appendChild(fileContainer);
                    container.appendChild(section);

                    instance.render({
                        fileDiff,
                        fileContainer,
                        lineAnnotations: lineAnnotations.length > 0 ? lineAnnotations : undefined
                    });
                }
            }

            if (focusedThreadID != null || Object.keys(annotationsByPath).length > 0) {
                function scrollToFocusedThread() {
                    const targetID = focusedThreadID ? ('review-thread-annotation-' + focusedThreadID) : null;
                    const target = findInShadow(document, (root) => {
                        const nodes = Array.from(root.querySelectorAll('[id^="review-thread-annotation-"]'));
                        if (nodes.length === 0) return null;
                        if (!targetID) return nodes[0];
                        return nodes.find((node) => node.id === targetID) || nodes[0];
                    });
                    if (!target || !container) return false;

                    let offsetTop = 0;
                    let el = target;
                    while (el) {
                        offsetTop += el.offsetTop || 0;
                        el = el.offsetParent;
                    }
                    container.scrollTop = Math.max(0, offsetTop - container.clientHeight / 3);
                    return true;
                }

                if (!scrollToFocusedThread()) {
                    const observer = new MutationObserver(() => {
                        if (scrollToFocusedThread()) observer.disconnect();
                    });
                    observer.observe(container, { childList: true, subtree: true });
                }
            }
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load diff renderer: ' + err.message;
            console.error('Pierre combined diff error:', err);
        }
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView wrapper for full file viewing with pierre

struct PierreFileWebView: NSViewRepresentable {
    let fileContent: String
    let fileName: String
    let theme: TerminalCodeTheme = .forColorScheme(.dark)
    var findModel: WebViewFindModel? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastContent = fileContent
        findModel?.webView = webView

        guard let baseURL = PierreLocalResources.baseURL else {
            webView.loadHTMLString(
                PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                baseURL: nil
            )
            return webView
        }

        let html = Self.buildFileHTML(content: fileContent, fileName: fileName, theme: theme)
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastContent != fileContent {
            context.coordinator.lastContent = fileContent
            guard let baseURL = PierreLocalResources.baseURL else {
                webView.loadHTMLString(
                    PierreLocalResources.errorHTML(message: PierreLocalResources.missingMessage, theme: theme),
                    baseURL: nil
                )
                return
            }
            let html = Self.buildFileHTML(content: fileContent, fileName: fileName, theme: theme)
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    class Coordinator: NSObject {
        var lastContent: String?
    }

    private static func buildFileHTML(content: String, fileName: String, theme: TerminalCodeTheme) -> String {
        let lang = PierreDiffWebView.detectLanguage(from: fileName)

        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let escapedName = PierreDiffWebView.escapeJS(fileName)
        let backgroundHex = theme.shellBackgroundHex
        let foregroundHex = theme.shellForegroundHex
        let mutedHex = theme.mutedHex
        let errorHex = theme.errorHex
        let themeType = theme.pierreThemeType
        let moduleImportPath = PierreLocalResources.moduleImportPath

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: \(foregroundHex);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
                background: \(backgroundHex);
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: \(mutedHex);
                font-size: 13px;
                background: \(backgroundHex);
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: \(errorHex);
                font-size: 13px;
                white-space: pre-wrap;
                background: \(backgroundHex);
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading file…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { File, DIFFS_TAG_NAME } = await import('\(moduleImportPath)');

            const fileContent = `\(escapedContent)`;

            document.getElementById('loading').classList.add('hidden');

            const container = document.getElementById('container');

            const instance = new File({
                theme: { dark: 'dark-plus', light: 'light-plus' },
                themeType: '\(themeType)',
                overflow: 'scroll',
                disableFileHeader: true,
                lineHoverHighlight: 'both',
            });

            const fileContainer = document.createElement(DIFFS_TAG_NAME);
            container.appendChild(fileContainer);
            instance.render({
                file: { contents: fileContent, name: '\(escapedName)', lang: '\(lang)' },
                fileContainer
            });
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load file viewer: ' + err.message;
            console.error('Pierre file viewer error:', err);
        }
        </script>
        </body>
        </html>
        """
    }
}
