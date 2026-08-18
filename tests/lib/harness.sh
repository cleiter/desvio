# shellcheck shell=bash
# Test harness. Sourced by every tests/test-*.sh.
#
# Plain bash on purpose: desvio installs with a symlink and needs nothing but
# bash and git, and a suite that needs a package manager undercuts that claim.
#
# NOT `set -e`. An assertion has to be able to fail without taking the rest of
# the file with it — that is the whole point of counting failures.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESVIO_SRC="$(cd "$HARNESS_DIR/../.." && pwd)"
DESVIO_BIN="$DESVIO_SRC/bin/desvio"

PASS=0; FAIL=0; CURRENT=""
FIXTURE_ROOTS=()

# ---------- reporting ----------
it()   { CURRENT="$1"; }

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "${1:-$CURRENT}"; return 0; }

# fail <name> [detail]
#
# Dumps the last desvio output too. `assert_eq 0 "$STATUS"` on its own reports
# "expected 0, got 255" and nothing else, which is unactionable on a machine you
# cannot reach — and CI is exactly that machine.
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "${1:-$CURRENT}"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/          /'; fi
  case "${2:-}" in
    *"in output:"*) ;;                      # assert_contains already showed it
    *) if [ -n "${OUT:-}" ]; then
         printf '          --- last desvio output ---\n'
         printf '%s\n' "$OUT" | tail -30 | sed 's/^/          /'
       fi ;;
  esac
  return 0
}

finish() {
  printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
  printf 'RESULT %d %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# ---------- assertions ----------
assert_eq() {
  if [ "$1" = "$2" ]; then ok "${3:-$CURRENT}"
  else fail "${3:-$CURRENT}" "expected: $1
     got: $2"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ok "${3:-$CURRENT}" ;;
    *) fail "${3:-$CURRENT}" "expected to find: $2
in output:
$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-$CURRENT}" "should NOT contain: $2
in output:
$1" ;;
    *) ok "${3:-$CURRENT}" ;;
  esac
}

# ---------- running desvio ----------
# Sets OUT (stdout+stderr) and STATUS. Never fails itself, so a non-zero exit is
# something a test asserts about rather than something that aborts the file.
run_desvio() {
  OUT="$("$DESVIO_BIN" "$@" 2>&1)"; STATUS=$?
  return 0
}

# run_desvio_answering <input> <desvio args...> — a run with a human on the
# other end. DESVIO_INTERACTIVE=1 is what makes desvio ask its questions at all:
# a test captures stdout through $(...), so the terminal detection interactive()
# does by itself is false here and always will be. <input> is what gets typed;
# pass "" for a bare Enter, and plain run_desvio for a stdin that is closed.
run_desvio_answering() {
  local input="$1"; shift
  OUT="$(printf '%s\n' "$input" | DESVIO_INTERACTIVE=1 "$DESVIO_BIN" "$@" 2>&1)"; STATUS=$?
  return 0
}

# assert_dies_with <pattern> <desvio args...>
assert_dies_with() {
  local want="$1"; shift
  run_desvio "$@"
  if [ "$STATUS" -eq 0 ]; then
    fail "$CURRENT" "expected non-zero exit, got 0
$OUT"
    return 0
  fi
  assert_contains "$OUT" "$want"
}

# ---------- fixtures ----------
#
# fixture_new — a throwaway world: an isolated HOME, a bare origin, a clone of it
# to stand in for the user's checkout, and a build directory with a config.
#
# The bare-plus-clone shape is not incidental. cmd_build runs `git fetch origin
# --prune` and default_base reads refs/remotes/origin/HEAD, so a fixture with no
# real remote would skip the code that actually runs in anger.
fixture_new() {
  # Strip the trailing slash: the macOS runner's TMPDIR has one, and without this
  # every fixture path carries a `//` that `cd` silently collapses — so $PWD stops
  # matching $BUILD and fourteen assertions fail for a reason that is not desvio.
  local tmproot="${TMPDIR:-/tmp}"
  TEST_TMP="$(mktemp -d "${tmproot%/}/desvio-test.XXXXXX")"
  FIXTURE_ROOTS+=("$TEST_TMP")

  # Isolation. Without GIT_CONFIG_GLOBAL the developer's own rerere settings,
  # hooks and templates leak in and a test can pass or fail for reasons that have
  # nothing to do with desvio.
  export HOME="$TEST_TMP/home"
  export DESVIO_HOME="$TEST_TMP/home/.desvio"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=desvio-test  GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=desvio-test GIT_COMMITTER_EMAIL=test@example.invalid
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
  unset DESVIO_CONFIG

  ORIGIN="$TEST_TMP/origin.git"
  SEED="$TEST_TMP/seed"
  REPO="$TEST_TMP/checkout"

  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$SEED"
  (
    cd "$SEED" || exit 1
    printf 'one\n'    > file.txt
    printf 'shared\n' > shared.txt
    git add -A && git commit -qm "base: initial"
    printf 'two\n' >> file.txt
    git add -A && git commit -qm "base: second"
    git remote add origin "$ORIGIN"
    git push -q origin main
  )
  git clone -q "$ORIGIN" "$REPO"
  git -C "$REPO" remote set-head origin --auto >/dev/null

  # Stand inside the fixture. A path-less write in a test then lands here rather
  # than in the source checkout — which is a mistake worth making impossible.
  cd "$TEST_TMP" || return 1
}

# repo_append <file> <line> — edit a file in the checkout. Always use this rather
# than a bare `>> file`, whose target depends on the caller's cwd.
repo_append() { printf '%s\n' "$2" >> "$REPO/$1"; }

fixture_cleanup() {
  local root
  for root in ${FIXTURE_ROOTS+"${FIXTURE_ROOTS[@]}"}; do
    # Worktrees live under $REPO/.git, which is inside the root, so one rm does it.
    [ -n "$root" ] && rm -rf "$root"
  done
}
trap fixture_cleanup EXIT

# upstream_commit <file> <line> <subject> — move origin/main forward.
upstream_commit() {
  (
    cd "$SEED" || exit 1
    printf '%s\n' "$2" >> "$1"
    git add -A && git commit -qm "$3"
    git push -q origin main
  )
}

# topic_branch <name> <file> <line> [from] — a local branch in the checkout.
topic_branch() {
  local name="$1" file="$2" line="$3" from="${4:-origin/main}"
  git -C "$REPO" checkout -q -B "$name" "$from"
  printf '%s\n' "$line" >> "$REPO/$file"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$name: change $file"
  git -C "$REPO" checkout -q main
}

# topic_branch_delete <name> <file> [from] — a local branch that DELETES a file.
#
# The fixture for the one conflict git cannot record. Merge this into a branch
# that modified the same file and the index gets stages 1 and 2 with no 3, no
# conflict markers anywhere, and nothing in rerere's cache however many times
# you resolve it.
topic_branch_delete() {
  local name="$1" file="$2" from="${3:-origin/main}"
  git -C "$REPO" checkout -q -B "$name" "$from"
  git -C "$REPO" rm -q "$file"
  git -C "$REPO" commit -qm "$name: delete $file"
  git -C "$REPO" checkout -q main
}

# topic_branch_rename <name> <from-file> <to-file> [from] — a branch that MOVES a
# file. Merged against a branch that modified it, git presents the old path with
# a stage missing, exactly like a plain deletion — which is why the classifier
# has to ask about renames rather than trust the stage count.
topic_branch_rename() {
  local name="$1" file="$2" dest="$3" from="${4:-origin/main}"
  git -C "$REPO" checkout -q -B "$name" "$from"
  git -C "$REPO" mv "$file" "$dest"
  git -C "$REPO" commit -qm "$name: move $file to $dest"
  git -C "$REPO" checkout -q main
}

# ---------- other people's repositories ----------
#
# A manifest line can name a branch on a remote that is not $DESVIO_REMOTE. The
# fixture for that is a SECOND bare repo, cloned from $ORIGIN so its history is
# compatible, plus a work clone to author commits in — pushing to a bare repo
# needs somewhere to commit first.
#
# Deliberately no fetch after `git remote add`: several tests exist to prove that
# desvio does the fetching, and a fixture that pre-fetched would pass them for
# the wrong reason.

# fork_remote <name> — a second remote, registered in the checkout, never fetched.
# Slashes are legal in a remote name (`team/alice`), so the on-disk path flattens
# them while the remote keeps the real name.
#
# `git remote add` since 2.54 refuses a name that is a prefix of an existing
# remote, or has one as its prefix ("is a subset of existing remote 'team'").
# Such a pair is still perfectly readable — older git added it happily, and so
# does `git config` today — so registering it by hand is not cheating the test:
# it builds the repository a user on 2.53 would hand to desvio on 2.54.
fork_remote() {
  local name="$1" safe="${1//\//-}"
  git clone -q --bare "$ORIGIN" "$TEST_TMP/$safe.git"
  git clone -q "$TEST_TMP/$safe.git" "$TEST_TMP/$safe-work"
  if ! git -C "$REPO" remote add "$name" "$TEST_TMP/$safe.git" 2>/dev/null; then
    git -C "$REPO" config "remote.$name.url" "$TEST_TMP/$safe.git"
    git -C "$REPO" config "remote.$name.fetch" \
      "+refs/heads/*:refs/remotes/$name/*"
  fi
}

# fork_branch <remote> <branch> <file> <line> — author a commit on that fork and
# push it there. Nothing about it reaches $REPO until desvio fetches.
#
# Called twice for the same branch, the second commit STACKS on the first rather
# than replacing it — that is what a fork actually does between your builds, and
# resetting to origin/main instead would make the push a rejected non-fast-forward.
fork_branch() {
  local branch="$2" file="$3" line="$4" w start
  w="$TEST_TMP/${1//\//-}-work"
  git -C "$w" fetch -q origin
  if git -C "$w" rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    start="origin/$branch"
  else
    start="origin/main"
  fi
  git -C "$w" checkout -q -B "$branch" "$start"
  printf '%s\n' "$line" >> "$w/$file"
  git -C "$w" add -A
  git -C "$w" commit -qm "$branch: change $file"
  git -C "$w" push -q origin "$branch"
}

# fork_pr_ref <remote> <N> <file> <line> — the same, pushed to refs/pull/<N>/head
# instead of a branch. No default refspec fetches that, which is the point.
fork_pr_ref() {
  local n="$2" file="$3" line="$4" w
  w="$TEST_TMP/${1//\//-}-work"
  git -C "$w" checkout -q -B "pr-$n" origin/main
  printf '%s\n' "$line" >> "$w/$file"
  git -C "$w" add -A
  git -C "$w" commit -qm "pr $n: change $file"
  git -C "$w" push -q origin "HEAD:refs/pull/$n/head"
}

# fork_delete_branch <remote> <branch> — the fork drops a branch, as happens the
# day a PR lands.
fork_delete_branch() {
  local w; w="$TEST_TMP/${1//\//-}-work"
  git -C "$w" push -q origin ":$2"
}

# break_remote <name> — point it at a path that does not exist, which is what a
# deleted, renamed or gone-private fork looks like from here.
break_remote() { git -C "$REPO" remote set-url "$1" "$TEST_TMP/gone.git"; }

# tree_has <file> <text> — is that line in the build tree's copy of the file?
tree_has() { grep -q "^$2\$" "$WORKTREE/$1" 2>/dev/null; }

# fixture_config [extra conf lines...] — writes the build dir's desvio.conf and
# points $DESVIO_CONFIG at it. Auto-resolve is OFF by default: a test must never
# reach the real agent, which costs money and is not deterministic.
fixture_config() {
  BUILD="$TEST_TMP/build"
  mkdir -p "$BUILD"
  cat > "$BUILD/desvio.conf" <<EOF
DESVIO_REPO="$REPO"
DESVIO_BRANCH="integration"
DESVIO_NAME="test build"
DESVIO_AUTO_RESOLVE=0
EOF
  if [ $# -gt 0 ]; then printf '%s\n' "$@" >> "$BUILD/desvio.conf"; fi
  : > "$BUILD/manifest.txt"
  export DESVIO_CONFIG="$BUILD/desvio.conf"
  # shellcheck disable=SC2034  # read by the tests/test-*.sh that source this
  WORKTREE="$BUILD/build-tree"
}

# manifest <line...> — replace manifest.txt. No trailing newline handling here;
# a test that cares writes the file itself with printf.
manifest() {
  : > "$BUILD/manifest.txt"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" >> "$BUILD/manifest.txt"; fi
}

# A stand-in for the agent: keeps both sides and removes every marker. Emitted as
# config text so a test can append it to desvio.conf. No test may ever reach the
# real resolver — it costs money and is not deterministic.
#
# NUL-delimited, like the code it stands in for. `for f in $(...)` word-splits,
# so a conflicted "my file.txt" becomes "my" and "file.txt" — and this helper is
# what tests/test-paths.sh uses to prove desvio handles such names, so a helper
# that could not handle them would fail the test for its own reasons.
resolver_keep_both() {
  cat <<'CONF'
desvio_resolve_conflict() {
  local f
  while IFS= read -r -d '' f; do
    sed -e '/^<<<<<<</d' -e '/^=======$/d' -e '/^>>>>>>>/d' \
      "$DESVIO_WORKTREE/$f" > "$DESVIO_WORKTREE/$f.resolved"
    mv "$DESVIO_WORKTREE/$f.resolved" "$DESVIO_WORKTREE/$f"
  done < <(gitw diff --name-only --diff-filter=U -z)
  return 0
}
CONF
}

# refs_of — every local branch and its OID in the checkout, sorted. The thing the
# ref-safety tests compare before and after.
refs_of() {
  git -C "$REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort
}

# Same, minus the integration branch — the one ref desvio is allowed to move.
refs_of_topics() { refs_of | grep -v '^refs/heads/integration '; }

oid_of() { git -C "$REPO" rev-parse "$1"; }
