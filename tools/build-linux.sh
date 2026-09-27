#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the TypePHP GUI toolchain on LINUX (packaged + dev direction).
#
#   usage:  bash tools/build-linux.sh
#
# Produces (under build/):
#   backend_shell     the shim (POSIX branch: AF_UNIX server, spawns the stock
#                     launcher + the PHP backend) — also the packaged ENTRY
#   launcher-linux    the NATIVE GTK3 + WebKit2GTK host. Pristine vendor source:
#                     this script only supplies build flags, never a patch, so
#                     the shipped binary stays byte-for-byte upstream-buildable.
#
# The backend is the system-PHP shebang script bin/run-backend.php (tpc AOT is a
# Windows-only toolchain); the POSIX shim execv()s it with no argv, which is why
# that file carries `#!/usr/bin/env php`.
#
# Dev direction here is NOT the win/mac `launcher --typephp` shape (that would
# require patching launcher-linux.cc). The shim owns the AF_UNIX endpoint and the
# pristine launcher connects to it as a client — the same direction
# test/posix/tier4-linux-window.sh proved, and the same one `tgui dev` drives.
#
# Two flags this build MUST pass, both learned the hard way (task_plan Errors
# #23): pristine launcher-linux.cc references `g_indicator` unconditionally in
# can_live_hidden(), while the declaration sits behind #ifdef TINYJS_APPINDICATOR
# → "optional dependency, auto-disable" does NOT hold upstream, so appindicator
# is a hard build requirement, not a nicety. Debian/Ubuntu expose it as the
# pkg-config name `ayatana-appindicator3-0.1`, Fedora/Arch as
# `libayatana-appindicator3.0` — probe both.
# TINYJS_PIPEWIRE stays UNDEFINED on purpose: without it the source compiles the
# #ifndef fallback screen-capture path, which is what we want linked.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
need_pkg() { # need_pkg <pkg-config-name> <Debian package> <Fedora/Arch package>
  pkg-config --exists "$1" 2>/dev/null && return 0
  printf '%s\n' "missing $1 — install it:" >&2
  printf '     Debian/Ubuntu:  apt install %s\n'   "$2" >&2
  printf '     Fedora:         dnf install %s\n'    "$3" >&2
  printf '     Arch:           pacman -S %s\n'      "$3" >&2
  printf '%s\n' "     (only the Debian/Ubuntu names are verified by an actual install here; Fedora/Arch names are indicative)" >&2
  return 1
}

command -v pkg-config >/dev/null 2>&1 || die "pkg-config not found (apt install pkg-config)"

CXX="${CXX:-}"
[ -n "$CXX" ] || for c in g++ c++ clang++; do
  command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }
done
[ -n "$CXX" ] || die "no C++ compiler found (set CXX=... or apt install g++)"

[ -f "$ROOT/shim/backend_shell.cpp" ]          || die "missing shim/backend_shell.cpp"
[ -f "$ROOT/gui/host/src/launcher-linux.cc" ]  || die "missing gui/host/src/launcher-linux.cc"
[ -f "$ROOT/gui/host/include/miniaudio.h" ]    || die "missing gui/host/include/miniaudio.h (vendored single-header dep)"

echo "== [1/4] dependencies =="
need_pkg gtk+-3.0              libgtk-3-dev                        gtk3-devel
# WebKit2GTK: 4.1 is current (Ubuntu 24.04+/Fedora 41+); 4.0 still ships on
# older releases (Debian 11, Ubuntu 22.04) and speaks the same API we use.
if   pkg-config --exists webkit2gtk-4.1 2>/dev/null; then WK=webkit2gtk-4.1
elif pkg-config --exists webkit2gtk-4.0 2>/dev/null; then WK=webkit2gtk-4.0
else need_pkg webkit2gtk-4.1 libwebkit2gtk-4.1-dev webkit2gtk4.1-devel >/dev/null
  printf '%s\n' "     (Debian 11 / Ubuntu 22.04 instead: apt install libwebkit2gtk-4.0-dev)" >&2
  die "no webkit2gtk-4.x — see the package names above"
fi
# Hard requirement, not optional (see header note on bug #23).
if   pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null; then IND=ayatana-appindicator3-0.1
elif pkg-config --exists libayatana-appindicator3.0 2>/dev/null; then IND=libayatana-appindicator3.0
else need_pkg ayatana-appindicator3-0.1 libayatana-appindicator3-1-dev libayatana-appindicator-devel >/dev/null
  printf '%s\n' "     (Fedora/Arch name: libayatana-appindicator3.0 / libappindicator-devel-ish)" >&2
  die "no ayatana appindicator — pristine launcher-linux.cc does NOT compile without it (#23)"
fi
# TINYJS_X11 gates the vendor's whole X11 integration block — parse_combo,
# do_keystroke (XTest), x11_hotkey_register/unregister (XGrabKey on the root
# window) — and every one of them has a no-op stub behind #else. Linking -lX11
# -lXtst WITHOUT the flag therefore produced a binary that answered
# hotkey.register with "ok" and grabbed nothing at all; test/posix/
# desktop-session.sh only got a real session to press keys in, and B3 failed
# until the flag was added. Keep it on: it is the difference between a global
# hotkey and a lie.
for lib in libX11 libXtst; do
  ldconfig -p 2>/dev/null | grep -q "$lib" && continue
  command -v gcc >/dev/null 2>&1 && gcc -print-file-name="$lib.so" 2>/dev/null | grep -q '^/' && continue
  [ -e "/usr/lib/$lib.so" ] || [ -e "/usr/lib/x86_64-linux-gnu/$lib.so" ] \
    || die "missing $lib (Debian: apt install libx11-dev libxtst-dev)"
done
printf '   cxx=%s (%s)  gtk=gtk+-3.0  webkit=%s  appindicator=%s\n' \
  "$CXX" "$("$CXX" -dumpversion 2>/dev/null || echo '?')" "$WK" "$IND"

echo "== [2/4] tiny_client.h (embed gui/runtime/tiny.js) =="
if command -v python3 >/dev/null 2>&1; then
  sh "$ROOT/gui/host/script/gen-client.sh" || die "gen-client.sh failed"
else
  # Same output as gen-client.sh, without the python3 dependency.
  command -v php >/dev/null 2>&1 || die "need python3 or php to generate tiny_client.h"
  php -r '
    $js = file_get_contents($argv[1]);
    if (strpos($js, ")TINYJS") !== false) { fwrite(STDERR, "raw-string delimiter collision\n"); exit(1); }
    file_put_contents($argv[2],
      "// GENERATED from gui/runtime/tiny.js by tools/build-linux.sh — do not edit.\n" .
      "static const char TINY_CLIENT_JS[] = R\"TINYJS(" . $js . ")TINYJS\";\n");
  ' "$ROOT/gui/runtime/tiny.js" "$ROOT/gui/host/src/tiny_client.h" \
    || die "tiny_client.h generation failed"
fi
[ -s "$ROOT/gui/host/src/tiny_client.h" ] || die "tiny_client.h not generated"

echo "== [3/4] shim (POSIX branch) -> build/backend_shell =="
mkdir -p "$BUILD"
"$CXX" -std=c++17 -Wall -Wextra -O2 -o "$BUILD/backend_shell" "$ROOT/shim/backend_shell.cpp" -lpthread \
  || die "shim compile failed"

echo "== [4/4] launcher-linux (GTK3 + $WK) -> build/launcher-linux =="
"$CXX" -std=c++17 -O2 -I "$ROOT/gui/host/include" -I "$ROOT/gui/host/src" \
  -DTINYJS_APPINDICATOR -DTINYJS_X11 \
  -o "$BUILD/launcher-linux" "$ROOT/gui/host/src/launcher-linux.cc" \
  $(pkg-config --cflags gtk+-3.0 "$WK" "$IND") $(pkg-config --libs gtk+-3.0 "$WK" "$IND") \
  -lX11 -lXtst -lpthread || die "launcher-linux compile failed"

echo
ls -l "$BUILD/backend_shell" "$BUILD/launcher-linux"
file "$BUILD/backend_shell" "$BUILD/launcher-linux" 2>/dev/null || true
printf '   launcher-linux links %d shared libs\n' \
  "$(ldd "$BUILD/launcher-linux" 2>/dev/null | grep -c '=>')"
echo
echo "done.  next:  gui/bin/tgui dev   (or)   gui/bin/tgui build"
