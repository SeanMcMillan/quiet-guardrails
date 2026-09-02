# Known limitations & non-goals

quiet-guardrails **corrects a cooperative model's habits** (to cut prompts) and **forces a confirmation on a few risky git ops** Claude Code auto-approves. It is **not a security boundary** and does not defend against an adversarial or prompt-injected agent.

Several things below are real limitations we've **deliberately left unfixed**. They come up in review again and again, so they're documented here with the reasoning. **Please read this before filing one as a bug.** Genuine bugs and ideas are welcome — see [Reporting](#reporting).

---

## Out of scope by design — it isn't a boundary

A determined or prompt-injected agent can defeat string heuristics; closing every hole isn't the goal. Worth noting, though, that several obvious "bypasses" actually **fail safe**, because Claude Code's *own* handling catches them:

- **`$(…)` and `$var` indirection fails safe.** The gates dequote — `git "push"` and `git p"u"sh` are caught — but they don't evaluate command substitution or variable expansion (`git $(printf push)`, `sub=push; git $sub`). They don't need to: Claude Code prompts on `$(…)` and `$`-expansion on its own ("cannot be statically analyzed" / "shell expansion"), so those get a **prompt, not a silent pass**.
- **`git config` code-exec isn't gated.** `git config core.hooksPath …` and alias `!`-commands can run arbitrary code and aren't index/worktree/history mutations, so the gate skips them; gating *all* `git config` would also prompt on read-only `--get`/`--list`. Whether an ungated `git config` write runs *silently* depends on Claude Code's own classification of the subcommand — unverified; it may well prompt as a non-read-only command.
- **Fails open.** If `jq` is missing, stdin is empty or malformed, or the command field is absent, the guard exits 0 and runs no rules. Deliberate — a guard that failed *closed* would block every Bash command on a hiccup. Right for a habit tool, wrong for a boundary.

## Not ours — upstream Claude Code

- **The allowlist is quote-blind.** Claude Code's permission matcher matches the whole command text, so `Bash(git diff *)` matches `git diff …` but not `git "diff" …` (reported in claude-code #23670). Our *gate* dequote works around this for the safety gates, but the *allowlist* is CC's. This **fails safe**: a quoted command that dodges an `allow` rule gets a prompt, not a bypass.

## Fails safe — annoying at worst

- **Dequoting the git gates can over-match.** To catch `git "push"`, the gates strip quote characters, so a quoted argument that happens to equal a subcommand name (e.g. `git diff "reset"`) can trip the gate and prompt you needlessly. It errs toward *prompting* — the safe direction for a gate.
- **Repo-controlled text in a message.** Rule 10 echoes a matching `package.json` script name into its correction. In an untrusted repo that's a minor prompt-injection surface into the model's context; in your own repo it's noise.

## Verify on your CLI version

The guard is calibrated to observed Claude Code behavior (developed against 2.1.x). Anthropic can change these:

- **Which git subcommands auto-approve.** The gates exist because CC read-only-misclassifies some — `git add` was observed running unprompted, which is what motivated them. If a version fixes that, the corresponding gate goes redundant (harmless).
- **`ask` vs `deny` precedence.** A PreToolUse hook returning `ask` reportedly bypassed `permissions.deny` in v2.1.84 (reported in claude-code #39344). If you rely on `deny` rules, verify on your version.
- **Hook coverage of MCP tools & backgrounded Bash.** The docs say PreToolUse hooks fire on these, and on subagents. We verified **subagents** empirically (the guard, allowlist, and git gates all apply, and approval-needing commands prompt you); MCP and backgrounded Bash are doc-confirmed only.

---

## Reporting

The [test suite](tests/run.sh) encodes the intended behavior, including the tricky cases. A genuine bug is one where the guard diverges from what the tests assert — for example a rule misfiring on an ordinary **cooperative** command, a portability break, or a safety gate that fails to fire.

File those (and feature ideas) as **GitHub Issues** on this repo. If you think one of the items above should move from "non-issue" to "issue," open one and make the case — but the burden is *why it's in scope for a habit tool*, not for a sandbox.
