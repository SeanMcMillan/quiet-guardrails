# quiet-guardrails

**manual mode, minus the nagging** — deterministic guardrails that quiet the safe prompts in Claude Code and keep you in control.

A single PreToolUse hook + a curated allowlist that make Claude Code **stop asking about safe work and start self-correcting its own bad habits** — while still forcing a confirmation on the few things that genuinely deserve one.

It's a deliberate alternative to auto mode. Where auto mode asks an LLM classifier to judge each action (probabilistic, opaque, per-call), this takes the opposite bet: **make the model's default behavior correct and frictionless, deterministically**, and keep *you* in control of exactly what runs unattended.

## The idea

Most Claude Code prompt fatigue isn't from dangerous commands — it's from safe ones dressed in shell habits: a `grep` piped into `wc`, a `cmd 2>&1 | tail`, a `cd repo && git status`, an `npx jest` instead of `npm test`. Each is harmless, none matches an allowlist, so each prompts. People get tired of approving them and flip on a blanket "just allow everything" mode — trading away all oversight to escape the noise.

This hook attacks the root instead. When the model reaches for one of those shapes, the hook **blocks it with `exit 2` and a one-line correction on stderr** ("run it bare — the harness already returns stdout, stderr, and the exit code"). The model reads that, rewrites the command into the plain form, and retries. **You never see a prompt, because the command that finally runs is the one your allowlist already trusts.** The model also, over a session, stops producing the bad shapes at all.

A few principles fall out of that:

- **Sanity > prompts > tokens.** Pick the correct, reviewable command first; avoid a needless prompt second; save keystrokes/tokens last. The recurring failure is inverting it — a "clever" one-liner that saves a token but prompts and mutates blind.
- **A block should mean "rewrite," not "bypass."** So the escape hatch (below) is *never mentioned in a rule's message*. When you're blocked, the only thing on screen is how to do it right — reaching for the override is a conscious act, not the reflex.
- **Force the prompts that should exist.** Claude Code read-only-*misclassifies* some git subcommands — `git add`, `git reset`, `git branch -D`, `git commit`, `git push` — so they auto-approve with no prompt. The guard overrides that and forces a confirmation. The index and your uncommitted work are yours.
- **Success is silent, so measure it.** Every use of the escape hatch is appended to a log, so "no prompts" can't quietly hide overuse.

## What it does

**Self-corrects (exit 2 → the model rewrites, no prompt):**

| Shape | Correction |
|---|---|
| `grep`/`find` piped or in `$(...)` | run the search bare, act on the result in a separate call (`… | wc -l` counts are exempt) |
| `cat`, leading `head`/`tail` on a file | use the Read tool |
| `cmd | tail`, `cmd 2>&1`, `echo $?`, `cmd > /tmp/…` | run it bare — the harness returns full stdout/stderr + exit status |
| `for`/`while` loop | separate/parallel tool calls |
| `cd repo && git …` | standalone `cd`, then plain git |
| `git -C <path> …` | plain git (or standalone `cd`) |
| `npx jest` / raw `eslint` when a script wraps it | `npm run <script>` |
| `sed -i`, `node -e … writeFile` | the Edit/Write tool |
| `python`/`node` parsing JSON | `jq` |

**Forces a confirmation (`permissionDecision: ask`):**

- Mutating `git branch` (`-f`/`-d`/`-D`/`-m`/`-c`), which CC auto-approves.
- Any index/worktree/history mutation: `add reset restore rm stash checkout switch clean commit push`.

**The escape hatch:** put `#override` anywhere in a command to skip the *overreach* rules (never the safety gates). Use it for the rare genuinely-necessary pipeline. Every use is logged to `~/.claude/hooks/override-escapes.log`.

## Install

1. Copy the hook and make it executable:
   ```bash
   mkdir -p ~/.claude/hooks
   cp hooks/guard-bash-overreach.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/guard-bash-overreach.sh
   ```
2. Wire it into Claude Code settings (`~/.claude/settings.json` for all projects, or a project's `.claude/settings.local.json`). Merge the `hooks` block and the starter `allow` list from [`settings.example.json`](settings.example.json).
3. Requires `jq` on your PATH.

The hook is re-read on every Bash call, so edits take effect immediately. The allowlist is read at session start — reload settings (or restart) after editing it.

## Growing your allowlist

The hook shrinks how big your allowlist needs to be (it corrects shapes instead of demanding an entry), but you still add the safe commands *your* project uses. The method:

1. **Don't pre-guess.** When a safe command prompts, add it — that's the signal.
2. **Add read-only and idempotent commands**, scoped tight: `Bash(npm run test)`, `Bash(npm run build)`, `Bash(git diff *)`. Keep mutations and network/arbitrary-code out (let them prompt).
3. **Prefer the wrapped form.** Allowlist `npm run <script>`, not the raw tool — the script carries required flags, and Rule 10 steers you there anyway.
4. **Wildcards cross spaces but not `/`** in Claude Code's matcher; a trailing `:*` is legacy *prefix* matching (which turns an earlier `*` literal). Pin host/port literals in URL rules (`http://localhost:3000*`, not `http://localhost:*`) so look-alike hosts don't match.
5. **Skills can re-open doors.** A skill's `allowed-tools` frontmatter is an *additive grant* — a blanket like `Bash(some-cli:*)` auto-approves every subcommand of that CLI while the skill runs, overriding your settings. Audit skill frontmatter, not just settings.

## Caveats

- **It's opinionated and tuned to a specific setup** (see the ENVIRONMENT ASSUMPTIONS block at the top of the hook): a native Claude Code build where `grep` is ugrep and there are no Grep/Glob tools, and npm projects for the `npm run` rule. On other builds some corrections flip (e.g. bare grep/find would steer to Grep/Glob tools). Read the rules before adopting; they're plain shell and easy to trim.
- The git safety gates assume *you* drive staging/commits/pushes. If you want an agent to commit unattended, drop `commit`/`push` from Rule 8b.
- These are heuristics on command *strings*, not a sandbox. They reduce prompts and teach better habits; they are not a security boundary.

## License

[0BSD](LICENSE) (SPDX: `0BSD`; [OSI-approved](https://opensource.org/license/0bsd)) — public-domain-equivalent, no attribution required. Take it and do whatever you want with it.
