# Copilot instructions

**Read [`AGENTS.md`](../AGENTS.md) at the repo root first — it is the full,
authoritative instruction set for every agent working here, and this file is
only a pointer to it.** (Copilot doesn't follow file imports, hence the
duplication below; if the two ever disagree, `AGENTS.md` wins.)

The short version:

- Perch is the native macOS **notch file shelf** in the
  [hausfold](https://github.com/hausfold) family: drag files onto the notch,
  they stage there, drag them back out.
- **The invariants are non-negotiable, and most of them are about not losing a
  user's file.** Never move, rename, edit or delete a source URL; persist only
  relative staged paths (never original paths, not even in a log); a visible
  `ShelfItem` must point at a *completed* staged representation.
- **Blocking work stays off the main thread** — file coordination, cloud
  download waits, copies. File promises are resolved before ordinary URLs, and
  outgoing drags advertise copy only.
- Keep display/window code out of importing and persistence; read `PRD.md`
  and `ARCHITECTURE.md` before touching transfer semantics, and update them
  when a product boundary moves. (There is no ADR tree — it was deleted on
  2026-08-20 and each decision restated where it binds.)
- **Versions are dates and CI owns them.** `VERSION` (CalVer) is the source of
  truth, cut with `bench release perch` from the workshop; the release workflow
  rewrites `nix/release.nix` and `Casks/perch.rb`. Never hand-type a version or
  hand-bump a pin.

For review comments, the same bar applies as anywhere in the family:
correctness and boundaries (does this change belong in *this* repo?) over style.
