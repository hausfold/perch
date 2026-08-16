# The published Perch.app release this flake installs.
#
# CI-OWNED: perch's release workflow (release.yml, the `bump-flake` job) rewrites
# these on every tag — the SAME version + SHA it stamps into the Homebrew cask
# (hausfold/homebrew-tap, Casks/perch.rb), at the same moment. The flake wraps
# the CI-built, Developer-ID-signed, Apple-notarized release ZIP rather than
# compiling from source: perch is an Xcode project, and macOS 26 blocks a
# `_nixbld` build user from applying SwiftPM's manifest sandbox (unlike pounce,
# which is plain `swiftc` with no packages) — so the release artifact is the only
# buildable-anywhere handle on the app. See ../nix/package.nix.
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release .zip's SHA-256 in hex (what `sha256sum`
# prints — the same value the cask stores).
{
  version = "2026.08.16-2";
  sha256 = "666a60ed66295ad99d5c937dc745c4099e6afe3e5a442ac4127b186205c747f3";
}
