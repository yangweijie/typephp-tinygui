#!/usr/bin/env python3
"""Stand-in for the aot-compiled PHP backend, for POSIX shim verification.

The shim spawns its backend with **no arguments** (`spawn_proc(app, {}, …)`), so
the backend must be a self-contained executable — which is why this is a
shebang'd script we `chmod +x` rather than `python3 mock_backend.py`. On POSIX
`execv()` handles the shebang, so a script is a perfectly good "backend"; on
Windows the equivalent has to be a real .exe, which is exactly why this kit is
POSIX-only.

Protocol implemented (identical to planb/backend.php):
  * print a `READY` banner on startup (the launcher ignores unknown frames);
  * `CALL <id> [...]` -> emit an `EVAL@*` window frame FIRST, then
    `RET <id> 0 <json>`;
  * anything else (WINSTATE / SYS / NAV / MENU …) is a NOTIFICATION and gets
    **no reply** — the launcher answers those itself.
Writing to stderr is avoided on purpose, but NOT because it is the frame channel:
stdout is the frame channel, and the shim keeps stderr on a **separate** pipe that
it drains into its own log. See `mock_backend_noisy.py`, which abuses stderr
deliberately to prove the two channels really are isolated.
"""
import sys


def main() -> int:
    # Work in BYTES, not text: text-mode stdout translates '\n' to '\r\n' on
    # Windows, which would make the frame stream platform-dependent. The real
    # aot-compiled backend writes raw LF too (the shim pops a stray trailing
    # '\r' if one ever appears).
    out = sys.stdout.buffer
    inp = sys.stdin.buffer

    out.write(b"READY\n")
    out.flush()

    # readline() (not `for line in sys.stdin`) so each frame is consumed as soon
    # as it lands instead of being held in the iterator's read-ahead buffer.
    while True:
        line = inp.readline()
        if not line:
            return 0  # EOF: the shim closed our stdin, time to exit
        line = line.rstrip(b"\r\n")
        if not line:
            continue
        if line.startswith(b"CALL "):
            parts = line.split(b" ", 2)
            fid = parts[1].decode("utf-8", "replace") if len(parts) > 1 else "0"
            # Window frames must precede the RET for the same call.
            out.write(('EVAL@* window.__emit && window.__emit('
                       '{"event":"mock","data":{"id":"%s"}})\n' % fid).encode())
            out.write(('RET %s 0 {"ok":true,"id":"%s"}\n' % (fid, fid)).encode())
            out.flush()
        else:
            # Notification: deliberately no reply. This is the case that hangs a
            # request/response-coupled proxy.
            continue


if __name__ == "__main__":
    sys.exit(main())
