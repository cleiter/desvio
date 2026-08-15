#!/usr/bin/env bash
#
# Install the bundle `desvio run package` built, and pin the settings it needs.
#
# Separate from packaging on purpose. This half fails for its own reasons — the
# app is running, /Applications says no — and none of them should cost you a
# five-minute rebuild. It also writes into the REAL userData directory, which is
# a thing you should have to ask for rather than get as a side effect.
#
# Usage:  desvio run install
# Env:    PASEO_APP_DEST=/Applications
#         PASEO_PRODUCT_NAME="Paseo Mine"
#         PASEO_USER_DATA="$HOME/Library/Application Support/Paseo"
#
set -euo pipefail

: "${DESVIO_WORKTREE:?run this with: desvio run install}"
BUILD_DIR="$DESVIO_WORKTREE"

DEST_DIR="${PASEO_APP_DEST:-/Applications}"

# Must match what package.sh built — export it once in desvio.conf, not here.
PRODUCT_NAME="${PASEO_PRODUCT_NAME:-Paseo}"
APP_NAME="$PRODUCT_NAME.app"
BUILT_APP="$BUILD_DIR/packages/desktop/release/mac-arm64/$APP_NAME"

# NOT "$PRODUCT_NAME": userData comes from app.setName(), which main.ts hardcodes
# to "Paseo" whatever the bundle is called. A renamed build reads and writes the
# stock directory, which is the point — same hosts, same settings, same history.
USER_DATA="${PASEO_USER_DATA:-$HOME/Library/Application Support/Paseo}"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[install]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$BUILT_APP" ] || die "no bundle at $BUILT_APP
  Build one first:  desvio run package"

# What it actually is, read from the bundle rather than recomputed — this script
# may run days after the build, and guessing the version would be a lie.
VERSION=$(plutil -extract CFBundleShortVersionString raw "$BUILT_APP/Contents/Info.plist" 2>/dev/null || echo unknown)

# The executable inside keeps its own name — electron-builder.yml pins
# executableName: Paseo and productName does not override it — so the full path
# is what tells this bundle apart from a stock one running next to it.
if pgrep -f "$DEST_DIR/$APP_NAME/Contents/MacOS/Paseo" >/dev/null 2>&1; then
  die "$PRODUCT_NAME is running from $DEST_DIR. Quit it first — replacing a
  running bundle leaves the live process reading files that no longer exist."
fi

# A daemon started from the tree owns port 6767 and would block the app's own.
# Two daemons, one port: the app's silently loses.
if lsof -nP -iTCP:6767 -sTCP:LISTEN -t >/dev/null 2>&1; then
  DPID=$(lsof -nP -iTCP:6767 -sTCP:LISTEN -t | head -1)
  DCWD=$(lsof -a -p "$DPID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  case "${DCWD:-}" in
    "$BUILD_DIR"|"$BUILD_DIR"/*)
      warn "a tree daemon (pid $DPID) holds 6767. The packaged app manages its own."
      warn "Stop it first: PASEO_HOME=\$HOME/.paseo $BUILD_DIR/packages/cli/bin/paseo daemon stop" ;;
  esac
fi

log "installing $VERSION to $DEST_DIR/$APP_NAME"
rm -rf "${DEST_DIR:?}/$APP_NAME"
cp -Rc "$BUILT_APP" "$DEST_DIR/$APP_NAME" 2>/dev/null || cp -R "$BUILT_APP" "$DEST_DIR/$APP_NAME"

# ---------- pin the desktop settings ----------
# The packaged app uses the REAL userData dir — PASEO_HOME and PASEO_LISTEN do
# not isolate it. Both migration flags must be pre-applied or coerceDocument
# resets keepRunningAfterQuit to its default on first read.
#
# manageBuiltInDaemon TRUE here, the opposite of desktop.sh: for the dev app the
# point is that it must never touch the real daemon; for the packaged app,
# running its own bundled daemon IS the point.
log "pinning $USER_DATA/desktop-settings.json"
mkdir -p "$USER_DATA"
cat >"$USER_DATA/desktop-settings.json" <<'JSON'
{
  "version": 1,
  "settings": {
    "releaseChannel": "stable",
    "daemon": {
      "manageBuiltInDaemon": true,
      "keepRunningAfterQuit": true
    }
  },
  "migrations": {
    "legacyRendererSettingsImported": true,
    "daemonStopOnQuitDefaultApplied": true
  }
}
JSON

PARALLEL_NOTE=""
if [ "$PRODUCT_NAME" != "Paseo" ]; then
  PARALLEL_NOTE="
A stock Paseo.app can sit in $DEST_DIR beside this one, and both read that same
userData dir. Run ONE at a time: Electron's single-instance lock lives there too,
so launching the second while the first is up just brings the first forward."
fi

cat <<EOF

$(printf '\033[1;34m[install]\033[0m') installed $DEST_DIR/$APP_NAME
       version: $VERSION

Launch it:  open -n "$DEST_DIR/$APP_NAME"

The host registry lives in the same userData dir, so the hosts you already added
are still there. The daemon this app starts is its own, on 6767, against
\$HOME/.paseo — do not also run \`desvio run start\`, or they fight over the port.
$PARALLEL_NOTE
EOF
