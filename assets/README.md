# Visual assets

Perch's mark is the family's paired cat-ears sitting over its own detail: two
overlapping cards — the shelf. Drawn as flat geometry in the
[nebelung](https://github.com/hausfold/nebelung) palette, graphite against the
muted green accent, so it reads at 16 px and sits next to the rest of the family.

| file | what it is |
|---|---|
| `perch-banner.png` | 1200×348 identity banner — the green wordmark beside the mark on a rounded graphite tile, on the family's shared banner lockup. What the README opens with. |
| `perch-icon-master.png` | 2048×2048 source for the native macOS app-icon slots — green mark on a dark graphite tile. |
| `perch-square.png` | The square mark on graphite. Used for the web logo and social card. |
| `perch-square-inverted.png` | The inverted variant — dark mark on a green tile. |

The files in `Perch/Assets.xcassets/AppIcon.appiconset` are mechanically scaled
from `perch-icon-master.png`. Keep the master rather than upscaling an icon slot.

`PerchIOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png` comes from the same
master, with three differences iOS requires: it is a single 1024×1024 slot (iOS
derives the rest), it is **flattened onto the mark's own graphite** — an iOS app
icon may not carry an alpha channel, and iOS masks its own squircle, so the
master's rounded corners would otherwise show as transparent notches — and the
mark is **inset 9%**, because the master bleeds its lower card off the tile edge
and iOS's mask is tight enough to clip that into a fragment at 60 pt.
