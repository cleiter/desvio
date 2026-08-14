#!/usr/bin/env bash
#
# desvio run — the task runner (lib/cmd-run.sh). The contract a task depends on:
# the config is loaded and exported with absolute paths, arguments arrive intact,
# and the exit status is the task's own.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A task that reports everything a task can see.
task_env() {
  cat > "$BUILD/env.sh" <<'EOF'
#!/usr/bin/env bash
echo "cwd=$PWD"
echo "args=$*"
env | grep '^DESVIO_' | sort
EOF
  chmod +x "$BUILD/env.sh"
}

setup() { fixture_new; fixture_config; manifest; }

# ---------------------------------------------------------------------------
it "the config arrives in the environment, absolute"
setup
task_env
run_desvio run env

assert_eq 0 "$STATUS" "the task ran"
assert_contains "$OUT" "DESVIO_WORKTREE=$BUILD/build-tree" "worktree is absolute"
assert_contains "$OUT" "DESVIO_REPO=$REPO" "repo is exported"
assert_contains "$OUT" "DESVIO_STATE=$BUILD/state" "state is exported"
assert_contains "$OUT" "DESVIO_MANIFEST=$BUILD/manifest.txt" "manifest is exported"
assert_contains "$OUT" "DESVIO_CONFIG_FILE=$BUILD/desvio.conf" "the config path is exported"
assert_contains "$OUT" "DESVIO_BRANCH=integration" "branch is exported"
assert_contains "$OUT" "DESVIO_BASE=origin/main" "the resolved base is exported"
assert_contains "$OUT" "cwd=$BUILD" "cwd is the config directory"

# ---------------------------------------------------------------------------
it "arguments pass through untouched, including spaces"
setup
task_env
run_desvio run env --flag "two words"
assert_contains "$OUT" "args=--flag two words" "the task got both arguments"

# ---------------------------------------------------------------------------
it "the task owns the exit status"
setup
printf '#!/usr/bin/env bash\nexit 42\n' > "$BUILD/fail.sh"
chmod +x "$BUILD/fail.sh"
run_desvio run fail
assert_eq 42 "$STATUS" "42 out means 42 back"

# ---------------------------------------------------------------------------
it "with no name it lists the tasks and exits 2"
setup
task_env
printf '#!/usr/bin/env bash\n' > "$BUILD/other.sh"; chmod +x "$BUILD/other.sh"
printf '#!/usr/bin/env bash\n' > "$BUILD/locked.sh"; chmod -x "$BUILD/locked.sh"
run_desvio run

assert_eq 2 "$STATUS" "listing is not a success"
assert_contains "$OUT" "desvio run env" "it lists the env task"
assert_contains "$OUT" "desvio run other" "and the other one"
assert_contains "$OUT" "locked (not executable)" "and flags the one missing its bit"

# ---------------------------------------------------------------------------
it "an unknown task names what does exist"
setup
task_env
run_desvio run nope
assert_contains "$OUT" "no task 'nope'" "it says which name failed"
assert_contains "$OUT" "There is:" "and lists the alternatives"

# ---------------------------------------------------------------------------
it "a path-shaped name is refused"
setup
run_desvio run sub/dir
assert_contains "$OUT" "is a path, and run takes a bare name" "it refuses a path"

# ---------------------------------------------------------------------------
it "a task without its executable bit says so"
setup
printf '#!/usr/bin/env bash\n' > "$BUILD/locked.sh"; chmod -x "$BUILD/locked.sh"
run_desvio run locked
assert_contains "$OUT" "chmod +x" "it says how to fix it"

# ---------------------------------------------------------------------------
it "a directory with no tasks says what a task is"
setup
run_desvio run
assert_contains "$OUT" "no tasks next to" "it says there are none"
assert_contains "$OUT" "executable <name>.sh" "and what one looks like"

# ---------------------------------------------------------------------------
it "--config is honoured from an unrelated directory"
setup
task_env
cd "$TEST_TMP" || exit 1
unset DESVIO_CONFIG
OUT="$("$DESVIO_BIN" --config "$BUILD/desvio.conf" run env 2>&1)"; STATUS=$?
assert_eq 0 "$STATUS" "it ran"
assert_contains "$OUT" "cwd=$BUILD" "and still ran in the config directory"

# ---------------------------------------------------------------------------
it "help works without a config at all"
fixture_new
cd "$TEST_TMP" || exit 1
unset DESVIO_CONFIG
run_desvio help run
assert_eq 0 "$STATUS" "help does not need a config"
assert_contains "$OUT" "usage: desvio run" "and prints the usage"

finish
