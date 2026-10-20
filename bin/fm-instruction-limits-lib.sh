# shellcheck shell=bash
# Verified project-instruction size limits of the harnesses that load AGENTS.md.
# Usage: . bin/fm-instruction-limits-lib.sh
#
# ONE OWNER for the byte limits Firstmate knows about.  bin/fm-spawn.sh passes
# FM_CODEX_PROJECT_DOC_MAX_BYTES on every Codex launch it builds, and
# bin/fm-startup-growth-check.sh and tests/fm-instruction-limits.test.sh compare
# AGENTS.md against FM_INSTRUCTION_LIMIT_BYTES, so the launch and the guard cannot drift.
#
# Only limits actually verified are recorded here; do not add a harness without
# reproducing its truncation.
#   Codex (codex-cli 0.163.0): reads at most `project_doc_max_bytes` of project
#   instructions, default 32768, and silently drops the rest, so the 50015-byte
#   AGENTS.md ended mid-word in section 8.  `codex debug prompt-input "hi"` shows
#   the block cut by default and complete with -c project_doc_max_bytes=262144.

# shellcheck disable=SC2034 # recorded evidence, read by tests/fm-instruction-limits.test.sh
FM_CODEX_DEFAULT_PROJECT_DOC_MAX_BYTES=32768
# Raised ceiling Firstmate launches Codex with, so sections 9-14 and the precedence rule are not dropped.
FM_CODEX_PROJECT_DOC_MAX_BYTES=131072

# The smallest limit that still applies to a Firstmate-launched session.
FM_INSTRUCTION_LIMIT_BYTES=$FM_CODEX_PROJECT_DOC_MAX_BYTES
FM_INSTRUCTION_LIMIT_OWNER='codex project_doc_max_bytes'

# fm_instruction_limit_overrun <agents-md-path>: print "<bytes> <limit> <owner>"
# and return 0 when the file exceeds the limit; return 1 when it fits or is unreadable.
fm_instruction_limit_overrun() {
  local path=$1 bytes
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -gt "$FM_INSTRUCTION_LIMIT_BYTES" ] || return 1
  printf '%s %s %s\n' "$bytes" "$FM_INSTRUCTION_LIMIT_BYTES" "$FM_INSTRUCTION_LIMIT_OWNER"
}
