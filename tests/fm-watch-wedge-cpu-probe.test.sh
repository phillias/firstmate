#!/usr/bin/env bash
# Behavior tests for the wedge stale-timer's opt-in foreground-CPU probe
# (FM_WEDGE_CPU_PROBE_SECS, bin/fm-watch.sh wedge_cpu_motion_defers).
#
# The probe's verdict comes from kernel facts (ps cputime deltas of a pane
# tty's foreground process group), not from any vendor-rendered surface; the
# only harness-dependent input is the tty resolution, one `#{pane_tty}` query.
# These tests therefore run REAL processes on a REAL pty (through `script`)
# with a stub tmux that answers that one query, so the sampling, the
# parse, the positive-motion deferral, and every unchanged-escalation
# fallthrough are exercised without a harness. The live `#{pane_tty}` query
# itself is already exercised end to end by the composer-identity lane that
# shares it (bin/fm-tmux-lib.sh fm_tmux_composer_identity).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-cpu-probe)

WATCH="$ROOT/bin/fm-watch.sh"

epoch_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Load the three probe functions from the production file by structure (name
# to matching close brace). This loads the shipped code to RUN it; every
# assertion below is on behavior, never on source bytes.
load_probe_functions() {
  local fragment="$TMP_ROOT/wedge-cpu-fragment.sh"
  sed -n \
    -e '/^wedge_cputime_to_secs()/,/^}/p' \
    -e '/^wedge_fg_cpu_seconds()/,/^}/p' \
    -e '/^wedge_cpu_motion_defers()/,/^}/p' \
    "$WATCH" > "$fragment"
  # shellcheck source=/dev/null
  . "$fragment"
  grep -q '^wedge_cpu_motion_defers()' "$fragment" || return 1
}

install_pane_tty_stub() {  # <dir> [marker]
  local dir=$1 marker=${2:-} fb="$1/fakebin"
  mkdir -p "$fb"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    if [ -n "$marker" ]; then
      printf 'touch %q\n' "$marker"
    fi
    cat <<'STUB'
case "$*" in *pane_tty*) printf '%s\n' "${FAKE_PANE_TTY:-}"; exit 0 ;; esac
exit 1
STUB
  } > "$fb/tmux"
  chmod +x "$fb/tmux"
}

# Start a real busy/idle case on a fresh pty and record "<pid>|<tty>" in
# "$TMP_ROOT/<name>.rec". Deliberately not command-substitution-captured: the
# backgrounded script(1) needs the current shell to outlive the wait loop.
start_pty_case() {  # <name> <command...>
  local name=$1
  shift
  local out="$TMP_ROOT/$name.tty" rec="$TMP_ROOT/$name.rec" pid i=0 tty attempt
  rm -f "$out" "$rec"
  # A loaded host can lose the pty child in its first moments; retry the
  # allocation instead of failing the case on a transient environment fault.
  for attempt in 1 2 3 4 5; do
    rm -f "$out"
    script -qec "tty > $(printf '%q' "$out"); $*" /dev/null >/dev/null 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 50 ]; do
      if [ -s "$out" ] && kill -0 "$pid" 2>/dev/null; then break; fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      i=$((i + 1))
    done
    tty=$(cat "$out" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$tty" ] && kill -0 "$pid" 2>/dev/null; then
      sleep 0.3
      if kill -0 "$pid" 2>/dev/null; then break; fi
      tty=''
    fi
    tty=''
  done
  printf '%s|%s\n' "$pid" "$tty" > "$rec"
}

pty_case_pid() { cut -d'|' -f1 "$TMP_ROOT/$1.rec"; }
pty_case_tty() { cut -d'|' -f2 "$TMP_ROOT/$1.rec"; }

stop_pty_case() {  # <pid>
  local pid=$1 tty
  tty=$(ps -o tty= -p "$(pgrep -P "$pid" 2>/dev/null | head -1)" 2>/dev/null | tr -d '[:space:]')
  kill "$pid" 2>/dev/null || true
  [ -n "$tty" ] && pkill -t "${tty#/dev/}" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_cputime_parser_handles_every_ps_shape() {
  load_probe_functions || fail "probe functions missing from $WATCH"
  assert_equals "3723" "$(wedge_cputime_to_secs '01:02:03.45')"
  assert_equals "754" "$(wedge_cputime_to_secs '12:34.5')"
  assert_equals "5" "$(wedge_cputime_to_secs '5.9')"
  assert_equals "86410" "$(wedge_cputime_to_secs '1-00:00:10')"
  assert_equals "0" "$(wedge_cputime_to_secs '0')"
  pass test_cputime_parser_handles_every_ps_shape
}

test_knob_off_returns_before_any_probe_cost() {
  local dir marker out rc
  dir="$TMP_ROOT/knob-off"; mkdir -p "$dir"
  marker="$dir/tmux-called"; rm -f "$marker"
  install_pane_tty_stub "$dir" "$marker"
  TRIAGE_LOG="$dir/triage.log" TRIAGE_LOG_MAX_BYTES=100000 PATH="$dir/fakebin:$PATH" \
    FM_WEDGE_CPU_PROBE_SECS=garbage bash -c '
      triage_log() { printf '%s\n' "$1" >> "$TRIAGE_LOG"; }
      . "'"$TMP_ROOT"'/wedge-cpu-fragment.sh"
      wedge_cpu_motion_defers "test:win" "'"$dir"'/since" "test-label" 300
    ' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a set-but-invalid knob must not defer"
  [ ! -e "$marker" ] || fail "invalid-knob path still called tmux"
  [ ! -e "$dir/since" ] || fail "invalid-knob path refreshed the since file"

  rm -f "$marker"
  unset FM_WEDGE_CPU_PROBE_SECS
  TRIAGE_LOG="$dir/triage.log" TRIAGE_LOG_MAX_BYTES=100000 PATH="$dir/fakebin:$PATH" \
    FM_WEDGE_CPU_PROBE_SECS=0 bash -c '
      triage_log() { printf '%s\n' "$1" >> "$TRIAGE_LOG"; }
      . "'"$TMP_ROOT"'/wedge-cpu-fragment.sh"
      wedge_cpu_motion_defers "test:win" "'"$dir"'/since2" "test-label" 300
    ' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit 0 knob must not defer"
  [ ! -e "$marker" ] || fail "explicit-0 path still called tmux"
  [ ! -e "$dir/since2" ] || fail "explicit-0 path refreshed the since file"
  pass test_knob_off_returns_before_any_probe_cost
}

test_positive_motion_defers_and_refreshes_the_timer() {
  local dir rec pid tty out rc size_before size_after
  command -v script >/dev/null || fail "script(1) is required for the real-pty cases"
  dir="$TMP_ROOT/positive"; mkdir -p "$dir"
  install_pane_tty_stub "$dir"
  start_pty_case positive 'while :; do :; done'
  pid=$(pty_case_pid positive); tty=$(pty_case_tty positive)
  [ -n "$tty" ] || { stop_pty_case "$pid"; fail "no pty was allocated for the busy case"; }
  FAKE_PANE_TTY="$tty"
  export FAKE_PANE_TTY
  since="$dir/since"; date +%s > "$since"
  size_before=$(epoch_mtime "$since")
  sleep 1
  TRIAGE_LOG="$dir/triage.log" TRIAGE_LOG_MAX_BYTES=100000 PATH="$dir/fakebin:$PATH" \
    FM_WEDGE_CPU_PROBE_SECS=1 bash -c '
      triage_log() { printf '%s\n' "$1" >> "$TRIAGE_LOG"; }
      . "'"$TMP_ROOT"'/wedge-cpu-fragment.sh"
      wedge_cpu_motion_defers "test:win" "'"$since"'" "test-label" 300
    ' > "$dir/out" 2>&1
  rc=$?
  stop_pty_case "$pid"
  [ "$rc" -eq 0 ] || fail "a CPU-moving foreground group did not defer: $(cat "$dir/out")"
  size_after=$(epoch_mtime "$since")
  [ -n "$size_after" ] || fail "deferral left no since file"
  [ "$size_after" != "$size_before" ] || fail "deferral did not refresh the wedge timer"
  grep -F 'foreground CPU moving' "$dir/triage.log" >/dev/null \
    || fail "deferral wrote no absorbed triage line: $(cat "$dir/triage.log")"
  pass test_positive_motion_defers_and_refreshes_the_timer
}

test_zero_motion_falls_through_to_the_unchanged_escalation() {
  local dir rec pid tty rc
  command -v script >/dev/null || fail "script(1) is required for the real-pty cases"
  dir="$TMP_ROOT/zero-motion"; mkdir -p "$dir"
  install_pane_tty_stub "$dir"
  start_pty_case zero 'sleep 30'
  pid=$(pty_case_pid zero); tty=$(pty_case_tty zero)
  [ -n "$tty" ] || { stop_pty_case "$pid"; fail "no pty was allocated for the sleeping case"; }
  FAKE_PANE_TTY="$tty"
  export FAKE_PANE_TTY
  since="$dir/since"; date +%s > "$since"
  TRIAGE_LOG="$dir/triage.log" TRIAGE_LOG_MAX_BYTES=100000 PATH="$dir/fakebin:$PATH" \
    FM_WEDGE_CPU_PROBE_SECS=1 bash -c '
      triage_log() { printf '%s\n' "$1" >> "$TRIAGE_LOG"; }
      . "'"$TMP_ROOT"'/wedge-cpu-fragment.sh"
      wedge_cpu_motion_defers "test:win" "'"$since"'" "test-label" 300
    ' > "$dir/out" 2>&1
  rc=$?
  stop_pty_case "$pid"
  [ "$rc" -ne 0 ] || fail "a zero-CPU foreground group deferred the escalation: $(cat "$dir/out")"
  [ ! -e "$dir/triage.log" ] || fail "a fallthrough wrote a triage line: $(cat "$dir/triage.log")"
  pass test_zero_motion_falls_through_to_the_unchanged_escalation
}

test_unreadable_tty_keeps_the_escalation() {
  local dir rc
  dir="$TMP_ROOT/unreadable"; mkdir -p "$dir"
  install_pane_tty_stub "$dir"
  FAKE_PANE_TTY="/dev/does-not-exist-$$"
  export FAKE_PANE_TTY
  since="$dir/since"; date +%s > "$since"
  TRIAGE_LOG="$dir/triage.log" TRIAGE_LOG_MAX_BYTES=100000 PATH="$dir/fakebin:$PATH" \
    FM_WEDGE_CPU_PROBE_SECS=1 bash -c '
      triage_log() { printf '%s\n' "$1" >> "$TRIAGE_LOG"; }
      . "'"$TMP_ROOT"'/wedge-cpu-fragment.sh"
      wedge_cpu_motion_defers "test:win" "'"$since"'" "test-label" 300
    ' > "$dir/out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable tty deferred the escalation: $(cat "$dir/out")"
  if [ -e "$dir/triage.log" ] && grep -F 'foreground CPU moving' "$dir/triage.log" >/dev/null; then
    fail "an unreadable tty produced an absorbed triage line"
  fi
  pass test_unreadable_tty_keeps_the_escalation
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_cputime_parser_handles_every_ps_shape \
  test_knob_off_returns_before_any_probe_cost \
  test_positive_motion_defers_and_refreshes_the_timer \
  test_zero_motion_falls_through_to_the_unchanged_escalation \
  test_unreadable_tty_keeps_the_escalation
