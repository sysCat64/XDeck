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
                WebViewDiagnostics.log("module evaluation probe status=resolved")
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
