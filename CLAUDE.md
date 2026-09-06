# CLAUDE.md

@AGENTS.md

Claude-only wiring: `.claude/settings.json` runs `SessionStart` → `.agents/setup.sh`.
The `WorktreeCreate`/`WorktreeRemove` hooks (`scruff hook create` / `scruff hook remove`) live in your `~/.claude/settings.json`, declared by haus.
The cross-harness map is [`.agents/README.md`](./.agents/README.md).
