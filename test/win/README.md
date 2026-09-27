# Windows verification kit for `tgui dev`

`test/posix/` covers the shim's POSIX half. This directory covers the other half:
the **Windows dev lifecycle**, which no macOS or Linux run can prove. Two scripts,
in order:

| Script | Runs on | Purpose |
|---|---|---|
| `dev-bounce.sh` | the Windows box, inside Git Bash | drives `tgui dev`, bounces it twice, asserts the process lifecycle |
| `collect-evidence.sh` | the same box, right after a PASS | copies the run artifacts into `evidence/win/` and derives a re-computable manifest |

## Why a dedicated driver exists

`dev`'s hot restart on Windows rests on exactly one mechanism. The CLI kills the
launcher with Git Bash `kill`; a killed process runs no `atexit` handler, so
launcher-win.cc's `terminate_typephp_backend()` never fires, and `dev_reap_shim()`
is Linux-only (`[ "$OS" = Linux ] || return 0`). **Named-pipe EOF in the shim is
the sole reaper** of the PHP child. So the load-bearing assertion is not "the
window opened" — it is:

> after **two** bounces, there is still exactly 1 `launcher-win.exe` / 1 `backend.exe`
> / 1 `app.exe`, and **each cycle came up on a fresh named pipe**.

One bounce is not enough: a leak that compounds per cycle is invisible in a single
sample, and a reused pipe name would mean the old instance never died while a new
one was stacked on top of it.

The run also proves three secondary things: Git Bash `kill` / `kill -0` reach a
native `launcher-win.exe`; the mtime watcher works under GNU `stat -c` (the driver
asserts BSD `-f` is *rejected*, because a box that answers both makes `hot_snap`
pick a dialect whose digest never changes); and, if MinGW `g++` is on PATH, the
shim's `_WIN32` branch recompiles with `-Wall -Wextra` at 0 warnings.

## Run it

```bash
bash test/win/dev-bounce.sh                        # full run, evidence -> /tmp/tpgui-21e
REBUILD_SHIM=0 bash test/win/dev-bounce.sh         # skip the MinGW shim rebuild
WORK=/c/temp/tpgui-21e bash test/win/dev-bounce.sh
```

7 steps: preflight (toolchain + the launcher/shim/app trio resolved **the same way
`gui/bin/tgui` resolves it**, including staging `build/app.exe` that tgui's
`[ -f ]` gate checks *before* the `tinyjs.json` override) → shim rebuild → quiet
box → cycle 1 → bounce into cycle 2 → bounce into cycle 3 → close the window.
Read the last line for `== 21e windows dev driver: PASS`. Exit code is the FAIL
flag. A mid-run FAIL triggers `cleanup` on EXIT so the box is not left with a
window plus a PHP chain behind.

What it does **not** prove: hot reload of PHP *logic*. On Windows the backend is a
tpc-compiled `app.exe`, so `touch src/backend.php` changes only its mtime — this
step proves the restart mechanism. And `test/win/` cannot be exercised on a POSIX
host; the driver exits 2 unless `uname -s` is `MINGW*|MSYS*|CYGWIN*`.

## File the evidence

`/tmp/tpgui-21e` on Git Bash is `%LOCALAPPDATA%\Temp` — it dies with the box, and
the repo convention is that acceptance现场 lives in `evidence/<os>/`. So on the
same machine, immediately after a PASS:

```bash
bash test/win/collect-evidence.sh
git add evidence/win && git commit -m 'evidence(win): Phase 21e dev-bounce 真机现场' && git push
```

The collector **refuses partial evidence** (exit 2) if `shim.log`, `tgui.out` or
any of the three `tasklist.*.txt` dumps is missing — a run that died at step 4
must not file a half story that later reads as a complete PASS. It then writes
`evidence/win/21e-*` plus `21e-MANIFEST.txt`, which derives, from the raw files:

- per-cycle pipe / CALL / RET / `WINDOW-E2E` counts (split on `[shell] transport=`,
  same log discipline as the driver — the frame log is append-only, and
  `WINDOW-E2E` appears **twice per cycle** because the backend echoes it on stderr,
  so it is not a cycle counter);
- `WINDOW-E2E` marker timings in cycle order — the latency numbers README quotes;
- distinct-pipes vs cycles, printed as `OK` or `MISMATCH`;
- launcher/shim/app counts per dump, with an `UNPARSED` guard: a non-empty dump
  whose rows match none of the three names is a *format drift*, and printing
  `0/0/0` there would be a confident lie (the first version of this parser did
  exactly that — it assumed CSV quoting while the dumps are `name pid`);
- sha256 + bytes for every stored file, the host string and the runtime git rev.

Anyone can then re-check it on their own machine, without a Windows box, against
the files already in the repo:

```bash
CHECK=1 OUT="$PWD/evidence/win" bash test/win/collect-evidence.sh
# == CHECK: SAME — every derived block ... reproduces from the stored 21e-* files
```

`CHECK=1` re-derives every block from the raw `21e-*` files and diffs the result
against the filed manifest's body. It writes nothing and needs no Windows — so it
is the check that a quoted number (13/13, 1/1/1, the `416 / 370 / 415ms`) actually
has a source in the evidence, and it is what caught two false figures when this
evidence was first filed. Exit `1` = DRIFT, with the diff inline.

```bash
REGEN=1 OUT="$PWD/evidence/win" bash test/win/collect-evidence.sh
```

`REGEN=1` does the same re-derivation but overwrites `21e-MANIFEST.txt`. Use it
when the derivation logic changes after a run was filed, so the stored manifest
matches the current parser. The original `# collected / # host / # repo rev`
provenance lines are kept verbatim and a single `# re-derived` stamp is appended —
those describe the machine where the driver actually ran, and repeated REGEN runs
must not accumulate stamps or overwrite them with a later machine's.

## Actual result

Phase 21e, real desktop session, no Xvfb: **PASS**, 3 frame cycles on 3 distinct
pipes, `13 CALL / 13 RET` each, 1/1/1 across both bounces, zero residue at
teardown, shim recompiled with 0 warnings.现场 in `evidence/win/`.
