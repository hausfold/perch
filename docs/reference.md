# perch reference

Build instructions, storage layout, and the v1 product boundary — the material
that used to live in the README.

## Build and run

Requirements: **Xcode 26+**, **macOS 14+**.

```sh
xcodebuild -project Perch.xcodeproj -scheme Perch \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Or open `Perch.xcodeproj`, pick the **Perch** scheme, and run **My Mac** for an
interactive build.

If you build or copy the app by hand instead of installing the cask, macOS may
quarantine your copy. Clear it with:

```sh
xattr -dr com.apple.quarantine /Applications/Perch.app
```

The Homebrew cask is signed with our Apple Developer ID and notarized, so it
never needs this.

## Where your stuff lives

The active shelf is stored under the app's own container:

```text
~/Library/Containers/com.nebelhaus.perch/Data/Library/Application Support/
  Perch/ActiveShelf/
```

Each import gets its own UUID directory — that's what prevents name collisions
without renaming your file. The manifest records only **staged relative paths**
and file metadata; original source paths are never persisted, and never logged.
Clearing an item deletes its whole import directory.

## The product boundary (v1)

v1 deliberately stages copies and exports copies.

True move semantics fight a resilient temporary shelf: a move can delete the only
staged file before the app knows whether the destination finished consuming it.
That's the failure mode that loses data, and it's the one Perch is built not to
have.

A future explicit "move originals" action can be added behind a separate
transactional export service — without changing the importer, the repository, or
the UI model. The current design leaves that door open on purpose.

## Permissions

Perch requests **no** Accessibility, Input Monitoring, or Screen Recording
permission, and has no Dock icon. It sees only what you drop on it.

There is no telemetry. Nothing about your files is written to a log.
