# Shared helpers. Sourced by bin/desvio before any subcommand.
#
# Everything here is also part of the hook API: a desvio.conf hook may call
# log/warn/die, in_tree, and the stamp_* pair. Treat their signatures as public.

B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'
BLU=$'\033[1;34m'; OFF=$'\033[0m'

# No colour when stdout is not a terminal, so piped output and CI logs stay clean.
if [ ! -t 1 ]; then
  B=""; DIM=""; GRN=""; YEL=""; RED=""; BLU=""; OFF=""
fi

log()  { printf '\n%s[desvio]%s %s\n' "$BLU" "$OFF" "$*"; }
warn() { printf '%s[desvio]%s %s\n' "$YEL" "$OFF" "$*"; }
die()  { printf '\n%s[desvio] ERROR:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# plural <count> <noun> — "1 file", "3 files". Only regular nouns.
plural() {
  if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

rule() {
  printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────────────" "$OFF"
}

# git in the upstream checkout, and git in the build worktree. Hooks get `in_tree`
# for running anything else there.
gitr()    { git -C "$DESVIO_REPO" "$@"; }
gitw()    { git -C "$DESVIO_WORKTREE" "$@"; }
in_tree() { ( cd "$DESVIO_WORKTREE" && "$@" ); }

# ---------- config ----------
#
# desvio.conf is sourced, not parsed: a hook is a bash function, and a config
# value that needs a command substitution should be allowed to have one. It runs
# with your privileges — the same trust you give a Makefile in a repo you cloned.
#
# Search order stops at the first hit:
#   --config <file>          explicit
#   $DESVIO_CONFIG           environment
#   ./desvio.conf            the directory you are standing in
#   $DESVIO_HOME/desvio.conf  ~/.desvio by default
find_config() {
  if [ -n "${DESVIO_CONFIG:-}" ]; then
    [ -f "$DESVIO_CONFIG" ] || die "no config at \$DESVIO_CONFIG: $DESVIO_CONFIG"
    # Absolute, like the ./desvio.conf branch below. Every other path is
    # resolved against this one's directory, and `desvio run` cd's into that
    # directory before running a task — so a config named relatively would
    # leave every derived path pointing somewhere that no longer exists.
    printf '%s/%s' "$(cd "$(dirname "$DESVIO_CONFIG")" && pwd -P)" "$(basename "$DESVIO_CONFIG")"
    return 0
  fi
  if [ -f "./desvio.conf" ]; then
    printf '%s' "$PWD/desvio.conf"
    return 0
  fi
  if [ -f "$DESVIO_HOME/desvio.conf" ]; then
    printf '%s' "$DESVIO_HOME/desvio.conf"
    return 0
  fi
  return 1
}

# Resolve a path relative to the config file rather than the caller's cwd, so a
# config works the same from anywhere.
config_relative() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$(dirname "$DESVIO_CONFIG_FILE")" "$1" ;;
  esac
}

# The same path with every symlink resolved, because git stores a worktree under
# its physical path. Hand it the logical one on the NEXT build and it does not
# recognise the tree as the one it already registered:
#
#   fatal: cannot force update the branch 'x' used by worktree at '/private/...'
#
# So the first build works, every rebuild dies — and only for someone whose build
# directory sits under a symlink, which on macOS includes anything in /tmp or
# /var. Resolve the parent when the path itself does not exist yet: the worktree
# is created by the very command that needs the resolved name.
physical_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
  elif [ -d "$(dirname "$p")" ]; then
    printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
  else
    printf '%s' "$p"
  fi
}

load_config() {
  local file
  file=$(find_config) || die "no desvio.conf found.

  Looked for: \$DESVIO_CONFIG, ./desvio.conf, $DESVIO_HOME/desvio.conf

  Write one with:  desvio init
  Or point at one: desvio --config /path/to/desvio.conf build"

  DESVIO_CONFIG_FILE="$file"
  # shellcheck disable=SC1090
  . "$file"

  [ -n "${DESVIO_REPO:-}" ] || die "DESVIO_REPO is not set in $file — it must point at the upstream checkout"
  DESVIO_REPO="${DESVIO_REPO/#\~/$HOME}"
  # Relative to the CONFIG, like DESVIO_STATE and the rest — not to whatever
  # directory you happened to run desvio from.
  DESVIO_REPO="$(config_relative "$DESVIO_REPO")"
  # Ask git rather than stat a path: .git is a plain directory only in a primary
  # checkout, and a FILE in a linked worktree. A linked worktree is a perfectly
  # good DESVIO_REPO — it shares the object store and the ref namespace, which is
  # all desvio touches — so a stat test rejects it for no reason.
  git -C "$DESVIO_REPO" rev-parse --git-dir >/dev/null 2>&1 ||
    die "DESVIO_REPO is not a git checkout: $DESVIO_REPO"

  DESVIO_REMOTE="${DESVIO_REMOTE:-origin}"
  DESVIO_BRANCH="${DESVIO_BRANCH:-desvio}"
  DESVIO_NAME="${DESVIO_NAME:-$DESVIO_BRANCH}"
  DESVIO_STATE="$(config_relative "${DESVIO_STATE:-state}")"
  DESVIO_WORKTREE="$(physical_path "$(config_relative "${DESVIO_WORKTREE:-build-tree}")")"
  DESVIO_MANIFEST="$(config_relative "${DESVIO_MANIFEST:-manifest.txt}")"
  DESVIO_AUTO_RESOLVE="${DESVIO_AUTO_RESOLVE:-1}"
  DESVIO_RESOLVER_MODEL="${DESVIO_RESOLVER_MODEL:-opus}"
  DESVIO_RESOLVER_EFFORT="${DESVIO_RESOLVER_EFFORT:-high}"
  DESVIO_BASE="${DESVIO_BASE:-$(default_base)}"

  [ -f "$DESVIO_MANIFEST" ] || die "no manifest at $DESVIO_MANIFEST"
  mkdir -p "$DESVIO_STATE"
}

# The remote's own default branch, asked rather than assumed — `main` is not a
# safe guess and neither is `master`. Falls back only if the remote never told us.
default_base() {
  local head
  head=$(gitr symbolic-ref --quiet "refs/remotes/$DESVIO_REMOTE/HEAD" 2>/dev/null) || head=""
  if [ -n "$head" ]; then
    printf '%s' "${head#refs/remotes/}"
    return 0
  fi
  for candidate in master main trunk; do
    if gitr rev-parse --verify --quiet "refs/remotes/$DESVIO_REMOTE/$candidate" >/dev/null; then
      printf '%s/%s' "$DESVIO_REMOTE" "$candidate"
      return 0
    fi
  done
  die "cannot work out the default branch of '$DESVIO_REMOTE'.
  Set DESVIO_BASE in $DESVIO_CONFIG_FILE, or run:
    git -C $DESVIO_REPO remote set-head $DESVIO_REMOTE --auto"
}

# ---------- stamps ----------
#
# For hooks that want to skip expensive work when nothing changed. Deliberately
# two calls: record only after the work SUCCEEDS, or a failed install leaves a
# stamp claiming it is current.
#
#   stamp_changed deps package-lock.json || return 0
#   npm ci && stamp_write deps package-lock.json
# Hash each input's NAME and existence alongside its content, not the raw
# concatenation. `cat a b` cannot tell "a grew a line that b lost" from "nothing
# moved", and — the one that actually bites — `cat missing 2>/dev/null` produces
# exactly the same bytes as an empty file. A deleted package-lock.json would
# hash equal to an empty one and the install would be skipped against stale
# node_modules.
#
# A missing input is recorded as absent rather than being an error: for a
# skip-the-work-if-nothing-changed hint, "the file is gone" means changed, and
# turning a cache miss into a failed build would be the wrong trade.
stamp_digest() {
  local name="$1"; shift
  ( cd "$DESVIO_WORKTREE" || exit 1
    local f
    for f in "$@"; do
      if [ -f "$f" ]; then
        printf '%s\0%s\0' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"
      else
        printf '%s\0absent\0' "$f"
      fi
    done | shasum -a 256 | cut -d' ' -f1 )
}

stamp_changed() {
  local name="$1"; shift
  local file="$DESVIO_STATE/stamp-$name"
  [ "$(cat "$file" 2>/dev/null)" != "$(stamp_digest "$name" "$@")" ]
}

stamp_write() {
  local name="$1"; shift
  stamp_digest "$name" "$@" > "$DESVIO_STATE/stamp-$name"
}

# resolver_log <topic> — where a resolver transcript for that branch lives.
#
# One helper rather than the same expression in three places, because all three
# have to agree or the message tells you to open a file that is not there.
# Slashes become dashes: `feature/foo` is the commonest branch convention there
# is, and a slash in a filename is a directory that does not exist, so `tee`
# fails and the transcript is lost — on the error path, where it is the only
# record of what the resolver was thinking when it gave up.
resolver_log() { printf '%s/resolve-%s.log' "$DESVIO_STATE" "${1//\//-}"; }

# ---------- hooks ----------
# has_hook <name> — is it defined by the config?
has_hook() { declare -f "$1" >/dev/null 2>&1; }

# run_hook <name> [args...] — call it if defined, otherwise do nothing.
run_hook() {
  local name="$1"; shift
  has_hook "$name" || return 0
  "$name" "$@"
}
