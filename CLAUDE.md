# Morsel

Morsel is the native macOS notch file shelf in the nebelhaus family.

## Non-negotiable invariants

- Never move, rename, edit, or delete a source URL.
- All blocking file coordination, cloud waiting, and copies stay off main.
- File promises are handled before ordinary URLs.
- Outgoing drags advertise copy only.
- Persist relative staged paths only; never persist or log original paths.
- A visible `ShelfItem` must point at a completed staged representation.
- Keep display/window code out of importing and persistence.

## Build

```sh
xcodebuild -project Morsel.xcodeproj -scheme Morsel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Read `PRD.md`, `ARCHITECTURE.md`, and the ADRs before changing transfer
semantics. Update them when a product boundary changes.
