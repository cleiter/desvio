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

finish
