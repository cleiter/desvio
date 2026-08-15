# desvio run — run a script that lives beside the config, with the config loaded.
#
# A build is not the end of the story: something has to start what came out,
# package it, install it. Those scripts are the project's business, not desvio's,
# but they all need the same three facts — where the tree is, what it is called,
# what it was built on. This hands them over rather than making each script
# rediscover them from its own $0.

cmd_run_usage() {
  cat <<'EOF'
usage: desvio run [<name>...] [args...]

  <name>   a script <name>.sh sitting next to your desvio.conf. Several run in
           the order you name them, and the first failure stops the chain.
           After a single name, everything is passed through untouched.

With no name, lists what is there.

The script runs with the config loaded and exported, its cwd set to the config
directory, and these in the environment as absolute paths:

  DESVIO_WORKTREE  DESVIO_REPO   DESVIO_STATE   DESVIO_MANIFEST
  DESVIO_BRANCH    DESVIO_NAME   DESVIO_BASE    DESVIO_REMOTE
  DESVIO_CONFIG_FILE  DESVIO_VERSION

So a task is an ordinary script that reads $DESVIO_WORKTREE and needs no idea
where it was invoked from:

  : "${DESVIO_WORKTREE:?run this with: desvio run start}"

  desvio run package             # ./package.sh
  desvio run package --no-install
  desvio build && desvio run package install
EOF
}

# The tasks that exist, one per line, for listing and for error messages.
run_tasks() {
  local dir="$1" f name
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    if [ -x "$f" ]; then printf '%s\n' "$name"; else printf '%s (not executable)\n' "$name"; fi
  done
}

cmd_run() {
  case "${1:-}" in
    -h|--help) cmd_run_usage; return 0 ;;
  esac

  load_config
  local dir; dir="$(dirname "$DESVIO_CONFIG_FILE")"
  local found; found="$(run_tasks "$dir")"

  # Leading bare words are task names; the first flag ends the list and the rest
  # belongs to the task. `--` ends it explicitly, for a task whose own first
  # argument is a bare word.
  local names=() count=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -*) break ;;
      *)  names[$count]="$1"; count=$((count + 1)); shift ;;
    esac
  done

  if [ "$count" -eq 0 ]; then
    case "${1:-}" in
      -*) die "unknown option: $1  (try: desvio help run)" ;;
    esac
    if [ -z "$found" ]; then
      die "no tasks next to $DESVIO_CONFIG_FILE.
  A task is an executable <name>.sh in that directory. See: desvio help run"
    fi
    printf '\ntasks next to %s:\n\n' "$DESVIO_CONFIG_FILE"
    printf '%s\n' "$found" | sed 's/^/  desvio run /'
    printf '\n'
    return 2
  fi

  # Which of several tasks would "$@" belong to? There is no honest answer, so
  # refuse instead of guessing.
  if [ "$count" -gt 1 ] && [ $# -gt 0 ]; then
    die "arguments belong to one task, and you named $count: ${names[*]}
  Run that one on its own to pass '$*'."
  fi

  # Resolve every name BEFORE running anything: a typo in the last task must not
  # cost you the first one.
  local scripts=() i=0 name script
  while [ "$i" -lt "$count" ]; do
    name="${names[$i]}"
    # A bare name only. A path would make the same command mean different things
    # from different directories, which is the problem this command exists to fix.
    case "$name" in
      */*|.|..) die "'$name' is a path, and run takes a bare name — a <name>.sh
  beside $DESVIO_CONFIG_FILE. To run a script somewhere else, run it directly." ;;
    esac
    script="$dir/$name.sh"
    if [ ! -f "$script" ]; then
      die "no task '$name' — nothing at $script
${found:+
  There is:
$(printf '%s\n' "$found" | sed 's/^/    /')}"
    fi
    [ -x "$script" ] || die "$script is not executable: chmod +x $script"
    scripts[$i]="$script"
    i=$((i + 1))
  done

  # Absolute already — load_config resolves the config to an absolute path
  # first, then puts every path including DESVIO_REPO through config_relative.
  # That is what makes the `cd` below safe.
  export DESVIO_REPO DESVIO_WORKTREE DESVIO_STATE DESVIO_MANIFEST \
         DESVIO_BRANCH DESVIO_NAME DESVIO_BASE DESVIO_REMOTE \
         DESVIO_CONFIG_FILE DESVIO_VERSION

  cd "$dir" || die "cannot enter $dir"

  local last=$((count - 1)) status
  i=0
  while [ "$i" -lt "$count" ]; do
    if [ "$count" -gt 1 ]; then
      log "run ${names[$i]}  ($((i + 1))/$count)"
    else
      log "run ${names[$i]}${*:+ $*}"
    fi
    # The last one execs, so a single task — the common case — owns the exit
    # status and its own signals exactly as it did before chaining existed.
    if [ "$i" -eq "$last" ]; then
      exec "${scripts[$i]}" "$@"
    fi
    status=0
    "${scripts[$i]}" || status=$?
    # Fail fast. Packaging a tree whose gate never passed, or installing a bundle
    # that failed to build, is worse than stopping here.
    [ "$status" -eq 0 ] || die "task '${names[$i]}' failed (exit $status) — stopped before ${names[$((i + 1))]}"
    i=$((i + 1))
  done
}
