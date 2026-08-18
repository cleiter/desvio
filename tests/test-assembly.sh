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
# Which branch is it on right now, and how much is left? The merge loop can sit
# on one line for minutes while the resolver runs, so every line it prints about
# a branch carries its position in the manifest.
assert_contains "$OUT" "[1/2] alpha → 1 file" "the line says how far along the build is"
assert_contains "$OUT" "[2/2] beta" "and counts to the end of the manifest"
# The banner says $DESVIO_NAME ("test build"), which is not a branch you can
# check out. The summary has to name the one you can.
assert_contains "$OUT" "built as" "the summary says what was built"
assert_contains "$(printf '%s\n' "$OUT" | grep -A1 'built as')" "integration" \
  "and names the branch the assembly is on, not just the display name"

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
# The point of the verdict: which commit it saw. Naming it is what lets you
# disagree with desvio, which is the whole reason this case is not one message.
assert_contains "$OUT" "alpha: change file.txt" "it names the commit its work landed in"

# ---------------------------------------------------------------------------
# The bug this guards: a branch created from the base and never committed to
# also merges into nothing, and desvio used to call that "already upstream" and
# tell you to delete the line — losing whatever is still uncommitted in its
# worktree. The subject it prints is the BASE's, which is exactly what makes the
# old message convincing and wrong.
it "a branch with no commits of its own is not called a dead manifest line"
setup
git -C "$REPO" branch never-touched main
fixture_config
manifest never-touched
run_desvio build

assert_eq 0 "$STATUS" "the build still succeeds"
assert_contains "$OUT" "no commits of its own" "it says the branch is empty"
assert_contains "$OUT" "branches with no commits at all: never-touched" \
  "and lists it apart from the dead lines"
assert_not_contains "$OUT" "dead manifest lines" "it is NOT a dead line"
assert_not_contains "$OUT" "drop this manifest line" "and must not say to drop it"
assert_contains "$OUT" "uncommitted" "it points at where the work probably is"

# ---------------------------------------------------------------------------
it "a branch an earlier manifest line already contains is named against that line"
setup
# beta sits on top of alpha, so merging beta first brings alpha in whole.
git -C "$REPO" branch -f beta alpha
git -C "$REPO" checkout -q beta
printf 'on-top\n' > "$REPO/on-top.txt"
git -C "$REPO" add on-top.txt
git -C "$REPO" commit -q -m "beta on top of alpha"
git -C "$REPO" checkout -q main
fixture_config
manifest beta alpha
run_desvio build

assert_eq 0 "$STATUS" "the build still succeeds"
assert_contains "$OUT" "'beta' is merged above it" "it names the branch that has it"
assert_contains "$OUT" "dead manifest lines: alpha" "and that line really is dead"

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
assert_not_contains "$OUT" "is ready" "no green banner over a failed gate"

# ---------------------------------------------------------------------------
# The gate has to run with `set -e` ARMED INSIDE IT, and catching its failure
# without losing that is the whole difficulty. Written the obvious way —
# `run_hook desvio_verify || GATE_STATUS=$?` — the hook runs with errexit
# disabled, so a two-command gate whose first command fails runs the second one
# anyway and reports the SECOND one's status. For the real thing that means:
# typecheck fails, lint runs anyway, lint passes, build reports GREEN.
#
# Measured on bash 3.2.57 and 5.3.15; an explicit `set -e` in a subshell does
# not save you either, because the ignore-errexit state propagates in. See
# run_gate in lib/common.sh.
#
# Mutation check: swapping run_gate back to the `||` form fails exactly this
# test and nothing else in the suite.
it "a gate whose first command fails does not pass because its last one succeeded"
setup
fixture_config 'desvio_verify() { false; true; }'
manifest alpha
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_not_contains "$OUT" "is ready" "and prints no green banner"

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
