# Guard watch list

Running list of command patterns seen in real use that are candidates for a guard change — a new correction (exit 2), an allowlist add, or a deliberate "note only." These are open, unresolved observations; deliberate non-goals live in `KNOWN-LIMITATIONS.md`.

## How candidates surface

- **Denials** are recorded in the Claude Code transcript (`"toolDenialKind":"user-rejected"`, plus the user's `userFeedback`), so they're greppable across sessions. But **low yield** for this purpose: the guard sits upstream and corrects bad *shapes* before they'd ever reach a prompt, so most denials are the user *redirecting* mid-task, not the agent overreaching.
- **Prompted-then-approved** commands are the interesting residual — a weird command that *ran* because it was approved — but they are **not** distinguishable from auto-approved ones in the logs (no permission-outcome marker is written, and there's no separate audit log). So these can only be caught **live** (someone notices and flags it) or by manually reading transcripts for weirdness.

So this list is fed mostly by live flagging, not log-mining.

## For each entry, decide

- **Grindable → correction:** a detectable shape → add an exit-2 rule that teaches the right form.
- **Grindable → allowlist:** a legit command that only prompts because it isn't listed → add it.
- **Note only:** genuinely undetectable "weirdness" (semantic, not structural) → leave it; the prompt is the acceptable outcome.

## Open items

### ✅ Resolved — subagent reached for cwd-independent git/gh forms (Opus 5 Explore agents) · seen 2026-09-21

After the default model switched to Opus 5, Explore subagents investigating the sibling working dirs (`obm-rts-api`, `obm-rts-api-docs`) cycled through form after form, each prompting: `git -C`, `git --git-dir=`/`--work-tree=`, `GIT_DIR=`/`GIT_WORK_TREE=` env, `(cd && git)` subshell / single-call `cd && git`, `gh --repo <o/r> pr view`, `gh api …/contents/`.

**Root cause (corrected).** The earlier guess here — that the subagent "doesn't know the dirs are local, so it treats a local checkout as remote" — was **wrong**. The real driver: a subagent's Bash cwd does not persist across separate calls (verified; see the Update below and [[subagents-inherit-permission-stack]]), so it reaches for the forms that *don't* depend on a held working directory — repo-scoped git flags/env, a `cd && git` that self-contains in one call, and `gh` (cwd-independent by nature). It isn't confusing local for remote; it's routing around a cwd it can't keep.

In the **main session** those forms self-correct to a local read or the whitelisted gh form (cwd persists there, so the correction lands prompt-free): git relocation (flags + env) → **Rule 9**; cd/subshell bundles → **Rule 6**; gh-api content (commits/compare/contents) + `gh pr diff` → **Rule 12**; `gh --repo` before the subcommand → **Rule 14**. In a **subagent** those corrections are carved out (they'd misfire) — see the Update.

**Watch for more of the class** (other cwd-independent / remote-fetch reaches): `curl`/`gh api` on `raw.githubusercontent.com`, `gh repo view`, `gh api repos/<o>/<r>` metadata, `git archive`. Add a redirect when one shows up.

- `git ls-remote` — **seen 2026-09-28** (`git branch -a --list "*1218*" && git ls-remote --heads origin "*1218*"` to check if the old split branch exists; prompted on the ls-remote half). Local `git branch -a --list` after a `git fetch` already lists remote-tracking refs — no remote round-trip needed. Note-only for now (one sample; ls-remote is a legit authoritative check sometimes) — grind a redirect only if it recurs.

**Update 2026-09-21 — the real driver, and the correctness fix.** Verified (docs, high confidence) that **subagent Bash cwd does not persist across separate calls** — long-standing, documented, NOT a regression. **Worktree isolation does not change this**: the docs say a worktree subagent's `cd` "don't persist between tool calls (same as normal mode)" — the main session is the lone outlier with persistent cwd. And the PreToolUse payload carries **no isolation field** (only `agent_id`/`agent_type`, present just for subagent calls), so there's nothing to key a worktree off of anyway. → `agent_id` alone is the correct and only carve-out key; no worktree branch.

So the Explore agent's repo-scoped forms (`git -C`, `--git-dir`, `GIT_DIR=`, `cd && git` in one call) were *correct for its environment*, and the guard was **wrong to force-correct them there** — it steers to a standalone `cd` that no-ops in a subagent (git then runs in the primary repo). Fix: a **subagent carve-out** — Rules 6 and 9 skip when `agent_id` is set.

**What the carve-out does and does NOT do.** It is **not** a silent-run path. Every cross-repo git form still **prompts** in a subagent: `cd && git` is a force-prompt special case (docs: a `cd` into another dir can execute that dir's hooks, so it gates regardless of git being read-only), and `git -C` / `--git-dir` / `GIT_DIR=` all shift the subcommand token past read-only auto-approval. There is **no prompt-free shell path for `git status` on another repo from a subagent** — the only prompt-free cross-dir move is the Read tool (file contents, absolute path). So the carve-out's value is narrow but real: it stops the guard from replacing a *prompts-then-works* form with the one form that *silently runs in the wrong repo*. Broken correction loop → one prompt, works.

Mutation gates (8/8b) are NOT carved out — they still fire in subagents. Rules 12/13/14 stay (Read tool for contents, `gh pr view --repo`). Residual nit: Rule 12's "use plain git" line reads slightly wrong for a cross-repo subagent — not broken, just imperfect.

**Resolution / policy.** The carve-out prevents the *worse* failure (a subagent silently running git in the wrong repo and reporting confident wrong answers), not the prompt storm — there is no prompt-free cross-dir git form in a subagent, so a cross-repo investigation there still storms. So the policy, not a new rule, is the answer: **keep cross-repo git/gh in the MAIN session** (cwd persists → the standard `cd` correction works, prompt-free); subagents keep fan-out search, primary-repo work, and cross-repo FILE reads via the Read tool. A read-only-git MCP tool was considered and **rejected** — an available tool doesn't beat the model's raw-git training prior without a friction gradient, and if the pattern is common "don't subagent it" is cheaper than building. Treated as **rare until it recurs**; revisit only if it proves frequent.

### ✅ Resolved — repo-destined test file authored in the scratchpad, then `cp`'d into the repo

Seen 2026-09-10 (`legendProbe.test.tsx`), **recurred 2026-09-16** (`zzprobe.test.tsx`) — the recurrence trigger. **Reframed on the second look:** the agent's instinct (a throwaway probe kept out of commits) is *reasonable*; it just fails on a mechanical fact — jest only discovers tests under the project roots, so a scratchpad test never runs and forces the `cp`. So the fix is informative, not a scold.

Two parts:
- **`hooks/guard-write-overreach.sh`** (public, the "second matcher") — a PreToolUse hook on the Write tool that catches a `.test`/`.spec` written into scratchpad/tmp and steers the probe back inside the project (a gitignored scratch dir if the project has one). Fires at the origin (the tmp Write), which a Bash hook can't see. Tested in `tests/run.sh`, wired in `settings.example.json`. Scoped to test/spec files; source scratch `.ts(x)` left out to avoid false-firing on one-off scripts.
- **A gitignored `/__scratch__/` zone in obm-rts-frontend** — verified jest discovers a root-level gitignored test (`@/` resolves via the absolute moduleNameMapper) while git/tsc/eslint/prettier all skip it. Documented in `.claude/rules/08-testing.md`. Gives the reasonable instinct a home that actually works — the piece the scratchpad and a to-be-deleted repo file both lacked.

The `cp`'s *visible* failure — CC's quote-blind "glob patterns not allowed in write" filter on a `[locale]` destination — is upstream (claude-code #23670 family) and unfixable from here; this removes the tmp-authoring that led there.

### `npx --<flag> <tool>` (flag between npx and the tool) slips Rule 10 · noted 2026-09-09

Rule 10 (raw/npx tool that a package.json script wraps → `npm run <script>`) matches only the tool *immediately* after `npx` — its regex is `npx[[:space:]]+(jest|eslint|tsc)`. So `npx --no-install jest`, `npx --yes eslint`, `npx -y tsc` are not recognized and fall through to a prompt instead of the correction. Env-assignment *prefixes* (`CI=1 npx jest`) are already handled by the leader extraction; this is specifically an npx *flag* between `npx` and the tool.

- **Grindable?** Yes, cleanly — widen the regex to allow optional flag tokens: `npx([[:space:]]+-[^[:space:]]+)*[[:space:]]+(jest|eslint|tsc)`. Low false-positive risk (the flags are `-`-prefixed). Deferred as speculative — not yet observed in practice, unlike the cwd bug it rode in on (that one was real and is fixed). Close it if the form actually shows up, or fold it in next time the rule is touched.

### `cd <dir> && npx <tool> --version` as a cwd/env probe · seen 2026-09-08

An agent ran `cd <abspath> && npx prettier --version` — described as "confirm cwd" — instead of `pwd`. Weird *semantically* (a probe used as a `pwd` synonym), not structurally: benign `cd && <cmd>` bundles auto-approve, and this one prompted only because `npx …` isn't allowlisted. The prompt was the correct outcome, but it **taught nothing** — a prompt gates; only an exit-2 correction teaches the right shape.

- **Grindable?** Only a narrow slice: `npx <tool> --version|--help` is ceremony in a lockfile project (a tool's presence/version is in `package-lock.json`), so it *could* be corrected → "run it with `npm run <script>`; check location with `pwd`." But it's **one sample** — watch for recurrence before fitting a rule (a finding is a sample, not a population). The general "agent picked a weird probe" is not detectable.

### `printenv OBM_ROLE; ls …` — NOT a sketchy probe (corrected) · seen 2026-09-23

First read as a fabricated-env-var probe; **wrong.** `OBM_ROLE` is the `obm:ticket-intake` plugin skill's documented lens selector, and `printenv OBM_ROLE` is the skill's own step (`~/.claude/plugins/cache/obm-ai-tooling/obm/*/skills/ticket-intake/SKILL.md:45`). The agent followed the skill; I asserted "invented" without reading it (see [[a-name-is-not-evidence]]). Only real observations:

- Prompted because `printenv` isn't allowlisted (the `ls` half is) and the agent chained the skill's `printenv` with an `ls` of the rules dir.
- **Keep `printenv` unlisted** anyway — bare `printenv` / a secret-bearing var would dump credentials into the transcript (same hazard as `gh auth status --show-token`). So this skill step prompts once per run; acceptable. Do **not** whitelist `printenv *`.
- No guard action, no feedback. Documented so the same probe isn't re-flagged as suspicious next time.
