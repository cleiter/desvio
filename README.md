<img src="static/logo-128.png" alt="" width="96" height="96">

# desvio

Keep a personal build of someone else's project.

You have branches that upstream has not merged — open pull requests, changes that were rejected, things only you want. desvio merges them onto a fresh upstream in a worktree of your own checkout, resolves the conflicts, and runs your gate. What comes out is a build you can install and use every day, rebuilt in a minute when upstream moves.

Your topic branches are never written to.

*Paseo* is Spanish for a walk. A *desvío* is the detour you take on the way.

## Install

```sh
git clone https://github.com/cleiter/desvio.git
mkdir -p ~/.local/bin
ln -s "$PWD/desvio/bin/desvio" ~/.local/bin/desvio
```

No root needed. If `~/.local/bin` is not already on your `PATH`, add it to your shell profile:

```sh
export PATH="$HOME/.local/bin:$PATH"
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
       its own commits are in origin/main, up to 7c41a90e2 keep the plan card…

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

A line does not have to be a branch of your own. It can name a branch on any remote your checkout knows about, or a pull request directly:

```
alice/keyboard-shortcuts    # a colleague's branch, on her fork
origin/pull/3206/head       # PR #3206, no fork to add
```

The remote has to exist already — `git remote add alice <url>` — and desvio does the fetching. Every build fetches `origin` plus every remote the manifest names, so a remote line is as current as a local one without you tracking anything.

**Local wins.** A bare name means what it always meant, and even a slashed one is a local branch first: with both a local `alice/keyboard-shortcuts` and that ref on the remote, the local branch is what gets merged. So nothing you already have in a manifest changes meaning.

**A pull request is written as its ref, verbatim.** `origin/pull/3206/head` on GitHub, `origin/merge-requests/3206/head` on GitLab. desvio knows nothing about either — it takes the path you wrote and fetches it — which is also why it works on Gerrit and anything else. That fetch is also what rescues a remote whose refspec is restricted, as a single-branch clone or `git remote add -t main` leaves it.

**When a fork is unreachable, the build carries on.** Someone deletes their fork the day their PR lands; you are on a plane. desvio warns, uses the refs from the last successful fetch, and marks that branch `STALE` in the summary — because a stranger's housekeeping should not stop you building. `origin` is the exception: it is the floor every build stands on, so losing it is still fatal.

**Order matters, and the rule is: the front is frozen, the back moves.** Merges resolve against everything already merged, so a branch's conflicts are decided by what sits above it. Move a line and every line below it can conflict differently, which throws away their recorded resolutions.

- **Front** — branches that will never land upstream. They are permanent, so pay their conflict cost once, at the bottom of the stack where nothing disturbs them.
- **Middle** — open pull requests, oldest first. When one lands, delete its line; only the lines below it re-resolve.
- **Back** — whatever you started yesterday. Churn belongs where it disturbs least, and a new branch has no recorded resolutions to lose.

Size is not the criterion. A large old branch is cheaper at the front than a small new one, because it has already paid for its conflicts.

### When a branch contributes nothing

Merging it produced no commit, and desvio marks the line `○`. There are three reasons for that, they want opposite responses, and desvio names the commit it is reasoning from so you can disagree with it:

| what you see | what happened | what to do |
|---|---|---|
| `already upstream` | the branch's own commits are in the base already | delete the line |
| `nothing was ever committed to this branch` | the branch was created and never moved | **keep the line** — look for uncommitted work in its worktree |
| `a branch above it already has it` | an earlier manifest line contains this one | delete one of the two |

The second is the one worth knowing about. A branch created from the base and never committed to merges into nothing exactly like a landed one, and the subject printed under it is the *base's* commit, not yours — so the line looks like a feature that shipped when in fact nothing was ever recorded. Tools that create a branch per workspace up front make this common. desvio tells the two apart by the branch's reflog: a branch that has only ever pointed at one commit never received one. Reflogs expire and a fresh clone has none, so treat it as the strong hint it is, and read the commit desvio names.

## Conflicts

The first time a conflict appears, something has to resolve it. After that, git's [rerere](https://git-scm.com/docs/git-rerere) replays the same resolution on every rebuild, and most rebuilds spend no thought at all.

For that first time, desvio runs Claude Code on the conflicted files. A conflict during assembly is never a question about your branch — the topic is already authored, and the merge only has to reconcile it with whatever upstream did since. That is mechanical enough to delegate, and delegating it is the difference between a fork you keep and a fork you abandon.

**Your branches cannot be touched by it.** Two independent reasons:

1. The agent runs with no shell tool, so it cannot run git at all, and its writes are confined to the worktree. Your refs live in the checkout's `.git`, outside that directory. This is structural, not a promise.
2. Every **local** branch's OID is snapshotted before the agent starts and verified after. Anything that moved stops the build and prints the `update-ref` that puts it back.

Remote-tracking refs are deliberately outside that snapshot, and lose nothing by it: they are not something you can commit to, the agent has no network, and a `git fetch` restores any of them. A manifest line that names one is pinned to a single OID at the start of the build regardless, so nothing it merges can shift underneath it.

desvio does not run that `update-ref` itself, on purpose. It cannot tell a misbehaving resolver from a commit you made in another worktree while the agent was thinking, and rewinding the second one would destroy real work. It stops, shows you the before and after OIDs, and lets you decide.

Turn it off with `desvio build --no-resolve` and resolve by hand; rerere records your resolution the same way. Replace it by defining `desvio_resolve_conflict` in the config.

## What it writes to your checkout

desvio does not clone. The build tree is a `git worktree` of `DESVIO_REPO`, so the tree's `.git` is a pointer file back into your checkout and everything below happens in your repo:

- **The integration branch.** `refs/heads/$DESVIO_BRANCH` is created in your checkout — not in the build directory — and reset to the base commit on every build.
- **A worktree registration** under `.git/worktrees/`.
- **Objects.** Every commit, tree, and blob the assembly authors is written to your object database. The merges are real commits in your repo, reachable from the integration branch.
- **`rerere.enabled` and `rerere.autoupdate`,** set to `true` in your `.git/config` on every build. Recorded resolutions accumulate in `.git/rr-cache`, which is shared by all worktrees of the checkout.
- **Remote-tracking refs,** moved by the `git fetch --prune` at the start of each build — for `origin` and for every other remote the manifest names.

Never your topic branches: nothing commits to them, and nothing is pushed anywhere. That is what the snapshot in [Conflicts](#conflicts) guarantees.

Two consequences worth knowing. Give each build directory its own `DESVIO_BRANCH` if you run more than one against a single checkout, or they will reset each other's integration branch out from under them. And to undo one completely, `git worktree remove <tree>` then `git branch -D <branch>` in the checkout — deleting the build directory alone leaves both behind.

## The gate is the point

Assembly tells you nothing about whether the result works. Two branches that never touch the same line merge cleanly and can still be incoherent: upstream moves a shared helper, your branch calls the old one, and git has no opinion because the edits are 200 lines apart.

A real one, from the build this tool came out of. Upstream started validating persisted settings against a strict schema. A branch added a new setting. Neither edit touched the other's lines, so the merge was clean — and the app then discarded every user preference on load, silently, with the symptom appearing as "the theme dropdown does nothing". Nothing in the merge could have caught it. A typecheck caught it one line later, in a different file.

So `desvio_verify` is not optional decoration. Make it the strictest check you are willing to wait for. desvio warns on every build that has no gate.

## Which branch broke the gate?

A gate failure names a file. It does not name a branch, and the branch is what you need — with sixteen manifest lines, four merges stacked above the culprit, and an error in a file none of them appear to touch, "which of mine did this" can cost more than the fix.

Two things answer it, cheapest first.

**The resolver's own doubt.** A conflict is often only *half* of one change: git conflicts on the part where both sides edited the same lines and merges the rest cleanly. Upstream deletes an import, your branch moves the code that used it — the deletion merges silently, the usage conflicts, and an agent that only looks at conflict regions fixes what it can see and leaves a file referencing symbols that no longer exist. Every guard passes, because there is no marker anywhere to catch.

So the resolver is asked to read each conflicted file end to end afterwards, and given a third verdict for when it cannot repair what it finds:

```
   ! markdown-skill-commands       # PR #2084
       Insert slash commands from agent output into the composer
       1 file · auto-resolved, and the resolver was NOT sure
       link.tsx references Shortcut and styles.tooltipBody with no import
       state/resolve-markdown-skill-commands.log
```

That mark is a lead, not a verdict — the gate still decides. `DESVIO_SUSPECT=fail` stops at the merge instead, for when you would rather not wait for the gate to confirm it.

**A bisect.** The integration branch is a straight chain of merge commits, one per manifest branch, in order. So the question is answerable by re-running the gate over that chain:

```sh
desvio build --bisect-gate
```

It binary-searches for the first merge where the gate breaks, then spends one more probe merging that branch onto the plain base alone — because "broken against upstream" and "broken against the branches above it" want opposite fixes, and it should not guess between them. It ends by naming the branch, its manifest line, and the command to rebase it.

Off by default: an unasked-for multi-minute bisect appended to an already-failed build is not a kindness. `DESVIO_BISECT_GATE=1` opts in for unattended runs. Define `desvio_verify_quick` — the fast half of your gate — and the probes use that instead:

```sh
desvio_verify()       { in_tree npm run typecheck; in_tree npm run lint; }
desvio_verify_quick() { in_tree npm run typecheck; }
```

If the quick hook does not reproduce the failure, desvio says so and refuses to bisect rather than name whichever branch the search happened to stop on. It refuses in three other cases too, for the same reason: when the base itself fails the gate (upstream, not you), when nothing fails on a second run (a gate that will not fail twice cannot be bisected), and it reports a break that needs two branches as a combination rather than accusing one of them.

The tree is left exactly as it failed, including after Ctrl-C. Look at it there — but do not fix it there, because the next build resets and cleans it. Fixes belong on the topic branch.

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
| `DESVIO_SUSPECT` | `warn` | `fail` to stop the build when the resolver flags its own resolution |
| `DESVIO_BISECT_GATE` | `0` | `1` to bisect automatically when the gate fails |

Hooks, all optional, called in this order:

| Hook | |
|---|---|
| `desvio_preflight` | refuse to build when it would not be safe — a server still running against the tree, a watcher holding files |
| `desvio_install` | dependencies |
| `desvio_seed` | anything generated that the gate needs and git ignores |
| `desvio_build` | compile |
| `desvio_verify` | **the gate** |
| `desvio_verify_quick` | the fast half of the gate, used only by `--bisect-gate`. If it does not reproduce a failure, desvio refuses to bisect rather than guess |
| `desvio_next_steps` | printed under the summary |
| `desvio_resolve_conflict` | replace the built-in resolver. Takes `<topic> <subject>`, returns 0 when every marker is gone. May set `RESOLVER_SUSPECT` to one line when it cleared every marker but believes the result is still broken |

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
desvio build origin/main~10    # ten back
desvio build d012b6f07         # a specific commit
```

Use it to sit out a broken upstream, or to reproduce yesterday's build. The merges replay the same way; only the floor moves. The summary says how far behind you pinned.

## Tasks

A build is not the end of it: something has to start what came out, package it, install it. Those scripts belong to your project, not to desvio — but they all need the same facts about where the build is, and rediscovering them from `$0` is how a script ends up only working from one directory.

Put an executable `<name>.sh` next to your `desvio.conf` and run it with:

```sh
desvio run start                 # ./start.sh
desvio run package --no-install  # after a single name, arguments pass straight through
desvio run package install       # in that order, and the first failure stops there
desvio run                       # lists what is there
```

It loads the config the same way `build` does — honouring `--config` and `$DESVIO_CONFIG` — sets the cwd to the config directory, and exports `DESVIO_WORKTREE`, `DESVIO_REPO`, `DESVIO_STATE`, `DESVIO_MANIFEST`, `DESVIO_BRANCH`, `DESVIO_NAME`, `DESVIO_BASE`, `DESVIO_REMOTE`, `DESVIO_CONFIG_FILE` and `DESVIO_VERSION`, every path absolute. So the whole of a task's preamble is:

```sh
: "${DESVIO_WORKTREE:?run this with: desvio run start}"
```

A single task is `exec`ed, so its exit status and its signals are its own. A chain runs each in turn and stops at the first failure — packaging a tree whose gate never passed is worse than stopping. Every name is resolved before anything runs, so a typo in the last task costs you nothing. Arguments only make sense for one task, so naming several and passing arguments too is an error rather than a guess; `--` ends the name list if a task's own first argument is a bare word.

`build` is not a task, so the whole path is two commands joined by the shell:

```sh
desvio build && desvio run package install
```

That is deliberate. `build` has its own flags and its own gate, and a `run` that special-cased the name `build` would shadow anyone's real `build.sh`.

## Tests

```sh
tests/run.sh                 # everything
tests/run.sh refsafety base  # only the files whose names match
```

Plain bash and git, no test framework to install. Every test builds a throwaway world — a bare origin, a clone of it standing in for your checkout, an isolated `HOME` and `GIT_CONFIG_GLOBAL` — so nothing it does can reach a repository you care about. Conflicts are resolved by an injected `desvio_resolve_conflict`, never by the real agent.

The two suites that justify the rest are `test-refsafety.sh` and `test-markers.sh`: they hold the README's two structural promises, that your branches are never written to and that a conflict marker is never committed. Both are mutation-checked — breaking `assert_refs_unchanged` or `assert_no_markers` in `lib/` makes them fail.

CI runs the suite on Linux and macOS, and on macOS a second time with `/bin/bash` first on `PATH`, which is the only way the bash 3.2 support claimed above is actually exercised.

## Known sharp edges

- **A stale rerere resolution can be wrong.** rerere matches on conflict text, so a resolution recorded from one merge can replay into a different one. desvio refuses to commit a file that still holds conflict markers, but a resolution that dropped a side leaves no markers to find. The gate is what catches it — and once a bad resolution is recorded, every later build replays it silently and reports a green *conflict replayed from rerere*. To be rid of one: `desvio build --forget <branch>`, which merges that branch with rerere off so the conflict comes back, forgets the recorded answer, and records the replacement. One build fixes it permanently. A **rebased** branch needs none of this: rerere keys on the text of the conflict, so a rebase produces a different conflict and the stale entry simply stops matching.
- **A clean merge is not a correct merge.** See above.
- **Bisecting shares one `node_modules`.** Probes clean with the same `DESVIO_CLEAN_KEEP` as a build, so an install hook without a `stamp_changed` guard reinstalls at every probe. And a failure caused by something `KEEP` preserves follows the search all the way down to the base, where desvio reports it as upstream's — which is why that verdict raises the possibility itself.
- **A bisect finds *a* break, not every break.** Binary search returns a pass→fail pair it actually observed, so the branch it names is genuinely broken there. If two branches are independently broken you will find the second one on the next run.
- **One worktree.** Anything that reads the tree while desvio rewrites it will misbehave; that is what `desvio_preflight` is for.
- **A base on another remote is not fetched for you.** `desvio build fork/main` resolves against whatever `fork/main` was at your last fetch of it, unless the manifest also names a `fork/` line. The fetch set comes from the manifest, not from the base.
- **The agent needs `claude` on your PATH** and uses your account.

## Example

[`examples/paseo`](examples/paseo) is a complete working configuration for [Paseo](https://github.com/getpaseo/paseo) — preflight against a running daemon, npm install gated on the lockfile, a generated-types seed, typecheck and lint as the gate — plus the scripts that run and package what comes out.

## Licence

Apache 2.0.
