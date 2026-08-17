#!/usr/bin/env bash
#
# --forget: getting out of a BAD recorded resolution.
#
# rerere is why a second build is fast, and it is also why a bad resolution is
# permanent — it is recorded the moment the merge commit is made, and every
# build after that replays it silently and reports a green "conflict replayed
# from rerere". Nothing in the summary tells a resolution you trust apart from
# one that broke the gate three builds ago.
#
# The mechanism is fussier than it looks, and these tests pin the fussy part.
# `git rerere forget` acts on the CURRENT conflict, and with rerere.autoupdate
# on there is no current conflict left by the time a replay has staged
# everything: forgetting there drops the cache entry but leaves the replayed
# content in the tree, so the build would commit the very resolution you asked
# to be rid of. Hence the merge for a --forget branch runs with rerere disabled,
# which brings the markers back, and the forget happens against that.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A resolver that is countable and whose output says which call made it, so a
# test can tell "resolved again" from "replayed what was recorded".
RESOLVER='
desvio_resolve_conflict() {
  local f n
  n=$(( $(cat "$DESVIO_STATE/calls" 2>/dev/null || echo 0) + 1 ))
  printf "%s" "$n" > "$DESVIO_STATE/calls"
  while IFS= read -r -d "" f; do
    printf "resolution-%s\n" "$n" > "$DESVIO_WORKTREE/$f"
  done < <(gitw diff --name-only --diff-filter=U -z)
  return 0
}'

setup() {
  fixture_new
  topic_branch conflicting file.txt "topic-line"
  upstream_commit file.txt "upstream-line" "base: third"
  fixture_config "DESVIO_AUTO_RESOLVE=1" "$RESOLVER"
  manifest conflicting
}

calls() { cat "$BUILD/state/calls" 2>/dev/null || echo 0; }
tree_content() { cat "$BUILD/build-tree/file.txt"; }

# ---------------------------------------------------------------------------
# The baseline the whole feature is a response to: resolve once, replay for ever.
it "a recorded resolution replays on every later build"
setup
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"
assert_contains "$OUT" "conflict auto-resolved" "the first build calls the resolver"
assert_eq "1" "$(calls)" "the resolver ran once"

run_desvio build
assert_eq 0 "$STATUS" "the second build succeeds"
assert_contains "$OUT" "replayed from rerere" "the second build replays it"
assert_eq "1" "$(calls)" "and never calls the resolver again"
assert_eq "resolution-1" "$(tree_content)" "the recorded resolution is what lands"

# ---------------------------------------------------------------------------
it "--forget resolves from scratch instead of replaying"
run_desvio build --forget conflicting
assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "ignoring any recorded resolution" "it says it is ignoring the cache"
assert_contains "$OUT" "forgot the recorded resolution" "and that it forgot it"
assert_not_contains "$OUT" "replayed from rerere" "nothing was replayed"
assert_eq "2" "$(calls)" "the resolver ran a second time"
assert_eq "resolution-2" "$(tree_content)" "and its answer is what lands"

# ---------------------------------------------------------------------------
# The point of forgetting rather than merely bypassing: one build fixes the
# cache. The merge runs with rerere off, but the COMMIT does not, so the
# replacement is recorded — otherwise every future build would need --forget
# again and the bad entry would sit there for ever.
it "the replacement is recorded, so the next plain build replays the new one"
run_desvio build
assert_eq 0 "$STATUS" "the next build succeeds"
assert_contains "$OUT" "replayed from rerere" "it replays from rerere again"
assert_eq "2" "$(calls)" "without calling the resolver"
assert_eq "resolution-2" "$(tree_content)" "and replays the REPLACEMENT, not the original"

# ---------------------------------------------------------------------------
it "--forget names one branch, not all of them"
setup
topic_branch other shared.txt "other-line"
manifest conflicting other
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

run_desvio build --forget other
assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "replayed from rerere" "the branch not named still replays"
assert_eq "1" "$(calls)" "and the resolver is not called for it"

# ---------------------------------------------------------------------------
# A branch that never conflicts has nothing recorded. --forget on it is a no-op,
# not an error: you should be able to name a branch without first working out
# whether it happens to have a cache entry this week.
it "--forget on a branch with no recorded resolution is harmless"
setup
manifest conflicting
run_desvio build --forget conflicting
assert_eq 0 "$STATUS" "the build succeeds"
assert_eq "1" "$(calls)" "the resolver ran, as it would have anyway"

# ---------------------------------------------------------------------------
it "--forget without a branch name is refused"
setup
assert_dies_with "--forget needs a branch name" build --forget

finish
