# shellcheck shell=bash
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
  --bisect-gate     when the gate fails, re-run it over the merge chain to find
                    the branch that broke it. On a terminal desvio offers this
                    anyway; the flag answers yes up front, for unattended runs.
  --no-bisect-gate  never bisect, and never ask. Print the command instead.
  --forget <branch> ignore this branch's recorded rerere resolution and resolve
                    the conflict again from scratch. Repeatable. For when a
                    resolution was wrong and every build has been replaying it.

Use a pinned base to reproduce yesterday's build, or to sit out a broken
upstream. The merges replay the same way; only the floor moves.

  desvio build                    # the remote's default branch
  desvio build v1.4.0             # a release tag
  desvio build origin/main~10     # ten back
EOF
}

cmd_build() {
  # do_bisect starts EMPTY, not 0. The config that may also set it has not been
  # sourced yet — load_config runs below, after this loop — so "the user did not
  # pass a flag" and "the user passed --no-bisect-gate" have to stay
  # distinguishable until there is a config to fall back to.
  local base_ref="" assemble_only=0 keep_going=0 do_bisect=""
  local -a FORGET; FORGET=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --assemble-only)  assemble_only=1 ;;
      --no-resolve)     DESVIO_AUTO_RESOLVE=0 ;;
      --keep-going)     keep_going=1 ;;
      --bisect-gate)    do_bisect=1 ;;
      --no-bisect-gate) do_bisect=0 ;;
      --forget)         shift; [ $# -gt 0 ] || die "--forget needs a branch name"
                        FORGET+=("$1") ;;
      -h|--help)        cmd_build_usage; return 0 ;;
      -*)               die "unknown option: $1" ;;
      *)
        [ -z "$base_ref" ] || die "more than one base given: '$base_ref' and '$1'"
        base_ref="$1" ;;
    esac
    shift
  done

  load_config
  # Three values, not two: 1 bisect, 0 never, `ask` put the question to whoever
  # is watching. `ask` is the default because the answer is what the tool is
  # for — but only a terminal can be asked, so with no human there `ask`
  # degrades to the printed command and an unattended build never stalls.
  #
  # The flag wins over the config; the config knob exists to pin either answer
  # once. Resolved here rather than in the parse loop because DESVIO_BISECT_GATE
  # does not exist until load_config has sourced the config.
  [ -n "$do_bisect" ] || do_bisect="${DESVIO_BISECT_GATE:-ask}"
  acquire_build_lock
  [ -n "$base_ref" ] || base_ref="$DESVIO_BASE"

  local started_at; started_at=$(date '+%Y-%m-%d %H:%M')

  # Assembly replays commits that are already authored. Skip hooks: a pre-commit
  # gate that runs a typecheck would block a merge commit before deps exist.
  export LEFTHOOK=0 HUSKY=0 PRE_COMMIT_ALLOW_NO_CONFIG=1

  gitr config rerere.enabled true
  gitr config rerere.autoupdate true

  # Read the manifest BEFORE fetching: which remotes to fetch is derived from
  # what the manifest names, and a remote branch cannot be resolved until its
  # remote has been fetched. So the old single loop is now three ordered steps —
  # parse, fetch, resolve — and the order is the whole point.
  local -a BRANCHES OIDS NOTES MISSING STALE FAILED_REMOTES
  BRANCHES=(); OIDS=(); NOTES=(); MISSING=(); STALE=(); FAILED_REMOTES=()
  parse_manifest
  fetch_remotes

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

  resolve_manifest

  local base_subject base_when base_behind=""
  base_subject=$(gitr log -1 --format='%s' "$base")
  base_when=$(gitr log -1 --format='%cr' "$base")
  if [ "$base" != "$(gitr rev-parse "$DESVIO_BASE" 2>/dev/null || echo none)" ]; then
    base_behind=$(gitr rev-list --count "$base..$DESVIO_BASE" 2>/dev/null || echo "?")
    [ "$base_behind" = "0" ] && base_behind=""
  fi

  log "building ${B}$DESVIO_BRANCH${OFF} on $base_ref @ ${base:0:9}"
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
      printf '  %s%2d%s   %-38s %s\n' "$DIM" "$((i + 1))" "$OFF" "${BRANCHES[$i]}" "${OIDS[$i]:0:9}"
    done
  fi

  gitw checkout -q -B "$DESVIO_BRANCH" "$base"

  # ---------- merge ----------
  #
  # What one branch's merge can end in:
  #
  #   gitw merge --no-ff <topic>
  #        |
  #        +-- exit 0 ......................... clean
  #        |
  #        \-- exit non-zero
  #              |
  #              +-- no unmerged entries ...... rerere replayed a resolution
  #              |
  #              \-- unmerged entries remain
  #                       |
  #                    classify_conflicts   (one `ls-files -u` read: stages AND modes)
  #                       |
  #        +--------------+---------------+-----------------+
  #     content       deleted-by-them  deleted-by-us      other
  #    (markers)      (stages 1,2)     (stages 1,3)   (submodule, rename,
  #        |                \             /            dir/file collision)
  #        |                 \           /                  |
  #        |               decision cache: hit -> replay          |
  #        |                              miss -> ask, then       |
  #        |                                      apply and stage |
  #        |                                      AFTER the commit|
  #        |                          |                           |
  #        \--------------------------+---------------------------/
  #                                   |
  #                         resolve_conflict (markers only, by now)
  #                                   |
  #                    no markers, no unmerged entries, commit
  #
  # Parallel indexed arrays, not an associative one: /bin/bash on macOS is 3.2
  # and has no `declare -A`.
  local -a HOW NFILES SUBJECTS MERGES SUSPECT WHY DEAD EMPTY FAILED DECNOTE
  HOW=(); NFILES=(); SUBJECTS=(); MERGES=(); SUSPECT=(); WHY=(); DEAD=(); EMPTY=(); FAILED=(); DECNOTE=()
  # The classifier's output and the not-yet-recorded decisions. Declared here
  # rather than where they are filled because bash 3.2 with `set -u` aborts on
  # `${#arr[@]}` for an array that was never assigned, and the commonest build
  # is the one where no conflict ever happens.
  local -a CLASS BASE_BLOB SURV_BLOB PENDING_KEYS PENDING_ACTS PENDING_PATHS
  local -a SETTLED_PATHS
  CLASS=(); BASE_BLOB=(); SURV_BLOB=()
  PENDING_KEYS=(); PENDING_ACTS=(); PENDING_PATHS=(); SETTLED_PATHS=()
  local b before after n refs_before

  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    b="${BRANCHES[$i]}"; oid="${OIDS[$i]}"
    DESVIO_STEP="${DIM}[$((i + 1))/${#BRANCHES[@]}]${OFF} "
    before=$(gitw rev-parse HEAD)
    HOW+=("clean"); NFILES+=("0"); SUSPECT+=(""); WHY+=(""); DECNOTE+=("")
    # Empty until the branch actually produces a commit. A branch that was
    # already upstream produced none, and one that --keep-going abandoned was
    # never merged; there is nothing to check out for either, so neither can be
    # the branch a gate bisect accuses.
    MERGES+=("")
    SUBJECTS+=("$(gitw log -1 --format=%s "$oid")")

    # --forget: merge this one branch with rerere switched OFF, so the recorded
    # resolution cannot replay and the conflict comes back with its markers. The
    # forgetting itself happens below, once there is a live conflict to forget —
    # `git rerere forget` works on the CURRENT conflict, and with autoupdate on
    # there is no current conflict to speak of by the time a replay has staged
    # everything. Measured: forgetting after a replay drops the cache entry but
    # leaves the replayed content in the tree, which would commit the very
    # resolution you asked to be rid of.
    #
    # ${rr[@]+...} because expanding an empty array under `set -u` on bash 3.2
    # is an abort, not an empty string.
    local -a rr; rr=()
    if in_forget_list "$b"; then
      rr=(-c rerere.enabled=false)
      step "${YEL}$b${OFF} — --forget: ignoring any recorded resolution"
    fi

    # --no-ff so a contribution always produces a merge commit. A fast-forward
    # would leave HEAD^ pointing at the topic's own parent, and the before/after
    # comparison below would read the wrong range.
    if ! gitw ${rr[@]+"${rr[@]}"} merge --no-ff --no-edit -m "merge $b into $DESVIO_BRANCH" "$oid"; then
      if [ -z "$(gitw ls-files -u)" ] && gitw rev-parse -q --verify MERGE_HEAD >/dev/null; then
        # rerere replayed a known resolution: `git merge` still exits non-zero
        # and leaves MERGE_HEAD, but every conflicted path is already staged.
        # This is the common case once a conflict has been resolved once.
        assert_no_markers "$b" || return 1
        gitw commit --no-edit -q
        HOW[$i]="rerere"
        step "${YEL}$b${OFF} — conflict replayed from rerere"
      elif [ -z "$(gitw ls-files -u)" ]; then
        die "merge of '$b' failed without conflicts — inspect $DESVIO_WORKTREE"
      elif [ "$DESVIO_AUTO_RESOLVE" = "1" ]; then
        refs_before=$(snapshot_refs)
        snapshot_conflicted
        classify_conflicts
        forget_recorded "$b"
        if settle_conflicts "$b" "${SUBJECTS[$i]}"; then
          assert_refs_unchanged "$refs_before"
          assert_resolver_scope "$b"
          stage_settled "$b"
          [ -z "$(gitw ls-files -u)" ] ||
            die "'$b': the resolver left unmerged entries. Tree is at $DESVIO_WORKTREE."
          assert_no_markers "$b"
          # rerere.autoupdate is on, so committing here records the resolution
          # and the next build replays it without spending an agent.
          gitw commit --no-edit -q
          # AFTER the commit, and never before. rerere writes its postimage at
          # exactly this point for exactly this reason: a decision recorded any
          # earlier outlives a merge that --keep-going goes on to abandon, and
          # the next build then replays an answer to a question that was never
          # accepted by anything.
          record_decisions "$b"
          HOW[$i]="$SETTLE_HOW"
          DECNOTE[$i]="$SETTLE_NOTE"
          step "${YEL}$b${OFF} — $SETTLE_SAID"
          # The resolver removed every marker and still thinks the result is
          # broken. Markers cannot check that, so carry it to the summary, where
          # it is read, instead of leaving it in a transcript, where it is not.
          if [ -n "${RESOLVER_SUSPECT:-}" ]; then
            SUSPECT[$i]="$RESOLVER_SUSPECT"
            HOW[$i]="auto-resolved-suspect"
            step_warn "${YEL}$b${OFF} — the resolver was not sure: $RESOLVER_SUSPECT"
            [ "${DESVIO_SUSPECT:-warn}" = "fail" ] &&
              die "'$b': the resolver flagged its own resolution and
  DESVIO_SUSPECT=fail. Nothing further was merged.
    $RESOLVER_SUSPECT
  Transcript: $(resolver_log "$b")"
          fi
        else
          assert_refs_unchanged "$refs_before"
          if [ "$keep_going" = 1 ]; then
            step_warn "${YEL}$b${OFF} — unresolved, abandoning this branch (--keep-going)"
            gitw merge --abort || true
            FAILED+=("$b"); HOW[$i]="unresolved"
            continue
          fi
          conflict_death "$b" "the resolver could not finish it.
  Transcript: $(resolver_log "$b")"
        fi
      elif [ "$keep_going" = 1 ]; then
        # --keep-going means what its help text says: report the branch and carry
        # on. It cannot mean that only when a resolver was the thing that failed.
        step_warn "${YEL}$b${OFF} — conflict, abandoning this branch (--no-resolve --keep-going)"
        gitw merge --abort || true
        FAILED+=("$b"); HOW[$i]="unresolved"
        continue
      else
        # Forget before dying, not after: the conflict is left in the tree for
        # you to resolve by hand, and the commit you make there is what records
        # the replacement. Dying first would leave the stale entry in the cache
        # and your hand resolution would be overwritten by it on the next build.
        snapshot_conflicted
        classify_conflicts
        forget_recorded "$b"
        conflict_death "$b" "auto-resolution is off (--no-resolve)."
      fi
    fi

    after=$(gitw rev-parse HEAD)
    if [ "$before" = "$after" ]; then
      dead_branch_why "$i" "$b" "$oid" "$base"
      HOW[$i]="$DEAD_HOW"; WHY[$i]="$DEAD_WHY"
      # An empty branch is not a dead line. The line is right and the branch is
      # wrong, so it must not end up in a list headed "delete these".
      if [ "$DEAD_HOW" = "no commits" ]; then EMPTY+=("$b"); else DEAD+=("$b"); fi
    else
      n=$(gitw diff --name-only "$before..$after" | wc -l | tr -d ' ')
      NFILES[$i]="$n"
      MERGES[$i]="$after"
      step "${YEL}$b${OFF} → $(plural "$n" file)"
    fi
  done
  # Back to untagged: everything below is about the manifest as a whole, and a
  # line that inherited "[7/7] " from the last branch would be a lie.
  # shellcheck disable=SC2034  # read by common.sh's step/step_warn, another file
  DESVIO_STEP=""

  if [ "${#DEAD[@]}" -gt 0 ]; then
    warn "dead manifest lines: ${DEAD[*]}"
  fi
  if [ "${#EMPTY[@]}" -gt 0 ]; then
    warn "branches with no commits at all: ${EMPTY[*]}
  Keep the manifest lines. Check each branch's worktree for uncommitted work."
  fi

  if [ "$assemble_only" = 1 ]; then
    log "--assemble-only — assembled, skipping install and gate."
    # The same check build_summary ends with. Skipping the summary must not also
    # skip the verdict: --assemble-only is the flag a CI job reaches for, and
    # exit 0 over a build that dropped a branch is exactly the lie CI believes.
    if [ "${#FAILED[@]}" -gt 0 ]; then
      warn "left out of this build: ${FAILED[*]}"
      return 1
    fi
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
    # run_gate, not run_hook: a failing gate must not kill the script HERE.
    # Everything below — the attribution, the exit status, the hint — exists
    # only because the failure is caught. See run_gate for why this cannot be
    # spelled `run_hook desvio_verify || GATE_STATUS=$?`.
    run_gate desvio_verify
    # Save it NOW. Every bisect probe runs through run_gate too, so GATE_STATUS
    # by the end holds whatever the last probe returned — and the last probe is
    # often a passing one. Returning that would exit 0 from a build whose gate
    # failed, which is the one outcome none of this is allowed to produce.
    local gate_status="$GATE_STATUS"
    if [ "$gate_status" -ne 0 ]; then
      # No build_summary on this path. Its first line is "$DESVIO_NAME is
      # ready", and a green banner over a build that failed its gate is the
      # exact lie the gate exists to prevent.
      gate_failed_banner "$gate_status"
      # Ask only once the banner is on screen: the question is "now that you
      # have seen THIS, do you want to know which branch", and it has to be
      # answerable with no. `ask` with nobody to ask resolves to no.
      if [ "$do_bisect" = ask ]; then
        do_bisect=0
        if interactive && bisect_ask; then do_bisect=1; fi
      fi
      if [ "$do_bisect" = 1 ]; then
        bisect_gate "$base"
      else
        gate_failed_hint
      fi
      # The gate's own status, unchanged. `desvio build` exiting with the code
      # your gate exited with is what CI reads, and tests/test-assembly.sh
      # pins it at 3.
      return "$gate_status"
    fi
    gated="gate passed: desvio_verify"
  else
    warn "no desvio_verify hook — this build was not verified.
  A merge that produces no conflict can still be semantically broken. The gate
  is what catches it; without one you are trusting textual merge alone."
  fi

  build_summary "$started_at" "$base_ref" "$base" "$base_subject" "$base_when" \
    "$base_behind" "$gated"
}

# ---------- manifest ----------
#
# Three ordered steps, because each one needs the previous one's answer:
#
#   parse_manifest    text only. Fills BRANCHES and NOTES.
#   fetch_remotes     needs BRANCHES, to know which remotes to fetch at all.
#   resolve_manifest  needs the fetch, to see a remote branch. Fills OIDS.
#
# All three fill the caller's arrays rather than printing them. bash locals are
# dynamically scoped, so a `local -a BRANCHES` in cmd_build is what these
# assign to — which is the only way to hand back three parallel arrays in bash
# 3.2, where there is no `declare -A` and no nameref.

# parse_manifest — the manifest as text. No git, so it is safe before the fetch.
parse_manifest() {
  local raw line note
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
    BRANCHES+=("$line"); NOTES+=("$note")
  done < "$DESVIO_MANIFEST"
}

# fetch_remotes — fetch $DESVIO_REMOTE plus every remote the manifest names.
#
# $DESVIO_REMOTE first and always, even when no manifest line mentions it: the
# base is resolved against it.
#
# The two failures are not the same failure. $DESVIO_REMOTE is the project you
# follow and the floor every build stands on, so losing it is fatal, exactly as
# before. The others are other people's repositories — a fork gets deleted the
# day its PR lands, made private, renamed — and letting a stranger's housekeeping
# stop every one of your builds would end the one-command rebuild this tool
# exists for. Those warn, and the summary marks what they left stale.
fetch_remotes() {
  local i r s seen
  local -a fetch_list; fetch_list=("$DESVIO_REMOTE")
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    r=$(remote_of "${BRANCHES[$i]}")
    [ -n "$r" ] || continue
    seen=0
    for s in ${fetch_list+"${fetch_list[@]}"}; do
      [ "$s" = "$r" ] && { seen=1; break; }
    done
    [ "$seen" = 1 ] || fetch_list+=("$r")
  done

  for r in "${fetch_list[@]}"; do
    log "fetching $r"
    if gitr fetch "$r" --prune; then
      continue
    fi
    [ "$r" != "$DESVIO_REMOTE" ] || die "cannot fetch '$r'.
  Every build starts from it, so there is nothing to build on. Check the URL,
  the network and your credentials:
    git -C $DESVIO_REPO fetch $r"
    # `git fetch` is not atomic, so some refs may already have moved before it
    # gave up. That is harmless — git never leaves a half-written ref — but it
    # is why this says "the last successful fetch" and not "the OID you had".
    warn "cannot fetch '$r' — building on the refs from the last successful fetch"
    FAILED_REMOTES+=("$r")
  done
}

# resolve_manifest — every line to an OID, in ONE pass.
#
# One pass, not "check they all exist, then resolve them": a branch can move
# between two passes — a rebase in another worktree — and then the build is
# assembled from two different moments in time, which is the exact thing
# resolving up front is meant to rule out.
#
# A miss appends to MISSING *and* pushes a placeholder into OIDS, so BRANCHES,
# NOTES, OIDS and STALE stay index-aligned. The placeholder never survives: a
# non-empty MISSING dies below, before anything reads OIDS.
resolve_manifest() {
  local i line remote rest
  RESOLVED_OID=""; RESOLVED_FROM=""
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    line="${BRANCHES[$i]}"
    remote=$(remote_of "$line")

    if ! resolve_topic "$line"; then
      # Nothing under that name yet. If it names a remote, the remote's own
      # refspec may simply not cover it, or it may be a ref outside refs/heads
      # like pull/3206/head. One explicit fetch settles both.
      if [ -n "$remote" ]; then
        rest="${line#"$remote"/}"
        if fetch_topic_ref "$remote" "$rest"; then
          resolve_topic "$line" || true
        fi
      fi
    fi

    if [ -z "$RESOLVED_OID" ]; then
      MISSING+=("$line"); OIDS+=(""); STALE+=("0")
      continue
    fi

    # Stale only when the ref we actually used came from a remote we failed to
    # fetch. A line that resolved to a LOCAL branch is never stale, however
    # badly its same-named remote went — that remote was never consulted.
    STALE+=("$(topic_is_stale "$RESOLVED_FROM" "$remote")")
    OIDS+=("$RESOLVED_OID")
  done

  # A named branch that does not exist is a broken manifest, not a build. Warning
  # and carrying on produces the worst possible artefact: a green "ready" banner
  # over a build that is quietly missing the feature you asked for.
  [ "${#MISSING[@]}" -eq 0 ] || die "$DESVIO_MANIFEST names $(plural "${#MISSING[@]}" branch) that does not exist in $DESVIO_REPO:
$(missing_advice)
  Nothing was built. Comment a line out with '#' to sit it out for one build."
}

# topic_is_stale <resolved_from> <remote> — 1 when the ref used came from a
# remote this build could not reach.
topic_is_stale() {
  local from="$1" remote="$2" r
  [ "$from" = "remote" ] && [ -n "$remote" ] || { printf '0'; return 0; }
  for r in ${FAILED_REMOTES+"${FAILED_REMOTES[@]}"}; do
    [ "$r" = "$remote" ] && { printf '1'; return 0; }
  done
  printf '0'
}

# missing_advice — one block per missing line, naming every reading that fits.
#
# Both readings, never just the remote one. `nosuch/feature-x` is a perfectly
# ordinary local branch name — `feature/nested` is in this repo's own test suite
# — so telling someone their remote is missing when they meant a local branch
# sends them to fix the wrong thing.
missing_advice() {
  local line remote rest
  for line in "${MISSING[@]}"; do
    remote=$(remote_of "$line")
    printf '    %s\n' "$line"
    if [ -n "$remote" ]; then
      rest="${line#"$remote"/}"
      printf '      remote %s exists, but has no %s. Check the spelling, or\n' "$remote" "$rest"
      printf '      whether it was deleted since: git -C %s ls-remote %s\n' "$DESVIO_REPO" "$remote"
    else
      printf '      no local branch by that name'
      case "$line" in
        */*) printf ', and no remote named %s\n' "${line%%/*}"
             printf '      a remote branch: git -C %s remote add %s <url>\n' "$DESVIO_REPO" "${line%%/*}" ;;
        *)   printf '\n' ;;
      esac
      printf '      a local branch:  git -C %s branch %s <start-point>\n' "$DESVIO_REPO" "$line"
    fi
  done
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
  trap build_cleanup EXIT INT TERM
}

# One trap for the whole build: drop the lock, and put the worktree back on the
# integration branch if a bisect was in flight.
#
# The restore is not a courtesy. Probing checks out DETACHED commits, and
# assert_worktree_ours refuses to adopt a tree that is not on $DESVIO_BRANCH —
# so a Ctrl-C during a bisect would make the NEXT build die with "the worktree
# is on a detached HEAD", telling you to remove a worktree to fix a state that
# desvio itself left behind.
#
# DESVIO_BISECT_RESTORE is global and holds the OID rather than a flag: a trap
# body is evaluated when the trap FIRES, by which point a local is long out of
# scope and there would be nothing to restore to.
#
# `|| true` on each step because this runs from a trap, quite possibly on the
# way out of an already-failed build, and a restore that itself died would
# replace a useful error message with a useless one.
build_cleanup() {
  if [ -n "${DESVIO_BISECT_RESTORE:-}" ]; then
    gitw checkout -q --detach 2>/dev/null || true
    gitw reset -q --hard "$DESVIO_BISECT_RESTORE" 2>/dev/null || true
    gitw checkout -q "$DESVIO_BRANCH" 2>/dev/null || true
    DESVIO_BISECT_RESTORE=""
  fi
  rm -rf "$DESVIO_LOCK_DIR"
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

# ---------- --forget ----------
#
# rerere is the reason a second build is fast, and it is also the reason a BAD
# resolution is permanent: it is recorded the moment the merge commit is made,
# and every build after that replays it silently and reports a green
# "conflict replayed from rerere". Nothing in the summary distinguishes a
# resolution you trust from one that broke the gate three builds ago.
#
# --forget is the way out. Note that a REBASED branch does not need it: rerere
# keys on the text of the conflict, so a rebase produces a different conflict
# and the stale entry simply stops matching. --forget is for the case where you
# cannot rebase, or do not want to.
in_forget_list() {
  local want="$1" f
  # `${FORGET[@]+...}`: bash 3.2 with `set -u` aborts on an empty expansion,
  # and an empty forget list is the overwhelmingly common case.
  for f in ${FORGET[@]+"${FORGET[@]}"}; do
    [ "$f" = "$want" ] && return 0
  done
  return 1
}

# forget_recorded <topic> — drop this conflict's recorded resolution.
#
# Called only with a LIVE conflict in the tree, which is the whole subtlety:
# `git rerere forget` acts on the current conflict, and after a replay there is
# no current conflict left to act on. That is why the merge above runs with
# rerere disabled for a --forget branch — it is what keeps the markers and the
# unmerged entries around long enough for this to mean something.
#
# The merge ran with rerere off; the COMMIT does not. So the resolution made
# after this call is recorded normally, replacing what was forgotten, and one
# build fixes the cache permanently.
forget_recorded() {
  local topic="$1" i key
  in_forget_list "$topic" || return 0
  [ "${#CONFLICTED[@]}" -gt 0 ] || return 0

  # Two caches now, and forgetting only one is worse than forgetting neither:
  # git's entry would go, desvio's would survive, and the next build would
  # replay the very decision you asked to be rid of — with no agent call in the
  # output to show that anything was reused.
  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    case "${CLASS[$i]}" in content|other) continue ;; esac
    key=$(decision_key "${CONFLICTED[$i]}" "${CLASS[$i]}" "${BASE_BLOB[$i]}" "${SURV_BLOB[$i]}")
    decision_forget "$key"
  done

  # One call per path rather than one call for all of them. `git rerere forget`
  # fails on a path it never recorded — which is every stage-incomplete path, by
  # construction — and a single call spanning both classes reports failure for
  # the whole set, printing "nothing recorded to forget" over a content conflict
  # that was in fact just forgotten.
  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    [ "${CLASS[$i]}" = "content" ] || continue
    gitw rerere forget -- "${CONFLICTED[$i]}" >/dev/null 2>&1 ||
      step_warn "${YEL}$topic${OFF} — nothing recorded to forget for ${CONFLICTED[$i]}"
  done
  step "${YEL}$topic${OFF} — forgot the recorded resolution, resolving from scratch"
}

# branch_oids <branch> — how many distinct commits this LOCAL branch has ever
# pointed at, per its reflog. 1 means it was created and never moved: no commit,
# no merge, no reset. 0 means there is no reflog to go on (a fresh clone, an
# expired one, or a ref that is not a local branch at all).
#
# refs/heads/ explicitly, because a manifest line may name a remote-tracking ref
# and that ref's reflog counts FETCHES, not commits: `fork/feature-x` has
# exactly one entry after its first fetch however many commits it carries. Left
# unqualified, every remote line's first build would score 1 and be reported as
# having no commits of its own. Scoring it 0 makes the heuristic abstain, which
# is the honest answer — nothing on this side records what that branch did — and
# costs nothing, because the message it would have chosen ends in "look for
# uncommitted work in its worktree", and someone else's worktree is not yours to
# look in. For a remote line both messages come down to the same advice.
branch_oids() {
  gitr reflog show --format=%H "refs/heads/$1" 2>/dev/null | sort -u | grep -c . || true
}

# dead_branch_why <i> <branch> <oid> <base> — why did merging this contribute
# nothing? Sets DEAD_HOW (the summary's case label) and DEAD_WHY (the evidence).
#
# All the merge itself proves is that the tip was already reachable from HEAD.
# desvio used to call every such branch "already upstream" and tell you to drop
# the line, which is an assertion about a cause it never checked — and it is the
# WRONG advice for the most common cause. A branch cut from the base and never
# committed to also merges into nothing, and its tip carries an upstream
# commit's subject, so the summary reads as though your feature had landed when
# in fact it was never committed. Deleting that line loses the work.
#
# So: name the commit, always — that alone answers "landed where?" — and pick
# between three messages:
#
#   the tip is in the base, and the branch never moved → no commits of its own.
#     It is an upstream commit wearing your branch name.
#   the tip is in the base otherwise → the branch's own commits really are in
#     the base; upstream took them keeping the shas.
#   the tip is not in the base at all → an EARLIER manifest line already
#     brought it in; this one is a duplicate of that one.
#
# A branch that landed upstream via squash or rebase does not come through here
# at all: its commits are rewritten, so the merge still produces a commit — an
# empty one, reported as "0 files".
dead_branch_why() {
  local i="$1" b="$2" oid="$3" base="$4" j tip
  tip="${oid:0:9} ${SUBJECTS[$i]}"
  DEAD_HOW=""; DEAD_WHY=""

  if gitw merge-base --is-ancestor "$oid" "$base"; then
    # Topology cannot tell these two apart: a branch whose commits landed
    # upstream and a branch that never had any BOTH end up pointing at a commit
    # in the base, and in both cases `rev-list base..tip` is empty. The reflog
    # can: a branch that was created and never committed to has only ever
    # pointed at one commit. That is a hint, not a proof — reflogs expire and a
    # fresh clone has none — so it only ever selects between two messages that
    # both name the commit and let you judge.
    if [ "$(branch_oids "$b")" = 1 ]; then
      DEAD_HOW="no commits"
      DEAD_WHY="its tip is $DESVIO_BASE's own $tip"
      step_warn "${YEL}$b${OFF} — contributed NOTHING: it has no commits of its own.
  Its tip is a commit on $DESVIO_BASE:
    $tip
  Nothing was ever committed to this branch. Look for uncommitted work in its
  worktree BEFORE you drop the manifest line."
      return 0
    fi
    DEAD_HOW="already upstream"
    DEAD_WHY="its own commits are in $DESVIO_BASE, up to $tip"
    step_warn "${YEL}$b${OFF} — contributed NOTHING: its commits are already in $DESVIO_BASE, up to
    $tip
  Drop this manifest line."
    return 0
  fi

  for ((j = 0; j < i; j++)); do
    if gitw merge-base --is-ancestor "$oid" "${OIDS[$j]}"; then
      DEAD_HOW="already merged"
      DEAD_WHY="${BRANCHES[$j]}, earlier in the manifest, already contains it"
      step_warn "${YEL}$b${OFF} — contributed NOTHING: '${BRANCHES[$j]}' is merged above it and
  already contains its tip $tip. Drop one of the two lines."
      return 0
    fi
  done

  # Reachable from HEAD, not from the base, and not from any earlier line's tip
  # — so an earlier merge RESOLUTION brought the content in without the tip
  # being an ancestor of that line. Rare, and not worth a guess.
  DEAD_HOW="already merged"
  DEAD_WHY="something merged above it already contains $tip"
  step_warn "${YEL}$b${OFF} — contributed NOTHING: its tip $tip is already in the build,
  brought in by a branch above it. Drop this manifest line."
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

# ---------- conflict classification ----------
#
# Not every conflict is text with markers in it, and the ones that are not are
# exactly the ones git cannot remember. `git rerere` records a conflict only
# when it can express it as a preimage with markers, which needs all three index
# stages present. Drop a stage — one side deleted the file — and git records
# nothing: MERGE_RR stays empty, the path appears in `git rerere remaining`, and
# every future build re-asks the same question. That is not a slow path, it is
# an uncacheable one, and it has to be recognised before anything is handed to a
# resolver that was written for markers.
#
#   ls-files -u  ─┬─ any stage mode 160000 ──────────────► other   (submodule)
#                 ├─ path is a rename source ────────────► other
#                 ├─ path nests inside another conflict ─► other   (dir/file)
#                 ├─ stages 2 AND 3 ─────────────────────► content (markers)
#                 ├─ stage 2, no 3 ──────────────────────► deleted-by-them
#                 └─ stage 3, no 2 ──────────────────────► deleted-by-us
#
# `other` is never cached and never decided here: an agent that edits files
# cannot fix an index gitlink, and a rename/delete or a dir/file collision spans
# several paths at once, so deciding each path on its own can produce a result
# that is individually reasonable and jointly incoherent. Those keep going to
# the resolver, which is where they went before this function existed.
#
# Stage presence ALONE is not enough to tell these apart. A gitlink conflict can
# present stages 1,2,3 or 1,2 or 1,3 like any other path, so the mode has to be
# read too — which is why this parses `ls-files -u` rather than reusing the
# --diff-filter=U path list that snapshot_conflicted already has.
#
# One parse for the whole merge, not one git call per path.
classify_conflicts() {
  local rec meta path mode sha stage i j idx
  local -a stages gitlink ours theirs
  stages=(); gitlink=(); ours=(); theirs=()
  CLASS=(); BASE_BLOB=(); SURV_BLOB=()

  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    stages+=(""); gitlink+=("0"); ours+=(""); theirs+=("")
    CLASS+=("content"); BASE_BLOB+=(""); SURV_BLOB+=("")
  done
  [ "${#CONFLICTED[@]}" -gt 0 ] || return 0

  # `<mode> SP <oid> SP <stage> TAB <path>`, NUL-terminated so a path with a
  # newline in it stays one record.
  while IFS= read -r -d '' rec; do
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    read -r mode sha stage <<< "$meta"
    idx=-1
    for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
      if [ "${CONFLICTED[$i]}" = "$path" ]; then idx=$i; break; fi
    done
    [ "$idx" -ge 0 ] || continue
    stages[$idx]="${stages[$idx]}$stage"
    [ "$mode" = "160000" ] && gitlink[$idx]=1
    case "$stage" in
      1) BASE_BLOB[$idx]="$sha" ;;
      2) ours[$idx]="$sha" ;;
      3) theirs[$idx]="$sha" ;;
    esac
  done < <(gitw ls-files -u -z)

  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    if [ "${gitlink[$i]}" = "1" ]; then CLASS[$i]="other"; continue; fi
    case "${stages[$i]}" in
      *2*3*|*3*2*) CLASS[$i]="content" ;;
      *2*)         CLASS[$i]="deleted-by-them"; SURV_BLOB[$i]="${ours[$i]}" ;;
      *3*)         CLASS[$i]="deleted-by-us";   SURV_BLOB[$i]="${theirs[$i]}" ;;
      *)           CLASS[$i]="other" ;;
    esac
  done

  # A directory/file collision reaches us as two ordinary-looking paths, one
  # nested in the other. Decide either alone and you can end up keeping a file
  # and the directory that replaced it.
  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    for ((j = 0; j < ${#CONFLICTED[@]}; j++)); do
      [ "$i" = "$j" ] && continue
      case "${CONFLICTED[$j]}" in
        "${CONFLICTED[$i]}"/*) CLASS[$i]="other"; CLASS[$j]="other" ;;
      esac
    done
  done

  demote_renames
}

# A missing stage means "deleted" only if nothing on that side took the content
# over. When a side RENAMED the file, git can still present the old path with a
# stage missing, and answering "is this file still needed?" about the old path
# is answering the wrong question — the content lives on under a new name.
#
# Asked of each side separately, and only when there is a deletion class to
# demote, so an ordinary content-only conflict pays nothing for this.
demote_renames() {
  local i mb them us
  local -a renamed
  local any=0
  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    case "${CLASS[$i]}" in deleted-by-them|deleted-by-us) any=1; break ;; esac
  done
  [ "$any" = 1 ] || return 0

  mb=$(gitw merge-base HEAD MERGE_HEAD 2>/dev/null) || return 0
  [ -n "$mb" ] || return 0
  them=$(rename_sources "$mb" MERGE_HEAD)
  us=$(rename_sources "$mb" HEAD)

  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    # The trailing newline is put back here: command substitution ate the one
    # rename_sources printed, and without it the last name in the list can only
    # be matched by a pattern that would also match a longer path ending the
    # same way — which is the whole reason for wrapping the names in newlines.
    case "${CLASS[$i]}" in
      deleted-by-them) renamed="$them"$'\n' ;;
      deleted-by-us)   renamed="$us"$'\n' ;;
      *) continue ;;
    esac
    case "$renamed" in
      *$'\n'"${CONFLICTED[$i]}"$'\n'*) CLASS[$i]="other" ;;
    esac
  done
}

# rename_sources <from> <to> — the old names of everything renamed or copied
# between two trees, newline-wrapped at both ends so a caller can test for a
# whole line without matching a path that merely ends the same way.
#
# A path containing a newline defeats this test and is simply not matched, which
# fails toward "treat it as an ordinary deletion and ask" — the safe direction,
# and the one that costs an agent call rather than a wrong answer.
rename_sources() {
  local st old out=$'\n'
  while IFS= read -r -d '' st; do
    case "$st" in
      # The second field of a rename is read and thrown away: this function
      # answers what a path USED to be called, and `_` says so where a named
      # variable would only invite a reader to look for the use that is not there.
      R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' _; out="$out$old"$'\n' ;;
      *)     IFS= read -r -d '' old ;;
    esac
  done < <(gitw diff --name-status -M -C -z "$1" "$2" 2>/dev/null)
  printf '%s' "$out"
}

# ---------- settling a conflicted merge ----------
#
# Order is the whole point of this function. Every stage-incomplete path is
# decided and STAGED first, and only then does the marker resolver run — because
# resolve_with_claude discovers its own path set from --diff-filter=U rather
# than being handed one. Run it first and it is given a file with no markers in
# it and told to remove the markers, which is how a four-and-a-half-minute
# agent call gets spent hand-porting a change into a file the topic deleted.
#
# Returns non-zero to leave the tree for a human, exactly like resolve_conflict.
# Sets SETTLE_HOW / SETTLE_NOTE / SETTLE_SAID for the summary.
settle_conflicts() {
  local topic="$1" subject="$2"
  local i cls key act path
  local hits=0 asks=0 deleted=0 kept=0 content=0

  # A resolver that is never called cannot clear this, and the previous
  # branch's doubt must not be reported against this one.
  RESOLVER_SUSPECT=""
  PENDING_KEYS=(); PENDING_ACTS=(); PENDING_PATHS=(); SETTLED_PATHS=()

  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    path="${CONFLICTED[$i]}"; cls="${CLASS[$i]}"
    case "$cls" in
      content) content=1; continue ;;
      other)
        content=1
        step_warn "${YEL}$topic${OFF} — $path: a conflict desvio will not decide or cache (submodule, rename or directory clash)"
        continue ;;
    esac

    key=$(decision_key "$path" "$cls" "${BASE_BLOB[$i]}" "${SURV_BLOB[$i]}")
    if act=$(decision_lookup "$key"); then
      case "$act" in
        delete|keep) ;;
        *) die "'$topic': the decision recorded for
    $path
  says '$act', which is neither 'delete' nor 'keep'. Nothing has been staged.
  Remove $(decision_dir)/$key and build again to decide it afresh." ;;
      esac
      hits=$((hits + 1))
      step "${YEL}$topic${OFF} — $path: $act replayed from the decision cache"
    else
      resolve_deletion "$topic" "$subject" "$path" "$cls" || return 1
      act="$DELETION_VERDICT"
      asks=$((asks + 1))
      # A custom resolver that settled the index itself owns that outcome. It
      # was not desvio's decision, so desvio does not apply it again and does
      # not put it in a cache whose entries only desvio knows how to invalidate.
      if [ "$act" = "handled" ]; then
        SETTLED_PATHS+=("$path")
        step "${YEL}$topic${OFF} — $path: settled by the resolver hook"
        continue
      fi
      PENDING_KEYS+=("$key"); PENDING_ACTS+=("$act"); PENDING_PATHS+=("$path")
    fi

    apply_decision "$topic" "$path" "$act" || return 1
    SETTLED_PATHS+=("$path")
    case "$act" in
      delete) deleted=$((deleted + 1)) ;;
      keep)   kept=$((kept + 1)) ;;
    esac
  done

  if [ "$content" = 1 ]; then
    resolve_conflict "$topic" "$subject" || return 1
  fi

  settle_verdict "$content" "$hits" "$asks" "$deleted" "$kept"
}

# The three strings the summary and the step line are built from. Split out
# because deciding what happened is a different job from doing it, and the
# combinations — cached or asked, deleted or kept, with or without a marker
# resolution beside them — are the part that is easy to get quietly wrong.
settle_verdict() {
  local content="$1" hits="$2" asks="$3" deleted="$4" kept="$5"
  local parts=""

  if [ "$((deleted + kept))" -gt 0 ]; then
    [ "$deleted" -gt 0 ] && parts="$(plural "$deleted" file) deleted"
    if [ "$kept" -gt 0 ]; then
      [ -n "$parts" ] && parts="$parts, "
      parts="$parts$(plural "$kept" file) kept"
    fi
    if [ "$hits" -gt 0 ] && [ "$asks" -gt 0 ]; then
      parts="$parts · $hits replayed, $asks decided"
    elif [ "$hits" -gt 0 ]; then
      parts="$parts · replayed from the decision cache"
    else
      parts="$parts · decided and recorded"
    fi
  fi
  SETTLE_NOTE="$parts"

  if [ "$content" = 1 ]; then
    SETTLE_HOW="auto-resolved"
    SETTLE_SAID="conflict auto-resolved (recorded in rerere)"
    [ -n "$parts" ] && SETTLE_SAID="$SETTLE_SAID · $parts"
  elif [ "$asks" -gt 0 ]; then
    SETTLE_HOW="decided"
    SETTLE_SAID="delete/modify decided — $parts"
  else
    SETTLE_HOW="decided-cached"
    SETTLE_SAID="delete/modify replayed from the decision cache — $parts"
  fi

  # The branches above end in a `&&` test, whose status would otherwise become
  # this function's — and settle_conflicts reads that as "the resolver failed".
  return 0
}

# desvio runs the git command, never the agent. The agent answers one question
# and has no shell to act on its own answer with.
apply_decision() {
  local topic="$1" path="$2" act="$3"
  case "$act" in
    delete)
      gitw rm -f -q -- "$path" ||
        { warn "'$topic': could not remove $path"; return 1; } ;;
    keep)
      gitw add -- "$path" ||
        { warn "'$topic': could not stage $path"; return 1; } ;;
    *) die "'$topic': internal error — decision '$act' for $path" ;;
  esac
}

# Stage what the resolver touched, which is every conflicted path EXCEPT the
# ones settled above: `git rm` already staged those, and a pathspec that matches
# nothing — which is what a removed path is — makes `git add` exit non-zero.
#
# Existence in the worktree is NOT the test. A resolver may legitimately settle a
# content conflict by deleting the file (tests/test-markers.sh:63), and `git add`
# on a path that is gone but still in the index is how that removal gets staged.
stage_settled() {
  local topic="$1" i j settled
  local -a add; add=()
  for ((i = 0; i < ${#CONFLICTED[@]}; i++)); do
    settled=0
    for ((j = 0; j < ${#SETTLED_PATHS[@]}; j++)); do
      if [ "${SETTLED_PATHS[$j]}" = "${CONFLICTED[$i]}" ]; then settled=1; break; fi
    done
    [ "$settled" = 1 ] || add+=("${CONFLICTED[$i]}")
  done
  [ "${#add[@]}" -gt 0 ] || return 0
  gitw add -- "${add[@]}"
}

# record_decisions <topic> — write the answers this merge had to ask for.
#
# Called only after the merge commits. A failed write is not fatal: the cost is
# one agent call on the next build, which is exactly the cost of not having a
# cache at all, and stopping a finished build over it would be worse than the
# thing it is protecting against.
record_decisions() {
  local topic="$1" i
  [ "${#PENDING_KEYS[@]}" -gt 0 ] || return 0
  for ((i = 0; i < ${#PENDING_KEYS[@]}; i++)); do
    decision_record "${PENDING_KEYS[$i]}" "${PENDING_ACTS[$i]}" "${PENDING_PATHS[$i]}" "$topic" ||
      step_warn "${YEL}$topic${OFF} — could not record the decision for ${PENDING_PATHS[$i]}; the next build will ask again"
  done
  PENDING_KEYS=(); PENDING_ACTS=(); PENDING_PATHS=()
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
  $(resolver_log "$topic"), before re-running."
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
        # NOT "drop this line". The subject printed above is the base's, not
        # yours, and the work this branch was named for may still be sitting
        # uncommitted in its worktree.
        "no commits")       mark="${YEL}○${OFF}"; stat="${YEL}nothing was ever committed to this branch${OFF}" ;;
        "already merged")   mark="${YEL}○${OFF}"; stat="${YEL}contributed nothing — a branch above it already has it${OFF}" ;;
        "unresolved")       mark="${RED}✗${OFF}"; stat="${RED}left out — conflict unresolved${OFF}" ;;
        "auto-resolved")    mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · conflict auto-resolved${OFF}" ;;
        "auto-resolved-suspect")
                            mark="${YEL}!${OFF}"; stat="${YEL}$(plural "${NFILES[$i]}" file) · auto-resolved, and the resolver was NOT sure${OFF}" ;;
        "rerere")           mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · conflict replayed from rerere${OFF}" ;;
        # Two outcomes rerere can never produce, kept visibly apart from it:
        # these are the conflicts git refuses to record, decided by desvio.
        "decided")          mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · delete/modify decided${OFF}" ;;
        "decided-cached")   mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file) · delete/modify replayed from the decision cache${OFF}" ;;
        *)                  mark="${GRN}●${OFF}"; stat="${DIM}$(plural "${NFILES[$i]}" file)${OFF}" ;;
      esac
      if [ -n "${NOTES[$i]}" ]; then
        # The manifest's own syntax, so it reads as the line it came from. The
        # column is wide enough for a remote-prefixed name; a shorter one just
        # pads, and a longer one pushes its note right rather than truncating.
        printf "   %b %s%-38s%s %s# %s%s\n" "$mark" "$B" "${BRANCHES[$i]}" "$OFF" "$DIM" "${NOTES[$i]}" "$OFF"
      else
        printf "   %b %s%s%s\n" "$mark" "$B" "${BRANCHES[$i]}" "$OFF"
      fi
      printf "       %s%s%s\n" "$DIM" "${SUBJECTS[$i]}" "$OFF"
      printf "       %b\n" "$stat"
      # Which files, and whether an agent was spent on them. One `HOW` value per
      # branch cannot say that when a single merge deleted one file, kept
      # another and replayed a third from the cache.
      if [ -n "${DECNOTE[$i]}" ]; then
        printf "       %s%s%s\n" "$DIM" "${DECNOTE[$i]}" "$OFF"
      fi
      # The evidence for a "contributed nothing" verdict: the commit desvio
      # actually saw. Without it the line above is an assertion you have to take
      # on faith, and the subject two lines up actively misleads.
      if [ -n "${WHY[$i]}" ]; then
        printf "       %s%s%s\n" "$DIM" "${WHY[$i]}" "$OFF"
      fi
      # What the resolver was unsure about, and where to read the rest of it.
      # A clean merge tells you nothing; a resolver saying "I merged this and I
      # think it is broken" tells you a great deal, and it belongs here rather
      # than in a transcript nobody opens.
      if [ -n "${SUSPECT[$i]}" ]; then
        printf "       %s%s%s\n" "$YEL" "${SUSPECT[$i]}" "$OFF"
        printf "       %s%s%s\n" "$DIM" "$(resolver_log "${BRANCHES[$i]}")" "$OFF"
      fi
      # Staleness is its own axis, not another value of $stat: a stale branch can
      # still have merged cleanly, replayed from rerere, or been dropped, and one
      # field cannot carry both without a cross-product of states.
      if [ "${STALE[$i]}" = "1" ]; then
        printf "       %s%s%s\n" "$YEL" "STALE — $(remote_of "${BRANCHES[$i]}") could not be fetched this build" "$OFF"
      fi
    done
  fi

  # The mirror of "starting from" above, in the same label column: the block
  # that says what you got has to say what to check out to get at it. $DESVIO_NAME
  # in the banner is a display name and is usually not the branch.
  printf "\n %sbuilt as%s\n" "$B" "$OFF"
  printf "   %-14s %s\n" "$DESVIO_BRANCH" "${head_oid:0:9}"
  printf "   %-14s %s%s%s\n" "" "$DIM" "$DESVIO_WORKTREE" "$OFF"
  printf "   %-14s %s%s%s\n" "" "$DIM" "$gated" "$OFF"
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
