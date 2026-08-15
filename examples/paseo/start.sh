#!/usr/bin/env bash
#
# Run your build against your real ~/.paseo data.
#
# Stops whatever daemon is on the real home, starts the build tree's daemon in
# its place, and launches the desktop app against it.
#
# STOPPING THE DAEMON KILLS EVERY AGENT PROCESS. The conversations survive —
# the session id is preserved and the next prompt resumes them — but a turn that
# is in flight right now is lost. That is why this asks first.
#
# Usage:  desvio run start [--no-desktop] [--yes]
# Env:    PASEO_REAL_HOME=/path
#
set -euo pipefail

: "${DESVIO_WORKTREE:?run this with: desvio run start}"
BUILD_DIR="$DESVIO_WORKTREE"

# Paseo's own settings live beside this script, not in desvio.conf. `if`, not
# `&&`: under `set -e` a false test as the last command kills the script.
PASEO_CONF="${PASEO_CONF:-$(dirname "$DESVIO_CONFIG_FILE")/paseo.conf}"
if [ -f "$PASEO_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PASEO_CONF"
fi
# Its sibling task. Handing off with exec rather than `desvio run desktop` keeps
# this working when desvio itself was invoked by path and is not on PATH.
DESKTOP_TASK="$(dirname "$DESVIO_CONFIG_FILE")/desktop.sh"

REAL_HOME="${PASEO_REAL_HOME:-$HOME/.paseo}"
DAEMON_LOG="$DESVIO_STATE/daemon-out.log"
BRANCH="${DESVIO_BRANCH:-mine}"
WANT_DESKTOP=1
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --no-desktop) WANT_DESKTOP=0 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[run]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[run]\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31m[run] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# The listen address must come from the real config.json. Setting PASEO_LISTEN
# here would write a different listen into the real home and strand the phone.
unset PASEO_LISTEN

PASEO="$BUILD_DIR/packages/cli/bin/paseo"
run_cli(){ PASEO_HOME="$REAL_HOME" "$PASEO" "$@"; }

# `npm start` runs the server workspace, so the daemon's cwd is
# <tree>/packages/server, never the tree root. Every comparison against a tree
# has to be a prefix test.
serves_build_tree(){ case "${1:-}" in "$BUILD_DIR"|"$BUILD_DIR"/*) return 0 ;; *) return 1 ;; esac; }

# ---------- preflight ----------
[ -d "$BUILD_DIR" ] || die "no build tree at $BUILD_DIR — run desvio build first"
[ -f "$BUILD_DIR/packages/server/dist/scripts/supervisor-entrypoint.js" ] ||
  die "build tree is not built — run desvio build first"
[ -x "$PASEO" ] || die "no CLI at $PASEO — run desvio build first"

HEAD_BRANCH=$(git -C "$BUILD_DIR" rev-parse --abbrev-ref HEAD)
[ "$HEAD_BRANCH" = "$BRANCH" ] ||
  warn "build tree is on '$HEAD_BRANCH', not '$BRANCH' — starting it anyway"

# Which tree is serving right now? If it is already this one, there is nothing to
# swap and stopping would kill agents for no reason.
CURRENT_CWD=""
PIDFILE="$REAL_HOME/paseo.pid"
if [ -f "$PIDFILE" ]; then
  DPID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PIDFILE" | head -1)
  if [ -n "${DPID:-}" ] && kill -0 "$DPID" 2>/dev/null; then
    CURRENT_CWD=$(lsof -a -p "$DPID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  fi
fi

if [ -n "${CURRENT_CWD:-}" ] && serves_build_tree "$CURRENT_CWD"; then
  log "the daemon already serves $BUILD_DIR — leaving it alone"
  if [ "$WANT_DESKTOP" = 1 ]; then exec "$DESKTOP_TASK"; fi
  exit 0
fi

log "swapping the daemon on $REAL_HOME"
printf '       from: %s\n' "${CURRENT_CWD:-<not running>}"
printf '       to:   %s\n' "$BUILD_DIR"

# ---------- who is about to be killed ----------
LIVE=""
if [ -n "${CURRENT_CWD:-}" ]; then
  LIVE=$(run_cli ls -g --json 2>/dev/null |
    python3 -c 'import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows if isinstance(rows, list) else []:
    if r.get("status") == "running":
        print("  %-9s %-46s %s" % (r.get("shortId",""), (r.get("name") or "")[:46], r.get("cwd","")))' || true)
fi

if [ -n "$LIVE" ]; then
  warn "these agents have a live process and will be terminated:"
  printf '%s\n' "$LIVE"
  warn "Their conversations resume on the next prompt. A turn running RIGHT NOW is lost."
  warn "If one of them is the agent reading this, it kills itself. Run this from a terminal."
fi

if [ "$ASSUME_YES" != 1 ] && [ -n "${CURRENT_CWD:-}" ]; then
  printf '\nStop the daemon and swap? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) die "cancelled — nothing was stopped" ;; esac
fi

# ---------- stop ----------
if [ -n "${CURRENT_CWD:-}" ]; then
  log "stopping the current daemon"
  run_cli daemon stop || die "daemon stop failed — nothing was started, you are unchanged"
fi

# ---------- start ----------
log "starting $BRANCH from $BUILD_DIR (log: $DAEMON_LOG)"
: > "$DAEMON_LOG"
(
  cd "$BUILD_DIR"
  PASEO_HOME="$REAL_HOME" nohup npm start >> "$DAEMON_LOG" 2>&1 &
  echo $! > "$DESVIO_STATE/daemon.pid"
)

# Everything below can fail, and by this point the user's real daemon has
# already been stopped. Failing without taking the half-started one down with us
# leaves 6767 held by a process nobody is managing, and the recovery
# instructions at the bottom of this file assume that has not happened.
kill_spawned() {
  local pid
  pid=$(cat "$DESVIO_STATE/daemon.pid" 2>/dev/null || true)
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  warn "stopping the daemon this script started (pid $pid)"
  # npm start spawns node as a child, so this may leave that behind. Say so
  # rather than implying the port is definitely free again.
  kill "$pid" 2>/dev/null ||
    warn "could not stop pid $pid — kill it by hand before retrying"
}

log "waiting for it to come up"
for _ in $(seq 1 60); do
  if run_cli daemon status >/dev/null 2>&1; then break; fi
  sleep 1
done

run_cli daemon status >/dev/null 2>&1 || {
  kill_spawned
  die "daemon did not come up within 60s — read $DAEMON_LOG"
}

# Prove it is OUR build serving, not a survivor or a desktop-managed daemon.
NEW_PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PIDFILE" | head -1)
NEW_CWD=$(lsof -a -p "$NEW_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
serves_build_tree "$NEW_CWD" || {
  kill_spawned
  die "a daemon is up (pid $NEW_PID) but serves '$NEW_CWD', not the build tree.
  Something else won the port. Read $DAEMON_LOG."
}

log "daemon up — pid $NEW_PID, serving $BUILD_DIR"

# ---------- desktop ----------
if [ "$WANT_DESKTOP" = 1 ]; then
  log "launching the desktop app against it"
  # Metro and Electron resolve their root at startup, so the UI must be
  # restarted too or it keeps serving the previous tree.
  exec "$DESKTOP_TASK"
fi

cat <<EOF

Desktop skipped. Launch it yourself with:
  desvio run desktop

Go back to the released app:
  PASEO_HOME=$REAL_HOME "$PASEO" daemon stop
  open -a Paseo
EOF
