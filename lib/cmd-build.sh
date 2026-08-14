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
  fi

  build_guards
  run_hook desvio_preflight

  # ---------- manifest ----------
  # Resolve every branch to an OID up front. A branch that moves mid-run (a
  # concurrent rebase in another worktree) must not assemble a build from two
  # different moments in time.
  local -a BRANCHES OIDS NOTES
  BRANCHES=(); OIDS=(); NOTES=()
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
      warn "SKIP $line — no such local branch"
      continue
    fi
    BRANCHES+=("$line"); OIDS+=("$oid"); NOTES+=("$note")
  done < "$DESVIO_MANIFEST"

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
        if resolve_conflict "$b" "${SUBJECTS[$i]}"; then
          assert_refs_unchanged "$refs_before"
          gitw add -A
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

# ---------- guards ----------
build_guards() {
  if [ -e "$DESVIO_WORKTREE/.git/MERGE_HEAD" ] || [ -n "$(gitw ls-files -u 2>/dev/null)" ]; then
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

# Restore anything that moved or vanished, then stop. Called after the resolver
# whatever its outcome.
assert_refs_unchanged() {
  local before="$1" now moved=0 oid ref cur
  now=$(snapshot_refs)
  # `if`, not `[ ... ] && return 0`: as the last command of a function, a false
  # test returns non-zero and under `set -e` that kills the caller.
  if [ "$now" = "$before" ]; then return 0; fi
  while read -r oid ref; do
    [ -n "${ref:-}" ] || continue
    cur=$(gitr rev-parse --verify --quiet "$ref" || true)
    if [ "$cur" != "$oid" ]; then
      warn "restoring $ref → ${oid:0:9} (was ${cur:-deleted})"
      gitr update-ref "$ref" "$oid"
      moved=1
    fi
  done <<< "$before"
  if [ "$moved" = 1 ]; then
    die "the resolver moved local branches. They have been restored from the
  pre-merge snapshot and the build stopped, so you can look at $DESVIO_REPO
  before anything else runs. This should be impossible — the resolver has no
  shell — so treat it as a bug in desvio, not a one-off."
  fi
  warn "new branches appeared during the merge — none of yours moved"
  return 0
}

# Never commit a conflict marker. rerere replays a resolution recorded from a
# DIFFERENT merge, so trust it exactly as far as the file content proves.
assert_no_markers() {
  local topic="$1" dirty
  # `|| true` twice on purpose: grep exits 1 when it finds nothing, which is the
  # GOOD case, and under `set -e` a bare assignment from a failing command
  # substitution kills the script with no message at all.
  dirty=$(gitw diff --cached --name-only |
    while read -r f; do
      [ -f "$DESVIO_WORKTREE/$f" ] || continue
      grep -lE '^(<<<<<<<|>>>>>>>)' "$DESVIO_WORKTREE/$f" 2>/dev/null || true
    done) || true
  [ -z "$dirty" ] || die "'$topic': conflict markers survived into the staged tree:
$(printf '    %s\n' $dirty)
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
