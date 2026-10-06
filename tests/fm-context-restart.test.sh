#!/usr/bin/env bash
# Behavior tests for the opt-in context restart (bin/fm-context-restart.sh).
#
# Hooks and the restart command run hermetically as children of a fake harness
# (a bash symlink named "claude") that writes its own pid into the fixture
# home's state/.lock and exports it as CLAUDE_PID, which is exactly the shape a
# real Claude primary gives its hooks and tool shells. Every inherited Claude,
# multiplexer, and FM_* marker of the shell running this suite is scrubbed so
# only the fixture's identity reaches the script. The final case drives the
# real injector end to end against a private tmux server whose pane runs a
# small composer that logs each submitted line.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_HOME expand inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-restart)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The tmux case starts a private server; stop it however the suite exits.
CTX_TMUX=
CTX_SOCKET=
ctx_cleanup() {
  [ -z "$CTX_SOCKET" ] || "$CTX_TMUX" -L "$CTX_SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap ctx_cleanup EXIT

SCRUB=(-u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE
  -u CLAUDE_CODE_CHILD_SESSION -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID
  -u HERDR_SESSION -u HERDR_SOCKET_PATH -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID
  -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE
  -u FM_DATA_OVERRIDE -u GROK_AGENT -u GROK_HOOK_EVENT -u CURSOR_AGENT)

make_primary_dir() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  printf '%s\n' "$dir"
}

# A transcript whose last main-chain step carries <context> tokens.
write_transcript() {  # <file> <context>
  local file=$1 ctx=$2
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}'
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m1","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":%d,"output_tokens":3}}}\n' 1000
    printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5-5","id":"m2","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":%d,"output_tokens":3}}}\n' 999999
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m3","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d,"output_tokens":3}}}\n' $((ctx - 1010))
  } > "$file"
}

# Run <command> inside a fake Claude primary that owns <dir>'s session lock.
# Extra environment assignments go before the command as NAME=value words.
as_primary() {  # <dir> <session-id> <command-string> [stdin-file]
  local dir=$1 session=$2 cmd=$3 input=${4:-/dev/null}
  env "${SCRUB[@]}" FM_TEST_CMD="$cmd" FM_TEST_DIR="$dir" FM_TEST_SESSION="$session" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_TEST_DIR/state/.lock"
      export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION CLAUDE_CODE_ENTRYPOINT=cli
      cd "$FM_TEST_DIR" && eval "$FM_TEST_CMD"
      status=$?
      :
      exit "$status"
    ' < "$input"
}

stop_payload() {  # <file> <session> <transcript>
  jq -cn --arg s "$2" --arg t "$3" '{session_id: $s, transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}' > "$1"
}

test_off_without_config() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/off")
  write_transcript "$dir/t.jsonl" 300000
  stop_payload "$dir/p.json" S1 "$dir/t.jsonl"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1); status=$?
  expect_code 0 "$status" "stop-hook without config"
  assert_equals "" "$out" "stop-hook must print nothing when the feature is off"
  [ ! -e "$dir/state/context-restart" ] || fail "stop-hook wrote state while the feature is off"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh restart --stowed' 2>&1); status=$?
  expect_code 1 "$status" "restart without config"
  assert_contains "$out" "not enabled" "restart names the missing opt-in"
  pass "context restart: absent config keeps both hooks silent and restart refuses"
}

test_threshold_parsing() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/parse")
  : > "$dir/config/context-restart"
  out=$(env "${SCRUB[@]}" "$dir/bin/fm-context-restart.sh" status)
  assert_contains "$out" "threshold 200000" "empty config uses the default"
  printf '# comment\n\n  250k \n' > "$dir/config/context-restart"
  out=$(env "${SCRUB[@]}" "$dir/bin/fm-context-restart.sh" status)
  assert_contains "$out" "threshold 250000" "k suffix after comment and blank lines"
  printf '1000\n' > "$dir/config/context-restart"
  out=$(env "${SCRUB[@]}" "$dir/bin/fm-context-restart.sh" status)
  assert_contains "$out" "below the 50000 minimum" "a loop-prone threshold is refused"
  printf 'lots\n' > "$dir/config/context-restart"
  out=$(env "${SCRUB[@]}" "$dir/bin/fm-context-restart.sh" status)
  assert_contains "$out" "inert" "a malformed threshold keeps the feature inert"
  pass "context restart: threshold parsing accepts N and Nk, defaults when empty, refuses malformed and loop-prone values"
}

test_blocks_once_over_threshold() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/block")
  printf '200k\n' > "$dir/config/context-restart"
  write_transcript "$dir/small.jsonl" 150000
  stop_payload "$dir/p.json" S1 "$dir/small.jsonl"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1); status=$?
  expect_code 0 "$status" "under threshold"
  assert_equals "" "$out" "no block under the threshold (sidechain steps do not count)"

  write_transcript "$dir/big.jsonl" 210000
  stop_payload "$dir/p.json" S1 "$dir/big.jsonl"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1); status=$?
  expect_code 0 "$status" "over threshold"
  [ "$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null)" = block ] || fail "expected a block decision, got: $out"
  assert_contains "$out" "about 210000 tokens" "the reason names the measured context"
  assert_contains "$out" "restart --stowed" "the reason names the restart command"
  assert_contains "$out" "stow skill" "the reason requires the stow pass first"

  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "the same conversation is told only once"
  stop_payload "$dir/p2.json" S2 "$dir/big.jsonl"
  out=$(as_primary "$dir" S2 'bin/fm-context-restart.sh stop-hook' "$dir/p2.json" 2>&1)
  assert_contains "$out" '"block"' "a new conversation over the threshold is told again"
  pass "context restart: stop-hook blocks once per conversation at or over the threshold, ignoring sidechain steps"
}

test_out_of_scope_sessions_stay_silent() {
  local dir sm wt base out other
  dir=$(make_primary_dir "$TMP_ROOT/scope")
  printf '200k\n' > "$dir/config/context-restart"
  write_transcript "$dir/big.jsonl" 300000
  stop_payload "$dir/p.json" S1 "$dir/big.jsonl"

  out=$(as_primary "$dir" S1 'CLAUDE_CODE_ENTRYPOINT=sdk-cli bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "an SDK session such as the supervision host is out of scope"

  out=$(as_primary "$dir" S1 'unset CLAUDE_PID; bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "a host with no proven Claude identity is out of scope"

  "$FAKE_CLAUDE" -c 'sleep 60; :' >/dev/null 2>&1 &
  other=$!
  out=$(env "${SCRUB[@]}" FM_TEST_DIR="$dir" FM_TEST_OTHER="$other" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$FM_TEST_OTHER" > "$FM_TEST_DIR/state/.lock"
    export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=S1
    cd "$FM_TEST_DIR" && bin/fm-context-restart.sh stop-hook
    :' < "$dir/p.json" 2>&1)
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_equals "" "$out" "a session that does not own the lock is out of scope"

  sm=$(make_primary_dir "$TMP_ROOT/scope-sm")
  printf 'sm-ctx\n' > "$sm/.fm-secondmate-home"
  printf '200k\n' > "$sm/config/context-restart"
  out=$(as_primary "$sm" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "a second mate home never restarts automatically"

  base=$(make_primary_dir "$TMP_ROOT/scope-base")
  wt="$TMP_ROOT/scope-wt"
  fm_git_worktree "$base" "$wt" fm/ctx-test >/dev/null
  mkdir -p "$wt/state" "$wt/config"
  : > "$wt/AGENTS.md"
  cp -R "$ROOT/bin" "$wt/bin"
  printf '200k\n' > "$wt/config/context-restart"
  out=$(as_primary "$wt" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "a linked task worktree is out of scope"
  pass "context restart: SDK sessions, non-Claude hosts, non-owners, second mate homes, and task worktrees stay silent"
}

test_restart_refusals() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/refuse")
  printf '200k\n' > "$dir/config/context-restart"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh restart' 2>&1); status=$?
  expect_code 1 "$status" "restart without --stowed"
  assert_contains "$out" "stow pass first" "restart requires the stow statement"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh restart --stowed' 2>&1); status=$?
  expect_code 1 "$status" "restart outside a pane"
  assert_contains "$out" "ask the captain to type /clear" "restart outside a pane hands the clear to the captain"
  [ ! -e "$dir/state/context-restart/request" ] || fail "a refused restart wrote a request"
  pass "context restart: restart refuses without --stowed and outside a tmux, Herdr, or cmux pane"
}

test_failure_reported_once() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  printf '200k\n' > "$dir/config/context-restart"
  mkdir -p "$dir/state/context-restart"
  write_transcript "$dir/big.jsonl" 300000
  stop_payload "$dir/p.json" S1 "$dir/big.jsonl"
  printf 'session=S1\npid=1\nbackend=tmux\ntarget=%%1\nthreshold=200000\ncontext=300000\nrequested_at=%s\n' "$(date +%s)" \
    > "$dir/state/context-restart/request"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "a pending restart keeps the stop-hook quiet"
  printf 'failed typing /clear was not confirmed\n' > "$dir/state/context-restart/result"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_contains "$out" "did not complete: typing /clear was not confirmed" "the failure reason reaches the model"
  assert_contains "$out" "Tell the captain" "the model is told to report the failure"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_equals "" "$out" "a failure is reported once"

  rm -f "$dir/state/context-restart/result" "$dir/state/context-restart/reported"
  printf 'session=S1\npid=1\nbackend=tmux\ntarget=%%1\nthreshold=200000\ncontext=300000\nrequested_at=%s\n' "$(( $(date +%s) - 4000 ))" \
    > "$dir/state/context-restart/request"
  out=$(as_primary "$dir" S1 'bin/fm-context-restart.sh stop-hook' "$dir/p.json" 2>&1)
  assert_contains "$out" "stopped without finishing" "an abandoned restart is reported as a failure"
  pass "context restart: a failed or abandoned restart is reported to the model exactly once"
}

test_session_hook_records_clear() {
  local dir payload
  dir=$(make_primary_dir "$TMP_ROOT/clear")
  printf '200k\n' > "$dir/config/context-restart"
  mkdir -p "$dir/state/context-restart"
  payload="$dir/clear.json"
  jq -cn '{session_id: "S2", source: "clear", hook_event_name: "SessionStart"}' > "$payload"
  as_primary "$dir" S2 '
    printf "session=S1\npid=%s\nbackend=tmux\ntarget=%%1\nthreshold=200000\ncontext=300000\nrequested_at=%s\n" "$$" "$(date +%s)" > state/context-restart/request
    bin/fm-context-restart.sh session-hook' "$payload" >/dev/null 2>&1
  assert_grep ' S2' "$dir/state/context-restart/cleared" "session-hook records the cleared conversation"
  rm -f "$dir/state/context-restart/cleared"
  jq -cn '{session_id: "S3", source: "startup"}' > "$payload"
  as_primary "$dir" S3 '
    printf "session=S1\npid=%s\nbackend=tmux\ntarget=%%1\nthreshold=200000\ncontext=300000\nrequested_at=%s\n" "$$" "$(date +%s)" > state/context-restart/request
    bin/fm-context-restart.sh session-hook' "$payload" >/dev/null 2>&1
  [ ! -e "$dir/state/context-restart/cleared" ] || fail "a startup source must not count as the requested clear"
  pass "context restart: session-hook records only a clear of the requesting lock owner"
}

# End to end through the real injector: a private tmux pane runs a composer
# that logs submitted lines; the fake primary requests the restart, the
# injector types /clear, the test plays Claude's SessionStart hook when the
# clear arrives, and the injector then submits the restart notice.
test_injector_end_to_end_tmux() {
  local dir socket real_tmux shim pane log i
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  dir=$(make_primary_dir "$TMP_ROOT/e2e")
  printf '200k\n' > "$dir/config/context-restart"
  real_tmux=$(command -v tmux)
  socket="fm-ctx-restart-$$"
  log="$dir/submitted.log"
  : > "$log"
  cat > "$dir/composer.sh" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
stty -echo -icanon min 1 time 0 2>/dev/null || true
buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$buf"; }
redraw
while IFS= read -r -n 1 ch; do
  case "$ch" in
    ''|$'\r'|$'\n') printf '%s\n' "$buf" >> "$LOG"; buf=; printf '\r\033[K\n'; redraw ;;
    $'\177'|$'\b') buf=${buf%?}; redraw ;;
    *) buf="$buf$ch"; redraw ;;
  esac
done
LOOP
  "$real_tmux" -L "$socket" -f /dev/null new-session -d -s ctx -x 200 -y 50
  CTX_TMUX=$real_tmux
  CTX_SOCKET=$socket
  pane=$("$real_tmux" -L "$socket" display-message -p -t ctx '#{pane_id}')
  "$real_tmux" -L "$socket" send-keys -t "$pane" "bash '$dir/composer.sh' '$log'" Enter
  sleep 1
  shim="$dir/shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$socket" > "$shim/tmux"
  chmod +x "$shim/tmux"

  env "${SCRUB[@]}" PATH="$shim:$PATH" TMUX="/tmp/fm-ctx-fake,1,0" TMUX_PANE="$pane" \
    FM_CONTEXT_RESTART_POLL=1 FM_CONTEXT_RESTART_TIMEOUT=60 FM_TEST_DIR="$dir" FM_TEST_LOG="$log" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_TEST_DIR/state/.lock"
      export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=S1 CLAUDE_CODE_ENTRYPOINT=cli
      cd "$FM_TEST_DIR" || exit 1
      bin/fm-context-restart.sh restart --stowed > restart.out 2>&1 || exit 1
      for i in $(seq 1 60); do grep -qx "/clear" "$FM_TEST_LOG" && break; sleep 0.5; done
      printf "%s\n" "{\"session_id\":\"S2\",\"source\":\"clear\"}" | CLAUDE_CODE_SESSION_ID=S2 bin/fm-context-restart.sh session-hook
      for i in $(seq 1 60); do [ -e state/context-restart/result ] && break; sleep 0.5; done
      :' >/dev/null 2>&1
  for i in $(seq 1 20); do [ -e "$dir/state/context-restart/result" ] && break; sleep 0.5; done
  "$real_tmux" -L "$socket" kill-server 2>/dev/null || true

  assert_contains "$(cat "$dir/restart.out" 2>/dev/null)" "context restart scheduled" "restart schedules the injector"
  assert_grep 'done ' "$dir/state/context-restart/result" "the injector finishes"
  [ "$(sed -n 1p "$log")" = "/clear" ] || fail "first submission must be /clear, got: $(cat "$log")"
  assert_contains "$(sed -n 2p "$log")" ": Firstmate operational input waiting: read '" "second submission is the operational doorbell"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ] || fail "expected exactly two submissions, got: $(cat "$log")"
  i=$(sed -n 2p "$log" | sed "s/.*read '\\([^']*\\)'.*/\\1/")
  assert_grep 'FIRSTMATE_OP: v1 session-start: Context restart:' "$i" "the doorbell names a session-start operational record"
  pass "context restart: end to end in tmux the injector types /clear, waits for the cleared session, then submits one restart notice"
}

test_off_without_config
test_threshold_parsing
test_blocks_once_over_threshold
test_out_of_scope_sessions_stay_silent
test_restart_refusals
test_failure_reported_once
test_session_hook_records_clear
test_injector_end_to_end_tmux
