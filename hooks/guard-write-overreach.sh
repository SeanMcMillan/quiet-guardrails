#!/usr/bin/env bash
# PreToolUse guard for the Write tool — the companion to guard-bash-overreach.sh.
#
# WHAT IT DOES. One rule today: catch a repo-destined TEST file being authored into
# the scratchpad / tmp. Tests only run inside the repo (its jest config + module
# resolution), so a test written to the scratchpad is a dead end that then becomes a
# `cp <tmp> <repo>` — a shell copy that prompts AND, for a Next.js route-group
# destination like `[locale]`/`[periodKey]`, trips Claude Code's quote-blind "glob
# patterns not allowed in write operations" filter (the brackets read as a glob even
# though they're a literal dir). The Write tool takes LITERAL paths, so authoring
# straight at the repo path — brackets and all — skips both problems.
#
# This fires at the ORIGIN (the tmp Write), which a Bash PreToolUse hook can't reach:
# by the time the `cp` shows up the tmp file already exists. A block means "rewrite"
# — author the file at its repo path — same as the Bash guard's exit-2 corrections.
#
# Wire it in settings alongside the Bash guard, matched to the Write tool. Requires
# jq (ships with Claude Code). Fails open on a parse hiccup.

input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
[ -n "$fp" ] || exit 0

# A test/spec file (jest/vitest naming) …
printf '%s' "$fp" | grep -Eq '\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$' || exit 0
# … written into a scratchpad / tmp location (not the repo).
printf '%s' "$fp" | grep -Eq '(/scratchpad/|^/tmp/|^/private/tmp/|/var/folders/)' || exit 0

echo "Overreach: a test written into the scratchpad won't run — jest only discovers tests under the project's own roots, so this becomes a 'cp' into the repo (which prompts, and trips Claude Code's glob-write filter on route-group dirs like [locale]). Author the throwaway probe INSIDE the project instead: a gitignored scratch dir if the project has one (jest still finds it; git/tsc/eslint skip it), otherwise the target __tests__ dir. Run it, then delete it — it stays out of commits without living in tmp." >&2
exit 2
