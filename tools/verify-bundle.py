#!/usr/bin/env python3
"""Verify a TypePHP dist/ bundle before you ship it.

Answers the questions a successful `tinyjs build --typephp` does NOT answer by
itself, all of which have been wrong at least once:

  * is the ENTRY a GUI-subsystem binary? A console (CUI) entry docks a black
    console window for the app's whole lifetime when double-clicked.
  * does the ENTRY carry an icon resource? `icon=` in the .conf only covers the
    runtime window/taskbar icon; Explorer reads the exe resources.
  * is dist/launcher.exe byte-for-byte the launcher it was copied from? The
    packaged direction drives the launcher through its STOCK argument contract
    (`<html> <endpoint> [title] [WxH] [version]`), so packaging must not modify
    it. Pass the source with --launcher; without it this check is skipped.
  * are php.exe (the compiled PHP backend), the eight runtime DLLs (six PHP +
    two MinGW), the conf and the frontend all present?

Usage:
    python verify-bundle.py <dist-dir> [--launcher <the launcher dist/ was copied from>]
Exit: 0 = all good, 1 = a problem that will bite a user, 2 = usage error.
"""
import ctypes
import hashlib
import os
import struct
import sys

SUBSYSTEM_NAMES = {1: "native", 2: "GUI", 3: "console", 5: "OS/2", 7: "POSIX",
                   9: "Windows CE", 10: "EFI app", 11: "EFI boot", 12: "EFI ROM",
                   14: "Xbox", 16: "Windows boot"}
PHP_RUNTIME_DLLS = [
    "php8ts.dll", "phpx.dll", "libmpdec-4.0.1.dll", "libmpdec++-4.0.1.dll",
    "gmp-10.dll", "mpfr-6.dll",
]
# libgcc/libstdc++: imported by BOTH the shim entry and the (MinGW-built)
# launcher. Missing them means the dist fails to load at all, not just on
# clean machines — so they are required, not optional.
MINGW_RUNTIME_DLLS = ["libgcc_s_seh-1.dll", "libstdc++-6.dll"]

failures = []
warnings = []


def fail(msg):
    failures.append(msg)
    print("  [FAIL] " + msg)


def warn(msg):
    warnings.append(msg)
    print("  [WARN] " + msg)


def ok(msg):
    print("  [ OK ] " + msg)


def pe_subsystem(path):
    """Return (subsystem:int|None, is_pe:bool). Reads the PE optional header."""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 0x40 or data[:2] != b"MZ":
        return None, False
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_off + 24 + 70 > len(data) or data[pe_off:pe_off + 4] != b"PE\0\0":
        return None, False
    return struct.unpack_from("<H", data, pe_off + 24 + 68)[0], True


def icon_count(path):
    """Number of icons Windows can extract from the file (0 = no icon resource).

    Uses the same API Explorer effectively consults, so it reflects reality
    rather than our belief about the resource directory.
    """
    try:
        shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    except OSError:
        return None
    shell32.ExtractIconExW.argtypes = [ctypes.c_wchar_p, ctypes.c_int,
                                       ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_uint]
    shell32.ExtractIconExW.restype = ctypes.c_uint
    return shell32.ExtractIconExW(path, -1, None, None, 0)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    if not a:
        print(__doc__)
        return 2
    dist = a[0]
    stock = None
    if "--launcher" in sys.argv:
        stock = sys.argv[sys.argv.index("--launcher") + 1]
    if not os.path.isdir(dist):
        print("not a directory: " + dist)
        return 2

    # The entry is <name>.exe, and tgui build writes a matching <name>.conf
    # beside it — use that linkage rather than guessing from the .exe list (which
    # also contains php.exe and launcher.exe).
    confs_all = [f for f in os.listdir(dist) if f.endswith(".conf")]
    entries = [os.path.splitext(c)[0] + ".exe" for c in confs_all
               if os.path.exists(os.path.join(dist, os.path.splitext(c)[0] + ".exe"))]
    if not entries:
        entries = [f for f in os.listdir(dist)
                   if f.lower().endswith(".exe")
                   and f.lower() not in ("launcher.exe", "php.exe", "app.exe")]
    if len(entries) != 1:
        fail("could not identify a single entry exe, found %d (%s)"
             % (len(entries), ", ".join(entries) or "none"))
        return 1
    entry = os.path.join(dist, entries[0])

    print("== entry: %s ==" % entries[0])
    sub, is_pe = pe_subsystem(entry)
    if not is_pe:
        fail("entry is not a PE image (double-click would not start it)")
    elif sub == 2:
        ok("PE subsystem GUI (no console window on double-click)")
    elif sub == 3:
        fail("PE subsystem is CONSOLE — double-clicking docks a console window "
             "for the app's whole lifetime")
    else:
        fail("PE subsystem is %s (%s), expected GUI" %
             (sub, SUBSYSTEM_NAMES.get(sub, "?")))

    n = icon_count(entry)
    if n is None:
        warn("could not call ExtractIconExW; skipped the icon check")
    elif n > 0:
        ok("icon resource present (%d icon(s) extractable by Explorer)" % n)
    else:
        warn("no icon resource — Explorer shows the generic exe icon "
             "(the .conf icon only sets the runtime window/taskbar icon)")

    print("== launcher ==")
    launcher = os.path.join(dist, "launcher.exe")
    if not os.path.exists(launcher):
        fail("launcher.exe missing — the entry spawns it")
    elif stock and os.path.exists(stock):
        if sha256(launcher) == sha256(stock):
            ok("byte-for-byte the launcher it was copied from")
        else:
            warn("launcher.exe differs from %s — the packaged direction is meant "
                 "to ship an unmodified launcher" % os.path.basename(stock))
    else:
        ok("launcher.exe present")

    print("== PHP backend + runtime ==")
    php = os.path.join(dist, "php.exe")
    if not os.path.exists(php):
        fail("php.exe missing — the compiled PHP backend (tgui build copies it "
             "under this name; the ENTRY <name>.exe is the shim, not the backend)")
    else:
        ok("php.exe present (%d bytes)" % os.path.getsize(php))
    required = PHP_RUNTIME_DLLS + MINGW_RUNTIME_DLLS
    missing = [d for d in required if not os.path.exists(os.path.join(dist, d))]
    if missing:
        fail("missing runtime DLLs: %s — php.exe / launcher.exe / the shim work "
             "on a machine with those on PATH and fail on a clean one"
             % ", ".join(missing))
    else:
        ok("all %d runtime DLLs present (6 PHP + 2 MinGW)" % len(required))

    print("== conf + frontend ==")
    confs = [f for f in os.listdir(dist) if f.endswith(".conf")]
    if not confs:
        fail("no <name>.conf — the entry has no html/title/size to launch with")
    else:
        ok("conf present: %s" % ", ".join(confs))
    fe = os.path.join(dist, "frontend", "index.html")
    if os.path.exists(fe):
        ok("frontend/index.html present")
    else:
        warn("no frontend/index.html (fine only for a \"url\" wrapper app)")

    total = sum(os.path.getsize(os.path.join(dist, f))
                for f in os.listdir(dist)
                if os.path.isfile(os.path.join(dist, f)))
    print("\ntop-level size: %.1f MB" % (total / 1e6))
    print("RESULT: %d failure(s), %d warning(s)" % (len(failures), len(warnings)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
