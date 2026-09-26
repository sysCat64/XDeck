import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var initialWindowSizeObserver: NSObjectProtocol?

    // SwiftUI's WindowGroup persists the window frame to UserDefaults under an
    // auto-generated "NSWindow Frame ..." key and restores it on every launch, which
    // overrides `.defaultSize` and makes the configured columnWidth-based initial size
    // unreliable. Clearing it before the window is created keeps the initial size
    // deterministic and driven by the current config on every launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
            defaults.removeObject(forKey: key)
        }

        if #available(macOS 13.0, *) {
            return
        }

        // macOS 12 has no SwiftUI defaultSize modifier, so size its first window when created.
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
    // overrides `.defaultSize` and makes the configured columnWidth-based initial size unreliable.
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
    @SceneBuilder
    var body: some Scene {
        if #available(macOS 13.0, *) {
            mainWindow.defaultSize(width: AppConfig.defaultWindowWidth, height: AppConfig.defaultWindowHeight)
        } else {
            mainWindow
        }
    }

    private var mainWindow: some Scene {
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
