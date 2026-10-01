# Qbar

[简体中文](README.md)

Qbar is a native macOS menu bar organizer built with SwiftUI, AppKit, and ScreenCaptureKit. It has no account, analytics SDK, or network service.

**Status: open-source development preview. There is no public binary release yet.** The current full-feature build is a local, non-sandboxed app. The experimental Mac App Store build is not feature-equivalent; see [App Store feasibility](docs/APP_STORE.md).

## Features

- Keep items visible, place them in a compact tray, or hide them completely.
- Show captured native status icons in a horizontal tray and search for items.
- Temporarily reveal an item in the macOS menu bar when selected; multiple items can remain revealed independently and return after an idle delay.
- Remember a layout when apps restart, support newly launched apps, and import or export settings.
- Follow macOS language for Simplified Chinese and English, with a configurable menu bar symbol and shortcuts.

These are implemented features, not a guarantee of compatibility with every app, display arrangement, or macOS version.

## Build

Requirements: macOS 14.4+, Xcode 15.3+, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project Qbar.xcodeproj -scheme Qbar -configuration Debug -derivedDataPath build build
```

For a local distributable bundle, set `QBAR_SIGNING_IDENTITY` to an Apple Development signing identity and run `zsh Scripts/build.sh`. Its output is **not notarized**. The default ad-hoc signature is for development only and may not retain the macOS permissions required by Qbar.

For a GitHub Release download, install a valid **Developer ID Application** certificate and store notarization credentials with `xcrun notarytool store-credentials`. Commit the source first, then run from a clean working tree:

```sh
QBAR_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
QBAR_TEAM_ID='TEAMID' \
QBAR_NOTARY_PROFILE='YourNotaryProfile' \
zsh Scripts/release.sh
```

The script creates `dist/Qbar-<version>-macos-universal.zip` and a SHA-256 checksum only after notarization, stapling, and Gatekeeper validation succeed. It does not upload to GitHub. Keep certificate private keys and notarization credentials out of the repository.

Qbar needs user-granted Accessibility control to move and reveal status items, and Screen Recording to capture their original menu bar images. Status icon snapshots and preferences stay in `~/Library/Application Support/Qbar/`; the app does not upload them. Resetting settings or revoking Screen Recording clears the icon cache.

## License

Qbar source and original artwork are released under the [MIT License](LICENSE). Please avoid committing your personal layouts, logs, screenshots, or signing credentials. The repository ignores local backups and build output.
