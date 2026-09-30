# AGENTS.md

Guidance for coding agents working on XDeck Pinos.

## Project

**XDeck Pinos — navigating X on Monterey.**

XDeck Pinos is a native macOS X client built with SwiftUI, WebKit, AppKit and Foundation. It shows x.com in multiple WKWebView columns and adjusts the pages with injected JavaScript/CSS.

- Repository: https://github.com/sysCat64/XDeck-Pinos
- XDeck Pinos was originally based on [morishin/XDeck](https://github.com/morishin/XDeck) and is **maintained independently**. GitHub may still list this repository in the upstream fork network; that does not change how it is maintained.
- The upstream repository is a historical and reference source, not the operational release repository.
- There is no obligation to merge, rebase or adopt upstream changes. Useful upstream fixes may be ported selectively.
- Do not open pull requests against upstream unless explicitly asked.
- Preserve the complete git history and the legal attribution to the original project (see Legal / Attribution).

Monterey (macOS 12) compatibility is a core goal of the project. Do not describe or treat the project as a temporary compatibility fork or an investigation.

## Canonical Identity

| Item | Value |
|---|---|
| Product | `XDeck Pinos.app` |
| Xcode target | `XDeck` |
| Scheme | `XDeck` |
| Bundle identifier | `io.github.syscat64.XDeckPinos` |
| Marketing version | `1.0.0` |
| Configuration directory | `~/.config/XDeckPinos` |
| Repository URL | `https://github.com/sysCat64/XDeck-Pinos` |
| Release tag prefix | `pinos-v` |
| First planned public release | `pinos-v1.0.0` |

Do not rename the target, scheme, source directory or Swift types just to match the product name.

## macOS Compatibility Contract

- The canonical deployment target is **macOS 12.0**. It lives in `XDeck.xcodeproj/project.pbxproj` and stays authoritative. Do not reintroduce command-line deployment-target overrides.
- Real-device validation exists for **macOS 12.7.6 on Intel**.
- **Apple Silicon Monterey runtime validation has not been performed.** Never describe it as validated.
- Preserve behavior on newer macOS versions where possible.
- Prefer the smallest compatibility fix over broad redesigns.
- Do not add third-party dependencies for compatibility without explicit approval.

## Build and CI

Project build shape:

```sh
xcodebuild \
  -project XDeck.xcodeproj \
  -scheme XDeck \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  build
```

Do not add `CODE_SIGNING_ALLOWED=NO`. The project is intentionally configured for ad-hoc signing.

The authoritative CI is `.github/workflows/ci.yml` (workflow name `CI`). It runs on `macos-26` with Xcode 26 selected explicitly, for manual dispatch, pushes to `main` and `pinos-independence` (temporary until the main cutover) and pull requests to `main`. It does not run for tags. It builds **Debug and Release** with the project's own settings (no deployment-target or signing overrides) into a deterministic DerivedData path, and runs `scripts/verify-app.sh` on each `XDeck Pinos.app`, which requires:

- bundle identifier, version `1.0.0` (build `1`) and an existing executable
- exactly x86_64 + arm64
- a minimum macOS of exactly 12.0, in `Info.plist` and in both architectures' load commands (not merely 12.0 or lower)
- a valid strict ad-hoc signature with no Team ID and no signing authority chain, and no Hardened Runtime flag
- App Sandbox not enabled; in Release, no `get-task-allow` (Debug may have it)

It uploads `XDeck-Pinos-macOS12-debug` and `XDeck-Pinos-macOS12-release`. The Release artifact is the candidate for the pre-release Monterey runtime gate. `scripts/verify-app.sh` is shared so a future release workflow can reuse it.

The project setting itself is expected to stay exactly macOS 12.0.

Treat CI with Xcode 26 as authoritative for project builds. Do not downgrade CI to an older Xcode because an older local toolchain behaves differently. `XDeck/XDeck.icon` needs the newer toolchain to compile into the app icon.

## Signing and Security Model

- `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"`: ad-hoc signed
- no `DEVELOPMENT_TEAM`
- App Sandbox **OFF** (no entitlements file)
- Hardened Runtime **OFF**
- no Developer ID signing and no notarization

Debug artifacts may contain the `get-task-allow` entitlement. **Release artifacts must not**; CI verifies this.

Do not add or assume Apple Developer credentials. Do not restore upstream signing identities, Team IDs, notarization credentials or secrets. Do not switch Hardened Runtime on just because it is normally desirable: the project setting intentionally matches the actual ad-hoc distribution model.

## Release Status

Intended XDeck Pinos release model:

- GitHub Releases, tagged `pinos-vMAJOR.MINOR.PATCH`; first release `pinos-v1.0.0`
- universal x86_64 + arm64, ad-hoc signed, not notarized
- created as a draft first
- SHA-256 checksum published with the zip
- `LICENSE` included in the distributed artifact

**There is currently no XDeck Pinos release workflow in the repository.** A dedicated Pinos release workflow will be added separately. The upstream release workflow and its Developer ID export options were removed; they remain only in git history and are not a template for Pinos.

Do not publish a release or create release tags unless explicitly authorized. Never use `git push --tags`: local clones may hold upstream's numeric tags, which must not be pushed. Push only explicitly named tags, and only when authorized.

## Branch and History Discipline

- `pinos-independence` is the current migration branch.
- `main` and `macos12` are preserved historical branches. `main` still points at the upstream baseline until an authorized cutover.
- Archive tags mark preserved milestones: `archive/xdeck-baseline` and `archive/pinos-macos12-validated`.
- Do not delete, rewrite, force-push or repoint these branches or tags unless explicitly authorized.
- Keep commits narrow and single-purpose.

For migration work:

1. verify the branch, the expected HEAD and a clean tree
2. inspect the current implementation
3. make the smallest necessary change
4. run the relevant validation
5. commit
6. push only the intended branch
7. wait for CI
8. use the exact CI artifact for runtime gates when required

## Repository URL Centralization

Operational GitHub URLs are centralized in `XDeck/Config/AppConfig.swift`:

- `AppConfig.repositoryUrl`
- `AppConfig.latestReleaseUrl`
- `AppConfig.releaseUrl(forVersion:)`

Do not add new hard-coded operational repository URLs in views when these can be used.

The release parser in `UpdateButton.swift` deliberately validates the scheme, the host, the exact configured repository path and `pinos-vMAJOR.MINOR.PATCH`, and fails closed for anything else. If the repository is renamed again, update `AppConfig.repositoryUrl` before shipping a release.

## Configuration and App Identity

XDeck Pinos uses `~/.config/XDeckPinos`, separate from upstream XDeck. `settings.json` is created there on first launch; `schema.json` is rewritten on every launch.

Do not add automatic migration unless explicitly requested. Existing upstream XDeck data and configuration must not be copied, modified or deleted automatically. Because Pinos has its own bundle identifier, its login session and preferences are separate as well.

## Monterey WebKit Compatibility

The WKWebView on macOS 12 uses an older system WebKit than current Safari builds.

- Two document-start shims are required by reached X.com code paths: `Array.prototype.toSorted` and `AbortSignal.timeout`.
- Do not broaden the shim set speculatively. Add another Web API shim only when a real reached call site shows that Monterey's WKWebView lacks it.
- A login-dialog fallback stylesheet covers the older media-query syntax. It is feature-gated (`matchMedia("(width >= 0px)")`), so it only applies on engines that cannot parse range media queries. Keep that gating instead of applying the fallback to newer engines.
- Do not replace these fixes with user-agent spoofing. UA testing showed the user agent was not the root cause of the blank-page and login problems.

## UI Compatibility Notes

- The GitHub toolbar icon is a custom `Shape` inside a plain `Button`. Keep its explicit `.contentShape(Rectangle())`; without it the icon was not reliably clickable on Monterey.
- The bottom toolbar `HStack` currently stays within the older SwiftUI `ViewBuilder` limit of 10 direct children. Older toolchains fail if more are added. When adding a toolbar item, group views or restructure deliberately instead of adding another direct child.
- Do not refactor the toolbar for style alone.

## Important Files

- `XDeck/XDeckApp.swift`: app entry point
- `XDeck/View/ContentView.swift`: main multi-column UI and bottom toolbar
- `XDeck/View/WebView.swift`: WKWebView wrapper
- `XDeck/WebViewConfigurations.swift`: injected JavaScript/CSS and compatibility shims
- `XDeck/Config/AppConfig.swift`: configuration paths and centralized repository/release URLs
- `XDeck/View/UpdateButton.swift`: Pinos update check and strict release URL parsing
- `XDeck.xcodeproj/project.pbxproj`: deployment target, product identity and signing settings
- `.github/workflows/ci.yml`: authoritative CI (Debug and Release build, verification, artifacts)
- `scripts/verify-app.sh`: verifies a built app against the build contract; used by CI
- `Artwork/XDeck-Pinos-AppIcon-1024.png`: canonical app icon master
- `README.md`: user-facing installation, configuration and attribution
- `CLAUDE.md`: short working guide for Claude Code; defers to this file

## App Icon

The XDeck Pinos app icon is a finalized, Pinos-owned design: a lighthouse with a Monterey cypress, whose light beams form an X-like crossing motif.

- Canonical master and source of truth for any future icon change: `Artwork/XDeck-Pinos-AppIcon-1024.png`
- Icon Composer package: `XDeck/XDeck.icon`, which uses `XDeck/XDeck.icon/Assets/XDeck-Pinos-AppIcon.png`, a byte-identical copy of the master
- It was visually validated on real macOS 12.7.6 Intel using the exact CI artifact from commit `36298feb` (workflow run `36702652997`). Apple Silicon Monterey remains unvalidated.
- Do not redesign or replace the icon casually or during unrelated tasks. If it ever changes, update the master first, then replace the integration copy with a byte-identical copy.

## Testing

There are no automated test targets.

Relevant validation:

- macOS 12-targeted compilation
- exact app identity and version
- universal x86_64 + arm64 executable
- minimum macOS
- codesign verification and the ad-hoc signature
- absence of App Sandbox and of Hardened Runtime
- app launch, X login and X.com rendering
- multi-column behavior, appearance switching and Hide Ads
- configuration loading and keyboard shortcuts
- toolbar links and the update/version links

For user-visible or runtime-sensitive compatibility changes, CI success alone is not enough. When requested, run a real macOS 12.7.6 Intel gate using the exact CI artifact (the Release artifact when validating release readiness). A real Intel Monterey gate is also required before the first public release. Apple Silicon Monterey remains untested and must not be described as validated.

## Legal / Attribution

Do not remove upstream attribution because the project is now independently maintained. The existing MIT `LICENSE` and the original copyright notice must be preserved.

Do not blanket-reject the string `morishin`: legal and historical attribution is valid. What should disappear over time are stale operational dependencies on the upstream repository, not legitimate attribution.

`LICENSE` keeps the original `Copyright (c) 2023 Shintaro Morikawa` notice and also records `Copyright (c) 2026 sysCat64` for XDeck Pinos.

## Scope Discipline

- Do not make opportunistic refactors during compatibility or release work.
- Do not mix unrelated concerns in one commit.
- Do not change icon design, copyright wording, `LICENSE`, CI architecture or the release workflow unless the task explicitly authorizes it.
- When unsure whether something is an intentional Pinos decision or an upstream leftover, inspect the current repository state before changing it.
