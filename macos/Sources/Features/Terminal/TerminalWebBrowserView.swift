import AppKit
import SwiftUI
import WebKit

/// In-tab browser content view: an iTerm2-style chrome bar above a WKWebView, with the
/// same Cmd-F find-in-page UX as the diff view (reusing `WebViewFindModel`/`WebViewFindBar`).
struct TerminalWebBrowserView: View {
    @ObservedObject var session: TerminalWebSession

    var body: some View {
        VStack(spacing: 0) {
            BrowserChromeBar(session: session)
            Divider()
            WebViewContainer(session: session)
                .overlay(alignment: .topTrailing) {
                    WebViewFindBar(model: session.findModel)
                }
                .background {
                    Button("") {
                        session.findModel.show(prefillSelection: true)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("terminal-web-browser")
    }
}

private struct BrowserChromeBar: View {
    @ObservedObject var session: TerminalWebSession

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!session.canGoBack)
            .help("Back")

            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!session.canGoForward)
            .help("Forward")

            Button {
                session.isLoading ? session.stopLoading() : session.reload()
            } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(session.isLoading ? "Stop" : "Reload")

            TextField("Search or enter address", text: $session.addressText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.navigateToAddressText() }
                .accessibilityIdentifier("browser-address-field")

            if session.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                session.openInExternalBrowser()
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .help("Open in external browser")
        }
        .imageScale(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Wraps the session's retained WKWebView so navigation/scroll survive content-tab switches.
private struct WebViewContainer: NSViewRepresentable {
    let session: TerminalWebSession

    func makeNSView(context: Context) -> WKWebView {
        session.findModel.webView = session.webView
        return session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
