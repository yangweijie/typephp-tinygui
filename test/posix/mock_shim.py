#!/usr/bin/env python3
"""An AF_UNIX endpoint server that stands in for backend_shell.

The pristine `launcher-linux` is the *client* on POSIX (bug #15's shape: the
shim owns the endpoint), and it drives its native desktop integrations from
plain text frames on that socket — TRAYBEGIN/ITEM/TRAYEND, HKREG/HKUNREG.
Our PHP backend exposes `menu.set` but NOT `tray.set` / `hotkey.register`, so
those frames are currently unreachable from a page. Rather than invent product
surface inside an acceptance test, this harness speaks the transport and injects
the frames directly, which is exactly what a backend that had the API would do.

It answers every `CALL <id> …` with `RET <id> 0 true` (the page's promises
resolve to a stub; this test asserts on the LAUNCHER's behaviour, not the
page's), logs every line it receives verbatim, and exits on EOF.

usage: mock_shim.py <socket> --log <path> [--inject <frames-file>]
                    [--inject-after 2.5] [--accept-timeout 25]
exit:  0 = a launcher connected and the session ended cleanly,
       4 = no launcher connected before the timeout.
"""
import argparse
import os
import socket
import sys
import threading
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock")
    ap.add_argument("--log", required=True)
    ap.add_argument("--inject", default="")
    ap.add_argument("--inject-after", type=float, default=2.5)
    ap.add_argument("--accept-timeout", type=float, default=25.0)
    args = ap.parse_args()

    if os.path.exists(args.sock):
        os.unlink(args.sock)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.sock)
    srv.listen(1)
    srv.settimeout(args.accept_timeout)

    log = open(args.log, "w", buffering=1)
    log.write("listening %s\n" % args.sock)

    try:
        conn, _ = srv.accept()
    except socket.timeout:
        log.write("no launcher connected\n")
        return 4
    log.write("launcher connected\n")
    conn.settimeout(1.0)

    stop = threading.Event()

    def inject():
        if not args.inject:
            return
        time.sleep(args.inject_after)
        with open(args.inject) as fh:
            for line in fh.read().splitlines():
                if not line:
                    continue
                # \t in the frames file is literal so the file stays greppable.
                conn.sendall((line.replace("\\t", "\t") + "\n").encode())
                log.write("injected %s\n" % line)
        stop.wait(0.2)

    def pump():
        buf = b""
        while not stop.is_set():
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", "replace")
                log.write("L->P: %s\n" % text)
                if text.startswith("CALL "):
                    parts = text.split(" ", 2)
                    if len(parts) >= 2:
                        conn.sendall(("RET %s 0 true\n" % parts[1]).encode())
        log.write("launcher closed\n")
        stop.set()

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    threading.Thread(target=inject, daemon=True).start()

    deadline = time.time() + args.accept_timeout
    while t.is_alive() and time.time() < deadline:
        t.join(0.25)
    stop.set()
    try:
        conn.close()
    except OSError:
        pass
    srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
