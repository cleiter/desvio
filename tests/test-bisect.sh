#!/usr/bin/env bash
#
# --bisect-gate: which of your branches broke the gate?
#
# The integration branch is a straight chain of merge commits, one per manifest
# branch, so the question is answerable by re-running the gate over that chain.
# What these tests mostly pin is the REFUSALS — a bisect that names a branch it
# cannot justify is worse than one that says it could not tell, because the
# wrong answer looks exactly as confident as the right one and sends you off
# rebasing a branch that was never the problem.
#
# The gate here is a grep for a marker string, so probes are instant and
# deterministic. topic_branch writes to files that do not exist yet, so distinct
# files per branch means no conflicts and the resolver is never involved.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# Fails when BROKEN appears anywhere in the tree. `if`, not `grep -q && ...`: as
# a hook's last command a false test is a failing gate, and the shape has to be
# explicit or the next reader gets it backwards.
GATE='desvio_verify() { if grep -rq BROKEN "$DESVIO_WORKTREE" --exclude-dir=.git; then return 1; fi; }'
QUICK='desvio_verify_quick() { if grep -rq BROKEN "$DESVIO_WORKTREE" --exclude-dir=.git; then return 1; fi; }'

setup() {
  fixture_new
  topic_branch aaa    aaa.txt    "aaa"
  topic_branch poison poison.txt "BROKEN"
  topic_branch zzz    zzz.txt    "zzz"
}

# ---------------------------------------------------------------------------
it "it names the branch that broke the gate"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio build --bisect-gate

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "poison broke the gate" "it names the culprit"
assert_contains "$OUT" "after poison" "and the merge it fails at"
assert_contains "$OUT" "fails on its own too" "it says the branch is broken alone"
assert_contains "$OUT" "rebase" "and tells you to rebase it"
assert_not_contains "$OUT" "is ready" "no green banner"

# ---------------------------------------------------------------------------
# The exit status is the gate's own, and CI reads it. A longer path to the
# failure must not change what the failure IS.
it "the gate's exit status survives the bisect"
setup
fixture_config 'desvio_verify() { if grep -rq BROKEN "$DESVIO_WORKTREE" --exclude-dir=.git; then return 3; fi; }'
manifest aaa poison zzz
run_desvio build --bisect-gate
assert_eq 3 "$STATUS" "the gate's status is the build's"

# ---------------------------------------------------------------------------
# The default is to ASK, and there is nobody here to ask: no terminal, so no
# question, and a build in CI or in a cron job can never stall on one.
it "with nobody to ask it only says how to find out"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_not_contains "$OUT" "Bisect now?" "it does not ask a terminal that is not there"
assert_contains "$OUT" "desvio build --bisect-gate" "it prints the command"
assert_contains "$OUT" "desvio_verify_quick" "and suggests the fast hook"
assert_not_contains "$OUT" "bisecting" "and does not bisect uninvited"

# ---------------------------------------------------------------------------
# On a terminal the question is the default, because the answer is the whole
# point of the tool. Enter takes it.
it "on a terminal it offers the bisect, and Enter accepts"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio_answering "" build

assert_contains "$OUT" "Bisect now?" "it asks"
assert_contains "$OUT" "poison broke the gate" "and a bare Enter runs it"
if [ "$STATUS" -ne 0 ]; then ok "the build still fails"; else fail "the build still fails" "got 0"; fi

it "y accepts too"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio_answering "y" build
assert_contains "$OUT" "poison broke the gate" "y bisects"

# ---------------------------------------------------------------------------
# Answering no must cost nothing: the banner is already on screen, so declining
# leaves exactly the output --no-bisect-gate would have produced.
it "answering no declines and leaves the command behind"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio_answering "n" build

assert_contains "$OUT" "the gate failed" "the failure is still reported"
assert_not_contains "$OUT" "bisecting" "nothing is bisected"
assert_contains "$OUT" "desvio build --bisect-gate" "and the command is still there"
if [ "$STATUS" -ne 0 ]; then ok "the build still fails"; else fail "the build still fails" "got 0"; fi

# ---------------------------------------------------------------------------
it "--bisect-gate and DESVIO_BISECT_GATE=1 skip the question"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio_answering "n" build --bisect-gate
assert_not_contains "$OUT" "Bisect now?" "the flag is the answer, so nothing is asked"
assert_contains "$OUT" "poison broke the gate" "and it bisects regardless of what was typed"

fixture_config "$GATE" "DESVIO_BISECT_GATE=1"   # fixture_config truncates the manifest
manifest aaa poison zzz
run_desvio_answering "n" build
assert_not_contains "$OUT" "Bisect now?" "the config knob answers it too"
assert_contains "$OUT" "poison broke the gate" "and bisects"

# ---------------------------------------------------------------------------
it "--no-bisect-gate and DESVIO_BISECT_GATE=0 never ask"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio_answering "y" build --no-bisect-gate
assert_not_contains "$OUT" "Bisect now?" "the flag is the answer here as well"
assert_not_contains "$OUT" "bisecting" "and it is no"

fixture_config "$GATE" "DESVIO_BISECT_GATE=1"
manifest aaa poison zzz
run_desvio_answering "y" build --no-bisect-gate
assert_not_contains "$OUT" "bisecting" "the flag beats the config"

fixture_config "$GATE" "DESVIO_BISECT_GATE=0"
manifest aaa poison zzz
run_desvio_answering "y" build
assert_not_contains "$OUT" "Bisect now?" "the config can pin it off, terminal or not"

# ---------------------------------------------------------------------------
# Upstream broke, not you. Accusing a branch here would be the worst wrong
# answer available: every branch in the manifest is innocent.
it "when the base itself fails, no branch is accused"
setup
upstream_commit poison.txt BROKEN "base: broke it upstream"
fixture_config "$GATE"
manifest aaa zzz
run_desvio build --bisect-gate

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "the base did" "it blames the base"
# Not `assert_not_contains "broke the gate"` — the header is literally "no
# branch of yours broke the gate". What must be absent is a NAMED branch.
assert_not_contains "$OUT" "aaa broke the gate" "and accuses no branch"
assert_not_contains "$OUT" "zzz broke the gate" "nor the other one"
assert_not_contains "$OUT" "the manifest line" "and prints no accusation block"
assert_contains "$OUT" "DESVIO_CLEAN_KEEP" "it raises the leftovers possibility"

# ---------------------------------------------------------------------------
# Neither branch is broken; the pair is. Telling someone to rebase one of them
# would be wrong and would waste a rebase to find that out.
it "a failure that needs two branches is reported as a combination"
fixture_new
topic_branch left  left.txt  "left"
topic_branch right right.txt "right"
# Fails only when BOTH files are present.
fixture_config 'desvio_verify() { if [ -f "$DESVIO_WORKTREE/left.txt" ] && [ -f "$DESVIO_WORKTREE/right.txt" ]; then return 1; fi; }'
manifest left right
run_desvio build --bisect-gate

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "right broke the gate" "it names where the break appears"
assert_contains "$OUT" "PASSES on its own" "but says the branch alone is fine"
assert_contains "$OUT" "the combination is" "and calls it a combination"
assert_contains "$OUT" "left" "listing what was merged before it"

# ---------------------------------------------------------------------------
# A quick gate that cannot see the failure would make every probe pass, and the
# search would then name whichever branch it stopped on. Refuse instead.
it "a quick gate that does not reproduce the failure refuses to guess"
setup
fixture_config "$GATE" 'desvio_verify_quick() { return 0; }'
manifest aaa poison zzz
run_desvio build --bisect-gate

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "nothing to bisect with" "it refuses"
assert_contains "$OUT" "desvio_verify_quick PASSES" "and says why"
assert_not_contains "$OUT" "broke the gate" "naming no branch at all"

# ---------------------------------------------------------------------------
it "the probes run the quick gate, and the real gate runs once"
setup
fixture_config \
  'desvio_verify()       { echo real  >> "$DESVIO_STATE/order"; if grep -rq BROKEN "$DESVIO_WORKTREE" --exclude-dir=.git; then return 1; fi; }' \
  'desvio_verify_quick() { echo quick >> "$DESVIO_STATE/order"; if grep -rq BROKEN "$DESVIO_WORKTREE" --exclude-dir=.git; then return 1; fi; }'
manifest aaa poison zzz
run_desvio build --bisect-gate

assert_eq "1" "$(grep -c '^real$' "$BUILD/state/order" || true)" "the real gate ran once"
if [ "$(grep -c '^quick$' "$BUILD/state/order" || true)" -gt 2 ]; then
  ok "the probes used the quick gate"
else
  fail "the probes used the quick gate" "quick ran $(grep -c '^quick$' "$BUILD/state/order") times"
fi

# ---------------------------------------------------------------------------
# The bisect checks out DETACHED commits over the build tree, and
# assert_worktree_ours refuses to adopt a tree that is not on the integration
# branch. Leaving one behind would make the NEXT build die pointing at a mess
# desvio itself made — so the regression test is that the next build works.
it "the tree is left on the integration branch, and the next build still works"
setup
fixture_config "$GATE" "$QUICK"
manifest aaa poison zzz
run_desvio build --bisect-gate

assert_eq "integration" "$(git -C "$WORKTREE" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)" \
  "the worktree is back on the integration branch"
assert_contains "$(git -C "$WORKTREE" log -1 --format=%s)" "merge zzz" \
  "and at the full assembly, not a probe"

manifest aaa zzz
run_desvio build
assert_eq 0 "$STATUS" "a later build is not poisoned by the bisect"

# ---------------------------------------------------------------------------
# A branch that contributed no commit has nothing to check out and cannot be the
# culprit. Accusing one would name a branch that is not even in the build.
it "a branch that contributed nothing is never accused"
setup
git -C "$REPO" push -q origin aaa:main       # aaa is now upstream, so it is dead
fixture_config "$GATE"
manifest aaa poison
run_desvio build --bisect-gate

assert_contains "$OUT" "poison broke the gate" "the real culprit is named"
assert_not_contains "$OUT" "after aaa" "the dead branch is never probed"

# ---------------------------------------------------------------------------
it "it says how many gate runs to expect before spending them"
setup
fixture_config "$GATE"
manifest aaa poison zzz
run_desvio build --bisect-gate
assert_contains "$OUT" "gate runs" "the budget is announced"

finish
