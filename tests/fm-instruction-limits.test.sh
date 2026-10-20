#!/usr/bin/env bash
# Guards the verified harness limits on project instructions: the tracked
# AGENTS.md must fit the smallest limit Firstmate launches a harness with, or
# that harness silently drops the tail (sections 9-14 for Codex's 32768 default).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-instruction-limits-lib.sh
. "$ROOT/bin/fm-instruction-limits-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-instruction-limits)

test_tracked_agents_md_fits_the_recorded_limit() {
  local out status=0
  out=$(fm_instruction_limit_overrun "$ROOT/AGENTS.md") || status=$?
  [ "$status" = 1 ] || fail "AGENTS.md exceeds the recorded harness limit ($out); shrink it or route detail to a skill (see firstmate-coding-guidelines)"
  pass "tracked AGENTS.md fits the recorded harness instruction limit"
}

test_overrun_is_reported_only_past_the_limit() {
  local f="$TMP_ROOT/AGENTS.md" out
  head -c "$FM_INSTRUCTION_LIMIT_BYTES" /dev/zero | tr '\000' x > "$f"
  if fm_instruction_limit_overrun "$f" >/dev/null; then fail "a file exactly at the limit was reported"; fi
  printf 'x' >> "$f"
  out=$(fm_instruction_limit_overrun "$f") || fail "a file one byte over the limit was not reported"
  [ "$out" = "$((FM_INSTRUCTION_LIMIT_BYTES + 1)) $FM_INSTRUCTION_LIMIT_BYTES $FM_INSTRUCTION_LIMIT_OWNER" ] \
    || fail "unexpected overrun report: $out"
  if fm_instruction_limit_overrun "$TMP_ROOT/absent.md" >/dev/null; then fail "an absent file was reported"; fi
  pass "overrun is reported only for a file past the limit"
}

test_launch_limit_is_above_the_codex_default() {
  [ "$FM_CODEX_PROJECT_DOC_MAX_BYTES" -gt "$FM_CODEX_DEFAULT_PROJECT_DOC_MAX_BYTES" ] \
    || fail "the launch limit must raise codex's default"
  pass "the launch limit raises codex's default"
}

test_tracked_agents_md_fits_the_recorded_limit
test_overrun_is_reported_only_past_the_limit
test_launch_limit_is_above_the_codex_default
pass "fm-instruction-limits"
