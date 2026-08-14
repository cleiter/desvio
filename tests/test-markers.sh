#!/usr/bin/env bash
#
# "Never commit a conflict marker" (lib/cmd-build.sh:300-315). rerere replays a
# resolution recorded from a DIFFERENT merge, so the file content is the only
# evidence worth trusting — which is why assert_no_markers checks the staged tree
# rather than believing the resolver's verdict.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# Two files that both conflict, so a resolver can fix one and botch the other.
setup_two_conflicts() {
  fixture_new
  git -C "$REPO" checkout -q -B conflicting origin/main
  repo_append file.txt   topic-a
  repo_append shared.txt topic-b
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "conflicting: change both files"
  git -C "$REPO" checkout -q main
  upstream_commit file.txt   "upstream-a" "base: third"
  upstream_commit shared.txt "upstream-b" "base: fourth"
}

# ---------------------------------------------------------------------------
it "a resolver that leaves markers in one file commits nothing"
setup_two_conflicts
# Fixes file.txt, leaves shared.txt exactly as it was, and claims success.
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  sed -e "/^<<<<<<</d" -e "/^=======$/d" -e "/^>>>>>>>/d" \
    "$DESVIO_WORKTREE/file.txt" > "$DESVIO_WORKTREE/file.txt.r"
  mv "$DESVIO_WORKTREE/file.txt.r" "$DESVIO_WORKTREE/file.txt"
  return 0
}'
manifest conflicting
run_desvio build

assert_contains "$OUT" "conflict markers survived into the staged tree" "the lie is caught"
assert_contains "$OUT" "shared.txt" "it names the file that still has markers"
assert_contains "$OUT" "Nothing was committed" "it says nothing was committed"
# Still sitting on the base desvio fetched, with no merge commit on top. Compared
# after the build: origin/main in the clone is stale until desvio fetches.
assert_eq "$(git -C "$REPO" rev-parse origin/main)" \
          "$(git -C "$REPO" rev-parse refs/heads/integration)" \
          "the integration branch did not advance past the base"

# ---------------------------------------------------------------------------
# grep exits 1 when it finds nothing, which is the GOOD case here. The `|| true`
# pair at lib/cmd-build.sh:304-311 exists for that; without it `set -e` kills the
# build with no message on every clean resolve.
it "a clean resolve is not mistaken for a failure"
setup_two_conflicts
fixture_config "DESVIO_AUTO_RESOLVE=1" "$(resolver_keep_both)"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "a fully resolved merge succeeds"
assert_not_contains "$OUT" "markers survived" "no false positive from grep exiting 1"
assert_contains "$OUT" "auto-resolved" "and it is reported as auto-resolved"

# ---------------------------------------------------------------------------
# `[ -f ... ] || continue` at lib/cmd-build.sh:309. A resolver may legitimately
# settle a conflict by deleting the file; grep on a path that is staged but gone
# would otherwise error out.
it "a resolver that deletes the conflicted file does not crash the check"
setup_two_conflicts
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  local f
  for f in $(gitw diff --name-only --diff-filter=U); do
    rm -f "$DESVIO_WORKTREE/$f"
  done
  return 0
}'
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "deleting both sides is a valid resolution"
assert_not_contains "$OUT" "markers survived" "no marker check crash on a missing file"

# ---------------------------------------------------------------------------
it "--no-resolve stops at the conflict and leaves it in place"
setup_two_conflicts
fixture_config
manifest conflicting
run_desvio build --no-resolve

assert_contains "$OUT" "auto-resolution is off" "it says why it stopped"
assert_contains "$OUT" "The conflict is LEFT IN PLACE" "and that the tree is yours to fix"
assert_contains "$(git -C "$BUILD/build-tree" ls-files -u)" "file.txt" \
  "the unmerged entries are still there"

finish
