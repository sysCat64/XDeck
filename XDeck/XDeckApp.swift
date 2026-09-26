import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var initialWindowSizeObserver: NSObjectProtocol?

    // SwiftUI's WindowGroup persists the window frame to UserDefaults under an
    // auto-generated "NSWindow Frame ..." key and restores it on every launch, which
    // overrides the configured initial size. Clearing it before the window is created
    // keeps the initial size deterministic and driven by the current config on every launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
            defaults.removeObject(forKey: key)
        }

        // Set the initial content size when the first window becomes key.
        initialWindowSizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            window.setContentSize(NSSize(width: AppConfig.defaultWindowWidth, height: AppConfig.defaultWindowHeight))

            if let observer = self?.initialWindowSizeObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.initialWindowSizeObserver = nil
            }
        }
    }

    // Without this, macOS restores the window frame from the previous launch, which
    // overrides the configured initial size and makes the columnWidth-based size unreliable.
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
}

@main
struct XDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let appConfig = AppConfig.loadConfig()

    // A rough starting size shown before login and before the actual column content has
    // rendered. ContentView resizes the window to fit the real rendered content width once
    // it is known, since WebView/scrollbar rendering introduces small, hard-to-predict differences.
    var body: some Scene {
        WindowGroup {
            if let appConfig {
                ContentView(appConfig: appConfig)
            } else {
                VStack(alignment: .center) {
                    Text("Error: Failed to load config file")
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
