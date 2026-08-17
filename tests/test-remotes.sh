#!/usr/bin/env bash
#
# Manifest lines that name a branch on another remote — resolve_topic and
# remote_of in lib/common.sh, parse_manifest/fetch_remotes/resolve_manifest in
# lib/cmd-build.sh.
#
# The two cases worth reading first are the shadowing ones. A local branch
# LITERALLY named `fork/feature-x` must beat the remote ref of the same name, and
# a remote named `feature` must not hijack a local `feature/nested`. Both are how
# "local first" either means something or does not.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

setup() {
  fixture_new
  fixture_config
}

# ---------------------------------------------------------------------------
it "a branch on another remote is fetched and merged"
setup
fork_remote fork
fork_branch fork feature-x file.txt "fork-line"
manifest fork/feature-x
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "fetching fork" "the fork was fetched, not just origin"
if tree_has file.txt "fork-line"; then ok "the fork's commit is in the tree"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# The fork is registered but never fetched by the fixture, and a second commit
# lands on it AFTER the first build. Without a per-build fetch of every remote
# the manifest names, the second build would silently rebuild the first one.
it "each build re-fetches the remote, so new commits land"
setup
fork_remote fork
fork_branch fork feature-x file.txt "fork-one"
manifest fork/feature-x
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

fork_branch fork feature-x file.txt "fork-two"
run_desvio build
assert_eq 0 "$STATUS" "the second build succeeds"
if tree_has file.txt "fork-two"; then ok "the commit pushed after the first build is there"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# Local first. These two names DO compete: `refs/heads/fork/feature-x` and
# `refs/remotes/fork/feature-x` are both spelled `fork/feature-x` in a manifest.
it "a local branch shadows the remote ref of the same name"
setup
fork_remote fork
fork_branch fork feature-x file.txt "from-the-remote"
topic_branch fork/feature-x file.txt "from-the-local-branch"
manifest fork/feature-x
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if tree_has file.txt "from-the-local-branch"; then ok "the local branch won"; else fail "$CURRENT"; fi
if tree_has file.txt "from-the-remote"; then fail "$CURRENT" "the remote ref was merged too"; else ok "and the remote ref was not merged"; fi

# ---------------------------------------------------------------------------
# `feature/nested` is an ordinary local branch name. A remote that happens to be
# called `feature` must not make desvio read it as one of that remote's branches.
it "a remote does not hijack a local branch that starts with its name"
setup
fork_remote feature
topic_branch feature/nested file.txt "local-nested"
manifest feature/nested
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if tree_has file.txt "local-nested"; then ok "the local branch was merged"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# git accepts a remote named `team/alice`. Splitting on the FIRST slash would
# answer `team` here, fetch the wrong remote, and then report the branch missing.
it "the longest matching remote name wins"
setup
fork_remote team
fork_remote team/alice
fork_branch team/alice topic file.txt "alice-line"
manifest team/alice/topic
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "fetching team/alice" "the longer remote was fetched"
if tree_has file.txt "alice-line"; then ok "its branch was merged"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# A slashed name is a perfectly ordinary local branch, so the error cannot assume
# the user meant a remote and send them to fix the wrong thing.
it "a name that resolves to nothing names both readings"
setup
manifest nosuch/feature-x
run_desvio build

assert_eq 1 "$STATUS" "the build fails"
assert_contains "$OUT" "nosuch/feature-x" "it names the line"
assert_contains "$OUT" "a local branch" "it offers the local-branch reading"
assert_contains "$OUT" "remote add nosuch" "and the remote reading"
assert_not_contains "$OUT" "is ready" "no success banner"

# ---------------------------------------------------------------------------
it "a branch on the configured remote resolves too"
setup
topic_branch feature-x file.txt "pushed-line"
git -C "$REPO" push -q origin feature-x
git -C "$REPO" branch -q -D feature-x
manifest origin/feature-x
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if tree_has file.txt "pushed-line"; then ok "the origin ref was merged"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
it "local and remote lines merge in manifest order"
setup
fork_remote fork
# Separate files: this test is about ORDER, and two branches appending to one
# file would conflict and make it about conflict handling instead.
fork_branch fork remote-topic shared.txt "remote-line"
topic_branch local-topic file.txt "local-line"
manifest local-topic fork/remote-topic
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
# Merge commits are recorded newest-first, so the last manifest line is first.
assert_contains "$(git -C "$WORKTREE" log --oneline --merges | head -1)" "fork/remote-topic" \
  "the remote line was merged second"

# ---------------------------------------------------------------------------
# --prune is what turns "someone deleted their branch" into an error instead of a
# build that silently keeps using a ref nothing will ever update again.
it "a branch deleted on the fork stops the next build"
setup
fork_remote fork
fork_branch fork feature-x file.txt "fork-line"
manifest fork/feature-x
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

fork_delete_branch fork feature-x
run_desvio build
assert_eq 1 "$STATUS" "the second build fails"
assert_contains "$OUT" "fork/feature-x" "it names the branch that went away"

# ---------------------------------------------------------------------------
it "a remote line that contributes nothing is marked, not merged"
setup
fork_remote fork
git -C "$TEST_TMP/fork-work" push -q origin origin/main:refs/heads/nothing
manifest fork/nothing
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "already upstream" "it says the line is dead"

# ---------------------------------------------------------------------------
# refs/pull/<N>/head is in no default refspec, so the ordinary fetch cannot see
# it and the explicit-refspec retry is the only thing that makes this work.
it "a pull-request ref resolves and merges"
setup
fork_remote fork
fork_pr_ref fork 3206 file.txt "pr-line"
manifest fork/pull/3206/head
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if tree_has file.txt "pr-line"; then ok "the PR ref was merged"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# `git fetch <remote>` obeys that remote's configured refspec. A restricted one
# never brings the branch down, and without the retry desvio would report a
# branch that plainly exists as missing.
it "a remote with a restricted refspec still resolves"
setup
fork_remote fork
fork_branch fork feature-x file.txt "restricted-line"
git -C "$REPO" config remote.fork.fetch "+refs/heads/main:refs/remotes/fork/main"
manifest fork/feature-x
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if tree_has file.txt "restricted-line"; then ok "the branch was fetched explicitly"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# The whole point of the warn-instead-of-die split: a fork that disappears must
# not stop you building. Two builds, because the first is what puts the ref in
# the object store for the second to fall back on.
it "an unreachable fork warns and builds on, and the summary says it is stale"
setup
fork_remote fork
fork_branch fork feature-x file.txt "fork-line"
manifest fork/feature-x
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

break_remote fork
run_desvio build
assert_eq 0 "$STATUS" "the build still succeeds with the fork gone"
assert_contains "$OUT" "cannot fetch 'fork'" "it says which remote it could not reach"
assert_contains "$OUT" "STALE" "and the summary marks the branch stale"
if tree_has file.txt "fork-line"; then ok "the last-fetched commit was still merged"; else fail "$CURRENT"; fi

# ---------------------------------------------------------------------------
# The other half of the split. Losing origin is losing the floor every build
# stands on, so it stays fatal.
it "an unreachable origin still stops the build"
setup
topic_branch alpha file.txt "alpha-line"
manifest alpha
break_remote origin
run_desvio build

assert_eq 1 "$STATUS" "the build fails"
assert_contains "$OUT" "cannot fetch 'origin'" "it names origin"
assert_not_contains "$OUT" "is ready" "no success banner"

# ---------------------------------------------------------------------------
# A local branch is never stale, however badly its same-named remote went — that
# remote was never consulted.
it "a locally-shadowed line is not marked stale when its remote fails"
setup
fork_remote fork
fork_branch fork feature-x file.txt "from-the-remote"
topic_branch fork/feature-x file.txt "from-the-local-branch"
manifest fork/feature-x
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

break_remote fork
run_desvio build
assert_eq 0 "$STATUS" "the second build succeeds"
assert_not_contains "$OUT" "STALE" "the local branch is not reported as stale"

finish
