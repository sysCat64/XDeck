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
    var isCleanResourceTimingDiagnostic: Bool = false

    func makeNSView(context: Context) -> WKWebView {
        let webView: WKWebView
        if let configuration = configuration {
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = WKWebView()
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
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
    private var didRunTLADuplicateImportProbe = false
    private var didScheduleCleanResourceTimingRead = false

    init(owner: WebView) {
        self.owner = owner
        self.lastUrl = owner.url
        self.refreshSwitch = false
        self.lastHandledScriptToken = owner.scriptExecutionToken
        super.init()
        if !owner.isCleanResourceTimingDiagnostic {
            owner.configuration?.userContentController.add(self, name: WebViewConfigurations.handlerName)
        }
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
        if owner.isCleanResourceTimingDiagnostic {
            scheduleCleanResourceTimingRead(for: webView)
            return
        }
        let superviewBounds = webView.superview.map { "\($0.bounds.width)x\($0.bounds.height)" } ?? "<unavailable>"
        let contentViewBounds: String
        if let contentView = webView.window?.contentView {
            contentViewBounds = "\(contentView.bounds.width)x\(contentView.bounds.height)"
        } else {
            contentViewBounds = "<unavailable>"
        }
        WebViewDiagnostics.log(
            "geometry frame=\(webView.frame.width)x\(webView.frame.height) "
                + "bounds=\(webView.bounds.width)x\(webView.bounds.height) "
                + "superviewBounds=\(superviewBounds) "
                + "windowContentViewBounds=\(contentViewBounds) "
                + "windowIsNil=\(webView.window == nil) isHidden=\(webView.isHidden) "
                + "alphaValue=\(webView.alphaValue)")
        logPageDiagnostics(for: webView)
        scheduleResourceSnapshots(for: webView)
        scheduleNativePageWorldProbe(for: webView)
        runTLADuplicateImportProbeOnce(for: webView)
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
        if let diagnostic = message.body as? [String: Any],
           diagnostic["channel"] as? String == "xdeck-runtime-diagnostic" {
            logRuntimeDiagnostic(diagnostic)
            return
        }
        print("[WKScriptMessage] \(message.body)")
        owner.messageFromWebView = message.body as? String
    }

    private func logRuntimeDiagnostic(_ diagnostic: [String: Any]) {
        func safeString(_ key: String) -> String {
            guard let value = diagnostic[key] as? String else { return "<unavailable>" }
            return String(WebViewDiagnostics.sanitized(value).prefix(500))
        }

        func safeNumber(_ key: String) -> String {
            guard let value = diagnostic[key] as? NSNumber else { return "<unavailable>" }
            return value.stringValue
        }

        func safeBoolean(_ key: String) -> String {
            guard let value = diagnostic[key] as? Bool else { return "<unavailable>" }
            return value ? "true" : "false"
        }

        switch diagnostic["type"] as? String {
        case "javascriptError":
            WebViewDiagnostics.log(
                "JavaScript error name=\(String(reflecting: safeString("name"))) "
                    + "message=\(String(reflecting: safeString("message"))) "
                    + "location=\(safeString("location")) line=\(safeNumber("line")) "
                    + "column=\(safeNumber("column"))")
        case "unhandledPromiseRejection":
            WebViewDiagnostics.log(
                "unhandled promise rejection name=\(String(reflecting: safeString("name"))) "
                    + "message=\(String(reflecting: safeString("message")))")
        case "resourceLoadFailure":
            WebViewDiagnostics.log(
                "resource load failure element=\(safeString("element")) "
                    + "location=\(safeString("location"))")
        case "stylesheetInsertion":
            let jetfuel = diagnostic["jetfuel"] as? Bool ?? false
            WebViewDiagnostics.log(
                "stylesheet insertion location=\(safeString("location")) jetfuel=\(jetfuel)")
        case "jetfuelStylesheetEvent":
            let event = safeString("event")
            guard event == "load" || event == "error" else { return }
            WebViewDiagnostics.log(
                "jetfuel stylesheet event=\(event) location=\(safeString("location"))")
        case "entryModuleEvent":
            let event = safeString("event")
            guard event == "load" || event == "error" else { return }
            WebViewDiagnostics.log(
                "entry module event=\(event) location=\(safeString("location"))")
        case "moduleEvaluationProbe":
            switch diagnostic["status"] as? String {
            case "resolved":
                WebViewDiagnostics.log(
                    "module evaluation probe status=resolved location=\(safeString("location")) "
                        + "reactContainerMarkerPresent=\(safeBoolean("reactContainerMarkerPresent")) "
                        + "document.readyState=\(safeString("readyState")) "
                        + "windowIsTop=\(safeBoolean("windowIsTop"))")
            case "rejected":
                WebViewDiagnostics.log(
                    "module evaluation probe status=rejected\n"
                        + "name=\(safeString("name"))\n"
                        + "message=\(safeString("message"))")
            case "entry-module-not-found":
                WebViewDiagnostics.log("module evaluation probe status=entry-module-not-found")
            default:
                break
            }
        case "routeModuleEvaluationProbe":
            let location = safeString("location")
            switch diagnostic["status"] as? String {
            case "resolved":
                WebViewDiagnostics.log(
                    "route module evaluation probe status=resolved location=\(location)")
            case "rejected":
                let failureKind = diagnostic["failureKind"] as? String
                let classification = failureKind == "network-failure"
                    ? " failureKind=network-failure" : ""
                WebViewDiagnostics.log(
                    "route module evaluation probe status=rejected location=\(location) "
                        + "name=\(safeString("name")) message=\(safeString("message"))"
                        + classification)
            default:
                break
            }
        case "routeModulePostImportState":
            WebViewDiagnostics.log(
                "route module post-import visibility "
                    + "pageVisible=\(safeBoolean("pageVisible")) "
                    + "elementCount=\(safeNumber("elementCount")) "
                    + "bodyDescendantElementCount=\(safeNumber("bodyDescendantElementCount")) "
                    + "jetfuelElementCount=\(safeNumber("jetfuelElementCount")) "
                    + "visibleJetfuelElementCount=\(safeNumber("visibleJetfuelElementCount")) "
                    + "jetfuelStylesheetPresent=\(safeBoolean("jetfuelStylesheetPresent")) "
                    + "hasLayers=\(safeBoolean("hasLayers"))")
        case "routeLazyLoaderProbe":
            switch diagnostic["status"] as? String {
            case "started":
                WebViewDiagnostics.log("route lazy-loader probe status=started")
            case "resolved":
                WebViewDiagnostics.log("route lazy-loader probe status=resolved")
            case "rejected":
                WebViewDiagnostics.log(
                    "route lazy-loader probe status=rejected "
                        + "name=\(safeString("name")) message=\(safeString("message"))")
            default:
                break
            }
        case "routerBootstrapProbe":
            switch diagnostic["status"] as? String {
            case "observed":
                WebViewDiagnostics.log(
                    "router bootstrap probe status=observed "
                        + "routerExists=\(safeBoolean("routerExists")) "
                        + "matchesIsArray=\(safeBoolean("matchesIsArray")) "
                        + "serializedMatchCount=\(safeNumber("serializedMatchCount")) "
                        + "initializedFieldPresent=\(safeBoolean("initializedFieldPresent"))")

                let matches = diagnostic["matches"] as? [[String: Any]] ?? []
                for match in matches {
                    func safeMatchString(_ key: String) -> String {
                        guard let value = match[key] as? String else { return "<unavailable>" }
                        return String(WebViewDiagnostics.sanitized(value).prefix(200))
                    }

                    WebViewDiagnostics.log(
                        "router bootstrap match id=\(String(reflecting: safeMatchString("id"))) "
                            + "status=\(String(reflecting: safeMatchString("status"))) "
                            + "ssr=\(String(reflecting: safeMatchString("ssr")))")
                }
            case "not-observed":
                WebViewDiagnostics.log("router bootstrap probe status=not-observed")
            case "observed-incomplete":
                WebViewDiagnostics.log(
                    "router bootstrap probe status=observed-incomplete "
                        + "routerOwnDataPropertyEverObserved=\(safeBoolean("routerOwnDataPropertyEverObserved")) "
                        + "matchesEverObserved=\(safeBoolean("matchesEverObserved")) "
                        + "matchesEverArray=\(safeBoolean("matchesEverArray"))")
            default:
                break
            }
        case "routerHydrationProbe":
            switch diagnostic["status"] as? String {
            case "bootstrap-observed":
                WebViewDiagnostics.log("router hydration probe status=bootstrap-observed")
            case "react-container-observed":
                WebViewDiagnostics.log("router hydration probe status=react-container-observed")
            case "initialized":
                WebViewDiagnostics.log("router hydration probe status=initialized")
            case "hydrated":
                WebViewDiagnostics.log("router hydration probe status=hydrated")
            case "bootstrap-deleted":
                WebViewDiagnostics.log("router hydration probe status=bootstrap-deleted")
            case "completion-not-observed":
                WebViewDiagnostics.log(
                    "router hydration probe status=completion-not-observed "
                        + "bootstrapObserved=\(safeBoolean("bootstrapObserved")) "
                        + "reactContainerMarkerObserved=\(safeBoolean("reactContainerMarkerObserved")) "
                        + "initializedPropertyObserved=\(safeBoolean("initializedPropertyObserved")) "
                        + "initializedTrueObserved=\(safeBoolean("initializedTrueObserved")) "
                        + "hydratedPropertyObserved=\(safeBoolean("hydratedPropertyObserved")) "
                        + "hydratedTrueObserved=\(safeBoolean("hydratedTrueObserved")) "
                        + "bootstrapDeletionObserved=\(safeBoolean("bootstrapDeletionObserved"))")
            default:
                break
            }
        default:
            break
        }
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
                const root = document.documentElement;
                const bodyRect = body ? body.getBoundingClientRect() : null;
                const bodyStyle = body ? getComputedStyle(body) : null;
                const hostPath = function (value) {
                    if (value === null || typeof value === "undefined") return "<unavailable>";
                    try {
                        const resourceURL = new URL(value, document.baseURI);
                        if (resourceURL.protocol !== "http:" && resourceURL.protocol !== "https:") {
                            return "<non-http resource>";
                        }
                        return resourceURL.host + (resourceURL.pathname || "/");
                    } catch (error) {
                        return "<unavailable>";
                    }
                };
                const availability = function (check) {
                    try {
                        return Boolean(check());
                    } catch (error) {
                        return false;
                    }
                };
                const scripts = Array.prototype.map.call(document.scripts, function (script, index) {
                    const hasSource = script.hasAttribute("src");
                    return {
                        index: index,
                        src: hasSource ? hostPath(script.getAttribute("src")) : "<inline>",
                        type: script.type || "",
                        async: Boolean(script.async),
                        defer: Boolean(script.defer),
                        nomodule: Boolean(script.noModule),
                        inlineTextLength: hasSource ? null : script.textContent.length
                    };
                });
                const stylesheetLinks = Array.prototype.map.call(
                    document.querySelectorAll('link[rel~="stylesheet"]'), function (link) {
                        return {
                            location: hostPath(link.getAttribute("href")),
                            media: link.media || ""
                        };
                    });
                const capabilities = {
                    fetch: availability(function () { return typeof window.fetch === "function"; }),
                    Promise: availability(function () { return typeof window.Promise === "function"; }),
                    WebAssembly: availability(function () { return typeof window.WebAssembly !== "undefined"; }),
                    BigInt: availability(function () { return typeof window.BigInt === "function"; }),
                    globalThis: availability(function () { return typeof globalThis !== "undefined"; }),
                    AbortController: availability(function () { return typeof window.AbortController === "function"; }),
                    TextEncoder: availability(function () { return typeof window.TextEncoder === "function"; }),
                    ResizeObserver: availability(function () { return typeof window.ResizeObserver === "function"; }),
                    IntersectionObserver: availability(function () { return typeof window.IntersectionObserver === "function"; }),
                    "crypto.subtle": availability(function () {
                        return typeof window.crypto !== "undefined" && Boolean(window.crypto.subtle);
                    }),
                    indexedDB: availability(function () { return typeof window.indexedDB !== "undefined" && Boolean(window.indexedDB); }),
                    "navigator.serviceWorker": availability(function () {
                        return typeof navigator !== "undefined" && Boolean(navigator.serviceWorker);
                    }),
                    localStorageAccess: availability(function () { return Boolean(window.localStorage); }),
                    sessionStorageAccess: availability(function () { return Boolean(window.sessionStorage); })
                };
                const bodyChildren = body ? Array.prototype.map.call(body.children, function (child) {
                    const rect = child.getBoundingClientRect();
                    const style = getComputedStyle(child);
                    return {
                        tag: String(child.tagName || "").toLowerCase(),
                        id: child.id || "",
                        className: child.getAttribute("class") || "",
                        width: rect.width,
                        height: rect.height,
                        display: style.display,
                        visibility: style.visibility,
                        opacity: style.opacity
                    };
                }) : [];
                return {
                    userAgent: navigator.userAgent,
                    readyState: document.readyState,
                    title: document.title,
                    host: window.location.host,
                    path: window.location.pathname,
                    bodyExists: body !== null,
                    bodyChildCount: body ? body.childNodes.length : null,
                    windowInnerWidth: window.innerWidth,
                    windowInnerHeight: window.innerHeight,
                    documentElementClientWidth: root ? root.clientWidth : null,
                    documentElementClientHeight: root ? root.clientHeight : null,
                    bodyRectWidth: bodyRect ? bodyRect.width : null,
                    bodyRectHeight: bodyRect ? bodyRect.height : null,
                    bodyScrollWidth: body ? body.scrollWidth : null,
                    bodyScrollHeight: body ? body.scrollHeight : null,
                    bodyDisplay: bodyStyle ? bodyStyle.display : null,
                    bodyVisibility: bodyStyle ? bodyStyle.visibility : null,
                    bodyOpacity: bodyStyle ? bodyStyle.opacity : null,
                    elementCount: document.querySelectorAll("*").length,
                    scriptCount: document.scripts.length,
                    stylesheetLinkCount: document.querySelectorAll('link[rel~="stylesheet"]').length,
                    bodyElementCount: body ? body.querySelectorAll("*").length : null,
                    hasDataReactRoot: document.querySelector("[data-reactroot]") !== null,
                    hasReactRoot: document.querySelector("#react-root") !== null,
                    hasRoot: document.querySelector("#root") !== null,
                    hasLayers: document.querySelector("#layers") !== null,
                    scripts: scripts,
                    stylesheetLinks: stylesheetLinks,
                    capabilities: capabilities,
                    bodyChildren: bodyChildren
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
            let layoutKeys = [
                "windowInnerWidth", "windowInnerHeight",
                "documentElementClientWidth", "documentElementClientHeight",
                "bodyRectWidth", "bodyRectHeight", "bodyScrollWidth", "bodyScrollHeight",
                "bodyDisplay", "bodyVisibility", "bodyOpacity"
            ]
            let layoutDiagnostics = layoutKeys.map { key in
                "\(key)=\(diagnostics[key].map { String(describing: $0) } ?? "<unavailable>")"
            }.joined(separator: " ")
            let structureKeys = [
                "elementCount", "scriptCount", "stylesheetLinkCount", "bodyElementCount",
                "hasDataReactRoot", "hasReactRoot", "hasRoot", "hasLayers"
            ]
            let structureDiagnostics = structureKeys.map { key in
                "\(key)=\(diagnostics[key].map { String(describing: $0) } ?? "<unavailable>")"
            }.joined(separator: " ")

            func diagnosticText(_ value: Any?) -> String {
                guard let value = value as? String else { return "<unavailable>" }
                return String(WebViewDiagnostics.sanitized(value).prefix(500))
            }

            func diagnosticNumber(_ value: Any?) -> String {
                guard let value = value as? NSNumber else { return "<unavailable>" }
                return value.stringValue
            }

            func diagnosticBoolean(_ value: Any?) -> String {
                guard let value = value as? Bool else { return "<unavailable>" }
                return value ? "true" : "false"
            }

            let scripts = diagnostics["scripts"] as? [[String: Any]] ?? []
            for script in scripts {
                let inlineLength = script["inlineTextLength"] is NSNull
                    ? "<not-inline>" : diagnosticNumber(script["inlineTextLength"])
                WebViewDiagnostics.log(
                    "script index=\(diagnosticNumber(script["index"])) "
                        + "src=\(diagnosticText(script["src"])) "
                        + "type=\(String(reflecting: diagnosticText(script["type"]))) "
                        + "async=\(diagnosticBoolean(script["async"])) "
                        + "defer=\(diagnosticBoolean(script["defer"])) "
                        + "nomodule=\(diagnosticBoolean(script["nomodule"])) "
                        + "inlineTextLength=\(inlineLength)")
            }

            let stylesheetLinks = diagnostics["stylesheetLinks"] as? [[String: Any]] ?? []
            for stylesheet in stylesheetLinks {
                WebViewDiagnostics.log(
                    "stylesheet location=\(diagnosticText(stylesheet["location"])) "
                        + "media=\(String(reflecting: diagnosticText(stylesheet["media"])))")
            }

            let capabilityKeys = [
                "fetch", "Promise", "WebAssembly", "BigInt", "globalThis", "AbortController",
                "TextEncoder", "ResizeObserver", "IntersectionObserver", "crypto.subtle", "indexedDB",
                "navigator.serviceWorker", "localStorageAccess", "sessionStorageAccess"
            ]
            let capabilities = diagnostics["capabilities"] as? [String: Any] ?? [:]
            let capabilityDiagnostics = capabilityKeys.map { key in
                "\(key)=\(diagnosticBoolean(capabilities[key]))"
            }.joined(separator: " ")
            WebViewDiagnostics.log("browser capabilities {\(capabilityDiagnostics)}")

            let bodyChildren = diagnostics["bodyChildren"] as? [[String: Any]] ?? []
            for child in bodyChildren {
                WebViewDiagnostics.log(
                    "body child tag=\(diagnosticText(child["tag"])) "
                        + "id=\(String(reflecting: diagnosticText(child["id"]))) "
                        + "class=\(String(reflecting: diagnosticText(child["className"]))) "
                        + "rect=\(diagnosticNumber(child["width"]))x\(diagnosticNumber(child["height"])) "
                        + "display=\(diagnosticText(child["display"])) "
                        + "visibility=\(diagnosticText(child["visibility"])) "
                        + "opacity=\(diagnosticText(child["opacity"]))")
            }

            WebViewDiagnostics.log(
                "didFinish JavaScript userAgent=\(String(reflecting: userAgent)) "
                    + "readyState=\(String(reflecting: readyState)) "
                    + "title=\(String(reflecting: title)) location=\(host)\(path) "
                    + "bodyExists=\(bodyExistsText) bodyChildCount=\(bodyChildCountText) "
                    + "layout {\(layoutDiagnostics)} structure {\(structureDiagnostics)}")
        }
    }

    private func scheduleResourceSnapshots(for webView: WKWebView) {
        guard owner.url.host == "x.com", owner.url.path == "/login" else { return }

        logResourceSnapshot(for: webView, elapsedLabel: "didFinish")
        let delayedSnapshots: [(TimeInterval, String)] = [(1, "1s"), (3, "3s"), (10, "10s")]
        for (delay, elapsedLabel) in delayedSnapshots {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                self.logResourceSnapshot(for: webView, elapsedLabel: elapsedLabel)
            }
        }
    }

    private func runTLADuplicateImportProbeOnce(for webView: WKWebView) {
        guard !didRunTLADuplicateImportProbe, isLoginFlowURL(webView.url) else { return }
        didRunTLADuplicateImportProbe = true

        let functionBody = #"""
            const importerDocument = document;
            let helperURL = null;
            let testURL = null;
            let startedObserved = false;
            let timedOut = false;
            let blobModuleRejected = false;
            let stopped = false;
            const completionOrder = [];
            const observations = Object.create(null);
            const notObserved = "<not-observed>";

            function safeErrorName(error) {
                try {
                    return error && typeof error.name === "string" ? error.name : "<unknown>";
                } catch (ignored) {
                    return "<unknown>";
                }
            }

            function makeResult(status) {
                function observationValue(label, key, fallback) {
                    const observation = observations[label];
                    return observation ? observation[key] : fallback;
                }
                return {
                    status: status,
                    startedObserved: startedObserved,
                    completionOrder: completionOrder.join(","),
                    firstTailRanAtFulfill: observationValue("first", "tailRanAtFulfill", notObserved),
                    firstSameDocument: observationValue("first", "sameDocument", notObserved),
                    firstTailSentinelReadable: observationValue("first", "tailSentinelReadable", notObserved),
                    firstTailSentinelErrorName: observationValue("first", "tailSentinelErrorName", notObserved),
                    secondTailRanAtFulfill: observationValue("second", "tailRanAtFulfill", notObserved),
                    secondSameDocument: observationValue("second", "sameDocument", notObserved),
                    secondTailSentinelReadable: observationValue("second", "tailSentinelReadable", notObserved),
                    secondTailSentinelErrorName: observationValue("second", "tailSentinelErrorName", notObserved),
                    timedOut: timedOut,
                    blobModuleRejected: blobModuleRejected
                };
            }

            function observeImport(label, importPromise, state) {
                return importPromise.then(function(moduleNamespace) {
                    if (stopped) return;

                    const tailRanAtFulfill = state.tailRan;
                    completionOrder.push(label);
                    let sameDocument = "<not-callable>";
                    if (typeof moduleNamespace.sameDocument === "function") {
                        try {
                            sameDocument = Boolean(moduleNamespace.sameDocument(importerDocument));
                        } catch (error) {
                            sameDocument = "<error:" + safeErrorName(error) + ">";
                        }
                    }

                    let tailSentinelReadable = false;
                    let tailSentinelErrorName = "<none>";
                    try {
                        void moduleNamespace.tailSentinel;
                        tailSentinelReadable = true;
                    } catch (error) {
                        tailSentinelErrorName = safeErrorName(error);
                    }

                    observations[label] = {
                        tailRanAtFulfill: tailRanAtFulfill,
                        sameDocument: sameDocument,
                        tailSentinelReadable: tailSentinelReadable,
                        tailSentinelErrorName: tailSentinelErrorName
                    };
                }, function() {
                    if (!stopped) blobModuleRejected = true;
                });
            }

            async function runProbe() {
                try {
                    helperURL = URL.createObjectURL(new Blob([
                        "export const state = { started: false, tailRan: false };"
                    ], { type: "text/javascript" }));

                    const testSource =
                        "import { state } from " + JSON.stringify(helperURL) + ";\n" +
                        "const moduleDocument = document;\n" +
                        "export const sameDocument = candidate => candidate === moduleDocument;\n" +
                        "state.started = true;\n" +
                        "await new Promise(resolve => setTimeout(resolve, 100));\n" +
                        "state.tailRan = true;\n" +
                        "export const tailSentinel = 1;\n";
                    testURL = URL.createObjectURL(new Blob([testSource], { type: "text/javascript" }));

                    const helperModule = await import(helperURL);
                    const state = helperModule.state;
                    const firstCompletion = observeImport("first", import(testURL), state);
                    const startDeadline = Date.now() + 750;
                    while (!state.started && !blobModuleRejected && !stopped && Date.now() < startDeadline) {
                        await new Promise(resolve => setTimeout(resolve, 5));
                    }

                    if (stopped) return makeResult("timeout");
                    if (blobModuleRejected) return makeResult("blocked");
                    if (!state.started) {
                        timedOut = true;
                        return makeResult("timeout");
                    }

                    startedObserved = true;
                    const secondCompletion = observeImport("second", import(testURL), state);
                    await Promise.all([firstCompletion, secondCompletion]);
                    return makeResult(blobModuleRejected ? "blocked" : "completed");
                } catch (ignored) {
                    blobModuleRejected = true;
                    return makeResult("blocked");
                }
            }

            let overallTimer = null;
            const overallTimeout = new Promise(resolve => {
                overallTimer = setTimeout(function() {
                    timedOut = true;
                    resolve(makeResult("timeout"));
                }, 2500);
            });

            let result;
            try {
                result = await Promise.race([runProbe(), overallTimeout]);
            } finally {
                stopped = true;
                if (overallTimer !== null) clearTimeout(overallTimer);
                if (testURL !== null) URL.revokeObjectURL(testURL);
                if (helperURL !== null) URL.revokeObjectURL(helperURL);
            }
            return result;
            """#

        webView.callAsyncJavaScript(
            functionBody,
            arguments: [:],
            in: nil,
            in: WKContentWorld.page) { result in
                switch result {
                case .success(let value):
                    guard let diagnostics = value as? [String: Any] else {
                        WebViewDiagnostics.log(
                            "tla duplicate-import probe status=invalid-result "
                                + "startedObserved=<not-observed> completionOrder=<not-observed> "
                                + "firstTailRanAtFulfill=<not-observed> firstSameDocument=<not-observed> "
                                + "firstTailSentinelReadable=<not-observed> firstTailSentinelErrorName=<not-observed> "
                                + "secondTailRanAtFulfill=<not-observed> secondSameDocument=<not-observed> "
                                + "secondTailSentinelReadable=<not-observed> secondTailSentinelErrorName=<not-observed> "
                                + "timedOut=false blobModuleRejected=false")
                        return
                    }

                    func diagnosticValue(_ key: String) -> String {
                        if let value = diagnostics[key] as? String {
                            return String(WebViewDiagnostics.sanitized(value).prefix(80))
                        }
                        if let value = diagnostics[key] as? Bool {
                            return value ? "true" : "false"
                        }
                        return "<not-observed>"
                    }

                    WebViewDiagnostics.log(
                        "tla duplicate-import probe status=\(diagnosticValue("status")) "
                            + "startedObserved=\(diagnosticValue("startedObserved")) "
                            + "completionOrder=\(diagnosticValue("completionOrder")) "
                            + "firstTailRanAtFulfill=\(diagnosticValue("firstTailRanAtFulfill")) "
                            + "firstSameDocument=\(diagnosticValue("firstSameDocument")) "
                            + "firstTailSentinelReadable=\(diagnosticValue("firstTailSentinelReadable")) "
                            + "firstTailSentinelErrorName=\(diagnosticValue("firstTailSentinelErrorName")) "
                            + "secondTailRanAtFulfill=\(diagnosticValue("secondTailRanAtFulfill")) "
                            + "secondSameDocument=\(diagnosticValue("secondSameDocument")) "
                            + "secondTailSentinelReadable=\(diagnosticValue("secondTailSentinelReadable")) "
                            + "secondTailSentinelErrorName=\(diagnosticValue("secondTailSentinelErrorName")) "
                            + "timedOut=\(diagnosticValue("timedOut")) "
                            + "blobModuleRejected=\(diagnosticValue("blobModuleRejected"))")
                case .failure:
                    WebViewDiagnostics.log(
                        "tla duplicate-import probe status=native-evaluation-failed "
                            + "startedObserved=false completionOrder=<not-observed> "
                            + "firstTailRanAtFulfill=<not-observed> firstSameDocument=<not-observed> "
                            + "firstTailSentinelReadable=<not-observed> firstTailSentinelErrorName=<not-observed> "
                            + "secondTailRanAtFulfill=<not-observed> secondSameDocument=<not-observed> "
                            + "secondTailSentinelReadable=<not-observed> secondTailSentinelErrorName=<not-observed> "
                            + "timedOut=false blobModuleRejected=false")
                }
            }
    }

    private func scheduleNativePageWorldProbe(for webView: WKWebView) {
        guard isLoginFlowURL(webView.url) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
            guard let self = self,
                  let webView = webView,
                  self.isLoginFlowURL(webView.url) else { return }

            let expression = #"""
                (() => {
                    let location = "<unavailable>";
                    const scripts = document.getElementsByTagName("script");
                    for (let index = 0; index < scripts.length; index += 1) {
                        const script = scripts[index];
                        if (String(script.type || "").toLowerCase() !== "module"
                            || !script.hasAttribute("src")
                            || script.src.indexOf("/entry-client-logged-out-") === -1) continue;
                        try {
                            const url = new URL(script.src);
                            if (url.protocol === "http:" || url.protocol === "https:") {
                                location = url.host + (url.pathname || "/");
                            }
                        } catch (ignored) {}
                        break;
                    }

                    let reactContainerMarkerPresent = false;
                    try {
                        const propertyNames = Object.getOwnPropertyNames(document);
                        for (let index = 0; index < propertyNames.length; index += 1) {
                            const propertyName = propertyNames[index];
                            if (propertyName.indexOf("__reactContainer$") !== 0) continue;
                            const descriptor = Object.getOwnPropertyDescriptor(document, propertyName);
                            if (descriptor
                                && Object.prototype.hasOwnProperty.call(descriptor, "value")) {
                                reactContainerMarkerPresent = true;
                                break;
                            }
                        }
                    } catch (ignored) {}

                    let bootstrapPresent = false;
                    let initializedPropertyPresent = false;
                    let initializedTrue = false;
                    try {
                        const bootstrapDescriptor = Object.getOwnPropertyDescriptor(window, "$_TSR");
                        if (bootstrapDescriptor
                            && Object.prototype.hasOwnProperty.call(bootstrapDescriptor, "value")) {
                            bootstrapPresent = true;
                            const bootstrap = bootstrapDescriptor.value;
                            if (bootstrap !== null && typeof bootstrap === "object") {
                                const initializedDescriptor = Object.getOwnPropertyDescriptor(bootstrap, "initialized");
                                if (initializedDescriptor
                                    && Object.prototype.hasOwnProperty.call(initializedDescriptor, "value")) {
                                    initializedPropertyPresent = true;
                                    initializedTrue = initializedDescriptor.value === true;
                                }
                            }
                        }
                    } catch (ignored) {}

                    let detachedDocumentExpandoObservable = false;
                    try {
                        const detachedDocument = document.implementation.createHTMLDocument("");
                        const expandoName = "__xdeckDetachedDocumentExpandoProbe__";
                        detachedDocument[expandoName] = true;
                        const detachedPropertyNames = Object.getOwnPropertyNames(detachedDocument);
                        if (detachedPropertyNames.indexOf(expandoName) !== -1) {
                            const detachedDescriptor = Object.getOwnPropertyDescriptor(
                                detachedDocument, expandoName);
                            detachedDocumentExpandoObservable = Boolean(detachedDescriptor
                                && Object.prototype.hasOwnProperty.call(detachedDescriptor, "value")
                                && detachedDescriptor.value === true);
                        }
                    } catch (ignored) {}

                    return {
                        location: location,
                        reactContainerMarkerPresent: reactContainerMarkerPresent,
                        bootstrapPresent: bootstrapPresent,
                        initializedPropertyPresent: initializedPropertyPresent,
                        initializedTrue: initializedTrue,
                        readyState: document.readyState,
                        windowIsTop: window === window.top,
                        detachedDocumentExpandoObservable: detachedDocumentExpandoObservable
                    };
                })()
                """#

            webView.evaluateJavaScript(expression, in: nil, in: WKContentWorld.page) { result in
                switch result {
                case .success(let value):
                    guard let diagnostics = value as? [String: Any] else {
                        WebViewDiagnostics.log("native page-world probe returned no dictionary")
                        return
                    }

                    func diagnosticString(_ key: String) -> String {
                        guard let value = diagnostics[key] as? String else { return "<unavailable>" }
                        return String(WebViewDiagnostics.sanitized(value).prefix(500))
                    }

                    func diagnosticBoolean(_ key: String) -> String {
                        guard let value = diagnostics[key] as? Bool else { return "<unavailable>" }
                        return value ? "true" : "false"
                    }

                    WebViewDiagnostics.log(
                        "native page-world probe "
                            + "location=\(diagnosticString("location")) "
                            + "reactContainerMarkerPresent=\(diagnosticBoolean("reactContainerMarkerPresent")) "
                            + "bootstrapPresent=\(diagnosticBoolean("bootstrapPresent")) "
                            + "initializedPropertyPresent=\(diagnosticBoolean("initializedPropertyPresent")) "
                            + "initializedTrue=\(diagnosticBoolean("initializedTrue")) "
                            + "readyState=\(diagnosticString("readyState")) "
                            + "windowIsTop=\(diagnosticBoolean("windowIsTop")) "
                            + "detachedDocumentExpandoObservable=\(diagnosticBoolean("detachedDocumentExpandoObservable"))")
                case .failure(let error):
                    WebViewDiagnostics.log(
                        "native page-world probe failed "
                            + String(WebViewDiagnostics.sanitized(error.localizedDescription).prefix(500)))
                }
            }
        }
    }

    private func scheduleCleanResourceTimingRead(for webView: WKWebView) {
        guard !didScheduleCleanResourceTimingRead, isLoginFlowURL(webView.url) else { return }
        didScheduleCleanResourceTimingRead = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak webView] in
            guard let webView = webView else { return }

            // The Safari-validated passive Sentry read, plus the toSorted shim state.
            let expression = #"""
                (() => {
                  const toSrc = f => { try { return Function.prototype.toString.call(f); } catch (e) { return ""; } };
                  const isNative = f => typeof f === "function" && /\[native code\]/.test(toSrc(f));
                  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

                  const entryEl = Array.prototype.find.call(document.scripts, s =>
                    String(s.type).toLowerCase() === "module" && s.src.indexOf("/entry-client-logged-out-") !== -1);
                  const entrySrc = entryEl ? entryEl.src.split("?")[0].replace(/^https?:\/\/[^/]+/, "") : "<none>";

                  const ids = window._sentryDebugIds;
                  const idValues = ids && typeof ids === "object" ? Object.values(ids) : [];
                  const started = id => idValues.indexOf(id) !== -1;

                  const rtNames = performance.getEntriesByType("resource").map(e => String(e.name).split("?")[0]);
                  const rtHas = file => rtNames.some(n => n.endsWith("/" + file));

                  const lang = document.documentElement.getAttribute("lang");
                  const isJa = String(lang || "").toLowerCase().indexOf("ja") === 0;
                  const locales = isJa
                    ? [["ja-D0XYHMW4.js", "bef64fd3-840c-4939-8a19-91c0c2a4fa3b"],
                       ["ja-DfUnl03v.js", "a2ac435c-3b43-4c5f-b3fc-46cb575e8bc4"],
                       ["ja-CfgzxN8m.js", "9d28a81d-fed6-444d-ad57-fee53edf7d92"],
                       ["ja-9hSKK9vH.js", "03a4c116-8e70-4f02-9634-5d5ea0281d33"]]
                    : [["en-CZvhHm-V.js", "a03ff173-3e89-4dde-882e-87300b32cebc"],
                       ["en-BwDj8DEf.js", "4f0f3486-4fa8-435f-a94b-932b7913dc76"],
                       ["en-BPFwhnqE.js", "60f4ffdc-f5cc-4b70-8bce-67d144e49331"],
                       ["en-CFbtUrW8.js", "cc2df4ed-0bda-4c20-9612-36b8d0fe6ed5"]];

                  let reactContainerMarkerPresent = false;
                  for (const name of Object.getOwnPropertyNames(document)) {
                    if (name.indexOf("__reactContainer$") === 0) { reactContainerMarkerPresent = true; break; }
                  }

                  const releaseDesc = Object.getOwnPropertyDescriptor(window, "SENTRY_RELEASE");
                  const release = releaseDesc && own(releaseDesc, "value") ? releaseDesc.value : undefined;
                  const lastDesc = Object.getOwnPropertyDescriptor(window, "_sentryDebugIdIdentifier");

                  return JSON.stringify({
                    entrySrc: entrySrc,
                    sentryRelease: release && typeof release === "object" ? String(release.id) : "<none>",
                    lastStartedModule: lastDesc && own(lastDesc, "value") ? String(lastDesc.value) : "<none>",
                    debugIdCount: idValues.length,
                    entryStarted: started("535f7c0f-29c1-4942-9c95-82b6ea1deb19"),
                    viewAsStarted: started("de6ca102-e554-45de-9803-a9403866bbf3"),
                    urlParseOwn: own(URL, "parse"),
                    urlParseSrc: toSrc(URL.parse).slice(0, 80),
                    errorIsErrorOwn: own(Error, "isError"),
                    errorIsErrorNative: isNative(Error.isError),
                    withResolversOwn: own(Promise, "withResolvers"),
                    withResolversNative: isNative(Promise.withResolvers),
                    ricNative: isNative(window.requestIdleCallback),
                    hasGtCookie: /(?:^|;\s*)gt=/.test(document.cookie),
                    guestActivatePresent: rtNames.some(n => n.endsWith("/1.1/guest/activate.json")),
                    lang: lang === null ? "<null>" : lang,
                    localeResource: locales.map(l => l[0] + "=" + rtHas(l[0])).join(","),
                    localeStarted: locales.map(l => l[0] + "=" + started(l[1])).join(","),
                    headerlessResource: rtHas("_headerless-DplpFx2F.js"),
                    headerlessStarted: started("eab8de91-acf3-45ac-971d-ad085c543528"),
                    webComponentResource: rtHas("web-DBVXEWWD.js"),
                    webComponentStarted: started("42b1c795-2fed-4241-95ac-2d319d356d93"),
                    rtCount: rtNames.length,
                    resourceTimingBufferSaturated: rtNames.length >= 2000,
                    reactContainerMarkerPresent: reactContainerMarkerPresent,
                    toSortedType: typeof Array.prototype.toSorted,
                    toSortedKind: typeof Array.prototype.toSorted !== "function" ? "missing"
                      : (isNative(Array.prototype.toSorted) ? "native" : "js")
                  });
                })()
                """#

            webView.evaluateJavaScript(expression, in: nil, in: WKContentWorld.page) { result in
                switch result {
                case .success(let value):
                    guard let json = value as? String else {
                        WebViewDiagnostics.log("toSorted shim read returned no string")
                        return
                    }
                    // Logged verbatim so it stays comparable with the earlier passive reads; the JSON
                    // holds only booleans, counts, debug IDs, a script path and the lang attribute.
                    WebViewDiagnostics.log("toSorted shim read +10s \(json)")
                case .failure(let error):
                    WebViewDiagnostics.log(
                        "toSorted shim read failed "
                            + String(WebViewDiagnostics.sanitized(error.localizedDescription).prefix(500)))
                }
            }
        }
    }

    private func isLoginFlowURL(_ url: URL?) -> Bool {
        guard let url = url, url.host == "x.com" else { return false }
        return url.path == "/login" || url.path == "/i/jf/onboarding/web"
    }

    private func logResourceSnapshot(for webView: WKWebView, elapsedLabel: String) {
        let expression = """
            (() => {
                const body = document.body;
                const safeLocation = function (value) {
                    try {
                        const url = new URL(value, window.location.href);
                        if (url.protocol !== "http:" && url.protocol !== "https:") {
                            return "<non-http resource>";
                        }
                        return url.host + (url.pathname || "/");
                    } catch (error) {
                        return "<unavailable>";
                    }
                };
                const entries = performance.getEntriesByType("resource");
                const jetfuelStylesheets = Array.prototype.filter.call(
                    document.querySelectorAll('link[rel~="stylesheet"]'), function (link) {
                        try {
                            const stylesheetURL = new URL(link.href, window.location.href);
                            return stylesheetURL.pathname.indexOf("/use-jetfuel-dev-") !== -1;
                        } catch (error) {
                            return false;
                        }
                    });
                const jetfuelStylesheet = jetfuelStylesheets.length > 0 ? jetfuelStylesheets[0] : null;
                const matchingResources = [];
                entries.forEach(function (entry) {
                    try {
                        const resourceURL = new URL(entry.name, window.location.href);
                        if (resourceURL.protocol !== "http:" && resourceURL.protocol !== "https:") return;
                        const pathname = resourceURL.pathname || "/";
                        const lowerPathname = pathname.toLowerCase();
                        if (lowerPathname.indexOf("jetfuel") !== -1
                            || lowerPathname.indexOf("onboarding") !== -1
                            || lowerPathname.indexOf("wrapper") !== -1) {
                            matchingResources.push({
                                initiatorType: String(entry.initiatorType || "<unknown>"),
                                location: resourceURL.host + pathname
                            });
                        }
                    } catch (error) {}
                });
                const resources = entries.map(function (entry) {
                    return {
                        initiatorType: String(entry.initiatorType || "<unknown>"),
                        location: safeLocation(entry.name),
                        duration: Math.round(entry.duration),
                        transferSize: entry.transferSize,
                        encodedBodySize: entry.encodedBodySize,
                        decodedBodySize: entry.decodedBodySize
                    };
                });
                const resourcePriority = function (resource) {
                    if (resource.location.indexOf("/entry-client-logged-out-") !== -1
                        && resource.location.endsWith(".js")) return 0;
                    if (resource.initiatorType === "link" || resource.location.endsWith(".css")) return 1;
                    if (resource.initiatorType === "fetch" || resource.initiatorType === "xmlhttprequest") return 2;
                    return 3;
                };
                resources.sort(function (left, right) {
                    return resourcePriority(left) - resourcePriority(right);
                });

                const counts = {};
                entries.forEach(function (entry) {
                    const type = String(entry.initiatorType || "<unknown>");
                    counts[type] = (counts[type] || 0) + 1;
                });
                const initiatorCounts = Object.keys(counts).sort().map(function (type) {
                    return { initiatorType: type, count: counts[type] };
                });

                return {
                    urlParseType: typeof URL.parse,
                    urlCanParseType: typeof URL.canParse,
                    jetfuelCSSLinkPresent: jetfuelStylesheet !== null,
                    jetfuelCSSLoaded: jetfuelStylesheet ? jetfuelStylesheet.sheet !== null : null,
                    matchingResources: matchingResources,
                    readyState: document.readyState,
                    elementCount: document.querySelectorAll("*").length,
                    bodyDescendantElementCount: body ? body.querySelectorAll("*").length : null,
                    hasLayers: document.querySelector("#layers") !== null,
                    hasRoot: document.querySelector("#root") !== null,
                    hasReactRoot: document.querySelector("#react-root") !== null,
                    bodyScrollWidth: body ? body.scrollWidth : null,
                    bodyScrollHeight: body ? body.scrollHeight : null,
                    resources: resources,
                    initiatorCounts: initiatorCounts
                };
            })()
            """

        webView.evaluateJavaScript(expression) { result, error in
            if let error = error {
                let nsError = error as NSError
                WebViewDiagnostics.log(
                    "snapshot elapsed=\(elapsedLabel) diagnostic failed NSError "
                        + "domain=\(String(reflecting: nsError.domain)) code=\(nsError.code) "
                        + "localizedDescription=\(String(reflecting: WebViewDiagnostics.sanitized(nsError.localizedDescription)))")
                return
            }

            guard let diagnostics = result as? [String: Any] else {
                WebViewDiagnostics.log("snapshot elapsed=\(elapsedLabel) returned no dictionary")
                return
            }

            func safeText(_ value: Any?) -> String {
                guard let value = value as? String else { return "<unavailable>" }
                return String(WebViewDiagnostics.sanitized(value).prefix(500))
            }

            func safeNumber(_ value: Any?) -> String {
                guard let value = value as? NSNumber else { return "<unavailable>" }
                return value.stringValue
            }

            func safeBoolean(_ value: Any?) -> String {
                guard let value = value as? Bool else { return "<unavailable>" }
                return value ? "true" : "false"
            }

            WebViewDiagnostics.log(
                "snapshot elapsed=\(elapsedLabel) "
                    + "readyState=\(safeText(diagnostics["readyState"])) "
                    + "elementCount=\(safeNumber(diagnostics["elementCount"])) "
                    + "bodyDescendantElementCount=\(safeNumber(diagnostics["bodyDescendantElementCount"])) "
                    + "hasLayers=\(safeBoolean(diagnostics["hasLayers"])) "
                    + "hasRoot=\(safeBoolean(diagnostics["hasRoot"])) "
                    + "hasReactRoot=\(safeBoolean(diagnostics["hasReactRoot"])) "
                    + "bodyScrollWidth=\(safeNumber(diagnostics["bodyScrollWidth"])) "
                    + "bodyScrollHeight=\(safeNumber(diagnostics["bodyScrollHeight"]))")

            let jetfuelCSSLinkPresent = safeBoolean(diagnostics["jetfuelCSSLinkPresent"])
            let jetfuelCSSLoaded: String
            if diagnostics["jetfuelCSSLinkPresent"] as? Bool == false {
                jetfuelCSSLoaded = "<link-absent>"
            } else {
                jetfuelCSSLoaded = safeBoolean(diagnostics["jetfuelCSSLoaded"])
            }
            WebViewDiagnostics.log(
                "snapshot elapsed=\(elapsedLabel) "
                    + "URL.parse=\(safeText(diagnostics["urlParseType"])) "
                    + "URL.canParse=\(safeText(diagnostics["urlCanParseType"])) "
                    + "jetfuelCSSLinkPresent=\(jetfuelCSSLinkPresent) "
                    + "jetfuelCSSLoaded=\(jetfuelCSSLoaded)")

            let matchingResources = diagnostics["matchingResources"] as? [[String: Any]] ?? []
            for resource in matchingResources {
                WebViewDiagnostics.log(
                    "matching resource elapsed=\(elapsedLabel) "
                        + "initiatorType=\(safeText(resource["initiatorType"])) "
                        + "location=\(safeText(resource["location"]))")
            }

            let resources = diagnostics["resources"] as? [[String: Any]] ?? []
            for resource in resources {
                WebViewDiagnostics.log(
                    "resource elapsed=\(elapsedLabel) "
                        + "initiatorType=\(safeText(resource["initiatorType"])) "
                        + "location=\(safeText(resource["location"])) "
                        + "durationMs=\(safeNumber(resource["duration"])) "
                        + "transferSize=\(safeNumber(resource["transferSize"])) "
                        + "encodedBodySize=\(safeNumber(resource["encodedBodySize"])) "
                        + "decodedBodySize=\(safeNumber(resource["decodedBodySize"]))")
            }

            let counts = diagnostics["initiatorCounts"] as? [[String: Any]] ?? []
            let countSummary = counts.map { count in
                "\(safeText(count["initiatorType"]))=\(safeNumber(count["count"]))"
            }.joined(separator: " ")
            WebViewDiagnostics.log(
                "resource initiator counts elapsed=\(elapsedLabel) "
                    + (countSummary.isEmpty ? "<none>" : countSummary))
        }
    }
}
