# shellcheck shell=bash
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
#      moved stops the build, names itself, and prints the update-ref that puts
#      it back. desvio does not run that command for you: it cannot tell a
#      misbehaving resolver from a commit you made in another worktree, and
#      rewinding the second one would destroy real work.
#
# The agent only edits the conflicted files. Staging, committing and every
# verification is done by desvio, not by it. Your desvio_verify gate is the real
# backstop: a resolution that dropped a side or invented an API does not survive
# it.

# resolve_conflict <topic> <subject>
#
# Returns 0 if every marker is gone, non-zero to leave the tree for a human.
#
# Also sets RESOLVER_SUSPECT: empty when the resolver is confident, otherwise
# one line saying what it thinks is still broken. A second return value needs a
# global — bash 3.2 has nothing better — and it is cleared here rather than in
# the resolvers so that a resolver which never sets it cannot leak the previous
# branch's doubt into this branch's summary line.
#
# A custom desvio_resolve_conflict hook may set RESOLVER_SUSPECT too; it is part
# of the hook's contract.
resolve_conflict() {
  RESOLVER_SUSPECT=""
  if has_hook desvio_resolve_conflict; then
    desvio_resolve_conflict "$@"
    return $?
  fi
  resolve_with_claude "$@"
}

resolve_with_claude() {
  local topic="$1" subject="$2" files f
  # An array as well as the text block: the block is what the prompt reads, the
  # array is what the marker check below greps. A path with a space in it must
  # not become two arguments there, or the check passes on a file it never read.
  local -a paths; paths=()
  while IFS= read -r -d '' f; do
    paths+=("$f")
  done < <(gitw diff --name-only --diff-filter=U -z)
  # Under bash 3.2 with `set -u`, expanding an empty array is an abort, not an
  # empty string — so check before, not after.
  [ "${#paths[@]}" -gt 0 ] || {
    warn "no conflicted files to resolve"
    return 1
  }
  files=$(printf '%s\n' "${paths[@]}")

  command -v claude >/dev/null 2>&1 || {
    warn "no 'claude' on PATH — cannot auto-resolve"
    return 1
  }

  log "resolving with $DESVIO_RESOLVER_MODEL at $DESVIO_RESOLVER_EFFORT effort (no shell, files only)"
  printf '       %s\n' "${paths[@]}"

  # Read/Edit/Write/Grep/Glob are enough to fix conflict markers, and all of them
  # are confined to the working directory. Everything that could reach a ref or
  # the network is denied.
  (
    # `|| exit` is not decoration here: without it a failed cd runs the agent,
    # in acceptEdits mode, against whatever directory we happen to be in.
    cd "$DESVIO_WORKTREE" || exit 1
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

A CONFLICT IS OFTEN ONLY HALF OF ONE CHANGE. Git may have merged the other half
CLEANLY, with no marker anywhere to show for it — upstream deleted an import, a
helper, a field, a style entry, and the topic moved or kept the code that uses
it. You will not see that in a conflict region, and it is the single commonest
way a merge with no markers left in it is still broken.

So once the markers are gone, read each conflicted file END TO END and check
that what the merged result now references still exists: imports, helpers,
types, constants, style keys, call signatures. Repairing that, in a file that
was already conflicted, is IN SCOPE and expected of you — it is part of the
merge, not an unrelated fix. What stays out of scope is other files and other
problems.

If a conflict cannot be resolved faithfully — the two sides genuinely contradict
each other and picking either loses behaviour — STOP, leave that file's markers
untouched, and end your reply with exactly UNRESOLVED on its own line, followed
by one sentence saying which file and why.

If you removed every marker but still believe the merged result is broken — a
symbol that no longer exists, a call whose signature moved, something you could
not repair from inside the conflicted files — end your reply with exactly
RESOLVED-SUSPECT on its own line, followed by one sentence saying what and
where. Say it here rather than only in prose: this line is the only part of your
reply desvio reads back, and it is what puts a warning next to this branch in
the build summary instead of a clean tick.

When you are done, every marker is gone, and you believe the result is sound,
end your reply with exactly RESOLVED on its own line." \
      --model "$DESVIO_RESOLVER_MODEL" \
      --effort "$DESVIO_RESOLVER_EFFORT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Edit Write Grep Glob \
      --disallowed-tools Bash Task WebFetch WebSearch \
      --output-format text
  ) | tee "$(resolver_log "$topic")" | sed 's/^/       │ /'

  # The agent's own verdict is a hint. Markers are the check.
  local -a left; left=()
  for f in "${paths[@]}"; do
    if grep -qE '^(<<<<<<<|>>>>>>>)' "$DESVIO_WORKTREE/$f" 2>/dev/null; then
      left+=("$f")
    fi
  done
  if [ "${#left[@]}" -gt 0 ]; then
    warn "conflict markers still present in:"
    printf '       %s\n' "${left[@]}"
    return 1
  fi

  # ...but a verdict the markers CANNOT check is worth keeping. RESOLVED-SUSPECT
  # means the agent removed every marker and still thinks the result is broken —
  # typically because the other half of a split change merged cleanly and it
  # could not repair it from inside the conflict set.
  #
  # This is additive information, never a veto: a false suspicion costs one
  # warning line, and the gate remains the thing that decides. Which is exactly
  # why it is worth reading — the one time this mattered in anger, the agent
  # said the file would not typecheck, said it in prose in a transcript nobody
  # opened, and the build printed a green tick over it.
  #
  # Read back from the transcript rather than capturing the pipeline twice: it
  # is already tee'd there, and the file is the thing the summary points at.
  local log; log=$(resolver_log "$topic")
  if [ -f "$log" ] && grep -q '^RESOLVED-SUSPECT' "$log"; then
    # The sentence after the verdict, if it gave one, else the verdict alone.
    RESOLVER_SUSPECT=$(sed -n 's/^RESOLVED-SUSPECT[[:space:]]*//p; /^RESOLVED-SUSPECT$/{n;p;}' "$log" |
      grep -v '^[[:space:]]*$' | head -1)
    [ -n "$RESOLVER_SUSPECT" ] || RESOLVER_SUSPECT="the resolver did not say what"
  fi
  return 0
}
