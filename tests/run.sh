#!/usr/bin/env bash
#
# Run every tests/test-*.sh, each in its own process, and total up the
# assertions. Exits non-zero if anything failed.
#
#   tests/run.sh                  everything
#   tests/run.sh refsafety base   only those files
#   /bin/bash tests/run.sh        under macOS's bash 3.2, which is the version
#                                 the README claims to support
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
[ "$total_fail" -eq 0 ]
