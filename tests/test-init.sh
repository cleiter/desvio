#!/usr/bin/env bash
#
# desvio init. The config it writes is sourced as bash by every later command, so
# "is it valid bash" is not a style question — a stray quote makes every build
# fail with a message from bash rather than from desvio.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------------------------------------------------------------------------
it "init writes both files and says what to do next"
fixture_new
mkdir -p "$TEST_TMP/fresh" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
run_desvio init "$REPO"

assert_eq 0 "$STATUS" "init succeeds"
[ -f desvio.conf ]  && ok "desvio.conf written"  || fail "desvio.conf written"
[ -f manifest.txt ] && ok "manifest.txt written" || fail "manifest.txt written"
assert_contains "$OUT" "desvio build" "it tells you the next command"
assert_contains "$(cat desvio.conf)" "DESVIO_REPO=\"$REPO\"" "the repo path is filled in"

# ---------------------------------------------------------------------------
it "the generated config is valid bash and defines the hooks it claims"
fixture_new
mkdir -p "$TEST_TMP/fresh" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
run_desvio init "$REPO"

if bash -n desvio.conf 2>/dev/null; then ok "it parses"; else fail "it parses"; fi
# Sourcing it must define exactly the hooks the template leaves uncommented.
defined="$(bash -c '. ./desvio.conf >/dev/null 2>&1; declare -F | awk "{print \$3}" | sort | tr "\n" " "')"
assert_contains "$defined" "desvio_install" "desvio_install is defined"
assert_contains "$defined" "desvio_verify" "desvio_verify is defined"
assert_not_contains "$defined" "desvio_preflight" "the commented-out preflight is not"

# ---------------------------------------------------------------------------
it "the generated manifest carries the branch-order doctrine"
fixture_new
mkdir -p "$TEST_TMP/fresh" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
run_desvio init "$REPO"
assert_contains "$(cat manifest.txt)" "the front is frozen, the back moves" \
  "the ordering rule is in the file where it is needed"

# ---------------------------------------------------------------------------
it "init refuses to overwrite an existing config"
fixture_new
mkdir -p "$TEST_TMP/fresh" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
printf 'DESVIO_REPO="keep me"\n' > desvio.conf
run_desvio init "$REPO"

assert_contains "$OUT" "already exists" "it refuses"
assert_contains "$(cat desvio.conf)" "keep me" "and the existing file is intact"

# ---------------------------------------------------------------------------
it "init warns when the target is not a checkout"
fixture_new
mkdir -p "$TEST_TMP/fresh" "$TEST_TMP/plain" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
run_desvio init "$TEST_TMP/plain"
assert_contains "$OUT" "not a git checkout" "it warns"
assert_eq 0 "$STATUS" "but still writes the files, so you can fix the path"

# ---------------------------------------------------------------------------
it "init then build works end to end"
fixture_new
mkdir -p "$TEST_TMP/fresh" && cd "$TEST_TMP/fresh" || exit 1
unset DESVIO_CONFIG
run_desvio init "$REPO"
# The template assumes npm; replace the hooks with something a fixture can run.
printf 'desvio_install() { :; }\ndesvio_verify() { :; }\n' >> desvio.conf
run_desvio build

assert_eq 0 "$STATUS" "a build from a generated config succeeds"
assert_contains "$OUT" "is ready" "and prints a summary"

finish
