# shellcheck shell=bash
# desvio init — write a desvio.conf and a manifest.txt into the current directory.

cmd_init() {
  local repo="${1:-}"
  [ -e "./desvio.conf" ] && die "./desvio.conf already exists — not overwriting it"
  [ -n "$repo" ] || repo="$PWD"
  repo=$(cd "$repo" 2>/dev/null && pwd) || die "no such directory: ${1:-}"
  [ -d "$repo/.git" ] || warn "$repo is not a git checkout — fix DESVIO_REPO before building"

  cat > ./desvio.conf <<EOF
# desvio configuration. Sourced as bash, so a value can be computed and a hook
# is an ordinary function. Paths are relative to this file.

DESVIO_REPO="$repo"          # the upstream checkout your branches live in
DESVIO_BRANCH="desvio"       # the disposable integration branch — never commit to it
DESVIO_NAME="my build"       # what the summary calls it
# DESVIO_BASE="origin/main"  # default: whatever the remote says its HEAD is
# DESVIO_WORKTREE="build-tree"
# DESVIO_MANIFEST="manifest.txt"
# DESVIO_RESOLVER_EFFORT="high"

# Refuse to build when it would not be safe. Anything that reads the tree while
# desvio rewrites it belongs here — a running server, a watcher, a dev process.
# desvio_preflight() {
#   pgrep -f "$repo" >/dev/null && die "something is still running against the tree"
# }

# Dependencies. stamp_changed/stamp_write skip the work when nothing moved, and
# only record after it SUCCEEDS — a failed install must not look current.
desvio_install() {
  if stamp_changed deps package-lock.json; then
    log "npm ci"
    in_tree npm ci
    stamp_write deps package-lock.json
  else
    log "dependencies current — skipping install"
  fi
}

# Whatever has to exist before the gate can run.
# desvio_build() { in_tree npm run build; }

# The gate. This is the part that catches a merge which was textually clean and
# semantically wrong, so make it the strictest check you are willing to wait for.
desvio_verify() {
  in_tree npm run typecheck
  in_tree npm run lint
}

# The fast half of the gate. Only a bisect runs this — the search for WHICH
# branch broke the gate, which desvio offers when the gate fails — so that
# finding out does not cost the whole gate a handful of times. It has to be able to see the same failures the real gate does; if it
# cannot, desvio says so and refuses to bisect rather than accuse a branch.
# desvio_verify_quick() { in_tree npm run typecheck; }

# Printed under the summary. A good place to name the tasks you keep next to this
# file: an executable start.sh here is \`desvio run start\`, with the config
# already loaded and exported. See: desvio help run
# desvio_next_steps() {
#   cat <<TXT
# Run it:
#   cd \$DESVIO_WORKTREE && npm start
# TXT
# }
EOF

  if [ ! -e "./manifest.txt" ]; then
    cat > ./manifest.txt <<'EOF'
# One branch per line, merged in this order. `#` starts a comment; a comment at
# the end of a line says why the line is there, and desvio prints it back to you
# in the build summary.
#
# A line can also name a branch on another remote, or a pull request:
#
#   my-branch                 a local branch
#   alice/keyboard-shortcuts  a branch on the remote `alice`
#   origin/pull/3206/head     PR #3206, with no fork to add as a remote
#
# The remote has to exist already (git remote add alice <url>); desvio fetches
# every remote this file names, on every build. Local wins: if you have a local
# branch called `alice/keyboard-shortcuts`, that is what gets merged. A pull
# request is written as its ref, verbatim — `pull/<N>/head` on GitHub,
# `merge-requests/<N>/head` on GitLab; desvio does not need to know which.
#
# ORDER MATTERS, and the rule is: the front is frozen, the back moves.
#
# Merges are resolved against everything already merged, so a branch's conflicts
# are decided by what sits ABOVE it. Move a line and every line after it can
# conflict differently, which throws away the recorded resolutions for all of
# them. So append; do not insert.
#
#   front   branches that will never land upstream — rejected, or private to you.
#           They are permanent, so pay their conflict cost once, at the bottom of
#           the stack where nothing else disturbs them.
#   middle  open pull requests, oldest first. As one lands, delete its line; the
#           lines below shift down by one and only they re-resolve.
#   back    whatever you started yesterday. Churn belongs where it disturbs the
#           least, and a new branch has no recorded resolutions to lose anyway.
#
# Size is not the criterion. A large old branch is cheaper at the front than a
# small new one, because it has already paid for its conflicts.
#
# Comment a line out rather than deleting it while you work out whether a branch
# is worth keeping — the order is preserved and re-enabling is one character.
EOF
  fi

  log "wrote ./desvio.conf and ./manifest.txt"
  cat <<EOF

Next:
  1. Put your branch names in manifest.txt (they must exist in $repo).
  2. Check the desvio_install / desvio_verify hooks in desvio.conf actually
     match this project. The template assumes npm.
  3. desvio build
EOF
}
