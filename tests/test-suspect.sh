#!/usr/bin/env bash
#
# RESOLVED-SUSPECT: the resolver removed every marker and still thinks the merge
# is broken.
#
# Markers cannot check that claim, which is exactly why it needs carrying. The
# failure this exists for: git conflicted on HALF of a coupled change and merged
# the other half cleanly — upstream deleted an import, the topic moved the code
# using it — so the resolver fixed what it could see, said so in prose, said
# RESOLVED, and the build printed a green tick over a file that would not
# compile. The gate caught it eventually, four merges and one full install
# later, with nothing pointing back at the branch.
#
# The suspicion is never a veto. A false one costs a warning line; the gate
# stays the thing that decides. DESVIO_SUSPECT=fail is for someone who would
# rather stop at the merge than wait for the gate.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A resolver that resolves cleanly and flags itself, the way the real one does
# when it cannot repair the half of the change that merged without a marker.
SUSPICIOUS='
desvio_resolve_conflict() {
  local f
  while IFS= read -r -d "" f; do
    sed -e "/^<<<<<<</d" -e "/^=======$/d" -e "/^>>>>>>>/d" \
      "$DESVIO_WORKTREE/$f" > "$DESVIO_WORKTREE/$f.r"
    mv "$DESVIO_WORKTREE/$f.r" "$DESVIO_WORKTREE/$f"
  done < <(gitw diff --name-only --diff-filter=U -z)
  RESOLVER_SUSPECT="file.txt references a helper that upstream deleted"
  return 0
}'

setup() {
  fixture_new
  topic_branch conflicting file.txt "topic-line"
  upstream_commit file.txt "upstream-line" "base: third"
}

# ---------------------------------------------------------------------------
it "a flagged resolution still builds, but says so in the summary"
setup
fixture_config "DESVIO_AUTO_RESOLVE=1" "$SUSPICIOUS"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds — a suspicion is not a veto"
assert_contains "$OUT" "the resolver was not sure" "it says so while merging"
assert_contains "$OUT" "references a helper that upstream deleted" "and what it was not sure about"
assert_contains "$OUT" "the resolver was NOT sure" "the summary marks the branch"
assert_contains "$OUT" "resolve-conflicting.log" "and points at the transcript"

# ---------------------------------------------------------------------------
it "DESVIO_SUSPECT=fail stops the build at the merge"
setup
fixture_config "DESVIO_AUTO_RESOLVE=1" "DESVIO_SUSPECT=fail" "$SUSPICIOUS"
manifest conflicting
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "DESVIO_SUSPECT=fail" "it says which knob did that"
assert_contains "$OUT" "references a helper that upstream deleted" "and repeats the reason"

# ---------------------------------------------------------------------------
# The suspicion is carried in a global, because bash 3.2 has no second return
# value. A global that is not cleared per call would paint every LATER branch
# with the doubt of an earlier one — which would train you to ignore the mark.
it "the flag does not leak onto a later branch"
setup
topic_branch second shared.txt "second-line"
# Flags only the branch it is given, so the second branch must come out clean.
ONE_ONLY='
desvio_resolve_conflict() {
  local f
  while IFS= read -r -d "" f; do
    sed -e "/^<<<<<<</d" -e "/^=======$/d" -e "/^>>>>>>>/d" \
      "$DESVIO_WORKTREE/$f" > "$DESVIO_WORKTREE/$f.r"
    mv "$DESVIO_WORKTREE/$f.r" "$DESVIO_WORKTREE/$f"
  done < <(gitw diff --name-only --diff-filter=U -z)
  [ "$1" = "conflicting" ] && RESOLVER_SUSPECT="only this one"
  return 0
}'
fixture_config "DESVIO_AUTO_RESOLVE=1" "$ONE_ONLY"
manifest conflicting second
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
# The summary marker, not the reason text: the reason legitimately appears twice
# for one branch — once as it is merged, once in the summary. What must not
# happen is a SECOND branch wearing the mark.
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c "NOT sure" || true)" \
  "exactly one branch is marked"

# ---------------------------------------------------------------------------
# A resolver that says nothing must produce no mark at all. This is the case
# every existing config is in, and a summary that grew a warning row for all of
# them would be worse than no feature.
it "a resolver that flags nothing leaves the summary alone"
setup
fixture_config "DESVIO_AUTO_RESOLVE=1" "$(resolver_keep_both)"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "conflict auto-resolved" "the branch is marked resolved"
assert_not_contains "$OUT" "NOT sure" "and carries no warning"

# ---------------------------------------------------------------------------
# The free half of gate attribution: if the resolver already said what is
# broken, say so before spending anything on finding out.
it "a gate failure repeats what the resolver flagged"
setup
fixture_config "DESVIO_AUTO_RESOLVE=1" "$SUSPICIOUS" 'desvio_verify() { return 1; }'
manifest conflicting
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "The resolver already flagged" "the gate failure names it"
assert_contains "$OUT" "a lead and not a verdict" "and does not overclaim"

finish
