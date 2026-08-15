#!/usr/bin/env bash
#
# Launch the desktop app from your build tree against the REAL daemon on
# 127.0.0.1:6767 (home ~/.paseo).
#
# Self-contained on purpose. It does not call the repo's own dev tooling, which
# has its own reasons to change; your build must not be entangled with it.
#
# Usage:  desvio run desktop [--no-seed]
# Env:    PASEO_REAL_HOME  PASEO_REAL_PORT
#         PASEO_FORK_DESKTOP_PORT (throwaway daemon, default 6769)
#         PASEO_FORK_CDP_PORT     (host seeder, default 9333)
#
# Why it is built this way
#
#   `npm run dev:desktop` cannot do this job. It pins PASEO_LISTEN to 6768 and
#   PASEO_HOME to <tree>/.dev/paseo-home, and it uses the checkout's ordinary
#   .dev/user-data — where manageBuiltInDaemon defaults to TRUE. The app then
#   starts its own empty daemon and connects to THAT. The symptom is a sidebar
#   of skeletons that never resolve, and nothing in the log to explain it.
#
#   So: a throwaway home (every daemon-lifecycle path in the app resolves
#   through $PASEO_HOME/paseo.pid, so the real daemon is not addressable), a
#   desktop-settings.json with management off, an assertion that Electron agrees
#   about userData, and a seeded host entry pointing at the real daemon.
#
set -euo pipefail

: "${DESVIO_WORKTREE:?run this with: desvio run desktop}"
BUILD_DIR="$DESVIO_WORKTREE"

# Paseo's own settings live beside this script, not in desvio.conf. `if`, not
# `&&`: under `set -e` a false test as the last command kills the script.
PASEO_CONF="${PASEO_CONF:-$(dirname "$DESVIO_CONFIG_FILE")/paseo.conf}"
if [ -f "$PASEO_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PASEO_CONF"
fi

REAL_HOME="${PASEO_REAL_HOME:-$HOME/.paseo}"
REAL_PORT="${PASEO_REAL_PORT:-6767}"
# Never 6767, and clear of 6768 which every dev script defaults to.
DESKTOP_DEV_PORT="${PASEO_FORK_DESKTOP_PORT:-6769}"
CDP_PORT="${PASEO_FORK_CDP_PORT:-9333}"
REGISTRY_KEY="@paseo:daemon-registry"
SEED=1

for arg in "$@"; do
  case "$arg" in
    --no-seed)  SEED=0 ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

die() { printf '\n\033[1;31m[fork] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# bash's /dev/tcp, so this needs no nc.
port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0
  return 1
}

# ---------- preflight ----------
[ -d "$BUILD_DIR" ] || die "no build tree at $BUILD_DIR — run desvio build first"
[ -d "$BUILD_DIR/packages/desktop" ] || die "$BUILD_DIR is not a Paseo checkout"

port_open "$REAL_PORT" || die "no daemon on 127.0.0.1:$REAL_PORT.
  Start it with: desvio run start --no-desktop. Do NOT switch on built-in
  daemon management in the app to work around this — that starts a second,
  empty daemon and the app connects to it."

# ---------- environment for dev.sh ----------
# dev.sh IGNORES a bare PASEO_ELECTRON_USER_DATA_DIR: resolveDevUserDataDir
# checks PASEO_DEV_ROOT first and returns "$PASEO_DEV_ROOT/.dev/user-data"
# (packages/desktop/scripts/dev-runtime-config.mjs). Getting this wrong is
# silent — Electron opens the checkout's ordinary .dev/user-data, where
# manageBuiltInDaemon defaults to true.
DESKTOP_ROOT="$BUILD_DIR/.dev/desktop-real-daemon"
export PASEO_DEV_ROOT="$DESKTOP_ROOT"
export PASEO_HOME="$DESKTOP_ROOT/.dev/paseo-home"
export PASEO_LISTEN="127.0.0.1:$DESKTOP_DEV_PORT"
export PASEO_DEV_MANAGED_HOME=1
unset PASEO_DEV_SEED_HOME
# Display only — dev.sh re-exports it as PASEO_DAEMON_ENDPOINT, which nothing
# under packages/desktop/src reads. The real connection is the seeded host below.
export PASEO_DEV_DAEMON_ENDPOINT="localhost:$REAL_PORT"
export PASEO_ELECTRON_USER_DATA_DIR="$DESKTOP_ROOT/.dev/user-data"
mkdir -p "$PASEO_ELECTRON_USER_DATA_DIR"

# Both migrations flags must be pre-applied: without
# daemonStopOnQuitDefaultApplied, coerceDocument resets keepRunningAfterQuit on
# first read (packages/desktop/src/settings/desktop-settings.ts).
cat >"$PASEO_ELECTRON_USER_DATA_DIR/desktop-settings.json" <<'JSON'
{
  "version": 1,
  "settings": {
    "releaseChannel": "stable",
    "daemon": {
      "manageBuiltInDaemon": false,
      "keepRunningAfterQuit": true
    }
  },
  "migrations": {
    "legacyRendererSettingsImported": true,
    "daemonStopOnQuitDefaultApplied": true
  }
}
JSON

# Ask the checkout's own resolver where Electron will really put userData and
# refuse to launch if it disagrees. The failure this catches is invisible from
# the outside: the app opens, looks fine, and talks to the wrong daemon. If the
# module is gone or renamed, degrade to a no-op rather than block the launch.
RESOLVED_USER_DATA=$(node --input-type=module -e "
  import { resolveDevUserDataDir } from '$BUILD_DIR/packages/desktop/scripts/dev-runtime-config.mjs';
  process.stdout.write(resolveDevUserDataDir({
    devRoot: process.env.PASEO_DEV_ROOT,
    inheritedUserDataDir: process.env.PASEO_ELECTRON_USER_DATA_DIR,
    fallbackRoot: process.env.PASEO_DEV_ROOT,
  }));
" 2>/dev/null) || RESOLVED_USER_DATA=""
if [ -n "$RESOLVED_USER_DATA" ] && [ "$RESOLVED_USER_DATA" != "$PASEO_ELECTRON_USER_DATA_DIR" ]; then
  die "userData mismatch — refusing to launch.
  seeded:   $PASEO_ELECTRON_USER_DATA_DIR
  Electron: $RESOLVED_USER_DATA
  The dev scripts' userData resolution changed. Without a fix the app would run
  with manageBuiltInDaemon defaulting to true and start its own daemon."
fi

# ---------- versions (display only, never fatal) ----------
# Use the BUILD TREE's CLI, not the one on PATH. PATH `paseo` is a symlink into
# the installed Paseo.app, which is older than this build and refuses to read a
# config the newer daemon wrote ('Unrecognized key: "agentProfiles"'). That is
# what silently killed the old launch path: a failing pipeline in a bare
# assignment under `set -euo pipefail`, with stderr sent to /dev/null.
FORK_CLI="$BUILD_DIR/packages/cli/bin/paseo"
DAEMON_VERSION=""
if [ -x "$FORK_CLI" ]; then
  DAEMON_VERSION=$(PASEO_HOME="$REAL_HOME" "$FORK_CLI" daemon status --json 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try { process.stdout.write(String(JSON.parse(s).daemonVersion ?? "")) } catch {}
    })' 2>/dev/null) || DAEMON_VERSION=""
fi
BUILD_VERSION=$(node -p "require('$BUILD_DIR/package.json').version" 2>/dev/null) || BUILD_VERSION=""

# ---------- host seeder ----------
#
# Electron cannot auto-register a host the way web does: runBoot() returns early
# as soon as window.paseoDesktop exists, before both the local-daemon override
# and the localhost fallback, and the only built-in auto-registration is the
# managed-daemon path — the exact thing that must stay off here. So seed the
# renderer's registry directly. It is AsyncStorage under "@paseo:daemon-registry",
# which on Electron is plain localStorage. Writing its LevelDB on disk is
# fragile, so drive it over CDP, the way the repo's own e2e fixtures do.
#
# This opens a debugging surface on 127.0.0.1 for the life of the app.
# Loopback-only and dev-only, but real — --no-seed turns it off.
SEED_NOTE="off (--no-seed) — add localhost:$REAL_PORT by hand"
if [ "$SEED" = "1" ]; then
  port_open "$CDP_PORT" &&
    die "port $CDP_PORT is already in use, so the seeder would attach to the wrong
  process. Set PASEO_FORK_CDP_PORT to a free port, or pass --no-seed."

  SERVER_ID=$(cat "$REAL_HOME/server-id" 2>/dev/null || true)
  [ -n "$SERVER_ID" ] || SERVER_ID="srv_unknown"

  # Top-level await needs the .mjs extension, and mktemp's random suffix would
  # become the extension — so make a directory and name the file inside it.
  SEEDER_DIR=$(mktemp -d -t desvio-seed) || die "could not create a temp dir for the seeder"
  cat >"$SEEDER_DIR/seed.mjs" <<'NODE'
const cdpPort = Number(process.env.SEED_CDP_PORT);
const endpoint = process.env.SEED_ENDPOINT;
const serverId = process.env.SEED_SERVER_ID;
const key = process.env.SEED_KEY;
const deadline = Date.now() + 180_000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Mirrors the shape normalizeStoredHostProfile accepts (host-connection.ts).
// The connection id must be `direct:<endpoint>` — it is recomputed on load, so
// a mismatch silently orphans preferredConnectionId.
const expression = `(() => {
  const K = ${JSON.stringify(key)};
  try {
    const cur = JSON.parse(localStorage.getItem(K) ?? "[]");
    if (Array.isArray(cur) && cur.length > 0) return "kept";
  } catch {}
  const endpoint = ${JSON.stringify(endpoint)};
  const id = "direct:" + endpoint;
  const now = new Date().toISOString();
  localStorage.setItem(K, JSON.stringify([{
    serverId: ${JSON.stringify(serverId)},
    label: "localhost",
    connections: [{ id, type: "directTcp", endpoint }],
    preferredConnectionId: id,
    createdAt: now,
    updatedAt: now,
  }]));
  return "seeded";
})()`;

async function findPageTarget() {
  const res = await fetch(`http://127.0.0.1:${cdpPort}/json/list`);
  const targets = await res.json();
  // Skip devtools:// targets; we want the app window itself.
  return targets.find(
    (t) => t.type === "page" && typeof t.url === "string" && t.url.startsWith("http"),
  );
}

function evaluate(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("CDP evaluate timed out"));
    }, 10_000);
    ws.onerror = () => { clearTimeout(timer); reject(new Error("CDP socket error")); };
    ws.onopen = () => {
      ws.send(JSON.stringify({
        id: 1,
        method: "Runtime.evaluate",
        params: { expression, returnByValue: true, awaitPromise: true },
      }));
    };
    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id === 1) {
        const outcome = msg.result?.result?.value;
        // Reload only when something was written: the app reads storage once at
        // boot, so a seed that lands after boot needs a re-read.
        if (outcome === "seeded") {
          ws.send(JSON.stringify({ id: 2, method: "Page.reload", params: {} }));
          return;
        }
        clearTimeout(timer);
        ws.close();
        resolve(outcome);
      } else if (msg.id === 2) {
        clearTimeout(timer);
        ws.close();
        resolve("seeded");
      }
    };
  });
}

while (Date.now() < deadline) {
  try {
    const target = await findPageTarget();
    if (target?.webSocketDebuggerUrl) {
      const outcome = await evaluate(target.webSocketDebuggerUrl);
      if (outcome === "seeded") {
        console.log(`[fork] host ${endpoint} auto-added`);
      } else if (outcome === "kept") {
        console.log("[fork] host registry already populated, left alone");
      }
      if (outcome) process.exit(0);
    }
  } catch {
    // Electron/Metro not up yet, or the window is still loading. Keep waiting.
  }
  await sleep(1000);
}
console.error("[fork] gave up waiting to auto-add the host — add it by hand");
process.exit(1);
NODE

  export PASEO_ELECTRON_REMOTE_DEBUGGING_PORT="$CDP_PORT"
  (
    SEED_CDP_PORT="$CDP_PORT" \
      SEED_ENDPOINT="localhost:$REAL_PORT" \
      SEED_SERVER_ID="$SERVER_ID" \
      SEED_KEY="$REGISTRY_KEY" \
      node "$SEEDER_DIR/seed.mjs"
    rm -rf "$SEEDER_DIR"
  ) &
  SEED_NOTE="on — localhost:$REAL_PORT added automatically (CDP $CDP_PORT)"
fi

echo "══════════════════════════════════════════════════════"
echo "  ${DESVIO_NAME:-your build} desktop → real daemon"
echo "══════════════════════════════════════════════════════"
echo "  Daemon:     localhost:$REAL_PORT  (not managed by this app)"
echo "  Versions:   daemon ${DAEMON_VERSION:-unknown} vs build ${BUILD_VERSION:-unknown}"
echo "  Home:       $PASEO_HOME  (throwaway — $REAL_HOME untouched)"
echo "  userData:   $PASEO_ELECTRON_USER_DATA_DIR"
echo "  Host seed:  $SEED_NOTE"
echo "══════════════════════════════════════════════════════"

exec npm --prefix "$BUILD_DIR" run dev --workspace=@getpaseo/desktop
