#!/usr/bin/env bash
#
# What a build sits on: default_base (lib/common.sh:104-120) and the explicit
# <base> argument. "main is not a safe guess and neither is master" — so the
# remote is asked, and the fallback only runs when it never answered.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------------------------------------------------------------------------
it "the remote's own HEAD is used when it is set"
fixture_new
fixture_config
manifest
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "origin/main" "it built on the remote's HEAD"

# ---------------------------------------------------------------------------
# With no refs/remotes/origin/HEAD the fallback tries master, main, trunk in that
# order. Only `main` exists here, so it must find it rather than give up.
it "with no remote HEAD, the fallback finds an existing branch"
fixture_new
# symbolic-ref -d, not update-ref -d: the latter dereferences, so it would delete
# origin/main and leave the symref dangling — which symbolic-ref still reads, and
# the test would pass for the wrong reason.
git -C "$REPO" symbolic-ref -d refs/remotes/origin/HEAD
fixture_config
manifest
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds without a remote HEAD"
assert_contains "$OUT" "origin/main" "the fallback resolved to origin/main"

# ---------------------------------------------------------------------------
it "when nothing resolves, it says how to fix the remote"
fixture_new
# symbolic-ref -d, not update-ref -d: the latter dereferences, so it would delete
# origin/main and leave the symref dangling — which symbolic-ref still reads, and
# the test would pass for the wrong reason.
git -C "$REPO" symbolic-ref -d refs/remotes/origin/HEAD
git -C "$REPO" update-ref -d refs/remotes/origin/main
fixture_config
manifest
run_desvio build

assert_contains "$OUT" "cannot work out the default branch" "it refuses to guess"
assert_contains "$OUT" "remote set-head" "and gives the command that fixes it"

# ---------------------------------------------------------------------------
it "an explicit base can be a tag, a ~N ref, or a hash"
fixture_new
upstream_commit file.txt "third" "base: third"
git -C "$REPO" fetch -q origin
git -C "$REPO" tag v1 origin/main~1
fixture_config
manifest

run_desvio build v1
assert_eq 0 "$STATUS" "a tag works"
assert_contains "$OUT" "v1" "the summary names the tag"

run_desvio build origin/main~1
assert_eq 0 "$STATUS" "a ~N ref works"

hash="$(git -C "$REPO" rev-parse origin/main~1)"
run_desvio build "$hash"
assert_eq 0 "$STATUS" "a raw hash works"

# ---------------------------------------------------------------------------
it "a pinned base reports how far behind it is"
fixture_new
upstream_commit file.txt "third"  "base: third"
upstream_commit file.txt "fourth" "base: fourth"
git -C "$REPO" fetch -q origin
fixture_config
manifest
run_desvio build origin/main~2

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "pinned" "it flags the pin"
assert_contains "$OUT" "2 commits" "and says how many commits it is missing"

# ---------------------------------------------------------------------------
it "an unresolvable base is an error with the fetch hint"
fixture_new
fixture_config
manifest
run_desvio build v99.99.99

assert_contains "$OUT" "cannot resolve" "it refuses"
assert_contains "$OUT" "fetch" "and suggests fetching for a new tag"

# ---------------------------------------------------------------------------
it "two bases at once is an error"
fixture_new
fixture_config
manifest
assert_dies_with "more than one base given" build main origin/main

finish
