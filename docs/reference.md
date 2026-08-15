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
interactive build. Either way you also get the `perch` command line tool, built
into the bundle at `Perch.app/Contents/MacOS/perch-cli` — see
[the CLI](cli.md).

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
~/Library/Containers/com.hausfold.perch/Data/Library/Application Support/
  Perch/ActiveShelf/
```

Perch was `com.nebelhaus.perch` until 2026-08-08. If you ran a build from before
then, its shelf is still sitting in the old container, orphaned — the new one
starts empty. Nothing reads it any more, so it's safe to delete:

```sh
rm -rf ~/Library/Containers/com.nebelhaus.perch
```

Each import gets its own UUID directory — that's what prevents name collisions
without renaming your file. The manifest records only **staged relative paths**
and file metadata; original source paths are never persisted, and never logged.

To get a copy out without dragging — the destination is a folder nothing has
open, or the item is pinned and you just want it on disk — right-click a tile
and pick **Save to…**. It writes a copy wherever you point the panel and leaves
the tile exactly where it was; only the panel can hand a sandboxed Perch a path
outside its container, which is why there is no fixed *Save to Downloads*.

Clearing an item deletes its whole import directory — the staged copy is deleted
outright rather than moved to the Trash, so **Clear asks first**: the shelf's
Clear button arms and needs a second click, and the menu bar's *Clear Shelf…*
raises an alert. The expiry timer under Settings ▸ Shelf is **off by default**
(`Never discard old items`); turn it on and pinned items are still exempt.

## Colors

The shelf paints from a nebelung palette. Four variants are built in — the
default `nebelung` pair and their high-contrast counterparts — and the one in use
follows macOS Light/Dark:

```text
~/.config/perch/
  config.json          { "themeDark": "nebelung", "themeLight": "nebelung-latte",
                         "accent": "mauve" }
  themes/<name>.json   flat "role": "#hex" map — a nebelung *.hex.json verbatim
```

A file in `themes/` **shadows** a built-in of the same name, so a palette bump
lands without a new release, and any Catppuccin-shaped palette drops in under its
own name. Perch requires seven roles — `base`, `crust`, `overlay0`, `text`,
`subtext0`, `green`, `red` — plus whichever one `accent` names, and ignores the
rest; a missing or malformed file falls back to built-in nebelung rather than
failing.

`accent` is the one colour the shelf *emphasises* with — the ember's pips under
the notch, a pinned tile, the filled button on a notice. It takes either a
catppuccin role name (the fourteen `haus.theme.accent` offers, resolved
against whichever palette is in force, so the hue follows the flavour and the
polarity by itself) or a literal `"#rrggbb"` if you're hand-editing. Leave it
out and the shelf accents with the palette's own `green` — `#abe1a6` under stock
nebelung, which is perch's mark green, the exact sage of the app icon. A role
the palette doesn't carry, or a typo, falls back to that same green rather than
to a broken shelf.

Label colour on a filled accent is chosen for contrast against the accent
itself, not against the panel, so a pale accent gets dark ink and a deep one
gets light ink whichever polarity it lands in.

On a [haus](https://github.com/hausfold/haus) desktop all of this is
written for you from `haus.theme.flavor` / `.contrast` / `.accent`;
standalone installs can write the two files by hand or ignore them entirely.
Perch has no theme or accent picker: colors come from the rice, everything else
from Settings.

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

Perch makes exactly one kind of network call: an hourly unauthenticated GET to
`api.github.com` for perch's own latest release tag, so the shelf can tell you a
new version is out. It carries nothing but an IP and a user-agent, downloads no
file, and Settings ▸ Updates switches it off. That is what
`com.apple.security.network.client` is for.

## Updating

When a newer release exists, the open shelf grows a strip along its bottom edge
("Perch 2026.08.05 is out") and the menu bar menu grows a matching row. `✕`
dismisses that version — the next release asks again.

Perch never installs the update itself: being sandboxed, it cannot replace its
own bundle in `/Applications`, and it would rather tell you the truth than fail
quietly. So the button does whatever *your* install needs — it knows which one
you have:

| installed by | the button does |
| --- | --- |
| the haus desktop | copies `haus update` |
| Homebrew | copies `brew upgrade --cask perch` |
| a Nix store path | copies `nix flake update perch` |
| dragging the release ZIP | opens the release page |

See [ADR 0003](architecture-decisions/0003-update-nudge-without-self-update.md).

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

The [haus](https://github.com/hausfold/haus) desktop sets this for you
whenever `haus.perch.enable` is on. Standalone cask installs should flip it
by hand, once.
