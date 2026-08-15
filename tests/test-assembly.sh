#!/usr/bin/env bash
#
# Assembly, and the hooks around it. The gate matters most: desvio's own README
# argues a clean merge tells you nothing, so a failing desvio_verify has to fail
# the build and a missing one has to be loud.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

setup() {
  fixture_new
  topic_branch alpha file.txt   "alpha-line"
  topic_branch beta  shared.txt "beta-line"
}

# ---------------------------------------------------------------------------
# --no-ff, always. A fast-forward would leave HEAD^ pointing at the topic's own
# parent and the before/after file count would read the wrong range.
it "every contributing branch produces a merge commit"
setup
fixture_config
manifest alpha beta
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_eq "2" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "two branches, two merge commits"
assert_contains "$OUT" "alpha → 1 file" "the file count is reported per branch"

# ---------------------------------------------------------------------------
it "a branch already upstream is called out as a dead manifest line"
setup
# Land alpha's change upstream, so merging it contributes nothing.
git -C "$REPO" push -q origin alpha:main
fixture_config
manifest alpha
run_desvio build

assert_eq 0 "$STATUS" "the build still succeeds"
assert_contains "$OUT" "contributed NOTHING" "it says the branch added nothing"
assert_contains "$OUT" "dead manifest lines: alpha" "and lists it as dead"
assert_contains "$OUT" "drop this manifest line" "the summary says what to do"

# ---------------------------------------------------------------------------
it "hooks run in order: preflight, install, seed, build, verify"
setup
fixture_config \
  'desvio_preflight() { echo preflight >> "$DESVIO_STATE/order"; }' \
  'desvio_install()   { echo install   >> "$DESVIO_STATE/order"; }' \
  'desvio_seed()      { echo seed      >> "$DESVIO_STATE/order"; }' \
  'desvio_build()     { echo build     >> "$DESVIO_STATE/order"; }' \
  'desvio_verify()    { echo verify    >> "$DESVIO_STATE/order"; }'
manifest alpha
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_eq "preflight
install
seed
build
verify" "$(cat "$BUILD/state/order")" "all five ran, in that order"

# ---------------------------------------------------------------------------
it "a preflight that dies stops the build before anything is merged"
setup
fixture_config 'desvio_preflight() { die "a daemon is still running"; }'
manifest alpha
run_desvio build

assert_contains "$OUT" "a daemon is still running" "the preflight message is shown"
assert_eq "0" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "nothing was merged"

# ---------------------------------------------------------------------------
it "a failing gate fails the build"
setup
fixture_config 'desvio_verify() { return 3; }'
manifest alpha
run_desvio build

assert_eq 3 "$STATUS" "the gate's exit status is the build's"
assert_contains "$OUT" "gate: desvio_verify" "it says it ran the gate"

# ---------------------------------------------------------------------------
it "no gate at all is loud but not fatal"
setup
fixture_config
manifest alpha
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "this build was not verified" "it warns"
assert_contains "$OUT" "no gate configured" "and the summary records it"

# ---------------------------------------------------------------------------
it "--assemble-only stops before install and gate"
setup
fixture_config \
  'desvio_install() { echo install >> "$DESVIO_STATE/order"; }' \
  'desvio_verify()  { echo verify  >> "$DESVIO_STATE/order"; }'
manifest alpha
run_desvio build --assemble-only

assert_eq 0 "$STATUS" "it succeeds"
assert_contains "$OUT" "skipping install and gate" "it says what it skipped"
assert_eq "1" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "but the merge did happen"
assert_eq "0" "$(cat "$BUILD/state/order" 2>/dev/null | wc -l | tr -d ' ')" \
  "no hook ran"

# ---------------------------------------------------------------------------
# --keep-going abandons the branch it cannot merge, finishes the rest, and still
# exits non-zero: a build missing a branch you asked for is not a success.
it "--keep-going abandons one branch, keeps the rest, exits non-zero"
setup_conflict_plus_harmless() {
  fixture_new
  topic_branch conflicting file.txt   "topic-line"
  topic_branch harmless    shared.txt "harmless-line"
  upstream_commit file.txt "upstream-line" "base: third"
}
setup_conflict_plus_harmless
# A resolver that gives up.
fixture_config "DESVIO_AUTO_RESOLVE=1" 'desvio_resolve_conflict() { return 1; }'
manifest conflicting harmless
run_desvio build --keep-going

assert_contains "$OUT" "abandoning this branch" "it abandons the conflicting branch"
assert_contains "$OUT" "left out of this build: conflicting" "and says which"
assert_contains "$OUT" "harmless" "the other branch still merged"
assert_eq "1" "$(git -C "$BUILD/build-tree" log --oneline --merges | wc -l | tr -d ' ')" \
  "only the harmless branch is in the result"
if [ "$STATUS" -ne 0 ]; then ok "exit status is non-zero"; else fail "exit status is non-zero" "got 0"; fi

# ---------------------------------------------------------------------------
# --keep-going means what `desvio build --help` says it means: report the failed
# branch and carry on. It applies whatever the conflict failed on — a resolver
# that gave up, or a resolver that was never allowed to run.
it "--keep-going applies to --no-resolve too"
setup_conflict_plus_harmless
fixture_config
manifest conflicting harmless
run_desvio build --keep-going --no-resolve

assert_contains "$OUT" "abandoning this branch" "the conflicting branch is abandoned"
assert_contains "$OUT" "left out of this build: conflicting" "and named in the summary"
assert_contains "$OUT" "harmless" "the other branch still merged"
if [ "$STATUS" -ne 0 ]; then ok "exit status is non-zero"; else fail "exit status is non-zero" "got 0"; fi

# Without --keep-going, --no-resolve still stops dead and leaves the conflict in
# the tree — that is the whole point of the flag.
it "--no-resolve alone still stops at the first conflict"
setup_conflict_plus_harmless
fixture_config
manifest conflicting harmless
run_desvio build --no-resolve

assert_contains "$OUT" "auto-resolution is off" "it dies at the first conflict"
assert_not_contains "$OUT" "abandoning this branch" "nothing is abandoned"

finish
