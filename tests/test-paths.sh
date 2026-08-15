#!/usr/bin/env bash
#
# Filenames and branch names that are not simple words.
#
# These matter more than they look. git QUOTES a path containing a space or a
# newline in --name-only output, so code that reads that output line by line
# does not merely mis-handle such a file — it fails to find it at all, hits its
# `continue`, and reports success. Every safety check in desvio that walks a
# file list therefore fails OPEN on exactly these inputs: the marker assertion
# passes on a file it never opened.
#
# Spaces in paths are not exotic. The Paseo example this repo ships is an
# Electron app, and asset trees like that are full of them.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# An add/add conflict on a file whose name has a space in it.
setup_spaced_conflict() {
  fixture_new
  topic_branch conflicting "my file.txt" "topic-line"
  upstream_commit "my file.txt" "upstream-line" "base: third"
}

# ---------------------------------------------------------------------------
it "a conflict in a file with a space in its name resolves and builds"
setup_spaced_conflict
fixture_config "DESVIO_AUTO_RESOLVE=1" "$(resolver_keep_both)"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "auto-resolved" "the conflict went through the resolver"
assert_contains "$(cat "$BUILD/build-tree/my file.txt")" "topic-line" "the topic's side is there"
assert_contains "$(cat "$BUILD/build-tree/my file.txt")" "upstream-line" "and upstream's"

# ---------------------------------------------------------------------------
# The fail-open case, and the reason this file exists. A resolver that claims
# success while leaving markers in a spaced filename must still be caught.
# Read line-by-line instead of NUL-delimited, this assertion silently passes.
it "conflict markers in a spaced filename are still caught"
setup_spaced_conflict
fixture_config "DESVIO_AUTO_RESOLVE=1" 'desvio_resolve_conflict() { return 0; }'
manifest conflicting
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "conflict markers survived" "the marker check caught it"
assert_contains "$OUT" "my file.txt" "and names the file"

# ---------------------------------------------------------------------------
# The resolver is told to edit only the conflicted files. That is an instruction
# in a prompt, so desvio checks it rather than trusting it.
it "a resolver that edits a file outside the conflict set is stopped"
setup_spaced_conflict
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  printf "sneaky\n" >> "$DESVIO_WORKTREE/shared.txt"
  local f
  while IFS= read -r -d "" f; do
    sed -e "/^<<<<<<</d" -e "/^=======$/d" -e "/^>>>>>>>/d" \
      "$DESVIO_WORKTREE/$f" > "$DESVIO_WORKTREE/$f.resolved"
    mv "$DESVIO_WORKTREE/$f.resolved" "$DESVIO_WORKTREE/$f"
  done < <(gitw diff --name-only --diff-filter=U -z)
  return 0
}'
manifest conflicting
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "outside the conflict set" "it says what the rule was"
assert_contains "$OUT" "shared.txt" "and names the file the resolver touched"
assert_not_contains "$OUT" "is ready" "nothing was committed"

# ---------------------------------------------------------------------------
# `feature/foo` is the commonest branch convention there is.
it "a branch name with a slash builds"
fixture_new
topic_branch feature/nested file.txt "nested-line"
fixture_config
manifest feature/nested
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "feature/nested" "the branch is named in the summary"
assert_contains "$(cat "$BUILD/build-tree/file.txt")" "nested-line" "and its change is in the tree"

# ---------------------------------------------------------------------------
it "a spaced filename survives a plain build with no conflict"
fixture_new
topic_branch alpha "some asset.txt" "asset-line"
fixture_config
manifest alpha
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$(cat "$BUILD/build-tree/some asset.txt")" "asset-line" "the file is in the tree"

finish
