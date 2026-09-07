#!/usr/bin/env bash
#
# Stop everything Paseo is running: the desktop app, the daemon behind it, and
# the agent processes the daemon spawned.
#
# Quitting the app from the Dock is not enough, and that is deliberate on the
# app's side: keepRunningAfterQuit leaves the supervisor and the daemon alive so
# agents keep working with no window open. But every agent turn — claude, its
# MCP servers, their children — hangs off the DAEMON, not off the window you
# closed. Close the window and the process tree stays: port 6767 held, models
# still running. This is the switch that takes the whole tree down.
#
# THIS KILLS EVERY AGENT PROCESS. The conversations survive — the session id is
# preserved and the next prompt resumes them — but a turn that is in flight right
# now is lost. That is why this asks first.
#
# Usage:  desvio run stop [--yes] [--dry-run] [--keep-app] [--keep-daemon]
# Env:    PASEO_REAL_HOME=/path
#
set -euo pipefail

# Not fatal when absent: cleaning up must work even from a half-built tree.
BUILD_DIR="${DESVIO_WORKTREE:-}"

# Paseo's own settings live beside this script, not in desvio.conf. `if`, not
# `&&`: under `set -e` a false test as the last command kills the script.
PASEO_CONF="${PASEO_CONF:-$(dirname "$DESVIO_CONFIG_FILE")/paseo.conf}"
if [ -f "$PASEO_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PASEO_CONF"
fi

REAL_HOME="${PASEO_REAL_HOME:-$HOME/.paseo}"
ASSUME_YES=0
DRY_RUN=0
WANT_APP=1
WANT_DAEMON=1

for arg in "$@"; do
  case "$arg" in
    --yes|-y)      ASSUME_YES=1 ;;
    --dry-run|-n)  DRY_RUN=1; ASSUME_YES=1 ;;
    --keep-app)    WANT_APP=0 ;;
    --keep-daemon) WANT_DAEMON=0 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[stop]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[stop]\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31m[stop] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
act(){  if [ "$DRY_RUN" = 1 ]; then printf '       would %s\n' "$*"; else printf '       %s\n' "$*"; fi; }

# ---------- process helpers ----------

# Every pid below $1, breadth first. Printed space separated.
descendants() {
  local frontier="$1" next kids all="" p
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      kids=$(pgrep -P "$p" 2>/dev/null || true)
      if [ -n "$kids" ]; then all="$all $kids"; next="$next $kids"; fi
    done
    frontier="$next"
  done
  printf '%s' "$all"
}

# The ppid chain above $1, so we can recognise our own process tree.
ancestors() {
  local p="$1" out=""
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
    out="$out $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
  done
  printf '%s' "$out"
}

alive_of() {
  local p out=""
  for p in $1; do
    if kill -0 "$p" 2>/dev/null; then out="$out $p"; fi
  done
  printf '%s' "$out"
}

describe() { ps -o command= -p "$1" 2>/dev/null | cut -c1-100 || true; }

# bash 3.2 — macOS's system bash, and the version this script must parse
# under (tests/run.sh lints it with `bash -n`) — cannot parse a `case`
# statement inside `$(...)` command substitution: it errors on the first
# `;;` regardless of how the case is laid out. Both matches below build
# their answer inside one, so each goes through a function instead — the
# function body is parsed on its own, and only a call to it appears inside
# the substitution.
is_helper() { case "$(describe "$1")" in *Helper*) return 0 ;; *) return 1 ;; esac; }
pid_in_self() { case "$SELF" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# SIGTERM, then SIGKILL for whatever ignored it. Returns 0 even when nothing was
# there, so a caller can run it unconditionally.
term_then_kill() {
  local pids left
  pids=$(alive_of "$1")
  [ -n "${pids// /}" ] || return 0
  local p
  for p in $pids; do act "kill $p  $(describe "$p")"; done
  [ "$DRY_RUN" = 1 ] && return 0
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    left=$(alive_of "$pids")
    [ -n "${left// /}" ] || return 0
    sleep 0.5
  done
  left=$(alive_of "$pids")
  if [ -n "${left// /}" ]; then
    warn "did not go on SIGTERM, sending SIGKILL:$left"
    kill -KILL $left 2>/dev/null || true
    sleep 1
  fi
  return 0
}

# Same pidfile format desvio.conf's desvio_preflight parses, and start.sh parses
# twice more — five copies after this one. See the comment at desvio.conf's
# desvio_preflight for the full list; a format change is a five-site edit.
pidfile_pid() {
  local f="$1/paseo.pid"
  [ -f "$f" ] || return 0
  sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -1
}

# ---------- what is running ----------

# Prefer the build tree's CLI: the `paseo` on PATH is a symlink into the
# installed bundle and may be older than the daemon it is talking to. Neither is
# required — everything below falls back to signalling the pid directly.
CLI=""
if [ -n "$BUILD_DIR" ] && [ -x "$BUILD_DIR/packages/cli/bin/paseo" ]; then
  CLI="$BUILD_DIR/packages/cli/bin/paseo"
elif command -v paseo >/dev/null 2>&1; then
  CLI="$(command -v paseo)"
fi

# Every home that could hold a daemon: the real one, plus the throwaway homes
# `desvio run desktop` and the repo's own dev scripts run against.
HOMES="$REAL_HOME"
if [ -n "$BUILD_DIR" ]; then
  HOMES="$HOMES
$BUILD_DIR/.dev/desktop-real-daemon/.dev/paseo-home
$BUILD_DIR/.dev/paseo-home"
fi

# The app bundles. Main processes only — the Helper children die with them.
APP_PIDS=$(pgrep -f 'Contents/MacOS/Paseo' 2>/dev/null | while read -r p; do
  is_helper "$p" || printf '%s ' "$p"
done || true)

# Metro, Electron and npm from `desvio run desktop`, which outlive a ^C often
# enough to matter. Matched on the tree path in their argv, never on a bare
# "node", so a sibling checkout is not touched.
DEV_PIDS=""
if [ -n "$BUILD_DIR" ]; then
  DEV_PIDS=$(pgrep -f "$BUILD_DIR" 2>/dev/null | tr '\n' ' ' || true)
fi
# The daemon `desvio run start` launched, recorded by that script.
if [ -n "${DESVIO_STATE:-}" ] && [ -f "$DESVIO_STATE/daemon.pid" ]; then
  DEV_PIDS="$DEV_PIDS $(cat "$DESVIO_STATE/daemon.pid")"
fi

# Never include ourselves in a sweep: this script and its own children (pgrep,
# ps) match the tree path too.
SELF=" $(ancestors $$) $$ "
DEV_PIDS=$(for p in $DEV_PIDS; do pid_in_self "$p" || printf '%s ' "$p"; done)

# Daemon pids, and the agent trees underneath them. Collected BEFORE anything is
# stopped: once the daemon dies its children reparent to launchd and there is
# nothing left tying them to Paseo. Killing only this recorded set is what keeps
# the sweep from touching a claude you started yourself in a terminal.
DAEMON_PIDS=""
AGENT_PIDS=""
while IFS= read -r home; do
  [ -n "$home" ] || continue
  pid=$(pidfile_pid "$home")
  [ -n "${pid:-}" ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  DAEMON_PIDS="$DAEMON_PIDS $pid"
  AGENT_PIDS="$AGENT_PIDS $(descendants "$pid")"
done <<EOF
$HOMES
EOF

if [ -z "${APP_PIDS// /}" ] && [ -z "${DAEMON_PIDS// /}" ] && [ -z "${DEV_PIDS// /}" ]; then
  log "nothing to stop — no app, no daemon, no dev processes"
  exit 0
fi

# ---------- report ----------
log "about to stop"
if [ "$WANT_APP" = 1 ] && [ -n "${APP_PIDS// /}" ]; then
  printf '       app:     %s\n' "$(for p in $APP_PIDS; do printf '%s ' "$p"; done)"
  for p in $APP_PIDS; do printf '                %s\n' "$(describe "$p")"; done
fi
if [ "$WANT_DAEMON" = 1 ] && [ -n "${DAEMON_PIDS// /}" ]; then
  printf '       daemon: %s\n' "$DAEMON_PIDS"
  printf '       agents: %s process(es) under it\n' "$(printf '%s' "$AGENT_PIDS" | wc -w | tr -d ' ')"
fi
[ -n "${DEV_PIDS// /}" ] && printf '       dev:    %s\n' "$DEV_PIDS"

# What the daemon calls live right now — worth seeing before you say yes.
if [ "$WANT_DAEMON" = 1 ] && [ -n "$CLI" ] && [ -n "${DAEMON_PIDS// /}" ]; then
  LIVE=$(PASEO_HOME="$REAL_HOME" "$CLI" ls -g --json 2>/dev/null |
    python3 -c 'import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows if isinstance(rows, list) else []:
    if r.get("status") == "running":
        print("  %-9s %-46s %s" % (r.get("shortId",""), (r.get("name") or "")[:46], r.get("cwd","")))' || true)
  if [ -n "$LIVE" ]; then
    warn "these agents have a live process and will be terminated:"
    printf '%s\n' "$LIVE"
    warn "Their conversations resume on the next prompt. A turn running RIGHT NOW is lost."
  fi
fi

# If one of the trees we are about to kill is our own, say so plainly. An agent
# running this stops itself mid-turn and its output never comes back.
for p in $DAEMON_PIDS $AGENT_PIDS $APP_PIDS; do
  case "$SELF" in
    *" $p "*)
      warn "pid $p is an ancestor of this shell — you are inside the tree being stopped."
      warn "This kills the agent running it. Run it from a terminal instead."
      break ;;
  esac
done

if [ "$ASSUME_YES" != 1 ]; then
  printf '\nStop all of it? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) die "cancelled — nothing was stopped" ;; esac
fi

# ---------- app first ----------
# Before the daemon, always. The app owns a supervisor and will start a fresh
# daemon the moment it notices the old one went away.
if [ "$WANT_APP" = 1 ] && [ -n "${APP_PIDS// /}" ]; then
  log "quitting the desktop app"
  term_then_kill "$APP_PIDS"
fi

# ---------- daemons ----------
if [ "$WANT_DAEMON" = 1 ]; then
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    pid=$(pidfile_pid "$home")
    [ -n "${pid:-}" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    log "stopping the daemon on $home (pid $pid)"
    if [ "$DRY_RUN" = 1 ]; then
      act "paseo daemon stop --home $home --force"
    elif [ -n "$CLI" ] && PASEO_HOME="$home" "$CLI" daemon stop --home "$home" --force >/dev/null 2>&1; then
      printf '       stopped cleanly\n'
    else
      # No CLI, or it could not talk to a daemon that is plainly alive. The
      # supervisor is the parent, so terminating it takes the daemon with it.
      warn "daemon stop did not work — signalling pid $pid directly"
      term_then_kill "$pid"
    fi
  done <<EOF
$HOMES
EOF
fi

# ---------- what the daemon left behind ----------
# The reason this task exists. Agent processes are spawned detached; a daemon
# that was SIGKILLed, or one that died with the app, leaves them reparented to
# launchd and running forever.
if [ "$WANT_DAEMON" = 1 ]; then
  ORPHANS=$(alive_of "$AGENT_PIDS")
  if [ -n "${ORPHANS// /}" ]; then
    log "cleaning up agent processes the daemon left running"
    term_then_kill "$ORPHANS"
  fi
fi

# ---------- dev processes ----------
if [ -n "${DEV_PIDS// /}" ]; then
  REMAINING=$(alive_of "$DEV_PIDS")
  if [ -n "${REMAINING// /}" ]; then
    log "stopping dev processes from $BUILD_DIR"
    term_then_kill "$REMAINING"
  fi
fi

# ---------- verify ----------
if [ "$DRY_RUN" = 1 ]; then
  log "dry run — nothing was stopped"
  exit 0
fi

LEFT=$(alive_of "$APP_PIDS $DAEMON_PIDS $AGENT_PIDS $DEV_PIDS")
if [ -n "${LEFT// /}" ]; then
  warn "still up after SIGKILL:"
  for p in $LEFT; do printf '       %s  %s\n' "$p" "$(describe "$p")"; done
  die "could not stop everything — the pids above need a look"
fi

log "all stopped"
