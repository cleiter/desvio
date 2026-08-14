<img src="static/logo-128.png" alt="" width="96" height="96">

# desvio

Keep a personal build of someone else's project.

You have branches that upstream has not merged — open pull requests, changes that were rejected, things only you want. desvio merges them onto a fresh upstream in a worktree of your own checkout, resolves the conflicts, and runs your gate. What comes out is a build you can install and use every day, rebuilt in a minute when upstream moves.

Your topic branches are never written to.

*Paseo* is Spanish for a walk. A *desvío* is the detour you take on the way.

## Install

```sh
git clone https://github.com/cleiter/desvio.git
ln -s "$PWD/desvio/bin/desvio" /usr/local/bin/desvio
```

bash 3.2 or newer, git, and — for automatic conflict resolution — [Claude Code](https://claude.com/claude-code) on your `PATH`. macOS and Linux.

## Quick start

```sh
mkdir ~/.myproject-build && cd ~/.myproject-build
desvio init ~/src/myproject     # writes desvio.conf and manifest.txt
$EDITOR manifest.txt            # one branch name per line
$EDITOR desvio.conf             # what to install, build and verify
desvio build
```

Every run does the same thing: fetch upstream, recreate the integration branch from the base commit, merge each manifest branch in order, install, build, verify, and print what you got.

```
────────────────────────────────────────────────────────────────────
 paseo-mine is ready   2026-08-14 07:50
────────────────────────────────────────────────────────────────────

 starting from
   origin/main    d012b6f07  Help agents diagnose provider problems
                  committed 4 hours ago

 your version adds   47 files changed, 2913 insertions(+), 220 deletions(-)
   ● workspace-labels            # PR #3206
       feat(app): label workspaces and filter the sidebar by label
       31 files · conflict replayed from rerere
   ● group-by-keyboard-toggle    # PR #2504
       feat(app): cycle sidebar grouping with a shortcut
       4 files
   ○ plan-visible-after-answer   # PR #3034
       feat(app): keep the plan card readable after answering
       already upstream — drop this manifest line

 head  a56070fc1   /Users/me/.myproject-build/build-tree
 gate passed: desvio_verify
────────────────────────────────────────────────────────────────────
```

## Why merge, not cherry-pick

A merge resolves once against a whole topic. Cherry-pick replays a branch commit by commit, so a branch that builds on itself conflicts with itself and you answer the same question once per commit. This is the workflow git.git uses to build its `seen` branch, for the same reason.

The integration branch is disposable. desvio recreates it from the base on every run, so nothing accumulates and nothing needs cleaning up. Never commit to it.

## The manifest

One branch per line, merged top to bottom. Anything after `#` is a comment, and a comment at the end of a line is printed back to you in the summary — make it the reason the line still exists.

```
my-private-tweak            # never upstreaming this
fix-something               # PR #1234
new-thing-i-started-today   # no PR yet
```

**Order matters, and the rule is: the front is frozen, the back moves.** Merges resolve against everything already merged, so a branch's conflicts are decided by what sits above it. Move a line and every line below it can conflict differently, which throws away their recorded resolutions.

- **Front** — branches that will never land upstream. They are permanent, so pay their conflict cost once, at the bottom of the stack where nothing disturbs them.
- **Middle** — open pull requests, oldest first. When one lands, delete its line; only the lines below it re-resolve.
- **Back** — whatever you started yesterday. Churn belongs where it disturbs least, and a new branch has no recorded resolutions to lose.

Size is not the criterion. A large old branch is cheaper at the front than a small new one, because it has already paid for its conflicts.

When a branch contributes nothing, desvio marks the line — that is upstream having merged it. Delete the line.

## Conflicts

The first time a conflict appears, something has to resolve it. After that, git's [rerere](https://git-scm.com/docs/git-rerere) replays the same resolution on every rebuild, and most rebuilds spend no thought at all.

For that first time, desvio runs Claude Code on the conflicted files. A conflict during assembly is never a question about your branch — the topic is already authored, and the merge only has to reconcile it with whatever upstream did since. That is mechanical enough to delegate, and delegating it is the difference between a fork you keep and a fork you abandon.

**Your branches cannot be touched by it.** Two independent reasons:

1. The agent runs with no shell tool, so it cannot run git at all, and its writes are confined to the worktree. Your refs live in the checkout's `.git`, outside that directory. This is structural, not a promise.
2. Every branch OID is snapshotted before the agent starts and verified after. Anything that moved is restored with `update-ref` and the build stops.

Turn it off with `desvio build --no-resolve` and resolve by hand; rerere records your resolution the same way. Replace it by defining `desvio_resolve_conflict` in the config.

## The gate is the point

Assembly tells you nothing about whether the result works. Two branches that never touch the same line merge cleanly and can still be incoherent: upstream moves a shared helper, your branch calls the old one, and git has no opinion because the edits are 200 lines apart.

A real one, from the build this tool came out of. Upstream started validating persisted settings against a strict schema. A branch added a new setting. Neither edit touched the other's lines, so the merge was clean — and the app then discarded every user preference on load, silently, with the symptom appearing as "the theme dropdown does nothing". Nothing in the merge could have caught it. A typecheck caught it one line later, in a different file.

So `desvio_verify` is not optional decoration. Make it the strictest check you are willing to wait for. desvio warns on every build that has no gate.

## Configuration

`desvio.conf` is sourced as bash: a value can be computed, and a hook is an ordinary function. It runs with your privileges, exactly like a Makefile in a repo you cloned. Paths are relative to the config file. Lookup order is `--config <file>`, `$DESVIO_CONFIG`, `./desvio.conf`, `$DESVIO_HOME/desvio.conf`.

| Variable | Default | |
|---|---|---|
| `DESVIO_REPO` | — | your checkout of the upstream project. Required. |
| `DESVIO_BRANCH` | `desvio` | the disposable integration branch |
| `DESVIO_NAME` | `$DESVIO_BRANCH` | what the summary calls your build |
| `DESVIO_BASE` | the remote's own `HEAD` | what to build on |
| `DESVIO_REMOTE` | `origin` | |
| `DESVIO_WORKTREE` | `build-tree` | where the build tree lives |
| `DESVIO_MANIFEST` | `manifest.txt` | |
| `DESVIO_STATE` | `state` | logs and stamps |
| `DESVIO_CLEAN_KEEP` | — | extra `git clean` args, e.g. `-e node_modules` |
| `DESVIO_AUTO_RESOLVE` | `1` | |
| `DESVIO_RESOLVER_MODEL` | `opus` | |
| `DESVIO_RESOLVER_EFFORT` | `high` | one conflict costs one agent call and rerere then replays it forever, so buy the thinking |

Hooks, all optional, called in this order:

| Hook | |
|---|---|
| `desvio_preflight` | refuse to build when it would not be safe — a server still running against the tree, a watcher holding files |
| `desvio_install` | dependencies |
| `desvio_seed` | anything generated that the gate needs and git ignores |
| `desvio_build` | compile |
| `desvio_verify` | **the gate** |
| `desvio_next_steps` | printed under the summary |
| `desvio_resolve_conflict` | replace the built-in resolver. Takes `<topic> <subject>`, returns 0 when every marker is gone |

Inside a hook you have `log`, `warn`, `die`, `in_tree <cmd...>`, `gitw`/`gitr`, and `stamp_changed`/`stamp_write` for skipping work when nothing moved:

```sh
desvio_install() {
  if stamp_changed deps package-lock.json; then
    in_tree npm ci && stamp_write deps package-lock.json
  fi
}
```

Two calls rather than one, deliberately: record the stamp only after the work succeeds, or a failed install leaves a stamp claiming it is current.

## Pinning the base

```sh
desvio build v1.4.0            # a release tag
desvio build origin/master~10  # ten back
desvio build d012b6f07         # a specific commit
```

Use it to sit out a broken upstream, or to reproduce yesterday's build. The merges replay the same way; only the floor moves. The summary says how far behind you pinned.

## Known sharp edges

- **A stale rerere resolution can be wrong.** rerere matches on conflict text, so a resolution recorded from one merge can replay into a different one. desvio refuses to commit a file that still holds conflict markers, but a resolution that dropped a side leaves no markers to find. The gate is what catches it. To drop one: `git rerere forget <path>` during the merge.
- **A clean merge is not a correct merge.** See above.
- **One worktree.** Anything that reads the tree while desvio rewrites it will misbehave; that is what `desvio_preflight` is for.
- **The agent needs `claude` on your PATH** and uses your account.

## Example

[`examples/paseo`](examples/paseo) is a complete working configuration for [Paseo](https://github.com/getpaseo/paseo) — preflight against a running daemon, npm install gated on the lockfile, a generated-types seed, typecheck and lint as the gate — plus the scripts that run and package what comes out.

## Licence

Apache 2.0.
