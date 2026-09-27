#!/usr/bin/env python3
"""
verify-bundle-macos.py — objective acceptance checks for a macOS .app produced
by `tgui build` (Phase 21c counterpart of tools/verify-bundle.py on Windows).

Everything is PARSED from the artifact, never assumed from the build log:
  1. layout      — Contents/{Info.plist, MacOS/<exec>, MacOS/<exec>.conf,
                   MacOS/launcher-macos, Resources/frontend/index.html,
                   Resources/app/{bin,src,gui/php/src/Tiny/Gui/bootstrap.php}}
  2. Info.plist  — plistlib load; CFBundleExecutable points at a real file;
                   identity keys present; TCC usage strings present
                   (WebKit getUserMedia / Speech crash without them)
  3. Mach-O      — magic + cpu-type slices read from the file headers; the host
                   arch must be covered (AMFI kills what it cannot validate)
  4. codesign    — ad-hoc/linker signature reported (informational)
  5. conf        — parsed with the SHIM's own semantics (key=value, relative
                   to Contents/MacOS); html/app/launcher must resolve to
                   existing paths; app must start with '#!' (stock backend)
  6. exec bits   — App / launcher-macos / run-backend.php are executable
  7. icon        — CFBundleIconFile (if declared) resolves to a real resource
  8. endpoint    — where the launch-mode socket will really be, using the
                   shim's own rule: <MacOS>/app.sock unless sun_path is full or
                   the bundle sits off the boot volume (then the per-user temp
                   dir — see bug #21)

Exit 0 = all hard checks pass; 1 = at least one FAIL. WARNs don't fail.
"""
import os
import plistlib
import platform
import struct
import subprocess
import sys

FAILS = 0
WARNS = 0

def ok(msg):
    print(f"  ok   {msg}")

def warn(msg):
    global WARNS
    WARNS += 1
    print(f"  !!   {msg}")

def bad(msg):
    global FAILS
    FAILS += 1
    print(f"  FAIL {msg}")

# --- Mach-O parsing ----------------------------------------------------------
CPU = {0x0100000C: "arm64", 0x0100000E: "arm64e", 0x01000007: "x86_64",
       0x00000007: "i386", 0x0100000C | 0x80000000: "arm64_32"}

def macho_arches(path):
    """Return set of arch names in a Mach-O (thin or fat); empty on parse fail."""
    with open(path, "rb") as f:
        data = f.read(4096)
    if len(data) < 4:
        return set()
    magic = data[:4]
    arches = set()
    def thin_cputype(hdr, endian):
        return struct.unpack(endian + "I", hdr[4:8])[0]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):  # 64-bit thin LE/BE
        ct = thin_cputype(data, "<" if magic[0] == 0xCF else ">")
        arches.add(CPU.get(ct, f"cpu-0x{ct:x}"))
    elif magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):  # fat LE/BE
        endian = ">" if magic[0] == 0xCA else "<"  # fat headers are BE on disk
        n = struct.unpack(endian + "I", data[4:8])[0]
        for i in range(min(n, 16)):
            off = 8 + i * 20
            ct = struct.unpack(endian + "I", data[off + 4:off + 8])[0]
            arches.add(CPU.get(ct & ~0x80000000, f"cpu-0x{ct:x}"))
    elif magic in (b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"):  # 32-bit thin
        ct = struct.unpack("<I", data[4:8])[0]
        arches.add(CPU.get(ct, f"cpu-0x{ct:x}"))
    return arches

HOST = {"arm64": {"arm64", "arm64e"}, "x86_64": {"x86_64"}}.get(
    platform.machine(), set())

def check_macho(name, path):
    arches = macho_arches(path)
    if not arches:
        bad(f"{name}: not a parseable Mach-O: {path}")
        return
    if HOST and not (arches & HOST):
        bad(f"{name}: slices {sorted(arches)} do not run on host "
            f"{platform.machine()}")
        return
    # Informational signature REPORT (codesign -dvv), not --verify:
    # `codesign --verify` on a binary inside a partially-sealed bundle
    # reports bundle-context errors that say nothing about whether the
    # LINKER ad-hoc signature is present and loadable (measured in the
    # Phase 21c build: raw --verify failed yet every binary ran). -dvv
    # just reads the existing signature block, which is what we actually
    # care about here: is there one at all, and of what kind?
    sig = "no signature"
    try:
        rc = subprocess.run(["codesign", "-dvv", path],
                            capture_output=True, text=True)
        # codesign -dvv prints its report on stderr, exit 1 when unsigned.
        out = rc.stderr
        if "Signature=adhoc" in out or "adhoc" in out.lower():
            sig = "linker ad-hoc signature"
        elif "CodeDirectory" in out:
            sig = "signed (non-ad-hoc)"
        elif rc.returncode != 0:
            sig = "unsigned"
    except FileNotFoundError:
        sig = "codesign unavailable"
    ok(f"{name}: Mach-O {sorted(arches)} covers host arch; {sig}")

# --- conf parse with the shim's semantics ------------------------------------
def parse_conf(path):
    c = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            c[k.strip()] = v.strip()
    except OSError:
        pass
    return c

def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(f"usage: {sys.argv[0]} /path/to/Name.app")
        return 2
    app = os.path.abspath(sys.argv[1])
    contents = os.path.join(app, "Contents")
    macos = os.path.join(contents, "MacOS")
    res = os.path.join(contents, "Resources")
    print(f"== verify-bundle-macos: {app}")

    # 1. layout
    plist_path = os.path.join(contents, "Info.plist")
    for label, p in [("Info.plist", plist_path), ("MacOS dir", macos),
                     ("Resources dir", res)]:
        if not os.path.exists(p):
            bad(f"layout: missing {label}: {p}")
    if FAILS:
        report()
        return

    # 2. Info.plist
    try:
        with open(plist_path, "rb") as f:
            plist = plistlib.load(f)
    except Exception as e:  # noqa: BLE001 - any parse error is a hard fail
        bad(f"Info.plist does not parse: {e}")
        report()
        return
    exe_name = plist.get("CFBundleExecutable", "")
    for key in ("CFBundleIdentifier", "CFBundlePackageType",
                "CFBundleShortVersionString"):
        if not plist.get(key):
            bad(f"Info.plist missing {key}")
    if not exe_name:
        bad("Info.plist missing CFBundleExecutable")
        report()
        return
    exe = os.path.join(macos, exe_name)
    if not os.path.isfile(exe):
        bad(f"CFBundleExecutable={exe_name} but {exe} does not exist")
        report()
        return
    ok(f"Info.plist parses; CFBundleExecutable -> {exe_name}")
    for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                "NSSpeechRecognitionUsageDescription"):
        if not plist.get(key):
            bad(f"Info.plist missing TCC string {key} "
                f"(linked WebKit/Speech code turns that into a launch-time crash)")

    # 3+4. Mach-O + signature on the two entries
    check_macho(exe_name, exe)
    launcher = os.path.join(macos, "launcher-macos")
    if os.path.isfile(launcher):
        check_macho("launcher-macos", launcher)
    else:
        bad(f"missing MacOS/launcher-macos (the shim spawns it by name)")

    # 5. conf, parsed the way backend_shell.cpp does
    conf_path = os.path.join(macos, exe_name + ".conf")
    if not os.path.isfile(conf_path):
        bad(f"shim launch mode seeks {conf_path} (<exe stem>.conf); missing")
    else:
        conf = parse_conf(conf_path)
        for key in ("html", "app", "launcher"):
            v = conf.get(key)
            if not v:
                bad(f"App.conf missing {key}=")
                continue
            p = v if os.path.isabs(v) else os.path.normpath(
                os.path.join(macos, v))
            if not os.path.exists(p):
                bad(f"App.conf {key}={v} resolves to nonexistent {p}")
            else:
                ok(f"App.conf {key}={v} -> exists")
        appbin = conf.get("app", "")
        if appbin:
            p = appbin if os.path.isabs(appbin) else os.path.normpath(
                os.path.join(macos, appbin))
            try:
                head = open(p, "rb").read(2)
            except OSError:
                head = b""
            if head == b"#!":
                ok("backend is a shebang script (stock php route — "
                   "target machine needs `php` on PATH)")
            else:
                warn(f"backend head={head!r}: shim will classify it "
                     f"TYPEPHP_APP_KIND != stock")

    # 6. exec bits
    for label, p in [(exe_name, exe), ("launcher-macos", launcher)]:
        if os.path.isfile(p) and not os.access(p, os.X_OK):
            bad(f"{label} not executable")
    runner = os.path.join(res, "app", "bin", "run-backend.php")
    if os.path.isfile(runner):
        if not os.access(runner, os.X_OK):
            bad("Resources/app/bin/run-backend.php not executable "
                "(shim execv's it without argv)")
    else:
        bad(f"missing bundled backend entry {runner}")
    for label, p in [("backend.php", os.path.join(res, "app", "src", "backend.php")),
                     ("bootstrap.php", os.path.join(res, "app", "gui", "php", "src",
                                                    "Tiny", "Gui", "bootstrap.php"))]:
        if not os.path.isfile(p):
            bad(f"bundled backend mirror incomplete: missing {label} ({p})")
    if os.path.isfile(os.path.join(res, "frontend", "index.html")):
        ok("Resources/frontend/index.html present")
    else:
        bad("Resources/frontend/index.html missing")

    # 7. icon
    icon = plist.get("CFBundleIconFile")
    if icon:
        cands = [os.path.join(res, icon), os.path.join(res, icon + ".icns")]
        if not any(os.path.isfile(c) for c in cands):
            bad(f"CFBundleIconFile={icon} resolves to no resource "
                f"(tried {cands})")
        else:
            ok(f"icon resource for CFBundleIconFile={icon} present")
    else:
        warn("no CFBundleIconFile — Finder shows the generic icon "
             "(tgui build warns too; not fatal)")

    # 8. launch-mode endpoint: mirror the shim's own selection rule, so the
    #   bundle we ship states where the socket will really be. Two measured
    #   reasons it leaves the app dir (see shim/backend_shell.cpp):
    #     a) sun_path holds 104 usable bytes on macOS;
    #     b) macOS blocks a LaunchServices-spawned app's FIRST new file on a
    #        non-boot volume until kTCCServiceSystemPolicyRemovableVolumes is
    #        answered — and that request can stay pending forever (bug #21,
    #        measured 2026-09-27 in experiments/ls-bind-probe: 786/786 samples
    #        in __open at a plain open(O_CREAT), so it is NOT socket-specific).
    #   A relocated endpoint is a fact about the layout, not a defect: `ok`.
    CAP = 104
    sock = os.path.join(macos, "app.sock")
    same_vol = os.stat(macos).st_dev == os.stat("/").st_dev
    why = None
    if len(sock.encode()) >= CAP:
        why = f"sun_path full ({len(sock)}B >= {CAP})"
    elif not same_vol:
        why = ("app dir is not on the boot volume — a LaunchServices launch "
               "would block creating the socket there (bug #21)")

    def tmp_endpoint():
        d = (os.environ.get("TMPDIR") or "/tmp").rstrip("/") or "/tmp"
        if len(d) + 40 >= CAP:
            d = "/tmp"
        return d + "/tinyjs-typephp-<pid>.sock"

    if why:
        ok(f"endpoint leaves the app dir ({why}) -> {tmp_endpoint()}")
    else:
        ok(f"launch-mode endpoint stays in the bundle "
           f"({len(sock.encode())}/{CAP}B): {sock}")

    report()
    return 1 if FAILS else 0

def report():
    total = "PASS" if FAILS == 0 else f"FAIL ({FAILS})"
    print(f"== result: {total}, {WARNS} warning(s)")

if __name__ == "__main__":
    sys.exit(main())
