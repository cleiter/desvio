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
# One build at a time per config: two runs share a worktree and an integration
# branch, so the second one's reset lands inside the first one's merge.
it "a second build refuses while another holds the lock"
setup
mkdir -p "$BUILD/state/build.lock"
printf '%s' "$$" > "$BUILD/state/build.lock/pid"   # this test's own shell: alive

run_desvio build
assert_contains "$OUT" "another desvio build is already running" "it refuses"
assert_contains "$OUT" "$$" "and names the pid holding it"
if [ -d "$BUILD/state/build.lock" ]; then
  ok "the refused build leaves the lock alone"
else
  fail "the refused build leaves the lock alone" "it deleted someone else's lock"
fi

# ---------------------------------------------------------------------------
# A build killed with SIGKILL, or a machine that lost power, leaves the lock
# behind. Refusing forever on a pid nobody is using would be worse than the race.
it "a lock left by a dead process is reclaimed"
setup
( : ) & stale=$!; wait "$stale" 2>/dev/null || true
mkdir -p "$BUILD/state/build.lock"
printf '%s' "$stale" > "$BUILD/state/build.lock/pid"

run_desvio build
assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "stale build lock" "it says it reclaimed one"

# ---------------------------------------------------------------------------
it "the lock is released when the build finishes"
setup
run_desvio build
assert_eq 0 "$STATUS" "the build succeeds"
if [ -d "$BUILD/state/build.lock" ]; then
  fail "the lock is gone afterwards" "build.lock survived a successful build"
else
  ok "the lock is gone afterwards"
fi

# ---------------------------------------------------------------------------
# `die` exits 1, and the trap is on EXIT — so a failed build must not strand the
# lock and refuse every later run.
it "the lock is released even when the build dies"
fixture_new
fixture_config
manifest
run_desvio build nosuchref        # dies resolving the base, after the lock is taken

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
if [ -d "$BUILD/state/build.lock" ]; then
  fail "the lock is gone afterwards" "build.lock survived a failed build"
else
  ok "the lock is gone afterwards"
fi

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

finish
