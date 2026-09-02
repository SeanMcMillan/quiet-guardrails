#!/usr/bin/env bash
# Test suite for the quiet-guardrails PreToolUse hook.
#
#   bash tests/run.sh [path-to-guard]
#
# Feeds fake tool payloads to the guard and checks each outcome:
#   block  — exit 2 (overreach self-correction); stderr must contain a substring
#   gate   — exit 0 with a permissionDecision:"ask" JSON on stdout (safety gate)
#   allow  — exit 0, no stdout, no stderr (command passes, or an #override escape)
#
# Requires jq (ships with Claude Code). Runs under an isolated $HOME so the
# escape-log writes don't touch your real ~/.claude.

GUARD="${1:-$(cd "$(dirname "$0")/.." && pwd)/hooks/guard-bash-overreach.sh}"
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude/hooks"   # let escape-log writes land where we can inspect them
pass=0 fail=0

run() { # $1 = command; sets $out $err $code
  local payload err_file
  payload="$(jq -nc --arg c "$1" '{tool_input:{command:$c}}')"
  err_file="$(mktemp)"
  out="$(printf '%s' "$payload" | bash "$GUARD" 2>"$err_file")"
  code=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"
}

ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n        %s\n' "$1" "$2"; }

expect_block() { run "$1"
  if [ "$code" -eq 2 ] && printf '%s' "$err" | grep -qF "$2"; then ok
  else bad "block: $1" "want exit 2 + [$2]; got code=$code err=[$err]"; fi; }
expect_gate()  { run "$1"
  if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then ok
  else bad "gate:  $1" "want ask JSON; got code=$code out=[$out]"; fi; }
expect_allow() { run "$1"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok
  else bad "allow: $1" "want silent exit 0; got code=$code out=[$out] err=[$err]"; fi; }

echo "== overreach rules (self-correct, exit 2) =="
expect_block 'grep -rn foo src | head -5'      'wired into a pipe'
expect_block 'cat notes.md'                    "'cat' in a Bash call"
expect_block 'head -20 file.txt'               'to read a file'
expect_block 'npm run test 2>&1 | tail -20'    'capping piped output'
expect_block 'npm run build 2>&1'              'stream-merge'
expect_block 'ls; echo done'                   "chained 'echo'"
expect_block 'cd myrepo && git status'         'bundled in one command'
expect_block 'git -C /tmp/x status'            'git -C <path>'
expect_block 'git -C /repo branch --list'      'git -C <path>'    # branch/-C collision -> corrector, not gate
expect_block 'find src/[locale] -name "*.tsx"' 'glob character'
expect_block 'for f in a b; do echo $f; done'  'shell loop'
expect_block 'python3 munge.py data.json'      'parsing JSON'
expect_block 'sed -i "s/a/b/" f'               'shell interpreter'
expect_block 'sed -Ei "s/a/b/" f'              'shell interpreter'   # combined-flag fix (#6)
expect_block 'perl -pi -e "s/a/b/" f'          'shell interpreter'   # perl -pi fix (#6)

echo "== safety gates (force a prompt, exit 0 + ask) =="
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
expect_gate  'git add . #override'                       # #override never skips a safety gate

echo "== passes (allow, silent) =="
expect_allow 'git status'
expect_allow 'git log --oneline -20'
expect_allow 'git branch --list'
expect_allow 'grep -rn foo src'
expect_allow 'grep -c foo src | wc -l'         # grep|wc count exemption
expect_allow 'ls -la'

echo "== escape log sanitization =="
LOG="$HOME/.claude/hooks/override-escapes.log"
: > "$LOG"
run "$(printf 'grep x . #override\nEVIL-forged-row')"
rows="$(wc -l < "$LOG" | tr -d ' ')"
if [ "$rows" = "1" ]; then ok; else bad "log sanitize (no forged rows)" "want 1 log row, got $rows"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
