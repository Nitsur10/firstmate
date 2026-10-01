#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account) and Claude account pool
# (config/claude-accounts), both owned by bin/fm-worker-account-lib.sh.
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. tests/fm-worker-account-live-e2e.test.sh proves those answers
# against the real runners.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 0
  root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
  if [ -f "\$root/.credentials.json" ]; then
    [ "\${3:-}" != --json ] || [ ! -f "\$root/email" ] || printf '{"loggedIn":true,"email":"%s"}\n' "\$(cat "\$root/email")"
    exit 0
  fi
  [ "\${3:-}" != --json ] || printf '{"loggedIn":false}\n'
  exit 1
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" >> '$dir/quota-calls'
cat "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/quota.json" 2>/dev/null
SH
  chmod +x "$fakebin/claude" "$fakebin/pi" "$fakebin/quota-axi"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  assert_absent "$CASE/quota-calls" "a home without a pool must not read quota"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

# pool_member <root> <email> [<weekly> <five-hour> <spendPriority> [<runway>]]
# A signed-in Claude root whose login reports <email>. With quota figures it
# also carries the reading the fake quota-axi serves for that root; without
# them the root has no reading, as when quota-axi cannot read it.
pool_member() {
  local root=$1 email=$2
  signed_in_claude_root "$root"
  printf '%s\n' "$email" > "$root/email"
  [ "$#" -ge 5 ] || return 0
  jq -n --arg email "$email" --argjson w "$3" --argjson f "$4" --argjson sp "$5" --arg runway "${6:-through_reset}" '
    {schemaVersion: 5, providers: [{provider: "claude", account: {email: $email},
      state: {status: "fresh", stale: false},
      windows: [{id: "five_hour", percentRemaining: $f}, {id: "seven_day", percentRemaining: $w}],
      quotaSemantics: {effectiveAvailability: [{scope: "all_models", effectivePercentRemaining: ([$w, $f] | min),
        runway: {status: $runway}, selection: {status: "known", spendPriority: $sp}}]}}]}' > "$root/quota.json"
}

test_pool_rotates_to_the_member_with_the_best_spend_priority() {
  local out rc id=pool-rank launch
  new_case pool-rank claude
  pool_member "$HOME_DIR/user-home/.claude" S@Example.com 60 90 0.8
  pool_member "$CASE/max1" n@example.com 50 90 1.4
  printf '# pooled logins\naccount=ordinary\naccount=%s\n\npages=ordinary\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pooled Claude spawn should succeed: $out"
  assert_contains "$out" "note: Claude account pool chose $CASE/max1 (n@example.com)" "the spawn should report the chosen account"
  assert_contains "$out" "spendPriority 1.4" "the choice should show the spendPriority that ranked it"
  assert_contains "$out" "account=$CASE/max1 account_email=n@example.com" "the spawned line should name the account and its login"
  assert_grep "account=$CASE/max1" "$HOME_DIR/state/$id.meta" "the task record should carry the chosen account"
  assert_grep "account_email=n@example.com" "$HOME_DIR/state/$id.meta" "the task record should carry the chosen login"
  assert_no_grep "profile-only" "$CASE/quota-calls" "a pooled read must use the Keychain login, never --profile-only"
  assert_grep "unset|--provider claude --no-credential-refresh --max-age 5m --full --json" "$CASE/quota-calls" \
    "the ordinary member must be read with CLAUDE_CONFIG_DIR unset and no credential refresh"
  assert_grep "$CASE/max1|--provider claude" "$CASE/quota-calls" "the second member must be read under its own root"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE/max1'" "the launch should select the chosen root"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/max1" "$CASE/claude-worker" "the worker should run under the chosen root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the chosen login"

  pool_member "$CASE/max1" n@example.com 50 90 0.5
  out=$(spawn_ship "$id-2"); rc=$?
  expect_code 0 "$rc" "a second pooled spawn should succeed: $out"
  assert_contains "$out" "account=ordinary account_email=s@example.com" "the higher spendPriority should now win"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "the ordinary member must launch with CLAUDE_CONFIG_DIR unset"
  pass "a Claude pool picks the member with the highest spendPriority and launches on it as a pin would"
}

test_pool_keeps_the_guards_floor_and_pages_reserve() {
  local out rc id=pool-guard
  new_case pool-guard claude
  pool_member "$HOME_DIR/user-home/.claude" s@example.com 15 90 2.0
  pool_member "$CASE/max1" n@example.com 40 90 0.5
  printf 'account=ordinary\naccount=%s\npages=ordinary\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-reserve"); rc=$?
  expect_code 0 "$rc" "a pool with one member inside the reserve should still launch: $out"
  assert_contains "$out" "skipped ordinary (s@example.com): weekly 15% left, inside the 20% pages-account reserve" \
    "the pages account should be held back by its reserve"
  assert_contains "$out" "account=$CASE/max1" "the launch should move to the other account"

  printf 'account=ordinary\naccount=%s\npages=ordinary\nreserve=10\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-lower"); rc=$?
  expect_code 0 "$rc" "a lower reserve should admit the pages account: $out"
  assert_contains "$out" "account=ordinary" "the pages account above its configured reserve should win on spendPriority"

  pool_member "$CASE/max1" n@example.com 40 10 3.0
  pool_member "$HOME_DIR/user-home/.claude" s@example.com 8 90 2.0
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a pool whose every member is guarded must refuse"
  assert_refused_before_launch "$id-none" "$out" "config/claude-accounts has no account a launch may use"
  assert_contains "$out" "weekly 8% left, under the 10% floor" "the refusal notes should show the floor"
  assert_contains "$out" "five-hour window 10% left, under the 15% guard" "the refusal notes should show the five-hour guard"

  pool_member "$HOME_DIR/user-home/.claude" s@example.com 60 90 2.0 exhausted_now
  out=$(spawn_ship "$id-out"); rc=$?
  expect_code 1 "$rc" "an exhausted member must not launch"
  assert_contains "$out" "skipped ordinary (s@example.com): exhausted now" "an exhausted runway should be skipped"
  pass "a Claude pool applies the five-hour guard, the weekly floor, the pages reserve, and exhaustion"
}

test_pool_skips_signed_out_duplicate_and_misread_members() {
  local out rc id=pool-skip
  new_case pool-skip claude
  mkdir -p "$HOME_DIR/user-home/.claude"
  pool_member "$CASE/max1" n@example.com 50 90 0.4
  pool_member "$CASE/max2" N@example.com 70 90 3.0
  pool_member "$CASE/max3" other@example.com 70 90 5.0
  pool_member "$CASE/misread" x@example.com 70 90 9.0
  jq '.providers[0].account.email = "s@example.com"' "$CASE/misread/quota.json" > "$CASE/misread.json"
  mv "$CASE/misread.json" "$CASE/misread/quota.json"
  rm "$CASE/max3/.credentials.json"
  printf 'account=ordinary\naccount=%s\naccount=%s\naccount=%s\naccount=%s\naccount=%s\n' \
    "$CASE/max1" "$CASE/max2" "$CASE/max3" "$CASE/misread" "$CASE/missing" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pool with skipped members should still launch on a usable one: $out"
  assert_contains "$out" "skipped ordinary: not signed in (claude auth status)" "a signed-out member should be skipped"
  assert_contains "$out" "skipped $CASE/max2 (n@example.com): the same login as $CASE/max1, counted once" \
    "a second root on the same login should be skipped"
  assert_contains "$out" "skipped $CASE/max3: not signed in" "a signed-out root should be skipped"
  assert_contains "$out" "skipped $CASE/misread (x@example.com): quota reading names s@example.com, not x@example.com" \
    "a reading of another login should never be trusted"
  assert_contains "$out" "skipped $CASE/missing: not a readable, searchable directory" "a missing root should be skipped"
  assert_contains "$out" "account=$CASE/max1 account_email=n@example.com" "the one usable member should be chosen"
  pass "a Claude pool skips signed-out, duplicate, misread, and missing members with a note and launches on the rest"
}

test_pool_never_trusts_an_unreadable_quota() {
  local out rc id=pool-unread
  new_case pool-unread claude
  pool_member "$HOME_DIR/user-home/.claude" s@example.com
  pool_member "$CASE/max1" n@example.com 50 90 0.4
  printf 'account=ordinary\naccount=%s\npages=ordinary\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-one"); rc=$?
  expect_code 0 "$rc" "a pool with one readable member should launch on it: $out"
  assert_contains "$out" "skipped ordinary (s@example.com): not eligible, quota read failed" \
    "an unreadable member should be skipped with a clear report"
  assert_contains "$out" "account=$CASE/max1 account_email=n@example.com" "the readable member should be chosen"

  rm "$CASE/max1/quota.json"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 0 "$rc" "a pool with no readable member should fall back to the default launch: $out"
  assert_contains "$out" "could not read any member's quota; launching on the ordinary default login exactly as without a pool" \
    "the fallback should be reported"
  assert_not_contains "$out" "chose" "no member should be chosen on an unknown quota"
  assert_not_contains "$out" "account=" "the fallback launch should record no account, as without a pool"
  assert_no_grep "^account" "$HOME_DIR/state/$id-none.meta" "the fallback task record should carry no account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" "the fallback launch should use the ambient login, not a pool member"

  out=$(spawn_ship "$id-override" --account "$CASE/max1"); rc=$?
  expect_code 0 "$rc" "--account should still override an unreadable quota: $out"
  assert_contains "$out" "account=$CASE/max1 account_email=n@example.com" "the override should name the requested account"
  pass "a Claude pool skips unreadable members, falls back to the default login when none can be read, and still honours --account"
}

test_pool_override_and_fixed_launches() {
  local out rc id=pool-override
  new_case pool-override claude
  pool_member "$HOME_DIR/user-home/.claude" s@example.com 60 90 3.0
  pool_member "$CASE/max1" n@example.com 5 90 0.1
  printf 'account=ordinary\naccount=%s\npages=ordinary\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-email" --account N@example.com); rc=$?
  expect_code 0 "$rc" "an override by email should launch on that account: $out"
  assert_contains "$out" "chose $CASE/max1 (n@example.com): named by --account" "the override should be reported"
  assert_contains "$out" "account=$CASE/max1" "the override should win over the ranking and the floor"
  out=$(spawn_ship "$id-root" --account "$CASE/max1"); rc=$?
  expect_code 0 "$rc" "an override by root should launch on that account: $out"
  assert_contains "$out" "account=$CASE/max1" "the override by root should be honoured"
  out=$(spawn_ship "$id-unknown" --account nobody@example.com); rc=$?
  expect_code 1 "$rc" "an override naming no member must refuse"
  assert_refused_before_launch "$id-unknown" "$out" "--account 'nobody@example.com' names no signed-in account"
  rm "$CASE/max1/.credentials.json"
  out=$(spawn_ship "$id-out" --account "$CASE/max1"); rc=$?
  expect_code 1 "$rc" "an override naming a signed-out member must refuse rather than move"
  assert_refused_before_launch "$id-out" "$out" "account $CASE/max1 is not signed in"

  out=$(spawn_ship "$id-raw" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude launch should take the pages account: $out"
  assert_contains "$out" "chose ordinary (s@example.com): the pages account takes every secondmate and raw launch" \
    "a raw launch should take the pages account"
  out=$(spawn_ship "$id-raw-set" --harness "CLAUDE_CONFIG_DIR=$CASE/max1 claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw command overriding the pooled account must refuse"
  assert_refused_before_launch "$id-raw-set" "$out" "config/claude-accounts selects the Claude worker account, but the raw launch command sets CLAUDE_CONFIG_DIR"

  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-pinned"); rc=$?
  expect_code 0 "$rc" "a pin should win over the pool: $out"
  assert_contains "$out" "account=ordinary" "the pin should select its own account"
  assert_not_contains "$out" "account_email=" "a pinned launch should not report a pooled login"
  out=$(spawn_ship "$id-pin-override" --account "$CASE/max1"); rc=$?
  expect_code 1 "$rc" "an override under a pin must refuse"
  assert_refused_before_launch "$id-pin-override" "$out" "config/claude-account pins every claude launch from this home, so --account cannot choose another"
  rm "$HOME_DIR/config/claude-account" "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-no-pool" --account "$CASE/max1"); rc=$?
  expect_code 1 "$rc" "an override without a pool must refuse"
  assert_refused_before_launch "$id-no-pool" "$out" "this home has no such file"
  out=$(spawn_ship "$id-codex" --harness codex --account "$CASE/max1"); rc=$?
  expect_code 1 "$rc" "an override for a non-Claude harness must refuse"
  assert_refused_before_launch "$id-codex" "$out" "applies only to Claude launches"
  pass "--account overrides the pool by email or root, fixed launches take the pages account, and a pin still wins"
}

test_malformed_pools_refuse_and_other_runners_ignore_the_pool() {
  local out rc id=pool-bad n=0 body
  new_case pool-bad claude
  pool_member "$CASE/max1" n@example.com 50 90 1.0
  for body in 'relative/root' "account=$CASE/max1"$'\r' 'pages=ordinary' "account=relative" \
    "account=$CASE/max1"$'\n'"account=$CASE/max1" "account=ordinary"$'\n'"pages=$CASE/max1" \
    "account=ordinary"$'\n'"reserve=101" "account=ordinary"$'\n'"floor=10" "account=ordinary"$'\n'"five-hour-floor=15" "account=ordinary"$'\n'"reserve=x"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-accounts"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pool #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-accounts"
  done
  assert_absent "$CASE/quota-calls" "a malformed pool must refuse before any quota read"
  printf 'account=%s\n' "$CASE/max1" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-codex" --harness codex); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore the Claude pool: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a pooled account"
  assert_absent "$CASE/quota-calls" "a codex spawn must not read the Claude pool"
  pass "a malformed pool refuses before launch, and other runners ignore it"
}

test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin
test_pool_rotates_to_the_member_with_the_best_spend_priority
test_pool_keeps_the_guards_floor_and_pages_reserve
test_pool_skips_signed_out_duplicate_and_misread_members
test_pool_never_trusts_an_unreadable_quota
test_pool_override_and_fixed_launches
test_malformed_pools_refuse_and_other_runners_ignore_the_pool

echo "# all fm-worker-account tests passed"
