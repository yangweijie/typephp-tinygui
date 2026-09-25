# Upstream patches

Everything here turns a **pristine** `tinyjsapp` checkout into a TypePHP-capable
one. Nothing in this project hand-edits the checkout: the two files we need to
change are stored as patches against a saved pristine base, so the checkout can
be restored or rebuilt at any time and the change is reviewable in a diff.

## Contents

| File | What it is |
|---|---|
| `base/cli.js.orig` | pristine `cli.js` from tinyjsapp **v0.42.0** (75,888 B, sha256 `07c786129b86…`) |
| `base/launcher-win.cc.orig` | pristine `native/launcher-win.cc` from v0.42.0 (306,252 B, sha256 `d2fb5fed…`) |
| `cli-typephp.patch` | adds `--typephp` to `dev` / `build` / `publish` |
| `launcher-win-typephp.patch` | makes the launcher spawn a backend instead of being spawned by one |

Apply them all with:

```bash
bash tools/bootstrap-tinyjsapp.sh          # add --install to also build + deploy
```

## Why patches and not a fork

`cli.js` and `launcher-win.cc` are upstream's files. We change ~324 lines of one
and 4 hunks of the other. Keeping them as patches against a saved base means:

* **restorable** — `base/` + patch reproduces the working tree bit-for-bit.
  Verified: both patches, applied to their bases, produce sha256 values identical
  to the files that have been through the full 50-check POSIX suite and the
  Windows end-to-end run.
* **reviewable** — `git diff` of a 400-line patch is readable; a 92 KB JS file
  dropped in wholesale is not.
* **upgradable** — when tinyjsapp releases 0.43, re-create the bases from the new
  tag and try to apply. The hunks are few and localised, so they should rebase.

## What each patch does

### `launcher-win-typephp.patch` — 4 hunks

Inverts the process relationship. Upstream, a JS backend creates the endpoint
server and spawns the launcher. Here the launcher is the entry point, so it
spawns the backend and connects to it as a client. Everything is gated behind
`TYPEPHP_BACKEND` / `--typephp`, so the stock JS path is untouched.

* hunk 1 — declares `g_typephp`, the child `PROCESS_INFORMATION`, and the
  `spawn_typephp_backend()` / `terminate_typephp_backend()` prototypes.
* hunks 2–4 — the spawn/terminate implementations, the pipe-name contract, and
  the `--typephp` argument parsing.

Pipe-name contract: `\\.\pipe\tinyjs-typephp-<launcher PID>`. The backend binary
comes from `TYPEPHP_BACKEND`, defaulting to `<launcher dir>/backend.exe` — which
is how the shim gets found.

### `cli-typephp.patch` — 8 hunks, 324 added / 3 rewritten

Adds a third backend type to the CLI:

* `typephpEnabled()` — true when `--typephp` is passed or `TINYJS_TYPEPHP=1`.
* `tinyjs dev --typephp` — spawns the launcher (which spawns shim → PHP) instead
  of txiki. Windows-only for now, because only the Windows launcher is patched.
  Honours `TINYJS_LAUNCHER`, so the launcher can live anywhere, including in this
  repo's `build/runtime/`.
* `tinyjs build --typephp` — assembles a portable `dist/` from a pre-compiled
  backend instead of bundling a JS module graph. The project's `tinyjs.json`
  supplies the how: a `typephp.build` shell hook, `typephp.app`, `typephp.dlls`.
* `tinyjs publish --typephp` — zips that `dist/`.

The 3 rewritten lines are a real bug fix, not noise: upstream runs
`tar -a -cf x.zip`, but on Windows `tar.exe` may be GNU tar, which **cannot write
zip** — `-a` with a `.zip` name silently produces an uncompressed POSIX tar that
looks fine until a user tries to open it. The patch adds `zipTar()` (finds
`%SystemRoot%\System32\tar.exe`, i.e. bsdtar 3.7.7, which does write zip) and
`assertRealZip()` (fails loudly if the result is not actually a zip).

## Regenerating the bases for a new upstream version

```bash
TAG=v0.43.0
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/cli.js" \
  -o patches/base/cli.js.orig
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/native/launcher-win.cc" \
  -o patches/base/launcher-win.cc.orig

# then try the existing patches; fix rejects and regenerate:
cd /tmp && cp <checkout>/cli.js cli.js
diff -u --label 'cli.js.orig' --label 'cli.js' \
  patches/base/cli.js.orig cli.js > patches/cli-typephp.patch
```

`xget.xi-xu.me` is a GitHub accelerator — direct `raw.githubusercontent.com`
access is unreliable from mainland China.
