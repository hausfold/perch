#!/usr/bin/env bash
#
# assert-arm64-only.sh — fail if any Mach-O under the given paths carries a
# slice other than arm64, or has no arm64 slice at all.
#
# WHY THIS EXISTS
#
# perch is Apple Silicon only, and the install routes promise that in prose long
# before anything checks it. Nothing downstream of the compiler does: a bundle
# with the wrong slices signs, notarizes, staples, passes
# `spctl --assess` and satisfies `PerchSigning.payloadRequirement` exactly like
# a right one, because not one of those steps is about architecture — so the
# first reader of the actual property is whoever double-clicks the download and
# gets "not supported on this Mac".
#
# It has already gone wrong once by accident. `-destination 'platform=macOS'`
# matches TWO destinations on an Apple Silicon Mac — `arch:arm64` and
# `arch:x86_64`, the same "My Mac" id twice — and xcodebuild takes the first,
# narrowing the build to it. The project declares no `ARCHS` of its own, so
# `-showBuildSettings` resolves `ARCHS_STANDARD` and prints the universal
# `arm64 x86_64` — reading the settings confirms the wrong answer, and only the
# command line disagrees. Which slice shipped was a property of
# the runner rather than a decision; on an Intel runner it would have been
# x86_64, published under a cask that refuses Intel. Note that
# `-showdestinations` lists only `My Mac (arch:arm64)` and `Any Mac`, so
# checking there reads as reassuring while the matcher disagrees — the build's
# own "Using the first of multiple matching destinations" warning is the honest
# surface, and it had been printing in every release run.
#
# Usage:
#   scripts/assert-arm64-only.sh <path>…      an .app bundle, or a binary
#
# Exits 0 only if it examined at least one Mach-O and every one was arm64 alone.

set -euo pipefail

WANT=arm64
examined=0
wrong=()

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    printf 'error: %s does not exist — the guard had nothing to check, which is a failure, not a pass.\n' "$target" >&2
    exit 1
  fi

  # Deliberately the same sweep as assert-no-instrumentation.sh, for the same
  # reasons: no -perm filter, because git preserves only the exec bit and a
  # vendored .dylib arrives 0644; -H so a symlinked bundle path (nix installs
  # Perch.app as a store symlink) is followed rather than skipped. Naming the
  # binaries instead would be a guard that keeps passing on the three names it
  # knows the day a framework or an XPC service joins an embed phase.
  while IFS= read -r f; do
    # LC_SEGMENT is what separates Mach-O from everything else in a bundle —
    # nibs, Assets.car, plists, shell scripts. otool exits 0 on a plain text
    # file and simply prints nothing, so its status filters nothing.
    load_commands="$(otool -l "$f" 2>/dev/null)" || continue
    [[ "$load_commands" == *LC_SEGMENT* ]] || continue
    examined=$((examined + 1))
    slices="$(lipo -archs "$f" 2>/dev/null || true)"
    if [[ "$slices" != "$WANT" ]]; then
      wrong+=("$f [${slices:-unreadable}]")
    fi
  done < <(find -H "$target" -type f 2>/dev/null)
done

if (( examined == 0 )); then
  printf 'error: found no Mach-O binaries under: %s\n' "$*" >&2
  printf '       A guard with no subject has failed, not passed — check the path.\n' >&2
  exit 1
fi

if (( ${#wrong[@]} > 0 )); then
  printf 'error: %d binary(ies) are not %s alone:\n' "${#wrong[@]}" "$WANT" >&2
  printf '  %s\n' "${wrong[@]}" >&2
  cat >&2 <<'WHY'

perch ships one slice, and every install route promises which one. A universal
bundle would run on an Intel Mac we do not support; an x86_64 bundle would run
on none of the Macs we do.

Check that the build names its architecture rather than inheriting the
builder's, and mind that `-destination 'platform=macOS'` alone resolves to
whichever arch the machine lists first:

  xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
    -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
WHY
  exit 1
fi

printf 'clean: %d Mach-O binary(ies) examined, all %s\n' "$examined" "$WANT"
