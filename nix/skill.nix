# perch's agent skills, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — the same file `perch skill`
# prints, which is baked into the CLI by `scripts/embed-skills.sh`. This
# derivation is how a *consumer* gets it: haus takes perch as a flake input
# already, so `pkgs.perch-skill` is all its AI room needs in order to drop the
# skill into every agent client on the machine. A standalone user gets the
# identical bytes from `perch skill install`.
#
# `$out/<skill>/SKILL.md` is the family standard's compliant-tool layout (the
# workshop's docs/agent-surface.md): one nesting level, named for the skill, so
# a consumer links a directory that is already called the right thing and the
# TOOL decides its skill's folder name rather than whoever installs it. haus's
# own skill is flat, `$out/SKILL.md` — it predates the standard, and is the one
# exception rather than the pattern. Skill names are globally unique across the
# family: they all land in one shared `~/.claude/skills/`.
#
# The guards are `scripts/check-skills.sh`, not a `runCommand` body, because
# perch's CI builds Xcode targets with no Nix at all — a guard living only here
# would run on a developer's machine and nowhere else. `.github/workflows/build.yml`
# runs the same script. Both this and the loop below DISCOVER the skills rather
# than naming them, so a second skill needs no edit in either place.
{
  lib,
  runCommand,
}:

runCommand "perch-skill"
  {
    meta = {
      description = "Agent skill teaching a coding agent to put files on the perch shelf";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
  ''
    ai=${../ai}
    bash ${../scripts/check-skills.sh} "$ai" perch

    mkdir -p "$out/perch"
    cp "$ai/SKILL.md" "$out/perch/SKILL.md"

    for dir in "$ai"/*/; do
      [ -f "$dir/SKILL.md" ] || continue
      name="$(basename "$dir")"
      mkdir -p "$out/$name"
      cp "$dir/SKILL.md" "$out/$name/SKILL.md"
    done
  ''
