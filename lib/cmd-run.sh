# desvio run — run a script that lives beside the config, with the config loaded.
#
# A build is not the end of the story: something has to start what came out,
# package it, install it. Those scripts are the project's business, not desvio's,
# but they all need the same three facts — where the tree is, what it is called,
# what it was built on. This hands them over rather than making each script
# rediscover them from its own $0.

cmd_run_usage() {
  cat <<'EOF'
usage: desvio run [<name>] [args...]

  <name>   a script <name>.sh sitting next to your desvio.conf. Everything
           after it is passed through untouched.

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
  local name="${1:-}"
  local found; found="$(run_tasks "$dir")"

  if [ -z "$name" ]; then
    if [ -z "$found" ]; then
      die "no tasks next to $DESVIO_CONFIG_FILE.
  A task is an executable <name>.sh in that directory. See: desvio help run"
    fi
    printf '\ntasks next to %s:\n\n' "$DESVIO_CONFIG_FILE"
    printf '%s\n' "$found" | sed 's/^/  desvio run /'
    printf '\n'
    return 2
  fi
  shift

  # A bare name only. A path would make the same command mean different things
  # from different directories, which is the problem this command exists to fix.
  case "$name" in
    -*)    die "unknown option: $name  (try: desvio help run)" ;;
    */*|.|..) die "'$name' is a path, and run takes a bare name — a <name>.sh
  beside $DESVIO_CONFIG_FILE. To run a script somewhere else, run it directly." ;;
  esac

  local script="$dir/$name.sh"
  if [ ! -f "$script" ]; then
    die "no task '$name' — nothing at $script
${found:+
  There is:
$(printf '%s\n' "$found" | sed 's/^/    /')}"
  fi
  [ -x "$script" ] || die "$script is not executable: chmod +x $script"

  # Absolute already — load_config put every path through config_relative.
  export DESVIO_REPO DESVIO_WORKTREE DESVIO_STATE DESVIO_MANIFEST \
         DESVIO_BRANCH DESVIO_NAME DESVIO_BASE DESVIO_REMOTE \
         DESVIO_CONFIG_FILE DESVIO_VERSION

  log "run $name${*:+ $*}"
  cd "$dir" || die "cannot enter $dir"
  # exec: the task owns the exit status and its own signals from here.
  exec "$script" "$@"
}
