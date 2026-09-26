import SwiftUI
import WebKit

struct LoginView: View {
    @State var isLoading: Bool = false
    @State var url: URL = URL(string: "https://x.com/login")!
    @State var scriptExecutionRequest: String? = nil
    @Binding var isShowingAlert: Bool
    @Binding var alertMessage: String?
    @Binding var loginViewMessage: String?

    private var diagnosticConfiguration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let script = WKUserScript(
            source: Self.runtimeDiagnosticsScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
        return configuration
    }

    private static let runtimeDiagnosticsScript = #"""
        (function() {
            function safeLocation(value) {
                if (!value) return "<unavailable>";
                try {
                    var url = new URL(value, window.location.href);
                    if (url.protocol !== "http:" && url.protocol !== "https:") {
                        return "<non-http resource>";
                    }
                    return url.host + (url.pathname || "/");
                } catch (ignored) {
                    return "<unavailable>";
                }
            }

            function safeText(value) {
                var text = typeof value === "string" ? value : "";
                text = text.replace(/https?:\/\/[^\s"'<>]+/gi, function(url) {
                    return safeLocation(url);
                });
                text = text.replace(/\?[^\s"'<>]*/g, "?<redacted>");
                text = text.replace(/\b(bearer|basic)\s+[A-Za-z0-9._~+\/=-]+/gi, "$1=<redacted>");
                text = text.replace(/\b(cookie|set-cookie|authorization|proxy-authorization|password|passwd|token|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|api[_-]?key|credential)\s*[:=]\s*[^\s,;]+/gi, "$1=<redacted>");
                return text.replace(/[\r\n]+/g, " ").slice(0, 500);
            }

            function sendDiagnostic(payload) {
                try {
                    var webkit = window.webkit;
                    var handlers = webkit && webkit.messageHandlers;
                    var handler = handlers && handlers["\#(WebViewConfigurations.handlerName)"];
                    if (!handler) return;
                    payload.channel = "xdeck-runtime-diagnostic";
                    handler.postMessage(payload);
                } catch (ignored) {}
            }

            window.addEventListener("error", function(event) {
                var target = event.target;
                if (target && target !== window && target.nodeType === 1) {
                    var resource = target.currentSrc || target.src || target.href || target.data || target.poster;
                    sendDiagnostic({
                        type: "resourceLoadFailure",
                        element: String(target.tagName || "unknown").toLowerCase(),
                        location: safeLocation(resource)
                    });
                    return;
                }

                var errorName = "Error";
                try {
                    if (event.error && typeof event.error.name === "string") errorName = event.error.name;
                } catch (ignored) {}
                sendDiagnostic({
                    type: "javascriptError",
                    name: safeText(errorName),
                    message: safeText(event.message || "<unavailable>"),
                    location: safeLocation(event.filename),
                    line: Number(event.lineno) || 0,
                    column: Number(event.colno) || 0
                });
            }, true);

            window.addEventListener("unhandledrejection", function(event) {
                var name = "<unknown>";
                var message = "<unavailable>";
                var reason = event.reason;
                if (typeof reason === "string" || typeof reason === "number" || typeof reason === "boolean") {
                    message = String(reason);
                } else if (reason && typeof reason === "object") {
                    try {
                        if (typeof reason.name === "string") name = reason.name;
                        if (typeof reason.message === "string") message = reason.message;
                    } catch (ignored) {}
                }
                sendDiagnostic({
                    type: "unhandledPromiseRejection",
                    name: safeText(name),
                    message: safeText(message)
                });
            });
        })();
        """#

    var body: some View {
        VStack {
            WebView(
                isLoading: $isLoading, url: $url, alertMessage: $alertMessage,
                messageFromWebView: $loginViewMessage,
                scriptExecutionRequest: scriptExecutionRequest,
                configuration: diagnosticConfiguration)
        }
        .padding()
        .onChange(of: alertMessage) { message in
            isShowingAlert = message != nil
        }
    }
}
