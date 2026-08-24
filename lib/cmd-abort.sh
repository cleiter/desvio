# shellcheck shell=bash
# desvio abort — throw away the merge left half-finished in the build tree.
#
# A conflict desvio cannot resolve is left in place deliberately: resolving it
# by hand and committing is what teaches rerere the resolution, and every build
# after that replays it for free. That is the path worth taking.
#
# The other path is giving up on the branch — it is stale, upstream moved under
# it, you will rebase it tomorrow — and until now that meant leaving desvio
# behind: cd into a tree whose every message tells you never to edit it, run
# `git merge --abort` there, and cd back. This is that one git command, run
# where it belongs, by the tool that knows where the tree is.
#
# Deliberately nothing more. It does not touch the manifest, and it does not
# forget a recorded resolution — `desvio build --forget <branch>` is that, and
# an abort says nothing about whether the resolution you already have is right.

cmd_abort_usage() {
  cat <<'EOF'
usage: desvio abort

Throw away a merge left half-finished in the build tree — the state a conflicted
build leaves behind when it stops and asks you to resolve by hand.

The build tree goes back to the last merge that succeeded. Nothing else moves:
not your topic branches, not the manifest, not what rerere has recorded. The
build tree is rebuilt from the base on every run anyway, so there is nothing in
there to lose.

With no merge in progress it says so and exits 0 — safe to run without looking.

  desvio abort                      # give up on the conflict
  $EDITOR manifest.txt              # comment the branch out, or rebase it
  desvio build
EOF
}

cmd_abort() {
  case "${1:-}" in
    -h|--help) cmd_abort_usage; return 0 ;;
    "")        ;;
    *)         die "abort takes no arguments, and got '$1'  (try: desvio help abort)" ;;
  esac

  load_config

  # No tree at all — the first build never ran, or someone removed it. Nothing
  # to abort is the outcome asked for, so it is not an error: `desvio abort &&
  # desvio build` has to work on a machine that has never built.
  if ! gitr worktree list --porcelain | grep -qx "worktree $DESVIO_WORKTREE"; then
    log "no build tree at $DESVIO_WORKTREE — nothing to abort"
    return 0
  fi

  # The same guard the build runs before it writes anything: only ever touch a
  # tree that is demonstrably desvio's own. `git merge --abort` throws away
  # working-tree state, and a DESVIO_WORKTREE pointing at the upstream checkout
  # by typo would throw away yours.
  assert_worktree_ours

  # And the same lock, because this writes to the tree a build would be halfway
  # through using. Aborting under a running build would take that build's merge
  # out from under it.
  acquire_build_lock

  local merging line topic
  merging=$(gitw rev-parse -q --verify MERGE_HEAD 2>/dev/null || true)

  if [ -z "$merging" ]; then
    # An index with unmerged entries and no MERGE_HEAD is not a merge: it is
    # what a killed one leaves, and `git merge --abort` refuses it. reset --hard
    # is the way back, and it is safe here for the same reason the build's own
    # guards are — this tree is disposable.
    if [ -n "$(gitw ls-files -u 2>/dev/null)" ]; then
      gitw reset -q --hard HEAD ||
        die "cannot reset $DESVIO_WORKTREE — it is in a state git will not undo.
  Remove it and let the next build make a new one:
    git -C $DESVIO_REPO worktree remove --force $DESVIO_WORKTREE"
      log "no merge was in progress, but the index had conflicts left in it — reset"
      return 0
    fi
    log "no merge in progress at $DESVIO_WORKTREE — nothing to abort"
    return 0
  fi

  # Which branch it was. The merge loop writes "merge <branch> into <integration
  # branch>" as the message, so MERGE_MSG names the manifest line rather than a
  # sha nobody can place. Fall back to the subject if the message is not ours —
  # a merge you started by hand in there is still a merge worth aborting.
  line=$(in_tree sh -c 'f=$(git rev-parse --git-path MERGE_MSG); [ -f "$f" ] && head -1 "$f"' 2>/dev/null || true)
  case "$line" in
    "merge "*" into $DESVIO_BRANCH") topic="${line#merge }"; topic="${topic% into $DESVIO_BRANCH}" ;;
    *) topic="" ;;
  esac

  gitw merge --abort || die "git merge --abort failed in $DESVIO_WORKTREE.
  That tree is disposable — the next build recreates it from the base. If it
  will not come back, remove it:
    git -C $DESVIO_REPO worktree remove --force $DESVIO_WORKTREE"

  if [ -n "$topic" ]; then
    log "aborted the merge of ${YEL}$topic${OFF} ${DIM}(${merging:0:9})${OFF}"
  else
    log "aborted the merge of ${DIM}${merging:0:9}${OFF}  $(gitw log -1 --format=%s "$merging" 2>/dev/null || true)"
  fi
  printf '       %s\n' "the build tree is back on the last merge that succeeded"
  if [ -n "$topic" ]; then
    printf '       %s\n' "the next build will merge $topic again — comment it out of"
    printf '       %s\n' "$DESVIO_MANIFEST, or rebase it, if you want it left out"
  fi
}
