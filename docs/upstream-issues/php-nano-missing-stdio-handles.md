# A standalone `--nano` binary has no handle on its own stdio: `STDIN`/`STDOUT` undefined, `php://` wrapper absent, `/dev/std*` unopenable

Filed against: `swoole/php-nano` (embedded runtime), with a question for `tpc` docs.

**Versions measured:** tpc v0.9.3 · swoole/php-nano v1.0.1 · swoole/phpx ~2.9.2 · host PHP 8.4.25 ·
nano `phpversion()` reports `8.6.0beta3` · g++ 12.2.0 · Debian bookworm aarch64 (Apple Container).

## Summary

`tpc --nano` produces a *standalone executable*, but that executable exposes no way to reach its own
standard streams:

- the `STDIN` / `STDOUT` / `STDERR` constants are undefined (they belong to the CLI SAPI),
- the `php://` stream wrapper is not registered,
- `fopen("/dev/stdin")` / `fopen("/dev/stdout")` fail with `No such file or directory` even though
  those symlinks exist in the container and the same binary opens a regular file and `/dev/null`
  without problem.

`echo`/`print` do reach stdout (we get plain output from small programs), so writing is possible
through buffered echo only. **Reading stdin has no path at all** that we could find.

## Reproduction

Four single-file programs, each compiled with
`php8.4 /work/tpc/bin/tpc.php <src>.php --nano -o <out> --build-dir <dir>` and then run with
`stdin=/dev/null` (measured in `evidence/linux/25-deps-vs-modules.txt` §3; sources in
`test/posix/upstream-nano-probes/`):

| source | program | result |
|---|---|---|
| `nano_stdout.php` | `fwrite(STDOUT, "stdout-ok\n");` | `Undefined constant "STDOUT"`, `Aborted`, **rc=134** |
| `nano_stream.php` | `$out = fopen("php://stdout", "w");` | stderr: `Unable to find the wrapper "php" - did you forget to enable it when you configured PHP?` then `Failed to open stream: No such file or directory`; program sees `false`, prints `fopen failed`, rc=0 |
| `nano_devio.php` | `fopen("/dev/stdin","r")` + `fopen("/dev/stdout","w")` | stderr: `Failed to open stream: No such file or directory`; program prints `fopen failed`, rc=0 |
| `nano_file.php` | `fopen("probe.txt","r")` and `fopen("/dev/null","r")` | `regular fopen ok: line-one` / `/dev/null: ok`, rc=0 |

The last line is the control that makes this a nano gap rather than an environment gap: within one
binary, real paths open and stdio paths do not — while the container's symlinks are intact:

```
lrwxrwxrwx 1 root root 15 Sep 26 17:33 /dev/stdin  -> /proc/self/fd/0
lrwxrwxrwx 1 root root 15 Sep 26 17:33 /dev/stdout -> /proc/self/fd/1
```

## Why this is a hard blocker for us (not a nicety)

Our backend speaks a line protocol over the pipe: it is spawned by a native launcher, reads
`CALL <id> <json>` lines from stdin and writes `RET <id> <status> <json>` lines to stdout. Every
byte of that lives on the standard streams:

```php
// gui/php/src/Tiny/Gui/Backend.php
75:   $chunk = fread(STDIN, 4096);
102:  fwrite(STDOUT, $s);
103:  fflush(STDOUT);
```

After the `Core` dependency issue is patched away, our aggregated backend gets past extension
startup and then dies immediately (`Unhandled TypePHP exception`, zero frames, rc=1) — consistent
with `STDIN` being the first thing `Backend::run()` touches. We did **not** instrument the binary
to prove that last step, so treat it as the remaining hypothesis; the four probes above are the
measured facts.

## Asks

1. Register the CLI-equivalent `STDIN` / `STDOUT` / `STDERR` resources in nano's startup (they are
   just fd 0/1/2; the `php_stream` API has standard wrappers for them), so `fopen("php://stdout")`,
   `php://input`, `php://memory`, `php://temp` and the three constants work.
2. If their absence is deliberate — nano being designed to be embedded in a host that owns the
   process — then please say so in the `--nano` docs and name the supported way to do pipe I/O from
   a standalone nano binary (an FFI/`phpx` hook? a `typephp-native` component to opt in?).
3. Either way: making an undefined `STDOUT` a *compile-time* error rather than a runtime abort
   would be a big usability win, because today a `--nano` program that is otherwise perfect dies
   with `Aborted`/rc=134 and no location.

## Evidence in our repo

- `evidence/linux/25-deps-vs-modules.txt` §3 — the four probes with rc and exact stderr, plus the
  regular-file//dev-null control in the same binary
- `test/posix/upstream-nano-probes/*.php` — the probe sources, verbatim
- `test/posix/upstream-nano-probes/run-probes.sh` — regenerates the whole transcript
