#!/usr/bin/env bash
#
# Build the build tree into a real Paseo.app that carries its own daemon.
#
# This produces the bundle and stops. `desvio run install` puts it in place —
# separate because the two fail for unrelated reasons, and retrying a two-second
# copy should not cost a five-minute rebuild.
#
# Usage:  desvio run package
# Env:    PASEO_PACKAGE_VERSION=1.2.3  PASEO_FORK_NAME=mine
#
# Run `desvio build` FIRST. This packages whatever is in the tree; it does not
# assemble branches, and it does not check whether your gate ever passed.
#
set -euo pipefail

: "${DESVIO_WORKTREE:?run this with: desvio run package}"
BUILD_DIR="$DESVIO_WORKTREE"

APP_NAME="Paseo.app"
BUILT_APP="$BUILD_DIR/packages/desktop/release/mac-arm64/$APP_NAME"

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

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[pkg]\033[0m %s\n' "$*"; }
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

BUILT_FROM=$(git -C "$BUILD_DIR" log -1 --format='%h %s' 2>/dev/null || echo unknown)

cat <<EOF

$(printf '\033[1;34m[pkg]\033[0m') built $BUILT_APP
       version:    $VERSION   (upstream $UPSTREAM_VERSION)
       built from: $BUILT_FROM

The bundle survives a rebuild — release/ is gitignored, and desvio's clean does
not use -x — so installing is a separate decision you can take whenever:

  desvio run install

Or the whole path in one go next time:

  desvio build && desvio run package install
EOF
