# dev-app — the source-build injection point

This directory is the default value of the flake's `prebuilt` input, and it is
**deliberately empty** (no `Perch.app`). When it's empty, `nix/package.nix`
fetches the CI-built release ZIP as normal.

`bench try` / `bench try-batch` use it to feel-test a perch **source** branch
without waiting on a release: because macOS 26 blocks a from-source Nix build
(the `_nixbld` user can't apply SwiftPM's manifest sandbox — see
`../package.nix`), bench builds `Perch.app` from the branch **in your login
session** (where `xcodebuild` works), signs it with a stable identity under the
`com.hausfold.perch.dev` bundle id, and points this input at that build:

```
--override-input haus/perch/prebuilt path:/path/to/built-app-dir
```

The package then packages *that* app instead of the release. Nothing here needs
committing per build — the override is transient, per `bench try` invocation.

## Renaming the bundle: use `PERCH_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`

All five targets derive their identifier from one project-level setting —
`$(PERCH_BUNDLE_ID)`, `.cli`, `.tests`, `.ios`, `.ios.share` — precisely so the
dev build can rename the whole family with a single override:

```sh
xcodebuild -scheme Perch … PERCH_BUNDLE_ID=com.hausfold.perch.dev
```

A `PRODUCT_BUNDLE_IDENTIFIER=` on the xcodebuild command line applies to **every
target in the scheme**, which collapses the app, the CLI and the iOS pair onto
one identifier. That is still worth avoiding on its own terms — an app
extension sharing its container's bundle id is malformed, and `PerchShare` on
the iOS side is exactly such an extension.

It used to matter more: the Mac shipped a `PerchFinderAction` extension, and
this collapse was the leading explanation for field-test #4 (no Quick Action,
nothing to switch on in Login Items & Extensions) through two passes. Fixing it
disproved the theory — with a properly nested id the extension still did not
render, and clicking it shelved nothing — so the extension was removed on
2026-08-23 and perch's only Finder door is now the app's own `NSServices`
entry.

### What the rename deliberately does *not* change

Three things stay pinned to the release identity, so a `…dev` build is not a
fully separate app and never was:

- **The App Group** is `88M28542LQ.com.hausfold.perch`, hardcoded in the
  entitlements and compiled into three binaries as a Swift constant
  (`PerchFinderBridge/FinderActionProtocol.swift`). It is portal-registered, so
  a derived `…dev` group would be unprovisioned and the Finder/CLI mailbox
  would not open at all. Consequence: a dev build and an installed release
  share one mailbox, and both poll it.
- **The single-instance guard** matches on `Bundle.main.bundleIdentifier`
  (`Perch/App/PerchApp.swift`), so a renamed dev build does *not* stand down
  for an installed release. Two panels, one notch — quit the installed app
  first, as `AGENTS.md` says.
- **`perch add` from the CLI** resolves the app by the literal
  `com.hausfold.perch` (`PerchCLI/PerchTool.swift`), so it reaches the
  *installed* app rather than the dev one whenever a release is installed.

None of this is new — the old `PRODUCT_BUNDLE_IDENTIFIER` rename produced all
three — but it is what to expect when feel-testing the Finder doors.
