# desvio build — assemble every branch in the manifest onto a fresh base.
#
# This is git.git's `seen` workflow. Merge (not cherry-pick) because a merge
# resolves once against a whole topic, while cherry-pick replays commit by commit
# and makes stacked commits self-conflict.
#
# Your topic branches are never written to. The integration branch is disposable:
# it is recreated from scratch on every run, so never commit to it.

cmd_build_usage() {
  cat <<'EOF'
usage: desvio build [<base>] [options]

  <base>            what to build on. Anything git resolves to a commit: a
                    branch, a tag, a hash, origin/main~5. Defaults to the
                    remote's own default branch.

  --assemble-only   merge, then stop. No install, no gate.
  --no-resolve      never call the agent; stop at the first conflict.
  --keep-going      report a failed branch and carry on with the rest.

Use a pinned base to reproduce yesterday's build, or to sit out a broken
upstream. The merges replay the same way; only the floor moves.

  desvio build                    # the remote's default branch
  desvio build v1.4.0             # a release tag
  desvio build origin/main~10     # ten back
EOF
}

cmd_build() {
  local base_ref="" assemble_only=0 keep_going=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --assemble-only) assemble_only=1 ;;
      --no-resolve)    DESVIO_AUTO_RESOLVE=0 ;;
      --keep-going)    keep_going=1 ;;
      -h|--help)       cmd_build_usage; return 0 ;;
      -*)              die "unknown option: $1" ;;
      *)
        [ -z "$base_ref" ] || die "more than one base given: '$base_ref' and '$1'"
        base_ref="$1" ;;
    esac
    shift
  done

  load_config
  acquire_build_lock
  [ -n "$base_ref" ] || base_ref="$DESVIO_BASE"

  local started_at; started_at=$(date '+%Y-%m-%d %H:%M')

  # Assembly replays commits that are already authored. Skip hooks: a pre-commit
  # gate that runs a typecheck would block a merge commit before deps exist.
  export LEFTHOOK=0 HUSKY=0 PRE_COMMIT_ALLOW_NO_CONFIG=1

  gitr config rerere.enabled true
  gitr config rerere.autoupdate true

  log "fetching $DESVIO_REMOTE"
  gitr fetch "$DESVIO_REMOTE" --prune

  # Resolve the base ONCE and use the OID everywhere after. A branch ref is a
  # moving target, and resolving it twice in one run can straddle a fetch.
  local base
  base=$(gitr rev-parse --verify --quiet "$base_ref^{commit}") || die "cannot resolve '$base_ref' to a commit.
  It has to be something git knows about in $DESVIO_REPO — a branch, a tag, a
  hash. Remote branches need the '$DESVIO_REMOTE/' prefix. For a tag pushed
  since your last fetch: git -C $DESVIO_REPO fetch $DESVIO_REMOTE --tags"

  if ! gitr worktree list --porcelain | grep -qx "worktree $DESVIO_WORKTREE"; then
    log "creating build worktree at $DESVIO_WORKTREE"
    gitr worktree add -f -B "$DESVIO_BRANCH" "$DESVIO_WORKTREE" "$base"
  else
    assert_worktree_ours
  fi

  # Preflight before the guards, because the guards WRITE. desvio_preflight is
  # the config's veto — the Paseo example uses it to refuse a build while the
  # daemon is still running — and a veto that arrives after `reset --hard` has
  # already rewritten the tree is not a veto.
  run_hook desvio_preflight
  build_guards

  # ---------- manifest ----------
  # Resolve every branch to an OID up front. A branch that moves mid-run (a
  # concurrent rebase in another worktree) must not assemble a build from two
  # different moments in time.
  local -a BRANCHES OIDS NOTES MISSING
  BRANCHES=(); OIDS=(); NOTES=(); MISSING=()
  local raw line note oid
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    # Everything after the first `#` is why the line exists — the one piece of a
    # manifest you cannot recover from git. Carry it into the summary, which is
    # where you actually read it.
    note=""
    case "$raw" in
      *'#'*) note="$(printf '%s' "${raw#*#}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ;;
    esac
    if ! oid=$(gitw rev-parse --verify --quiet "refs/heads/$line^{commit}"); then
      MISSING+=("$line")
      continue
    fi
    BRANCHES+=("$line"); OIDS+=("$oid"); NOTES+=("$note")
  done < "$DESVIO_MANIFEST"

  # A named branch that does not exist is a broken manifest, not a build. Warning
  # and carrying on produces the worst possible artefact: a green "ready" banner
  # over a build that is quietly missing the feature you asked for. Nothing has
  # been written yet at this point, so dying here costs nothing.
  if [ "${#MISSING[@]}" -gt 0 ]; then
    die "$DESVIO_MANIFEST names $(plural "${#MISSING[@]}" branch) that does not exist in $DESVIO_REPO:
$(printf '    %s\n' "${MISSING[@]}")
  Nothing was built. Either create the branch, fix the spelling, or — if it
  landed upstream and you no longer need it — delete the line from the
  manifest. Comment it out with '#' to sit it out for one build."
  fi

  local base_subject base_when base_behind=""
  base_subject=$(gitr log -1 --format='%s' "$base")
  base_when=$(gitr log -1 --format='%cr' "$base")
  if [ "$base" != "$(gitr rev-parse "$DESVIO_BASE" 2>/dev/null || echo none)" ]; then
    base_behind=$(gitr rev-list --count "$base..$DESVIO_BASE" 2>/dev/null || echo "?")
    [ "$base_behind" = "0" ] && base_behind=""
  fi

  log "building $DESVIO_BRANCH on $base_ref @ ${base:0:9}"
  printf '       %s  (%s)\n' "$base_subject" "$base_when"
  if [ -n "$base_behind" ]; then
    warn "pinned base — $DESVIO_BASE is $(plural "$base_behind" commit) ahead of it"
  fi

  # An empty manifest is a legitimate build, not an error: it is what you want
  # when every branch has landed. Plain upstream, assembled and gated by the
  # same path as everything else.
  local i
  if [ "${#BRANCHES[@]}" -eq 0 ]; then
    warn "manifest lists no branches — building plain $base_ref"
  else
    # Index arithmetic, not "${!arr[@]}": under bash 3.2 (/bin/bash on macOS) an
    # empty array expansion with `set -u` is an unbound-variable abort, which is
    # exactly the empty-manifest case above.
    for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
      printf '       %-28s %s\n' "${BRANCHES[$i]}" "${OIDS[$i]:0:9}"
    done
  fi

  gitw checkout -q -B "$DESVIO_BRANCH" "$base"

  # ---------- merge ----------
  # Parallel indexed arrays, not an associative one: /bin/bash on macOS is 3.2
  # and has no `declare -A`.
  local -a HOW NFILES SUBJECTS DEAD FAILED
  HOW=(); NFILES=(); SUBJECTS=(); DEAD=(); FAILED=()
  local b before after n refs_before

  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    b="${BRANCHES[$i]}"; oid="${OIDS[$i]}"
    before=$(gitw rev-parse HEAD)
    HOW+=("clean"); NFILES+=("0")
    SUBJECTS+=("$(gitw log -1 --format=%s "$oid")")

    # --no-ff so a contribution always produces a merge commit. A fast-forward
    # would leave HEAD^ pointing at the topic's own parent, and the before/after
    # comparison below would read the wrong range.
    if ! gitw merge --no-ff --no-edit -m "merge $b into $DESVIO_BRANCH" "$oid"; then
      if [ -z "$(gitw ls-files -u)" ] && gitw rev-parse -q --verify MERGE_HEAD >/dev/null; then
        # rerere replayed a known resolution: `git merge` still exits non-zero
        # and leaves MERGE_HEAD, but every conflicted path is already staged.
        # This is the common case once a conflict has been resolved once.
        assert_no_markers "$b" || return 1
        gitw commit --no-edit -q
        HOW[$i]="rerere"
        log "  $b — conflict replayed from rerere"
      elif [ -z "$(gitw ls-files -u)" ]; then
        die "merge of '$b' failed without conflicts — inspect $DESVIO_WORKTREE"
      elif [ "$DESVIO_AUTO_RESOLVE" = "1" ]; then
        refs_before=$(snapshot_refs)
        snapshot_conflicted
        if resolve_conflict "$b" "${SUBJECTS[$i]}"; then
          assert_refs_unchanged "$refs_before"
          assert_resolver_scope "$b"
          gitw add -- "${CONFLICTED[@]}"
          [ -z "$(gitw ls-files -u)" ] ||
            die "'$b': the resolver left unmerged entries. Tree is at $DESVIO_WORKTREE."
          assert_no_markers "$b"
          # rerere.autoupdate is on, so committing here records the resolution
          # and the next build replays it without spending an agent.
          gitw commit --no-edit -q
          HOW[$i]="auto-resolved"
          log "  $b — conflict auto-resolved (recorded in rerere)"
        else
          assert_refs_unchanged "$refs_before"
          if [ "$keep_going" = 1 ]; then
            warn "  $b — unresolved, abandoning this branch (--keep-going)"
            gitw merge --abort || true
            FAILED+=("$b"); HOW[$i]="unresolved"
            continue
          fi
          conflict_death "$b" "the resolver could not finish it.
  Transcript: $DESVIO_STATE/resolve-$b.log"
        fi
      else
        conflict_death "$b" "auto-resolution is off (--no-resolve)."
      fi
    fi

    after=$(gitw rev-parse HEAD)
    if [ "$before" = "$after" ]; then
      warn "  $b — contributed NOTHING (already upstream). Delete this manifest line."
      DEAD+=("$b"); HOW[$i]="already upstream"
    else
      n=$(gitw diff --name-only "$before..$after" | wc -l | tr -d ' ')
      NFILES[$i]="$n"
      log "  $b → $(plural "$n" file)"
    fi
  done

  if [ "${#DEAD[@]}" -gt 0 ]; then
    warn "dead manifest lines: ${DEAD[*]}"
  fi

  if [ "$assemble_only" = 1 ]; then
    log "--assemble-only — assembled, skipping install and gate."
    return 0
  fi

  # ---------- install, build, gate ----------
  # All four are the config's business. desvio does not know what this project
  # is written in, and guessing npm would be wrong more often than it is right.
  if has_hook desvio_install; then
    run_hook desvio_install
  else
    warn "no desvio_install hook — skipping dependency install"
  fi
  run_hook desvio_seed
  run_hook desvio_build

  local gated="no gate configured — nothing verified this build"
  if has_hook desvio_verify; then
    log "gate: desvio_verify"
    run_hook desvio_verify
    gated="gate passed: desvio_verify"
  else
    warn "no desvio_verify hook — this build was not verified.
  A merge that produces no conflict can still be semantically broken. The gate
  is what catches it; without one you are trusting textual merge alone."
  fi

  build_summary "$started_at" "$base_ref" "$base" "$base_subject" "$base_when" \
    "$base_behind" "$gated"
}

# ---------- lock ----------
#
# One build at a time per config. Two runs share one worktree and one
# integration branch, so the second one's `reset --hard` lands in the middle of
# the first one's merge, and neither build is the build either of you asked for.
#
# mkdir, not flock(1): that is a util-linux tool and a stock macOS does not have
# it. mkdir is atomic everywhere, which is the only property a lock needs.
acquire_build_lock() {
  # Global, not local: the trap body is evaluated when the trap FIRES, by which
  # point a local would be long out of scope and the lock would leak.
  DESVIO_LOCK_DIR="$DESVIO_STATE/build.lock"
  local dir="$DESVIO_LOCK_DIR" pid
  if ! mkdir "$dir" 2>/dev/null; then
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another desvio build is already running (pid $pid).
  They would share the build tree at $DESVIO_WORKTREE and overwrite each
  other. Wait for it, or stop it and remove $dir."
    fi
    # A build killed with SIGKILL, or a machine that lost power, leaves the
    # directory behind with a pid nobody is using. Say so and take it.
    warn "stale build lock from pid ${pid:-unknown} — reclaiming it"
    rm -rf "$dir"
    mkdir "$dir" || die "cannot create the build lock at $dir"
  fi
  printf '%s' "$$" > "$dir/pid"
  # EXIT covers `die`, which exits 1.
  trap 'rm -rf "$DESVIO_LOCK_DIR"' EXIT INT TERM
}

# ---------- guards ----------
#
# The build tree is disposable and build_guards below will reset --hard and
# clean -fd it. That is only safe on a tree desvio made. `worktree list` also
# lists the primary checkout, so a config that points DESVIO_WORKTREE at
# $DESVIO_REPO — a plausible typo — takes the adopt path and lands here with
# your real work in it. Adopt only what is demonstrably ours: registered to
# this repo, and sitting on the disposable integration branch.
assert_worktree_ours() {
  local top branch
  top=$(physical_path "$(gitr rev-parse --show-toplevel)")
  [ "$DESVIO_WORKTREE" != "$top" ] || die "DESVIO_WORKTREE points at the upstream checkout itself:
    $DESVIO_WORKTREE
  That is where your work lives. The build tree is disposable — desvio resets
  and cleans it on every run — so it must be a separate directory. Fix
  DESVIO_WORKTREE in $DESVIO_CONFIG_FILE."

  branch=$(gitw symbolic-ref -q --short HEAD 2>/dev/null || true)
  [ "$branch" = "$DESVIO_BRANCH" ] || die "the worktree at $DESVIO_WORKTREE is on '${branch:-a detached HEAD}',
  not the integration branch '$DESVIO_BRANCH'. desvio only ever adopts its own
  build tree, because adopting one means resetting and cleaning it. If this
  really is a stale desvio tree, remove it:
    git -C $DESVIO_REPO worktree remove --force $DESVIO_WORKTREE"
}

build_guards() {
  # Ask git, do not stat a path: .git in a linked worktree is a FILE, so
  # $DESVIO_WORKTREE/.git/MERGE_HEAD can never exist and the test is dead. That
  # matters most in the case this guard exists for — a merge you resolved and
  # staged but have not committed has no unmerged entries either, so a dead
  # MERGE_HEAD test would fall through to the reset --hard below and delete the
  # resolution this very message tells you to make.
  if gitw rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || [ -n "$(gitw ls-files -u 2>/dev/null)" ]; then
    die "a merge is in progress at $DESVIO_WORKTREE. Finish it:
    cd $DESVIO_WORKTREE
    git status                      # see the conflicted files
    \$EDITOR <files>                 # resolve the <<<<<<< markers
    git add -A && git commit --no-edit
  then re-run. That teaches rerere the resolution and it replays on every
  future build. To give up instead: git merge --abort, comment the branch out
  of $DESVIO_MANIFEST, and re-run."
  fi

  if [ -n "$(gitw status --porcelain 2>/dev/null)" ]; then
    warn "build tree has local changes — discarding them (never edit in here)"
    gitw reset --hard --quiet
    gitw clean -fdq ${DESVIO_CLEAN_KEEP:+$DESVIO_CLEAN_KEEP}
  fi
}

conflict_death() {
  die "conflict merging '$1' — $2
  The conflict is LEFT IN PLACE. Resolve it by hand ONCE:
    cd $DESVIO_WORKTREE
    git status
    \$EDITOR <files>
    git add -A && git commit --no-edit
  Then re-run. rerere records the resolution and replays it next time."
}

# ---------- ref safety ----------
# Every local branch except the disposable integration branch.
snapshot_refs() {
  gitr for-each-ref --format='%(objectname) %(refname)' refs/heads |
    grep -v " refs/heads/$DESVIO_BRANCH\$" || true
}

# Report anything that moved or vanished, then stop. Called after the resolver
# whatever its outcome.
#
# It REPORTS, it does not rewind. desvio cannot tell "the resolver did this"
# from "you committed in another worktree while the agent was thinking", and
# the two want opposite responses. Restoring automatically gets the first case
# slightly faster and destroys a real commit in the second. Since the header
# comment is right that this path should be unreachable — the resolver has no
# shell — a firing here means our model of what happened is already wrong, and
# that is the worst possible moment to start writing refs. So: print the
# before/after OIDs and the exact command to undo it, and let a human choose.
assert_refs_unchanged() {
  local before="$1" now moved=0 oid ref cur restore=""
  now=$(snapshot_refs)
  # `if`, not `[ ... ] && return 0`: as the last command of a function, a false
  # test returns non-zero and under `set -e` that kills the caller.
  if [ "$now" = "$before" ]; then return 0; fi
  while read -r oid ref; do
    [ -n "${ref:-}" ] || continue
    cur=$(gitr rev-parse --verify --quiet "$ref" || true)
    if [ "$cur" != "$oid" ]; then
      warn "$ref moved: ${oid:0:9} → ${cur:-deleted}"
      restore="$restore    git -C $DESVIO_REPO update-ref $ref $oid
"
      moved=1
    fi
  done <<< "$before"
  if [ "$moved" = 1 ]; then
    die "local branches moved while the merge was running, and the build stopped
  before anything else could run. NOTHING has been restored — desvio cannot
  tell a misbehaving resolver from a commit you made in another worktree, and
  guessing wrong would throw away real work.

  Look at $DESVIO_REPO first. If the move was not yours, put them back with:
$restore
  The resolver has no shell, so it should not be able to reach a ref at all.
  If these moves were not yours either, treat it as a bug in desvio."
  fi
  warn "new branches appeared during the merge — none of yours moved"
  return 0
}

# ---------- resolver scope ----------
#
# The resolver is TOLD to edit only the conflicted files. An instruction in a
# prompt is not a boundary, so record the conflict set before it runs and check
# it after. Without this, `git add -A` would stage an adjacent file the agent
# helpfully "fixed" on the way past, and the merge commit would carry an edit
# nobody reviewed and no conflict asked for.
#
# NUL-delimited: a path with a space or a newline in it must not split into two.
snapshot_conflicted() {
  local p
  CONFLICTED=()
  while IFS= read -r -d '' p; do
    CONFLICTED+=("$p")
  done < <(gitw diff --name-only --diff-filter=U -z)
}

assert_resolver_scope() {
  local topic="$1" p c known
  local -a stray; stray=()
  [ "${#CONFLICTED[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' p; do
    known=0
    for c in "${CONFLICTED[@]}"; do
      if [ "$p" = "$c" ]; then known=1; break; fi
    done
    [ "$known" = 1 ] || stray+=("$p")
  done < <(
    gitw diff --name-only -z
    gitw ls-files --others --exclude-standard -z
  )
  [ "${#stray[@]}" -eq 0 ] || die "'$topic': the resolver touched files outside the conflict set:
$(printf '    %s\n' "${stray[@]}")
  It was asked to edit only the conflicted files. Nothing has been staged or
  committed. Look at the tree at $DESVIO_WORKTREE, and at the transcript in
  $DESVIO_STATE/resolve-$topic.log, before re-running."
}

# Never commit a conflict marker. rerere replays a resolution recorded from a
# DIFFERENT merge, so trust it exactly as far as the file content proves.
#
# NUL-delimited, because this check must not fail OPEN. Without -z, git QUOTES
# any path containing a space or a newline ("a b.ts" comes back with the quotes
# in it), the `[ -f ]` test below then misses the file, `continue` fires, and a
# staged conflict marker sails through the one assertion meant to catch it.
assert_no_markers() {
  local topic="$1" f
  local -a dirty; dirty=()
  while IFS= read -r -d '' f; do
    [ -f "$DESVIO_WORKTREE/$f" ] || continue
    # grep exits 1 when it finds nothing, which is the GOOD case, and under
    # `set -e` that would kill the script with no message at all.
    if grep -qE '^(<<<<<<<|>>>>>>>)' "$DESVIO_WORKTREE/$f" 2>/dev/null; then
      dirty+=("$f")
    fi
  done < <(gitw diff --cached --name-only -z)
  [ "${#dirty[@]}" -eq 0 ] || die "'$topic': conflict markers survived into the staged tree:
$(printf '    %s\n' "${dirty[@]}")
  Nothing was committed. Tree is at $DESVIO_WORKTREE."
}

# ---------- summary ----------
build_summary() {
  local started_at="$1" base_ref="$2" base="$3" base_subject="$4" base_when="$5"
  local base_behind="$6" gated="$7"
  local head_oid shortstat i mark stat
  head_oid=$(gitw rev-parse HEAD)
  shortstat=$(gitw diff --shortstat "$base..HEAD" | sed 's/^ *//')
  [ -n "$shortstat" ] || shortstat="no changes over the base"

  printf '\n'
  rule
  printf " %s%s%s   %s%s%s\n" "$GRN" "$DESVIO_NAME is ready" "$OFF" "$DIM" "$started_at" "$OFF"
  rule
  printf "\n %sstarting from%s\n" "$B" "$OFF"
  printf "   %-14s %s\n" "$base_ref" "${base:0:9}  $base_subject"
  printf "   %-14s %s%s%s\n" "" "$DIM" "committed $base_when" "$OFF"
  if [ -n "$base_behind" ]; then
    printf "   %-14s %s%s%s\n" "" "$YEL" "pinned — $DESVIO_BASE has $(plural "$base_behind" commit) you do NOT have" "$OFF"
  fi

  printf "\n %syour version adds%s   %s%s%s\n" "$B" "$OFF" "$DIM" "$shortstat" "$OFF"
  if [ "${#BRANCHES[@]}" -eq 0 ]; then
    printf "   %s%s%s\n" "$DIM" "nothing — plain upstream, no branches in the manifest" "$OFF"
  else
    # Three lines per branch: what it is called, what it does, what it cost.
    for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
      case "${HOW[$i]}" in
        "already upstream") mark="${YEL}○${OFF}"; stat="${YEL}already upstream — drop this manifest line${OFF}" ;;
        "unresolved")       mark="${RED}✗${OFF}"; stat="${RED}left out — conflict unresolved${OFF}" ;;
        "auto-resolved")    mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · conflict auto-resolved${OFF}" ;;
        "rerere")           mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · conflict replayed from rerere${OFF}" ;;
        *)                  mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file)${OFF}" ;;
      esac
      if [ -n "${NOTES[$i]}" ]; then
        # The manifest's own syntax, so it reads as the line it came from.
        printf "   %b %s%-28s%s %s# %s%s\n" "$mark" "$B" "${BRANCHES[$i]}" "$OFF" "$DIM" "${NOTES[$i]}" "$OFF"
      else
        printf "   %b %s%s%s\n" "$mark" "$B" "${BRANCHES[$i]}" "$OFF"
      fi
      printf "       %s%s%s\n" "$DIM" "${SUBJECTS[$i]}" "$OFF"
      printf "       %b\n" "$stat"
    done
  fi

  printf "\n %shead%s  %s   %s%s%s\n" "$B" "$OFF" "${head_oid:0:9}" "$DIM" "$DESVIO_WORKTREE" "$OFF"
  printf " %s%s%s\n" "$DIM" "$gated" "$OFF"
  rule

  if has_hook desvio_next_steps; then
    printf '\n'
    desvio_next_steps
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\n'
    warn "left out of this build: ${FAILED[*]}"
    return 1
  fi
}
