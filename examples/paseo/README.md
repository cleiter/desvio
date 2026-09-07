# desvio for Paseo

A working configuration for [Paseo](https://github.com/getpaseo/paseo), plus the scripts that run and package what comes out.

```sh
cp -R examples/paseo ~/.paseo-fork
cd ~/.paseo-fork
$EDITOR desvio.conf     # DESVIO_REPO must point at your Paseo checkout
$EDITOR manifest.txt    # your branches
desvio build
```

Keep this directory outside the checkout. It holds the build tree, the state directory and your manifest, and none of that belongs in a repo you also send pull requests from.

Two config files, and the split is deliberate. **`desvio.conf`** is desvio's, and holds `DESVIO_*` and the build hooks — desvio is a generic tool and knows nothing about Paseo. **`paseo.conf`** is Paseo's: the bundle name, where it installs, which daemon home to run against. The scripts here source it; desvio never reads it and does not know it exists. Anything you add that only means something to Paseo belongs in the second file.

## What the config does

| Hook | |
|---|---|
| `desvio_preflight` | refuses to build while a daemon serves the build tree — rebuilding rewrites `dist/` under a process that lazily requires from it |
| `desvio_install` | `npm ci`, skipped when `package-lock.json` has not moved |
| `desvio_seed` | copies `packages/app/.expo/types/router.d.ts` from your checkout. Expo generates it, git ignores it, and without it the app's typecheck fails for reasons unrelated to your branches |
| `desvio_verify` | `npm run typecheck` and `npm run lint` |

## The scripts

Run them with `desvio run <name>`, which loads `desvio.conf` and exports it — so each script reads `$DESVIO_WORKTREE` and needs no idea where it was invoked from. `desvio run` on its own lists them. Several names run in order and stop at the first failure, so the whole path from branches to an installed app is:

```sh
desvio build && desvio run package install
```

**`start.sh`** (`desvio run start`) swaps the daemon on your real `~/.paseo` for the one in the build tree, then launches the desktop app against it. Stopping a daemon kills every agent process — conversations resume on the next prompt, but a turn in flight right now is lost, so it lists what it is about to kill and asks. `--no-desktop` starts only the daemon, `--yes` skips the prompt.

**`stop.sh`** (`desvio run stop`) tears all of it down again. Quitting the app from the Dock is not enough — `keepRunningAfterQuit`, pinned by `install.sh`, leaves the daemon serving with no window open, and every agent turn hangs off the daemon, not the window you closed. This finds the app, the daemon (on the real home and the throwaway ones `desktop.sh` and `start.sh` use), and the agent processes underneath it, and stops all three in the right order — app, then daemon, then whatever it left behind. `--dry-run` lists what it would kill without touching anything; `--keep-app` and `--keep-daemon` narrow the sweep.

**`desktop.sh`** (`desvio run desktop`) launches only the desktop app, against the daemon already on `127.0.0.1:6767`. `npm run dev:desktop` cannot do this: it uses the checkout's `.dev/user-data`, where `manageBuiltInDaemon` defaults to true, so the app starts its own empty daemon and connects to that instead. The symptom is a sidebar of skeletons that never resolve and nothing in the log to explain it. So this script uses a throwaway home, pins the desktop settings, asserts that Electron agrees about the userData path, and seeds the host entry over CDP.

**`package.sh`** (`desvio run package`) builds `Paseo.app` with its own bundled daemon. After you install it the app stops reading the build tree, so you can rebuild whenever you like. Three things in it are worth knowing before you copy it elsewhere:

- The version becomes `<upstream>-<name>.<yymmdd-HHMM>`, a semver prerelease of upstream's version. `260814-0750` is one alphanumeric identifier because semver forbids leading zeroes in a numeric one, so `.0750` would be invalid.
- That version ranks *below* upstream's stable release of the same number, so a working updater would replace your build with stock Paseo. What prevents it is that `-c.mac.target=dir` publishes nothing and therefore writes no `app-update.yml`. The script asserts the file is absent rather than assuming it.
- `packages/app/app.config.js` derives Android and iOS version numbers from `package.json` on every Expo config load, including a web-only export, and accepts only `X.Y.Z` and `X.Y.Z-beta.N`. The script widens that pattern in the tree and restores it afterwards. If upstream edits the pattern, the exact-string match fails and the script stops instead of silently skipping.

By default it installs as `Paseo Plus.app`, beside a stock Paseo rather than over it — with its own `appId`, so LaunchServices is not left choosing between two bundles claiming `sh.paseo.desktop`. Set `PASEO_PRODUCT_NAME="Paseo"` in [`paseo.conf`](paseo.conf) to replace stock instead. The rename is cosmetic on purpose. `main.ts` hardcodes `app.setName("Paseo")` and derives userData from that, not from the product name, so both bundles read the same hosts, settings and conversations. The same directory holds Electron's single-instance lock, which is why this gives you two icons to choose between rather than two apps to run at once: launch the second while the first is up and it just brings the first forward. It is also why `install.sh` warns if it finds a stock `Paseo.app` already there — the daemon settings below are pinned into that same shared file, so both bundles end up managing their own background daemon, not just this one.

A renamed bundle also gets a badged icon — a small plus drawn into the top-right corner, so the two apps are told apart by more than their name. `auto` (the default) badges whenever `PASEO_PRODUCT_NAME` is not `Paseo`; set `PASEO_LOGO_PLUS=0` to keep the stock icon regardless, or `1` to force the badge either way. Needs ImageMagick (`brew install imagemagick`) — under `auto` its absence is a warning, and the build proceeds with the stock icon; asked for explicitly with `=1` and nothing to badge with, it stops instead. The work happens in `logo-plus`, a helper next to these scripts rather than a task of its own — it has exactly one caller and no reason to be typed by hand. Preview the mark without a build: `./logo-plus --preview /tmp/plus.png`. Icons under 48px keep the plain mark; below that the plus is a grey smudge, not a different icon.

The bundle is re-signed ad-hoc in full. electron-builder signs only the outer binary, and dyld refuses to map the bundled Electron Framework — a different team ID — into an ad-hoc process, so the app dies at launch before any of its own code runs.

**`install.sh`** (`desvio run install`) puts that bundle in `/Applications` and pins `desktop-settings.json` so the app manages its own daemon. Deliberately not part of packaging: the two halves fail for unrelated reasons — Expo and electron-builder on one side, a running app or a busy port on the other — and retrying a two-second copy should not cost a five-minute rebuild. It also writes into the real userData directory, which is worth asking for rather than receiving as a side effect. Re-runnable on its own because the bundle survives rebuilds: `release/` is gitignored and desvio's `git clean` does not pass `-x`. It reads the version out of the bundle's `Info.plist`, so what it reports is what it is installing even days later. It also refuses to replace a bundle whose own daemon is still running — quitting the window is not enough, since `keepRunningAfterQuit` keeps the daemon up with no window open — and names `desvio run stop` as the way out.
