# XDeck Pinos

**XDeck Pinos — navigating X on Monterey.** A native macOS client that shows X in multiple columns, in the style of TweetDeck.

![XDeck Pinos — lighthouse on the Monterey coast](Artwork/XDeck-Pinos-README-Cover-1600x640.png)

XDeck Pinos was originally based on [XDeck](https://github.com/morishin/XDeck) and is maintained independently for Monterey (macOS 12) compatibility. It is not affiliated with, maintained by, or endorsed by the original XDeck author.

> **Status:** version 1.0.0 is in preparation. The first GitHub Release has not been published yet.

## Features

- Multi-column X browsing: each column is a web view of x.com
- Light/dark appearance switch
- Hide Ads toggle for promoted posts
- Configurable columns (For You, Following, Notifications, Profile) and custom X URLs such as lists
- Runs on macOS 12 Monterey. At the time this project began, the original XDeck required macOS 13.3.

XDeck Pinos loads x.com in web views and adjusts the page with injected scripts and styles. If X changes its site, some of these adjustments may stop working.

## Requirements

- macOS 12.0 (Monterey) or later
- Validated on real hardware: macOS 12.7.6 on an Intel Mac
- Release builds are intended to be universal (x86_64 and arm64)
- **Apple Silicon on Monterey has not been runtime-tested yet**

## Installation

Download `XDeck-Pinos-<version>.zip` from [GitHub Releases](https://github.com/sysCat64/XDeck-Pinos/releases) and unzip it.

The Homebrew `xdeck` cask installs the upstream XDeck project, not XDeck Pinos. XDeck Pinos is not available through Homebrew.

### About code signing

XDeck Pinos is distributed through GitHub Releases only. The app is **ad-hoc signed**. It is **not signed with an Apple Developer ID and not notarized**, so macOS Gatekeeper will not open it normally the first time.

### First launch

1. Move `XDeck Pinos.app` to your Applications folder if you like.
2. In Finder, Control-click (or right-click) `XDeck Pinos.app`.
3. Choose **Open**.
4. Confirm **Open** when macOS asks.

After this, XDeck Pinos opens normally.

If macOS still blocks the app, open System Preferences → Security & Privacy → General (System Settings → Privacy & Security on newer macOS) and choose **Open Anyway** for XDeck Pinos. On newer macOS versions the Control-click shortcut may not be offered, and this Security setting is the way to open the app.

## Configuration

Press `⌘,` in the app and choose **Open Folder**, or open `~/.config/XDeckPinos` yourself. The files are:

- `~/.config/XDeckPinos/settings.json`: your settings. It is created with defaults on first launch. Edit it and restart the app.
- `~/.config/XDeckPinos/schema.json`: a JSON schema for editor validation, rewritten by the app on every launch. Do not edit it.

Example `settings.json`:

```json
{
  "$schema": "./schema.json",
  "columnWidth": 450,
  "columns": [
    {
      "type": "following"
    },
    {
      "type": "forYou"
    },
    {
      "type": "notifications"
    },
    {
      "type": "profile"
    },
    {
      "type": "custom",
      "url": "https://x.com/i/lists/123456789"
    }
  ]
}
```

XDeck Pinos intentionally uses its own configuration directory, separate from upstream XDeck. It does not migrate anything: an existing XDeck configuration is not automatically copied, modified or deleted. To reuse it, copy your `settings.json` into `~/.config/XDeckPinos` yourself. XDeck Pinos also has its own app identity, so its X login and preferences are separate from XDeck's, and you need to sign in to X again.

## Updates

XDeck Pinos releases are tagged `pinos-vMAJOR.MINOR.PATCH`, for example `pinos-v1.0.0`.

The installed version is shown in the app's footer, linking to its release page. The app checks the latest release in this repository on GitHub, and shows an update link when a newer XDeck Pinos release exists. Updating is manual: download the new release and replace the app.

## Building from Source

```sh
open XDeck.xcodeproj
```

- Scheme: `XDeck`
- Product: `XDeck Pinos.app`
- No third-party dependencies (SwiftUI, WebKit and AppKit only)
- The project is configured for ad-hoc signing, so no Apple Developer account is needed
- The deployment target is macOS 12.0
- Continuous integration builds with Xcode 26. The app icon (`XDeck.icon`) uses the Icon Composer format, which needs the newer toolchain to compile into the app icon.

## Attribution

XDeck Pinos was originally based on [XDeck](https://github.com/morishin/XDeck) by Shintaro Morikawa and is now maintained independently. Thanks to the original author for the project this one grew from.

X is a trademark of X Corp. XDeck Pinos is not affiliated with X Corp.

## License

Released under the MIT License. See [LICENSE](LICENSE) for the license text and the original copyright notice.
