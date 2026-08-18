# shellcheck shell=bash
# Shared helpers. Sourced by bin/desvio before any subcommand.
#
# Everything here is also part of the hook API: a desvio.conf hook may call
# log/warn/die, in_tree, and the stamp_* pair. Treat their signatures as public.

B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'
BLU=$'\033[1;34m'; OFF=$'\033[0m'

# No colour when stdout is not a terminal, so piped output and CI logs stay clean.
# shellcheck disable=SC2034  # read by cmd-build.sh's summary, a separate file
if [ ! -t 1 ]; then
  B=""; DIM=""; GRN=""; YEL=""; RED=""; BLU=""; OFF=""
fi

log()  { printf '\n%s[desvio]%s %s\n' "$BLU" "$OFF" "$*"; }
warn() { printf '%s[desvio]%s %s\n' "$YEL" "$OFF" "$*"; }
die()  { printf '\n%s[desvio] ERROR:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# Which manifest line the build is on, as "[3/7] ". Set by the merge loop and
# empty everywhere else, so a line printed outside the loop cannot be tagged with
# a stale position. Everything the loop says about a branch goes through these
# two — including the resolver's, which can arrive minutes after the line above
# it and until now did not say which branch it was working on.
DESVIO_STEP=""
step()      { log  "  $DESVIO_STEP$*"; }
step_warn() { warn "  $DESVIO_STEP$*"; }

# plural <count> <noun> — "1 file", "3 files", "3 branches".
#
# The -es case is not pedantry: "branch" is the noun this tool says most often,
# and "3 branchs" in the middle of an error message reads as a typo in the tool
# rather than as information. Still only regular nouns beyond that.
plural() {
  if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; return 0; fi
  case "$2" in
    *ch|*sh|*s|*x|*z) printf '%s %ses' "$1" "$2" ;;
    *)                printf '%s %ss'  "$1" "$2" ;;
  esac
}

rule() {
  printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────────────" "$OFF"
}

# Is there a human here to answer a question?
#
# Both ends have to be a terminal: stdout so the question is visible, stdin
# because that is where the answer is read from. A build in CI, in a cron job,
# or with its output piped has neither and must never stop for input.
#
# DESVIO_INTERACTIVE overrides the detection in both directions — `0` for a
# wrapper that runs desvio on a terminal but wants no questions, `1` for one
# that answers them on stdin. It is also how the test suite exercises the
# prompts, which otherwise no test could reach.
interactive() {
  case "${DESVIO_INTERACTIVE:-}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  [ -t 0 ] && [ -t 1 ]
}

# git in the upstream checkout, and git in the build worktree. Hooks get `in_tree`
# for running anything else there.
gitr()    { git -C "$DESVIO_REPO" "$@"; }
gitw()    { git -C "$DESVIO_WORKTREE" "$@"; }
in_tree() { ( cd "$DESVIO_WORKTREE" && "$@" ); }

# ---------- topics ----------
#
# A manifest line names either a local branch — `feature-x` — or a branch on a
# remote — `fork/feature-x`, `origin/pull/3206/head`. Local wins, so a bare name
# means today exactly what it has always meant, and a slashed one only reaches a
# remote when no local branch owns that name.
#
# NOT a bare `rev-parse --verify <name>`. git's own disambiguation would do
# local-then-remote for us, but gitrevisions(7) checks refs/tags/ BEFORE
# refs/heads/ — so a tag `v1.4` would silently shadow a branch `v1.4` in your
# manifest, and you would build the wrong commit with no message at all.
#
# resolve_topic <name> — sets RESOLVED_OID and RESOLVED_FROM (`local`/`remote`),
# and returns non-zero when nothing answers.
#
# Two globals rather than printing the OID, because the caller needs BOTH answers
# and a printed one would have to be read through `$(...)` — a subshell, where an
# assignment to RESOLVED_FROM dies with the subshell and never reaches the
# caller. Asking a second time instead is not an option: the two lookups could
# straddle a branch moving, and then the OID merged and the provenance reported
# would come from two different moments.
# shellcheck disable=SC2034  # RESOLVED_OID/RESOLVED_FROM are read by resolve_manifest in cmd-build.sh
resolve_topic() {
  RESOLVED_FROM=""
  if RESOLVED_OID=$(gitr rev-parse --verify --quiet "refs/heads/$1^{commit}"); then
    RESOLVED_FROM=local
    return 0
  fi
  if RESOLVED_OID=$(gitr rev-parse --verify --quiet "refs/remotes/$1^{commit}"); then
    RESOLVED_FROM=remote
    return 0
  fi
  RESOLVED_OID=""
  return 1
}

# remote_of <name> — the configured remote that owns this line, or nothing.
#
# LONGEST match wins, and that is not pedantry: a remote can be named
# `team/alice` (git 2.54 stopped ADDING one next to a remote `team`, but it still
# reads the pairs older git wrote). With both configured, `${name%%/*}` would
# answer `team` for a line belonging to `team/alice` — so desvio would fetch the
# wrong remote and then report the branch as missing.
remote_of() {
  local name="$1" r best=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$name" in
      "$r"/*) [ "${#r}" -gt "${#best}" ] && best="$r" ;;
    esac
  done < <(gitr remote)
  printf '%s' "$best"
}

# fetch_topic_ref <remote> <rest> — fetch one ref explicitly, into the place
# resolve_topic will look for it.
#
# Only called when the ordinary lookup already missed, so it costs nothing on the
# normal path. Two things land here:
#
#   1. A remote whose configured refspec does not cover the branch — a
#      single-branch clone, or `git remote add -t main`. `git fetch <remote>`
#      obeys that refspec, so the branch never arrives and desvio would report it
#      as a branch that does not exist.
#   2. A ref outside refs/heads entirely: `origin/pull/3206/head`. No forge is
#      recognised here and none needs to be — the line says where the ref lives,
#      and GitHub, GitLab and Gerrit all just work out of the same two attempts.
fetch_topic_ref() {
  local remote="$1" rest="$2" src
  for src in "refs/heads/$rest" "refs/$rest"; do
    if gitr fetch --quiet "$remote" "+$src:refs/remotes/$remote/$rest" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

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
    #
    # Absolute, NOT physical. `pwd -P` here would rewrite the whole config's
    # world: on macOS $TMPDIR is /var/folders/…, a symlink to /private/var, so
    # every path desvio reports and exports would come back spelled differently
    # from the one you gave it. Symlink resolution belongs to physical_path, and
    # only to the worktree, because that is the one place git demands it.
    printf '%s/%s' "$(cd "$(dirname "$DESVIO_CONFIG")" && pwd)" "$(basename "$DESVIO_CONFIG")"
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
#
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

# bisect_log <k> <oid> — where one gate probe's output lives. A helper for the
# same reason resolver_log is one: three places print this path, and if they
# disagree the message tells you to open a file that is not there.
bisect_log() { printf '%s/bisect-%s-%s.log' "$DESVIO_STATE" "$1" "${2:0:9}"; }

# ---------- hooks ----------
# has_hook <name> — is it defined by the config?
has_hook() { declare -f "$1" >/dev/null 2>&1; }

# run_hook <name> [args...] — call it if defined, otherwise do nothing.
run_hook() {
  local name="$1"; shift
  has_hook "$name" || return 0
  "$name" "$@"
}

# run_gate <name> — run a hook and SURVIVE its failure. Sets GATE_STATUS.
#
# Three things here are load-bearing, and two of them are not obvious:
#
#   1. It reports through a global rather than returning. A function that
#      RETURNS non-zero is, under `set -e`, indistinguishable from a crash: it
#      kills the script at the call site. The caller has to be able to write
#      `run_gate desvio_verify` as a bare command and still be alive on the
#      next line, which is the whole point.
#
#   2. It is NOT written `"$name" || GATE_STATUS=$?`. A command on the left of
#      `||` runs with errexit disabled, and that disabling reaches all the way
#      INSIDE the hook — past an explicit `set -e` in a subshell, too. A
#      two-command gate whose first command fails would then run its second
#      command anyway and report the SECOND one's status. For the gate this
#      tool exists to protect, that is: typecheck fails, lint runs anyway, lint
#      passes, build reports GREEN. Measured on bash 3.2.57 and 5.3.15:
#
#        h(){ echo first; false; echo "SECOND RAN"; }
#        ( set -e; h ) || s=$?             → first / SECOND RAN / status=0
#        set +e; ( set -e; h ); s=$?       → first / status=1
#
#   3. So: `set +e` on the OUTER shell, and a foreground subshell that arms
#      `set -e` for itself. Nothing is part of a `||` list, so the arming
#      sticks and the hook still aborts at its first failing command, exactly
#      as it does when called through run_hook.
#
# A background subshell with `wait $!` reports the right status too, and is
# rejected: an async subshell in a non-interactive shell ignores SIGINT, so
# Ctrl-C during a five-minute typecheck would kill desvio and leave npm running.
#
# The subshell means a gate hook's variable assignments do not escape. Hooks
# already communicate by file (stamp_write) and exit status, so that costs
# nothing today — but it is the one way desvio_verify differs from the other
# four hooks, and the next person to add a hook should know it.
# shellcheck disable=SC2034  # GATE_STATUS is read by cmd-build.sh and bisect.sh
run_gate() {
  local name="$1"
  set +e
  ( set -e; "$name" )
  GATE_STATUS=$?
  set -e
  return 0
}
