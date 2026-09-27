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

            // Observe only stylesheet links, without changing their attributes or insertion behavior.
            if (window === window.top) {
                var loggedStylesheetEvents = Object.create(null);
                var observedJetfuelLinks = new WeakSet();
                var observedHead = null;
                var observedDocumentElement = null;
                var waitingForDocumentElement = false;
                var headObserver = new MutationObserver(function(records) {
                    records.forEach(function(record) {
                        Array.prototype.forEach.call(record.addedNodes, inspectHeadAddedNode);
                    });
                });
                var documentElementObserver = new MutationObserver(function(records) {
                    if (!observedDocumentElement) {
                        attachDocumentElementObserver();
                        return;
                    }
                    records.forEach(function(record) {
                        Array.prototype.forEach.call(record.addedNodes, inspectDocumentTreeNode);
                    });
                });

                function isStylesheetLink(element) {
                    try {
                        if (!element || element.nodeType !== 1
                            || String(element.tagName || "").toUpperCase() !== "LINK") return false;
                        var rel = String(element.rel || element.getAttribute("rel") || "").toLowerCase();
                        return rel.split(/\s+/).indexOf("stylesheet") !== -1;
                    } catch (ignored) {
                        return false;
                    }
                }

                function stylesheetInfo(element) {
                    try {
                        if (!isStylesheetLink(element)) return null;
                        var href = element.getAttribute("href") || element.href;
                        if (!href) return null;
                        var url = new URL(href, document.baseURI);
                        var pathname = url.pathname || "/";
                        return {
                            location: url.host + pathname,
                            jetfuel: pathname.toLowerCase().indexOf("use-jetfuel-dev-") !== -1
                        };
                    } catch (ignored) {
                        return null;
                    }
                }

                function sendStylesheetEvent(eventName, info) {
                    var key = JSON.stringify([info.location, eventName]);
                    if (loggedStylesheetEvents[key]) return;
                    loggedStylesheetEvents[key] = true;
                    if (eventName === "insert") {
                        sendDiagnostic({
                            type: "stylesheetInsertion",
                            location: info.location,
                            jetfuel: info.jetfuel
                        });
                    } else {
                        sendDiagnostic({
                            type: "jetfuelStylesheetEvent",
                            event: eventName,
                            location: info.location
                        });
                    }
                }

                function observeInsertedStylesheet(element) {
                    try {
                        if (!element || !element.isConnected) return;
                        var info = stylesheetInfo(element);
                        if (!info) return;
                        sendStylesheetEvent("insert", info);
                        if (!info.jetfuel || observedJetfuelLinks.has(element)) return;
                        observedJetfuelLinks.add(element);
                        element.addEventListener("load", function() {
                            sendStylesheetEvent("load", info);
                        });
                        element.addEventListener("error", function() {
                            sendStylesheetEvent("error", info);
                        });
                    } catch (ignored) {}
                }

                function inspectHeadAddedNode(node) {
                    try {
                        if (isStylesheetLink(node)) observeInsertedStylesheet(node);
                        if (!node || typeof node.querySelectorAll !== "function") return;
                        Array.prototype.forEach.call(
                            node.querySelectorAll('link[rel~="stylesheet"]'), observeInsertedStylesheet);
                    } catch (ignored) {}
                }

                function inspectDocumentTreeNode(node) {
                    try {
                        if (!node) return;
                        if (String(node.tagName || "").toUpperCase() === "HEAD") {
                            attachHeadObserver();
                            return;
                        }
                        if (isStylesheetLink(node)) observeInsertedStylesheet(node);
                        if (typeof node.querySelectorAll !== "function") return;
                        Array.prototype.forEach.call(
                            node.querySelectorAll('head, link[rel~="stylesheet"]'), function(element) {
                                if (String(element.tagName || "").toUpperCase() === "HEAD") {
                                    attachHeadObserver();
                                } else {
                                    observeInsertedStylesheet(element);
                                }
                            });
                    } catch (ignored) {}
                }

                function captureDirectStylesheetLinks(node) {
                    var links = [];
                    try {
                        if (isStylesheetLink(node)) {
                            links.push(node);
                        } else if (node && node.nodeType === 11) {
                            Array.prototype.forEach.call(node.childNodes, function(child) {
                                if (isStylesheetLink(child)) {
                                    links.push(child);
                                }
                            });
                        }
                    } catch (ignored) {}
                    return links;
                }

                function attachHeadObserver() {
                    try {
                        var head = document.head;
                        if (!head) return;
                        if (head !== observedHead) {
                            if (observedHead) headObserver.disconnect();
                            observedHead = head;
                            inspectHeadAddedNode(head);
                            headObserver.observe(head, {childList: true, subtree: true});
                        }
                        if (observedDocumentElement || waitingForDocumentElement) {
                            documentElementObserver.disconnect();
                            observedDocumentElement = null;
                            waitingForDocumentElement = false;
                        }
                    } catch (ignored) {}
                }

                function attachDocumentElementObserver() {
                    try {
                        var root = document.documentElement;
                        if (!root) {
                            if (!waitingForDocumentElement) {
                                waitingForDocumentElement = true;
                                documentElementObserver.observe(document, {childList: true});
                            }
                            return;
                        }
                        if (root === observedDocumentElement) return;
                        documentElementObserver.disconnect();
                        waitingForDocumentElement = false;
                        observedDocumentElement = root;
                        documentElementObserver.observe(root, {childList: true, subtree: true});
                        inspectDocumentTreeNode(root);
                    } catch (ignored) {}
                }

                // Document.prototype.createElement is not used as evidence: rel is usually set after createElement("link").
                function wrapInsertionMethod(methodName) {
                    try {
                        var originalMethod = Node.prototype[methodName];
                        if (typeof originalMethod !== "function") return;
                        Node.prototype[methodName] = function() {
                            var insertedNode = arguments[0];
                            var stylesheetLinks = captureDirectStylesheetLinks(insertedNode);
                            var result = originalMethod.apply(this, arguments);
                            try {
                                attachHeadObserver();
                                stylesheetLinks.forEach(observeInsertedStylesheet);
                                if (this === document.head) inspectHeadAddedNode(insertedNode);
                            } catch (ignored) {}
                            return result;
                        };
                    } catch (ignored) {}
                }

                wrapInsertionMethod("appendChild");
                wrapInsertionMethod("insertBefore");
                attachDocumentElementObserver();
            }

            var parsePolyfilled = false;
            var canParsePolyfilled = false;
            if (window === window.top && typeof URL === "function") {
                if (typeof URL.canParse !== "function") {
                    try {
                        URL.canParse = function(input, base) {
                            try {
                                if (arguments.length >= 2) {
                                    new URL(input, base);
                                } else {
                                    new URL(input);
                                }
                                return true;
                            } catch (ignored) {
                                return false;
                            }
                        };
                        canParsePolyfilled = typeof URL.canParse === "function";
                    } catch (ignored) {}
                }

                if (typeof URL.parse !== "function") {
                    try {
                        URL.parse = function(input, base) {
                            try {
                                if (arguments.length >= 2) {
                                    return new URL(input, base);
                                }
                                return new URL(input);
                            } catch (ignored) {
                                return null;
                            }
                        };
                        parsePolyfilled = typeof URL.parse === "function";
                    } catch (ignored) {}
                }

                if (window.console && typeof window.console.log === "function") {
                    window.console.log(
                        "[XDeck WebView] URL compatibility probe "
                            + "parsePolyfilled=" + parsePolyfilled
                            + " canParsePolyfilled=" + canParsePolyfilled);
                }
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

                var routeModuleProbeStarted = false;
                var routeModulePostImportStateReported = false;

                function reportRouteModulePostImportState() {
                    if (routeModulePostImportStateReported) return;
                    routeModulePostImportStateReported = true;
                    var body = document.body;
                    var jetfuelElements = document.querySelectorAll('[class*="jf-element"]');
                    var visibleJetfuelElementCount = 0;
                    Array.prototype.forEach.call(jetfuelElements, function(element) {
                        try {
                            var rect = element.getBoundingClientRect();
                            var style = window.getComputedStyle(element);
                            if (rect.width > 0 && rect.height > 0
                                && style.display !== "none"
                                && style.visibility !== "hidden"
                                && Number(style.opacity) > 0) {
                                visibleJetfuelElementCount += 1;
                            }
                        } catch (ignored) {}
                    });
                    var jetfuelStylesheetPresent = false;
                    Array.prototype.forEach.call(
                        document.querySelectorAll('link[rel~="stylesheet"]'), function(link) {
                            try {
                                var stylesheetURL = new URL(link.href, document.baseURI);
                                if (stylesheetURL.pathname.toLowerCase().indexOf("use-jetfuel-dev-") !== -1) {
                                    jetfuelStylesheetPresent = true;
                                }
                            } catch (ignored) {}
                        });
                    sendDiagnostic({
                        type: "routeModulePostImportState",
                        elementCount: document.querySelectorAll("*").length,
                        bodyDescendantElementCount: body ? body.querySelectorAll("*").length : null,
                        jetfuelElementCount: jetfuelElements.length,
                        visibleJetfuelElementCount: visibleJetfuelElementCount,
                        pageVisible: visibleJetfuelElementCount > 0,
                        jetfuelStylesheetPresent: jetfuelStylesheetPresent,
                        hasLayers: document.querySelector("#layers") !== null
                    });
                }

                function reportRouteModuleProbeResult(payload) {
                    sendDiagnostic(payload);
                    window.setTimeout(reportRouteModulePostImportState, 250);
                    window.setTimeout(probeRouteLazyLoader, 1000);
                }

                function isExplicitModuleNetworkFailure(name, message) {
                    var description = (name + " " + message).toLowerCase();
                    return /importing a module script failed|failed to fetch dynamically imported module|failed to load module script|networkerror|network error|load failed|\b404\b|not found|timed out|timeout/.test(description);
                }

                function probeRouteModuleEvaluation() {
                    if (routeModuleProbeStarted) return;
                    routeModuleProbeStarted = true;
                    var routeModuleURL = "https://abs.twimg.com/x-web/x-web/assets/web-D93GVrdd.js";
                    var routeModuleLocation = safeLocation(routeModuleURL);
                    import(routeModuleURL).then(function() {
                        reportRouteModuleProbeResult({
                            type: "routeModuleEvaluationProbe",
                            status: "resolved",
                            location: routeModuleLocation
                        });
                    }, function(error) {
                        var name = "<unknown>";
                        var message = "<unavailable>";
                        try {
                            if (error && typeof error.name === "string") name = error.name;
                            if (error && typeof error.message === "string") message = error.message;
                        } catch (ignored) {}
                        reportRouteModuleProbeResult({
                            type: "routeModuleEvaluationProbe",
                            status: "rejected",
                            location: routeModuleLocation,
                            name: safeText(name),
                            message: safeText(message),
                            failureKind: isExplicitModuleNetworkFailure(name, message) ? "network-failure" : "module-rejection"
                        });
                    });
                }

                window.addEventListener("load", function() {
                    window.setTimeout(probeRouteModuleEvaluation, 3000);
                }, true);

                var routeLazyLoaderProbeStarted = false;

                function reportRouteLazyLoaderRejected(error) {
                    var name = "<unknown>";
                    var message = "<unavailable>";
                    try {
                        if (typeof error === "string") {
                            message = error;
                        } else if (error) {
                            if (typeof error.name === "string") name = error.name;
                            if (typeof error.message === "string") message = error.message;
                        }
                    } catch (ignored) {}
                    sendDiagnostic({
                        type: "routeLazyLoaderProbe",
                        status: "rejected",
                        name: safeText(name),
                        message: safeText(message)
                    });
                }

                function invokeRouteLazyLoader(routeModule) {
                    var route = routeModule && routeModule.t;
                    var component = route && route.options && route.options.component;
                    if (!component) {
                        throw new Error("onboarding route component is unavailable in route manifest");
                    }
                    if (typeof component.preload !== "function") {
                        reportRouteLazyLoaderRejected(
                            new Error("onboarding route component preload function is unavailable"));
                        return;
                    }

                    var preloadFailure = null;
                    function observePreloadFailure(event) {
                        if (event && event.payload && !preloadFailure) preloadFailure = event.payload;
                    }
                    window.addEventListener("vite:preloadError", observePreloadFailure);

                    var preloadPromise;
                    try {
                        preloadPromise = component.preload();
                    } catch (error) {
                        window.removeEventListener("vite:preloadError", observePreloadFailure);
                        reportRouteLazyLoaderRejected(error);
                        return;
                    }

                    Promise.resolve(preloadPromise).then(function() {
                        window.removeEventListener("vite:preloadError", observePreloadFailure);
                        if (preloadFailure) {
                            reportRouteLazyLoaderRejected(preloadFailure);
                        } else {
                            sendDiagnostic({type: "routeLazyLoaderProbe", status: "resolved"});
                        }
                    }, function(error) {
                        window.removeEventListener("vite:preloadError", observePreloadFailure);
                        reportRouteLazyLoaderRejected(error);
                    });
                }

                function probeRouteLazyLoader() {
                    if (routeLazyLoaderProbeStarted) return;
                    routeLazyLoaderProbeStarted = true;
                    sendDiagnostic({type: "routeLazyLoaderProbe", status: "started"});
                    import("https://abs.twimg.com/x-web/x-web/assets/web-Bts3i53A.js")
                        .then(invokeRouteLazyLoader)
                        .catch(reportRouteLazyLoaderRejected);
                }

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
