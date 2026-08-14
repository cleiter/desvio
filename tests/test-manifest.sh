#!/usr/bin/env bash
#
# The manifest parser, lib/cmd-build.sh:85-101. Small, and every branch of it is
# a case someone will hit: a comment, a note, a branch that no longer exists, a
# file the editor saved without a trailing newline.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

setup() {
  fixture_new
  topic_branch alpha file.txt   "alpha-line"
  topic_branch beta  shared.txt "beta-line"
  fixture_config
}

# ---------------------------------------------------------------------------
it "comments, blank lines and stray whitespace are ignored"
setup
printf '# a whole-line comment\n\n  alpha  \n\n#beta is commented out\n' > "$BUILD/manifest.txt"
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "alpha" "the real branch was merged"
assert_not_contains "$OUT" "a whole-line comment" "the comment is not read as a branch"
assert_eq "1" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "exactly one branch was merged"

# ---------------------------------------------------------------------------
# The note after `#` is the one thing about a manifest you cannot recover from
# git, so it is carried into the summary (lib/cmd-build.sh:89-95).
it "an inline note is captured and printed in the summary"
setup
manifest "alpha  # rejected upstream, keeping it anyway"
run_desvio build

assert_contains "$OUT" "rejected upstream, keeping it anyway" "the note reaches the summary"

# ---------------------------------------------------------------------------
it "a branch that does not exist is skipped and the build carries on"
setup
manifest ghost alpha
run_desvio build

assert_eq 0 "$STATUS" "the build still succeeds"
assert_contains "$OUT" "SKIP ghost" "the missing branch is reported"
assert_contains "$OUT" "no such local branch" "with the reason"
assert_contains "$OUT" "alpha" "and the real branch is still merged"

# ---------------------------------------------------------------------------
# `|| [ -n "$raw" ]` on the read loop. Without it the last line of a file with no
# trailing newline is silently dropped — a branch you asked for, missing, quietly.
it "the last line is read even without a trailing newline"
setup
printf 'alpha' > "$BUILD/manifest.txt"   # deliberately no \n
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "alpha" "the unterminated last line is still parsed"
assert_eq "1" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "and it was actually merged"

# ---------------------------------------------------------------------------
# An empty manifest is what you want when every branch has landed. It is also the
# bash 3.2 empty-array trap documented at lib/cmd-build.sh:124-126.
it "an empty manifest is a legitimate build, not an error"
setup
manifest
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "manifest lists no branches" "it says what it is doing"
assert_contains "$OUT" "no branches in the manifest" "the summary says so too"
assert_eq "0" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "nothing was merged"

# ---------------------------------------------------------------------------
it "order is respected"
setup
manifest beta alpha
run_desvio build
# Merge commits are recorded newest-first, so the last merged is the first line.
assert_contains "$(git -C "$BUILD/build-tree" log --oneline --merges | head -1)" "alpha" \
  "the second manifest line was merged second"

# ---------------------------------------------------------------------------
it "a missing manifest file is an error, not an empty build"
setup
rm -f "$BUILD/manifest.txt"
assert_dies_with "no manifest at" build

finish
