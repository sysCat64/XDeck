import SwiftUI
import WebKit
import AppKit

struct WebView: NSViewRepresentable {
    typealias NSViewType = WKWebView

    @Binding var isLoading: Bool
    @Binding var url: URL
    @Binding var alertMessage: String?
    @Binding var messageFromWebView: String?
    var scriptExecutionRequest: String? = nil

    @AppStorage("pageZoom") var pageZoom: Double = 1

    var scriptExecutionToken: Int = 0
    var refreshSwitch: Bool = false
    var configuration: WKWebViewConfiguration? = nil
    // Temporary startup-timing diagnostic: when set, the coordinator logs [StartupTiming] records.
    var diagnosticLabel: String? = nil

    func makeNSView(context: Context) -> WKWebView {
        let webView: WKWebView
        if let configuration = configuration {
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = WKWebView()
        }
        // Pretend Safari because 𝕏 bans the user agent of WebView
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        let request = URLRequest(url: url)
        context.coordinator.startStartupTiming()
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if url != context.coordinator.lastUrl {
            let request = URLRequest(url: url)
            context.coordinator.lastUrl = url
            webView.load(request)
        }
        if refreshSwitch != context.coordinator.refreshSwitch {
            let request = URLRequest(url: url)
            webView.load(request)
            context.coordinator.refreshSwitch = refreshSwitch
        } else if let script = scriptExecutionRequest, scriptExecutionToken != context.coordinator.lastHandledScriptToken {
            webView.evaluateJavaScript(script)
            context.coordinator.lastHandledScriptToken = scriptExecutionToken
        }
        if webView.pageZoom != pageZoom {
            webView.pageZoom = CGFloat(pageZoom)
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(owner: self)
    }
}

class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let owner: WebView
    var lastUrl: URL
    var refreshSwitch: Bool
    var lastHandledScriptToken: Int
    private var startupTimingStart: TimeInterval?
    private var loggedStartupTimingEvents = Set<String>()

    init(owner: WebView) {
        self.owner = owner
        self.lastUrl = owner.url
        self.refreshSwitch = false
        self.lastHandledScriptToken = owner.scriptExecutionToken
        super.init()
        owner.configuration?.userContentController.add(self, name: WebViewConfigurations.handlerName)
    }

    // MARK: Startup timing (temporary diagnostic)
    func startStartupTiming() {
        guard owner.diagnosticLabel != nil else { return }
        startupTimingStart = ProcessInfo.processInfo.systemUptime
        logStartupTiming("loadRequested")
    }

    // Logs each event once, as elapsed time since the initial load() of this web view.
    // A marker may carry detail after its event name: "<event>:<detail>".
    private func logStartupTiming(_ marker: String) {
        let parts = marker.split(separator: ":", maxSplits: 1)
        let event = parts.first.map(String.init) ?? marker
        guard let label = owner.diagnosticLabel, let start = startupTimingStart,
              loggedStartupTimingEvents.insert(event).inserted else { return }
        let elapsedMs = Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
        let detail = parts.count > 1 ? " detail=\(parts[1])" : ""
        print("[StartupTiming] \(label) event=\(event) elapsedMs=\(elapsedMs)\(detail)")
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner.isLoading = true
        logStartupTiming("didStart")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logStartupTiming("didCommit")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.isLoading = false
        logStartupTiming("didFinish")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if case .linkActivated = navigationAction.navigationType, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        owner.alertMessage = message
        print("🚨️ \(message)")
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.begin { response in
            if response == .OK {
                completionHandler(openPanel.urls)
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebViewConfigurations.handlerName else { return }
        let prefix = WebViewConfigurations.startupTimingMessagePrefix
        if let body = message.body as? String, body.hasPrefix(prefix) {
            // Startup-timing markers are logged here and never forwarded as XDeck messages.
            logStartupTiming(String(body.dropFirst(prefix.count)))
            return
        }
        print("[WKScriptMessage] \(message.body)")
        owner.messageFromWebView = message.body as? String
    }
}
