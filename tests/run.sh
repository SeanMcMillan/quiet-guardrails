#!/usr/bin/env bash
# Test suite for the quiet-guardrails PreToolUse hook.
#
#   bash tests/run.sh [path-to-guard]
#
# Feeds fake tool payloads to the guard and checks each outcome:
#   block  — exit 2 (overreach self-correction); stderr must contain a substring
#   gate   — exit 0 with a permissionDecision:"ask" JSON on stdout (workflow gate)
#   allow  — exit 0, no stdout, no stderr (command passes, or an #override escape)
#
# Requires jq (ships with Claude Code). Runs under an isolated $HOME so the
# escape-log writes don't touch your real ~/.claude.

GUARD="${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/guard-bash-overreach.sh}"
WGUARD="$(cd "$(dirname "$0")/.." && pwd)/hooks/guard-write-overreach.sh"
export HOME="$(mktemp -d)"
FIXTURE="$(mktemp -d)"           # a fake repo for Rule 10 (package.json + a subdir)
trap 'rm -rf "$HOME" "$FIXTURE"' EXIT
mkdir -p "$HOME/.claude/hooks"   # let escape-log writes land where we can inspect them
mkdir -p "$FIXTURE/sub"
printf '%s\n' '{ "scripts": { "test": "jest --silent", "lint": "eslint --max-warnings=0 ." } }' > "$FIXTURE/package.json"
pass=0 fail=0

run() { # $1 = command, $2 = optional payload cwd; sets $out $err $code
  local payload err_file
  if [ -n "$2" ]; then
    payload="$(jq -nc --arg c "$1" --arg cwd "$2" '{tool_input:{command:$c},cwd:$cwd}')"
  else
    payload="$(jq -nc --arg c "$1" '{tool_input:{command:$c}}')"
  fi
  err_file="$(mktemp)"
  out="$(printf '%s' "$payload" | bash "$GUARD" 2>"$err_file")"
  code=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"
}

ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n        %s\n' "$1" "$2"; }

expect_block() { run "$1" "$3"
  if [ "$code" -eq 2 ] && printf '%s' "$err" | grep -qF "$2"; then ok
  else bad "block: $1" "want exit 2 + [$2]; got code=$code err=[$err]"; fi; }
expect_gate()  { run "$1" "$2"
  if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then ok
  else bad "gate:  $1" "want ask JSON; got code=$code out=[$out]"; fi; }
expect_allow() { run "$1" "$2"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok
  else bad "allow: $1" "want silent exit 0; got code=$code out=[$out] err=[$err]"; fi; }

runw() { # $1 = Write file_path; sets $out $err $code
  local payload err_file
  payload="$(jq -nc --arg fp "$1" '{tool_input:{file_path:$fp}}')"
  err_file="$(mktemp)"
  out="$(printf '%s' "$payload" | bash "$WGUARD" 2>"$err_file")"
  code=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"
}
expect_block_w() { runw "$1"
  if [ "$code" -eq 2 ] && printf '%s' "$err" | grep -qF "$2"; then ok
  else bad "block(write): $1" "want exit 2 + [$2]; got code=$code err=[$err]"; fi; }
expect_allow_w() { runw "$1"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok
  else bad "allow(write): $1" "want silent exit 0; got code=$code out=[$out] err=[$err]"; fi; }

runsub() { # $1 = command, delivered as if from a subagent (agent_id set); sets $out $err $code
  local payload err_file
  payload="$(jq -nc --arg c "$1" '{tool_input:{command:$c},agent_id:"sub-test"}')"
  err_file="$(mktemp)"
  out="$(printf '%s' "$payload" | bash "$GUARD" 2>"$err_file")"
  code=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"
}
expect_allow_sub() { runsub "$1"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok
  else bad "allow(subagent): $1" "want silent exit 0; got code=$code out=[$out] err=[$err]"; fi; }
expect_gate_sub()  { runsub "$1"
  if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then ok
  else bad "gate(subagent): $1" "want ask JSON; got code=$code out=[$out]"; fi; }

echo "== overreach rules (self-correct, exit 2) =="
expect_block 'grep -rn foo src | head -5'      'wired into a pipe'
expect_block 'cat notes.md'                    "'cat' in a Bash call"
expect_block 'head -20 file.txt'               'to read a file'
expect_block 'npm run test 2>&1 | tail -20'    'capping piped output'
expect_block 'npm run build 2>&1'              'stream-merge'
expect_block 'ls; echo done'                   "chained 'echo'"
expect_block 'cd myrepo && git status'         'bundled in one command'
expect_block '(cd /x && git status)'           'bundled in one command'   # subshell-wrapped cd+git still caught
expect_block 'git -C /tmp/x status'            'git pointed at another repo'
expect_block 'git -C /repo branch --list'      'git pointed at another repo'   # branch/-C collision -> corrector, not gate
expect_block 'git --git-dir=/x/.git --work-tree=/x status --short --branch' 'git pointed at another repo'
expect_block 'git --work-tree=/x status'       'git pointed at another repo'
expect_block 'GIT_DIR=/x/.git GIT_WORK_TREE=/x git status --short --branch' 'git pointed at another repo'
expect_block 'GIT_WORK_TREE=/x git status'     'git pointed at another repo'
expect_block 'find src/[locale] -name "*.tsx"' 'glob character'
expect_block 'for f in a b; do echo $f; done'  'shell loop'
expect_block 'python3 munge.py data.json'      'parsing JSON'
expect_block 'sed -i "s/a/b/" f'               'shell interpreter'
expect_block 'sed -Ei "s/a/b/" f'              'shell interpreter'   # combined-flag fix (#6)
expect_block 'perl -pi -e "s/a/b/" f'          'shell interpreter'   # perl -pi fix (#6)
expect_block "sed 's/a/b/' f"                  'gates sed'           # read-only sed steered off (Rule 11b)
expect_block "ls | sed 's|.*/||'"              'gates sed'           # read-only sed in a pipe

echo "== workflow gates (force a prompt, exit 0 + ask) =="
expect_gate 'git add .'
expect_gate 'git commit -m "wip"'
expect_gate 'git push origin main'
expect_gate 'git reset --hard HEAD'
expect_gate 'git branch -D old'
expect_gate 'git "push" --force'               # quoted-subcommand fix (#1)
expect_gate 'git p"u"sh'                        # split-quote fix (#1)

echo "== escape hatch (#override) =="
expect_allow 'cat notes.md #override'                    # real trailing marker bypasses overreach
expect_block 'cat "#override.md"' "'cat' in a Bash call" # quoted marker in DATA does not escape (fix #4)
expect_gate  'git add . #override'                       # #override never skips a workflow gate

echo "== passes (allow, silent) =="
expect_allow 'git status'
expect_allow 'git log --oneline -20'
expect_allow 'git branch --list'
expect_allow 'grep -rn foo src'
expect_allow 'grep -c foo src | wc -l'         # grep|wc count exemption
expect_allow 'ls -la'

echo "== Rule 10 — raw/npx tool with a wrapping package.json (cwd-aware) =="
expect_block 'npx jest'              "running 'jest' raw/npx"   "$FIXTURE"
expect_block 'jest --watch'          "running 'jest' raw/npx"   "$FIXTURE"
expect_block 'npx eslint .'          "running 'eslint' raw/npx" "$FIXTURE"
expect_block 'npx jest --coverage x' "running 'jest' raw/npx"   "$FIXTURE"
expect_block 'npx jest'              "running 'jest' raw/npx"   "$FIXTURE/sub"  # nearest package.json is one dir up
expect_allow 'npx jest'              "$HOME"                                    # control: no wrapping script above -> passes

echo "== Rule 9b — pager-disabling git flag (no-op in the tool, breaks the allowlist) =="
expect_block 'git -c core.pager=cat show f491d6c --stat' 'pager-disabling git flag'
expect_block 'git --no-pager log --oneline -20'          'pager-disabling git flag'
expect_gate  'git -c core.pager=cat commit -m wip'       # mutation still gates first (Rule 8b), not corrected
expect_allow 'git show f491d6c --stat --date=short'      # control: plain git show, no pager flag

echo "== Rules 12/13/14 — gh read redirects (local git / Read / gh pr view; graphql & flag-order) =="
expect_block 'gh pr diff 42'                            'reading repo content through gh'
expect_block 'gh api repos/o/r/commits/abc123'          'reading repo content through gh'
expect_block 'gh api repos/o/r/compare/main...feature'  'reading repo content through gh'
expect_block 'gh api repos/o/r/contents/sections/x.yml?ref=main' 'reading repo content through gh'
expect_block 'gh api repos/o/r/pulls/42/comments'       'reading PR comments'
expect_block 'gh --repo o/r pr view 196 --json title'   'flag placed before the subcommand'
expect_allow "gh api graphql -f query='{ reviewThreads }'"  # inline threads: no read-only equivalent, must NOT be flagged
expect_allow 'gh pr view 42 --comments'                 # correct form: read-only, whitelistable
expect_allow 'gh pr view 42 --json state,mergedAt'      # PR metadata via gh pr view is fine
expect_allow 'gh pr view 196 --repo o/r --json title'  # Rule 14's target: --repo after the subcommand
expect_allow 'git show abc123 --stat'                   # the git form Rule 12 steers toward

echo "== heredoc bodies are data, not shell (no false overreach) =="
hd_py="$(printf '%s\n' \
  "docker exec -i app python manage.py shell <<'PY'" \
  "from consumer.models import Consumer" \
  "for c in Consumer.objects.all():" \
  "    print(c)" \
  "PY")"
expect_allow "$hd_py"                                   # a Python 'for' in the body is not a shell loop
hd_sql="$(printf '%s\n' "psql <<'SQL'" "SELECT * FROM t WHERE a | b;" "SQL")"
expect_allow "$hd_sql"                                  # SQL '|' in the body is not a shell pipe
hd_commit="$(printf '%s\n' "git commit -F - <<'MSG'" "wip | tidy" "MSG")"
expect_gate  "$hd_commit"                               # the shell command around the heredoc still gates

echo "== escape log sanitization =="
LOG="$HOME/.claude/hooks/override-escapes.log"
: > "$LOG"
run "$(printf 'grep x . #override\nEVIL-forged-row')"
rows="$(wc -l < "$LOG" | tr -d ' ')"
if [ "$rows" = "1" ]; then ok; else bad "log sanitize (no forged rows)" "want 1 log row, got $rows"; fi

echo "== Write guard — repo-destined test file authored into scratchpad/tmp =="
expect_block_w '/private/tmp/claude-501/x/scratchpad/probe.test.tsx' 'jest only discovers tests under the project'
expect_block_w '/tmp/zzprobe.spec.ts'                               'jest only discovers tests under the project'
expect_allow_w '/Users/me/project/src/app/[locale]/x/__tests__/probe.test.tsx'  # repo test path (brackets fine) -> allowed
expect_allow_w '/private/tmp/claude-501/x/scratchpad/notes.md'      # non-test scratch file -> allowed
expect_allow_w '/private/tmp/claude-501/x/scratchpad/analyze.ts'    # non-test source scratch -> out of scope, allowed

echo "== subagent carve-out — cd/relocation correctors skip when agent_id is present =="
expect_allow_sub 'cd /x && git status'                          # Rule 6 skipped: cd&&git in one call is a subagent's working form
expect_allow_sub 'git -C /x status'                             # Rule 9 skipped: repo-scoped flag is cwd-independent
expect_allow_sub 'git --git-dir=/x/.git --work-tree=/x status'  # Rule 9 skipped
expect_allow_sub 'GIT_DIR=/x/.git git status'                   # Rule 9 skipped (env-var form)
expect_gate_sub  'git -C /x add .'                              # mutation gate (8b) STILL fires in a subagent — carve-out opened no hole
# (the same relocation/cd commands WITHOUT agent_id still block — see the Rule 6 / Rule 9 cases above)

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
