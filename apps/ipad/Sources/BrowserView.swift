import SwiftUI
import WebKit

@MainActor
final class BrowserViewState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL = ""
    @Published var title = ""
    @Published fileprivate var commandID = UUID()
    fileprivate var command: BrowserCommand?

    func goBack() {
        command = .goBack
        commandID = UUID()
    }

    func goForward() {
        command = .goForward
        commandID = UUID()
    }

    func reload() {
        command = .reload
        commandID = UUID()
    }

    func loadCurrentTarget() {
        command = .loadTarget
        commandID = UUID()
    }
}

private enum BrowserCommand {
    case goBack
    case goForward
    case reload
    case loadTarget
}

struct BrowserView: UIViewRepresentable {
    let url: URL
    @ObservedObject var state: BrowserViewState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url || context.coordinator.targetURL != url {
            context.coordinator.targetURL = url
            webView.load(URLRequest(url: url))
            return
        }

        guard context.coordinator.commandID != state.commandID else { return }
        context.coordinator.commandID = state.commandID

        switch state.command {
        case .goBack:
            if webView.canGoBack { webView.goBack() }
        case .goForward:
            if webView.canGoForward { webView.goForward() }
        case .reload:
            webView.reload()
        case .loadTarget:
            webView.load(URLRequest(url: url))
        case nil:
            break
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, targetURL: url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: BrowserViewState
        var targetURL: URL
        var commandID = UUID()

        init(state: BrowserViewState, targetURL: URL) {
            self.state = state
            self.targetURL = targetURL
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            updateState(webView)
        }

        private func updateState(_ webView: WKWebView) {
            state.canGoBack = webView.canGoBack
            state.canGoForward = webView.canGoForward
            state.isLoading = webView.isLoading
            state.currentURL = webView.url?.absoluteString ?? ""
            state.title = webView.title ?? ""
        }
    }
}
