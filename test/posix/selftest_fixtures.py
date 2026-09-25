#!/usr/bin/env python3
"""Self-test for the POSIX kit's FIXTURES (not for the C++ shim).

`mock_launcher.py` is the oracle of the whole kit: if it disagrees with
`mock_backend.py` about the frame format, `run.sh` fails on Linux for a reason
that has nothing to do with `backend_shell.cpp` — and you would burn a remote
round-trip finding that out.

This runs **anywhere**, including Windows (no AF_UNIX needed): it monkeypatches
`socket.socket` with a shim that pipes straight into `mock_backend.py` over
stdio, then executes the real `mock_launcher.py` through that fake socket. So the
launcher's actual parsing/assertions are exercised against the backend's actual
replies.

    python3 selftest_fixtures.py            # exit 0 = fixtures agree

It does NOT prove anything about the C++ shim — that is `run.sh` on Linux.
"""
import os
import runpy
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "mock_backend.py")
LAUNCHER = os.path.join(HERE, "mock_launcher.py")
N_CALLS = "5"


class FakeSocket:
    """Stands in for the AF_UNIX connection: writes go to the backend's stdin,
    reads come from its stdout. Mirrors the real socket API subset that
    mock_launcher.py uses."""

    procs = []

    def __init__(self, *args, **kwargs):
        self.proc = subprocess.Popen(
            [sys.executable, BACKEND],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        FakeSocket.procs.append(self.proc)

    def settimeout(self, _t):
        pass

    def connect(self, _path):
        pass  # the pipe is already "connected"

    def sendall(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def recv(self, n):
        # read1 returns whatever is available rather than blocking for n bytes,
        # which is what a socket does for small reads.
        chunk = self.proc.stdout.read1(n)
        # This object stands in for the *launcher-facing* side of the shim, and
        # the shim normalises line endings before forwarding (its pump pops a
        # trailing '\r'), so emulate that instead of leaking CRLF to the oracle.
        return chunk.replace(b"\r\n", b"\n")

    def close(self):
        try:
            self.proc.stdin.close()  # EOF for the backend, like hanging up
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            raise SystemExit("FAIL: backend did not exit after stdin closed")


def main() -> int:
    if not os.path.exists(BACKEND) or not os.path.exists(LAUNCHER):
        print("FAIL: fixtures missing next to this file")
        return 2

    saved_socket, saved_argv = socket.socket, sys.argv
    # Windows Python has no AF_UNIX; the launcher only *passes* it to the
    # constructor we are about to replace, so a placeholder is enough.
    if not hasattr(socket, "AF_UNIX"):
        socket.AF_UNIX = 1
    socket.socket = FakeSocket
    sys.argv = [LAUNCHER, "/nonexistent.sock", N_CALLS]
    try:
        runpy.run_path(LAUNCHER, run_name="__main__")
        print("FAIL: mock_launcher returned without SystemExit")
        return 2
    except SystemExit as e:
        code = e.code or 0
    finally:
        socket.socket, sys.argv = saved_socket, saved_argv

    # Always reap the children: if the oracle bailed out early it never called
    # close(), leaving the backend blocked on readline() — which would hang the
    # interpreter at exit instead of reporting the failure.
    problems = []
    for p in FakeSocket.procs:
        if p.poll() is None:
            try:
                p.stdin.close()  # let it see EOF
            except OSError:
                pass
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        err = p.stderr.read().decode("utf-8", "replace") if p.stderr else ""
        if p.returncode != 0:
            problems.append("backend exit %s (stderr=%r)" % (p.returncode, err))

    if problems:
        for problem in problems:
            print("FAIL: %s" % problem)
        return 1

    if code != 0:
        print("FIXTURES DISAGREE (mock_launcher exit %s)" % code)
        return 1
    print("FIXTURES OK: mock_launcher and mock_backend agree on the frame protocol")
    return 0


if __name__ == "__main__":
    sys.exit(main())
