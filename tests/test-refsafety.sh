#!/usr/bin/env bash
#
# "Your topic branches are never written to" — README's central promise, and the
# only one whose failure lands silently in a repository the user cares about.
#
# The injection point is desvio_resolve_conflict: it is the one hook that runs
# while a merge is half-finished, and lib/cmd-build.sh snapshots refs around it
# precisely because a resolver is the thing most likely to misbehave.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A conflict both sides append to the end of the same file.
setup_conflict() {
  fixture_new
  topic_branch conflicting file.txt "topic-line"
  topic_branch victim shared.txt "victim-line"
  upstream_commit file.txt "upstream-line" "base: third"
}

# ---------------------------------------------------------------------------
# desvio REPORTS a moved ref, it does not rewind it. It cannot tell a
# misbehaving resolver from a commit you made in another worktree mid-build,
# and rewinding the second case destroys real work. So the promise these tests
# encode is: the build stops before anything else runs, and you are told
# exactly what moved and how to undo it.
it "a resolver that MOVES a topic ref stops the build and hands you the undo"
setup_conflict
victim_before="$(oid_of victim)"
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  gitr update-ref refs/heads/victim "$(gitr rev-parse refs/heads/conflicting)"
  return 1
}'
manifest conflicting
run_desvio build

assert_contains "$OUT" "local branches moved" "moving a ref stops the build"
assert_contains "$OUT" "refs/heads/victim moved" "it says which ref moved"
assert_contains "$OUT" "NOTHING has been restored" "it is explicit that it did not rewind"
assert_contains "$OUT" "update-ref refs/heads/victim $victim_before" \
  "it prints the exact command that puts the ref back"

# ---------------------------------------------------------------------------
it "a resolver that DELETES a topic ref stops the build and hands you the undo"
setup_conflict
victim_before="$(oid_of victim)"
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  gitr update-ref -d refs/heads/victim
  return 1
}'
manifest conflicting
run_desvio build

assert_contains "$OUT" "local branches moved" "deleting a ref stops the build"
assert_contains "$OUT" "→ deleted" "the message says it had been deleted"
assert_contains "$OUT" "update-ref refs/heads/victim $victim_before" \
  "it prints the command that recreates the branch at its OID"

# ---------------------------------------------------------------------------
# A NEW branch appearing is deliberately not an error (lib/cmd-build.sh:296). A
# test that forbade it would be encoding the wrong promise: the guarantee is
# about the branches you already had.
it "a resolver that CREATES a branch is allowed through with a warning"
setup_conflict
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() {
  gitr branch newcomer refs/heads/conflicting
  local f
  for f in $(gitw diff --name-only --diff-filter=U); do
    sed -e "/^<<<<<<</d" -e "/^=======$/d" -e "/^>>>>>>>/d" \
      "$DESVIO_WORKTREE/$f" > "$DESVIO_WORKTREE/$f.resolved"
    mv "$DESVIO_WORKTREE/$f.resolved" "$DESVIO_WORKTREE/$f"
  done
  return 0
}'
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "new branches appeared" "it warns about the new branch"
assert_not_contains "$OUT" "the resolver moved local branches" "but does not treat it as tampering"

# ---------------------------------------------------------------------------
it "a full build over a conflict leaves every topic OID byte-identical"
setup_conflict
before="$(refs_of_topics)"
fixture_config "DESVIO_AUTO_RESOLVE=1" "$(resolver_keep_both)"
manifest conflicting victim
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "auto-resolved" "the conflict went through the resolver"
# The integration branch is desvio's to move; nothing else may have.
assert_eq "$before" "$(refs_of_topics)" "topic refs unchanged across a real build"

# ---------------------------------------------------------------------------
it "the integration branch is the only ref desvio is allowed to move"
setup_conflict
fixture_config
manifest
run_desvio build
assert_eq 0 "$STATUS" "a plain build succeeds"
assert_contains "$(git -C "$REPO" branch --list integration)" "integration" \
  "the integration branch was created in the checkout"

finish
