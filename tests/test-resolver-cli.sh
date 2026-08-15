#!/usr/bin/env bash
#
# The contract desvio has with the `claude` binary.
#
# README's central safety claim is that the resolver "runs with NO shell tool,
# so it cannot run git at all". That claim rests entirely on the flags
# lib/resolve.sh passes — and nothing else in the suite reads them. Delete
# `--disallowed-tools Bash` and every other test in this repo still passes,
# which makes the promise exactly as strong as a comment.
#
# So: a fake `claude` first on PATH that records its own argv, and assertions
# about what it was handed. The real binary is never called — it costs money and
# is not deterministic — which is the same reason every other test stubs the
# resolver at the hook level. This file stubs one layer lower, because the flags
# are the thing under test.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# fake_claude <behaviour> — put a stub `claude` first on PATH.
#
# It writes its arguments, one per line, to $ARGV_LOG, then acts:
#   resolve — strip every marker, so desvio sees a successful resolution
#   giveup  — touch nothing, so the markers survive and desvio must notice
fake_claude() {
  local behaviour="$1"
  FAKE_BIN="$TEST_TMP/fakebin"
  ARGV_LOG="$TEST_TMP/claude-argv.txt"
  mkdir -p "$FAKE_BIN"
  : > "$ARGV_LOG"

  cat > "$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
if [ "$behaviour" = resolve ]; then
  # cwd is the build tree: resolve.sh cd's there before invoking us, which is
  # itself part of the contract this file checks.
  for f in \$(git diff --name-only --diff-filter=U); do
    sed -e '/^<<<<<<</d' -e '/^=======\$/d' -e '/^>>>>>>>/d' "\$f" > "\$f.tmp"
    mv "\$f.tmp" "\$f"
  done
fi
printf 'RESOLVED\n'
EOF
  chmod +x "$FAKE_BIN/claude"
  export PATH="$FAKE_BIN:$PATH"
}

setup_conflict() {
  fixture_new
  topic_branch conflicting file.txt "topic-line"
  upstream_commit file.txt "upstream-line" "base: third"
}

# argv_has <flag> <value> — the flag appears immediately before that value.
# Adjacency matters: `--allowed-tools Read` and `--disallowed-tools Read` differ
# by exactly this, and a plain substring search cannot tell them apart.
argv_has() {
  local want_flag="$1" want_val="$2" prev="" line
  while IFS= read -r line; do
    if [ "$prev" = "$want_flag" ] && [ "$line" = "$want_val" ]; then return 0; fi
    prev="$line"
  done < "$ARGV_LOG"
  return 1
}

assert_argv() {
  if argv_has "$1" "$2"; then ok "$3"
  else fail "$3" "expected '$1 $2' in the argv desvio passed claude:
$(cat "$ARGV_LOG")"; fi
}

# ---------------------------------------------------------------------------
it "the resolver is invoked with the sandbox flags README promises"
setup_conflict
fake_claude resolve
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "auto-resolved" "the conflict went through the resolver"

# Every one of these is load-bearing for "the agent cannot reach a ref".
assert_argv --disallowed-tools Bash      "Bash is denied"
assert_argv Bash Task                    "Task is denied (it could spawn a shell)"
assert_argv Task WebFetch                "WebFetch is denied"
assert_argv WebFetch WebSearch           "WebSearch is denied"
assert_argv --allowed-tools Read         "Read is allowed"
assert_argv --permission-mode acceptEdits "it runs in acceptEdits mode"

# ---------------------------------------------------------------------------
it "the configured model and effort reach the binary"
setup_conflict
fake_claude resolve
fixture_config "DESVIO_AUTO_RESOLVE=1" 'DESVIO_RESOLVER_MODEL=sonnet' \
  'DESVIO_RESOLVER_EFFORT=low'
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_argv --model sonnet "the configured model is passed"
assert_argv --effort low   "the configured effort is passed"

# ---------------------------------------------------------------------------
# The agent's own verdict is a hint; markers are the check. A stub that claims
# RESOLVED while leaving the conflict in place must not produce a green build.
it "a resolver that says RESOLVED but leaves markers does not pass"
setup_conflict
fake_claude giveup
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest conflicting
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "conflict markers still present" "it says the markers survived"
assert_not_contains "$OUT" "auto-resolved" "and does not claim a resolution"

# ---------------------------------------------------------------------------
# The transcript is the only record of what the agent was doing, and it is read
# after a failure — so its path has to be one that exists.
it "the transcript is written where the error message says it is"
setup_conflict
fake_claude resolve
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest conflicting
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if [ -f "$BUILD/state/resolve-conflicting.log" ]; then
  ok "the transcript exists"
else
  fail "the transcript exists" "nothing at $BUILD/state/resolve-conflicting.log"
fi

# ---------------------------------------------------------------------------
# A slash is the commonest thing in a branch name, and a slash in a filename is
# a directory. Without flattening, tee fails and the transcript is lost.
it "a branch with a slash still gets a transcript"
fixture_new
topic_branch feature/nested file.txt "topic-line"
upstream_commit file.txt "upstream-line" "base: third"
fake_claude resolve
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest feature/nested
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
if [ -f "$BUILD/state/resolve-feature-nested.log" ]; then
  ok "the transcript path is flattened, not nested"
else
  fail "the transcript path is flattened, not nested" \
    "nothing at $BUILD/state/resolve-feature-nested.log
state/ holds: $(ls "$BUILD/state" 2>/dev/null | tr '\n' ' ')"
fi

finish
