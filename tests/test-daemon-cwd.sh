#!/usr/bin/env bash
#
# examples/paseo's daemon-cwd lookup: paseo_daemon_cwd() itself, real on
# whichever branch this OS exercises (/proc on Linux, lsof on macOS — CI's
# matrix covers both without a conditional here), and desvio_preflight()'s use
# of it, where paseo_daemon_cwd is stubbed so the four outcomes below don't
# depend on a real process's real working directory.
#
# This is the regression test for issue #2: a live daemon whose tree cannot be
# determined used to read as "no daemon" and let a build proceed under it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

CONF="$DESVIO_SRC/examples/paseo/desvio.conf"

# lib/common.sh first, for the real die/log/warn — desvio.conf's hooks call
# them by contract (see the comment at its own top), and a stub here would
# test a reimplementation instead of what actually runs.
# shellcheck source=../lib/common.sh
. "$DESVIO_SRC/lib/common.sh"
# shellcheck source=../examples/paseo/desvio.conf
. "$CONF"

# If either symbol has moved or been renamed, fail once here instead of a
# screenful of confusing failures below — same reasoning as
# test-stop-selection.sh's check after its own extraction.
type paseo_daemon_cwd >/dev/null 2>&1 ||
  { printf 'could not find paseo_daemon_cwd in %s — has it moved or been renamed?\n' "$CONF" >&2; exit 2; }
type desvio_preflight >/dev/null 2>&1 ||
  { printf 'could not find desvio_preflight in %s\n' "$CONF" >&2; exit 2; }

# Every pid this file backgrounds, so a failed assertion never leaves a real
# `sleep` running past the test that started it.
ALL_TEST_PIDS=()
cleanup_all() {
  local p
  for p in ${ALL_TEST_PIDS+"${ALL_TEST_PIDS[@]}"}; do kill -KILL "$p" 2>/dev/null || true; done
  fixture_cleanup
}
trap cleanup_all EXIT

# spawn_in <dir> — a real `sleep`, backgrounded directly (no command-
# substitution subshell in between) so its cwd is exactly <dir>. Sets $PID.
spawn_in() {
  ( cd "$1" && exec sleep 60 ) &
  PID=$!
  ALL_TEST_PIDS+=("$PID")
}

wait_gone() {
  local pid="$1"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
}

# ---------------------------------------------------------------------------
it "paseo_daemon_cwd resolves a live process's real directory"
fixture_new
mkdir -p "$TEST_TMP/somewhere"
spawn_in "$TEST_TMP/somewhere"
# -P: both lsof and /proc/*/cwd report the kernel's resolved path, not a
# symlinked TMPDIR — macOS's is /var/folders/... over /private/var/folders/...,
# and a plain `pwd` here would compare the wrong one.
want="$(cd "$TEST_TMP/somewhere" && pwd -P)"
got="$(paseo_daemon_cwd "$PID")"
assert_eq "$want" "$got"
kill -KILL "$PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "paseo_daemon_cwd on a dead pid prints nothing and does not fail"
fixture_new
spawn_in "$TEST_TMP"
DEAD_PID="$PID"
kill -KILL "$DEAD_PID" 2>/dev/null
wait_gone "$DEAD_PID"
# shellcheck disable=SC2218  # false positive: the real definition comes from
# the sourced desvio.conf above, not from this file's later stub of the same name
got="$(paseo_daemon_cwd "$DEAD_PID")"; status=$?
assert_eq 0 "$status" "does not fail"
assert_eq "" "$got" "prints nothing"

# ---------------------------------------------------------------------------
# desvio_preflight, with paseo_daemon_cwd stubbed: the lookup itself is
# covered above, so these cases are about what the hook DOES with an answer,
# not about the answer itself.
STUB_CWD=""
paseo_daemon_cwd() { printf '%s' "$STUB_CWD"; }

# preflight_run — desvio_preflight in a command substitution, so its `die`
# (which calls `exit`) only ends that subshell, not this test file.
preflight_run() { PRE_OUT=$(desvio_preflight 2>&1); PRE_STATUS=$?; }

write_pidfile() { printf '{"pid":%s}\n' "$1" > "$HOME/.paseo/paseo.pid"; }

# ---------------------------------------------------------------------------
it "desvio_preflight dies when a live daemon's cwd is inside the tree"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
mkdir -p "$HOME/.paseo"
spawn_in "$TEST_TMP"
write_pidfile "$PID"
STUB_CWD="$DESVIO_WORKTREE/packages/server"
preflight_run
assert_eq 1 "$PRE_STATUS" "non-zero exit"
assert_contains "$PRE_OUT" "is serving from this tree"
kill -KILL "$PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "desvio_preflight passes when the daemon serves a different tree"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
mkdir -p "$HOME/.paseo"
spawn_in "$TEST_TMP"
write_pidfile "$PID"
STUB_CWD="$TEST_TMP/somewhere/else"
preflight_run
assert_eq 0 "$PRE_STATUS"
kill -KILL "$PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "desvio_preflight is not fooled by a sibling tree sharing its prefix"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
mkdir -p "$HOME/.paseo"
spawn_in "$TEST_TMP"
write_pidfile "$PID"
STUB_CWD="${DESVIO_WORKTREE}-other/packages/server"
preflight_run
assert_eq 0 "$PRE_STATUS" "a bare prefix match must not trigger on <tree>-other"
kill -KILL "$PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "desvio_preflight dies when a live daemon's tree cannot be determined — the regression this fixes"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
mkdir -p "$HOME/.paseo"
spawn_in "$TEST_TMP"
write_pidfile "$PID"
STUB_CWD=""
preflight_run
assert_eq 1 "$PRE_STATUS" "an unknown tree must refuse, not pass"
assert_contains "$PRE_OUT" "cannot say"
kill -KILL "$PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "desvio_preflight passes when the pidfile names a dead pid"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
mkdir -p "$HOME/.paseo"
spawn_in "$TEST_TMP"
DEAD_PID="$PID"
kill -KILL "$DEAD_PID" 2>/dev/null
wait_gone "$DEAD_PID"
write_pidfile "$DEAD_PID"
STUB_CWD="$DESVIO_WORKTREE/packages/server"   # must never be consulted
preflight_run
assert_eq 0 "$PRE_STATUS" "a dead pid is not a running daemon"

# ---------------------------------------------------------------------------
it "desvio_preflight passes when there is no pidfile at all"
fixture_new
DESVIO_WORKTREE="$TEST_TMP/build-tree"
rm -f "$HOME/.paseo/paseo.pid" 2>/dev/null
preflight_run
assert_eq 0 "$PRE_STATUS"

finish
