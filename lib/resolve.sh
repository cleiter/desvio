# Conflict resolution.
#
# A conflict during assembly is never a question about YOUR branch. The topic is
# already authored; the merge only has to reconcile it with whatever upstream did
# since. That is mechanical enough to delegate, and delegating it is the
# difference between a fork you keep and a fork you abandon.
#
# YOUR BRANCHES ARE NEVER TOUCHED. Two independent reasons, not one:
#
#   1. The agent runs with NO shell tool, so it cannot run git at all, and its
#      file writes are confined to its working directory. Refs live in
#      $DESVIO_REPO/.git — outside the worktree — so no tool it has can reach
#      them. This is structural, not a promise.
#   2. Belt and braces: every branch OID except the integration branch is
#      snapshotted before the agent starts and verified after. Anything that
#      moved is restored with update-ref and the build stops.
#
# The agent only edits the conflicted files. Staging, committing and every
# verification is done by desvio, not by it. Your desvio_verify gate is the real
# backstop: a resolution that dropped a side or invented an API does not survive
# it.

# resolve_conflict <topic> <subject>
# Returns 0 if every marker is gone, non-zero to leave the tree for a human.
resolve_conflict() {
  if has_hook desvio_resolve_conflict; then
    desvio_resolve_conflict "$@"
    return $?
  fi
  resolve_with_claude "$@"
}

resolve_with_claude() {
  local topic="$1" subject="$2" files left
  files=$(gitw diff --name-only --diff-filter=U)

  command -v claude >/dev/null 2>&1 || {
    warn "no 'claude' on PATH — cannot auto-resolve"
    return 1
  }

  log "resolving with $DESVIO_RESOLVER_MODEL at $DESVIO_RESOLVER_EFFORT effort (no shell, files only)"
  printf '       %s\n' $files

  # Read/Edit/Write/Grep/Glob are enough to fix conflict markers, and all of them
  # are confined to the working directory. Everything that could reach a ref or
  # the network is denied.
  (
    cd "$DESVIO_WORKTREE"
    claude -p "You are resolving a git merge conflict in a build tree. Working directory: $DESVIO_WORKTREE

A topic branch is being merged into a disposable integration branch:
  topic:  $topic — \"$subject\"
  into:   $DESVIO_BRANCH, which is plain upstream plus earlier topics

Conflicted files (each contains <<<<<<< / ======= / >>>>>>> markers):
$files

'HEAD' is upstream. '$topic' is the local feature branch.

Your job:
- Edit ONLY the files listed above, and only their conflict regions plus whatever
  minimal surrounding code the merge needs to stay coherent.
- Remove every conflict marker.
- KEEP BOTH SIDES' BEHAVIOUR. Upstream changed this code for a reason and the
  topic added a feature to it; the merged result must do both. Deleting one
  side's logic to make the markers go away is the one unacceptable outcome.
- Read the surrounding file and any file it imports before deciding. Match the
  code around you.
- Do not run tests, do not reformat, do not fix unrelated things.

If a conflict cannot be resolved faithfully — the two sides genuinely contradict
each other and picking either loses behaviour — STOP, leave that file's markers
untouched, and end your reply with exactly UNRESOLVED on its own line, followed
by one sentence saying which file and why.

When you are done and every marker is gone, end your reply with exactly RESOLVED
on its own line." \
      --model "$DESVIO_RESOLVER_MODEL" \
      --effort "$DESVIO_RESOLVER_EFFORT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Edit Write Grep Glob \
      --disallowed-tools Bash Task WebFetch WebSearch \
      --output-format text
  ) | tee "$DESVIO_STATE/resolve-$topic.log" | sed 's/^/       │ /'

  # The agent's own verdict is a hint. Markers are the check.
  left=$(cd "$DESVIO_WORKTREE" && grep -lE '^(<<<<<<<|>>>>>>>)' -- $files 2>/dev/null || true)
  if [ -n "$left" ]; then
    warn "conflict markers still present in:"
    printf '       %s\n' $left
    return 1
  fi
  return 0
}
