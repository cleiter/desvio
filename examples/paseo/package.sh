#!/usr/bin/env bash
#
# Package the build tree into a real Paseo.app that carries its own daemon.
#
# This is the point of packaging: the app stops reading the build tree. The tree
# becomes a build input, no process has its cwd inside it, and `desvio build`'s
# live-daemon guard never fires again — so you can rebuild whenever you like and
# install the result when it suits you.
#
# Usage:  ./package.sh [--no-install]
# Env:    PASEO_APP_DEST=/Applications  PASEO_PACKAGE_VERSION=1.2.3
#
# Run `desvio build` FIRST. This packages whatever is in the tree; it does not
# assemble branches.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/desvio.conf"
case "${DESVIO_WORKTREE:-build-tree}" in
  /*) BUILD_DIR="$DESVIO_WORKTREE" ;;
  *)  BUILD_DIR="$HERE/${DESVIO_WORKTREE:-build-tree}" ;;
esac

DEST_DIR="${PASEO_APP_DEST:-/Applications}"
APP_NAME="Paseo.app"
BUILT_APP="$BUILD_DIR/packages/desktop/release/mac-arm64/$APP_NAME"
USER_DATA="$HOME/Library/Application Support/Paseo"

# Version: upstream's, with this build marked as a prerelease of it.
#
#   0.4.0-mine.260814-0646
#   ^^^^^ upstream base   ^^^^^^^^^^^^ whose build, and when
#
# Same shape as upstream's own `0.4.0-beta.2`: a dot after the name, exactly like
# beta's counter. The stamp is `yymmdd-HHMM` and NOT `260814.0646` — semver
# forbids leading zeroes in a numeric identifier, so `.0646` is invalid while
# `260814-0646` is one alphanumeric identifier and passes.
#
# Precedence: this ranks BELOW upstream's stable release of the same number,
# because every prerelease loses to its own release. That is only safe because
# the bundled updater cannot run at all — see the app-update.yml check below.
FORK_NAME="${PASEO_FORK_NAME:-${DESVIO_BRANCH:-mine}}"
UPSTREAM_VERSION=$(node -p "require('$BUILD_DIR/package.json').version" 2>/dev/null || echo "0.0.0")
BUILD_STAMP=$(date '+%y%m%d-%H%M')
VERSION="${PASEO_PACKAGE_VERSION:-$UPSTREAM_VERSION-$FORK_NAME.$BUILD_STAMP}"
INSTALL=1

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[pkg]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[pkg]\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31m[pkg] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$BUILD_DIR" ] || die "no build tree at $BUILD_DIR — run desvio build first"
[ "$(uname -m)" = "arm64" ] || die "this script only builds the arm64 bundle"

# ---------- stamp the version ----------
# `-c.extraMetadata.version` rewrites ONLY the packaged root package.json, which
# is what app.getVersion(), the Info.plist and the updater read. Two other
# versions are read at runtime from their own package.json and are untouched:
#
#   packages/app     resolveAppVersion() imports ../../package.json directly, so
#                    Metro inlines it at export time — stamp it BEFORE the export
#                    or the About screen keeps showing plain upstream.
#   packages/server  the daemon walks up to @getpaseo/server/package.json at
#                    runtime (server/package-version.ts).
#
# Stamp BOTH or neither. isVersionMismatch is a plain string comparison, so
# stamping only the app trades a stale version label for a permanent "app and
# daemon versions differ" warning.
#
# Safe to rewrite because every cross-package dependency is "*", so no range
# stops matching. The tree is disposable, but restore on the way out anyway so a
# half-finished package leaves no dirt.
STAMPED_MANIFESTS=(packages/app/package.json packages/server/package.json)

# app.config.js runs getNativeReleaseVersion(pkg.version) whenever the Expo
# config loads — including a web-only export, which never uses the Android
# versionCode or iOS buildNumber it derives. Its pattern accepts `X.Y.Z` and
# `X.Y.Z-beta.N` and nothing else, so a stamped fork version aborts the export:
#
#   Cannot derive native release version from unsupported version: 0.4.0-mine.…
#
# No version string satisfies both that and semver's prerelease rules —
# `-beta.260814` parses there but then fails its own 1..998 beta-number check.
# So widen the pattern in the tree instead and restore it with the manifests.
VERSION_PATTERN_FILE=packages/app/native-release-version.js
RESTORED_FILES=("${STAMPED_MANIFESTS[@]}" "$VERSION_PATTERN_FILE")

restore_manifests() {
  git -C "$BUILD_DIR" checkout -- "${RESTORED_FILES[@]}" 2>/dev/null || true
}

log "stamping $VERSION"
trap restore_manifests EXIT
for manifest in "${STAMPED_MANIFESTS[@]}"; do
  node -e '
    const fs = require("node:fs");
    const [file, version] = process.argv.slice(1);
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.version = version;
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  ' "$BUILD_DIR/$manifest" "$VERSION" || die "could not stamp $manifest"
done

node -e '
  const fs = require("node:fs");
  const [file] = process.argv.slice(1);
  const source = fs.readFileSync(file, "utf8");
  const from = "/^(\\d+)\\.(\\d+)\\.(\\d+)(?:-beta\\.(\\d+))?$/";
  const to = "/^(\\d+)\\.(\\d+)\\.(\\d+)(?:-beta\\.(\\d+))?(?:[-+][0-9A-Za-z.-]+)?$/";
  if (!source.includes(from)) {
    throw new Error("version pattern not found — upstream changed it, re-check the patch");
  }
  fs.writeFileSync(file, source.replace(from, to));
' "$BUILD_DIR/$VERSION_PATTERN_FILE" || die "could not widen the native version pattern"

# ---------- build ----------
# The root `npm run build:desktop` wrapper is not usable: its `cd packages/app`
# runs in a shell whose cwd npm does not leave at the repo root, so it dies with
# "cd: packages/app: No such file or directory". Run the three stages directly.
log "1/3 app deps (clean)"
npm --prefix "$BUILD_DIR" run build:app-deps:clean

log "2/3 expo web export"
( cd "$BUILD_DIR/packages/app" && PASEO_WEB_PLATFORM=electron npx expo export --platform web )

log "3/3 electron-builder (unsigned, no notarization, v$VERSION)"
# CSC_IDENTITY_AUTO_DISCOVERY=false: no Developer ID needed.
# -c.mac.target=dir: the .app only. Add dmg/zip if you want to hand it out.
( cd "$BUILD_DIR" && CSC_IDENTITY_AUTO_DISCOVERY=false npm run build --workspace=@getpaseo/desktop -- \
    -c.mac.notarize=false \
    -c.mac.target=dir \
    -c.extraMetadata.version="$VERSION" )

[ -d "$BUILT_APP" ] || die "electron-builder produced no app at $BUILT_APP"

# ---------- disarm the updater ----------
# electron-builder.yml publishes to getpaseo/paseo and auto-updater.ts sets
# autoDownload = true, so a working updater would replace this build with stock
# Paseo — and it WOULD, because the version above is a prerelease of upstream's
# and therefore ranks below it. What stops it is that electron-updater needs
# app-update.yml from the bundle's resources, and `-c.mac.target=dir` publishes
# nothing, so none is written. Assert that rather than assume it: add a dmg or
# zip target one day and this fires instead of silently arming the updater.
UPDATER_CFG=$(find "$BUILT_APP" -name "app-update.yml" 2>/dev/null | head -1 || true)
if [ -n "$UPDATER_CFG" ]; then
  die "the bundle ships an updater config:
    $UPDATER_CFG
  With a prerelease version, upstream's stable release outranks this build and
  the updater would overwrite it. Delete that file, or set PASEO_PACKAGE_VERSION
  to something that outranks upstream, before installing this."
fi

# ---------- re-sign ----------
# electron-builder's ad-hoc fallback signs ONLY the outer binary. The bundled
# Electron Framework keeps Electron's team ID, and dyld refuses to map a binary
# with a different Team ID into an ad-hoc process:
#   Library not loaded: @rpath/Electron Framework.framework/Electron Framework
#   ... mapping process and mapped file (non-platform) have different Team IDs
# The app dies at launch, before any of its own code runs. Re-sign everything.
log "re-signing the whole bundle ad-hoc"
codesign --force --deep --sign - "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP" || die "the bundle does not verify after re-signing"

if [ "$INSTALL" != "1" ]; then
  log "built (not installed): $BUILT_APP"
  exit 0
fi

# ---------- install ----------
if pgrep -f "$DEST_DIR/$APP_NAME/Contents/MacOS/Paseo" >/dev/null 2>&1; then
  die "Paseo is running from $DEST_DIR. Quit it first — replacing a running
  bundle leaves the live process reading files that no longer exist."
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

log "installing to $DEST_DIR/$APP_NAME"
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

BUILT_FROM=$(git -C "$BUILD_DIR" log -1 --format='%h %s' 2>/dev/null || echo unknown)

cat <<EOF

$(printf '\033[1;34m[pkg]\033[0m') installed $DEST_DIR/$APP_NAME
       version:    $VERSION   (upstream $UPSTREAM_VERSION)
       built from: $BUILT_FROM

Launch it:  open -n "$DEST_DIR/$APP_NAME"

The host registry lives in the same userData dir, so the hosts you already added
are still there. The daemon this app starts is its own, on 6767, against
\$HOME/.paseo — do not also run start.sh, or they fight over the port.
EOF
