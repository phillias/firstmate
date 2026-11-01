#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-trust.sh and the grok spawns that call it.
#
# Both halves of the contract are load-bearing: a fresh task worktree's
# primary checkout is trusted in the store the worker will actually read, so
# the worker reaches its brief with no dialog, and every out-of-scope path,
# malformed store, recorded decline, and undeterminable store is REFUSED rather
# than warned about or quietly overridden.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-trust)

TRUST="$ROOT/bin/fm-worker-trust.sh"

PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -I -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$candidate
    break
  fi
done

# make_case <name>: a project with one linked worktree plus an isolated user
# home. Sets CASE_DIR, PROJ, WT, and UHOME.
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  UHOME="$CASE_DIR/home"
  mkdir -p "$UHOME"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
}

run_trust() {  # <harness> <worktree> <project>
  env -u GROK_HOME HOME="$UHOME" "$TRUST" "$@" 2>&1
}

# toml_value <store> <key> <field>: the parsed [folders.<key>] value as JSON, or null.
toml_value() {
  "$PYTHON" -I -c '
import json, sys, tomllib
store, key, field = sys.argv[1:]
with open(store, "rb") as stream:
    doc = tomllib.load(stream)
print(json.dumps(doc.get("folders", {}).get(key, {}).get(field)))
' "$@"
}

grok_store() { printf '%s\n' "$UHOME/.grok/trusted_folders.toml"; }

need_python() {  # <label>
  [ -n "$PYTHON" ] && return 0
  pass "$1 (skipped: no python 3.11+ with tomllib)"
  return 1
}

test_grok_trusts_the_primary_checkout() {
  need_python "fm-worker-trust.sh: grok records the primary checkout" || return 0
  local out
  make_case grok-basic
  out=$(run_trust grok "$WT" "$PROJ")
  expect_code 0 $? "a grok registration for a linked worktree must succeed: $out"
  assert_contains "$out" "trusted: $PROJ" "grok must record the primary checkout"
  [ "$(toml_value "$(grok_store)" "$PROJ" trusted)" = true ] \
    || fail "the grok store does not trust the primary checkout"
  [ "$(toml_value "$(grok_store)" "$WT" trusted)" = null ] \
    || fail "grok must not record the worktree path it never reads"
  pass "fm-worker-trust.sh: grok records the primary checkout grok keys on"
}

test_linked_worktree_project_resolves_its_primary_checkout() {
  need_python "fm-worker-trust.sh: a linked-worktree project resolves its primary" || return 0
  local out second
  make_case linked-project
  second="$CASE_DIR/second"
  git -C "$PROJ" worktree add --quiet -b wt-linked-second "$second"
  out=$(run_trust grok "$WT" "$second")
  expect_code 0 $? "a project argument that is itself a linked worktree must be accepted: $out"
  [ "$(toml_value "$(grok_store)" "$PROJ" trusted)" = true ] \
    || fail "the primary checkout behind a linked-worktree project was not recorded"
  [ "$(toml_value "$(grok_store)" "$second" trusted)" = null ] \
    || fail "the linked-worktree project path itself was recorded"
  pass "fm-worker-trust.sh: a linked-worktree project records its primary checkout"
}

test_registration_is_idempotent() {
  need_python "fm-worker-trust.sh: a repeat registration is a no-op" || return 0
  local before after
  make_case idempotent
  run_trust grok "$WT" "$PROJ" >/dev/null || fail "first grok registration failed"
  before=$(cat "$(grok_store)")
  run_trust grok "$WT" "$PROJ" >/dev/null || fail "repeat grok registration failed"
  after=$(cat "$(grok_store)")
  [ "$before" = "$after" ] || fail "a repeat registration rewrote an already trusted store"
  pass "fm-worker-trust.sh: a repeat registration leaves the store unchanged"
}

test_existing_store_content_is_preserved() {
  need_python "fm-worker-trust.sh: unrelated content is preserved" || return 0
  local store out
  make_case preserve
  store=$(grok_store)
  mkdir -p "$(dirname "$store")"
  printf '# operator comment\n[folders."/elsewhere"]\ntrusted = true\ndecided_at = 1' > "$store"
  out=$(run_trust grok "$WT" "$PROJ")
  expect_code 0 $? "registration into an existing store must succeed: $out"
  assert_grep '# operator comment' "$store" "the operator's comment was dropped"
  [ "$(toml_value "$store" /elsewhere trusted)" = true ] \
    || fail "an unrelated folder entry was lost"
  [ "$(toml_value "$store" "$PROJ" trusted)" = true ] \
    || fail "the primary checkout entry was not added"
  pass "fm-worker-trust.sh: existing store bytes and entries are preserved"
}

test_out_of_scope_paths_are_refused() {
  local out plain
  make_case scope
  plain="$CASE_DIR/plain"
  mkdir -p "$plain" "$WT/sub"
  out=$(run_trust grok "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  out=$(run_trust grok "$WT/sub" "$PROJ")
  expect_code 1 $? "a worktree subdirectory must be refused: $out"
  out=$(run_trust grok "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  out=$(run_trust grok "$UHOME" "$PROJ")
  expect_code 1 $? "the home directory must be refused: $out"
  make_case scope-foreign
  out=$(run_trust grok "$WT" "$TMP_ROOT/scope/project")
  expect_code 1 $? "a worktree of an unrelated project must be refused: $out"
  [ ! -e "$UHOME/.grok/trusted_folders.toml" ] || fail "a refused registration still wrote a store"
  pass "fm-worker-trust.sh: every out-of-scope path is refused and nothing is written"
}

test_unverified_harness_name_is_refused() {
  local out name
  make_case unverified
  for name in codex grokker grok-cli; do
    out=$(run_trust "$name" "$WT" "$PROJ")
    expect_code 2 $? "harness name '$name' must be refused: $out"
  done
  [ ! -e "$UHOME/.grok" ] || fail "an unverified harness name still wrote a store"
  pass "fm-worker-trust.sh: only an exact verified harness name is accepted"
}

test_recorded_decline_is_not_overridden() {
  need_python "fm-worker-trust.sh: a recorded decline is refused" || return 0
  local out store before
  make_case decline
  store=$(grok_store)
  mkdir -p "$(dirname "$store")"
  printf '[folders."%s"]\ntrusted = false\n' "$PROJ" > "$store"
  before=$(cat "$store")
  out=$(run_trust grok "$WT" "$PROJ")
  expect_code 1 $? "a grok decline must be refused: $out"
  assert_contains "$out" "decline" "the grok refusal did not name the decline"
  [ "$before" = "$(cat "$store")" ] || fail "the grok decline was rewritten"
  pass "fm-worker-trust.sh: a recorded decline is refused, never overridden"
}

test_numeric_trust_values_are_not_accepted() {
  need_python "fm-worker-trust.sh: numeric trust values are rejected" || return 0
  local out store before
  make_case numeric-trust
  store=$(grok_store)
  mkdir -p "$(dirname "$store")"
  for value in 1 1.0; do
    printf '[folders."%s"]\ntrusted = %s\n' "$PROJ" "$value" > "$store"
    before=$(cat "$store")
    out=$(run_trust grok "$WT" "$PROJ")
    expect_code 1 $? "numeric trust value '$value' must be refused: $out"
    [ "$before" = "$(cat "$store")" ] || fail "numeric trust value '$value' was rewritten"
  done
  pass "fm-worker-trust.sh: numeric trust values are rejected"
}

test_malformed_and_foreign_stores_are_refused() {
  need_python "fm-worker-trust.sh: malformed stores are refused" || return 0
  local out store
  make_case malformed
  store=$(grok_store)
  mkdir -p "$(dirname "$store")"
  printf 'not = [valid\n' > "$store"
  out=$(run_trust grok "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not = [valid' "$store" "the unparseable store was overwritten"
  printf 'folders = { "/x" = { trusted = true } }\n' > "$store"
  out=$(run_trust grok "$WT" "$PROJ")
  expect_code 1 $? "a store that cannot take an appended table must be refused: $out"
  assert_grep 'folders = {' "$store" "the inline-table store was rewritten"
  if [ "$(id -u)" != 0 ]; then
    rm -f "$store"
    ln -s /etc/passwd "$store"
    out=$(run_trust grok "$WT" "$PROJ")
    expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  fi
  pass "fm-worker-trust.sh: malformed and foreign-owned stores are refused untouched"
}

test_missing_python_is_a_refusal() {
  local out bindir tool
  make_case no-python
  bindir="$CASE_DIR/bin"
  mkdir -p "$bindir"
  for tool in git dirname basename cat; do
    ln -s "$(command -v "$tool")" "$bindir/$tool"
  done
  out=$(env -u GROK_HOME HOME="$UHOME" PATH="$bindir" /bin/bash "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a host without python 3.11+ must refuse: $out"
  assert_contains "$out" "python 3.11" "the refusal did not name the missing python"
  [ ! -e "$UHOME/.grok/trusted_folders.toml" ] || fail "a store was written without python"
  pass "fm-worker-trust.sh: a host without python 3.11+ is refused, never warned past"
}

test_repository_local_python_modules_are_not_imported() {
  need_python "fm-worker-trust.sh: repository-local python modules are ignored" || return 0
  local out marker
  make_case local-module
  marker="$CASE_DIR/imported"
  printf 'open(%s, "w").close()\nraise SystemExit(0)\n' "'$marker'" > "$WT/tomllib.py"
  out=$(cd "$WT" && env -u GROK_HOME HOME="$UHOME" PYTHONPATH="$WT" "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "registration from a checkout holding tomllib.py must still succeed: $out"
  [ ! -e "$marker" ] || fail "a repository-local tomllib.py was imported"
  pass "fm-worker-trust.sh: a repository-local tomllib.py is never imported"
}

test_store_home_is_relocated() {
  need_python "fm-worker-trust.sh: GROK_HOME relocates the store" || return 0
  local out
  make_case relocate
  out=$(HOME="$UHOME" GROK_HOME="$CASE_DIR/gh" "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "a GROK_HOME registration must succeed: $out"
  [ "$(toml_value "$CASE_DIR/gh/trusted_folders.toml" "$PROJ" trusted)" = true ] \
    || fail "GROK_HOME was not honoured"
  out=$(HOME="$UHOME" GROK_HOME=relative "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative GROK_HOME must be refused: $out"
  [ ! -e "$UHOME/.grok" ] || fail "a relocated registration still wrote under HOME"
  pass "fm-worker-trust.sh: GROK_HOME relocates the store and a relative home is refused"
}

# spawn_grok <name> <grok-home> <harness-or-raw-command> [allowlist-body]: a
# real fm-spawn of a ship worker in a fresh linked worktree, with GROK_HOME set
# to <grok-home> (empty leaves it unset) and, when a fourth argument is given,
# config/launch-env-allowlist holding it. Sets CASE_DIR, PROJ, WT, SPAWN_HOME,
# SPAWN_ID, OUT, and SPAWN_RC.
spawn_grok() {
  local name=$1 grok_home=$2 launch=$3 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  SPAWN_HOME="$CASE_DIR/fmhome"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  SPAWN_ID="${name//-/}$$"
  fakebin=$(make_spawn_fakebin "$CASE_DIR/fake" grok)
  fm_test_spawn_home "$SPAWN_HOME" grok
  if [ "$#" -ge 4 ]; then
    printf '%s' "$4" > "$SPAWN_HOME/config/launch-env-allowlist"
  fi
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
  fm_test_spawn_brief "$SPAWN_HOME" "$SPAWN_ID"
  OUT=$(
    unset GROK_HOME
    [ -z "$grok_home" ] || export GROK_HOME="$grok_home"
    fm_test_run_spawn "$SPAWN_HOME" "$WT" "$fakebin" "$SPAWN_ID" "$PROJ" "$launch" \
      --mode no-mistakes --yolo off
  )
  SPAWN_RC=$?
}

user_grok_store() { printf '%s\n' "$SPAWN_HOME/user-home/.grok/trusted_folders.toml"; }

test_grok_spawn_pretrusts_its_primary_checkout() {
  need_python "fm-spawn.sh: a grok spawn pre-trusts its checkout" || return 0
  local grok_home="$TMP_ROOT/grok-spawn-home"
  mkdir -p "$grok_home"
  spawn_grok grok-spawn "$grok_home" grok
  expect_code 0 "$SPAWN_RC" "the grok spawn failed: $OUT"
  [ "$(toml_value "$grok_home/trusted_folders.toml" "$PROJ" trusted)" = true ] \
    || fail "the grok spawn did not pre-register the primary checkout: $OUT"
  pass "fm-spawn.sh: a grok spawn pre-registers the primary checkout before launch"
}

test_allowlist_without_grok_home_registers_the_default_store() {
  need_python "fm-spawn.sh: an allowlist that drops GROK_HOME uses the default store" || return 0
  local grok_home="$TMP_ROOT/allowlist-ignored-grok-home"
  mkdir -p "$grok_home"
  spawn_grok allowlist-default "$grok_home" grok ''
  expect_code 0 "$SPAWN_RC" "the allowlisted grok spawn failed: $OUT"
  [ "$(toml_value "$(user_grok_store)" "$PROJ" trusted)" = true ] \
    || fail "a launch that drops GROK_HOME did not register the worker's default store: $OUT"
  [ ! -e "$grok_home/trusted_folders.toml" ] \
    || fail "a GROK_HOME the launch drops still received the registration"
  pass "fm-spawn.sh: an allowlist that omits GROK_HOME registers \$HOME/.grok"
}

test_raw_command_setting_grok_home_is_refused() {
  need_python "fm-spawn.sh: a raw command that sets GROK_HOME is refused" || return 0
  spawn_grok raw-grok-home '' 'GROK_HOME=/elsewhere grok --always-approve'
  expect_code 1 "$SPAWN_RC" "a raw grok launch that sets GROK_HOME must refuse: $OUT"
  assert_contains "$OUT" "sets GROK_HOME itself" "the refusal did not name the undeterminable store"
  [ ! -e "$SPAWN_HOME/state/$SPAWN_ID.meta" ] || fail "a refused raw launch still published task state"
  [ ! -e "$(user_grok_store)" ] || fail "a refused raw launch still wrote a trust store"
  pass "fm-spawn.sh: a raw grok command that sets GROK_HOME is refused, never parsed"
}

test_refused_spawn_leaves_no_task_state() {
  need_python "fm-spawn.sh: a trust-refused grok spawn leaves no task state" || return 0
  local grok_home="$TMP_ROOT/refused-grok-home"
  mkdir -p "$grok_home"
  printf 'not = [valid\n' > "$grok_home/trusted_folders.toml"
  spawn_grok refused-spawn "$grok_home" grok
  expect_code 1 "$SPAWN_RC" "a spawn whose trust registration is refused must fail: $OUT"
  assert_contains "$OUT" "folder trust" "the spawn did not report the trust refusal"
  [ ! -e "$SPAWN_HOME/state/$SPAWN_ID.busy-state" ] \
    || fail "a refused spawn stranded a busy record"
  [ ! -e "/tmp/fm-$SPAWN_ID" ] \
    || { rm -rf "/tmp/fm-$SPAWN_ID"; fail "a refused spawn stranded a temp root"; }
  assert_grep 'not = [valid' "$grok_home/trusted_folders.toml" "the refused spawn rewrote the store"
  pass "fm-spawn.sh: a trust-refused grok spawn leaves no task state behind"
}

fm_test_run \
  test_grok_trusts_the_primary_checkout \
  test_linked_worktree_project_resolves_its_primary_checkout \
  test_registration_is_idempotent \
  test_existing_store_content_is_preserved \
  test_out_of_scope_paths_are_refused \
  test_unverified_harness_name_is_refused \
  test_recorded_decline_is_not_overridden \
  test_numeric_trust_values_are_not_accepted \
  test_malformed_and_foreign_stores_are_refused \
  test_missing_python_is_a_refusal \
  test_repository_local_python_modules_are_not_imported \
  test_store_home_is_relocated \
  test_grok_spawn_pretrusts_its_primary_checkout \
  test_allowlist_without_grok_home_registers_the_default_store \
  test_raw_command_setting_grok_home_is_refused \
  test_refused_spawn_leaves_no_task_state
