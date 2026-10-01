# CLAUDE.md

**Read and follow `AGENTS.md` first.** It is the canonical repository-wide policy (identity, compatibility contract, signing, release and branch safety, attribution). This file is a short working guide. If the two ever seem to disagree, treat `AGENTS.md` as authoritative and inspect the current repository before acting.

## Project

**XDeck Pinos — navigating X on Monterey.** A native macOS X client built with SwiftUI, WebKit and AppKit/Foundation. It shows x.com in multiple WKWebView columns and adapts the pages with injected JavaScript/CSS. Repository: https://github.com/sysCat64/XDeck-Pinos.

XDeck Pinos was originally based on [morishin/XDeck](https://github.com/morishin/XDeck) and is maintained independently. macOS 12 (Monterey) compatibility is a core requirement.

| Item | Value |
|---|---|
| Product | `XDeck Pinos.app` |
| Xcode target / scheme | `XDeck` / `XDeck` |
| Deployment target | macOS 12.0 (set in the Xcode project) |
| Bundle ID | `io.github.syscat64.XDeckPinos` |
| Marketing version / build | `1.0.1` / `2` |
| Config directory | `~/.config/XDeckPinos` |
| Release tags | `pinos-vMAJOR.MINOR.PATCH` |

Do not rename the target, scheme or source paths just to match the product name.

## Build and Run

```sh
open XDeck.xcodeproj    # run with Cmd+R
```

```sh
xcodebuild \
  -project XDeck.xcodeproj \
  -scheme XDeck \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  build
```

The project is intentionally ad-hoc signed, so do not add `CODE_SIGNING_ALLOWED=NO`.

Authoritative CI is `.github/workflows/ci.yml` (`macos-26`, Xcode 26). It builds Debug and Release and runs `scripts/verify-app.sh` on each app: universal x86_64 + arm64, minimum macOS exactly 12.0, a strict ad-hoc signature with no Team ID, Hardened Runtime and App Sandbox off, and no `get-task-allow` in Release (Debug may have it). It uploads `XDeck-Pinos-macOS12-debug` and `XDeck-Pinos-macOS12-release`; the Release artifact is the candidate for the pre-release Monterey runtime gate. Xcode 26 is the build contract (the `XDeck.icon` asset needs it). An older local toolchain may show extra constraints, but it does not override CI.

There are no automated tests. CI success is not runtime validation: real macOS 12.7.6 Intel gates use the exact CI artifact, and the exact release assets when the gate justifies a release validation claim (see `AGENTS.md`). Apple Silicon Monterey is untested, so never claim it as validated.

## Architecture

There is no separate view-model layer. State lives in the SwiftUI views (`@State`, `@AppStorage`), mainly `ContentView`.

**Startup: `XDeck/XDeckApp.swift`**
- `XDeckApp` is the `@main` entry point. `AppConfig.loadConfig()` runs before `ContentView` is created; if it fails, an error view is shown.
- `AppDelegate` clears saved window frames, disables state restoration, and sets the initial content size on the first key window, so the starting size is deterministic.

**Main UI: `XDeck/View/ContentView.swift`**
- Builds the multi-column layout and the WebView columns from `AppConfig`.
- Owns the bottom toolbar (GitHub link, version/update, ♡ Sponsor link, appearance and Hide Ads toggles, shortcut hints) and the hidden keyboard shortcuts.
- Handles appearance, Hide Ads, zoom, refresh and window-fit.
- Decodes messages from the web views and updates state.
- Toolbar traps on Monterey: keep `.contentShape(Rectangle())` on the GitHub icon. The toolbar `HStack` sits at the practical 10-direct-child `ViewBuilder` limit of older SwiftUI toolchains; group or restructure instead of adding an 11th child (the Sponsor link lives in the inner GitHub/version group).

**WebView: `XDeck/View/WebView.swift`**
- `NSViewRepresentable` around `WKWebView`. Its coordinator is the navigation delegate, UI delegate and script-message handler.
- Forwards script messages, runs JavaScript requests from `ContentView`, applies page zoom, opens link activations with `NSWorkspace`, and shows the file picker.
- It sets a Safari-like custom user agent because X rejects the default WebView agent. Do not remove or redesign it casually, and do not treat user-agent changes as a WebKit compatibility fix: UA spoofing was not the fix for the Monterey blank-page and login problems.

**Injection: `XDeck/WebViewConfigurations.swift`**
- Builds the `WKWebViewConfiguration`. All scripts inject at document start; the post-load ones wait for `DOMContentLoaded`.
- Scripts: console bridge, username discovery, theme color, For You/Following tab selection, side-header and post-area hiding, Hide Ads/Show Ads, media-overlay detection, and the login dialog fallback.
- Compatibility shims for macOS 12's WKWebView: `Array.prototype.toSorted` and `AbortSignal.timeout`. Both were added for real X code paths. **Do not add speculative shims.**
- The login dialog media-query fallback is gated by `window.matchMedia("(width >= 0px)")`. Keep the gate.

**Messages:** JavaScript posts a JSON string to `webkit.messageHandlers.handler`; the coordinator passes it through the `WebView` binding; `ContentView` decodes `WebViewMessage` (`userName`, `themeColor`, `mediaOverlay`).

**Login: `XDeck/View/LoginView.swift`**
- Loads https://x.com/login in a `WebView` with `findUserName`, `findThemeColor` and `loginDialogCompatibility`. Once the username arrives, `ContentView` switches to the columns.

**Configuration: `XDeck/Config/AppConfig.swift`**
- Config paths under `~/.config/XDeckPinos`, creation and loading of `settings.json`, rewriting `schema.json` on every launch, and the centralized repository/release URLs: `AppConfig.repositoryUrl`, `AppConfig.latestReleaseUrl`, `AppConfig.releaseUrl(forVersion:)`, `AppConfig.sponsorUrl`. Do not hard-code the repository or sponsor URL in views.
- Upstream XDeck configuration is never migrated automatically.

**Updates: `XDeck/View/UpdateButton.swift`**
- Checks the latest release in sysCat64/XDeck-Pinos. It accepts only the configured repository and only `pinos-vMAJOR.MINOR.PATCH` tags, fails closed otherwise, and compares numeric version components. Do not weaken the repository-path check. If the repository is renamed again, update `AppConfig.repositoryUrl` before shipping a release.

## Signing (short form)

Manual signing, `CODE_SIGN_IDENTITY = "-"` (ad-hoc), no `DEVELOPMENT_TEAM`, App Sandbox off, Hardened Runtime off, no Developer ID, no notarization. Debug artifacts may contain `get-task-allow`; Release artifacts must not. Do not restore upstream Apple credentials. Full policy is in `AGENTS.md`.

## Release Warning

`main` is the canonical operational branch (the migration cutover is complete). `pinos-independence` is only a preserved migration branch that nothing runs on, and `macos12` is the preserved validated compatibility branch; do not delete or move either without explicit authorization. CI runs on pushes and pull requests to `main`, and by manual dispatch.

The release workflow is `.github/workflows/release.yml`. Manual `workflow_dispatch` is the normal dry-run path: it never creates a tag or a GitHub Release, and uploads `XDeck-Pinos-<version>-release-candidate` as an Actions artifact. There is no branch-push dry-run trigger. Pushing a `pinos-vMAJOR.MINOR.PATCH` tag is the only real trigger; the workflow validates the exact tag format in bash and requires it to match the built app's `CFBundleShortVersionString`. Real releases are drafts only, never published automatically. Both paths build Release, run `scripts/verify-app.sh`, package `XDeck Pinos.app` + `LICENSE` into `XDeck-Pinos-<version>.zip`, re-extract and reverify the ZIP, and write a `.sha256` sidecar. Details are in `AGENTS.md`.

Do not create or publish a release, or create or push release tags, unless the owner explicitly authorizes it, and never use `git push --tags`. Detailed release publication and update-E2E safeguards are documented in `AGENTS.md`.

## App Icon

The Pinos app icon is finalized (lighthouse, Monterey cypress, X-like light beams). Its source/master is `Artwork/XDeck-Pinos-AppIcon-1024.png`. Icon Composer uses the byte-identical copy `XDeck/XDeck.icon/Assets/XDeck-Pinos-AppIcon.png`, and `XDeck/XDeck.icon/icon.json` holds the active integration settings. It passed real visual validation on macOS 12.7.6 Intel. Do not redesign or replace it during unrelated work.

## Important Files

- `AGENTS.md`: canonical repository policy
- `README.md`: user-facing Pinos documentation
- `XDeck/XDeckApp.swift`: app entry point and startup
- `XDeck/View/ContentView.swift`: main UI, columns and toolbar
- `XDeck/View/LoginView.swift`: X login web view
- `XDeck/View/WebView.swift`: WKWebView wrapper and delegates
- `XDeck/WebViewConfigurations.swift`: injected JS/CSS and Monterey compatibility code
- `XDeck/Config/AppConfig.swift`: settings and repository/release identity
- `XDeck/View/UpdateButton.swift`: release/version check
- `XDeck.xcodeproj/project.pbxproj`: deployment target, product and signing
- `.github/workflows/ci.yml`: authoritative CI (Debug + Release build, verification, artifacts)
- `scripts/verify-app.sh`: verifies a built app against the build contract

## Working Practice

- Inspect before editing; prefer narrow changes and avoid opportunistic refactors. Do not mix unrelated concerns in one commit.
- When told, verify the branch, the expected HEAD and a clean tree first, and run `git diff --check` before committing.
- Wait for CI when asked, and use the exact CI artifact for Monterey runtime gates.
- Keep legitimate attribution to the original project (the `LICENSE` and links to it); only stale operational dependencies on upstream should go.
