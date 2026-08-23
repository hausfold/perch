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

Every target derives its identifier from one project-level setting —
`$(PERCH_BUNDLE_ID)`, `$(PERCH_BUNDLE_ID).finder-action`,
`$(PERCH_BUNDLE_ID).cli`, and the two iOS ones — precisely so the dev build can
rename the whole family with a single override:

```sh
xcodebuild -scheme Perch … PERCH_BUNDLE_ID=com.hausfold.perch.dev
```

A `PRODUCT_BUNDLE_IDENTIFIER=` on the xcodebuild command line applies to **every
target in the scheme**, which collapses the app, the Finder Action and the CLI
onto one identifier. An app extension that shares its container's bundle id is
malformed: PluginKit registers it (`defaults read pbs` even shows
`APPEXTENSION-… = 1`) but Finder never offers the Quick Action and Login Items &
Extensions has nothing to switch on — which is what field-test #4 turned out to
be, after two passes of looking for it in the plist.
