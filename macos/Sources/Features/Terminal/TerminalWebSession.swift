import AppKit
import Combine
import WebKit

/// Owns a live WKWebView for an in-tab browser content tab. Held (retained) by
/// `TerminalTabState` so navigation/scroll survive content-tab switches. Publishes the
/// chrome-bar state (address, title, back/forward, loading) via KVO on the web view.
@MainActor
final class TerminalWebSession: NSObject, ObservableObject {
    let id: String
    let webView: WKWebView
    let findModel = WebViewFindModel()

    @Published var addressText: String = ""
    @Published private(set) var pageTitle: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    /// Invoked when the page title or URL changes so the owning tab can refresh its
    /// content-tab label/subtitle.
    var onChange: (@MainActor () -> Void)?

    private var observations: [NSKeyValueObservation] = []

    init(id: String, initialURL: URL?) {
        self.id = id

        // Re-inject the shared find-in-page script on every page load (idempotent via
        // `window._pfInit`), so Cmd-F works after navigations.
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(
                source: WebViewFindModel.findScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        findModel.webView = webView

        if let initialURL {
            if initialURL.absoluteString != "about:blank" {
                addressText = initialURL.absoluteString
            }
            load(initialURL)
        }

        observe()
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                let newTitle = (change.newValue ?? nil) ?? ""
                Task { @MainActor in
                    guard let self else { return }
                    self.pageTitle = newTitle
                    self.onChange?()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                let newURL = change.newValue ?? nil
                Task { @MainActor in
                    guard let self else { return }
                    if let newURL, newURL.absoluteString != "about:blank" {
                        self.addressText = newURL.absoluteString
                    }
                    self.onChange?()
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.isLoading = value }
            },
        ]
    }

    var currentURL: URL? { webView.url }

    /// Title to show on the content tab (page title, falling back to host/URL).
    var contentTabTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        if let host = currentURL?.host { return host }
        return addressText.isEmpty ? "New Tab" : addressText
    }

    var contentTabSubtitle: String? {
        currentURL?.absoluteString ?? (addressText.isEmpty ? nil : addressText)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Loads whatever is in `addressText`, normalizing it into a URL.
    func navigateToAddressText() {
        guard let url = Self.normalizedURL(from: addressText) else { return }
        addressText = url.absoluteString
        load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func openInExternalBrowser() {
        guard let url = currentURL ?? Self.normalizedURL(from: addressText) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Normalizes a user-entered address into a loadable URL, prepending `https://` when
    /// no scheme is present. Returns nil for blank input.
    nonisolated static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }
}
