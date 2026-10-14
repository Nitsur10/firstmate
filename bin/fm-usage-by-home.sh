#!/usr/bin/env bash
# fm-usage-by-home.sh - which home and which task used each Claude account.
#
# Claude Code writes every interactive and print-mode session's steps, with
# their token usage, to <config-dir>/projects/<cwd>/<session>.jsonl. The login
# folder a transcript sits under is the account that paid for it, and its
# working directory says whose session it was. This script joins the two:
#
#   - A session in a task's working directory is that task's, by the
#     attribution records bin/fm-spawn.sh appends to each home's
#     state/usage-attribution.tsv before every launch (`record` below). A
#     worktree slot reused by a later task is told apart by launch time: a
#     step belongs to the latest launch recorded at or before it.
#   - Otherwise a session under a home's own root is that home's firstmate
#     session; an SDK entrypoint there is its supervision host.
#   - A no-mistakes validation session is credited to the task whose branch it
#     checks when the branch's last path segment is a recorded task id, and
#     otherwise to the home and project whose clone's `no-mistakes` remote
#     names the pipeline repository its working directory belongs to.
#   - Anything else is reported as (other) under its working directory.
#
# Homes are this home plus every local second mate registered in its
# data/secondmates.md; each home's own spawn records attribute its own workers.
# A remote second mate's transcripts stay on its host and are listed as not
# counted. Workers on other harnesses keep no Claude transcript.
#
# Cost is an approximate list price from the table in price() below, used only
# as a relative weight: it shows each home's and task's share of what the
# account spent, which is the best available proxy for its share of the
# account's usage limits. Unknown models count tokens but no cost.
#
# Usage:
#   fm-usage-by-home.sh [report] [--since <when>] [--config-dir <dir>]... [--tsv]
#       --since       7d (default), 36h, 90m, a YYYY-MM-DD date (UTC), or epoch seconds
#       --config-dir  a Claude login folder to scan, repeatable; default is
#                     ${CLAUDE_CONFIG_DIR:-~/.claude}, ~/.claude, and every
#                     folder a spawn record names
#       --tsv         one row per login folder, home, and task, tab-separated:
#                     config_dir account_now home task steps input cache_write
#                     cache_read output usd
#   fm-usage-by-home.sh record <task> <kind> <harness> <cwd> [<claude-config-dir>]
#       Append one attribution record to state/usage-attribution.tsv (called
#       by bin/fm-spawn.sh). Record format, tab-separated:
#       epoch task kind harness cwd physical-cwd claude-config-dir account
#       where account is the Claude login folder's signed-in email at launch.
#
# Accounts: a login folder's account is read when the report runs, so rows are
# grouped by folder and labelled with the account signed in now; when a launch
# recorded a different account for that folder inside the window, the report
# says so, because the folder's earlier transcripts may belong to it.
#
# Bounds: only transcript files modified inside the window are read, steps are
# filtered by their own timestamps, each API message is counted once even when
# a resumed or forked session repeats it, and the whole report stops after
# FM_USAGE_TIMEOUT seconds (default 120). It runs only when invoked; no hook,
# watcher, or spawn waits on it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORDS_NAME=usage-attribution.tsv
SCAN_TIMEOUT=${FM_USAGE_TIMEOUT:-120}
case "$SCAN_TIMEOUT" in ''|*[!0-9]*|0) SCAN_TIMEOUT=120 ;; esac

usage() {
  sed -n '/^# Usage:/,/^# Accounts:/{/^# Accounts:/d;s/^# \{0,1\}//;p;}' "$0"
}

die() { echo "fm-usage-by-home: $1" >&2; exit "${2:-1}"; }

# --- record -----------------------------------------------------------------
# The account a login folder is signed in to now, or "unknown". The default
# folder keeps its account record beside it in ~/.claude.json.
account_of() {  # <config-dir>
  local dir=$1 file email
  if [ "$dir" = "$HOME/.claude" ]; then
    file=$HOME/.claude.json
  else
    file=$dir/.claude.json
  fi
  email=$(jq -r '.oauthAccount.emailAddress // empty' "$file" 2>/dev/null)
  printf '%s\n' "${email:-unknown}"
}

cmd_record() {
  local task=${1:-} kind=${2:-} harness=${3:-} cwd=${4:-} config_dir=${5:-} phys field account
  [ "$#" -ge 4 ] && [ "$#" -le 5 ] || die "usage: fm-usage-by-home.sh record <task> <kind> <harness> <cwd> [<claude-config-dir>]" 2
  for field in "$task" "$kind" "$harness" "$cwd" "$config_dir"; do
    case "$field" in *$'\t'*|*$'\n'*|*$'\r'*) die "record fields must not contain tabs or newlines" 2 ;; esac
  done
  [ -n "$task" ] && [ -n "$cwd" ] || die "record needs a task and a working directory" 2
  phys=$(cd "$cwd" 2>/dev/null && pwd -P) || phys=$cwd
  [ -d "$STATE" ] || die "state directory $STATE does not exist"
  account=
  [ "$harness" != claude ] || account=$(account_of "${config_dir:-$HOME/.claude}")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$task" "$kind" "$harness" "$cwd" "$phys" "$config_dir" "$account" \
    >> "$STATE/$RECORDS_NAME" || die "cannot append to $STATE/$RECORDS_NAME"
}

# --- report -----------------------------------------------------------------
# Print the window start as epoch seconds.
parse_since() {  # <when>
  local when=$1 n now
  now=$(date +%s)
  case "$when" in
    [0-9]*d) n=${when%d}; case "$n" in *[!0-9]*) return 1 ;; esac; echo $((now - 10#$n * 86400)) ;;
    [0-9]*h) n=${when%h}; case "$n" in *[!0-9]*) return 1 ;; esac; echo $((now - 10#$n * 3600)) ;;
    [0-9]*m) n=${when%m}; case "$n" in *[!0-9]*) return 1 ;; esac; echo $((now - 10#$n * 60)) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      date -u -j -f '%Y-%m-%d %H:%M:%S' "$when 00:00:00" +%s 2>/dev/null \
        || date -u -d "$when" +%s 2>/dev/null || return 1 ;;
    *[!0-9]*|'') return 1 ;;
    *) echo "$((10#$when))" ;;
  esac
}

iso_utc() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# Print "label<TAB>path<TAB>remote-host" for this home and each registered
# second mate.
list_homes() {
  local label line
  if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
    label=$(head -n 1 "$FM_HOME/.fm-secondmate-home" 2>/dev/null | tr -d '[:space:]')
    [ -n "$label" ] || label=home
  else
    label=main
  fi
  printf '%s\t%s\t\n' "$label" "$(cd "$FM_HOME" && pwd -P)"
  [ -f "$DATA/secondmates.md" ] || return 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    [ -n "$SECONDMATE_REGISTRY_ID" ] || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      printf '%s\t%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_HOST"
    else
      printf '%s\t%s\t\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
    fi
  done < "$DATA/secondmates.md"
}

# Emit one tab-separated line per assistant step in <config-dir> since the
# window start: config_dir msg_id epoch cwd branch entrypoint model input
# write_5m write_1h cache_read output.
scan_dir() {  # <config-dir> <since-epoch> <since-iso> <minutes>
  local dir=$1 since=$2 since_iso=$3 minutes=$4
  [ -d "$dir/projects" ] || return 0
  find "$dir/projects" -type f -name '*.jsonl' -mmin "-$minutes" -print0 2>/dev/null \
    | xargs -0 grep -h -F '"type":"assistant"' 2>/dev/null \
    | jq -R -r --arg dir "$dir" --arg since "$since_iso" --argjson since_epoch "$since" '
        fromjson?
        | select(type == "object" and .type == "assistant"
                 and (.message.usage | type) == "object"
                 and (.message.model // "") != "<synthetic>"
                 and (.timestamp // "") >= $since)
        | (.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
        | select($t >= $since_epoch)
        | .message.usage as $u
        | ($u.cache_creation.ephemeral_5m_input_tokens // 0) as $w5
        | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1
        | (if ($w5 + $w1) == 0 then ($u.cache_creation_input_tokens // 0) else $w5 end) as $w5b
        | [$dir, (.message.id // .uuid // ""), $t, (.cwd // ""), (.gitBranch // ""),
           (.entrypoint // ""), (.message.model // ""), ($u.input_tokens // 0), $w5b, $w1,
           ($u.cache_read_input_tokens // 0), ($u.output_tokens // 0)]
        | map(tostring | gsub("\t"; " ")) | @tsv' 2>/dev/null
}

cmd_report() {
  local since_arg=7d tsv=0 since since_iso minutes now dir homes_file records_file steps_file
  local label path host records count clone url acct
  local -a dirs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) [ "$#" -ge 2 ] || die "--since needs a value" 2; since_arg=$2; shift 2 ;;
      --since=*) since_arg=${1#--since=}; shift ;;
      --config-dir) [ "$#" -ge 2 ] || die "--config-dir needs a value" 2; dirs+=("$2"); shift 2 ;;
      --config-dir=*) dirs+=("${1#--config-dir=}"); shift ;;
      --tsv) tsv=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq is required"
  since=$(parse_since "$since_arg") || die "--since '$since_arg' is not 7d, 36h, 90m, YYYY-MM-DD, or epoch seconds" 2
  now=$(date +%s)
  [ "$since" -lt "$now" ] || die "--since '$since_arg' is not in the past" 2
  since_iso=$(iso_utc "$since")
  minutes=$(( (now - since) / 60 + 2 ))

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-usage-by-home.XXXXXX") || die "cannot create a temporary directory"
  trap 'rm -rf "$work"' EXIT
  trap 'rm -rf "$work"; exit 143' TERM
  trap 'rm -rf "$work"; exit 130' INT
  homes_file=$work/homes
  records_file=$work/records
  steps_file=$work/steps
  : > "$records_file"
  list_homes > "$homes_file"
  while IFS=$'\t' read -r label path host; do
    [ -z "$host" ] || continue
    records=$path/state/$RECORDS_NAME
    [ "$path" != "$(cd "$FM_HOME" && pwd -P)" ] || records=$STATE/$RECORDS_NAME
    [ -f "$records" ] || continue
    awk -F'\t' -v OFS='\t' -v home="$label" 'NF >= 6 { print home, $0 }' "$records" >> "$records_file"
  done < "$homes_file"

  # Pipeline repository -> home and project, from each local clone's
  # no-mistakes remote (.../repos/<hash>.git).
  : > "$work/pipelines"
  while IFS=$'\t' read -r label path host; do
    [ -z "$host" ] || continue
    for clone in "$path"/projects/*; do
      [ -e "$clone/.git" ] || continue
      url=$(git -C "$clone" config remote.no-mistakes.url 2>/dev/null) || continue
      url=${url%.git}
      printf '%s\t%s\t%s\n' "${url##*/}" "$label" "${clone##*/}" >> "$work/pipelines"
    done
  done < "$homes_file"

  if [ "${#dirs[@]}" -eq 0 ]; then
    dirs+=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude")
    while IFS=$'\t' read -r dir; do
      [ -n "$dir" ] && dirs+=("$dir")
    done < <(awk -F'\t' '$5 == "claude" && $8 != "" { print $8 }' "$records_file" | sort -u)
  fi
  # Absolute, existing, de-duplicated login folders.
  count=0
  : > "$work/dirs"
  for dir in "${dirs[@]}"; do
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    grep -qxF "$dir" "$work/dirs" 2>/dev/null && continue
    printf '%s\n' "$dir" >> "$work/dirs"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "no Claude login folder found to scan"

  : > "$steps_file"
  while IFS= read -r dir; do
    scan_dir "$dir" "$since" "$since_iso" "$minutes" >> "$steps_file"
  done < "$work/dirs"

  : > "$work/accounts"
  while IFS= read -r dir; do
    printf '%s\t%s\n' "$dir" "$(account_of "$dir")" >> "$work/accounts"
  done < "$work/dirs"
  # Accounts launches recorded for each folder inside the window.
  : > "$work/launch-accounts"
  # The account comes first because tab is IFS whitespace: an empty leading
  # folder field (the default login folder) would otherwise shift the fields.
  while IFS=$'\t' read -r acct dir; do
    dir=$(cd "${dir:-$HOME/.claude}" 2>/dev/null && pwd -P) || continue
    printf '%s\t%s\n' "$dir" "$acct" >> "$work/launch-accounts"
  done < <(awk -F'\t' -v since="$since" '$5 == "claude" && $2 + 0 >= since && $9 != "" { print $9 "\t" $8 }' "$records_file" | sort -u)

  awk -F'\t' -v OFS='\t' \
    -v homes="$homes_file" -v records="$records_file" -v accounts="$work/accounts" \
    -v pipelines="$work/pipelines" -v launch_accounts="$work/launch-accounts" \
    -v home_dir="$HOME" -v tsv="$tsv" -v since_iso="$since_iso" -v since_arg="$since_arg" '
    function price(model, kind,    p, pa) {
      # US$ per million tokens: input, 5-minute cache write, 1-hour cache
      # write, cache read, output (Anthropic list prices, checked 2026-10-04).
      if (model ~ /opus-5-5|opus-5\.5/) p = "4 5 8 0.20 20"
      else if (model ~ /sonnet-5-5|sonnet-5\.5/) p = "2 2.5 4 0.20 10"
      else if (model ~ /haiku-4-5|haiku-4\.5/) p = "1 1.25 2 0.10 5"
      else if (model ~ /fable-5-1|fable-5\.1/) p = "10 12.5 20 0.25 50"
      else if (model ~ /opus-5($|[^-.0-9])/) p = "5 6.25 10 0.50 25"
      else return -1
      split(p, pa, " ")
      return pa[kind]
    }
    function under(cwd, root) {
      return root != "" && (cwd == root || index(cwd, root "/") == 1)
    }
    function tilde(p) {
      if (index(p, home_dir "/") == 1) return "~" substr(p, length(home_dir) + 1)
      return p
    }
    function commas(n,    s, neg) {
      s = sprintf("%.0f", n); neg = ""
      if (substr(s, 1, 1) == "-") { neg = "-"; s = substr(s, 2) }
      while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", s)
      return neg s
    }
    BEGIN {
      while ((getline line < homes) > 0) {
        split(line, h, "\t")
        nh++; hlabel[nh] = h[1]; hpath[nh] = h[2]; hhost[nh] = h[3]
      }
      while ((getline line < records) > 0) {
        split(line, r, "\t")
        if (!(r[3] in task_home) || r[2] + 0 >= task_epoch[r[3]]) {
          task_home[r[3]] = r[1]; task_epoch[r[3]] = r[2] + 0
        }
        # A second mate launch names the home of that mate, which the home
        # roots below already attribute to the mate itself.
        if (r[4] == "secondmate") continue
        nr++; rhome[nr] = r[1]; repoch[nr] = r[2] + 0; rtask[nr] = r[3]
        rcwd[nr] = r[6]; rphys[nr] = r[7]
      }
      while ((getline line < pipelines) > 0) {
        split(line, pl, "\t")
        if (!(pl[1] in pipe_home)) { pipe_home[pl[1]] = pl[2]; pipe_project[pl[1]] = pl[3] }
        else if (pipe_home[pl[1]] != pl[2]) pipe_home[pl[1]] = "(PR checks)"
      }
      while ((getline line < accounts) > 0) {
        split(line, ac, "\t"); account[ac[1]] = ac[2]
      }
      while ((getline line < launch_accounts) > 0) {
        split(line, la, "\t")
        if (la[2] != account[la[1]] && index(other_accounts[la[1]], " " la[2] " ") == 0)
          other_accounts[la[1]] = other_accounts[la[1]] " " la[2] " "
      }
    }
    {
      dir = $1; id = $2; t = $3 + 0; cwd = $4; branch = $5; entry = $6; model = $7
      if (id != "" && (id in seen)) next
      if (id != "") seen[id] = 1
      home = ""; task = ""
      # Records whose working directory contains that of this step, found once per
      # distinct directory: "index:matched-length" pairs.
      if (!(cwd in cand)) {
        c = ""
        for (i = 1; i <= nr; i++) {
          len = 0
          if (under(cwd, rcwd[i])) len = length(rcwd[i])
          if (under(cwd, rphys[i]) && length(rphys[i]) > len) len = length(rphys[i])
          if (len > 0) c = c " " i ":" len
        }
        cand[cwd] = c
      }
      nc = split(cand[cwd], cl, " ")
      bestlen = 0; bestepoch = -1
      for (ci = 1; ci <= nc; ci++) {
        split(cl[ci], cp, ":"); i = cp[1] + 0; len = cp[2] + 0
        if (repoch[i] > t) continue
        if (len > bestlen || (len == bestlen && repoch[i] > bestepoch)) {
          bestlen = len; bestepoch = repoch[i]; home = rhome[i]; task = rtask[i]
        }
      }
      if (home == "") {
        best = 0
        for (i = 1; i <= nh; i++) {
          if (hhost[i] == "" && under(cwd, hpath[i]) && length(hpath[i]) > best) {
            best = length(hpath[i]); home = hlabel[i]
            task = (entry ~ /^sdk/) ? "(supervision host)" : "(firstmate)"
          }
        }
      }
      if (home == "" && cwd ~ /\/\.no-mistakes\//) {
        bt = branch; sub(/.*\//, "", bt)
        repo = cwd; sub(/.*\/\.no-mistakes\/worktrees\//, "", repo); sub(/\/.*/, "", repo)
        if (bt != "" && bt != "HEAD" && (bt in task_home)) { home = task_home[bt]; task = bt " (PR checks)" }
        else if (repo in pipe_home) { home = pipe_home[repo]; task = pipe_project[repo] " (PR checks)" }
        else { home = "(PR checks)"; task = "pipeline " repo }
      }
      if (home == "") { home = "(other)"; task = (cwd == "" ? "?" : tilde(cwd)) }

      inp = $8 + 0; w5 = $9 + 0; w1 = $10 + 0; cr = $11 + 0; out = $12 + 0
      p1 = price(model, 1)
      if (p1 < 0) { usd = 0; unpriced[model] = 1 }
      else usd = (inp * p1 + w5 * price(model, 2) + w1 * price(model, 3) + cr * price(model, 4) + out * price(model, 5)) / 1000000
      k = dir SUBSEP home SUBSEP task
      if (!(k in steps)) { nk++; keys[nk] = k }
      steps[k]++; in_t[k] += inp; cw_t[k] += w5 + w1; cr_t[k] += cr; out_t[k] += out; usd_t[k] += usd
      hk = dir SUBSEP home
      if (!(hk in hsteps)) { nhk++; hkeys[nhk] = hk }
      hsteps[hk]++; husd[hk] += usd; hout[hk] += out; hcr[hk] += cr
      dsteps[dir]++; dusd[dir] += usd
    }
    END {
      if (tsv == 1) {
        print "config_dir", "account_now", "home", "task", "steps", "input", "cache_write", "cache_read", "output", "usd"
        for (i = 1; i <= nk; i++) {
          split(keys[i], kk, SUBSEP)
          printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%.2f\n", kk[1], account[kk[1]], kk[2], kk[3], steps[keys[i]], in_t[keys[i]], cw_t[keys[i]], cr_t[keys[i]], out_t[keys[i]], usd_t[keys[i]]
        }
        exit
      }
      printf "Claude usage by home and task since %s (%s), from session transcripts.\n", since_iso, since_arg
      printf "Cost is approximate list price, used as each row'"'"'s share of what the account spent.\n"
      ndirs = 0
      for (i = 1; i <= nhk; i++) {
        split(hkeys[i], kk, SUBSEP)
        if (!(kk[1] in dir_seen)) { dir_seen[kk[1]] = 1; ndirs++; dir_order[ndirs] = kk[1] }
      }
      if (ndirs == 0) printf "\nNo Claude steps found in the window.\n"
      for (d = 1; d <= ndirs; d++) {
        dir = dir_order[d]
        printf "\n%s (signed in now as %s): %s steps, ~US$%.2f\n", tilde(dir), account[dir], commas(dsteps[dir]), dusd[dir]
        if (other_accounts[dir] != "") {
          oa = other_accounts[dir]; gsub(/^ +| +$/, "", oa); gsub(/  +/, ", ", oa)
          printf "  Launches in this window also recorded this folder signed in as %s; its rows may mix accounts.\n", oa
        }
        printf "  %-14s %-36s %8s %10s %12s %10s %6s\n", "home", "task", "steps", "output", "cache-read", "~US$", "share"
        # Homes by cost, each followed by its tasks by cost.
        nhd = 0
        for (i = 1; i <= nhk; i++) { split(hkeys[i], kk, SUBSEP); if (kk[1] == dir) { nhd++; hd[nhd] = hkeys[i] } }
        for (i = 1; i <= nhd; i++) for (j = i + 1; j <= nhd; j++) if (husd[hd[j]] > husd[hd[i]]) { tmp = hd[i]; hd[i] = hd[j]; hd[j] = tmp }
        for (i = 1; i <= nhd; i++) {
          split(hd[i], kk, SUBSEP); home = kk[2]
          share = (dusd[dir] > 0) ? 100 * husd[hd[i]] / dusd[dir] : 0
          printf "  %-14s %-36s %8s %10s %12s %10.2f %5.1f%%\n", substr(home, 1, 14), "(all)", commas(hsteps[hd[i]]), commas(hout[hd[i]]), commas(hcr[hd[i]]), husd[hd[i]], share
          nt = 0
          for (j = 1; j <= nk; j++) { split(keys[j], tk, SUBSEP); if (tk[1] == dir && tk[2] == home) { nt++; td[nt] = keys[j] } }
          for (ti = 1; ti <= nt; ti++) for (tj = ti + 1; tj <= nt; tj++) if (usd_t[td[tj]] > usd_t[td[ti]]) { tmp = td[ti]; td[ti] = td[tj]; td[tj] = tmp }
          for (ti = 1; ti <= nt; ti++) {
            split(td[ti], tk, SUBSEP)
            share = (dusd[dir] > 0) ? 100 * usd_t[td[ti]] / dusd[dir] : 0
            printf "  %-14s %-36s %8s %10s %12s %10.2f %5.1f%%\n", "", substr(tk[3], 1, 36), commas(steps[td[ti]]), commas(out_t[td[ti]]), commas(cr_t[td[ti]]), usd_t[td[ti]], share
          }
        }
      }
      for (i = 1; i <= nh; i++) if (hhost[i] != "") printf "\nNot counted: second mate %s runs on %s; its transcripts stay there.\n", hlabel[i], hhost[i]
      for (m in unpriced) printf "Unpriced model (tokens counted, no cost): %s\n", m
    }' "$steps_file"
}

# Run the report under one hard bound covering every step of it.
cmd_report_bounded() {
  local rc
  [ "${FM_USAGE_INNER:-}" != 1 ] || { cmd_report "$@"; return; }
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fm_run_timed "$SCAN_TIMEOUT" env FM_USAGE_INNER=1 "$0" report "$@"
  rc=$?
  if fm_timed_out "$rc"; then
    die "the report took longer than ${SCAN_TIMEOUT}s; narrow --since or raise FM_USAGE_TIMEOUT"
  fi
  return "$rc"
}

case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  report) shift; cmd_report_bounded "$@" ;;
  -h|--help|help) usage ;;
  *) cmd_report_bounded "$@" ;;
esac
