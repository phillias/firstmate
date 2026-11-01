#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-trust.sh and the grok and codex spawns that
# call it.
#
# Both halves of the contract are load-bearing: a fresh task worktree is
# trusted under the key each harness actually reads (grok: the primary
# checkout; codex: the worktree), so the worker reaches its brief with no
# dialog, and every out-of-scope path, malformed store, and recorded decline is
# REFUSED rather than warned about or quietly overridden.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-trust)

TRUST="$ROOT/bin/fm-worker-trust.sh"

PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
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
  env -u GROK_HOME -u CODEX_HOME HOME="$UHOME" "$TRUST" "$@" 2>&1
}

# toml_value <store> <table> <key> <field>: the parsed value as JSON, or null.
toml_value() {
  "$PYTHON" -c '
import json, sys, tomllib
store, table, key, field = sys.argv[1:]
with open(store, "rb") as stream:
    doc = tomllib.load(stream)
print(json.dumps(doc.get(table, {}).get(key, {}).get(field)))
' "$@"
}

grok_store() { printf '%s\n' "$UHOME/.grok/trusted_folders.toml"; }
codex_store() { printf '%s\n' "$UHOME/.codex/config.toml"; }

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
  [ "$(toml_value "$(grok_store)" folders "$PROJ" trusted)" = true ] \
    || fail "the grok store does not trust the primary checkout"
  [ "$(toml_value "$(grok_store)" folders "$WT" trusted)" = null ] \
    || fail "grok must not record the worktree path it never reads"
  pass "fm-worker-trust.sh: grok records the primary checkout grok keys on"
}

test_codex_trusts_only_the_worktree() {
  need_python "fm-worker-trust.sh: codex records the worktree" || return 0
  local out
  make_case codex-basic
  out=$(run_trust codex "$WT" "$PROJ")
  expect_code 0 $? "a codex registration for a linked worktree must succeed: $out"
  [ "$(toml_value "$(codex_store)" projects "$WT" trust_level)" = '"trusted"' ] \
    || fail "the codex store does not trust the worktree"
  [ "$(toml_value "$(codex_store)" projects "$PROJ" trust_level)" = null ] \
    || fail "codex must not widen trust to the primary checkout"
  pass "fm-worker-trust.sh: codex records only the worktree"
}

test_registration_is_idempotent() {
  need_python "fm-worker-trust.sh: a repeat registration is a no-op" || return 0
  local before after
  make_case idempotent
  run_trust grok "$WT" "$PROJ" >/dev/null || fail "first grok registration failed"
  run_trust codex "$WT" "$PROJ" >/dev/null || fail "first codex registration failed"
  before=$(cat "$(grok_store)" "$(codex_store)")
  run_trust grok "$WT" "$PROJ" >/dev/null || fail "repeat grok registration failed"
  run_trust codex "$WT" "$PROJ" >/dev/null || fail "repeat codex registration failed"
  after=$(cat "$(grok_store)" "$(codex_store)")
  [ "$before" = "$after" ] || fail "a repeat registration rewrote an already trusted store"
  pass "fm-worker-trust.sh: a repeat registration leaves the store unchanged"
}

test_existing_store_content_is_preserved() {
  need_python "fm-worker-trust.sh: unrelated content is preserved" || return 0
  local store out
  make_case preserve
  store=$(codex_store)
  mkdir -p "$(dirname "$store")"
  printf '# operator comment\nmodel = "m"\n[projects."/elsewhere"]\ntrust_level = "trusted"' > "$store"
  out=$(run_trust codex "$WT" "$PROJ")
  expect_code 0 $? "registration into an existing store must succeed: $out"
  assert_grep '# operator comment' "$store" "the operator's comment was dropped"
  [ "$(toml_value "$store" projects /elsewhere trust_level)" = '"trusted"' ] \
    || fail "an unrelated project entry was lost"
  [ "$(toml_value "$store" projects "$WT" trust_level)" = '"trusted"' ] \
    || fail "the worktree entry was not added"
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
  out=$(run_trust codex "$WT/sub" "$PROJ")
  expect_code 1 $? "a worktree subdirectory must be refused: $out"
  out=$(run_trust codex "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  out=$(run_trust grok "$UHOME" "$PROJ")
  expect_code 1 $? "the home directory must be refused: $out"
  out=$(run_trust grok "$WT" "$WT")
  expect_code 1 $? "a project argument that is not a primary checkout must be refused: $out"
  make_case scope-foreign
  out=$(run_trust codex "$WT" "$TMP_ROOT/scope/project")
  expect_code 1 $? "a worktree of an unrelated project must be refused: $out"
  [ ! -e "$UHOME/.grok/trusted_folders.toml" ] && [ ! -e "$UHOME/.codex/config.toml" ] \
    || fail "a refused registration still wrote a store"
  pass "fm-worker-trust.sh: every out-of-scope path is refused and nothing is written"
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
  store=$(codex_store)
  mkdir -p "$(dirname "$store")"
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$PROJ" > "$store"
  before=$(cat "$store")
  out=$(run_trust codex "$WT" "$PROJ")
  expect_code 1 $? "a codex decline on the primary checkout must be refused: $out"
  [ "$before" = "$(cat "$store")" ] || fail "the codex decline was overridden by a worktree entry"
  pass "fm-worker-trust.sh: a recorded decline is refused, never overridden"
}

test_malformed_and_foreign_stores_are_refused() {
  need_python "fm-worker-trust.sh: malformed stores are refused" || return 0
  local out store
  make_case malformed
  store=$(codex_store)
  mkdir -p "$(dirname "$store")"
  printf 'not = [valid\n' > "$store"
  out=$(run_trust codex "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not = [valid' "$store" "the unparseable store was overwritten"
  printf 'projects = { "/x" = { trust_level = "trusted" } }\n' > "$store"
  out=$(run_trust codex "$WT" "$PROJ")
  expect_code 1 $? "a store that cannot take an appended table must be refused: $out"
  assert_grep 'projects = {' "$store" "the inline-table store was rewritten"
  if [ "$(id -u)" != 0 ]; then
    rm -f "$store"
    ln -s /etc/passwd "$store"
    out=$(run_trust codex "$WT" "$PROJ")
    expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  fi
  pass "fm-worker-trust.sh: malformed and foreign-owned stores are refused untouched"
}

test_missing_python_exits_3_and_writes_nothing() {
  local out bindir tool
  make_case no-python
  bindir="$CASE_DIR/bin"
  mkdir -p "$bindir"
  for tool in git dirname basename cat; do
    ln -s "$(command -v "$tool")" "$bindir/$tool"
  done
  out=$(env -u GROK_HOME HOME="$UHOME" PATH="$bindir" /bin/bash "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 3 $? "a host without python 3.11+ must exit 3: $out"
  [ ! -e "$UHOME/.grok/trusted_folders.toml" ] || fail "a store was written without python"
  out=$(env -u GROK_HOME HOME="$UHOME" PATH="$bindir" /bin/bash "$TRUST" grok "$PROJ" "$PROJ" 2>&1)
  expect_code 1 $? "a scope refusal must not soften without python: $out"
  pass "fm-worker-trust.sh: missing python exits 3 and a scope refusal stays a refusal"
}

test_store_homes_are_relocated() {
  need_python "fm-worker-trust.sh: GROK_HOME and CODEX_HOME relocate the store" || return 0
  local out
  make_case relocate
  out=$(HOME="$UHOME" GROK_HOME="$CASE_DIR/gh" "$TRUST" grok "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "a GROK_HOME registration must succeed: $out"
  [ "$(toml_value "$CASE_DIR/gh/trusted_folders.toml" folders "$PROJ" trusted)" = true ] \
    || fail "GROK_HOME was not honoured"
  out=$(HOME="$UHOME" CODEX_HOME=relative "$TRUST" codex "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative CODEX_HOME must be refused: $out"
  [ ! -e "$UHOME/.grok" ] || fail "a relocated registration still wrote under HOME"
  pass "fm-worker-trust.sh: GROK_HOME relocates the store and a relative home is refused"
}

# spawn_worker <name> <harness> [extra env...]: a real fm-spawn of a ship worker
# in a fresh linked worktree. Sets CASE_DIR, PROJ, WT, SPAWN_HOME, and OUT.
spawn_worker() {
  local name=$1 harness=$2 fakebin id assignment
  shift 2
  CASE_DIR="$TMP_ROOT/$name"
  SPAWN_HOME="$CASE_DIR/fmhome"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  id="${name//-/}$$"
  fakebin=$(make_spawn_fakebin "$CASE_DIR/fake" "$harness")
  fm_test_spawn_home "$SPAWN_HOME" "$harness"
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
  fm_test_spawn_brief "$SPAWN_HOME" "$id"
  OUT=$(
    unset CODEX_HOME GROK_HOME
    for assignment in "$@"; do export "${assignment?}"; done
    fm_test_run_spawn "$SPAWN_HOME" "$WT" "$fakebin" "$id" "$PROJ" "$harness" \
      --mode no-mistakes --yolo off
  )
}

test_codex_spawn_pretrusts_its_worktree() {
  need_python "fm-spawn.sh: a codex spawn pre-trusts its worktree" || return 0
  spawn_worker codex-spawn codex
  expect_code 0 $? "the codex spawn failed: $OUT"
  [ "$(toml_value "$SPAWN_HOME/user-home/.codex/config.toml" projects "$WT" trust_level)" = '"trusted"' ] \
    || fail "the codex spawn did not pre-register its worktree: $OUT"
  pass "fm-spawn.sh: a codex spawn pre-registers its worktree before launch"
}

test_grok_spawn_pretrusts_its_primary_checkout() {
  need_python "fm-spawn.sh: a grok spawn pre-trusts its checkout" || return 0
  local grok_home="$TMP_ROOT/grok-spawn-home"
  mkdir -p "$grok_home"
  spawn_worker grok-spawn grok GROK_HOME="$grok_home"
  expect_code 0 $? "the grok spawn failed: $OUT"
  [ "$(toml_value "$grok_home/trusted_folders.toml" folders "$PROJ" trusted)" = true ] \
    || fail "the grok spawn did not pre-register the primary checkout: $OUT"
  pass "fm-spawn.sh: a grok spawn pre-registers the primary checkout before launch"
}

test_refused_spawn_leaves_no_task_state() {
  need_python "fm-spawn.sh: a trust-refused codex spawn leaves no task state" || return 0
  local codex_home="$TMP_ROOT/refused-codex-home" id
  mkdir -p "$codex_home"
  printf 'not = [valid\n' > "$codex_home/config.toml"
  CASE_DIR="$TMP_ROOT/refused-spawn"
  SPAWN_HOME="$CASE_DIR/fmhome"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  id="refusedcodex$$"
  fm_test_spawn_home "$SPAWN_HOME" codex
  fm_git_worktree "$PROJ" "$WT" wt-refused-codex
  fm_test_spawn_brief "$SPAWN_HOME" "$id"
  OUT=$(CODEX_HOME="$codex_home" \
    fm_test_run_spawn "$SPAWN_HOME" "$WT" "$(make_spawn_fakebin "$CASE_DIR/fake" codex)" "$id" "$PROJ" codex \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration is refused must fail: $OUT"
  assert_contains "$OUT" "folder trust" "the spawn did not report the trust refusal"
  [ ! -e "$SPAWN_HOME/state/$id.busy-state" ] \
    || fail "a refused spawn stranded a busy record"
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root"; }
  assert_grep 'not = [valid' "$codex_home/config.toml" "the refused spawn rewrote the store"
  pass "fm-spawn.sh: a trust-refused codex spawn leaves no task state behind"
}

fm_test_run \
  test_grok_trusts_the_primary_checkout \
  test_codex_trusts_only_the_worktree \
  test_registration_is_idempotent \
  test_existing_store_content_is_preserved \
  test_out_of_scope_paths_are_refused \
  test_recorded_decline_is_not_overridden \
  test_malformed_and_foreign_stores_are_refused \
  test_missing_python_exits_3_and_writes_nothing \
  test_store_homes_are_relocated \
  test_codex_spawn_pretrusts_its_worktree \
  test_grok_spawn_pretrusts_its_primary_checkout \
  test_refused_spawn_leaves_no_task_state
