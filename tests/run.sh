#!/usr/bin/env bash
#
# Run every tests/test-*.sh, each in its own process, and total up the
# assertions. Exits non-zero if anything failed.
#
# A full run lints first — `bash -n` and shellcheck over every shell file in the
# repo, the same two gates CI runs before it runs any test. They live here rather
# than only in the workflow because a green suite says nothing about them: CI
# stops at shellcheck, so a warning it rejects means the tests never ran at all,
# and there is no way to learn that locally from a command that only runs tests.
#
#   tests/run.sh                  everything, lint included
#   tests/run.sh refsafety base   only those files, no lint (see below)
#   tests/run.sh --no-lint        skip the lint stage
#   tests/run.sh --lint-only      lint and stop — what CI runs as its own step,
#                                 so the file list below is the only copy
#   /bin/bash tests/run.sh        under macOS's bash 3.2, which is the version
#                                 the README claims to support
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

lint=1 only_lint=0
case "${1:-}" in
  --no-lint)   lint=0;      shift ;;
  --lint-only) only_lint=1; shift ;;
esac

files=()
if [ $# -gt 0 ]; then
  for want in "$@"; do
    for f in "$HERE"/test-*"$want"*.sh; do
      [ -f "$f" ] && files+=("$f")
    done
  done
  [ "${#files[@]}" -gt 0 ] || { printf 'no test file matches: %s\n' "$*" >&2; exit 2; }
else
  for f in "$HERE"/test-*.sh; do [ -f "$f" ] && files+=("$f"); done
fi

[ "${#files[@]}" -gt 0 ] || { printf 'no test files in %s\n' "$HERE" >&2; exit 2; }

printf 'bash %s · git %s\n' "$BASH_VERSION" "$(git --version | awk '{print $3}')"

# Lint the whole tree or not at all. A filtered run is already not a full
# verification, and shellcheck costs about seven seconds — too much to pay on
# every tight-loop `tests/run.sh forget`, and nothing at all before a push.
[ "${#files[@]}" -eq "$(ls "$HERE"/test-*.sh | wc -l)" ] || lint=0

lint_status=0
if [ "$lint" = 1 ]; then
  # The list is a literal rather than a find: every shell file in this repo is
  # in one of these four places, and a glob that quietly stops matching is worse
  # than one a reader can check against `ls`.
  sources=("$ROOT/bin/desvio" "$ROOT"/lib/*.sh "$ROOT"/examples/paseo/*.sh \
           "$ROOT"/tests/*.sh "$ROOT/tests/lib/harness.sh")

  printf '\nlint\n'
  # One file per call, on purpose. `bash -n a.sh b.sh` parses a.sh and turns
  # everything after it into positional parameters, so the obvious one-liner
  # silently checks the first file and reports the other twenty as fine.
  syntax=0
  for src in "${sources[@]}"; do
    bash -n "$src" || syntax=1
  done
  if [ "$syntax" = 0 ]; then
    printf '  ok    bash -n\n'
  else
    printf '  FAIL  bash -n\n'; lint_status=1
  fi

  # Not having shellcheck is not a failure — it is not a dependency of the test
  # suite — but it must not read as a pass either, because CI has it and will
  # fail on what it finds here.
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "${sources[@]}"; then
      printf '  ok    shellcheck %s\n' "$(shellcheck --version | awk '/^version:/{print $2}')"
    else
      printf '  FAIL  shellcheck\n'; lint_status=1
    fi
  else
    printf '  SKIP  shellcheck is not installed — CI runs it and will fail on\n'
    printf '        anything it finds. brew install shellcheck\n'
  fi
fi
[ "$only_lint" = 0 ] || exit "$lint_status"

# Indexed expansion, not "${arr[@]}": bash 3.2 with set -u treats an empty array
# expansion as an unbound variable. The same trap desvio itself documents.
total_pass=0 total_fail=0 bad_files=()
for f in "${files[@]}"; do
  printf '\n%s\n' "$(basename "$f")"
  out="$(bash "$f" 2>&1)"; status=$?
  # Everything but the machine-readable tally, which is for this loop.
  printf '%s\n' "$out" | grep -v '^RESULT '
  line="$(printf '%s\n' "$out" | grep '^RESULT ' | tail -1)"
  if [ -n "$line" ]; then
    total_pass=$((total_pass + $(printf '%s' "$line" | awk '{print $2}')))
    total_fail=$((total_fail + $(printf '%s' "$line" | awk '{print $3}')))
  else
    # No tally means the file died before finish() — a crash, not a failed
    # assertion, and it must not be reported as a pass.
    bad_files+=("$(basename "$f") (no RESULT line, exit $status)")
  fi
  [ "$status" -eq 0 ] || bad_files+=("$(basename "$f") exit $status")
done

printf '\n────────────────────────────────────────\n'
printf '%d passed, %d failed, across %d files\n' "$total_pass" "$total_fail" "${#files[@]}"

if [ "${#bad_files[@]}" -gt 0 ]; then
  printf '\nfiles that did not pass:\n'
  printf '  %s\n' ${bad_files+"${bad_files[@]}"}
  exit 1
fi
# Lint failure fails the run. It is reported last, after the tally, so a green
# suite above it cannot be mistaken for a green run.
[ "$lint_status" -eq 0 ] || { printf '\nlint failed — CI stops here before it runs a single test\n'; exit 1; }
[ "$total_fail" -eq 0 ]
