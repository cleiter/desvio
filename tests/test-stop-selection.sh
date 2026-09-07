#!/usr/bin/env bash
#
# stop.sh's pure process-selection logic: descendants(), ancestors(),
# alive_of(), term_then_kill(), and the self-exclusion filter that keeps a
# sweep from reaping the shell running it. Real `sleep` children throughout —
# no mocking needed, since none of this touches Paseo.
#
# Daemon discovery, the CLI-stop fallback and the live-agent listing stay
# untested: they need a real daemon, and this suite builds fixtures rather
# than driving one.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

STOP_SH="$DESVIO_SRC/examples/paseo/stop.sh"

# Pull in only the helper functions, not the whole script. Sourcing stop.sh
# itself would run its "what is running" section — real pgrep/lsof calls and a
# blocking confirmation prompt — as a side effect of testing four functions.
eval "$(awk '
  /^# ---------- process helpers ----------$/ { f=1 }
  f { print }
  /^# ---------- what is running ----------$/ { exit }
' "$STOP_SH")"

# If stop.sh's section markers ever move, the eval above silently defines
# nothing rather than failing loudly — catch that here instead of forty
# confusing failures below.
type descendants >/dev/null 2>&1 ||
  { printf 'could not extract stop.sh helpers — its section markers may have moved\n' >&2; exit 2; }

# term_then_kill calls these; stand them in rather than extracting a second,
# earlier range from stop.sh — they are presentation, not selection logic.
# shellcheck disable=SC2034  # read by the eval'd term_then_kill, not this file
DRY_RUN=0
act()  { :; }
warn() { :; }

# The self-exclusion filter is inline in stop.sh, not a function — extract the
# exact two lines it runs, so this tests stop.sh's own code rather than a
# reimplementation that could drift from it.
SELF_FILTER_SRC="$(grep -A1 -F 'SELF=" $(ancestors $$) $$ "' "$STOP_SH")"
[ -n "$SELF_FILTER_SRC" ] ||
  { printf 'could not extract the self-exclusion filter from stop.sh\n' >&2; exit 2; }

# ---------- helpers ----------

# assert_has_pid/assert_no_pid <haystack> <pid> <label> — descendants() and
# alive_of() return space-joined pids, sometimes with an embedded newline from
# a multi-child `pgrep -P`. Normalise before matching so pid "2" cannot match
# inside "12".
assert_has_pid() {
  local haystack="$1" pid="$2" label="$3"
  case " $(printf '%s' "$haystack" | tr '\n' ' ') " in
    *" $pid "*) ok "$label" ;;
    *) fail "$label" "expected pid $pid in: $haystack" ;;
  esac
}
assert_no_pid() {
  local haystack="$1" pid="$2" label="$3"
  case " $(printf '%s' "$haystack" | tr '\n' ' ') " in
    *" $pid "*) fail "$label" "should not contain pid $pid: $haystack" ;;
    *) ok "$label" ;;
  esac
}

# Every pid this file backgrounds, so a failed assertion never leaves a real
# `sleep` running past the test that started it.
ALL_TEST_PIDS=()
cleanup_all() {
  local p
  for p in ${ALL_TEST_PIDS+"${ALL_TEST_PIDS[@]}"}; do kill -KILL "$p" 2>/dev/null || true; done
  fixture_cleanup
}
trap cleanup_all EXIT

# spawn_one <name> — writes a one-off script from stdin, backgrounds it
# directly (no command-substitution subshell in between, so its parent stays
# THIS process rather than an ephemeral one that has already exited), and sets
# $PID.
spawn_one() {
  local f="$TEST_TMP/$1.sh"
  cat > "$f"
  chmod +x "$f"
  "$f" &
  PID=$!
  ALL_TEST_PIDS+=("$PID")
}

# spawn_tree — a real three-level tree: ROOT (a backgrounded script, child of
# THIS process) backgrounds MID, which backgrounds LEAF. Sets ROOT_PID,
# MID_PID and LEAF_PID.
#
# descendants() is always read through a command substitution, here and in
# stop.sh alike, so it runs the whole BFS inside a subshell of its caller.
# Querying descendants() of $$ itself (or of any of $$'s own ancestors) is
# self-referential: that computing subshell is really and currently a child
# of $$, and pgrep -P $$ will honestly report it — then, at the next BFS
# level, it recurses into ITS OWN in-flight `pgrep ... || true` wrapper
# process, since `||` keeps that wrapper alive as a real, if transient, child
# of the subshell for exactly as long as the query takes. The result is a
# phantom branch that only exists because it was asked about, and how much of
# it survives to be seen is a pure timing race — it reproduced on every run
# under Linux/glibc pgrep, and not once under macOS/BSD pgrep. stop.sh itself
# never triggers this: it only ever calls descendants() on a daemon pid, never
# on itself or an ancestor. So the fix here is not to descendants() but to the
# tree: root it one level below $$, at ROOT (a plain descendant, not an
# ancestor, of the subshell that computes the answer), which is exactly the
# shape stop.sh's own calls have.
spawn_tree() {
  TREE_DIR="$TEST_TMP/tree"; mkdir -p "$TREE_DIR"
  cat > "$TREE_DIR/leaf.sh" <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
  cat > "$TREE_DIR/mid.sh" <<EOF
#!/usr/bin/env bash
"$TREE_DIR/leaf.sh" &
echo \$! > "$TREE_DIR/leaf.pid"
wait
EOF
  cat > "$TREE_DIR/root.sh" <<EOF
#!/usr/bin/env bash
"$TREE_DIR/mid.sh" &
echo \$! > "$TREE_DIR/mid.pid"
wait
EOF
  chmod +x "$TREE_DIR/leaf.sh" "$TREE_DIR/mid.sh" "$TREE_DIR/root.sh"
  "$TREE_DIR/root.sh" &
  ROOT_PID=$!
  ALL_TEST_PIDS+=("$ROOT_PID")
  # Wait for each pidfile rather than a fixed sleep — not a race against how
  # fast the fork happens on a loaded machine.
  for _ in $(seq 1 50); do [ -f "$TREE_DIR/mid.pid" ] && break; sleep 0.1; done
  MID_PID=$(cat "$TREE_DIR/mid.pid" 2>/dev/null || true)
  [ -n "${MID_PID:-}" ] || { printf 'mid process never started\n' >&2; exit 2; }
  ALL_TEST_PIDS+=("$MID_PID")
  for _ in $(seq 1 50); do [ -f "$TREE_DIR/leaf.pid" ] && break; sleep 0.1; done
  LEAF_PID=$(cat "$TREE_DIR/leaf.pid" 2>/dev/null || true)
  [ -n "${LEAF_PID:-}" ] || { printf 'leaf process never started\n' >&2; exit 2; }
  ALL_TEST_PIDS+=("$LEAF_PID")
}

reap_tree() {
  kill -KILL "$LEAF_PID" "$MID_PID" "$ROOT_PID" 2>/dev/null || true
  wait "$ROOT_PID" 2>/dev/null || true
}

wait_gone() {
  local pid="$1"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
}

# ---------------------------------------------------------------------------
it "descendants() finds a whole tree breadth first"
fixture_new
spawn_tree
got="$(descendants "$ROOT_PID")"
assert_has_pid "$got" "$MID_PID" "the direct child is found"
assert_has_pid "$got" "$LEAF_PID" "the grandchild is found too"
assert_contains "$got" "$MID_PID $LEAF_PID" "the child comes before the grandchild"
reap_tree

# ---------------------------------------------------------------------------
it "ancestors() walks to init and stops"
fixture_new
parent_pid=$(ps -o ppid= -p $$ | tr -d ' ')
got="$(ancestors "$$")"
assert_has_pid "$got" "$$" "includes itself"
assert_has_pid "$got" "$parent_pid" "includes its parent"
assert_no_pid "$got" "0" "does not walk past pid 0"
assert_no_pid "$got" "1" "does not walk past pid 1 (init/launchd)"

# ---------------------------------------------------------------------------
it "alive_of() drops reaped pids"
fixture_new
spawn_one alive <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
ALIVE_PID="$PID"
spawn_one dying <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
DYING_PID="$PID"
kill -KILL "$DYING_PID" 2>/dev/null
wait_gone "$DYING_PID"
got="$(alive_of "$ALIVE_PID $DYING_PID")"
assert_has_pid "$got" "$ALIVE_PID" "the still-alive pid stays"
assert_no_pid "$got" "$DYING_PID" "the killed pid is dropped"
kill -KILL "$ALIVE_PID" 2>/dev/null

# ---------------------------------------------------------------------------
it "term_then_kill() stops a normal process with SIGTERM alone"
fixture_new
spawn_one normal <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
term_then_kill "$PID"
kill -0 "$PID" 2>/dev/null
assert_eq 1 "$?" "gone after SIGTERM, no escalation needed"

# ---------------------------------------------------------------------------
it "term_then_kill() escalates to SIGKILL when TERM is ignored"
fixture_new
spawn_one stubborn <<'EOF'
#!/usr/bin/env bash
trap '' TERM
exec sleep 60
EOF
term_then_kill "$PID"
wait_gone "$PID"
kill -0 "$PID" 2>/dev/null
assert_eq 1 "$?" "gone after SIGKILL escalation"

# ---------------------------------------------------------------------------
it "the self-exclusion filter keeps the caller out of DEV_PIDS"
fixture_new
spawn_one other <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
OTHER_PID="$PID"
parent_pid=$(ps -o ppid= -p $$ | tr -d ' ')
DEV_PIDS="$$ $parent_pid $OTHER_PID"
eval "$SELF_FILTER_SRC"
assert_no_pid "$DEV_PIDS" "$$" "the caller's own pid is filtered out"
assert_no_pid "$DEV_PIDS" "$parent_pid" "and its parent, up the ancestor chain"
assert_has_pid "$DEV_PIDS" "$OTHER_PID" "an unrelated process survives the filter"

finish
