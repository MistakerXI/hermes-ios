import SwiftUI
import UIKit
import WebKit

private let dashboardURL = URL(string: "https://dash.thewhome.top/chat")!

struct DashboardWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.031, green: 0.031, blue: 0.110, alpha: 1)
        web.load(URLRequest(url: dashboardURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ web: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let host = url.host ?? ""
            let inApp = host.hasSuffix("thewhome.top") || host.hasSuffix("cloudflareaccess.com")
            if !inApp && navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

@main
struct HermesApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardWebView()
                .preferredColorScheme(.dark)
        }
    }
}
