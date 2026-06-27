import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url || context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reloadToken: reloadToken)
    }

    final class Coordinator {
        var reloadToken: UUID

        init(reloadToken: UUID) {
            self.reloadToken = reloadToken
        }
    }
}
