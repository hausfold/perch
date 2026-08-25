#!/usr/bin/env bash
#
# assert-no-instrumentation.sh — fail if any Mach-O under the given paths was
# built with profiling instrumentation.
#
# WHY THIS EXISTS
#
# `ENABLE_CODE_COVERAGE = NO` is pinned project-wide (see AGENTS.md) because
# Xcode's default is YES and the Xcode 26 build service applies it to a plain
# `build`, not just to `test`. An instrumented binary is *behaviourally
# identical* — it runs, it passes tests, it notarizes — and the only symptom is
# that LLVM's profile runtime writes a `default.profraw` into whatever
# directory the process exits in. `perch` is on PATH everywhere and its Quick
# Action runs from Finder's cwd, so those files landed in whichever repo the
# shell was sitting in and read as untracked work to `holt reap` and
# `bench status`, which then refuse to sweep the checkout.
#
# A setting nothing checks is a setting that comes back. hausfold/trill#14 is
# the same bug in the sibling repo, found two days after perch pinned the
# setting and never noticed it had drifted — because nothing was watching.
#
# Usage:
#   scripts/assert-no-instrumentation.sh <path>…      an .app bundle, or a binary
#
# Exits 0 only if it examined at least one Mach-O and none carried the section.

set -euo pipefail

MARKER=__llvm_prf_cnts
examined=0
dirty=()

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    printf 'error: %s does not exist — the guard had nothing to check, which is a failure, not a pass.\n' "$target" >&2
    exit 1
  fi

  # No -perm filter on the find below: git preserves only the exec bit, so a
  # committed or vendored .dylib/.framework arrives 0644 and an executable-only
  # sweep would walk straight past it — a guard that can silently pass is the
  # failure mode this script exists to end. -H so a symlinked bundle path (nix
  # installs Perch.app as a store symlink) is followed rather than skipped.
  while IFS= read -r f; do
    # The LC_SEGMENT test is what separates Mach-O from everything else in a
    # bundle — nibs, Assets.car, plists, shell scripts. Don't be tempted to
    # lean on otool's exit status instead: it returns 0 on a plain text file
    # and simply prints nothing, so `|| continue` alone would filter nothing.
    load_commands="$(otool -l "$f" 2>/dev/null)" || continue
    [[ "$load_commands" == *LC_SEGMENT* ]] || continue
    examined=$((examined + 1))
    # No `| grep -q`: under `set -o pipefail`, grep exits at its first match,
    # otool takes a SIGPIPE, and the pipeline status is 141 — so a hit would
    # read as a miss and this guard would wave through exactly what it exists
    # to stop.
    if [[ "$load_commands" == *"$MARKER"* ]]; then
      dirty+=("$f")
    fi
  done < <(find -H "$target" -type f 2>/dev/null)
done

if (( examined == 0 )); then
  printf 'error: found no Mach-O binaries under: %s\n' "$*" >&2
  printf '       A guard with no subject has failed, not passed — check the path.\n' >&2
  exit 1
fi

if (( ${#dirty[@]} > 0 )); then
  printf 'error: %d binary(ies) carry %s — built with profiling instrumentation:\n' "${#dirty[@]}" "$MARKER" >&2
  printf '  %s\n' "${dirty[@]}" >&2
  cat >&2 <<'WHY'

Shipping these would drop a `default.profraw` into the working directory of
every process that runs them — including whatever repo a `perch` invocation
happens to be sitting in, which `holt reap` then refuses to sweep.

Check that ENABLE_CODE_COVERAGE is still NO in both project-level build
configurations, and that nothing reintroduced it via an xcconfig or a scheme:

  xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
    -showBuildSettings | grep ENABLE_CODE_COVERAGE
WHY
  exit 1
fi

printf 'clean: %d Mach-O binary(ies) examined, none instrumented\n' "$examined"
