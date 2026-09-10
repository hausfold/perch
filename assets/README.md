# Visual assets

Perch's mark is the family's paired cat-ears sitting over its own detail: two
overlapping cards — the shelf. Drawn as flat geometry in the
[nebelung](https://github.com/hausfold/nebelung) palette — graphite against the
muted green accent, and a light tile in the latte set where the ground is
lightest and the cards step darker — so it reads at 16 px and sits next to the
rest of the family.

| file | what it is |
|---|---|
| `perch-banner.png` | 1200×348 identity banner — the green wordmark beside the mark on a rounded graphite tile, on the family's shared banner lockup. What the README opens with. |
| `perch-square.svg` | **The mark's source of record.** The same geometry in a 100-unit viewBox, colours as nebelung hexes; the brand kit's `docs/design.md` is the standard it answers to. The two dark PNGs below are it rendered at 592² and 2048². |
| `perch-square-inverted.svg` | **The inverted mark's source of record.** `perch-square-inverted.png` renders from it, at 592². |
| `perch-square-latte.svg` | **The light tile's source of record.** The same geometry in nebelung's latte set, where the ramp runs the other way: the tile is `base` (#f1f1f1) and the back card `surface1` (#c0c0c0) steps darker than it, with the front card and the ears in latte `green` (#4a9e3a) — a small accent inside a story shape keeps the product colour here as it does on the inverted tile. There is no light *inverted* tile: an inverted one already carries its own colour. |
| `perch-square-latte.png` | The light tile on latte base, 592², rendered from it. |
| `perch-icon-ios.svg` | **The iOS icon's source of record.** The same mark with what iOS requires drawn in: the graphite ground bleeds to the edge, and the mark is inset 9%. `PerchIOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png` is checked against it at 1024², and renders from it the next time the mark moves. |
| `perch-icon-master.png` | 2048×2048 source for the native macOS app-icon slots — green mark on a dark graphite tile. |
| `perch-square.png` | The square mark on graphite. Used for the web logo and social card. |
| `perch-square-inverted.png` | The inverted variant — dark mark on a green tile. |

When a nebelung token moves, swap it in every SVG here, re-render every PNG
below, then regenerate the macOS icon slots from `perch-icon-master.png`. resvg is what the committed PNGs were checked against;
a different rasteriser will not land byte-for-byte on them.

```sh
nix run nixpkgs#resvg -- -w 592  assets/perch-square.svg assets/perch-square.png
nix run nixpkgs#resvg -- -w 2048 assets/perch-square.svg assets/perch-icon-master.png
nix run nixpkgs#resvg -- assets/perch-square-inverted.svg assets/perch-square-inverted.png
nix run nixpkgs#resvg -- -w 592  assets/perch-square-latte.svg assets/perch-square-latte.png
nix run nixpkgs#resvg -- assets/perch-icon-ios.svg "$TMPDIR/perch-icon-ios.png"
nix run nixpkgs#imagemagick -- "$TMPDIR/perch-icon-ios.png" -alpha off \
  PNG24:PerchIOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png
```

The iOS icon takes the second command because resvg always writes RGBA and iOS
refuses an alpha channel. Every pixel that SVG draws is already opaque, so
dropping the channel changes no colour.

The files in `Perch/Assets.xcassets/AppIcon.appiconset` are mechanically scaled
from `perch-icon-master.png`. Keep that PNG master rather than upscaling an icon
slot.

`PerchIOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png` answers to
`perch-icon-ios.svg` rather than to the master, because iOS wants the mark
drawn three ways the master isn't: a single 1024×1024 slot (iOS derives the
rest), **flattened onto the mark's own graphite** — an iOS app icon may not
carry an alpha channel, and iOS masks its own squircle, so the master's rounded
corners would otherwise show as transparent notches — and the mark **inset 9%**,
because the master bleeds its lower card off the tile edge and iOS's mask is
tight enough to clip that into a fragment at 60 pt.

`perch-square-latte.png` is the exception in the other direction: it was
rendered from its SVG, so it round-trips byte for byte. The three below do not.

That PNG was drawn before the SVG existed and is checked against it, not
re-rendered from it: at resvg 0.48.1 the two agree on 98.9% of pixels and no
channel differs by more than 54/255, which is antialiasing along the shapes'
edges. The dark PNGs are the same story at this version — 1.0% of
`perch-square.png`, 0.3% of `perch-icon-master.png` — so the iOS icon is not
the odd one out. Re-render it, with the two commands above, the next time the
mark moves.
