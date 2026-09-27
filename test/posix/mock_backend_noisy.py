#!/usr/bin/env python3
"""A deliberately NOISY stand-in for the PHP backend — the stderr-isolation probe.

`mock_backend.py` is well-behaved; this one writes garbage to stderr *while* it is
answering a call, so the two output channels are exercised at the same instant.
That is the whole point: it is the adversarial counterpart to the happy path.

What it does per `CALL <id> …`
------------------------------
  1. writes a DECOY to stderr that is byte-for-byte a plausible protocol frame
     for the very id being answered:  `RET <id> 0 {"from":"stderr"}`
  2. writes a partial stderr line (no newline) and finishes it later, to exercise
     the shim's per-channel line reassembly rather than just whole lines
  3. writes the REAL answer to stdout:  `EVAL@*` then `RET <id> 0 {...}`

Why the decoy is a *RET* and not just text
------------------------------------------
A stray line of prose would only prove the shim tolerates junk. A decoy RET is
strictly stronger, because it is **ambiguous with the real answer**: the client
waits for `RET <id> 0 ` and would accept the decoy as the answer. If the channels
were ever merged, the decoy would be consumed as the reply for that id and the
real RET would then arrive while the client is waiting for the *next* id, which
the client reports as an unexpected frame. So the failure mode is loud and points
at the right call, instead of silently succeeding minus a reply.

If the shim routed stderr into the frame channel, the client would see this
(and only this) symptom:
    FAIL: unexpected frame while waiting for id01: 'RET id00 0 {"from":"stderr"}'
With pristine output, the decoy never reaches the wire and shows up only in the
shim's own log, prefixed `[shell] backend stderr:`.

Positive control (`NOISY_CHANNEL=stdout`)
----------------------------------------
`NOISY_CHANNEL` moves the decoy onto stdout, i.e. into the frame channel. The
client MUST then fail — that is what makes the passing run above meaningful
rather than vacuous. Without this control, "the test passed" could just mean the
decoy never got written at all.
"""
import os
import sys


def main() -> int:
    # Raw bytes on both channels, for the same reason as mock_backend.py: text
    # mode would translate '\n' to '\r\n' and make framing platform-dependent.
    out = sys.stdout.buffer
    err = sys.stderr.buffer

    # Default: stderr (the correct channel). `stdout` deliberately injects the
    # decoy into the frame stream and must be detectable as a failure.
    noisy = os.environ.get("NOISY_CHANNEL", "stderr").strip().lower()
    ch = out if noisy == "stdout" else err

    out.write(b"READY\n")
    out.flush()

    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return 0  # EOF: the shim closed our stdin, time to exit
        line = line.rstrip(b"\r\n")
        if not line:
            continue
        if not line.startswith(b"CALL "):
            continue  # notification: no reply, by protocol

        parts = line.split(b" ", 2)
        fid = parts[1].decode("utf-8", "replace") if len(parts) > 1 else "0"

        # 1. The decoy. Indistinguishable from a real answer for this exact id.
        ch.write(('RET %s 0 {"from":"%s","decoy":true}\n' % (fid, noisy)).encode())
        # 2. A partial line: the shim must buffer it and not emit it early.
        ch.write(b'PHP Notice: undefined variable in ')
        ch.flush()
        ch.write(b'/srv/app/handler.php on line 42\n')
        ch.flush()

        # 3. The real answer, on the real channel, in the real order.
        out.write(('EVAL@* window.__emit && window.__emit('
                   '{"event":"mock","data":{"id":"%s"}})\n' % fid).encode())
        out.write(('RET %s 0 {"ok":true,"id":"%s"}\n' % (fid, fid)).encode())
        out.flush()


if __name__ == "__main__":
    sys.exit(main())
