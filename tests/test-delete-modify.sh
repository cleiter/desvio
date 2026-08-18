#!/usr/bin/env bash
#
# The conflicts git cannot record.
#
# rerere keys a resolution on the conflict markers it wrote. A delete/modify
# conflict has no markers — the index holds stages 1 and 2 (or 1 and 3) and the
# working tree holds the surviving side's file, whole and ordinary — so rerere
# declines it, permanently: `git rerere remaining` lists it and MERGE_RR stays
# empty however many times you resolve it by hand.
#
# Everything below is about the two things desvio does instead: classify the
# conflict, and remember the answer itself.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- stubs ----------
#
# fake_claude_deletion <verdict> — a `claude` first on PATH that answers the
# deletion question with <verdict> (DELETE, KEEP, or any junk a test wants to
# see rejected), and resolves ordinary marker conflicts the way the real one is
# supposed to. One stub for both, because the interesting builds have both.
#
# Every invocation appends its argv to $ARGV_LOG and bumps $CALL_LOG, which is
# how the cache tests prove an agent call did NOT happen.
fake_claude_deletion() {
  local verdict="$1"
  FAKE_BIN="$TEST_TMP/fakebin"
  ARGV_LOG="$TEST_TMP/claude-argv.txt"
  CALL_LOG="$TEST_TMP/claude-calls.txt"
  UPATHS_LOG="$TEST_TMP/claude-upaths.txt"
  mkdir -p "$FAKE_BIN"
  : > "$ARGV_LOG"; : > "$CALL_LOG"; : > "$UPATHS_LOG"

  cat > "$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
printf 'x\n' >> "$CALL_LOG"
case "\$*" in
  *"delete/modify conflict"*)
    printf 'I checked the importers and the barrel files.\n%s\n' "$verdict" ;;
  *)
    # The marker resolver. Its path list is recorded too: the deletions must
    # already be staged by the time it runs, so they must not appear here.
    git diff --name-only --diff-filter=U >> "$UPATHS_LOG"
    for f in \$(git diff --name-only --diff-filter=U); do
      sed -e '/^<<<<<<</d' -e '/^=======\$/d' -e '/^>>>>>>>/d' "\$f" > "\$f.tmp"
      mv "\$f.tmp" "\$f"
    done
    printf 'RESOLVED\n' ;;
esac
EOF
  chmod +x "$FAKE_BIN/claude"
  unfake_claude
  export PATH="$FAKE_BIN:$PATH"
}

# unfake_claude — take every stub back off PATH. A warm-cache build has to pass
# with no `claude` reachable at all; a stub that merely counts calls could be
# wrong about being called, an absent binary cannot.
#
# Every directory holding a `claude`, not just this fixture's stub: each fixture
# prepends its own, so removing the newest merely uncovers the one before it —
# and the developer's real binary is on PATH underneath all of them, which is
# the one that must never be reached from a test.
unfake_claude() {
  local part rest="$PATH" out=""
  while [ -n "$rest" ]; do
    part="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
    if [ -x "$part/claude" ]; then continue; fi
    [ -n "$out" ] && out="$out:"
    out="$out$part"
  done
  export PATH="$out"
}

calls() { wc -l < "$CALL_LOG" 2>/dev/null | tr -d ' '; }

decisions() { ls "$BUILD/state/decisions" 2>/dev/null | wc -l | tr -d ' '; }

# upstream_delete <file> <subject> — origin/main removes a file. The mirror of
# upstream_commit, and the only way to build a deleted-by-us conflict.
upstream_delete() {
  (
    cd "$SEED" || exit 1
    git rm -q "$1"
    git commit -qm "$2"
    git push -q origin main
  )
}

# The everyday shape: one branch edits a file, a later branch deletes it.
setup_delete_modify() {
  fixture_new
  topic_branch editor file.txt "editor-line"
  topic_branch_delete remover file.txt
}

# ---------------------------------------------------------------------------
it "a delete/modify conflict is decided, applied and recorded"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "delete/modify decided" "the summary says it was decided"
assert_contains "$OUT" "1 file deleted" "and what the decision was"
assert_eq 1 "$(calls)" "the agent was asked exactly once"
assert_eq 1 "$(decisions)" "and the answer was recorded"
if [ -e "$WORKTREE/file.txt" ]; then
  fail "the file is gone from the build tree" "$WORKTREE/file.txt still exists"
else ok "the file is gone from the build tree"; fi
assert_eq "" "$(git -C "$REPO" ls-tree -r --name-only refs/heads/integration -- file.txt)" \
  "and gone from the committed tree"

# ---------------------------------------------------------------------------
# The whole point. rerere replays a content conflict from its cache; nothing
# replays a delete/modify, so desvio has to.
it "the recorded decision replays with no claude on PATH at all"
run_desvio build     # same fixture, same decision, second build
first_calls=$(calls)
unfake_claude
run_desvio build

assert_eq 0 "$STATUS" "the second build succeeds"
assert_contains "$OUT" "replayed from the decision cache" "it says where the answer came from"
assert_not_contains "$OUT" "deciding with" "and did not ask again"
assert_eq "$first_calls" "$(calls)" "the agent was not invoked"

# ---------------------------------------------------------------------------
it "KEEP keeps the surviving side"
setup_delete_modify
fake_claude_deletion KEEP
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "1 file kept" "the summary says it was kept"
if tree_has file.txt editor-line; then ok "the surviving side's change is in the tree"
else fail "the surviving side's change is in the tree" "file.txt: $(cat "$WORKTREE/file.txt" 2>&1)"; fi

# ---------------------------------------------------------------------------
# The mirror case: upstream (or an earlier topic) removed the file and the topic
# being merged is the one that still has it. Same question, opposite sides —
# and the code has to name them the right way round to ask it.
it "a deleted-by-us conflict is decided too"
fixture_new
upstream_delete shared.txt "base: drop shared"
git -C "$REPO" fetch -q origin
topic_branch keeper shared.txt "topic-line" "origin/main~1"
fake_claude_deletion KEEP
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest keeper
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "deleted-by-us" "the class is named"
assert_contains "$OUT" "1 file kept" "and the decision applied"

# ---------------------------------------------------------------------------
# Half the value of the cache is that it survives the branch being rewritten:
# a rebase changes every OID and none of the content, and rerere would still
# replay. The key is the path, the class and the blobs — never the topic OID.
it "the decision survives a rebase of the topic branch"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build
assert_eq 1 "$(calls)" "the first build asked"

upstream_commit shared.txt "unrelated" "base: fifth"
git -C "$REPO" fetch -q origin
git -C "$REPO" rebase -q origin/main remover >/dev/null 2>&1
git -C "$REPO" rebase -q origin/main editor  >/dev/null 2>&1
git -C "$REPO" checkout -q main
unfake_claude
run_desvio build

assert_eq 0 "$STATUS" "the rebuilt branches still merge"
assert_contains "$OUT" "replayed from the decision cache" "the decision replayed"

# ---------------------------------------------------------------------------
# Same content, different file: a component that is dead in one place can be a
# live route in another, so the path is part of the question and part of the key.
it "identical content at a different path is a different question"
fixture_new
cp "$REPO/file.txt" /dev/null 2>/dev/null || true
printf 'same\ncontent\n' > "$REPO/a.txt"
printf 'same\ncontent\n' > "$REPO/b.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "two identical files"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
topic_branch edit-a a.txt "edit"
topic_branch_delete kill-a a.txt
topic_branch edit-b b.txt "edit"
topic_branch_delete kill-b b.txt

fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest edit-a kill-a
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"
assert_eq 1 "$(calls)" "a.txt was asked about"

manifest edit-b kill-b
run_desvio build
assert_eq 0 "$STATUS" "the second build succeeds"
assert_eq 2 "$(calls)" "b.txt was asked about separately"

# ---------------------------------------------------------------------------
it "a decision file that says something else stops the build"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build
assert_eq 0 "$STATUS" "the first build succeeds"

for f in "$BUILD"/state/decisions/*; do printf 'maybe\n' > "$f"; done
run_desvio build
if [ "$STATUS" -ne 0 ]; then ok "the second build fails"; else fail "the second build fails" "got 0"; fi
assert_contains "$OUT" "neither 'delete' nor 'keep'" "it says what is wrong with the file"
assert_contains "$OUT" "Nothing has been staged" "and that it did not act on it"

# ---------------------------------------------------------------------------
# Order inside one merge. resolve_with_claude rediscovers its own path set from
# --diff-filter=U, so a deletion still sitting unmerged when it runs is handed
# to it as a file to remove markers from — and it has none. Every deletion is
# decided and staged BEFORE the marker resolver is invoked.
it "a mixed merge decides the deletion before the marker resolver runs"
fixture_new
topic_branch editor file.txt "editor-line"
git -C "$REPO" checkout -q -B mixed origin/main
git -C "$REPO" rm -q file.txt
printf 'topic\n' >> "$REPO/shared.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "mixed: delete one file, edit another"
git -C "$REPO" checkout -q main
topic_branch other-editor shared.txt "other-line"
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor other-editor mixed
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "auto-resolved" "the marker conflict was resolved"
assert_contains "$OUT" "1 file deleted" "and the deletion reported beside it"
assert_contains "$(cat "$UPATHS_LOG")" "shared.txt" "the marker resolver saw the content conflict"
assert_not_contains "$(cat "$UPATHS_LOG")" "file.txt" "and was never handed the deleted path"

# ---------------------------------------------------------------------------
# A submodule presents exactly like a file — stages 1 and 2, no markers — and a
# resolver with Read and Grep cannot fix an index gitlink whatever it decides.
# The mode is the only thing that tells them apart, which is why the classifier
# reads modes and not just stage numbers.
it "a conflicting submodule is not decided and not cached"
fixture_new
sub=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" update-index --add --cacheinfo "160000,$sub,sub"
git -C "$REPO" commit -qm "add a submodule"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B bumper origin/main
bumped=$(git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse HEAD^{tree})" -m x -p "$sub")
git -C "$REPO" update-index --add --cacheinfo "160000,$bumped,sub"
git -C "$REPO" commit -qm "bumper: move the submodule"
git -C "$REPO" checkout -q -B unsub origin/main
git -C "$REPO" rm -q --cached sub
git -C "$REPO" commit -qm "unsub: drop the submodule"
git -C "$REPO" checkout -q main
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest bumper unsub
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build stops rather than guessing"; else fail "the build stops rather than guessing" "got 0"; fi
assert_contains "$OUT" "will not decide or cache" "it says why it will not touch it"
assert_eq 0 "$(decisions)" "and recorded nothing"

# ---------------------------------------------------------------------------
# A missing stage means "deleted" only if nothing on that side took the content
# over. Rename detection normally spares the merge this entirely; turn it off
# and the old path arrives looking exactly like a deletion, which is the shape
# a big enough rename limit produces on a real repository.
it "a renamed file is not mistaken for a deleted one"
fixture_new
git -C "$REPO" config merge.renames false
topic_branch editor file.txt "editor-line"
topic_branch_rename mover file.txt moved.txt
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor mover
run_desvio build

assert_contains "$OUT" "will not decide or cache" "it refuses to answer about the old path"
assert_not_contains "$OUT" "deleted-by-them" "it was never put as a deletion question"
assert_eq 0 "$(decisions)" "and nothing was cached"

# ---------------------------------------------------------------------------
# A space proves nothing about a NUL-delimited parser; a tab and a newline do.
# `ls-files -u` is read with -z for exactly this, and the classifier splits the
# record on the first tab, which a path containing tabs would break if it split
# on the last.
it "a path containing a tab and a newline is classified correctly"
fixture_new
weird=$'we\tird
name.txt'
printf 'one\n' > "$REPO/$weird"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "a path with a tab and a newline in it"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B weird-editor origin/main
printf 'editor\n' >> "$REPO/$weird"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "weird-editor: edit it"
git -C "$REPO" checkout -q -B weird-remover origin/main
git -C "$REPO" rm -q -- "$weird"
git -C "$REPO" commit -qm "weird-remover: delete it"
git -C "$REPO" checkout -q main
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest weird-editor weird-remover
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "1 file deleted" "the deletion was decided, not mishandled"
assert_eq 1 "$(decisions)" "and recorded once"

# ---------------------------------------------------------------------------
it "an answer that is not DELETE or KEEP stops the build"
setup_delete_modify
fake_claude_deletion "probably delete it"
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "did not end with DELETE or KEEP" "it says what it wanted"
assert_eq 0 "$(decisions)" "and cached nothing"

# ---------------------------------------------------------------------------
# The flags are the sandbox. A verdict is one word: it needs no write tool, and
# the ones it does not need are named on --disallowed-tools rather than merely
# left off, because "not mentioned" is not the same as "denied".
it "the deletion resolver is invoked read-only"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build
assert_eq 0 "$STATUS" "the build succeeds"

# argv_has <flag> <value> — adjacency, not substring: --allowed-tools Read and
# --disallowed-tools Read differ by exactly this.
argv_has() {
  local want_flag="$1" want_val="$2" prev="" line
  while IFS= read -r line; do
    if [ "$prev" = "$want_flag" ] && [ "$line" = "$want_val" ]; then return 0; fi
    prev="$line"
  done < "$ARGV_LOG"
  return 1
}
assert_argv() {
  if argv_has "$1" "$2"; then ok "$3"
  else fail "$3" "expected '$1 $2' in the argv desvio passed claude:
$(cat "$ARGV_LOG")"; fi
}
assert_argv --allowed-tools Read     "Read is allowed"
assert_argv Read Grep                "Grep is allowed"
assert_argv Grep Glob                "Glob is allowed"
assert_argv --disallowed-tools Bash  "Bash is denied"
assert_argv Bash Task                "Task is denied"
assert_argv WebSearch Edit           "Edit is denied"
assert_argv Edit Write               "Write is denied"
assert_argv Write NotebookEdit       "NotebookEdit is denied"
assert_not_contains "$(cat "$ARGV_LOG")" "acceptEdits" "and it is not run in an edit-accepting mode"

# ---------------------------------------------------------------------------
# The flags above are a request, not a boundary. assert_resolver_scope exists in
# this codebase for the same reason: check the tree, do not trust the prompt.
it "a deletion resolver that edits the tree is caught"
setup_delete_modify
fake_claude_deletion DELETE
cat > "$TEST_TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'sneaky\n' >> file.txt
printf 'I had a look around.\nDELETE\n'
EOF
chmod +x "$TEST_TMP/fakebin/claude"
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "changed the working tree while answering" "it says what happened"
assert_eq 0 "$(decisions)" "and recorded nothing"

# ---------------------------------------------------------------------------
it "with no claude on PATH the build says so rather than guessing"
setup_delete_modify
fake_claude_deletion DELETE
unfake_claude
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "no 'claude' on PATH" "it names the missing binary"

# ---------------------------------------------------------------------------
# A config that replaces the resolver replaces it for this question too. Adding
# this code path must not quietly route deletions past a resolver someone chose.
it "a desvio_resolve_deletion hook is used instead of the agent"
setup_delete_modify
fake_claude_deletion KEEP
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_deletion() {
  printf "%s\n" "$3" >> "$DESVIO_STATE/asked"
  DELETION_VERDICT=delete
}'
manifest editor remover
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_eq "file.txt" "$(cat "$BUILD/state/asked" 2>/dev/null)" "the hook was asked, about that path"
assert_eq 0 "$(calls)" "and the agent was not"
assert_contains "$OUT" "1 file deleted" "the hook's answer was applied"

# ---------------------------------------------------------------------------
it "a hook that leaves DELETION_VERDICT unset stops the build"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_deletion() { return 0; }'
manifest editor remover
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "DELETION_VERDICT" "it names the thing the hook did not set"

# ---------------------------------------------------------------------------
# The older contract. A config with only desvio_resolve_conflict predates this
# code path entirely, so it gets the merge and is believed by its result, not
# its return code: if it settled the path, it owns the outcome.
it "a desvio_resolve_conflict hook that settles the path owns the outcome"
setup_delete_modify
fixture_config "DESVIO_AUTO_RESOLVE=1" '
desvio_resolve_conflict() { gitw rm -q -f -- file.txt; }'
manifest editor remover
run_desvio build

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "settled by the resolver hook" "it says who settled it"
assert_eq 0 "$(ls "$BUILD/state/decisions" 2>/dev/null | wc -l | tr -d ' ')" \
  "and desvio cached no decision it did not make"

# ---------------------------------------------------------------------------
it "a desvio_resolve_conflict hook that cannot settle it is told why"
setup_delete_modify
fixture_config "DESVIO_AUTO_RESOLVE=1" "$(resolver_keep_both)"
manifest editor remover
run_desvio build

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "no markers to remove" "it explains the shape of the conflict"
assert_contains "$OUT" "desvio_resolve_deletion" "and names the hook to define"

# ---------------------------------------------------------------------------
it "--no-resolve leaves the delete/modify conflict in the tree"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config
manifest editor remover
run_desvio build --no-resolve

if [ "$STATUS" -ne 0 ]; then ok "the build fails"; else fail "the build fails" "got 0"; fi
assert_contains "$OUT" "auto-resolution is off" "it dies at the conflict"
assert_eq 0 "$(calls)" "no agent was invoked"
assert_eq 0 "$(decisions)" "and nothing was cached"

# ---------------------------------------------------------------------------
# Recorded after the commit, not before. A decision belonging to a merge that
# never landed would replay on the next build as though it had been agreed.
it "a branch abandoned by --keep-going records nothing"
fixture_new
topic_branch editor file.txt "editor-line"
git -C "$REPO" checkout -q -B doomed origin/main
git -C "$REPO" rm -q file.txt
printf 'topic\n' >> "$REPO/shared.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "doomed: delete one file, edit another"
git -C "$REPO" checkout -q main
topic_branch other-editor shared.txt "other-line"
fake_claude_deletion DELETE
# The marker half of the same merge gives up, so the branch is abandoned after
# the deletion was already decided.
cat > "$TEST_TMP/fakebin/claude" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "$CALL_LOG"
case "\$*" in
  *"delete/modify conflict"*) printf 'thought about it\nDELETE\n' ;;
  *) printf 'RESOLVED\n' ;;
esac
EOF
chmod +x "$TEST_TMP/fakebin/claude"
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor other-editor doomed
run_desvio build --keep-going

if [ "$STATUS" -ne 0 ]; then ok "the build reports the abandoned branch"; else fail "the build reports the abandoned branch" "got 0"; fi
assert_eq 0 "$(decisions)" "the decision from the abandoned merge was not recorded"

# ---------------------------------------------------------------------------
it "--assemble-only still decides deletions"
setup_delete_modify
fake_claude_deletion DELETE
fixture_config "DESVIO_AUTO_RESOLVE=1"
manifest editor remover
run_desvio build --assemble-only

assert_eq 0 "$STATUS" "the build succeeds"
assert_contains "$OUT" "1 file deleted" "the deletion was applied"
assert_eq 1 "$(decisions)" "and recorded"

finish
