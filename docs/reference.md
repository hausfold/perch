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

## Colors

The shelf paints from a nebelung palette. Four variants are built in — the
default `nebelung` pair and their high-contrast counterparts — and the one in use
follows macOS Light/Dark:

```text
~/.config/perch/
  config.json          { "themeDark": "nebelung", "themeLight": "nebelung-latte" }
  themes/<name>.json   flat "role": "#hex" map — a nebelung *.hex.json verbatim
```

A file in `themes/` **shadows** a built-in of the same name, so a palette bump
lands without a new release, and any Catppuccin-shaped palette drops in under its
own name. Perch reads seven roles — `base`, `crust`, `overlay0`, `text`,
`subtext0`, `green`, `red` — and ignores the rest; a missing or malformed file
falls back to built-in nebelung rather than failing.

On a [nebelhaus](https://github.com/nebelhaus/nebelhaus) rice all of this is
written for you from `nebelhaus.theme.flavor` / `.contrast`; standalone installs
can write the two files by hand or ignore them entirely. Perch has no theme
picker: colors come from the rice, everything else from Settings.

Changes are picked up the next time the shelf opens — no relaunch.

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

It is sandboxed, with one read-only exception: `~/.config/perch/`, where the
theme above lives. That is the only path Perch opens that a drag or a file picker
didn't hand it, and it is never written.

There is no telemetry. Nothing about your files is written to a log.

## The one system setting perch needs

Turn **off** System Settings ▸ Desktop & Dock ▸ *"Drag windows to top of screen
to enter Mission Control"*, or equivalently:

```sh
defaults write com.apple.dock enterMissionControlByTopWindowDrag -bool false
killall Dock
```

The Dock arms that top-screen-edge trigger for the whole duration of *any* drag
session — files included, despite the key's name — and the band it watches is
exactly where the notch catch zone lives. Overshoot the notch by a few points
and the Dock takes the drag into Mission Control before perch ever sees a
`draggingEntered:`.

Perch cannot defend against this from inside the app. The Dock's edge monitor
runs above every window level, so no panel can shadow it, and intercepting the
drag would require a `CGEventTap` — an Accessibility grant perch deliberately
refuses to ask for (see Permissions above). A system toggle is the honest fix,
and it is reversible in the same place.

The [nebelhaus](https://github.com/nebelhaus/nebelhaus) rice sets this for you
whenever `nebelhaus.perch.enable` is on. Standalone cask installs should flip it
by hand, once.
