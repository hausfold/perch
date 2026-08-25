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

Each import gets its own UUID directory — that's what prevents name collisions
without renaming your file. The manifest records only **staged relative paths**
and file metadata; original source paths are never persisted, and never logged.

To get a copy out without dragging — the destination is a folder nothing has
open, or the item is pinned and you just want it on disk — right-click a tile
and pick **Save to…**. It writes a copy wherever you point the panel and leaves
the tile exactly where it was, replacing an existing file only once the new
copy is whole; only the panel can hand a sandboxed Perch a path
outside its container, which is why there is no fixed *Save to Downloads*.

Clearing an item deletes its whole import directory — the staged copy is deleted
outright rather than moved to the Trash, so **Clear asks first**: the shelf's
Clear button arms and needs a second click, and the menu bar's *Clear Shelf…*
raises an alert. The expiry timer under Settings ▸ Shelf is **off by default**
(*Discard items after: Never*); turn it on and pinned items are still exempt.

## The shelf, in detail

The behaviors the README summarises, spelled out:

- **The catch zone finds the notch.** The drop target hugs the physical camera
  housing when a display has one, and falls back to a tidy top-center band on
  notchless screens. Either way the collapsed shelf draws no chrome of its
  own: no synthetic notch, no tray.
- **You can see it's holding something.** A staged shelf lights a small accent
  ember under the camera housing (under the menu bar on a notchless screen),
  with a pip per item and a flare as each one lands. It says the shelf is
  holding something, not exactly how much; for that, open it.
- **Awkward producers land correctly.** Photos exports, Safari images, and
  other apps that hand files over lazily (AppKit "file promises") go down
  their own import path, so they arrive whole instead of empty.
- **It stays responsive.** Imports run off the main thread with a
  two-at-a-time limit, and iCloud placeholders are downloaded explicitly,
  waiting outside that limit, so a slow download never holds up an ordinary
  drop and a multi-gigabyte file never stops the shelf animating.
- **Drag-out is a group, and clears the shelf.** Grab any tile and every
  completed item comes with it, advertised as a copy. Once a destination
  accepts the drop the item leaves the shelf; a refused or cancelled drag
  springs the tiles back.
- **Pinning.** A pinned tile stays on the shelf after a successful drag,
  ready to drop into several destinations in quick succession, and survives
  relaunch. Unpinning restores the usual one-and-done behavior.
- **It follows you around.** One panel per display, tracking Space,
  fullscreen, and Stage Manager changes with public AppKit behavior. On Tahoe
  it wears `NSGlassEffectView`; older systems get an AppKit material fallback.
- **If the Services entry goes missing**: it's on by default, but the
  checkbox lives in System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸
  Services, under **Files and Folders**, as *Add to Perch Shelf*.

## Watched folders

Settings ▸ Watched Folders keeps a list of folders whose **new** files land on
the shelf by themselves — `~/Downloads`, a scans folder, wherever things
arrive. Everything about it is copy-only: the arrival is staged like a drop,
the original never moves, and clearing the tile — or letting the retention
timer expire it — deletes perch's copy and nothing of yours.

**Shelf my screenshots** is the same thing with the finding-out done for you.
Flipping it opens the same folder panel, already pointed at wherever this Mac
saves captures: what `screenshotsFolder` in `~/.config/perch/config.json` says
(haus writes that key from `haus.screenshots.location`, when
`haus.shelf.watchScreenshots` is on), else the Desktop,
which is macOS's own default. Perch cannot simply read the setting — a
sandboxed app is not shown another app's preferences — and it cannot grant
itself the folder either, so the panel stays: the click is the permission.
Pick a different folder in it and that one becomes your screenshots folder,
because you know where they go and perch was guessing — and a folder already
in the list is adopted rather than added twice.

Switching it off takes that folder out of the watched list altogether:
everything already on the shelf stays, nothing new arrives on its own, and
turning it back on means the panel again (the grant went with the folder).
That is the same folder the list below shows, so if you added it for other
reasons too, this is the switch that removes it.

One macOS setting is worth turning off alongside it: the floating screenshot
thumbnail. It doesn't preview a saved file, it *holds* the capture and writes
it out about five seconds later, so the shelf catches every screenshot five
seconds after you took it. System Settings has no switch for it; the
screenshot toolbar's Options ▸ Show Floating Thumbnail does, and on a haus
machine `haus.shelf.watchScreenshots` turns it off for you.

What already sits in a folder when you add it stays off the shelf; only what
arrives afterwards lands, including things that arrived while perch wasn't
running. **Replacing a file's contents counts as a new arrival** — download or
save over one twice and you get two tiles, because what is there now is a
different file wearing the old one's name. Renaming doesn't: the tile you
already have is that file, whatever it is called now.
Half-written downloads (`.crdownload`, `.part`, `.download`…) wait
until they finish and are renamed — that rename is the real completion signal —
and any other file is imported only after its size has stopped changing for a
moment, so a normally written file never lands mid-write. (A writer that stalls
for over a second can still be shelved early; the probe is a net under the
naming convention, not a proof of doneness. A download that stalls that long and
then resumes gives you **two** tiles — the short one perch shelved during the
stall, and the finished file — because by the rule above the finished file is a
different file. Clear the short one; the complete one is the later tile.) New folders appearing inside a watched
folder are not auto-imported; folders still reach the shelf through every
deliberate door. **Dragging an item out of the shelf into a watched folder
does not put it back** — perch recognises what it just wrote and ledgers it
without shelving it, so dropping onto a watched Desktop behaves like dropping
anywhere else. A watched folder copies what arrives and never touches the
original — same invariant as every other door.

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

That file carries one non-colour key as well — `screenshotsFolder`, which
tells the screenshots switch where this Mac saves captures (see [Watched
folders](#watched-folders)). Anything perch doesn't recognise is ignored.

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
permission, and has no Dock icon. It sees only what you drop on it and the
folders you pick for it to watch.

It is sandboxed, with one read-only exception: `~/.config/perch/`, where the
theme above lives. That is the only path Perch opens that a drag or a file picker
didn't hand it, and it is never written. A watched folder is picker-granted
too — perch just keeps that grant across relaunches as an app-scoped security
bookmark (the `files.bookmarks.app-scope` entitlement), one per folder,
dropped the moment you stop watching it.

There is no telemetry. Nothing about your files is written to a log.

Perch touches the network in exactly two ways, and only one of them leaves your
home.

**Out to the internet:** an hourly unauthenticated GET to `api.github.com` for
perch's own latest release tag, so the shelf can tell you a new version is out.
It carries nothing but an IP and a user-agent, downloads no file, and
Settings ▸ Updates switches it off. That is what
`com.apple.security.network.client` is for.

**On your own network:** with Settings ▸ Devices on — it ships on — perch
advertises `_perch._tcp` over Bonjour and listens for a paired iPhone or iPad
(`com.apple.security.network.server`). Only a device you paired by scanning the
QR code — or pasting the same offer as a line of text — can connect, the
transfer is end-to-end encrypted, and nothing about it
goes through a server of ours — there isn't one. Settings ▸ Devices switches
the listener off entirely.

That link is **peer-to-peer**, so it works with no network at all: every wire
path sets `includePeerToPeer`, which lets delivery run over AWDL — the same
direct radio link AirDrop uses. Turning Wi-Fi off in Control Center leaves AWDL
up on purpose, so your phone still finds your Mac; Airplane Mode, or
Settings ▸ Wi-Fi ▸ Off, is what actually takes the link down. All it needs is
the Wi-Fi radio switched on at both ends — no router, and not the same one. If
your phone delivers to a Mac that looks offline, that is the feature working.

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

Perch nudges and never installs: it has no self-updater, so the copied command
is always the one your install method understands.

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
whenever `haus.shelf.enable` is on. Standalone cask installs should flip it
by hand, once.
