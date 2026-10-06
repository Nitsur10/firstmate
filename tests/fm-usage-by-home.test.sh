#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-by-home.sh: spawn attribution records and the
# per-home, per-task usage report built from Claude session transcripts.
#
# The fixture is a fake HOME with one Claude login folder (~/.claude and its
# ~/.claude.json account record), a main home with a local and a remote second
# mate registered, and transcripts covering every attribution rule.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-usage-by-home)
fm_git_identity fmtest fmtest@example.invalid
SCRIPT="$ROOT/bin/fm-usage-by-home.sh"
SCRUB=(-u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u CLAUDE_CONFIG_DIR)

iso_ago() {  # <seconds-ago>
  local t=$(( $(date +%s) - $1 ))
  date -u -r "$t" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%S.000Z
}

# One assistant step: <file> <id> <seconds-ago> <cwd> <branch> <entrypoint> <model> <cache-read> <output>
step() {
  mkdir -p "$(dirname "$1")"
  jq -cn --arg id "$2" --arg ts "$(iso_ago "$3")" --arg cwd "$4" --arg br "$5" --arg ep "$6" --arg m "$7" \
    --argjson cr "$8" --argjson out "$9" \
    '{type: "assistant", timestamp: $ts, cwd: $cwd, gitBranch: $br, entrypoint: $ep, isSidechain: false,
      message: {id: $id, model: $m, usage: {input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: $cr, output_tokens: $out}}}' >> "$1"
}

test_record_appends_attribution() {
  local home out status line
  home="$TMP_ROOT/rec"
  mkdir -p "$home/state" "$home/wt"
  env "${SCRUB[@]}" FM_HOME="$home" "$SCRIPT" record t1 ship claude "$home/wt" /acct/dir >/dev/null \
    || fail "record failed"
  line=$(cat "$home/state/usage-attribution.tsv")
  assert_contains "$line" $'\tt1\tship\tclaude\t'"$home/wt"$'\t' "record writes task, kind, harness, and cwd"
  assert_contains "$line" $'\t/acct/dir' "record writes the login folder"
  case "${line%%$'\t'*}" in ''|*[!0-9]*) fail "record must start with an epoch: $line" ;; esac
  out=$(env "${SCRUB[@]}" FM_HOME="$home" "$SCRIPT" record $'bad\ttask' ship claude "$home/wt" 2>&1); status=$?
  expect_code 2 "$status" "record refuses a tab in a field"
  assert_contains "$out" "must not contain tabs" "record names the bad field shape"
  pass "usage by home: record appends one tab-separated attribution line and refuses malformed fields"
}

test_report_attributes_every_rule() {
  local h main sm wt nmwt proj tsv acct out now
  h="$TMP_ROOT/report"
  main="$h/main"; sm="$h/sm1"; wt="$h/pool/1/proj"; nmwt="$h/nm/.no-mistakes/worktrees/abc123/RUN1"
  mkdir -p "$h/fakehome/.claude/projects" "$main/state" "$main/data" "$sm/state" "$wt" "$nmwt"
  printf '{"oauthAccount":{"emailAddress":"owner@example.invalid"}}\n' > "$h/fakehome/.claude.json"
  printf 'sm1\n' > "$sm/.fm-secondmate-home"
  {
    printf -- '- sm1 - Local mate. (home: %s; scope: things; projects: proj; added 2026-01-01)\n' "$sm"
    printf -- '- rm1 - Remote mate. (host: mini; root: /r; home: /r/h; scope: other; projects: none; added 2026-01-01)\n'
  } > "$main/data/secondmates.md"
  proj="$main/projects/proj"
  fm_git_init_commit "$proj" >/dev/null 2>&1
  git -C "$proj" remote add no-mistakes /x/.no-mistakes/repos/abc123.git

  now=$(date +%s)
  # The pool slot served taska first, then taskb from 2 hours ago.
  printf '%s\ttaska\tship\tclaude\t%s\t%s\t\n' $((now - 20000)) "$wt" "$wt" > "$main/state/usage-attribution.tsv"
  printf '%s\ttaskb\tship\tclaude\t%s\t%s\t\n' $((now - 7200)) "$wt" "$wt" >> "$main/state/usage-attribution.tsv"
  printf '%s\tmatetask\tship\tclaude\t%s\t%s\t\n' $((now - 9000)) "$h/pool/2/other" "$h/pool/2/other" > "$sm/state/usage-attribution.tsv"

  acct="$h/fakehome/.claude/projects"
  step "$acct/main/s1.jsonl" m1 3600 "$main" "main" cli claude-opus-5-5 1000000 0
  step "$acct/main/s1.jsonl" m1 3600 "$main" "main" cli claude-opus-5-5 1000000 0
  step "$acct/main/s2.jsonl" m2 3500 "$main/projects/proj" "main" sdk-cli claude-sonnet-5-5 1000000 0
  step "$acct/main/s9.jsonl" m1 3600 "$main" "main" cli claude-opus-5-5 1000000 0
  step "$acct/wt/s3.jsonl" m3 10000 "$wt" "fm/taska" cli claude-opus-5-5 1000000 0
  step "$acct/wt/s4.jsonl" m4 3000 "$wt/sub" "fm/taskb" cli claude-opus-5-5 1000000 0
  step "$acct/sm/s5.jsonl" m5 3000 "$sm" "main" cli claude-opus-5-5 1000000 0
  step "$acct/sm/s6.jsonl" m6 3000 "$h/pool/2/other" "fm/matetask" cli claude-haiku-4-5-20251001 1000000 0
  step "$acct/nm/s7.jsonl" m7 3000 "$nmwt" "HEAD" sdk-cli claude-sonnet-5-5 1000000 0
  step "$acct/nm/s8.jsonl" m8 3000 "$h/nm/.no-mistakes/worktrees/zzz/RUN2" "fm/matetask" sdk-cli claude-sonnet-5-5 1000000 0
  step "$acct/x/s10.jsonl" m10 3000 "$h/elsewhere" "" cli mystery-model 5 7
  step "$acct/x/s11.jsonl" m11 $((9 * 86400)) "$main" "main" cli claude-opus-5-5 1000000 0

  tsv=$(env "${SCRUB[@]}" HOME="$h/fakehome" FM_HOME="$main" "$SCRIPT" --since 1d --tsv) || fail "report failed"
  row() { printf '%s\n' "$tsv" | awk -F'\t' -v home="$1" -v task="$2" '$3 == home && $4 == task { print $5 "\t" $10 }'; }
  assert_equals $'1\t0.20' "$(row main '(firstmate)')" "main session counted once despite a repeated and a resumed copy of its step, and its step outside the window excluded"
  assert_equals $'1\t0.20' "$(row main '(supervision host)')" "an SDK session under a home root is its supervision host"
  assert_equals $'1\t0.20' "$(row main taskb)" "a reused slot's later session belongs to the later task"
  assert_equals $'1\t0.20' "$(row main taska)" "a reused slot's earlier session stays with the earlier task"
  assert_equals $'1\t0.20' "$(row sm1 '(firstmate)')" "a local second mate's own session is its home's"
  assert_equals $'1\t0.10' "$(row sm1 matetask)" "a second mate's worker is attributed through that home's records"
  assert_equals $'1\t0.20' "$(row main 'proj (PR checks)')" "a detached PR check maps through the clone's pipeline remote"
  assert_equals $'1\t0.20' "$(row sm1 'matetask (PR checks)')" "a PR check on a task branch belongs to that task"
  assert_equals $'1\t0.00' "$(row '(other)' "$h/elsewhere")" "an unknown working directory is reported as other, unpriced"
  assert_contains "$tsv" $'\towner@example.invalid\t' "rows carry the login folder's account"

  out=$(env "${SCRUB[@]}" HOME="$h/fakehome" FM_HOME="$main" "$SCRIPT" --since 1d) || fail "human report failed"
  assert_contains "$out" "(owner@example.invalid)" "the human report names the account"
  assert_contains "$out" "Not counted: second mate rm1 runs on mini" "a remote second mate is named as not counted"
  assert_contains "$out" "Unpriced model (tokens counted, no cost): mystery-model" "unknown models are flagged"
  pass "usage by home: report attributes home roots, supervision hosts, reused slots, second mates, PR checks, and other work, counting each step once"
}

test_report_rejects_bad_window() {
  local out status
  out=$(env "${SCRUB[@]}" FM_HOME="$TMP_ROOT" "$SCRIPT" --since soon 2>&1); status=$?
  expect_code 2 "$status" "a malformed --since"
  assert_contains "$out" "is not 7d, 36h, 90m, YYYY-MM-DD, or epoch seconds" "the accepted forms are named"
  pass "usage by home: a malformed window is refused"
}

test_record_appends_attribution
test_report_attributes_every_rule
test_report_rejects_bad_window
