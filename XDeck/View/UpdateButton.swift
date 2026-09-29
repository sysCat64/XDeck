import SwiftUI

struct UpdateButton: View {
    @State private var updateAvailable: Bool = false
    @State private var latestVersion: String? = nil
    @Environment(\.openURL) private var openURL

    private static var currentVersion: String? {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        if let currentVersion = Self.currentVersion {
            HStack {
                if updateAvailable, let latestVersion = latestVersion {
                    HStack {
                        Text("v\(currentVersion) (v\(latestVersion) is available)")
                        Button("Update", action: {
                            openURL(AppConfig.latestReleaseUrl)
                        })
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button("v\(currentVersion)" + (Self.isDebug ? " (dev)" : ""), action: {
                        openURL(AppConfig.releaseUrl(forVersion: currentVersion))
                    }).buttonStyle(.plain)
                }
            }
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onAppear {
                Task {
                    await checkForUpdate()
                }
            }
        } else {
            EmptyView()
        }
    }

    func checkForUpdate() async {
        var request = URLRequest(url: AppConfig.latestReleaseUrl)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            // Without a Pinos release, "latest" doesn't end on a pinos-v tag URL: no update.
            if let latestVersion = response.url.flatMap(Self.extractVersion(from:)) {
                let currentVersion = Self.currentVersion ?? "0.0"
                if currentVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
                    DispatchQueue.main.async {
                        self.latestVersion = latestVersion
                        self.updateAvailable = true
                    }
                }
            }
        } catch {
            self.latestVersion = nil
            self.updateAvailable = false
        }
    }

    // Returns "MAJOR.MINOR.PATCH" only for a XDeck Pinos release tag URL
    // (".../releases/tag/pinos-vMAJOR.MINOR.PATCH" on the repository's host); nil otherwise.
    static func extractVersion(from url: URL) -> String? {
        let prefix = NSRegularExpression.escapedPattern(for: AppConfig.releaseTagPrefix)
        let path = url.path
        guard url.host == AppConfig.repositoryUrl.host,
              let regex = try? NSRegularExpression(pattern: "/releases/tag/\(prefix)([0-9]+\\.[0-9]+\\.[0-9]+)$"),
              let match = regex.firstMatch(in: path, range: NSRange(location: 0, length: path.utf16.count)),
              let range = Range(match.range(at: 1), in: path) else {
            return nil
        }
        return String(path[range])
    }
}

#Preview {
    UpdateButton().frame(maxWidth: .infinity)
}
