#!/usr/bin/env bash
# The two verbs that need no shelf, checked against a real binary.
#
# `perch skill` and `perch doctor` are the whole agent surface: a stranger's
# agent reads the first to learn perch exists, and runs the second when the
# shelf misbehaves. Both are pure enough to exercise from a script with no app
# running, no container and no notch — which is exactly why they can rot
# unnoticed, since nothing else in the suite compiles PerchCLI.
#
# So this pins the *documented contract*: the bytes `skill` prints, and the exit
# codes `skill install` and `doctor` promise in `docs/cli.md`, `ai/SKILL.md` and
# `perch --help`. A change that breaks one of those breaks all three documents
# at once, silently.
#
# It never runs a bare `skill install` — every case names a throwaway `--dir`,
# because the bare form writes into the real `$HOME`.
#
# Usage: scripts/check-cli-surface.sh <path-to-perch-cli>
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] || { printf 'usage: check-cli-surface.sh <path-to-perch-cli>\n' >&2; exit 2; }
cli="$1"
[ -x "$cli" ] || { printf 'check-cli-surface.sh: not executable: %s\n' "$cli" >&2; exit 2; }
# Absolute, because one case below runs from a scratch directory and a
# DerivedData-relative path would stop resolving there (exit 127, not the
# usage code the case is asking about).
cli="$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")"

status=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; status=1; }

# One helper, because every case is the same shape: run it, check the exit code,
# keep the stdout for whatever the case wants to say about it. `out` is global
# rather than captured through a pipe on purpose — a pipeline would run this in
# a subshell and throw `status` away with it.
out=""
expect() {
  local want="$1" label="$2"; shift 2
  local rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass "$label"
  else
    fail "$label — expected exit $want, got $rc"
  fi
}

says() {
  printf '%s\n' "$out" | grep -q -- "$1" && pass "$2" || fail "$2"
}

tmp="$(mktemp -d)"
# The unwritable case stays unwritable until we put it back, or the trap cannot
# clean up after itself.
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

printf 'perch skill\n'

if "$cli" skill | cmp -s - "$root/ai/SKILL.md"; then
  pass 'prints ai/SKILL.md byte for byte'
else
  fail 'the printed skill differs from ai/SKILL.md'
fi

if diff -q <("$cli" skill) <("$cli" skill perch) >/dev/null; then
  pass "the tool's own name is the default"
else
  fail 'naming the tool prints something other than the default'
fi

expect 1 'an unknown skill name is a usage error' "$cli" skill nope
[ -z "$out" ] && pass 'and writes nothing to stdout' || fail 'it wrote to stdout'

expect 0 '--json answers' "$cli" skill --json
says '"name" : "perch"' '--json carries the name'

printf 'perch skill install\n'

expect 0 'writes into an empty --dir' "$cli" skill install --dir "$tmp/a"
says '^wrote ' 'and says so on stdout'
cmp -s "$tmp/a/perch/SKILL.md" "$root/ai/SKILL.md" \
  && pass 'the installed file is the source' \
  || fail 'the installed file differs from ai/SKILL.md'

expect 0 'a second run changes nothing' "$cli" skill install --dir "$tmp/a"
says '^current ' "and says 'current'"

printf 'tampered\n' >>"$tmp/a/perch/SKILL.md"
expect 2 'refuses to overwrite a file that differs' "$cli" skill install --dir "$tmp/a"
grep -q '^tampered$' "$tmp/a/perch/SKILL.md" \
  && pass 'and leaves it exactly as it found it' \
  || fail 'the differing file was overwritten'

mkdir -p "$tmp/b" && ln -s /nowhere "$tmp/b/perch"
expect 0 'leaves a symlink alone — the haus case is not a failure' "$cli" skill install --dir "$tmp/b"
[ -L "$tmp/b/perch" ] && pass 'and the symlink survives' || fail 'the symlink was replaced'

mkdir -p "$tmp/c" && chmod 500 "$tmp/c"
expect 4 'a write it cannot do is exit 4, not exit 0' "$cli" skill install --dir "$tmp/c"
chmod 700 "$tmp/c"

expect 1 'an unknown client is a usage error' "$cli" skill install --client emacs
expect 1 '--dir and --client together are refused' \
  "$cli" skill install --dir "$tmp/d" --client claude
[ ! -e "$tmp/d" ] && pass 'and nothing was written to --dir' || fail '--dir was honoured and --client dropped'

# An empty value is an unset shell variable, not a request. `--dir ""` used to
# resolve against the working directory and write a perch/SKILL.md there, which
# is why this runs from a scratch directory and looks for the file afterwards.
here="$PWD"
mkdir -p "$tmp/e" && cd "$tmp/e" || exit 2
expect 1 'an empty --dir is a usage error' "$cli" skill install --dir ""
expect 1 'an empty --client is a usage error' "$cli" skill install --client ""
expect 1 'a --dir with nothing after it is a usage error' "$cli" skill install --dir
expect 1 'a --client with nothing after it is a usage error' "$cli" skill install --client
[ ! -e "$tmp/e/perch" ] && pass 'and nothing landed in the working directory' \
  || fail 'an empty --dir wrote into the working directory'
cd "$here" || exit 2

printf 'perch doctor\n'

# 0 (ready) and 3 (something blocking) are both correct answers here — CI has no
# container and no shelf, a developer's Mac has both. Anything else is a bug:
# doctor must never report through a usage or transport code.
out="$("$cli" doctor 2>/dev/null)"
case "$?" in
0 | 3) pass 'exits 0 or 3, never a usage or transport code' ;;
*) fail "doctor exited with something other than 0 or 3" ;;
esac
printf '%s\n' "$out" | head -1 | grep -qE '^perch[ ,]' \
  && pass 'opens with the version line' \
  || fail 'the first line is not the version line'
printf '%s\n' "$out" | sed -n 2p | grep -qE '^macOS .* on ' \
  && pass 'and then the macOS/model line' \
  || fail 'the second line is not the macOS/model line'

json="$("$cli" doctor --json 2>/dev/null)"
missing=""
for key in version bundleID app launchServicesApp tool install installName \
  updateCommand os model container containerPresent running shelfItems ok checks; do
  printf '%s' "$json" | grep -q "\"$key\" :" || missing="$missing $key"
done
[ -z "$missing" ] \
  && pass '--json carries every documented key' \
  || fail "--json is missing:$missing"

expect 1 'an argument is a usage error' "$cli" doctor nonsense

printf 'perch --help\n'
expect 0 'prints and exits 0' "$cli" --help
says 'perch doctor' '--help names doctor'
says 'perch skill' '--help names skill'

exit "$status"
