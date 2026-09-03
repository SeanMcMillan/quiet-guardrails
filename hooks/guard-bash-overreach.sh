#!/usr/bin/env bash
# PreToolUse guard for the Bash tool — the "self-correct, don't prompt" hook.
#
# WHAT IT DOES. Two jobs, in one PreToolUse hook:
#   1. OVERREACH rules (exit 2): catch the command shapes that needlessly PROMPT
#      (or that a first-class tool does better), and feed a one-line correction
#      back to the model on stderr. The model rewrites and retries — the user
#      never sees a prompt. A block means "rewrite," not "ask the human."
#   2. WORKFLOW gates (permissionDecision:ask): FORCE a confirmation on the few git
#      subcommands Claude Code auto-approves but that YOU drive (they mutate the
#      index, working tree, history, or a branch). Here a block means "ask the human."
#
# ENVIRONMENT ASSUMPTIONS (read before adopting — some guidance flips otherwise):
#   - A NATIVE macOS/Linux Claude Code build (2.1.117+) with NO Grep/Glob tools:
#     `grep` is embedded ugrep and `rg` routes into the CLI, so shell search IS the
#     sanctioned fast path. The guard therefore does NOT treat a bare `grep`/`find`/
#     `rg` as overreach — only search wired into a pipe/$(...). On a build that HAS
#     Grep/Glob tools, you'd instead steer bare grep/find to those tools.
#   - An npm/`package.json` project for Rule 10 (raw-tool -> `npm run <script>`).
#     Harmless in non-npm repos (it only fires when a wrapping script exists).
#   - `jq` (used to parse the hook payload) — ships with Claude Code, nothing to install.
#
# THE ESCAPE HATCH. Put the marker  #override  anywhere in a command to skip the
# OVERREACH checks (NOT the workflow gates). It is deliberately NOT mentioned in any
# rule message — so a block nudges you to rewrite, and reaching for the escape is a
# conscious choice, not the reflexive way past. Every use is logged (see below) so
# "success is silent" doesn't hide overuse.
#
# The rules (exit 2 -> self-correct):
#   - grep/find wired into a pipe or $(...)  (chained search plumbing) -> split
#   - cat, or a leading head/tail, to read a file                      -> Read tool
#   - head/tail capping piped output ('cmd | tail')                    -> run bare
#   - python/node parsing JSON                                         -> jq
#   - shell for/while loops                                            -> separate calls
#   - self-added output instrumentation (echo $?, chained echo,        -> run bare
#     capture to a scratch/tmp file, a bare 2>&1) that turns an
#     allowlisted command into a prompting compound
#   - cd + git bundled in one command (trips CC's hook-safety prompt)  -> cd standalone
#   - find with a glob-char PATH arg ([x]/(y); trips CC)               -> ls / cd + find .
#   - git -C <path> (defeats CC's read-only auto-approve)              -> plain git / cd
#   - a tool run raw/npx when a package.json script wraps it (jest…)   -> npm run <script>
#   - editing a file via a shell interpreter (sed -i, node -e write…)  -> Edit/Write tool
#
# The workflow gates (permissionDecision:ask -> force a confirmation):
#   - mutating `git branch` (force/delete/rename/copy)
#   - any index/worktree/history-mutating git subcommand
#     (add/reset/restore/rm/stash/checkout/switch/clean/commit/push)

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# Quote-stripped view for structural checks: remove single- and double-quoted
# spans so a `|`, `$(`, `;`, or `for` INSIDE a quoted regex/arg (e.g.
# `grep -E 'a|b'`) is not mistaken for a shell operator. Only the pipe/subst/loop
# and segment-leader checks use $scan; the raw $cmd is kept for content checks.
scan="$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"

# Dequoted view for the git workflow gates: strip quote CHARACTERS but keep their
# contents, so `git "push"` / `git p"u"sh` can't hide a mutating subcommand from a
# gate the way $scan (which deletes whole quoted spans) would.
dequoted="$(printf '%s' "$cmd" | tr -d "\"'")"

# Rule 8 — WORKFLOW gate, checked BEFORE the #override escape so it can't be waived
# through. A mutating `git branch` (force/delete/rename/copy): Claude Code
# classifies ALL of `git branch …` as read-only, so `git branch -f/-d/-D/-m/-M/-c/-C`
# auto-approves and can force-move or delete a branch with NO prompt. Force a human
# confirmation via permissionDecision:ask (overrides the read-only auto-approve).
if printf '%s' "$dequoted" | grep -Eq '(^|[^[:alnum:]_])git([[:space:]]+[^;|&[:space:]]+)*[[:space:]]+branch([[:space:]]|$)'; then
  # Check for a mutating flag only in the args AFTER 'branch', so a global
  # 'git -C <path>' / 'git -c k=v' BEFORE the subcommand is not misread as a
  # 'branch -C/-c' copy. That false match would send 'git -C … branch --list'
  # (read-only) into this ASK gate instead of on to the git -C corrector (Rule 9).
  branchargs="$(printf '%s' "$dequoted" | sed 's/^.*[[:space:]]branch//')"
  if printf '%s' "$branchargs" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*[dDfmMcC][a-zA-Z]*|--force|--delete|--move|--copy|--force-with-lease)([[:space:]]|=|$)'; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git branch with a mutating flag (-f/-d/-D/-m/-M/-c/-C or --force/--delete/--move) force-moves, deletes, renames, or copies a branch. Claude Code auto-approves it because git branch is read-only-classified, so this hook forces a confirmation."}}'
    exit 0
  fi
fi

# Rule 8b — WORKFLOW gate (before the escape, so it can't be #override'd past): git
# subcommands that mutate the index, working tree, or history — which you manage
# yourself (the index and any uncommitted work are yours to stage/commit). Claude
# Code read-only-misclassifies some of these so they auto-approve. Force a
# confirmation. Flag-agnostic, token-bounded to the subcommand position so an arg
# that merely contains the word does not trip it.
if printf '%s' "$dequoted" | grep -Eq '(^|[^[:alnum:]_])git([[:space:]]+[^;|&[:space:]]+)*[[:space:]]+(add|reset|restore|rm|stash|checkout|switch|clean|commit|push)([[:space:]]|$)'; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This git subcommand mutates the index, working tree, or history (add/reset/restore/rm/stash/checkout/switch/clean/commit/push) — which you manage yourself. Claude Code auto-approves some of these as read-only, so this hook forces a confirmation."}}'
  exit 0
fi

# Escape hatch for the OVERREACH rules below: put  #override  anywhere to skip
# them (deliberate last resort — not advertised in the messages). Does NOT skip
# the git workflow gates above (branch + index/worktree/history). Each use is logged.
# Matched against $scan so a quoted "#override" in data (a filename, a grep pattern)
# can't disable the rules — only a real unquoted trailing marker counts.
case "$scan" in
  *'#override'*)
    # Sanitize tabs/newlines out of the logged command so a crafted argument
    # can't forge extra rows in the TSV log.
    logcmd="$(printf '%s' "$cmd" | tr '\t\n' '  ')"
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$PWD" "$logcmd" \
      2>/dev/null >> "$HOME/.claude/hooks/override-escapes.log"
    exit 0
    ;;
esac

# Rule 1 — parsing JSON with an interpreter. Prefer jq.
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])python3?([^[:alnum:]_]|$)' \
   || printf '%s' "$cmd" | grep -Eq 'node[[:space:]]+(-e|-p|--eval|--input-type)'; then
  if printf '%s' "$cmd" | grep -Eiq '\.jsonl?([^[:alnum:]]|$)|json\.load|json\.dump|JSON\.parse|fromjson|import[[:space:]]+json'; then
    echo "Overreach: parsing JSON with an interpreter. Use jq (auto-approved) instead of python/node." >&2
    exit 2
  fi
fi

# Leading command of every segment (split on \n ; | && || $( and backticks).
leaders="$(printf '%s' "$scan" | awk '
  { s=$0; gsub(/\$\(/,"\n",s); gsub(/`/,"\n",s); gsub(/&&/,"\n",s); gsub(/\|\|/,"\n",s); gsub(/\|/,"\n",s); gsub(/;/,"\n",s); print s }
' | awk '
  { i=1; while ($i ~ /=/ || $i=="sudo" || $i=="command" || $i=="nohup") i++; if ($i=="timeout"){i++;i++} if ($i!="") print $i }
')"
firstleader="$(printf '%s\n' "$leaders" | sed -n '1p')"

# Rule 2 — chained search plumbing: a grep/find piped or command-substituted.
# A bare grep/find (even after `cd … &&`) is fine — that's the native search path.
if printf '%s\n' "$leaders" | grep -qxE 'grep|egrep|fgrep|find'; then
  if printf '%s' "$scan" | grep -Eq '[|]|[$][(]'; then
    # Exception: a terminal count 'grep/find … | wc' (single pipe into wc, nothing
    # further) — wc is a scalar reducer, not chained plumbing, and there's no bare
    # grep/find flag for a cross-file total count.
    secondleader="$(printf '%s\n' "$leaders" | sed -n '2p')"
    nleaders="$(printf '%s\n' "$leaders" | grep -c .)"
    if [ "$nleaders" = "2" ] && [ "$secondleader" = "wc" ] \
       && printf '%s' "$firstleader" | grep -qxE 'grep|egrep|fgrep|find' \
       && ! printf '%s' "$scan" | grep -Eq '[$][(]|;|&&|[|][|]'; then
      : # terminal 'grep/find | wc' count — allowed
    else
      echo "Overreach: a grep/find wired into a pipe or \$(...). Run the search as its own Bash call and act on the result in a separate step. (Exception: a terminal count '… | wc -l' is fine. Bare 'grep'/'rg'/'find' are fine — this native build's grep is ugrep.)" >&2
      exit 2
    fi
  fi
fi

# Rule 3 — reading a file: cat (anywhere), or a leading head/tail. Use the Read tool.
if printf '%s\n' "$leaders" | grep -qx 'cat'; then
  echo "Overreach: 'cat' in a Bash call. Read files with the Read tool (or feed the file straight to jq)." >&2
  exit 2
fi
case "$firstleader" in
  head|tail)
    echo "Overreach: '$firstleader' to read a file. Use the Read tool (offset/limit for ranges)." >&2
    exit 2 ;;
esac

# Rule 3b — head/tail capping PIPED output ('cmd | tail -N'). The harness already
# returns each command's full stdout/stderr AND exit status, so this just
# instruments an otherwise-bare (often allowlisted) command into a prompting
# compound. Run it bare and read the result.
if printf '%s\n' "$leaders" | grep -qxE 'head|tail' && printf '%s' "$scan" | grep -Eq '[|]'; then
  echo "Overreach: capping piped output with head/tail ('cmd | tail -N'). The harness already returns each command's full stdout/stderr AND exit status — run the command bare and read the result, don't pipe through head/tail. A genuinely huge run you've deliberately chosen to filter is the #override case." >&2
  exit 2
fi

# Rule 4 — shell loop. Iterate via separate/parallel tool calls instead.
if printf '%s' "$scan" | grep -Eq '(^|[;&|(])[[:space:]]*(for|while)[[:space:]]'; then
  echo "Overreach: shell loop in a Bash call. Iterate with separate (parallel) tool calls instead." >&2
  exit 2
fi

# Rule 5 — self-added output instrumentation. The harness already returns each
# command's stdout/stderr to you AND tracks its exit status, so echoing $?,
# chaining a label/status echo, or capturing to a scratch/tmp file just turns
# an already-allowlisted bare command into a prompting COMPOUND. Run it bare.
if printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_])echo([^[:alnum:]_]|$)' \
   && printf '%s' "$cmd" | grep -Eq '[$][?]'; then
  echo "Overreach: echoing the exit code (\$?). The harness already reports pass/fail — run the command bare and read the result; drop the  echo \"exit=\$?\" ." >&2
  exit 2
fi
if printf '%s' "$scan" | grep -Eq '(;|&&|[|])[[:space:]]*echo([^[:alnum:]_]|$)'; then
  echo "Overreach: a chained 'echo' after another command (status/label/separator). The harness returns each command's output directly — run commands bare as separate calls, no echo scaffolding." >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq '>[[:space:]]*[^[:space:]]*(scratchpad|/tmp/|/private/tmp/)'; then
  echo "Overreach: capturing output to a scratch/tmp file. The harness returns stdout/stderr to you — run the command bare and read the result, don't redirect-then-Read." >&2
  exit 2
fi
# Rule 5c — a bare '2>&1' stream-merge (no pipe). The harness already returns both
# stdout AND stderr plus exit status, so merging them adds nothing and just breaks
# the allowlist match. Drop it and run bare. (2>&1 feeding a pipe is the pipe
# rules' business, handled above.)
if printf '%s' "$cmd" | grep -Eq '2>&1' && ! printf '%s' "$scan" | grep -Eq '[|]'; then
  echo "Overreach: a bare '2>&1' stream-merge. The harness already returns both stdout and stderr (and exit status) — drop the '2>&1' and run the command bare." >&2
  exit 2
fi

# Rule 6 — cd + git in one command. Claude Code prompts on this (git in a freshly
# cd'd directory can execute that directory's hooks). Splitting is free: `cd` into
# a working/additional dir auto-approves, and read-only git auto-approves.
if printf '%s\n' "$leaders" | grep -qx 'cd' && printf '%s\n' "$leaders" | grep -qx 'git'; then
  echo "Overreach: 'cd' + 'git' bundled in one command — Claude Code prompts because git in a freshly cd'd directory can run that directory's hooks. Run the 'cd <dir>' as its OWN call (it auto-approves into a working/additional dir), then each 'git …' as a separate call." >&2
  exit 2
fi

# Rule 7 — find with a glob character in its PATH argument. Claude Code's
# find-glob safety prompts on [ ] ( ) * in the positional path (e.g. framework
# dirs like '[id]' / '(group)'). Checked on the FIRST path token in the raw
# command only, so globs in -name/-path VALUES (which are fine) don't false-fire.
if printf '%s\n' "$leaders" | grep -qx 'find' \
   && printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])find[[:space:]]+(-[HLP][[:space:]]+)*[^[:space:]]*[][()*]'; then
  echo "Overreach: 'find' with a glob character ([ ] ( ) *) in its PATH argument — Claude Code's find-glob safety prompts on this. Use  ls \"<path>\"  (or ls -R), or a standalone  cd \"<path>\"  then  find . <filters>  — the '.' path is glob-free, and -name/-path value globs are fine." >&2
  exit 2
fi

# Rule 9 — `git -C <path>` (global directory flag). Defeats CC's read-only
# auto-approve: -C shifts the subcommand token out of the read-only detector's
# reach, so even `git -C … status/log/diff` prompts. Steer to plain git. Case-
# sensitive, and only right after `git`, so `git log -C` (copy detection) is
# untouched.
if printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+-C([[:space:]]|$)'; then
  echo "Overreach: 'git -C <path>' defeats CC's read-only auto-approve (the -C shifts the subcommand token, so even read-only git prompts). If <path> is your current repo, drop -C and run plain git (e.g. 'git status --short --branch'). If it's a different repo, use a standalone 'cd <path>' then plain git. Not sure where you are? run 'pwd' first, then plain git — don't defensively -C." >&2
  exit 2
fi

# Rule 10 — a tool run raw / via npx when a package.json script wraps it. The
# script carries the project's required flags/env (e.g. eslint's --max-warnings=0).
# DYNAMIC: looks the tool up in the current repo's ./package.json, so it only fires
# when a wrapping script actually exists — a tool with no script passes, and it
# stays correct across repos. Detection uses segment leaders so a tool name
# appearing as an ARG (e.g. `rg jest src`) is not flagged. Extend the tool list to
# taste; jest/eslint/tsc are common cases.
if [ -f package.json ]; then
  t="$(printf '%s\n' "$leaders" | grep -m1 -oxE 'jest|eslint|tsc' || true)"
  if [ -z "$t" ] && printf '%s\n' "$leaders" | grep -qx 'npx'; then
    t="$(printf '%s' "$scan" | grep -oE 'npx[[:space:]]+(jest|eslint|tsc)([[:space:]]|$)' | grep -m1 -oE 'jest|eslint|tsc' || true)"
  fi
  if [ -n "$t" ]; then
    wrap="$(jq -r --arg t "$t" '.scripts // {} | to_entries[] | select(.value | test("\\b" + $t + "\\b")) | .key' package.json 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$wrap" ]; then
      echo "Overreach: running '$t' raw/npx, but package.json wraps it — use  npm run  (matching script: $wrap). The script carries the project's required flags/env (e.g. eslint's --max-warnings=0); raw/npx silently drops them. Pass extra args with  npm run <script> -- <args> ." >&2
      exit 2
    fi
  fi
fi

# Rule 11 — editing a file THROUGH a shell interpreter instead of the Edit/Write
# tool: `sed -i` / `perl -i` (in-place), or a `node`/`python`/`perl` `-e`/`-c`
# that writes a file. A blind regex mutation that also prompts (arbitrary code /
# file write). Read-only forms — `sed 's/…/…/' file` (prints), `node -e` that
# only computes/prints — have no in-place flag or write call and pass.
if { printf '%s\n' "$leaders" | grep -qxE 'sed|perl' && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*i|--in-place)([[:space:]=.'\'']|$)'; } \
   || { printf '%s\n' "$leaders" | grep -qxE 'node|python|python3|perl' \
        && printf '%s' "$cmd" | grep -Eq '(-e|-c|--eval|--exec)([[:space:]]|$)' \
        && printf '%s' "$cmd" | grep -Eq 'writeFileSync|writeFile|appendFileSync|appendFile|fs\.write|\.write\(|writelines|write_text'; }; then
  echo "Overreach: editing a file through a shell interpreter (sed -i / perl -i, or node/python -e that writes a file) — a blind mutation that also prompts. Use the Edit or Write tool: reviewable, harness-tracked, and won't mangle the file on a slightly-off regex. For a REPEATED edit, use Edit with replace_all (one call per distinct old->new)." >&2
  exit 2
fi

exit 0
