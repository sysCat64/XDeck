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
        case loginDialogCompatibility

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
            case .loginDialogCompatibility: return WebViewConfigurations.loginDialogCompatibility
            }
        }

        var runAfterLoad: Bool {
            switch self {
            case .findUserName, .findThemeColor, .clickForYouTab, .clickFollowingTab, .hideSideHeader, .hidePostArea, .hideAds:
                return true
            case .global, .detectMediaOverlay, .loginDialogCompatibility:
                return false
            }
        }
    }

    static let handlerName = "handler";

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

    // macOS 12 system WKWebView uses WebKit 613 (Safari 15.6-generation)
    // and lacks built-ins that X's web client uses unconditionally. Each shim
    // installs only when the native API is missing, so newer WebKit keeps its
    // own implementation.
    // - Array.prototype.toSorted: called at module top level while X's module
    //   graph evaluates; without it evaluation stops and the page stays blank.
    // - AbortSignal.timeout: passed to onboarding/login flow requests; without
    //   it the login page shows "Something went wrong".
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

    // X's login dialog lays itself out with Tailwind "narrow:" utilities inside
    // @media (width>=517px) and "max-narrow:" utilities inside @media not all and (width>=517px).
    // WebKit 613 (macOS 12 WKWebView) cannot parse media-query range syntax and drops both
    // branches, so the dialog ends up at the top-left (or collapses below 517px). This re-declares
    // the dialog's utilities, copied from X's stylesheet, with classic min-width syntax and keyed to
    // the same classes on role="dialog". The <style> goes into <head>, where React hydration skips it.
    private static let loginDialogCompatibility: String = #"""
        (function () {
            // Range media queries are what WebKit 613 cannot parse; it treats "(width >= 0px)" as
            // non-matching, while any engine that supports them matches it for every viewport. Skip
            // the fallback there so this frozen copy never overrides X's native responsive rules.
            if (window.matchMedia("(width >= 0px)").matches) return;
            const css = String.raw`
                @media (min-width: 517px) {
                    [role="dialog"].narrow\:inset-0 { inset: 0; }
                    [role="dialog"].narrow\:m-auto { margin: auto; }
                    [role="dialog"].narrow\:h-fit { height: fit-content; }
                    [role="dialog"].narrow\:w-\[700px\] { width: 700px; }
                    [role="dialog"].narrow\:max-w-full { max-width: 100%; }
                    [role="dialog"].narrow\:overflow-hidden { overflow: hidden; }
                    [role="dialog"].narrow\:rounded-lg { border-radius: calc(24px * var(--x-radius-m)); }
                    [role="dialog"].narrow\:border { border-style: var(--tw-border-style); border-width: 1px; }
                    [role="dialog"].narrow\:border-normal { border-color: var(--x-border-normal); }
                    [role="dialog"].narrow\:shadow-popup {
                        --tw-shadow: var(--x-shadow-popup);
                        box-shadow: var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow);
                    }
                }
                @media not all and (min-width: 517px) {
                    [role="dialog"].max-narrow\:inset-0 { inset: 0; }
                    [role="dialog"].max-narrow\:rounded-none { border-radius: 0; }
                    [role="dialog"].max-narrow\:p-4 { padding: 16px; }
                    [role="dialog"].max-narrow\:\[--x-modal-bg\:var\(--x-bg-primary\)\] { --x-modal-bg: var(--x-bg-primary); }
                    [role="dialog"].max-narrow\:bg-primary { background-color: var(--x-bg-primary); }
                    [role="dialog"].max-narrow\:shadow-none {
                        --tw-shadow: 0 0 #0000;
                        box-shadow: var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow);
                    }
                    [role="dialog"].max-narrow\:data-\[starting-style\]\:translate-y-full[data-starting-style] {
                        --tw-translate-y: 100%;
                        translate: var(--tw-translate-x) var(--tw-translate-y);
                    }
                    [role="dialog"].max-narrow\:data-\[ending-style\]\:translate-y-full[data-ending-style] {
                        --tw-translate-y: 100%;
                        translate: var(--tw-translate-x) var(--tw-translate-y);
                    }
                    [role="dialog"].max-narrow\:p-0\! { padding: 0 !important; }
                }
            `;
            const install = () => {
                const style = document.createElement("style");
                style.setAttribute("data-xdeck", "login-dialog-compatibility");
                style.textContent = css;
                document.head.appendChild(style);
            };
            if (document.head) {
                install();
                return;
            }
            const observer = new MutationObserver(() => {
                if (!document.head) return;
                observer.disconnect();
                install();
            });
            observer.observe(document, { childList: true, subtree: true });
        })();
        """#

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

