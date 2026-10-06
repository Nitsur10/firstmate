#!/usr/bin/env bash
# fm-context-restart.sh - opt-in automatic save-and-restart of a Claude primary
# session once its context passes a threshold.
#
# Every turn of a long primary session re-reads its whole context, so a session
# that runs far past its useful size pays for that size on every step. A written
# "start a fresh session at ~200k" rule is easy to forget; this makes the
# restart happen. It is off unless the home creates config/context-restart.
#
# Scope: only the main home's primary Claude session - the session that owns
# state/.lock in a plain primary checkout. Secondmate homes (a valid
# .fm-secondmate-home marker), linked task worktrees, the supervision host
# (an SDK entrypoint), and every other harness stay inert.
#
# Flow:
#   1. stop-hook (tracked Claude Stop hook) measures the session's context from
#      its transcript after each turn. Once the context reaches the threshold,
#      or the conversation's first measured context plus half the threshold if
#      that is larger, it blocks the stop once per conversation and tells the
#      model to finish the wake in hand, run the stow pass, then run
#      `restart --stowed`. The floor rule keeps a restarted session that starts
#      near the threshold from restarting again straight away.
#   2. restart --stowed (run by the model) refuses unless the session owns the
#      lock and runs inside a pane this script can type into (tmux, Herdr, or
#      cmux), records a request, and starts the detached injector. The model
#      then ends its turn. --stowed is the model's statement that the stow pass
#      finished; durable fleet state (the wake queue, backlog, task records)
#      already lives on disk and nothing here acknowledges or deletes it.
#   3. inject (detached) waits until the turn that ran `restart` has ended (the
#      stop-hook records it) and the pane is idle with an empty composer, types
#      /clear, waits for session-hook to observe the cleared conversation,
#      then submits one record-backed session-start operational input so the
#      fresh conversation takes a turn, retrying that submit until its
#      deadline. If any later turn (a wake or a captain message) adds a step
#      before the clear, the stop-hook cancels the request at that turn's end
#      and offers the restart again, so the stow pass is repeated first; after
#      three such cancellations in one conversation it gives up and says so. A
#      /clear typed by hand meanwhile is accepted and only the notice is sent. /clear keeps the same
#      Claude process, so the session lock, its Remote Control link, and the
#      launcher's own arguments are untouched; the SessionStart hook re-emits
#      the bin/fm-session-start.sh digest (wake queue included) for the lock
#      owner, and that first turn's Stop re-arms supervision as usual. Away
#      mode's state/.afk is never touched, and the operational input keeps an
#      away session away.
#   4. session-hook (tracked Claude SessionStart hook) records the clear when a
#      request is pending for this lock owner.
#   A failed or abandoned restart is reported to the model once, so it can
#   tell the captain: by the next Stop in the same conversation when the clear
#   never happened, or by the cleared conversation's first Stop when only the
#   notice failed.
#
# Configuration: config/context-restart (local, gitignored). Absent = off and
# each hook costs one file test. Its first line that is not blank and not a
# `#` comment is the threshold in tokens, as an integer or with a `k` suffix
# (200000 or 200k); a file with no such line uses 200000. A threshold below
# 50000 is refused, because a fresh session after its startup digest already
# sits near that size (about 58k measured on a lab home) and would have no room
# to work. An invalid file keeps the feature inert and is reported by `status`.
#
# Usage:
#   fm-context-restart.sh stop-hook        Claude Stop hook; payload on stdin
#   fm-context-restart.sh session-hook     Claude SessionStart hook; payload on stdin
#   fm-context-restart.sh restart --stowed run by the primary after its stow pass
#   fm-context-restart.sh status           threshold, pending restart, recent log
#   fm-context-restart.sh inject           internal: the detached injector
#
# Durable records live in state/context-restart/: floor (conversation id and
# its first measured context), prompted (conversation id already told to
# restart, then its measured context), turn-end (transcript and assistant-step
# count when the restarting turn ended), cancels, request (key=value), cleared, result, reported, and
# an append-only log. Context is the last main-chain assistant step's
# input + cache-creation + cache-read tokens, read from a bounded tail of the
# transcript Claude names in the hook payload.
#
# Tunables (environment): FM_CONTEXT_RESTART_TIMEOUT (1800: seconds the
# injector may take end to end), FM_CONTEXT_RESTART_POLL (2: seconds between
# pane reads), FM_CONTEXT_RESTART_MEASURE_TIMEOUT (10: bound on reading the
# transcript).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/context-restart"
DIR="$STATE/context-restart"
LOG="$DIR/log"

DEFAULT_THRESHOLD=200000
MIN_THRESHOLD=50000
TIMEOUT=${FM_CONTEXT_RESTART_TIMEOUT:-1800}
POLL=${FM_CONTEXT_RESTART_POLL:-2}
MEASURE_TIMEOUT=${FM_CONTEXT_RESTART_MEASURE_TIMEOUT:-10}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=1800 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$MEASURE_TIMEOUT" in ''|*[!0-9]*|0) MEASURE_TIMEOUT=10 ;; esac

usage() {
  sed -n '/^# Usage:/,/^# Durable/{/^# Durable/d;s/^# \{0,1\}//;p;}' "$0"
}

now() { date +%s; }

log_line() {  # <text>
  mkdir -p "$DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  mkdir -p "$DIR" 2>/dev/null || return 1
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Print the first line of a record file, or nothing.
first_line() {  # <file>
  [ -f "$1" ] || return 0
  head -n 1 "$1" 2>/dev/null || true
}

# Print the value of <key> in the request record, or nothing.
request_get() {  # <key>
  [ -f "$DIR/request" ] || return 0
  sed -n "s/^$1=//p" "$DIR/request" 2>/dev/null | head -n 1
}

# --- configuration ----------------------------------------------------------
THRESHOLD=
CONFIG_ERROR=
# Sets THRESHOLD, or CONFIG_ERROR and returns 1. Returns 2 when the feature is
# off (no config file).
read_threshold() {
  local line value
  THRESHOLD=
  CONFIG_ERROR=
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || return 2
  if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ]; then
    CONFIG_ERROR="config/context-restart must be a readable regular file"
    return 1
  fi
  value=
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$line" in ''|'#'*) continue ;; esac
    value=$line
    break
  done < "$CONFIG_FILE"
  if [ -z "$value" ]; then
    THRESHOLD=$DEFAULT_THRESHOLD
    return 0
  fi
  case "$value" in
    *[!0-9kK]*|[kK]*|*[kK]?*|'') CONFIG_ERROR="config/context-restart threshold '$value' is not a token count such as 200000 or 200k"; return 1 ;;
    *[kK]) value=${value%?}; value=$((10#$value * 1000)) ;;
    *) value=$((10#$value)) ;;
  esac
  if [ "$value" -lt "$MIN_THRESHOLD" ]; then
    CONFIG_ERROR="config/context-restart threshold $value is below the $MIN_THRESHOLD minimum (a fresh session starts near that size)"
    return 1
  fi
  THRESHOLD=$value
  return 0
}

# --- scope ------------------------------------------------------------------
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SCOPE_REASON=
# True when this process belongs to the main home's lock-owning primary Claude
# session. Sets SCOPE_REASON when false.
in_primary_scope() {
  SCOPE_REASON=
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    sdk*) SCOPE_REASON="an SDK session such as the supervision host is not the primary"; return 1 ;;
  esac
  if fm_root_is_secondmate_home "$FM_ROOT" || fm_root_is_secondmate_home "$FM_HOME"; then
    SCOPE_REASON="second mate homes never restart automatically"
    return 1
  fi
  if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
    SCOPE_REASON="not a primary checkout with a state directory"
    return 1
  fi
  if ! fm_session_lock_owned_by_self "$STATE"; then
    SCOPE_REASON="this session does not own the home's session lock"
    return 1
  fi
  # Pi's Claude-hook compatibility layer and other hosts also load the tracked
  # Claude settings; only a proven Claude session (a Claude-shaped CLAUDE_PID in
  # this process's harness ancestry) is in scope.
  if ! fm_session_lock_trusted_session_id >/dev/null; then
    SCOPE_REASON="only a Claude primary session can restart itself this way"
    return 1
  fi
  return 0
}

# --- measurement ------------------------------------------------------------
# Print the context of the last main-chain assistant step in <transcript>.
measure_tail() {  # <transcript>
  tail -c 4000000 "$1" 2>/dev/null \
    | grep -F '"type":"assistant"' \
    | jq -R -r 'fromjson?
        | select(type == "object" and .type == "assistant" and (.isSidechain | not)
                 and (.message.usage | type) == "object"
                 and (.message.model // "") != "<synthetic>")
        | (.message.usage.input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null \
    | tail -n 1
}

measure_context() {  # <transcript>
  local transcript=$1 out
  [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  out=$(fm_run_timed "$MEASURE_TIMEOUT" bash -c "$(declare -f measure_tail); measure_tail \"\$1\"" _ "$transcript") || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# Print how many assistant steps <transcript> holds (0 when unreadable).
assistant_steps() {  # <transcript>
  local n
  [ -n "$1" ] && [ -f "$1" ] || { echo 0; return 0; }
  n=$(grep -c -F '"type":"assistant"' "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

# --- pane endpoint ----------------------------------------------------------
ENDPOINT_BACKEND=
ENDPOINT_TARGET=
# Resolve the pane this primary runs in, innermost multiplexer first, matching
# bin/fm-backend.sh's fm_backend_detect order. Zellij and Orca are not used:
# a primary's own Zellij pane id has no verified mapping to that adapter's
# target, and Orca never hosts a primary.
resolve_endpoint() {
  ENDPOINT_BACKEND=
  ENDPOINT_TARGET=
  if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
    ENDPOINT_BACKEND=tmux
    ENDPOINT_TARGET=$TMUX_PANE
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    ENDPOINT_BACKEND=herdr
    ENDPOINT_TARGET="${HERDR_SESSION:-default}:$HERDR_PANE_ID"
  elif [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ]; then
    ENDPOINT_BACKEND=cmux
    ENDPOINT_TARGET="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
  else
    return 1
  fi
  return 0
}

load_backend() {
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  # shellcheck source=bin/fm-composer-lib.sh
  . "$SCRIPT_DIR/fm-composer-lib.sh" || return 1
  fm_backend_source "$1"
}

# True when <backend> <target> shows an idle Claude with an empty composer.
pane_ready() {  # <backend> <target>
  local backend=$1 target=$2 native tail_lines
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = empty ] || return 1
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  [ "$native" != busy ] || return 1
  tail_lines=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  if printf '%s' "$tail_lines" | grep -v '^[[:space:]]*$' | tail -n 12 | fm_busy_lines_match claude; then
    return 1
  fi
  return 0
}

# --- result records ---------------------------------------------------------
RESULT_STATE=
RESULT_REASON=
read_result() {
  local line
  RESULT_STATE=
  RESULT_REASON=
  line=$(first_line "$DIR/result")
  [ -n "$line" ] || return 1
  RESULT_STATE=${line%% *}
  RESULT_REASON=${line#* }
  [ "$RESULT_REASON" != "$line" ] || RESULT_REASON=
  return 0
}

record_result() {  # <done|failed> <reason>
  printf '%s %s\n' "$1" "$2" | write_atomic "$DIR/result" || true
  log_line "restart $1: $2"
}

# True while a request exists with no result and its deadline has not passed.
request_pending() {
  local at
  [ -f "$DIR/request" ] || return 1
  [ ! -f "$DIR/result" ] || return 1
  at=$(request_get requested_at)
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(now) - at )) -le $((TIMEOUT + 120)) ]
}

block() {  # <reason>
  jq -cn --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

# --- stop-hook --------------------------------------------------------------
cmd_stop_hook() {
  local payload transcript session ctx req_session reported floor trigger cancels cleared_session
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || exit 0
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  ! fm_hook_payload_is_foreign_host "$payload" || exit 0
  read_threshold || exit 0
  in_primary_scope || exit 0
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$session" ] || exit 0

  # A restart this conversation asked for. The first turn end after the
  # request is the turn that ran `restart`; record how many assistant steps
  # the transcript held then, so the injector can tell whether any later turn
  # (a wake, a captain message) ran before the clear. A later turn end while
  # the request is still pending means exactly that: cancel it so the stow
  # pass is repeated, and offer the restart again below, at most twice per
  # conversation. A failure or an abandoned injector is reported once.
  req_session=$(request_get session)
  if [ -n "$req_session" ] && [ "$req_session" = "$session" ]; then
    if request_pending; then
      if [ ! -f "$DIR/turn-end" ]; then
        printf '%s\n%s\n' "$transcript" "$(assistant_steps "$transcript")" | write_atomic "$DIR/turn-end" || true
        exit 0
      fi
      [ "$(assistant_steps "$transcript")" -gt "$(sed -n 2p "$DIR/turn-end" 2>/dev/null || echo 0)" ] || exit 0
      record_result cancelled "a later turn ran before the clear, so the stow pass may be out of date"
      cancels=$(sed -n 2p "$DIR/cancels" 2>/dev/null)
      [ "$(first_line "$DIR/cancels")" = "$session" ] || cancels=0
      case "$cancels" in ''|*[!0-9]*) cancels=0 ;; esac
      cancels=$((cancels + 1))
      printf '%s\n%s\n' "$session" "$cancels" | write_atomic "$DIR/cancels" || true
      if [ "$cancels" -ge 3 ]; then
        printf '%s\n' "$session" | write_atomic "$DIR/reported" || true
        block "Context restart gave up: new work kept arriving before the clear, three times. This conversation is still at about $(request_get context) tokens. Tell the captain the automatic restart could not find a quiet moment, and ask them to type /clear in this session when convenient; do not retry the restart yourself in this conversation."
      fi
      rm -f "$DIR/prompted" 2>/dev/null || true
    else
      reported=$(first_line "$DIR/reported")
      if [ "$reported" != "$session" ] && [ ! -f "$DIR/cleared" ]; then
        if ! read_result; then
          RESULT_STATE=failed
          RESULT_REASON="the restart helper stopped without finishing"
          record_result failed "$RESULT_REASON"
        fi
        if [ "$RESULT_STATE" = failed ]; then
          printf '%s\n' "$session" | write_atomic "$DIR/reported" || true
          block "Context restart did not complete: ${RESULT_REASON:-no reason recorded}. This conversation is still at about $(request_get context) tokens. Tell the captain the automatic restart failed and why, and ask them to type /clear in this session when convenient; do not retry the restart yourself in this conversation."
        fi
      fi
      read_result || true
      [ "$RESULT_STATE" = cancelled ] || exit 0
    fi
  fi

  # A failure after the clear belongs to the cleared conversation: its restart
  # notice never arrived, so tell it once what the notice would have said.
  cleared_session=$(first_line "$DIR/cleared")
  cleared_session=${cleared_session#* }
  if [ -n "$cleared_session" ] && [ "$cleared_session" = "$session" ] && ! request_pending \
    && read_result && [ "$RESULT_STATE" = failed ] && [ "$(first_line "$DIR/reported")" != "$session" ]; then
    printf '%s\n' "$session" | write_atomic "$DIR/reported" || true
    block "Context restart cleared the previous conversation, but its restart notice did not arrive (${RESULT_REASON:-no reason recorded}). The bin/fm-session-start.sh digest at the start of this conversation is current: handle its wake queue and any OPEN DECISIONS or UNREAD STATUS it shows, then resume the emitted supervision protocol. Do not type /clear again."
  fi

  ctx=$(measure_context "$transcript") || exit 0
  # The first context measured in a conversation is its floor. The prompt
  # fires at the threshold or at the floor plus half the threshold, whichever
  # is larger, so a conversation that starts above the threshold (a large
  # startup digest, or one long first turn) still has room to work and a
  # restarted session can never restart again straight away.
  floor=
  [ "$(first_line "$DIR/floor")" != "$session" ] || floor=$(sed -n 2p "$DIR/floor" 2>/dev/null)
  case "$floor" in
    ''|*[!0-9]*) floor=$ctx; printf '%s\n%s\n' "$session" "$ctx" | write_atomic "$DIR/floor" || true ;;
  esac
  trigger=$((floor + THRESHOLD / 2))
  [ "$trigger" -ge "$THRESHOLD" ] || trigger=$THRESHOLD
  [ "$ctx" -ge "$trigger" ] || exit 0
  [ "$(first_line "$DIR/prompted")" != "$session" ] || exit 0
  printf '%s\n%s\n' "$session" "$ctx" | write_atomic "$DIR/prompted" || exit 0
  log_line "prompted session=$session context=$ctx threshold=$THRESHOLD floor=$floor"
  block "Context restart: this primary session's context is about $ctx tokens, past its restart point in config/context-restart (threshold $THRESHOLD tokens). Restart it now, before taking new work: finish handling any wake already in hand (acknowledge only what you handled), then load the stow skill and run its complete pass so this session's knowledge and open work records are on disk. Then run \`bin/fm-context-restart.sh restart --stowed\` and end your turn without further tool calls. That clears this conversation when the turn ends; the cleared session receives the bin/fm-session-start.sh digest (including any queued wakes) and a restart notice, and resumes supervision. If restart refuses, tell the captain why in one line and continue normally."
}

# --- session-hook -----------------------------------------------------------
cmd_session_hook() {
  local payload source session req_session pid lock_pid
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || exit 0
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  ! fm_hook_payload_is_foreign_host "$payload" || exit 0
  source=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)
  [ "$source" = clear ] || exit 0
  request_pending || exit 0
  in_primary_scope || exit 0
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
  req_session=$(request_get session)
  [ -n "$session" ] && [ "$session" != "$req_session" ] || exit 0
  pid=$(request_get pid)
  lock_pid=$(first_line "$STATE/.lock")
  [ -n "$pid" ] && [ "$pid" = "$lock_pid" ] || exit 0
  printf '%s %s\n' "$(now)" "$session" | write_atomic "$DIR/cleared" || exit 0
  log_line "cleared old=$req_session new=$session"
  exit 0
}

# --- restart ----------------------------------------------------------------
cmd_restart() {
  local stowed=0 arg session pid lock_pid rc ctx injector
  for arg in "$@"; do
    case "$arg" in
      --stowed) stowed=1 ;;
      *) echo "usage: fm-context-restart.sh restart --stowed" >&2; exit 2 ;;
    esac
  done
  refuse() { echo "context restart refused: $1" >&2; log_line "restart refused: $1"; exit 1; }
  read_threshold
  rc=$?
  [ "$rc" -ne 2 ] || refuse "not enabled in this home (config/context-restart is absent)"
  [ "$rc" -eq 0 ] || refuse "$CONFIG_ERROR"
  [ "$stowed" -eq 1 ] || refuse "run the stow pass first, then pass --stowed"
  in_primary_scope || refuse "$SCOPE_REASON"
  session=$(fm_session_lock_trusted_session_id) || refuse "only a Claude primary session can restart itself this way"
  pid=${CLAUDE_PID:-}
  lock_pid=$(first_line "$STATE/.lock")
  [ -n "$pid" ] && [ "$pid" = "$lock_pid" ] || refuse "the session lock names pid ${lock_pid:-none}, not this Claude process ${pid:-unknown}"
  if request_pending; then
    refuse "a restart requested at $(request_get requested_at) is still in progress"
  fi
  resolve_endpoint || refuse "this session is not running inside a tmux, Herdr, or cmux pane, so nothing can type /clear into it; ask the captain to type /clear"
  load_backend "$ENDPOINT_BACKEND" || refuse "the $ENDPOINT_BACKEND adapter could not be loaded"
  fm_backend_target_exists "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" \
    || refuse "this session's $ENDPOINT_BACKEND pane $ENDPOINT_TARGET cannot be reached"
  ctx=
  [ "$(first_line "$DIR/prompted")" != "$session" ] || ctx=$(sed -n 2p "$DIR/prompted" 2>/dev/null)
  mkdir -p "$DIR" 2>/dev/null || refuse "cannot create $DIR"
  rm -f "$DIR/cleared" "$DIR/result" "$DIR/reported" "$DIR/turn-end" 2>/dev/null || true
  write_atomic "$DIR/request" <<EOF || refuse "cannot write $DIR/request"
session=$session
pid=$pid
backend=$ENDPOINT_BACKEND
target=$ENDPOINT_TARGET
threshold=$THRESHOLD
context=${ctx:-unknown}
requested_at=$(now)
EOF
  # The injector must outlive this tool call and the turn that made it: nohup,
  # stdio detached, and its own process group, the shape
  # bin/fm-startup-network.sh uses for its deferred worker.
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-context-restart.sh" inject >/dev/null 2>&1 </dev/null &
  injector=$!
  set +m 2>/dev/null || true
  log_line "restart requested session=$session pid=$pid endpoint=$ENDPOINT_BACKEND:$ENDPOINT_TARGET injector=$injector"
  echo "context restart scheduled: end this turn now; /clear runs in this $ENDPOINT_BACKEND pane once the turn ends and the composer is empty."
}

# --- inject -----------------------------------------------------------------
cmd_inject() {
  local backend target pid at deadline cleared_at verdict doorbell body ctx transcript steps
  [ -f "$DIR/request" ] || exit 1
  backend=$(request_get backend)
  target=$(request_get target)
  pid=$(request_get pid)
  at=$(request_get requested_at)
  ctx=$(request_get context)
  case "$at" in ''|*[!0-9]*) record_result failed "the restart request is malformed"; exit 1 ;; esac
  deadline=$((at + TIMEOUT))
  load_backend "$backend" || { record_result failed "the $backend adapter could not be loaded"; exit 1; }
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"

  owner_unchanged() {
    kill -0 "$pid" 2>/dev/null || { record_result failed "the Claude process $pid exited before the restart finished"; exit 1; }
    [ "$(first_line "$STATE/.lock")" = "$pid" ] || { record_result failed "the session lock changed hands during the restart"; exit 1; }
  }
  wait_ready() {  # <what>
    while :; do
      owner_unchanged
      pane_ready "$backend" "$target" && return 0
      [ "$(now)" -lt "$deadline" ] || { record_result failed "the pane never showed an idle, empty composer before $1"; exit 1; }
      sleep "$POLL"
    done
  }

  # Type /clear only once the turn that ran `restart` has ended (the
  # stop-hook records its assistant-step count) and no later turn has added a
  # step since. A later turn makes the stop-hook cancel this request at that
  # turn's end, so the stow pass is repeated first; a /clear typed by hand in
  # the meantime is accepted and only the notice is still sent.
  while :; do
    owner_unchanged
    [ ! -f "$DIR/result" ] || { log_line "injector stopped: $(first_line "$DIR/result")"; exit 0; }
    [ ! -f "$DIR/cleared" ] || break
    if [ -f "$DIR/turn-end" ]; then
      transcript=$(sed -n 1p "$DIR/turn-end" 2>/dev/null)
      steps=$(sed -n 2p "$DIR/turn-end" 2>/dev/null)
      if [ "$(assistant_steps "$transcript")" = "$steps" ] && pane_ready "$backend" "$target"; then
        verdict=$(fm_backend_send_text_submit "$backend" "$target" "/clear" 3 0.5 0.5 2>/dev/null)
        [ "$verdict" = empty ] || { record_result failed "typing /clear was not confirmed (verdict=${verdict:-none})"; exit 1; }
        log_line "typed /clear into $backend:$target"
        break
      fi
    fi
    [ "$(now)" -lt "$deadline" ] || { record_result failed "the turn that requested the restart never reached a quiet, empty composer"; exit 1; }
    sleep "$POLL"
  done

  while :; do
    owner_unchanged
    cleared_at=$(first_line "$DIR/cleared")
    cleared_at=${cleared_at%% *}
    case "$cleared_at" in ''|*[!0-9]*) ;; *) break ;; esac
    [ "$(now)" -lt "$deadline" ] || { record_result failed "/clear was typed but the cleared session never started"; exit 1; }
    sleep "$POLL"
  done

  body="Context restart: this conversation was cleared automatically after a stow pass because the previous one reached about ${ctx:-unknown} tokens (threshold $(request_get threshold), config/context-restart). The bin/fm-session-start.sh digest above is current: handle its wake queue and any OPEN DECISIONS or UNREAD STATUS it shows, then resume the emitted supervision protocol. Tell the captain only what that digest makes captain-relevant."
  if fm_operational_harness_needs_record claude; then
    fm_operational_record_write "$STATE" session-start "$body" doorbell \
      || { record_result failed "the restart notice record could not be written"; exit 1; }
  else
    fm_operational_input_encode session-start "$body" doorbell \
      || { record_result failed "the restart notice could not be encoded"; exit 1; }
  fi
  # The cleared conversation's own SessionStart hooks (the session-start
  # digest among them) begin with the clear record written; require two idle
  # reads in a row so the notice lands after their spinner, not in the gap
  # before it is drawn. A submit that is not confirmed is retried until the
  # deadline, because the cleared conversation has no other prompt to act on.
  while :; do
    wait_ready "the restart notice"
    sleep "$POLL"
    wait_ready "the restart notice"
    verdict=$(fm_backend_send_text_submit "$backend" "$target" "$doorbell" 3 0.5 0.5 2>/dev/null)
    [ "$verdict" != empty ] || break
    log_line "restart notice not confirmed (verdict=${verdict:-none}); retrying"
    [ "$(now)" -lt "$deadline" ] || { record_result failed "the restart notice was not confirmed submitted (verdict=${verdict:-none})"; exit 1; }
    sleep $((POLL * 5))
  done
  record_result "done" "cleared and notified at $(now)"
  exit 0
}

# --- status -----------------------------------------------------------------
cmd_status() {
  local rc
  read_threshold
  rc=$?
  case "$rc" in
    2) echo "context restart: off (config/context-restart absent)" ;;
    1) echo "context restart: inert - $CONFIG_ERROR" ;;
    *) echo "context restart: on, threshold $THRESHOLD tokens" ;;
  esac
  if [ -f "$DIR/request" ]; then
    echo "last request:"
    sed 's/^/  /' "$DIR/request"
    if read_result; then
      echo "  result=$RESULT_STATE${RESULT_REASON:+ ($RESULT_REASON)}"
    elif request_pending; then
      echo "  result=pending"
    else
      echo "  result=abandoned"
    fi
  fi
  if [ -f "$LOG" ]; then
    echo "recent log:"
    tail -n 5 "$LOG" | sed 's/^/  /'
  fi
}

case "${1:-}" in
  stop-hook) shift; cmd_stop_hook "$@" ;;
  session-hook) shift; cmd_session_hook "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  inject) shift; cmd_inject "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
