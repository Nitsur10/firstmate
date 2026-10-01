#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds. It also owns the opt-in Claude
# account pool (config/claude-accounts, section below), which chooses one
# pooled login per launch and applies it exactly as a pin.
#
# docs/configuration.md "Worker account pin" and "Claude account pool" own the
# operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary` or the absolute path and providers is empty for Claude. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
      print $1, "\t";
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_resolve <harness> <config-dir>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 file cfg token rc declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  declared=${token%%$'\t'*}
  root=$declared
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_clean_env <variable> <root>
# Sets FM_WORKER_ACCOUNT_ENV to the `env -i` prefix every account probe runs
# under: HOME, PATH, TMPDIR, USER, LOGNAME, and <variable>=<root> when root is
# non-empty, so a credential left in the caller cannot answer for a root.
fm_worker_account_clean_env() {
  local name
  FM_WORKER_ACCOUNT_ENV=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || FM_WORKER_ACCOUNT_ENV+=("$name=${!name}")
  done
  [ -z "$2" ] || FM_WORKER_ACCOUNT_ENV+=("$1=$2")
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict
  local -a clean
  case "$harness" in
  claude)
    fm_worker_account_clean_env CLAUDE_CONFIG_DIR "$root"
    clean=("${FM_WORKER_ACCOUNT_ENV[@]}")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    fm_worker_account_clean_env PI_CODING_AGENT_DIR "$root"
    clean=("${FM_WORKER_ACCOUNT_ENV[@]}")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_raw_guard <raw-command> <file>
# Refuses a raw Claude launch command whose leading assignments would override
# the account <file> selects: CLAUDE_CONFIG_DIR or a shed credential.
fm_worker_account_raw_guard() {
  local word
  for word in $1; do
    case "$word" in
    [A-Za-z_]*=*)
      case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
      *" ${word%%=*} "*)
        echo "error: config/$2 selects the Claude worker account, but the raw launch command sets ${word%%=*}, which would override it; remove ${word%%=*} from the raw command, or change or remove config/$2" >&2
        return 1
        ;;
      esac
      ;;
    *) break ;;
    esac
  done
}

# fm_worker_account_select <harness> <config-dir> <model> <executable>
#   [<raw-command> [<kind> [<override> [<prior>]]]]
# The whole launch-time decision. Prints nothing when neither a pin nor a
# Claude pool applies, so the caller keeps today's launch unchanged. Otherwise
# prints "declared<TAB>root<TAB>provider<TAB>email": provider is the Pi launch
# model's own (empty for Claude) and email is the verified login a pool launch
# chose (empty for a pin). <kind> is the task kind, <override> a per-launch
# --account value, and <prior> the account= a relaunched task recorded. On
# refusal prints one error and returns 1. bin/fm-spawn.sh runs it before any
# endpoint exists, and bin/fm-control.sh before a relaunch stops the live
# agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} kind=${6:-} override=${7:-} prior=${8:-}
  local selection declared root providers rc provider=
  selection=$(fm_worker_account_resolve "$harness" "$config") || return 1
  if [ -z "$selection" ]; then
    if [ "$harness" != claude ]; then
      [ -z "$override" ] || {
        echo "error: --account chooses among the Claude accounts in config/claude-accounts and applies only to Claude launches, not '$harness'" >&2
        return 1
      }
      return 0
    fi
    fm_worker_account_pool_select "$config" "$executable" "$raw" "$kind" "$override" "$prior"
    rc=$?
    [ "$rc" -ne 3 ] || rc=0
    return "$rc"
  fi
  [ -z "$override" ] || {
    echo "error: config/$(fm_worker_account_file "$harness") pins every $harness launch from this home, so --account cannot choose another; change or remove the pin instead" >&2
    return 1
  }
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    fm_worker_account_raw_guard "$raw" claude-account || return 1
  else
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\t\n' "$declared" "$root" "$provider"
}

# --- Claude account pool (config/claude-accounts) ---------------------------
#
# An opt-in pool of Claude logins a home's workers rotate across, one choice
# per launch; docs/configuration.md "Claude account pool" owns the operator
# contract. The single-account pin above wins whenever it is present. The file
# holds key=value lines, with blank lines and #-comments allowed:
#   account=<ordinary|/absolute/root>   one per pooled login, at least one
#   pages=<one of the accounts>         optional: the account that owns pages
#   reserve=<0-100>                     weekly percent kept on pages (default 20)
# Each member is probed in the same cleared environment as the pin check:
# `claude auth status --json` names its signed-in email, and one bounded
# `quota-axi --provider claude --no-credential-refresh --max-age 5m --full
# --json` reads its windows from the root's own Keychain entry (never
# --profile-only, which reads only a credentials file that macOS logins do not
# have). A member is skipped, with a note, when its root is unusable, it is
# signed out or names no email, its email repeats an earlier member's, its
# quota reading names a different account, or a reading shows it exhausted,
# under the five-hour guard (15 percent) or the weekly floor (10 percent), or
# (the pages account) under reserve. A member whose quota cannot be read is not
# eligible either, and is reported; when no signed-in member can be read at all
# the launch falls back to the ordinary default login exactly as without a
# pool, never to the pages account on a guess. Eligible members rank by
# quota-axi's all_models spendPriority, then weekly percent left, then file
# order. A relaunch stays on its recorded account while that account remains
# eligible. A secondmate or raw Claude launch takes the pages account when one
# is declared, with only the sign-in check, as a pin would. --account names a
# member by its root or its signed-in email and skips the quota gates, never
# the sign-in check. Only when every member is skipped does the launch refuse.

FM_WORKER_ACCOUNT_QUOTA_SECONDS=${FM_WORKER_ACCOUNT_QUOTA_SECONDS:-20}
FM_WORKER_ACCOUNT_POOL_FLOOR=10
FM_WORKER_ACCOUNT_POOL_FIVE_HOUR_GUARD=15

# fm_worker_account_pool_read <file>
# Prints the pool as "key<TAB>value" lines: one `account` line per member in
# file order, then `pages` (empty when undeclared) and `reserve` with its
# default applied. Returns 3 when the file does not
# exist, 4 when it cannot be inspected, 5 when it is not a readable regular
# file, and 6 when it is malformed; 4 and 6 print one error.
fm_worker_account_pool_read() {
  perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    sub bad { print STDERR "error: config/claude-accounts $_[0]: $f\n"; exit 6 }
    bad("must not contain control characters other than newlines") if $body =~ /[\x00-\x09\x0b-\x1f\x7f]/;
    my (@acct, %seen, %one);
    my $reserve = 20;
    my $pages = "";
    my $n = 0;
    for my $line (split /\n/, $body) {
      $n++;
      next if $line =~ /\A\s*(?:#.*)?\z/;
      my ($k, $v) = $line =~ /\A(account|pages|reserve)=(.*)\z/
        or bad("line $n must be account=, pages=, or reserve=");
      if ($k eq "account" or $k eq "pages") {
        $v =~ m{\A(?:ordinary|/.*)\z} or bad("line $n must name ordinary or one absolute path");
      }
      if ($k eq "account") {
        bad("line $n repeats account $v") if $seen{$v}++;
        push @acct, $v;
        next;
      }
      bad("line $n repeats $k=") if $one{$k}++;
      if ($k eq "pages") { $pages = $v; next }
      ($v =~ /\A(?:100|[1-9]?[0-9])\z/) or bad("line $n needs $k= a whole percent from 0 to 100");
      $reserve = $v;
    }
    bad("must name at least one account=") unless @acct;
    bad("pages=$pages must also be listed as an account=") if $pages ne "" && !$seen{$pages};
    print "account\t$_\n" for @acct;
    print "pages\t$pages\n";
    print "reserve\t$reserve\n";
  ' -- "$1"
}

# fm_worker_account_root <declared>
# Prints the CLAUDE_CONFIG_DIR a declared account selects: empty for ordinary.
fm_worker_account_root() {
  [ "$1" = ordinary ] || printf '%s\n' "$1"
}

# fm_worker_account_claude_email <executable> <declared>
# Prints the signed-in email the account's own `claude auth status --json`
# reports, lowercased. Returns 1 with the reason on stdout when the root is
# unusable, signed out, or names no email.
fm_worker_account_claude_email() {
  local executable=$1 declared=$2 root out email
  root=$(fm_worker_account_root "$declared")
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "not a readable, searchable directory"
    return 1
  fi
  fm_worker_account_clean_env CLAUDE_CONFIG_DIR "$root"
  out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${FM_WORKER_ACCOUNT_ENV[@]}" \
    "$executable" auth status --json 2>/dev/null </dev/null) || {
    echo "not signed in (claude auth status)"
    return 1
  }
  email=$(printf '%s\n' "$out" | jq -r '
    if type == "object" and .loggedIn == true and (.email | type) == "string" then .email | ascii_downcase else empty end' 2>/dev/null)
  [ -n "$email" ] || {
    echo "signed in without a verifiable email (claude auth status)"
    return 1
  }
  printf '%s\n' "$email"
}

# fm_worker_account_claude_quota <declared> <email> <reserve>
# Prints one verdict line for the account's live quota: "ok<TAB>spendPriority
# <TAB>weekly<TAB>summary" (spendPriority and weekly may be empty), "unknown
# <TAB>reason", or "skip<TAB>reason". <reserve> is -1 for every account but
# the pages account.
fm_worker_account_claude_quota() {
  local declared=$1 email=$2 reserve=$3 out rc
  fm_worker_account_clean_env CLAUDE_CONFIG_DIR "$(fm_worker_account_root "$declared")"
  out=$(fm_run_timed "$FM_WORKER_ACCOUNT_QUOTA_SECONDS" "${FM_WORKER_ACCOUNT_ENV[@]}" \
    quota-axi --provider claude --no-credential-refresh --max-age 5m --full --json 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      printf 'unknown\tquota read timed out after %ss\n' "$FM_WORKER_ACCOUNT_QUOTA_SECONDS"
    else
      printf 'unknown\tquota read failed (quota-axi exit %s)\n' "$rc"
    fi
    return 0
  fi
  printf '%s\n' "$out" | jq -r --arg email "$email" --argjson floor "$FM_WORKER_ACCOUNT_POOL_FLOOR" \
    --argjson five "$FM_WORKER_ACCOUNT_POOL_FIVE_HOUR_GUARD" --argjson reserve "$reserve" '
    ([.providers[]? | select(.provider == "claude")] | first) as $p |
    (($p.account.email // "") | ascii_downcase) as $qe |
    if $p == null then "unknown\tquota reading has no claude row"
    elif $qe == "" then "unknown\tquota reading names no account"
    elif $qe != $email then "skip\tquota reading names \($qe), not \($email)"
    elif (($p.windows // []) | length) == 0 then "unknown\tquota \($p.state.status // "unavailable")"
    else
      ([$p.windows[] | select(.id == "five_hour") | .percentRemaining] | first) as $f |
      ([$p.windows[] | select(.id == "seven_day") | .percentRemaining] | first) as $w |
      ([$p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")] | first) as $all |
      "weekly \($w // "?")% left, five-hour \($f // "?")% left" as $summary |
      if ($all.runway.status // "") == "exhausted_now" then "skip\texhausted now (\($summary))"
      elif $f != null and $f < $five then "skip\tfive-hour window \($f)% left, under the \($five)% guard"
      elif $w != null and $w < $floor then "skip\tweekly \($w)% left, under the \($floor)% floor"
      elif $reserve >= 0 and $w != null and $w < $reserve then "skip\tweekly \($w)% left, inside the \($reserve)% pages-account reserve"
      else "ok\t\(if $all.selection.status == "known" then $all.selection.spendPriority // "" else "" end)\t\($w // "")\t\($summary)"
      end
    end' 2>/dev/null || printf 'unknown\tquota reading is not valid JSON\n'
}

# fm_worker_account_pool_select <config-dir> <executable> <raw> <kind> <override> <prior>
# The pool half of fm_worker_account_select, with the same output. Returns 3,
# printing nothing, when the home has no pool and no override was asked for.
fm_worker_account_pool_select() {
  local config=$1 executable=$2 raw=$3 kind=$4 asked=$5 prior=$6 override
  local file="$config/claude-accounts" pool rc key value reserve pages=
  local i member email verdict status rest reason summary best priority weekly chosen='' chosen_email=
  local -a members=() emails=() skipped=() ranked=()
  local unread=0 refused=0
  pool=$(fm_worker_account_pool_read "$file")
  rc=$?
  case "$rc" in
  0) ;;
  3)
    [ -z "$asked" ] || {
      echo "error: --account chooses among the accounts in config/claude-accounts, and this home has no such file" >&2
      return 1
    }
    return 3
    ;;
  5)
    echo "error: config/claude-accounts must be a readable regular file: $file" >&2
    return 1
    ;;
  *) return 1 ;;
  esac
  while IFS=$'\t' read -r key value; do
    case "$key" in
    account) members+=("$value") ;;
    pages) pages=$value ;;
    reserve) reserve=$value ;;
    esac
  done <<<"$pool"
  fm_worker_account_raw_guard "$raw" claude-accounts || return 1

  # A named override or a fixed launch takes one account with only the
  # sign-in check, and refuses rather than moving elsewhere.
  if [ -n "$asked" ]; then
    override=$(printf '%s' "$asked" | tr '[:upper:]' '[:lower:]')
    for member in "${members[@]}"; do
      [ "$member" != "$asked" ] || { chosen=$member; break; }
    done
    if [ -z "$chosen" ] && [[ "$override" == *@* ]]; then
      for member in "${members[@]}"; do
        email=$(fm_worker_account_claude_email "$executable" "$member") || continue
        [ "$email" = "$override" ] && chosen=$member && break
      done
    fi
    [ -n "$chosen" ] || {
      echo "error: --account '$asked' names no signed-in account in config/claude-accounts; name one of its account= roots or its signed-in email" >&2
      return 1
    }
    reason="named by --account"
  elif [ -n "$pages" ] && { [ "$kind" = secondmate ] || [ -n "$raw" ]; }; then
    chosen=$pages
    reason="the pages account takes every secondmate and raw launch"
  fi
  if [ -n "$chosen" ]; then
    chosen_email=$(fm_worker_account_claude_email "$executable" "$chosen") || {
      echo "error: config/claude-accounts account $chosen is $chosen_email; sign in with $( [ "$chosen" = ordinary ] && echo 'env -u CLAUDE_CONFIG_DIR claude' || echo "CLAUDE_CONFIG_DIR=$chosen claude"), then /login, or choose another account" >&2
      return 1
    }
    echo "note: Claude account pool chose $chosen ($chosen_email): $reason" >&2
    printf '%s\t%s\t\t%s\n' "$chosen" "$(fm_worker_account_root "$chosen")" "$chosen_email"
    return 0
  fi

  # A relaunch keeps its recorded account while that account stays eligible,
  # so only a launch that must move pays for reading every member.
  if [ -n "$prior" ]; then
    for member in "${members[@]}"; do
      [ "$member" = "$prior" ] || continue
      if email=$(fm_worker_account_claude_email "$executable" "$member"); then
        value=-1
        [ "$member" != "$pages" ] || value=$reserve
        verdict=$(fm_worker_account_claude_quota "$member" "$email" "$value")
        status=${verdict%%$'\t'*}
        if [ "$status" = ok ]; then
          echo "note: Claude account pool kept $member ($email) for this relaunch: ${verdict##*$'\t'}" >&2
          printf '%s\t%s\t\t%s\n' "$member" "$(fm_worker_account_root "$member")" "$email"
          return 0
        fi
        echo "note: Claude account pool is moving this relaunch off $member ($email): ${verdict#*$'\t'}" >&2
      else
        echo "note: Claude account pool is moving this relaunch off $member: $email" >&2
      fi
    done
  fi

  i=0
  for member in "${members[@]}"; do
    i=$((i + 1))
    if ! email=$(fm_worker_account_claude_email "$executable" "$member"); then
      skipped+=("$member: $email")
      continue
    fi
    for value in ${emails[@]+"${emails[@]}"}; do
      [ "${value#*$'\t'}" != "$email" ] || {
        skipped+=("$member ($email): the same login as ${value%%$'\t'*}, counted once")
        continue 2
      }
    done
    emails+=("$member"$'\t'"$email")
    value=-1
    [ "$member" != "$pages" ] || value=$reserve
    verdict=$(fm_worker_account_claude_quota "$member" "$email" "$value")
    status=${verdict%%$'\t'*}
    rest=${verdict#*$'\t'}
    case "$status" in
    ok)
      # rank<TAB>weekly<TAB>order<TAB>member<TAB>email<TAB>summary, where a
      # member without a spendPriority or weekly reading sorts after any with one.
      priority=${rest%%$'\t'*}
      weekly=$(printf '%s' "$rest" | cut -f2)
      summary=${rest##*$'\t'}
      [ -z "$priority" ] || summary="$summary, spendPriority $priority"
      ranked+=("${priority:--1e308}"$'\t'"${weekly:--1}"$'\t'"$i"$'\t'"$member"$'\t'"$email"$'\t'"$summary")
      ;;
    unknown)
      unread=$((unread + 1))
      skipped+=("$member ($email): not eligible, $rest")
      ;;
    *)
      refused=$((refused + 1))
      skipped+=("$member ($email): $rest")
      ;;
    esac
  done
  for value in ${skipped[@]+"${skipped[@]}"}; do
    echo "note: Claude account pool skipped $value" >&2
  done
  if [ "${#ranked[@]}" -gt 0 ]; then
    best=$(printf '%s\n' "${ranked[@]}" | sort -t "$(printf '\t')" -k1,1gr -k2,2gr -k3,3n | head -1)
    chosen=$(printf '%s' "$best" | cut -f4)
    chosen_email=$(printf '%s' "$best" | cut -f5)
    summary=$(printf '%s' "$best" | cut -f6)
  elif [ "$unread" -gt 0 ] && [ "$refused" -eq 0 ]; then
    echo "note: Claude account pool could not read any member's quota; launching on the ordinary default login exactly as without a pool" >&2
    return 0
  else
    echo "error: config/claude-accounts has no account a launch may use; every member was skipped (see the notes above): sign one in, wait for a reset, or name one with --account" >&2
    return 1
  fi
  echo "note: Claude account pool chose $chosen ($chosen_email): $summary" >&2
  printf '%s\t%s\t\t%s\n' "$chosen" "$(fm_worker_account_root "$chosen")" "$chosen_email"
}

# fm_worker_account_prior <prior-harness> <recorded-account>
# Prints the account a relaunched task is treated as already on: the recorded
# account=, or `ordinary` for a Claude task whose record predates the pool and
# carries none, so its relaunch stays on the login it started on.
fm_worker_account_prior() {
  if [ -n "$2" ] || [ "$1" != claude ]; then
    printf '%s\n' "$2"
  else
    printf 'ordinary\n'
  fi
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
