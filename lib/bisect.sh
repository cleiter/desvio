# shellcheck shell=bash
# Which branch broke the gate?
#
# The integration branch is a straight chain of merge commits — one per manifest
# branch, in manifest order, every one of them made by the run that is still in
# progress. So "which of my branches did this" is an answerable question: check
# out merge commit K, run the gate, and binary-search for the first K that fails.
#
# This exists because of one specific failure. Upstream deleted an import and
# three StyleSheet entries from a file; a topic branch had MOVED the code that
# used them into a new helper. Git merged the deletion CLEANLY and conflicted
# only on the usage. The resolver resolved the usage correctly and removed every
# marker — so every guard passed, and the result referenced five symbols that no
# longer existed. Three more branches merged on top, then the install, then the
# build, then eight typecheck errors in one file with nothing whatsoever
# connecting them to the branch that caused them.
#
# The search is only sound because it probes BOTH endpoints, and those two
# probes are not overhead — they are the two honest-failure answers:
#
#   the final assembly passes  → the probe gate does not reproduce it
#   the base fails             → it was never your manifest
#
# Everything between them is a directly observed pass→fail pair.

# ---------- the gate failed: say what happened ----------
#
# Printed on every gate failure, before the decision about bisecting is made,
# because none of it depends on that decision: the status, the tree, the
# resolver's leads and the warning not to fix anything in the build tree are
# true whether a bisect follows or not.
gate_failed_banner() {
  local status="$1" n=0
  n=$(bisect_candidate_count)
  printf '\n'
  rule
  printf " %s%s%s\n" "$RED" "the gate failed — this build is not usable" "$OFF"
  rule
  printf "\n desvio_verify exited %s. The tree is exactly as it failed:\n" "$status"
  printf "   %s   %s%s%s\n" "$DESVIO_BRANCH" "$DIM" "$DESVIO_WORKTREE" "$OFF"
  bisect_suspect_hint
  printf "\n Nothing above says WHICH of your %s did it, and it is very often not\n" \
    "$(plural "$n" branch)"
  printf " the one named in the error. A branch merges cleanly, four merge on top of\n"
  printf " it, and the gate reports a file none of them touched.\n"
  printf "\n Look, but do not fix it in the build tree — the next build resets and\n"
  printf " cleans it. Fixes belong on the topic branch in %s.\n" "$DESVIO_REPO"
}

# Not bisecting — declined, --no-bisect-gate, or nobody there to ask. Name the
# command instead of running it, so the answer stays one line away.
gate_failed_hint() {
  printf "\n %sTo find out WHICH — re-runs the gate over the merge chain:%s\n" "$B" "$OFF"
  printf "   desvio build --bisect-gate\n"
  bisect_quick_hint
  rule
}

# The single thing that makes a bisect cheap, said wherever the cost comes up —
# and only the first time. The prompt and the hint under it both want to raise
# it, and they can appear four lines apart.
BISECT_QUICK_HINTED=0
bisect_quick_hint() {
  has_hook desvio_verify_quick && return 0
  [ "$BISECT_QUICK_HINTED" = 0 ] || return 0
  BISECT_QUICK_HINTED=1
  printf "\n Make those runs cheap, with the fast half of your gate:\n"
  printf "   %sdesvio_verify_quick() { in_tree npm run typecheck; }%s\n" "$DIM" "$OFF"
}

# ---------- a human is here: offer the bisect ----------
#
# The question is asked AFTER the banner rather than instead of it, so the
# answer is never the price of seeing what failed — Ctrl-C, EOF or a stray
# newline at this prompt all leave you with the same output --no-bisect-gate
# would have given.
#
# Default yes. The prompt only appears when the gate has already failed and a
# human is watching, and at that point the answer is almost always "well, which
# branch was it" — that is the entire question this tool exists to answer.
bisect_ask() {
  local n reply
  n=$(bisect_candidate_count)
  printf "\n A bisect re-runs the gate over the merge chain — about %s more\n" \
    "$((3 + $(bisect_log2 "$n")))"
  printf " gate runs, and your %s stay untouched either way.\n" "$(plural "$n" branch)"
  bisect_quick_hint
  # The question goes HERE, on the prompt line, and not above the cost and the
  # quick-gate hint: those are four lines tall together, and a [Y/n] with the
  # question that far up is a [Y/n] to nothing.
  printf "\n %sBisect now?%s [Y/n] " "$B" "$OFF"

  # A failed read is EOF — a closed stdin, or Ctrl-D. Treat it as no rather than
  # as the default: nobody typed anything, so nobody agreed to anything.
  if ! IFS= read -r reply; then printf '\n'; return 1; fi
  case "$reply" in
    ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
    *)                    return 1 ;;
  esac
}

# A gate failure that the resolver already predicted costs nothing to report, so
# report it before anything expensive happens. This is the free answer: the one
# time this mattered in anger, the resolver named the broken file and the reason
# in its transcript, said RESOLVED, and the build spent four more merges, an
# install and a full build before failing with no reference to any of it.
#
# It is a lead, not a verdict — a bisect still has to confirm it, and a branch
# nobody suspected can be the culprit. Worded accordingly.
bisect_suspect_hint() {
  local i n=0
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    [ -n "${SUSPECT[$i]}" ] && n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 0

  printf "\n %sThe resolver already flagged %s during assembly:%s\n" \
    "$YEL" "$(plural "$n" branch)" "$OFF"
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    [ -n "${SUSPECT[$i]}" ] || continue
    printf "   %s%s%s\n     %s\n     %s%s%s\n" \
      "$B" "${BRANCHES[$i]}" "$OFF" "${SUSPECT[$i]}" \
      "$DIM" "$(resolver_log "${BRANCHES[$i]}")" "$OFF"
  done
  if [ "$n" = 1 ]; then
    printf " %sStart there. It is a lead and not a verdict — the gate may be failing\n" "$DIM"
    printf " for something else entirely — but it is free and it is often right.%s\n" "$OFF"
  fi
}

# ---------- the search ----------

# bisect_gate <base>
#
# Reads BRANCHES / OIDS / NOTES / MERGES from cmd_build, the way build_summary
# already does. Always leaves the worktree back on the integration branch.
bisect_gate() {
  local base="$1" final started
  final=$(gitw rev-parse HEAD)
  started=$(date '+%s')

  BISECT_GATE_HOOK="desvio_verify"
  BISECT_QUICK=0
  if has_hook desvio_verify_quick; then
    BISECT_GATE_HOOK="desvio_verify_quick"; BISECT_QUICK=1
  fi

  # Candidates are only the branches that produced a merge commit. A branch that
  # was already upstream produced none and a --keep-going casualty was never
  # merged; there is nothing to check out for either, and neither can be the
  # culprit. Accusing one would be the worst kind of wrong — it is not even in
  # the build.
  local -a CAND_B CAND_OID CAND_I
  CAND_B=(); CAND_OID=(); CAND_I=()
  local i
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    [ -n "${MERGES[$i]}" ] || continue
    CAND_B+=("${BRANCHES[$i]}"); CAND_OID+=("${MERGES[$i]}"); CAND_I+=("$i")
  done
  local n="${#CAND_B[@]}"

  # Set BEFORE the first checkout, so a Ctrl-C anywhere from here on still puts
  # the worktree back. See build_cleanup in cmd-build.sh.
  DESVIO_BISECT_RESTORE="$final"

  log "bisecting $(plural "$n" branch) to find out which one"
  printf '       %sabout %s gate runs%s\n' "$DIM" "$((3 + $(bisect_log2 "$n")))" "$OFF"
  if [ "$BISECT_QUICK" = 1 ]; then
    printf '       %sprobing with desvio_verify_quick%s\n' "$DIM" "$OFF"
  fi

  # ---- endpoint 1: does the probe gate see this failure at all?
  #
  # Skipped when the probe gate IS desvio_verify — we watched it fail on this
  # exact tree a moment ago, and it is the most expensive probe there is. The
  # cost of skipping is that a FLAKY gate goes unnoticed here, which is what the
  # re-probe further down is for.
  local hi_confirmed=0
  if [ "$BISECT_QUICK" = 1 ]; then
    bisect_probe "$final" "the full assembly" "$n"
    if [ "$PROBE_STATUS" -eq 0 ]; then
      bisect_restore "$final"
      bisect_verdict_no_quick "$started"
      return 0
    fi
    hi_confirmed=1
  fi

  # ---- endpoint 2: is it upstream rather than us?
  bisect_probe "$base" "the base, none of your branches" 0
  if [ "$PROBE_STATUS" -ne 0 ]; then
    bisect_restore "$final"
    bisect_verdict_base "$base" "$n" "$started"
    return 0
  fi

  # ---- the search.
  #
  # lo is a commit we OBSERVED passing, hi one we OBSERVED failing; index k
  # means "after CAND_B[k-1]", and 0 means the base. The loop only ever narrows
  # to ADJACENT indices, so what comes out is a pass→fail pair we actually
  # measured rather than one the monotonicity assumption implies. That is what
  # makes this survive a gate that is not monotonic: the answer is a true
  # statement about one merge. It is just not a proof that it is the only one,
  # and the verdict says so rather than pretending.
  local lo=0 hi="$n" mid
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    bisect_probe "${CAND_OID[$((mid - 1))]}" "after ${CAND_B[$((mid - 1))]}" "$mid"
    if [ "$PROBE_STATUS" -eq 0 ]; then lo="$mid"; else hi="$mid"; hi_confirmed=1; fi
  done

  # Every probe passed and we never actually watched the top end fail: the gate
  # failed once and will not do it again. Confirm that rather than accuse the
  # branch the search happened to stop on.
  if [ "$hi" = "$n" ] && [ "$hi_confirmed" = 0 ]; then
    bisect_probe "$final" "the full assembly again" "$n"
    if [ "$PROBE_STATUS" -eq 0 ]; then
      bisect_restore "$final"
      bisect_verdict_flaky "$started"
      return 0
    fi
  fi

  # ---- broken alone, or only in company?
  #
  # One more probe answers what the search structurally cannot, and the two
  # answers want opposite fixes: rebase the branch, versus move it in the
  # manifest or teach it about the others. Guessing between those is worse than
  # spending a probe.
  # The first candidate needs no solo probe: merged onto the base with nothing
  # before it, the solo merge IS the probe we already ran.
  local k=$((hi - 1))
  BISECT_SOLO="alone"
  if [ "$hi" -gt 1 ]; then
    bisect_solo "$base" "${OIDS[${CAND_I[$k]}]}" "${CAND_B[$k]}"
  fi

  bisect_restore "$final"
  bisect_verdict_culprit "$base" "$final" "$lo" "$hi" "$k" "$BISECT_SOLO" "$n" "$started"
}

# bisect_probe <oid> <label> <k> — put the tree at <oid>, rebuild it, gate it.
# Sets PROBE_STATUS.
bisect_probe() {
  local oid="$1" label="$2" k="$3" logf
  logf=$(bisect_log "$k" "$oid")
  printf '       %s%-34s%s %s\n' "$B" "$label" "$OFF" "${oid:0:9}"

  # DETACH first, then reset. `reset --hard` with the integration branch checked
  # out MOVES that branch — and it is both the record of the assembly we are
  # here to explain and the thing build_cleanup restores to.
  gitw checkout -q --detach
  gitw reset -q --hard "$oid"
  # The same KEEP a build uses, deliberately: a probe has to resemble the build
  # it is explaining. Keeping node_modules is also the only reason a handful of
  # probes is affordable at all.
  # shellcheck disable=SC2086  # DESVIO_CLEAN_KEEP is a word list on purpose
  gitw clean -fdq ${DESVIO_CLEAN_KEEP:+$DESVIO_CLEAN_KEEP}

  # Quiet: a handful of full typecheck outputs would bury the report they exist
  # to support.
  run_gate bisect_pipeline > "$logf" 2>&1
  PROBE_STATUS="$GATE_STATUS"

  if [ "$PROBE_STATUS" -eq 0 ]; then
    printf '         %spassed%s\n' "$GRN" "$OFF"
  else
    printf '         %sfailed (%s)%s   %s%s%s\n' "$RED" "$PROBE_STATUS" "$OFF" "$DIM" "$logf" "$OFF"
  fi
}

# Install, seed, build and gate as ONE unit, so a probe whose BUILD fails counts
# as a failing probe rather than crashing the bisect. That is also the honest
# reading: a commit that does not build does not pass the gate.
#
# desvio_install runs at every probe, and is free at every probe, because that
# hook's contract is already "skip the work when the stamp has not moved". When
# the probe commit's lockfile genuinely differs, installing is exactly right —
# gating a tree against the wrong dependencies would blame whichever branch the
# search happened to be standing on.
bisect_pipeline() {
  run_hook desvio_install
  run_hook desvio_seed
  run_hook desvio_build
  "$BISECT_GATE_HOOK"
}

# bisect_solo <base> <topic oid> <name> — sets BISECT_SOLO to
# alone | together | conflicted.
#
# A global rather than stdout, and NOT called in a command substitution: this
# runs a probe, and a probe prints its progress. Captured, that progress becomes
# part of the "return value" and every comparison against it silently fails —
# the verdict then falls through every case and says nothing about whether the
# branch is broken alone, which is the one thing the extra probe was spent on.
bisect_solo() {
  local base="$1" topic_oid="$2" name="$3"
  gitw checkout -q --detach
  gitw reset -q --hard "$base"
  # shellcheck disable=SC2086
  gitw clean -fdq ${DESVIO_CLEAN_KEEP:+$DESVIO_CLEAN_KEEP}
  # rerere OFF for this one merge. It is a merge no real build ever produces:
  # recording a resolution from it would put a preimage in the cache that
  # nothing will ever match, and REPLAYING one into it could make a healthy
  # branch look broken alone — the exact wrong answer to the exact question.
  if ! gitw -c rerere.enabled=false merge --no-ff --no-edit \
         -m "desvio solo probe: $name" "$topic_oid" >/dev/null 2>&1; then
    gitw merge --abort >/dev/null 2>&1 || true
    BISECT_SOLO="conflicted"
    return 0
  fi
  bisect_probe "$(gitw rev-parse HEAD)" "$name alone on the base" solo
  if [ "$PROBE_STATUS" -eq 0 ]; then BISECT_SOLO="together"; else BISECT_SOLO="alone"; fi
}

# Put the worktree back on the integration branch, at the assembly that failed.
# Clears the trap variable so build_cleanup does not redo this on the way out.
bisect_restore() {
  gitw checkout -q --detach
  gitw reset -q --hard "$1"
  # shellcheck disable=SC2086
  gitw clean -fdq ${DESVIO_CLEAN_KEEP:+$DESVIO_CLEAN_KEEP}
  gitw checkout -q "$DESVIO_BRANCH"
  # shellcheck disable=SC2034  # read by build_cleanup's trap in cmd-build.sh
  DESVIO_BISECT_RESTORE=""
}

# How many branches actually contributed a commit — what a bisect could search.
bisect_candidate_count() {
  local i n=0
  for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
    [ -n "${MERGES[$i]}" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ceil(log2(n)), the only way that is portable to a shell with no maths library.
bisect_log2() {
  local n="$1" p=1 r=0
  while [ "$p" -lt "$n" ]; do p=$((p * 2)); r=$((r + 1)); done
  printf '%s' "$r"
}

# Wall time of the bisect, in the shape a human reads.
bisect_elapsed() {
  local s=$(( $(date '+%s') - $1 ))
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}

# ---------- verdicts ----------
#
# Each of these is honest about what it does NOT know. A bisect that names a
# branch it cannot justify is worse than one that says it could not tell: the
# wrong answer looks exactly as confident as the right one, and it sends you off
# rebasing a branch that was never the problem.

bisect_verdict_culprit() {
  local base="$1" final="$2" lo="$3" hi="$4" k="$5" solo="$6" n="$7" started="$8"
  local name="${CAND_B[$k]}" note="${NOTES[${CAND_I[$k]}]}" j
  local lo_oid="$base" lo_label="the base, none of your branches"
  if [ "$lo" -gt 0 ]; then
    lo_oid="${CAND_OID[$((lo - 1))]}"; lo_label="after ${CAND_B[$((lo - 1))]}"
  fi

  printf '\n'
  rule
  printf " %s%s broke the gate%s   %s%s%s\n" \
    "$RED" "$name" "$OFF" "$DIM" "$(bisect_elapsed "$started")" "$OFF"
  rule

  printf "\n %spasses at%s\n   %s   %s of %s · %s\n" \
    "$B" "$OFF" "${lo_oid:0:9}" "$lo" "$n" "$lo_label"
  printf "\n %sfails at%s\n   %s   %s of %s · after %s\n" \
    "$B" "$OFF" "${CAND_OID[$k]:0:9}" "$hi" "$n" "$name"
  printf "               %s%s%s\n" "$DIM" "$(bisect_log "$hi" "${CAND_OID[$k]}")" "$OFF"

  printf "\n %sthe manifest line%s\n   %s" "$B" "$OFF" "$name"
  [ -n "$note" ] && printf "       %s# %s%s" "$DIM" "$note" "$OFF"
  printf '\n'

  case "$solo" in
    alone)
      printf "\n It fails on its own too, merged onto the plain base with none of your\n"
      printf " other branches present. So this is the branch against upstream, not an\n"
      printf " interaction between your branches — rebasing it is the fix.\n"
      printf "\n   git -C %s rebase %s %s\n   desvio build\n" \
        "$DESVIO_REPO" "$DESVIO_BASE" "$name" ;;
    together)
      printf "\n It PASSES on its own, merged onto the plain base. So the branch is not\n"
      printf " broken — the combination is, with what was merged before it:\n\n"
      for ((j = 0; j < k; j++)); do
        printf "   %s\n" "${CAND_B[$j]}"
      done
      printf "\n Rebasing %s will not fix this by itself. Either one of these\n" "$name"
      printf " branches needs to learn about the others, or the order is wrong — and\n"
      printf " the manifest's rule is that the front is frozen and the back moves, so\n"
      printf " the line to move is %s, not the ones above it.\n" "$name" ;;
    conflicted)
      printf "\n desvio could not test it alone: merged onto the plain base by itself it\n"
      printf " conflicts, and resolving that is a different merge from the one this\n"
      printf " build made. The pass→fail pair above still holds; what is missing is\n"
      printf " only whether the branch or the combination is at fault.\n" ;;
  esac

  printf "\n %ssee what that merge did%s\n   git -C %s diff %s %s\n" \
    "$B" "$OFF" "$DESVIO_REPO" "${lo_oid:0:9}" "${CAND_OID[$k]:0:9}"
  printf "\n %sor sit it out for one build%s — comment the line, keep the order:\n" "$B" "$OFF"
  printf "   %s#%-28s # breaks the gate%s\n" "$DIM" "$name" "$OFF"

  printf "\n The tree is back at the full assembly %s — the failure you started\n" "${final:0:9}"
  printf " with, untouched. Inspect it there; do not fix it there, the next build\n"
  printf " resets and cleans this tree.\n"

  printf "\n %sBinary search: this is the first break it found, not a proof there is\n" "$DIM"
  printf " only one.%s" "$OFF"
  [ "$BISECT_QUICK" = 1 ] && printf " %sProbed with desvio_verify_quick.%s" "$DIM" "$OFF"
  printf '\n'
  rule
}

bisect_verdict_base() {
  local base="$1" n="$2" started="$3"
  printf '\n'
  rule
  printf " %sno branch of yours broke the gate — the base did%s   %s%s%s\n" \
    "$RED" "$OFF" "$DIM" "$(bisect_elapsed "$started")" "$OFF"
  rule
  printf "\n %sfails at%s\n   %s   %s\n" "$B" "$OFF" "${base:0:9}" "$(gitr log -1 --format='%s' "$base")"
  printf "   %swith not one of your %s merged.%s\n" "$DIM" "$(plural "$n" branch)" "$OFF"
  printf "\n So this is one of: upstream shipped something broken, your gate itself is\n"
  printf " wrong, or the tree carries state from before —\n"
  printf " DESVIO_CLEAN_KEEP keeps \"%s\" across builds AND across\n" "${DESVIO_CLEAN_KEEP:-}"
  printf " every probe, so a stale one of those follows the search all the way down.\n"
  if [ "$BISECT_QUICK" = 1 ]; then
    printf "\n %sProbed with desvio_verify_quick, which is not the gate that failed. If\n" "$YEL"
    printf " that hook is STRICTER than desvio_verify, this verdict is about the\n"
    printf " hook and not about upstream.%s\n" "$OFF"
  fi
  printf "\n %sCheck the gate where none of this applies:%s\n" "$B" "$OFF"
  printf "   cd %s && <your gate>\n" "$DESVIO_REPO"
  printf "\n %sOr build on a commit from before it broke:%s\n" "$B" "$OFF"
  printf "   desvio build %s~10\n" "$DESVIO_BASE"
  printf "\n %sOr, if it is the leftovers, take the loss once:%s\n" "$B" "$OFF"
  printf "   DESVIO_CLEAN_KEEP= desvio build\n"
  rule
}

bisect_verdict_no_quick() {
  printf '\n'
  rule
  printf " %scannot say which branch — nothing to bisect with%s   %s%s%s\n" \
    "$YEL" "$OFF" "$DIM" "$(bisect_elapsed "$1")" "$OFF"
  rule
  printf "\n desvio_verify_quick PASSES on the very assembly that desvio_verify just\n"
  printf " failed. It does not see this failure.\n"
  printf "\n Every probe would therefore pass, and desvio would end up naming whichever\n"
  printf " branch the search happened to stop on. That answer would look exactly as\n"
  printf " confident as a correct one, so there is none.\n"
  printf "\n %sEither widen the quick hook until it catches this%s — the failure is in\n" "$B" "$OFF"
  printf " the output above, so you can see what it would have to run.\n"
  printf "\n %sOr drop the hook and bisect with the real gate:%s\n" "$B" "$OFF"
  printf "   desvio build --bisect-gate      %sslower, and it will be right%s\n" "$DIM" "$OFF"
  rule
}

bisect_verdict_flaky() {
  printf '\n'
  rule
  printf " %scannot say which branch — the gate is not reproducible%s   %s%s%s\n" \
    "$YEL" "$OFF" "$DIM" "$(bisect_elapsed "$1")" "$OFF"
  rule
  printf "\n Every probe passed, including a second run at the full assembly — the same\n"
  printf " commit, the same tree, that failed minutes ago.\n"
  printf "\n A gate that does not fail twice cannot be bisected: the search would name\n"
  printf " whichever branch it stopped on. So look for state that lives outside the\n"
  printf " commit — a cache, a port, a file a hook writes, a lockfile a probe\n"
  printf " reinstalled, a check that reads the clock.\n"
  printf "\n The probe logs are side by side:\n   %s/bisect-*.log\n" "$DESVIO_STATE"
  rule
}
