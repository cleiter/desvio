#!/usr/bin/env bash
#
# Build the build tree into a real Paseo.app that carries its own daemon.
#
# This produces the bundle and stops. `desvio run install` puts it in place —
# separate because the two fail for unrelated reasons, and retrying a two-second
# copy should not cost a five-minute rebuild.
#
# Usage:  desvio run package
# Env:    PASEO_PACKAGE_VERSION=1.2.3  PASEO_FORK_NAME=plus
#         PASEO_PRODUCT_NAME="Paseo Plus"   name the bundle, to sit beside a stock
#                                           install rather than replace it
#         PASEO_LOGO_PLUS=0|1|auto           badge the icon with a plus; auto (the
#                                           default) means whenever it is renamed
#
# Run `desvio build` FIRST. This packages whatever is in the tree; it does not
# assemble branches, and it does not check whether your gate ever passed.
#
set -euo pipefail

: "${DESVIO_WORKTREE:?run this with: desvio run package}"
BUILD_DIR="$DESVIO_WORKTREE"

# Paseo's own settings live beside this script, not in desvio.conf: desvio is a
# generic tool and what the bundle is called is none of its business. `if`, not
# `&&`, because under `set -e` a false test as the last command kills the script.
PASEO_CONF="${PASEO_CONF:-$(dirname "$DESVIO_CONFIG_FILE")/paseo.conf}"
if [ -f "$PASEO_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PASEO_CONF"
fi

# Naming the bundle is what lets it live in /Applications next to a stock Paseo.
# It renames the BUNDLE ONLY. The app's data does not follow it, and that is on
# purpose here: packages/desktop/src/main.ts hardcodes
#
#   const APP_NAME = process.env.PASEO_TEST_APP_NAME?.trim() || "Paseo";
#   app.setName(APP_NAME);
#
# and userData is derived from that name, not from productName. So both bundles
# read ~/Library/Application Support/Paseo — same hosts, same settings, same
# conversations, whichever icon you click.
#
# The flip side, and the reason this is not a way to run two at once: that
# directory also holds Electron's SingletonLock. Launch the second app while the
# first is running and it hands off to the running instance and quits. One at a
# time. Separating them would mean patching APP_NAME too, and then they would no
# longer share data.
PRODUCT_NAME="${PASEO_PRODUCT_NAME:-Paseo}"
APP_NAME="$PRODUCT_NAME.app"
BUILT_APP="$BUILD_DIR/packages/desktop/release/mac-arm64/$APP_NAME"

# A renamed bundle gets its own appId as well. Two bundles claiming
# sh.paseo.desktop leaves LaunchServices to pick between them for `open -b` and
# for the paseo:// scheme, and it picks the one it feels like. Nothing about the
# app's data is keyed on this — the desktop stores nothing under the bundle id
# and uses no keychain — but macOS grants permissions per bundle id, so the
# renamed app may ask for notifications and the like on its own account.
BUILDER_NAME_ARGS=()
if [ "$PRODUCT_NAME" != "Paseo" ]; then
  slug=$(printf '%s' "$PRODUCT_NAME" | tr '[:upper:]' '[:lower:]' \
         | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//; s/^paseo-//')
  APP_ID="${PASEO_APP_ID:-sh.paseo.desktop.$slug}"
  BUILDER_NAME_ARGS=(-c.productName="$PRODUCT_NAME" -c.appId="$APP_ID")
fi

# Version: upstream's, with this build marked as a prerelease of it.
#
#   0.4.0-plus.260814-0646
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
FORK_NAME="${PASEO_FORK_NAME:-${DESVIO_BRANCH:-plus}}"
UPSTREAM_VERSION=$(node -p "require('$BUILD_DIR/package.json').version" 2>/dev/null || echo "0.0.0")
BUILD_STAMP=$(date '+%y%m%d-%H%M')
VERSION="${PASEO_PACKAGE_VERSION:-$UPSTREAM_VERSION-$FORK_NAME.$BUILD_STAMP}"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log(){  printf '\n\033[1;34m[pkg]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[pkg]\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31m[pkg] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# The product name becomes a path component, and further down it becomes the
# target of an `rm -rf`. It is your own config value rather than anything
# hostile, so this is a typo guard — but a slash in it silently aims that rm at
# a directory you did not mean, which is worth one case statement.
case "$PRODUCT_NAME" in
  ""|.|..) die "PASEO_PRODUCT_NAME cannot be '$PRODUCT_NAME'" ;;
  */*)     die "PASEO_PRODUCT_NAME cannot contain a slash: '$PRODUCT_NAME'
  It names one bundle, so it becomes one path component." ;;
  -*)      die "PASEO_PRODUCT_NAME cannot start with a dash: '$PRODUCT_NAME'
  It would be read as an option by the tools that receive it." ;;
  *..*)    die "PASEO_PRODUCT_NAME cannot contain '..': '$PRODUCT_NAME'" ;;
esac

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
#   Cannot derive native release version from unsupported version: 0.4.0-plus.…
#
# No version string satisfies both that and semver's prerelease rules —
# `-beta.260814` parses there but then fails its own 1..998 beta-number check.
# So widen the pattern in the tree instead and restore it with the manifests.
VERSION_PATTERN_FILE=packages/app/native-release-version.js

# logo-plus rewrites the desktop icons in place, further down. Restored with the
# manifests and for the same reason: the tree is disposable, but a build that
# stopped halfway should not leave a badged icon behind for the next one to badge
# again. Added to RESTORED_FILES below, only when badging actually runs — a run
# with PASEO_LOGO_PLUS=0 never touched this directory and has nothing to restore.
ICON_ASSET_DIR=packages/desktop/assets
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

# ---------- the plus ----------
# "Paseo Plus" wants an icon that says so, or the two bundles in /Applications
# are told apart only by their name. logo-plus draws a superscript plus into
# the top-right of every render in assets/ — the .icns the bundle wears and the
# icon.png electron-builder copies to Resources/ for the window and the dock.
#
# Before the build, not after: electron-builder reads these files, and patching
# the packed bundle afterwards would mean re-signing it a second time and
# fighting macOS's icon cache for the copy Finder already remembered.
#
# Default `auto` — on exactly when the bundle is renamed. A build that still
# calls itself Paseo is replacing the stock app, and badging that one leaves you
# unable to tell a fork build from the real thing.
LOGO_PLUS="${PASEO_LOGO_PLUS:-auto}"
if [ "$LOGO_PLUS" = "auto" ]; then
  [ "$PRODUCT_NAME" != "Paseo" ] && LOGO_PLUS=1 || LOGO_PLUS=0
fi
if [ "$LOGO_PLUS" = "1" ]; then
  if command -v magick >/dev/null 2>&1; then
    RESTORED_FILES+=("$ICON_ASSET_DIR")
    "$(dirname "$DESVIO_CONFIG_FILE")/logo-plus" "$BUILD_DIR" \
      || die "could not badge the icon. Set PASEO_LOGO_PLUS=0 to package with the
  stock icon instead."
  elif [ "${PASEO_LOGO_PLUS:-}" = "1" ]; then
    # Asked for explicitly — silently shipping the stock icon would answer a
    # direct request with the wrong bundle, and say nothing about it.
    die "ImageMagick is not installed — brew install imagemagick
  Or unset PASEO_LOGO_PLUS (or set it to 0) to package with the stock icon."
  else
    # auto resolved to "badge it", but there is nothing to badge with. Degrade
    # rather than fail the whole build over an optional icon.
    warn "ImageMagick is not installed — packaging with the stock icon.
       brew install imagemagick to badge it, or set PASEO_LOGO_PLUS=0 to silence this."
  fi
fi

# ---------- build ----------
# The root `npm run build:desktop` wrapper is not usable: its `cd packages/app`
# runs in a shell whose cwd npm does not leave at the repo root, so it dies with
# "cd: packages/app: No such file or directory". Run the three stages directly.
log "1/3 app deps (clean)"
npm --prefix "$BUILD_DIR" run build:app-deps:clean

log "2/3 expo web export"
( cd "$BUILD_DIR/packages/app" && PASEO_WEB_PLATFORM=electron npx expo export --platform web )

log "3/3 electron-builder (unsigned, no notarization, v$VERSION, $APP_NAME)"
# CSC_IDENTITY_AUTO_DISCOVERY=false: no Developer ID needed.
# -c.mac.target=dir: the .app only. Add dmg/zip if you want to hand it out.
# The ${...[@]+...} guard is for bash 3.2, where expanding an empty array under
# `set -u` is an error rather than nothing.
( cd "$BUILD_DIR" && CSC_IDENTITY_AUTO_DISCOVERY=false npm run build --workspace=@getpaseo/desktop -- \
    -c.mac.notarize=false \
    -c.mac.target=dir \
    -c.extraMetadata.version="$VERSION" \
    ${BUILDER_NAME_ARGS[@]+"${BUILDER_NAME_ARGS[@]}"} )

# electron-builder names the .app directory after executableName, which the
# config pins to "Paseo" and -c.productName does not touch. Do not override that
# too: after-pack.js and after-sign.js both hardcode
#
#   const EXECUTABLE_NAME = "Paseo";  ... path.join(appOutDir, `${EXECUTABLE_NAME}.app`)
#
# and after-pack uses it to find the Resources to prune, which is ~210 MB of
# native modules. Rename it here instead, once the build and its hooks are done.
# Nothing inside cares: the bundle's identity is in Info.plist, where
# -c.productName already set CFBundleName and CFBundleDisplayName, and the
# executable stays Contents/MacOS/Paseo. Rename before the re-sign below, so the
# signature is taken on the bundle as it will be installed.
PACKED_APP="$BUILD_DIR/packages/desktop/release/mac-arm64/Paseo.app"
[ -d "$PACKED_APP" ] || die "electron-builder produced no app at $PACKED_APP"
if [ "$PACKED_APP" != "$BUILT_APP" ]; then
  log "renaming the bundle to $APP_NAME"
  rm -rf "${BUILT_APP:?}"
  mv "$PACKED_APP" "$BUILT_APP"
fi

# ---------- the helper the daemon runs from ----------
# packages/desktop/src/daemon/runtime-paths.ts spawns the supervisor from
#
#   const name = path.basename(process.execPath);            // "Paseo"
#   <bundle>/Contents/Frameworks/${name} Helper.app/Contents/MacOS/${name} Helper
#
# and falls back to process.execPath — the app's OWN binary — when that path does
# not exist. The two are not interchangeable. The helper is LSUIElement with its
# own bundle id; the app binary is not, so a daemon spawned from it checks in to
# LaunchServices as a foreground instance of this app. With keepRunningAfterQuit
# on it then OUTLIVES the window: the Dock tile activates a process that has no
# window and reports "the application is not open anymore", and install.sh's
# running-app check matches the daemon and tells you to quit what you just quit.
#
# The rename is what misses. electron-builder derives the helper name from
# productName ("Paseo Plus Helper"), executableName stays "Paseo", and the
# lookup is built from the executable. A stock build never notices. Same bug,
# upstream: electron-userland/electron-builder#6962 ("Unable to find helper app
# when productName and executableName are set to different names") — check
# whether it still needs a workaround before assuming this one always will.
#
# A copy, not a symlink: the tested path names the executable INSIDE the bundle,
# so that has to match too. 228K, and the re-sign below covers it.
if [ "$PRODUCT_NAME" != "Paseo" ]; then
  SRC_HELPER="$BUILT_APP/Contents/Frameworks/$PRODUCT_NAME Helper.app"
  DAEMON_HELPER="$BUILT_APP/Contents/Frameworks/Paseo Helper.app"
  [ -d "$SRC_HELPER" ] || die "no helper bundle at $SRC_HELPER
  electron-builder names it after productName; if that changed, this rename has
  to change with it or the daemon silently runs from the app binary again."
  log "adding Paseo Helper.app for the daemon"
  rm -rf "${DAEMON_HELPER:?}"
  cp -Rc "$SRC_HELPER" "$DAEMON_HELPER" 2>/dev/null || cp -R "$SRC_HELPER" "$DAEMON_HELPER"
  mv "$DAEMON_HELPER/Contents/MacOS/$PRODUCT_NAME Helper" "$DAEMON_HELPER/Contents/MacOS/Paseo Helper"
  # Its own id: two bundles claiming ...helper is the ambiguity the appId rename
  # above exists to avoid. LSUIElement is inherited from the copy — that is the
  # property that keeps the daemon out of the Dock.
  plutil -replace CFBundleExecutable -string "Paseo Helper" "$DAEMON_HELPER/Contents/Info.plist"
  plutil -replace CFBundleName       -string "Paseo Helper" "$DAEMON_HELPER/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$APP_ID.helper.daemon" "$DAEMON_HELPER/Contents/Info.plist"
fi

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
