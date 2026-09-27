# Upstream issue material — `tpc` / `php-nano` / `phpx` nano route

Status: **drafted, NOT filed.** Nothing here has been opened against any upstream repo, and nothing
should be without an explicit decision. Each file below is written so it can be pasted into a new
issue as-is.

## The three gaps and how they stack

They are independent, and they sit in the order you hit them:

| # | file | owned by | symptom | what it costs us |
|---|---|---|---|---|
| 1 | [`phpx-nano-args-get-link-gap.md`](phpx-nano-args-get-link-gap.md) | `swoole/phpx` (nano source manifest) | `ld`: `undefined reference to php::Args::get(unsigned long) const` | the 16-module aggregated backend never finishes linking |
| 2 | [`tpc-nano-core-dependency-unsatisfiable.md`](tpc-nano-core-dependency-unsatisfiable.md) | `tpc` + `php-nano` | build succeeds, then `Unable to start PHP Nano extensions`, rc=1 | any program that calls `strlen`/`strcmp`/… cannot start |
| 3 | [`php-nano-missing-stdio-handles.md`](php-nano-missing-stdio-handles.md) | `swoole/php-nano` | `STDIN`/`STDOUT` undefined, `php://` wrapper absent, `/dev/std*` unopenable | our stdio frame protocol has no I/O path even with 1+2 fixed |

1 is a link-time wall, 2 a start-time wall, 3 a run-time wall. We verified a working patch for 1
(compile the two `Args` accessors into an already-composed TU → the backend links to a 6,933,344 B
libphp-free binary) and a 4-line patch for 2 (a `strlen` program then prints `15`). With both in
place the aggregated backend still produces **zero protocol frames**, which is where 3 takes over.

## Shared reproduction environment

- Apple Container instance `tgl`, Debian bookworm aarch64, repo at `/work/repo`, tpc at `/work/tpc`
  (compile with **`/work/tpc/bin/tpc.php`** — `cli.php` is a *run* wrapper and will print `READY`
  instead of compiling).
- tpc v0.9.3 · swoole/php-nano v1.0.1 · swoole/phpx ~2.9.2 · host PHP 8.4.25 ·
  g++ (Debian 12.2.0-14+deb12u1) 12.2.0 · GNU ld 2.40.
- Work dir must be cold (`rm -rf /tmp/tpgui-tier6`) so a `--dry` run cannot pass off a cached
  artifact as a fresh result.

Regenerate the measurements:

```
base64 -i test/posix/upstream-nano-probes/run-probes.sh \
  | container exec -i tgl sh -lc 'base64 -d > /tmp/g.sh && sh /tmp/g.sh'
```

The script is read-only apart from writing `recheck-*` artifacts under `/tmp/tpgui-tier6`; it needs
the probe `.php` files and the tier-6 build dirs to already be there, and it prints the transcript
that `evidence/linux/25-deps-vs-modules.txt` stores.

## Evidence stored in this repo

| file | contents |
|---|---|
| `evidence/linux/25-deps-vs-modules.txt` | required deps vs composed arrays, the `"Core"` citations, the empirical startup table, a from-scratch recheck on an unpatched tree, probe sources |
| `evidence/linux/25-upstream-probe.txt` | the two reverted patches (phpx `variant.cc`, tpc `Translator.php`), the successful 6.9 MB link, the symbol/manifest dump |
| `evidence/linux/25-naive-fix-fails.log` | full build log for "just add `src/core/extension.cc`" — 4 compile errors, rc=255 |
| `evidence/linux/24-*` | the original tier-6 run: the failing link line, the 240-vs-138 object comparison, the driver verdict |

Known defect in one stored transcript: `25-upstream-probe.txt` §B prints `modules []` three times —
that came from a broken grep (composer arrays hold C *variables* like `basic_functions_module`, not
name strings). The corrected raw data is `25-deps-vs-modules.txt` §1. Nothing else in that file is
superseded.

## One correction to what Phase 24 recorded

Phase 24 concluded that the aggregated build "keeps `basic_functions_module`, so its
`ZEND_MOD_REQUIRED("Core")` is satisfiable", and that the startup gap only bit the small `strlen`
probe. **That inference is falsified.** `basic_functions_module` is named `"standard"`; nothing in a
composer array is ever named `"Core"`, so the linked aggregate dies at startup too — measured:
`app-nano-fixed` (patch 1 only) → `Unable to start PHP Nano extensions`, rc=1. The Phase 24 driver
assertion `test/posix/tier6-nano-aggregate.sh [4c]` and the README wording were fixed in Phase 25.

Also worth recording: the item we had numbered **#33** ("the driver passes on a GAP it should not")
was **our own** compound-assertion bug, not an upstream gap. The upstream set is exactly 1 + 2 + 3.
