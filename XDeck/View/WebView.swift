import SwiftUI
import WebKit
import AppKit

private enum WebViewDiagnostics {
    static func log(_ message: String) {
        print("[XDeck WebView] \(message)")
    }

    static func location(for url: URL?) -> String {
        guard let url = url else { return "<unavailable>" }
        let host = url.host ?? "<no-host>"
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host)\(path)"
    }

    static func sanitized(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(
            of: #"(?i)\b(cookie|set-cookie|authorization|proxy-authorization)\s*[:=]\s*[^\r\n]+"#,
            with: "$1: <redacted>", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)\b(password|passwd|token|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|api[_-]?key|credential)\s*[:=]\s*[^\s,;]+"#,
            with: "$1: <redacted>", options: .regularExpression)

        if let urlPattern = try? NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in urlPattern.matches(in: value, range: range).reversed() {
                guard let matchRange = Range(match.range, in: value) else { continue }
                let matchedURL = String(value[matchRange])
                let replacement = URL(string: matchedURL).map { location(for: $0) } ?? "<URL redacted>"
                value.replaceSubrange(matchRange, with: replacement)
            }
        }

        return value.replacingOccurrences(
            of: #"\?[^\s]+"#, with: "?<redacted>", options: .regularExpression)
    }

    static func safeUserInfo(for error: NSError) -> String {
        var fields: [String] = []
        if let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            fields.append("failingLocation=\(location(for: failingURL))")
        } else if let failingURLString = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
                  let failingURL = URL(string: failingURLString) {
            fields.append("failingLocation=\(location(for: failingURL))")
        }
        if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            fields.append("failureReason=\(String(reflecting: sanitized(reason)))")
        }
        if let suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
            fields.append("recoverySuggestion=\(String(reflecting: sanitized(suggestion)))")
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields.append(
                "underlyingErrorDomain=\(String(reflecting: underlying.domain)) code=\(underlying.code)")
        }
        return fields.isEmpty ? "<no allow-listed fields>" : fields.joined(separator: ", ")
    }
}

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

    func makeNSView(context: Context) -> WKWebView {
        let webView: WKWebView
        if let configuration = configuration {
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = WKWebView()
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        WebViewDiagnostics.log(
            "created location=\(WebViewDiagnostics.location(for: url)) "
                + "customUserAgent=\(String(reflecting: webView.customUserAgent ?? "<nil>")) "
                + "macOS=\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        let request = URLRequest(url: url)
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

    init(owner: WebView) {
        self.owner = owner
        self.lastUrl = owner.url
        self.refreshSwitch = false
        self.lastHandledScriptToken = owner.scriptExecutionToken
        super.init()
        owner.configuration?.userContentController.add(self, name: WebViewConfigurations.handlerName)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner.isLoading = true
        WebViewDiagnostics.log(
            "didStartProvisionalNavigation location=\(WebViewDiagnostics.location(for: webView.url))")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        WebViewDiagnostics.log("didCommit location=\(WebViewDiagnostics.location(for: webView.url))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.isLoading = false
        WebViewDiagnostics.log("didFinish location=\(WebViewDiagnostics.location(for: webView.url))")
        logPageDiagnostics(for: webView)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        logNavigationFailure("didFailProvisionalNavigation", webView: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavigationFailure("didFail", webView: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        WebViewDiagnostics.log(
            "webViewWebContentProcessDidTerminate location=\(WebViewDiagnostics.location(for: webView.url))")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let location = WebViewDiagnostics.location(for: navigationResponse.response.url)
        if let response = navigationResponse.response as? HTTPURLResponse {
            WebViewDiagnostics.log(
                "navigationResponse mainFrame=\(navigationResponse.isForMainFrame) "
                    + "HTTP status=\(response.statusCode) location=\(location)")
        } else {
            WebViewDiagnostics.log(
                "navigationResponse mainFrame=\(navigationResponse.isForMainFrame) "
                    + "nonHTTP location=\(location)")
        }
        decisionHandler(.allow)
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
        print("[WKScriptMessage] \(message.body)")
        owner.messageFromWebView = message.body as? String
    }

    private func logNavigationFailure(_ event: String, webView: WKWebView, error: Error) {
        let nsError = error as NSError
        let description = WebViewDiagnostics.sanitized(nsError.localizedDescription)
        WebViewDiagnostics.log(
            "\(event) location=\(WebViewDiagnostics.location(for: webView.url)) "
                + "NSError domain=\(String(reflecting: nsError.domain)) code=\(nsError.code) "
                + "localizedDescription=\(String(reflecting: description)) "
                + "safeUserInfo={\(WebViewDiagnostics.safeUserInfo(for: nsError))}")
    }

    private func logPageDiagnostics(for webView: WKWebView) {
        let expression = """
            (() => {
                const body = document.body;
                return {
                    userAgent: navigator.userAgent,
                    readyState: document.readyState,
                    title: document.title,
                    host: window.location.host,
                    path: window.location.pathname,
                    bodyExists: body !== null,
                    bodyChildCount: body ? body.childNodes.length : null
                };
            })()
            """
        webView.evaluateJavaScript(expression) { result, error in
            if let error = error {
                let nsError = error as NSError
                WebViewDiagnostics.log(
                    "didFinish JavaScript diagnostic failed NSError "
                        + "domain=\(String(reflecting: nsError.domain)) code=\(nsError.code) "
                        + "localizedDescription=\(String(reflecting: WebViewDiagnostics.sanitized(nsError.localizedDescription))) "
                        + "safeUserInfo={\(WebViewDiagnostics.safeUserInfo(for: nsError))}")
                return
            }

            guard let diagnostics = result as? [String: Any] else {
                WebViewDiagnostics.log("didFinish JavaScript diagnostic returned no dictionary")
                return
            }
            let userAgent = WebViewDiagnostics.sanitized(diagnostics["userAgent"] as? String ?? "<unavailable>")
            let readyState = WebViewDiagnostics.sanitized(diagnostics["readyState"] as? String ?? "<unavailable>")
            let title = WebViewDiagnostics.sanitized(diagnostics["title"] as? String ?? "<unavailable>")
            let host = WebViewDiagnostics.sanitized(diagnostics["host"] as? String ?? "<unavailable>")
            let path = WebViewDiagnostics.sanitized(diagnostics["path"] as? String ?? "<unavailable>")
            let bodyExists = diagnostics["bodyExists"] as? Bool
            let bodyChildCount = diagnostics["bodyChildCount"] as? Int
            let bodyExistsText = bodyExists.map { String($0) } ?? "<unavailable>"
            let bodyChildCountText = bodyChildCount.map { String($0) } ?? "<unavailable>"

            WebViewDiagnostics.log(
                "didFinish JavaScript userAgent=\(String(reflecting: userAgent)) "
                    + "readyState=\(String(reflecting: readyState)) "
                    + "title=\(String(reflecting: title)) location=\(host)\(path) "
                    + "bodyExists=\(bodyExistsText) bodyChildCount=\(bodyChildCountText)")
        }
    }
}
