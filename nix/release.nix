# The published Perch.app release this flake installs.
#
# CI-OWNED: perch's release workflow (release.yml, the `bump-flake` job) rewrites
# these on every tag — the SAME version + SHA it stamps into the Homebrew cask
# (nebelhaus/homebrew-tap, Casks/perch.rb), at the same moment. The flake wraps
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
  version = "2026.07.29";
  sha256 = "78e9d060e76066d13205946f4d0b60c3ee355a7753cb12e6bbf94a1788aa4aef";
}
