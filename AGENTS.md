# AGENTS.md

## Project

XDeck is a native macOS X/Twitter client built with SwiftUI, WebKit, AppKit, and Foundation.

This repository is a fork of `morishin/XDeck`.

The current goal of this fork is to investigate and implement compatibility with macOS 12 Monterey while preserving upstream behavior as much as possible.

## Primary Goal

Make XDeck build and run on macOS 12.7.x.

Do not redesign the application or change product behavior unless required for macOS 12 compatibility.

Prefer the smallest compatibility changes possible.

## Compatibility Policy

- Target macOS 12 unless a task explicitly says otherwise.
- Preserve existing behavior on newer macOS versions.
- When an API is unavailable on macOS 12:
  1. Prefer an older equivalent Apple API.
  2. Otherwise use availability checks where appropriate.
  3. Avoid removing functionality unless no reasonable compatibility path exists.
- Do not introduce third-party dependencies solely to solve compatibility issues unless explicitly approved.
- Keep SwiftUI/WebKit/AppKit architecture intact unless a compatibility issue requires otherwise.

## Build

Primary validation command:

```sh
xcodebuild \
  -project XDeck.xcodeproj \
  -scheme XDeck \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Treat compiler availability errors as the authoritative list of macOS 12 migration work.

## Important Files

- `XDeck/XDeckApp.swift` — app entry point
- `XDeck/View/ContentView.swift` — main multi-column UI
- `XDeck/View/WebView.swift` — WKWebView wrapper
- `XDeck/WebViewConfigurations.swift` — JavaScript injection
- `XDeck/Config/AppConfig.swift` — settings/configuration handling
- `XDeck.xcodeproj/project.pbxproj` — deployment target and build settings
- `.github/workflows/release.yml` — upstream release workflow
- `CLAUDE.md` — upstream development notes

## Upstream Preservation

Treat `morishin/XDeck` as upstream.

Do not:
- open pull requests against upstream unless explicitly requested
- change upstream release/tag conventions unnecessarily
- modify signing/notarization credentials or assume upstream secrets exist
- publish releases unless explicitly requested

For compatibility work, prefer changes isolated to this fork.

## Release / Signing

Initial macOS 12 compatibility work does not require Developer ID signing or notarization.

For CI experiments, unsigned builds or ad-hoc artifacts are acceptable.

Do not attempt to use upstream Apple Developer credentials.

## Scope Discipline

For each task:

1. Inspect the existing implementation first.
2. Identify the exact macOS availability problem.
3. Make the smallest compatible change.
4. Build again.
5. Report remaining compatibility errors separately from unrelated warnings.

Do not perform broad refactors while compatibility work is still being established.

## Testing

There are currently no automated test targets.

Validation should focus on:

- successful macOS 12-targeted compilation
- app launch
- login flow
- X.com WebView rendering
- multi-column layout
- theme switching
- ad hiding
- configuration loading
- keyboard shortcuts

## Notes

`XDeck/XDeck.icon` requires Xcode 26 to compile correctly in the upstream release workflow.

If icon handling prevents compatibility builds, prefer a compatibility-specific icon solution rather than weakening unrelated application behavior.
