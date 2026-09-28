import Foundation
import WebKit

struct WebViewConfigurations {
    enum OnLoadScript {
        case global
        case findUserName
        case findThemeColor
        case clickForYouTab
        case hidePostArea
        case clickFollowingTab
        case hideSideHeader
        case hideAds
        case detectMediaOverlay(columnIndex: Int)
        case loginLayoutDiagnostic

        var scriptContent: String {
            switch self {
            case .global: return WebViewConfigurations.global
            case .findUserName: return WebViewConfigurations.findUserName
            case .findThemeColor: return WebViewConfigurations.findThemeColor
            case .clickForYouTab: return WebViewConfigurations.clickForYouTab
            case .hidePostArea: return WebViewConfigurations.hidePostArea
            case .clickFollowingTab: return WebViewConfigurations.clickFollowingTab
            case .hideSideHeader: return WebViewConfigurations.hideSideHeader
            case .hideAds: return WebViewConfigurations.hideAds
            case .detectMediaOverlay(let columnIndex): return WebViewConfigurations.detectMediaOverlay(columnIndex: columnIndex)
            case .loginLayoutDiagnostic: return WebViewConfigurations.loginLayoutDiagnostic
            }
        }

        var runAfterLoad: Bool {
            switch self {
            case .findUserName, .findThemeColor, .clickForYouTab, .clickFollowingTab, .hideSideHeader, .hidePostArea, .hideAds:
                return true
            case .global, .detectMediaOverlay, .loginLayoutDiagnostic:
                return false
            }
        }
    }

    static let handlerName = "handler";
    // Temporary login-layout diagnostic: a separate handler so it never reaches normal XDeck messaging.
    static let loginLayoutDiagnosticHandlerName = "xdeckLoginLayoutDiagnostic"

    static func makeConfiguration(onLoadScripts: [OnLoadScript]) -> WKWebViewConfiguration {
        let script = [
            onLoadScripts.filter({ !$0.runAfterLoad }).map(\.scriptContent).joined(separator: "\n"),
            wrapOnLoad(contents: onLoadScripts.filter({ $0.runAfterLoad }).map(\.scriptContent)),
        ].joined(separator: "\n")
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        // Added first so the shims are in place before X's module graph evaluates.
        userContentController.addUserScript(WKUserScript(
            source: compatibilityShims,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(userScript)
        return configuration
    }

    // WKWebView on macOS 12 (WebKit 17613, the Safari 17.6 build) lacks built-ins that X's
    // web client uses unconditionally. Each shim installs only when the native API is missing,
    // so newer WebKit keeps its own implementation.
    // - Array.prototype.toSorted: called at module top level while X's module graph evaluates;
    //   without it evaluation stops and the page stays blank.
    // - AbortSignal.timeout: passed to every onboarding/login flow request; without it the
    //   login page shows "Something went wrong".
    private static let compatibilityShims: String = """
        (function () {
            if (typeof Array.prototype.toSorted !== "function") {
                Object.defineProperty(Array.prototype, "toSorted", {
                    value: function toSorted(comparefn) {
                        if (comparefn !== undefined && typeof comparefn !== "function") {
                            throw new TypeError("The comparison function must be either a function or undefined");
                        }
                        var source = Object(this);
                        var length = Math.min(Math.max(Math.trunc(Number(source.length)) || 0, 0), Number.MAX_SAFE_INTEGER);
                        var copy = new Array(length);
                        for (var index = 0; index < length; index += 1) copy[index] = source[index];
                        return copy.sort(comparefn);
                    },
                    writable: true,
                    enumerable: false,
                    configurable: true
                });
            }

            if (typeof AbortSignal === "function" && typeof AbortSignal.timeout !== "function") {
                Object.defineProperty(AbortSignal, "timeout", {
                    value: function timeout(milliseconds) {
                        var delay = Number(milliseconds);
                        if (!isFinite(delay) || delay < 0) {
                            throw new TypeError("AbortSignal.timeout requires a finite, non-negative number of milliseconds");
                        }
                        var controller = new AbortController();
                        setTimeout(function () {
                            controller.abort(new DOMException("The operation timed out.", "TimeoutError"));
                        }, Math.min(Math.trunc(delay), 2147483647));
                        return controller.signal;
                    },
                    writable: true,
                    enumerable: false,
                    configurable: true
                });
            }
        })();
        """

    private static let global: String = """
        window.onerror = function(msg, url, line, column, error) {
            const message = JSON.stringify({ type: "debug", body: `❌️ ${msg}` });
            webkit.messageHandlers.\(Self.handlerName).postMessage(message);
        };
        window.console.error = function(msg) {
            const message = JSON.stringify({ type: "debug", body: `❌️ ${msg}` });
            webkit.messageHandlers.\(Self.handlerName).postMessage(message);
        };
        window.console.warn = function(msg) {
            const message = JSON.stringify({ type: "debug", body: `⚠️ ${msg}` });
            webkit.messageHandlers.\(Self.handlerName).postMessage(message);
        };
        window.console.info = function(msg) {
            const message = JSON.stringify({ type: "debug", body: `ℹ️ ${msg}` });
            webkit.messageHandlers.\(Self.handlerName).postMessage(message);
        };
        window.console.log = function(msg) {
            const message = JSON.stringify({ type: "debug", body: `ℹ️ ${msg}` });
            webkit.messageHandlers.\(Self.handlerName).postMessage(message);
        };

        \(getElementsByXPath)

        \(waitForElement)
    """

    private static let hidePostArea: String = """
        const style = document.createElement('style');
        style.type = 'text/css';
        style.innerHTML = "div:has(> main):has(> :nth-child(4)) > main div:has(> div > div[role='progressbar']) { display: none; }";
        document.querySelector('head').appendChild(style);
    """

    private static let findUserName: String = """
        waitForElement("a[aria-label='Profile'], a[data-testid='AppTabBar_Profile_Link']", 0, (element) => {
            const href = element.getAttribute('href') || element.href || '';
            let userName = null;
            try {
                const url = new URL(href, window.location.origin);
                const segments = url.pathname.split('/').filter(Boolean);
                userName = segments[0] || null;
            } catch (_) {}
            if (userName) {
                const message = JSON.stringify({ type: "userName", body: userName });
                webkit.messageHandlers.\(Self.handlerName).postMessage(message);
            }
        });
    """

    private static let findThemeColor: String = """
        waitForElement("meta[name='theme-color']", 0, (meta) => {
            // The theme-color meta tag can be rewritten multiple times while the SPA hydrates
            // (e.g. a default value first, then the value derived from the night_mode cookie),
            // so wait for it to stop changing before reporting it back.
            let debounceTimer = null;
            const reportWhenStable = () => {
                clearTimeout(debounceTimer);
                debounceTimer = setTimeout(() => {
                    const message = JSON.stringify({ type: "themeColor", body: meta.getAttribute('content') });
                    webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                }, 500);
            };
            new MutationObserver(reportWhenStable).observe(meta, { attributes: true, attributeFilter: ['content'] });
            reportWhenStable();
        });
    """

    private static let hideSideHeader: String = """
        const style = document.createElement('style');
        style.type = 'text/css';
        style.innerHTML = "header { display: none !important; }";
        document.querySelector('head').appendChild(style);
        """

    // X's home timeline tabs: index 0 is For You, index 1 is Following.
    private static let homeTimelineTabSelector = "[data-testid='primaryColumn'] [role='tablist'] div[role='tab']"

    private static let clickForYouTab: String = """
        waitForElement("\(homeTimelineTabSelector)", 0, (element) => {
            element.click();
        });
        """

    private static let clickFollowingTab: String = """
        waitForElement("\(homeTimelineTabSelector)", 1, (element) => {
            element.click();
        });
        """

    // Temporary login-layout diagnostic. Read-only: waits until a meaningful visible login control
    // exists (not a 1x1 accessibility sentinel), lets layout settle for two animation frames, then
    // reports viewport, document and ancestor-chain geometry once through its own message handler.
    private static let loginLayoutDiagnostic: String = """
        (function () {
            const rect = (element) => {
                const r = element.getBoundingClientRect();
                return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
            };
            // Rendered, at least 100x20, intersecting the viewport, and not hidden by display,
            // visibility or opacity. Opacity does not inherit, so ancestors are checked too.
            const isVisible = (element) => {
                const r = element.getBoundingClientRect();
                if (r.width < 100 || r.height < 20) return false;
                if (r.right <= 0 || r.bottom <= 0 || r.left >= window.innerWidth || r.top >= window.innerHeight) return false;
                const style = getComputedStyle(element);
                if (style.display === "none" || style.visibility === "hidden") return false;
                for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
                    if (parseFloat(getComputedStyle(node).opacity) === 0) return false;
                }
                return true;
            };
            const hasVisibleText = (element) => (element.innerText || "").trim().length > 0;
            const describe = (element) => {
                const style = getComputedStyle(element);
                return {
                    tag: element.tagName.toLowerCase(),
                    role: element.getAttribute("role"),
                    testid: element.getAttribute("data-testid"),
                    aria: (element.getAttribute("aria-label") || "").slice(0, 40) || null,
                    rect: rect(element),
                    style: {
                        display: style.display, position: style.position,
                        width: style.width, maxWidth: style.maxWidth,
                        marginLeft: style.marginLeft, marginRight: style.marginRight,
                        justifyContent: style.justifyContent, alignItems: style.alignItems,
                        transform: style.transform
                    }
                };
            };
            // Meaningful visible login controls: inputs, and buttons with visible text. Input values are never read.
            const controls = () => {
                const inputs = Array.from(document.querySelectorAll('input:not([type="hidden"])')).filter(isVisible);
                const buttons = Array.from(document.querySelectorAll('button, [role="button"]'))
                    .filter((element) => isVisible(element) && hasVisibleText(element));
                return { inputs: inputs, buttons: buttons };
            };
            const findTarget = () => {
                const found = controls();
                return found.inputs[0] || found.buttons[0] || null;
            };
            let reported = false;
            let observer = null;
            const report = () => {
                if (reported) return;
                const target = findTarget();
                if (!target) {
                    // The control went away while layout settled; keep waiting for it.
                    waitForControl();
                    return;
                }
                reported = true;
                const ancestors = [];
                for (let element = target.parentElement, depth = 0;
                     element && element !== document.documentElement && depth < 8;
                     element = element.parentElement, depth += 1) {
                    ancestors.push(describe(element));
                }
                const found = controls();
                const summarize = (element) => ({
                    tag: element.tagName.toLowerCase(),
                    type: element.getAttribute("type"),
                    text: (element.innerText || "").trim().slice(0, 30),
                    rect: rect(element)
                });
                const viewport = window.visualViewport;
                const main = document.querySelector("main");
                const metaViewport = document.querySelector('meta[name="viewport"]');
                webkit.messageHandlers.\(Self.loginLayoutDiagnosticHandlerName).postMessage(JSON.stringify({
                    path: location.pathname,
                    viewport: {
                        innerWidth: window.innerWidth, innerHeight: window.innerHeight,
                        outerWidth: window.outerWidth, outerHeight: window.outerHeight,
                        devicePixelRatio: window.devicePixelRatio,
                        screenWidth: screen.width, screenHeight: screen.height,
                        visualViewport: viewport ? {
                            width: viewport.width, height: viewport.height,
                            offsetLeft: viewport.offsetLeft, offsetTop: viewport.offsetTop,
                            scale: viewport.scale
                        } : null,
                        metaViewport: metaViewport ? metaViewport.getAttribute("content") : null
                    },
                    document: {
                        clientWidth: document.documentElement.clientWidth, clientHeight: document.documentElement.clientHeight,
                        scrollWidth: document.documentElement.scrollWidth, scrollHeight: document.documentElement.scrollHeight,
                        bodyClientWidth: document.body.clientWidth, bodyClientHeight: document.body.clientHeight,
                        bodyScrollWidth: document.body.scrollWidth, bodyScrollHeight: document.body.scrollHeight
                    },
                    rects: {
                        documentElement: rect(document.documentElement),
                        body: rect(document.body),
                        main: main ? rect(main) : null
                    },
                    controls: {
                        inputCount: found.inputs.length,
                        buttonCount: found.buttons.length,
                        firstControls: found.inputs.concat(found.buttons).slice(0, 6).map(summarize)
                    },
                    target: Object.assign(describe(target), { kind: target.tagName.toLowerCase() === "input" ? "input" : "button" }),
                    ancestors: ancestors
                }));
            };
            const settleThenReport = () => {
                requestAnimationFrame(() => requestAnimationFrame(report));
            };
            // No timeout: waits until the real control exists. Attribute changes are observed too,
            // because the page can reveal content by switching classes or styles without adding nodes.
            const waitForControl = () => {
                if (findTarget()) {
                    settleThenReport();
                    return;
                }
                if (observer) return;
                observer = new MutationObserver(() => {
                    if (!findTarget()) return;
                    observer.disconnect();
                    observer = null;
                    settleThenReport();
                });
                observer.observe(document, {
                    childList: true, subtree: true,
                    attributes: true, attributeFilter: ["style", "class", "hidden", "aria-hidden"]
                });
            };
            waitForControl();
        })();
        """

    private static func wrapOnLoad(contents: [String]) -> String {
        return """
            \(waitForElement)
            document.addEventListener('DOMContentLoaded', () => {
                \(contents.map {
                    """
                    (() => {
                        \($0)
                    })();
                    """
                }.joined(separator: "\n"))
            });
            """
    }

    private static let waitForElement: String = """
        function waitForElement(selector, index, callback, once=true) {
            const observer = new MutationObserver((mutationsList, observer) => {
                const element = document.querySelectorAll(selector)[index];
                if (element) {
                    callback(element);
                    if (once) {
                        observer.disconnect();
                    }
                }
            });
            observer.observe(document.body, { childList: true, subtree: true });
        }
        """

    private static let getElementsByXPath: String = """
        function getElementsByXPath(xpath, parent) {
          let results = [];
          let query = document.evaluate(
            xpath,
            parent || document,
            null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
            null
          );
          for (let i = 0, length = query.snapshotLength; i < length; i++) {
            results.push(query.snapshotItem(i));
          }
          return results;
        }
        """

    static let hideAds: String = """
        function hideAds() {
          const cells = document.querySelectorAll('div[data-testid="cellInnerDiv"]');
          cells.forEach((cell) => {
            if (cell.querySelector('div[data-testid="placementTracking"]')) {
              cell.style.display = "none";
            }
          });
        }

        if (!window.hideAdsMutationObserver) {
          let hideAdsTimer;
          let observer = new MutationObserver(() => {
            clearTimeout(hideAdsTimer);
            hideAdsTimer = setTimeout(hideAds, 100);
          });

          observer.observe(document.body, {
            childList: true,
            subtree: true,
          });

          window.hideAdsMutationObserver = observer;
        }

        hideAds();
        """

    static let showAds: String = """
        (() => {
          if (window.hideAdsMutationObserver) {
            window.hideAdsMutationObserver.disconnect();
            window.hideAdsMutationObserver = null;
          }

          const cells = document.querySelectorAll('div[data-testid="cellInnerDiv"]');
          cells.forEach((cell) => {
            if (cell.querySelector('div[data-testid="placementTracking"]')) {
              cell.style.display = "flex";
            }
          });
        })();
    """

    private static func detectMediaOverlay(columnIndex: Int) -> String {
        return """
            (function() {
                var mediaExpanded = false;
                const originalPushState = history.pushState;
                history.pushState = function() {
                    originalPushState.apply(this, arguments);
                    const url = window.location.href;
                    if (!mediaExpanded && /\\/(photo|video)\\/\\d+/.test(url)) {
                        mediaExpanded = true;
                        const message = JSON.stringify({ type: "mediaOverlay", body: String(\(columnIndex)) });
                        webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                    }
                };
                window.addEventListener('popstate', function() {
                    const url = window.location.href;
                    if (mediaExpanded && !/\\/(photo|video)\\/\\d+/.test(url)) {
                        mediaExpanded = false;
                        const message = JSON.stringify({ type: "mediaOverlay", body: "close" });
                        webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                    }
                });
            })();
        """
    }
}

