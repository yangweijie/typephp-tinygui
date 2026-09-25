#!/usr/bin/env python3
"""Minimal stand-in for the tinyjsapp launcher, for POSIX shim verification.

The real `launcher-linux` needs GTK + webkit2gtk and a display, which is a lot of
setup to verify a transport. This client speaks the same AF_UNIX + newline-framed
protocol (`runtime/bridge.js` / `launcher-linux.cc`) and nothing else, so it
exercises exactly the shim: endpoint creation, accept, and the bidirectional pump.

It also deliberately replays the shape that deadlocked the first shim design:
notification frames (WINSTATE/SYS) that the backend never answers, interleaved
with CALL frames. A request/response-coupled pump hangs here; the polling pump
must not.

Usage: mock_launcher.py <socket-path> [n_calls]
Exit:  0 = protocol clean, 1 = mismatch/timeout.
"""
import json
import socket
import sys

TIMEOUT = 15.0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: mock_launcher.py <socket-path> [n_calls]")
        return 2
    sock_path = sys.argv[1]
    n_calls = int(sys.argv[2]) if len(sys.argv) > 2 else 5

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.connect(sock_path)
    print("connected to %s" % sock_path)

    # The peer must close exactly when we do, so EOF is what proves the
    # teardown path ran rather than the shim being killed.
    buf = b""

    def read_line():
        nonlocal buf
        while b"\n" not in buf:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                return None
            if not chunk:
                return None
            buf += chunk
        line, buf = buf.split(b"\n", 1)
        return line.decode("utf-8", "replace")

    def send(line: str) -> None:
        s.sendall((line + "\n").encode())

    # 1. the backend's startup banner has to survive the pump
    first = read_line()
    if first != "READY":
        print("FAIL: expected the READY banner first, got %r" % first)
        return 1
    print("banner ok: %r" % first)

    # 2. interleave notifications with calls — the deadlock regression test
    evals = 0
    rets = 0
    for i in range(n_calls):
        send('WINSTATE main {"fullscreen":false,"focused":true}')
        send("SYS theme light")
        payload = json.dumps(json.dumps({"method": "ping", "params": {}}))
        fid = "id%02d" % i
        send('CALL %s [%s,"file://"]' % (fid, payload))
        while True:
            line = read_line()
            if line is None:
                print("FAIL: peer closed/timed out waiting for RET %s "
                      "(%d/%d rets, %d evals) — pump stalled?"
                      % (fid, rets, n_calls, evals))
                return 1
            if line.startswith("EVAL"):
                evals += 1
            elif line.startswith("RET %s " % fid):
                if not line.startswith("RET %s 0 " % fid):
                    print("FAIL: RET for %s carried a non-zero status: %r" % (fid, line))
                    return 1
                rets += 1
                break
            else:
                print("FAIL: unexpected frame while waiting for %s: %r" % (fid, line))
                return 1

    print("calls ok: %d CALL -> %d RET, %d EVAL frames pushed ahead of them"
          % (rets, rets, evals))

    # 3. closing our end must make the shim finish cleanly (it logs
    #    "launcher closed" and exits 0) rather than being terminated.
    s.close()
    print("closed the connection; the shim should now shut down on its own")
    return 0


if __name__ == "__main__":
    sys.exit(main())
