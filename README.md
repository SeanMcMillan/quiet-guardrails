# quiet-guardrails

**manual mode, minus the nagging** — deterministic guardrails that quiet the safe prompts in Claude Code and keep you in control.

A single PreToolUse hook + a curated allowlist that make Claude Code **stop asking about safe work and start self-correcting its own bad habits** — while still forcing a confirmation on the few things that genuinely deserve one.

It's a deliberate alternative to auto mode. Where auto mode asks an LLM classifier to judge each action (probabilistic, opaque, per-call), this takes the opposite bet: **make the model's default behavior correct and frictionless, deterministically**, and keep *you* in control of exactly what runs unattended.

> **What it is — and isn't.** This *corrects a cooperative model's habits* (to cut prompts) and *forces a confirmation on a few risky git ops Claude Code waves through*. It is **not** a security boundary and does **not** defend against an adversarial or prompt-injected agent — a determined one can slip any string heuristic. It works **alongside** Claude Code's own allowlist and sandbox, not as a replacement for either: the sandbox is your wall against a hostile process; this is habit-correction for a well-behaved one.

## The idea

Most Claude Code prompt fatigue isn't from dangerous commands — it's from safe ones dressed in shell habits: a `grep` piped into `wc`, a `cmd 2>&1 | tail`, a `cd repo && git status`, an `npx jest` instead of `npm test`. Each is harmless, none matches an allowlist, so each prompts. People get tired of approving them and flip on a blanket "just allow everything" mode — trading away all oversight to escape the noise.

This hook attacks the root instead. When the model reaches for one of those shapes, the hook **blocks it with `exit 2` and a one-line correction on stderr** ("run it bare — the harness already returns stdout, stderr, and the exit code"). The model reads that, rewrites the command into the plain form, and retries. **You never see a prompt, because the command that finally runs is the one your allowlist already trusts.** The model also, over a session, stops producing the bad shapes at all.

A few principles fall out of that:

- **Sanity > prompts > tokens.** Pick the correct, reviewable command first; avoid a needless prompt second; save keystrokes/tokens last. The recurring failure is inverting it — a "clever" one-liner that saves a token but prompts and mutates blind.
- **A block should mean "rewrite," not "bypass."** So the escape hatch (below) is *never mentioned in a rule's message*. When you're blocked, the only thing on screen is how to do it right — reaching for the override is a conscious act, not the reflex.
- **Force the prompts that should exist.** Claude Code read-only-*misclassifies* some git subcommands — `git add`, `git reset`, `git branch -D` — so they auto-approve with no prompt. The guard overrides that and forces a confirmation. The index and your uncommitted work are yours.
- **Success is silent, so measure it.** Every use of the escape hatch is appended to a log, so "no prompts" can't quietly hide overuse.

## What it does

**Self-corrects (exit 2 → the model rewrites, no prompt):**

| Shape | Correction |
|---|---|
| `grep`/`find` piped or in `$(...)` | run the search bare, act on the result in a separate call (`… \| wc -l` counts are exempt) |
| `cat`, leading `head`/`tail` on a file | use the Read tool |
| `cmd \| tail`, `cmd 2>&1`, `echo $?`, `cmd > /tmp/…` | run it bare — the harness returns full stdout/stderr + exit status |
| `for`/`while` loop | separate/parallel tool calls |
| `cd repo && git …` | standalone `cd`, then plain git |
| `git -C <path> …` | plain git (or standalone `cd`) |
| `npx jest` / raw `eslint` when a script wraps it | `npm run <script>` |
| `sed -i`, `node -e … writeFile` | the Edit/Write tool |
| `python`/`node` parsing JSON | `jq` |

**Forces a confirmation (`permissionDecision: ask`) — the *workflow* gates:**

The default rules for Claude Code auto-approve some git ops (most notably, `git add`.) The guard forces the confirmation you'd want. Same purpose as the corrections above (your workflow, made deterministic), pointed the other way: those *remove* an unwanted prompt, these *add* a wanted one.

- Mutating `git branch` (`-f`/`-d`/`-D`/`-m`/`-c`), which CC auto-approves.
- Any index/worktree/history mutation: `add reset restore rm stash checkout switch clean commit push`.

**The escape hatch:** put `#override` anywhere in a command to skip the *overreach* rules (never the workflow gates). Use it for the rare genuinely-necessary pipeline. Every use is logged to `~/.claude/hooks/override-escapes.log`.

## Install

1. Copy the hook and make it executable:
   ```bash
   mkdir -p ~/.claude/hooks
   cp hooks/guard-bash-overreach.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/guard-bash-overreach.sh
   ```
2. Wire it into Claude Code settings (`~/.claude/settings.json` for all projects, or a project's `.claude/settings.local.json`). Merge the `hooks` block, the starter `allow` list, and the `defaultMode` from [`settings.example.json`](settings.example.json).
3. Verify it's wired — feed the hook a command that trips a rule and watch it correct you (run this in your own terminal):
   ```bash
   jq -nc --arg c 'cat somefile' '{tool_input:{command:$c}}' | bash ~/.claude/hooks/guard-bash-overreach.sh
   ```
   You should see `Overreach: 'cat' in a Bash call. Read files with the Read tool…` on stderr. Silence means the hook didn't run — check the path.

The sample sets **`defaultMode: acceptEdits`** — auto-accept in-project file edits (Edit/Write) while every Bash command stays under the guard and allowlist. That's the sweet spot this is built for: manual control over what *runs*, no friction on what you *write*. Use `default` (manual) if you want edits to prompt too — but not `auto`/`bypassPermissions`, which hand back the oversight this exists to keep.

The hook is re-read on every Bash call, so edits take effect immediately. The allowlist and `defaultMode` are read at session start — reload settings (or restart) after editing them.

## Growing your allowlist

The hook shrinks how big your allowlist needs to be (it corrects shapes instead of demanding an entry), but you still add the safe commands *your* project uses. The method:

1. **Don't pre-guess.** When a safe command prompts, add it — that's the signal.
2. **Add read-only and idempotent commands**, scoped tight: `Bash(npm run test)`, `Bash(npm run build)`, `Bash(git diff *)`. Keep mutations and network/arbitrary-code out (let them prompt).
3. **Prefer the wrapped form.** Allowlist `npm run <script>`, not the raw tool — the script carries required flags, and Rule 10 steers you there anyway.
4. **Wildcards cross spaces but not `/`** in Claude Code's matcher; a trailing `:*` is legacy *prefix* matching (which turns an earlier `*` literal). Pin host/port literals in URL rules (`http://localhost:3000*`, not `http://localhost:*`) so look-alike hosts don't match.
5. **Skills can re-open doors.** A skill's `allowed-tools` frontmatter is an *additive grant* — a blanket like `Bash(some-cli:*)` auto-approves every subcommand of that CLI while the skill runs, overriding your settings. Audit skill frontmatter, not just settings.

## Tests

`bash tests/run.sh` feeds fake tool payloads to the hook and asserts each outcome (block / gate / allow) across every rule, with explicit regression cases for the tricky ones (quoted git subcommands, the `#override` marker appearing in data, combined `sed` flags). It runs under an isolated `$HOME`, needs no setup, and exits non-zero on any failure — CI-ready. Add a case whenever you add or change a rule.

## FAQ

**Why this instead of the built-in `fewer-permission-prompts` skill?**

They attack the same annoyance from opposite ends, and they compose — this isn't a replacement.

`fewer-permission-prompts` scans your transcripts and *grows your allowlist* to match the commands the model already runs. It's official, zero-setup, and a great way to seed a starter allowlist from real usage.

quiet-guardrails goes the other way: instead of widening the allowlist to fit the model's habits, it *fixes the habits* so a small allowlist suffices. When the model reaches for `cmd 2>&1 | tail`, `cd repo && git status`, or `npx jest`, the guard rewrites it to the plain form your allowlist already trusts. Three things follow:

- **The allowlist grows to match mess; the guard removes the mess.** An uncorrected model, over a week, runs `npx jest`, `jest --silent`, `npm test 2>&1 | tail`, `npm test -- --findRelatedTests x`, and `cd frontend && npm test` — five shapes for "run the tests," each its own allowlist decision, and some (the `2>&1 | tail`, the `&&`) things you shouldn't bless at all. Corrected, they collapse to `npm test` and `npm test -- <args>` — two entries. `fewer-permission-prompts` grows the list to fit the variety; the guard shrinks the variety.
- **It adds friction, not just removes it.** `fewer-permission-prompts` is purely additive — it only ever makes *more* things auto-approve. quiet-guardrails also *forces* a prompt on `git add` / `reset` / `branch -D` — index and history mutations Claude Code silently auto-approves. A list-only tool structurally can't add that.
- **And the model actually learns.** Because the correction lands *at the command*, the bad shapes taper off over the session — you're training the habit, not just filtering the output. An allowlist never does that; it only accumulates.

**Use both:** seed the allowlist with `fewer-permission-prompts` from real usage, then let quiet-guardrails correct habits and add the workflow gates. Each makes the other's job smaller.

**Why a hook and not a rule, skill, or `CLAUDE.md` instruction?**

Because those are advice the model can ignore — and reliably does, at exactly the wrong moment.

A rule or skill loads into context and *asks* the model to comply ("run searches bare, don't pipe into `wc`"). That holds right up until the model is heads-down mid-task and reaches for the shell habit anyway — the instruction is present, it just doesn't fire when the command is composed. A PreToolUse hook fires *deterministically, on every command*, remembered or not, and hands back a specific correction at the instant it's needed, so the model rewrites and retries.

Two things make it non-negotiable rather than nice-to-have:

- **This tool exists because the advisory version didn't stick.** The bad shapes kept recurring despite being written down; the `exit 2` feedback *at the command* is what actually changed behavior. You can't teach a habit with a doc the model skims once a session.
- **A guardrail has to be un-ignorable to be a guardrail.** "Force a confirmation on `git add`" as a *rule* is worthless — the model can just not. As a hook returning `permissionDecision: ask`, the harness enforces it. You can't build an enforced gate out of a suggestion.

This isn't "hooks beat rules" — rules and skills are the right tool for *judgment* a regex can't capture (taste, architecture, "is this proportionate?"). The split: deterministic, mechanical command shapes go in the hook; genuine judgment stays in your instructions.

**Why not just use auto mode?**

Auto mode hands each decision to an LLM classifier — probabilistic and per-call. quiet-guardrails keeps a deterministic allowlist *you* control and never auto-approves anything you didn't list; it cuts prompts by fixing the model's commands, not by trusting a judge to wave them through. The intro has the fuller contrast.

## Caveats

- **It's opinionated and tuned to a specific setup** (see the ENVIRONMENT ASSUMPTIONS block at the top of the hook): a native Claude Code build where `grep` is ugrep and there are no Grep/Glob tools, and npm projects for the `npm run` rule. On other builds some corrections flip (e.g. bare grep/find would steer to Grep/Glob tools). Read the rules before adopting; they're plain shell and easy to trim.
- **Calibrated to observed Claude Code behavior (developed against 2.1.x).** The rules encode current CC quirks — which git subcommands it mis-classifies as read-only, how its allowlist matcher treats `*` and `:*`. Anthropic can change these between versions: if they fix a misclassification a workflow gate just goes redundant (harmless), and the allowlist-matcher notes may need re-checking. Re-verify against your build.
- The git workflow gates assume *you* drive staging/commits/pushes. If you want an agent to commit unattended, drop `commit`/`push` from Rule 8b.
- **Not a security boundary.** It corrects a *cooperative* model; a determined or prompt-injected one can defeat string heuristics, and it deliberately **fails open**. See **[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md)** for the specifics and why they're out of scope. If you need a real boundary, use the sandbox.

## License

[0BSD](LICENSE) (SPDX: `0BSD`; [OSI-approved](https://opensource.org/license/0bsd)) — public-domain-equivalent, no attribution required. Take it and do whatever you want with it.

---

Built with Claude Code, and largely written by Claude — which is part of why it's 0BSD.
