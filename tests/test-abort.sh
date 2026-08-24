#!/usr/bin/env bash
#
# desvio abort, lib/cmd-abort.sh. The way out of a conflict you do not want to
# resolve — the one thing that used to need cd-ing into the build tree by hand.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A build stopped in the middle of a conflict: alpha and upstream both touch
# file.txt, and --no-resolve leaves the merge in the tree on purpose.
conflicted() {
  fixture_new
  topic_branch alpha file.txt "alpha-line"
  fixture_config
  manifest alpha
  run_desvio build                    # first build makes the worktree
  git -C "$REPO" checkout -q -B wip origin/main
  repo_append file.txt "wip-line"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "wip: conflicting change"
  upstream_commit file.txt "upstream-line" "base: third"
  manifest wip
  run_desvio build --no-resolve
}

# ---------------------------------------------------------------------------
it "abort clears a half-finished merge, and the next build runs"
conflicted
assert_contains "$OUT" "conflict merging 'wip'" "the fixture really is stuck"

run_desvio abort
assert_eq 0 "$STATUS" "abort succeeds"
assert_contains "$OUT" "aborted the merge of wip" "it names the branch, not a sha"

# The state the next build refused to touch is gone.
if [ -n "$(git -C "$WORKTREE" ls-files -u)" ]; then
  fail "no conflicted entries are left" "ls-files -u is not empty"
else
  ok "no conflicted entries are left"
fi

# Not alpha: upstream moved under it in the fixture, so it conflicts too now.
# A branch cut from where upstream is today is the "you dropped the bad line"
# case this asserts.
topic_branch beta shared.txt "beta-line"
manifest beta
run_desvio build
assert_eq 0 "$STATUS" "and a build with the branch dropped goes through"
assert_not_contains "$OUT" "a merge is in progress" "the guard has nothing to complain about"

# ---------------------------------------------------------------------------
# The message the conflict itself prints has to name the way out, or the command
# is only findable by reading --help.
it "the conflict that stops a build points at abort"
conflicted
assert_contains "$OUT" "desvio abort" "conflict_death offers it"

run_desvio build
assert_contains "$OUT" "desvio abort" "and so does the guard on the next build"

# ---------------------------------------------------------------------------
# Safe to run blind: in a script, or because you cannot remember whether the
# last build got as far as conflicting.
it "abort with nothing in progress is a no-op, not an error"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha
run_desvio build

run_desvio abort
assert_eq 0 "$STATUS" "it exits 0"
assert_contains "$OUT" "no merge in progress" "and says why there was nothing to do"

# ---------------------------------------------------------------------------
it "abort before the first build says there is no tree yet"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha

run_desvio abort
assert_eq 0 "$STATUS" "it exits 0"
assert_contains "$OUT" "nothing to abort" "and does not pretend a tree exists"

# ---------------------------------------------------------------------------
# It resets a tree, so it gets the same guard the build has: only ever desvio's
# own worktree, never the checkout your work lives in.
it "abort refuses a DESVIO_WORKTREE pointing at the upstream checkout"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha
run_desvio build
printf 'DESVIO_WORKTREE="%s"\n' "$REPO" >> "$BUILD/desvio.conf"

assert_dies_with "points at the upstream checkout itself" abort

# ---------------------------------------------------------------------------
# A merge killed mid-flight — Ctrl-C, a reboot — can leave conflicted entries in
# the index with no MERGE_HEAD above them. `git merge --abort` refuses that
# state ("there is no merge to abort"), so abort must not simply hand it over.
it "abort clears conflicted entries left behind with no MERGE_HEAD"
conflicted
rm -f "$(cd "$WORKTREE" && git rev-parse --git-path MERGE_HEAD)"

run_desvio abort
assert_eq 0 "$STATUS" "abort succeeds"
assert_contains "$OUT" "the index had conflicts left in it" "it says what it found"
if [ -n "$(git -C "$WORKTREE" ls-files -u)" ]; then
  fail "the index is clean again" "ls-files -u is not empty"
else
  ok "the index is clean again"
fi

# ---------------------------------------------------------------------------
it "abort takes no arguments"
fixture_new
topic_branch alpha file.txt "alpha-line"
fixture_config
manifest alpha

assert_dies_with "abort takes no arguments" abort wip

finish
