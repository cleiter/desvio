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

# ---------- deletions ----------
#
# resolve_deletion <topic> <subject> <path> <class>
#
# A delete/modify conflict has no markers in it. The file in the tree is the
# surviving side's, whole and unremarkable, and the question is not "merge these
# two texts" but "does this file still belong here at all?" — one bit, not a
# rewrite. Handing that to the marker resolver produces the single most
# expensive wrong answer available: it finds no markers, cannot delete anything
# because it has no shell, and so ports the other side's change into a file that
# side removed on purpose.
#
# Sets DELETION_VERDICT to `delete`, `keep`, or `handled` (a custom resolver
# settled the index itself, so desvio neither applies nor records anything).
# Returns non-zero to leave the tree for a human.
resolve_deletion() {
  local topic="$1" subject="$2" path="$3" cls="$4"
  DELETION_VERDICT=""

  # The documented hook first. A config that replaces the resolver replaces it
  # for THIS question too — otherwise adding this code path would quietly send
  # every deletion to the built-in agent, past a resolver someone chose on
  # purpose, and past the stub every test in this suite installs.
  if has_hook desvio_resolve_deletion; then
    desvio_resolve_deletion "$topic" "$subject" "$path" "$cls" || return 1
    case "${DELETION_VERDICT:-}" in
      delete|keep|handled) return 0 ;;
      *) warn "desvio_resolve_deletion left DELETION_VERDICT as '${DELETION_VERDICT:-}' for $path"
         return 1 ;;
    esac
  fi

  # A desvio_resolve_conflict hook without a desvio_resolve_deletion one: give
  # it the merge, then believe the index rather than its return code. If it
  # settled the path, it owns the outcome and desvio records nothing. If it did
  # not, say so plainly instead of silently reaching for the built-in agent
  # behind the hook's back.
  if has_hook desvio_resolve_conflict; then
    desvio_resolve_conflict "$topic" "$subject" || return 1
    if [ -z "$(gitw ls-files -u -- "$path")" ]; then
      DELETION_VERDICT="handled"
      return 0
    fi
    warn "desvio_resolve_conflict left $path unmerged.
  It is a delete/modify conflict, which has no markers to remove — define a
  desvio_resolve_deletion hook that sets DELETION_VERDICT to delete or keep."
    return 1
  fi

  resolve_deletion_with_claude "$topic" "$subject" "$path" "$cls"
}

resolve_deletion_with_claude() {
  local topic="$1" subject="$2" path="$3" cls="$4"
  local deleter survivor who gone log before after verdict

  command -v claude >/dev/null 2>&1 || {
    warn "no 'claude' on PATH — cannot decide the deletion of $path"
    return 1
  }

  # Which ref deleted it and which one still has it. Named rather than implied:
  # 'ours' and 'theirs' invert depending on the class, and getting that backwards
  # asks the agent to reason about the wrong side of the merge.
  case "$cls" in
    deleted-by-them) gone="MERGE_HEAD"; survivor="HEAD";       who="$topic" ;;
    deleted-by-us)   gone="HEAD";       survivor="MERGE_HEAD"; who="$DESVIO_BRANCH" ;;
    *) warn "resolve_deletion called with class '$cls' for $path"; return 1 ;;
  esac

  # The evidence. The agent has no shell, so it cannot go and find any of this
  # for itself: not the commit that removed the file, not its message, not what
  # the surviving side changed. Without it the only thing it can do is read the
  # file and guess, and a guess is what the reference-scan approach was rejected
  # for. Bounded, because a prompt is not a place to paste a whole history.
  deleter=$(gitw log -1 --format='%h %s%n%n%b' "$gone" -- "$path" 2>/dev/null | head -30)

  step "${YEL}$topic${OFF} — $path: $cls, deciding with $DESVIO_RESOLVER_MODEL (read-only, no shell)"

  log=$(resolver_log "$topic" "$path")
  before=$(worktree_fingerprint)
  (
    cd "$DESVIO_WORKTREE" || exit 1
    claude -p "You are deciding ONE question about a git merge conflict. Working directory: $DESVIO_WORKTREE

A topic branch is being merged into a disposable integration branch:
  topic:  $topic — \"$subject\"
  into:   $DESVIO_BRANCH, which is plain upstream plus earlier topics

The conflicted path is:
  $path

This is a delete/modify conflict. There are NO conflict markers anywhere — do
not go looking for any. '$who' DELETED this file. The other side modified it,
and the copy currently in the working directory is that surviving version, in
full and unmodified.

The commit that deleted it:
$deleter

Neither side is automatically right. Being merged later does not make a change
newer, and an integration branch can carry a deliberate refactor just as a topic
can. Decide on the evidence, not on which side is which.

Your job is to answer one question: after this merge, does anything still need
this file?

Read whatever you need to. Look for imports of it, re-exports of it through an
index or barrel file, and any convention by which a framework loads a file by
its PATH rather than by an import — a router directory is the usual example, and
a file loaded that way has no importers by design and is still very much alive.
If the deleting side moved the contents somewhere else, check that the new home
actually carries the behaviour the surviving side added.

You cannot edit anything and you have no shell. Do not try. Nothing you write
would be kept.

Explain your reasoning first, in a few sentences, naming the specific files you
checked. Then end your reply with EXACTLY ONE of these two words, alone on the
final line:

DELETE   — the deletion stands; nothing needs this file any more
KEEP     — the file must survive the merge; something still needs it" \
      --model "$DESVIO_RESOLVER_MODEL" \
      --effort "$DESVIO_RESOLVER_EFFORT" \
      --allowed-tools Read Grep Glob \
      --disallowed-tools Bash Task WebFetch WebSearch Edit Write NotebookEdit \
      --output-format text
  ) | tee "$log" | sed 's/^/       │ /'

  # A one-word answer needs no write tools, so it does not get any — but the
  # flags above are a request, and assert_resolver_scope exists in this codebase
  # precisely because a prompt is not a boundary. Check the tree rather than
  # trust the flag list: an agent that edited the survivor and then answered
  # KEEP would otherwise have its edit committed as part of the merge.
  after=$(worktree_fingerprint)
  if [ "$before" != "$after" ]; then
    warn "the deletion resolver changed the working tree while answering about
    $path
  It was given no write tools at all. Nothing has been staged or committed.
  Tree: $DESVIO_WORKTREE
  Transcript: $log"
    return 1
  fi

  # The verdict is the last non-empty line and nothing else. The transcript is
  # prose, and prose about a merge contains words like 'delete' in the middle of
  # sentences — a grep over the whole reply would eventually match one of them
  # and remove a file nobody agreed to remove.
  verdict=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1 |
            tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  case "$verdict" in
    DELETE) DELETION_VERDICT="delete" ;;
    KEEP)   DELETION_VERDICT="keep" ;;
    *)
      warn "the deletion resolver did not end with DELETE or KEEP for
    $path
  Its last line was: ${verdict:-(nothing)}
  Transcript: $log"
      return 1 ;;
  esac
  step "${YEL}$topic${OFF} — $path: $DELETION_VERDICT"
}

# Everything git can see about the working tree, in one string. Conflicted
# entries, modifications and untracked files all move it, which is the point:
# it is compared before and after an agent that is supposed to touch nothing.
worktree_fingerprint() {
  {
    gitw status --porcelain -z
    # Status codes alone are not enough: an unmerged path is reported `UD`
    # whatever its contents, so an agent that rewrote the surviving file would
    # leave the porcelain output identical. The diff is the part that moves.
    gitw diff
    gitw ls-files --others --exclude-standard -z
  } | git hash-object --stdin
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

  step "${YEL}$topic${OFF} — resolving with $DESVIO_RESOLVER_MODEL at $DESVIO_RESOLVER_EFFORT effort (no shell, files only)"
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
