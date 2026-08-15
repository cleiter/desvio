#!/usr/bin/env bash
#
# build_guards, lib/cmd-build.sh:237-253. Two jobs: refuse to touch a tree with a
# merge half-finished in it, and wipe local changes in a tree nobody should be
# editing — without wiping the expensive generated directories.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

setup() {
  fixture_new
  topic_branch alpha file.txt "alpha-line"
  fixture_config
  manifest alpha
  run_desvio build          # first build makes the worktree
}

# ---------------------------------------------------------------------------
it "a merge left half-finished stops the next build"
setup
# Recreate the state a conflicted, abandoned merge leaves behind.
git -C "$REPO" checkout -q -B wip origin/main
repo_append file.txt "wip-line"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "wip: conflicting change"
upstream_commit file.txt "upstream-line" "base: third"
run_desvio build --no-resolve   # leaves the conflict in place on purpose

run_desvio build
assert_contains "$OUT" "a merge is in progress" "the next build refuses"
assert_contains "$OUT" "git add -A && git commit --no-edit" "and says how to finish it"

# ---------------------------------------------------------------------------
it "local changes in the build tree are discarded with a warning"
setup
printf 'hand-edited\n' > "$BUILD/build-tree/file.txt"
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "discarding them" "it warns that it threw the edit away"
assert_not_contains "$(cat "$BUILD/build-tree/file.txt")" "hand-edited" "the edit is gone"

# ---------------------------------------------------------------------------
it "an untracked file is cleaned by default"
setup
touch "$BUILD/build-tree/stray.txt"
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if [ -e "$BUILD/build-tree/stray.txt" ]; then
  fail "the stray file is cleaned" "stray.txt survived"
else
  ok "the stray file is cleaned"
fi

# ---------------------------------------------------------------------------
# The difference between a 30-second rebuild and a 5-minute one: node_modules is
# untracked, so without DESVIO_CLEAN_KEEP one stray file wipes it.
it "DESVIO_CLEAN_KEEP preserves what it names"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config 'DESVIO_CLEAN_KEEP="-e node_modules -e dist"'
manifest alpha
run_desvio build

mkdir -p "$BUILD/build-tree/node_modules/pkg" "$BUILD/build-tree/dist"
touch "$BUILD/build-tree/node_modules/pkg/index.js" "$BUILD/build-tree/dist/out.js"
touch "$BUILD/build-tree/stray.txt"
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if [ -e "$BUILD/build-tree/node_modules/pkg/index.js" ]; then
  ok "node_modules survived the clean"
else
  fail "node_modules survived the clean" "it was deleted"
fi
if [ -e "$BUILD/build-tree/dist/out.js" ]; then
  ok "dist survived the clean"
else
  fail "dist survived the clean" "it was deleted"
fi
if [ -e "$BUILD/build-tree/stray.txt" ]; then
  fail "but an unlisted stray file is still cleaned" "stray.txt survived"
else
  ok "but an unlisted stray file is still cleaned"
fi

# ---------------------------------------------------------------------------
# Adopting a worktree means resetting and cleaning it, so desvio may only adopt
# one it made. `git worktree list` includes the PRIMARY checkout, so without an
# ownership check a DESVIO_WORKTREE typo pointing at your own repo takes the
# adopt path and gets reset --hard'd.
it "a DESVIO_WORKTREE pointing at the checkout itself is refused"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha
printf 'DESVIO_WORKTREE="%s"\n' "$REPO" >> "$BUILD/desvio.conf"
repo_append file.txt "precious-uncommitted-work"

run_desvio build
assert_contains "$OUT" "points at the upstream checkout itself" "it refuses"
assert_contains "$(cat "$REPO/file.txt")" "precious-uncommitted-work" \
  "and the uncommitted work in it is untouched"

# ---------------------------------------------------------------------------
it "a worktree on someone else's branch is refused, not adopted"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha
git -C "$REPO" worktree add -q -b other "$TEST_TMP/other" origin/main
printf 'DESVIO_WORKTREE="%s"\n' "$TEST_TMP/other" >> "$BUILD/desvio.conf"
printf 'work-in-progress\n' > "$TEST_TMP/other/file.txt"

run_desvio build
assert_contains "$OUT" "is on 'other'" "it names the branch it found"
assert_contains "$OUT" "worktree remove" "and says how to get rid of it if it is stale"
assert_contains "$(cat "$TEST_TMP/other/file.txt")" "work-in-progress" \
  "the other worktree's changes survive"

# ---------------------------------------------------------------------------
it "a config pointing at a non-checkout is rejected"
fixture_new
fixture_config
manifest
printf 'DESVIO_REPO="%s/not-a-repo"\n' "$TEST_TMP" >> "$BUILD/desvio.conf"
mkdir -p "$TEST_TMP/not-a-repo"
assert_dies_with "not a git checkout" build

# ---------------------------------------------------------------------------
# Found by CI, not by hand: the macOS runner's TMPDIR sits under /var, which is a
# symlink to /private/var. git registers a worktree under the resolved path, so
# handing it the logical one on the rebuild produced
#
#   fatal: cannot force update the branch 'integration' used by worktree at ...
#
# First build fine, every rebuild dead. This test does not depend on TMPDIR being
# symlinked — it makes its own link, so the case is covered everywhere.
it "a build directory reached through a symlink can be rebuilt"
fixture_new
fixture_config
manifest
ln -s "$BUILD" "$TEST_TMP/link"

run_desvio --config "$TEST_TMP/link/desvio.conf" build
assert_eq 0 "$STATUS" "the first build works"
run_desvio --config "$TEST_TMP/link/desvio.conf" build
assert_eq 0 "$STATUS" "and so does the second"
assert_contains "$OUT" "$(cd "$BUILD" && pwd -P)/build-tree" "the worktree is named by its resolved path"

# ---------------------------------------------------------------------------
it "no config at all explains where it looked"
fixture_new
BUILD="$TEST_TMP/empty"; mkdir -p "$BUILD"
unset DESVIO_CONFIG
cd "$BUILD" || exit 1
assert_dies_with "no desvio.conf found" build
run_desvio build
assert_contains "$OUT" "desvio init" "and suggests init"

# ---------------------------------------------------------------------------
# Two concurrent builds share one worktree and one integration branch, so the
# second one's `reset --hard` lands in the middle of the first one's merge.
# Neither build is then the build anybody asked for.
it "a second build refuses to start while one is running"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha

mkdir -p "$BUILD/state/build.lock"
sleep 30 &
holder=$!
printf '%s' "$holder" > "$BUILD/state/build.lock/pid"

run_desvio build
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

assert_contains "$OUT" "another desvio build is already running" "the second build refuses"
assert_contains "$OUT" "pid $holder" "and names the process holding it"
if [ -d "$BUILD/state/build.lock" ]; then
  ok "it leaves the other build's lock alone"
else
  fail "it leaves the other build's lock alone" "the lock was removed"
fi

# ---------------------------------------------------------------------------
# SIGKILL and lost power both leave the directory behind with a pid nobody is
# using. Refusing forever on that would mean hand-deleting a directory to build.
it "a lock left by a dead process is reclaimed"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha

mkdir -p "$BUILD/state/build.lock"
( exit 0 ) &
dead=$!
wait "$dead" 2>/dev/null || true
printf '%s' "$dead" > "$BUILD/state/build.lock/pid"

run_desvio build
assert_eq 0 "$STATUS" "the build runs"
assert_contains "$OUT" "stale build lock" "and says it took a stale lock"

# ---------------------------------------------------------------------------
it "the lock is released when the build finishes"
setup
if [ -e "$BUILD/state/build.lock" ]; then
  fail "no lock is left behind after a successful build" "build.lock survived"
else
  ok "no lock is left behind after a successful build"
fi

# ---------------------------------------------------------------------------
# `die` exits 1, which fires the EXIT trap. If it did not, one bad ref would
# wedge every later build behind a lock nobody holds.
it "the lock is released even when the build dies"
fixture_new
fixture_config
manifest
run_desvio build nosuchref
if [ "$STATUS" -eq 0 ]; then fail "the build fails" "got 0"; else ok "the build fails"; fi
if [ -e "$BUILD/state/build.lock" ]; then
  fail "and the lock is still released" "build.lock survived"
else
  ok "and the lock is still released"
fi

finish
