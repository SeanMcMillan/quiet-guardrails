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

### Repo-destined file authored in the scratchpad, then `cp`'d into the repo · seen 2026-09-10

An agent wrote a probe test (`legendProbe.test.tsx`) into the scratchpad, then ran `cp <scratchpad>/legendProbe.test.tsx <repo>/…/__tests__/legendProbe.test.tsx`. The cp **succeeded** (after a prompt). Two things of note:

- **CC's Bash write-analysis is quote-blind (not ours, can't fix from here).** The quoted destination contains `[locale]`/`(dashboard)` (Next.js route dirs); CC flagged `[ ] ( )` as glob patterns ("Glob patterns are not allowed in write operations") even though the quotes prevent any expansion — a false-positive, same family as CC's allowlist quote-blindness (claude-code #23670). It nags but is harmless (the cp ran), and our guard can't suppress CC's own filter.
- **The `cp` is the symptom, not the cause.** The real mistake was authoring a repo-destined file in the scratchpad at all — a **Write-tool** call. By the time the `cp` appears, the tmp file already exists. Our guard is a **Bash** PreToolUse hook, so it never sees Write/Edit and structurally cannot catch the origin. This is the guard's first observed *tool-write* blind spot (everything else it gates is a Bash shape).

- **Grindable?** Only by expanding beyond Bash: a PreToolUse hook on the **Write tool** that flags a repo-destined file (`.test.tsx`, `.spec.*`, source `.ts(x)`) written into scratchpad/tmp → "author it at its repo path; the scratchpad is for throwaway artifacts, not repo files staged for a copy." Fires at origin, before the tmp file and the cp. **One sample + new infrastructure (a second matcher)** — watch for recurrence before building it. Symptom-level `cp`/`mv` rules are the wrong layer and were rejected.

### `npx --<flag> <tool>` (flag between npx and the tool) slips Rule 10 · noted 2026-09-09

Rule 10 (raw/npx tool that a package.json script wraps → `npm run <script>`) matches only the tool *immediately* after `npx` — its regex is `npx[[:space:]]+(jest|eslint|tsc)`. So `npx --no-install jest`, `npx --yes eslint`, `npx -y tsc` are not recognized and fall through to a prompt instead of the correction. Env-assignment *prefixes* (`CI=1 npx jest`) are already handled by the leader extraction; this is specifically an npx *flag* between `npx` and the tool.

- **Grindable?** Yes, cleanly — widen the regex to allow optional flag tokens: `npx([[:space:]]+-[^[:space:]]+)*[[:space:]]+(jest|eslint|tsc)`. Low false-positive risk (the flags are `-`-prefixed). Deferred as speculative — not yet observed in practice, unlike the cwd bug it rode in on (that one was real and is fixed). Close it if the form actually shows up, or fold it in next time the rule is touched.

### `cd <dir> && npx <tool> --version` as a cwd/env probe · seen 2026-09-08

An agent ran `cd <abspath> && npx prettier --version` — described as "confirm cwd" — instead of `pwd`. Weird *semantically* (a probe used as a `pwd` synonym), not structurally: benign `cd && <cmd>` bundles auto-approve, and this one prompted only because `npx …` isn't allowlisted. The prompt was the correct outcome, but it **taught nothing** — a prompt gates; only an exit-2 correction teaches the right shape.

- **Grindable?** Only a narrow slice: `npx <tool> --version|--help` is ceremony in a lockfile project (a tool's presence/version is in `package-lock.json`), so it *could* be corrected → "run it with `npm run <script>`; check location with `pwd`." But it's **one sample** — watch for recurrence before fitting a rule (a finding is a sample, not a population). The general "agent picked a weird probe" is not detectable.
