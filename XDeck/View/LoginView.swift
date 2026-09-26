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
                    if (String(target.tagName || "").toLowerCase() === "script"
                        && String(target.type || "").toLowerCase() === "module"
                        && String(target.src || "").indexOf("/entry-client-logged-out-") !== -1) return;
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

            function findEntryModule() {
                var scripts = document.getElementsByTagName("script");
                for (var index = 0; index < scripts.length; index += 1) {
                    var script = scripts[index];
                    if (String(script.type || "").toLowerCase() === "module"
                        && script.hasAttribute("src")
                        && script.src.indexOf("/entry-client-logged-out-") !== -1) {
                        return script;
                    }
                }
                return null;
            }

            if (window === window.top) {
                function observeEntryModuleEvent(event) {
                    var script = event.target;
                    if (!script || String(script.tagName || "").toLowerCase() !== "script") return;
                    var entryModule = findEntryModule();
                    if (!entryModule || script !== entryModule) return;
                    if (event.type !== "load" && event.type !== "error") return;
                    sendDiagnostic({
                        type: "entryModuleEvent",
                        event: event.type,
                        location: safeLocation(script.src)
                    });
                }

                window.addEventListener("load", observeEntryModuleEvent, true);
                window.addEventListener("error", observeEntryModuleEvent, true);

                function probeEntryModuleEvaluation() {
                    var entryModule = findEntryModule();
                    if (!entryModule) {
                        sendDiagnostic({
                            type: "moduleEvaluationProbe",
                            status: "entry-module-not-found"
                        });
                        return;
                    }

                    import(entryModule.src).then(function() {
                        sendDiagnostic({
                            type: "moduleEvaluationProbe",
                            status: "resolved"
                        });
                    }, function(error) {
                        var name = "<unknown>";
                        var message = "<unavailable>";
                        try {
                            if (error && typeof error.name === "string") name = error.name;
                            if (error && typeof error.message === "string") message = error.message;
                        } catch (ignored) {}
                        sendDiagnostic({
                            type: "moduleEvaluationProbe",
                            status: "rejected",
                            name: safeText(name),
                            message: safeText(message)
                        });
                    });
                }

                window.addEventListener("load", function() {
                    window.setTimeout(probeEntryModuleEvaluation, 3000);
                }, true);
            }

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
