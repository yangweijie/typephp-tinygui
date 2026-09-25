#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build native/launcher-win.exe for the TypePHP bridge, without touching the
# tinyjsapp checkout's sources.
#
#   usage:  bash tools/build-launcher.sh [--install] [tinyjsapp-dir]
#           TINYJSAPP=/path/to/tinyjsapp-0.42.0 bash tools/build-launcher.sh
#
#   --install   also copy the runtime trio into <tinyjsapp>/native/ so a bare
#               `tinyjs dev --typephp` works with no environment variables.
#               Without it, everything lands in <repo>/build/runtime/ and you
#               point at it with TINYJS_LAUNCHER (see the echo at the end).
#
# What it produces (all under <repo>/build/):
#   gen/launcher-win.cc     pristine base + patches/launcher-win-typephp.patch
#   launcher-win.exe        the patched launcher
#   runtime/                launcher + backend.exe (shim) + app.exe (PHP)
#   winrt-shim/ include/    downloaded build deps, cached between runs
#
# Why the checkout stays clean: launcher-win.cc is derived from
# patches/base/launcher-win.cc.orig rather than edited in place, and the headers
# we fetch are cached under build/. Upstream's own setup.ps1 writes into
# native/; we deliberately do not, so `tools/bootstrap-tinyjsapp.sh status` can
# still tell you exactly what state the checkout is in.
#
# The launcher needs three app-level WinRT headers that MinGW-Builds does NOT
# ship, and MinGW-Builds' *base* WinRT headers are near-empty stubs. We overlay a
# complete headline set from mingw-w64 and put it FIRST on the include path with
# -I (using -idirafter instead lets the local stubs win and yields ~41 cryptic
# "'ABI::Windows::...' has not been declared" errors).
# ---------------------------------------------------------------------------
set -uo pipefail

INSTALL=0
args=()
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    *) args+=("$a") ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TJS="${args[0]:-${TINYJSAPP:-D:/git/web/tinyjsapp-0.42.0}}"
BUILD="$ROOT/build"
GEN="$BUILD/gen"
SHIMHDR="$BUILD/winrt-shim"
INCHDR="$BUILD/include"
WEBVIEW2_VERSION="1.0.2903.40"

die() { printf '\n!! %s\n' "$*"; exit 1; }

# Complete mingw-w64 headline set the launcher (transitively) needs.
SHIM_HEADERS=(
  hstring.h inspectable.h restrictederrorinfo.h
  windows.applicationmodel.h windows.applicationmodel.activation.h
  windows.applicationmodel.background.h windows.applicationmodel.core.h
  windows.data.xml.dom.h
  windows.devices.geolocation.h windows.devices.input.h
  windows.foundation.h windows.foundation.collections.h windows.foundation.metadata.h
  windows.security.credentials.ui.h
  windows.storage.h windows.storage.fileproperties.h windows.storage.search.h
  windows.storage.streams.h
  windows.system.h
  windows.ui.h windows.ui.core.h windows.ui.input.h windows.ui.notifications.h
)

[ -d "$TJS" ]                              || die "not a tinyjsapp checkout: $TJS"
[ -f "$TJS/cli.js" ]                       || die "no cli.js in $TJS"
[ -f "$TJS/runtime/tiny.js" ]              || die "no runtime/tiny.js in $TJS"
[ -f "$TJS/native/include/webview/webview.h" ] \
  || die "no native/include/webview/webview.h in $TJS — incomplete checkout"
[ -f "$ROOT/patches/base/launcher-win.cc.orig" ] \
  || die "missing patches/base/launcher-win.cc.orig"
[ -f "$ROOT/patches/launcher-win-typephp.patch" ] \
  || die "missing patches/launcher-win-typephp.patch"

mkdir -p "$BUILD" "$GEN" "$SHIMHDR" "$INCHDR"
cd "$TJS" || die "cannot cd $TJS"

fetch_url() { # fetch_url <relative-path> <out-file>
  local rel="$1" out="$2" u
  for u in \
    "https://xget.xi-xu.me/gh/mingw-w64/mingw-w64/raw/master/mingw-w64-headers/include/$rel" \
    "https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/$rel" \
    "https://cdn.jsdelivr.net/gh/mingw-w64/mingw-w64@master/mingw-w64-headers/include/$rel" ; do
    if curl -fsSL --max-time 45 "$u" -o "$out" 2>/dev/null && [ -s "$out" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "== [1/6] winrt-shim headers ($SHIMHDR)"
for h in "${SHIM_HEADERS[@]}"; do
  if [ -s "$SHIMHDR/$h" ]; then continue; fi
  if fetch_url "$h" "$SHIMHDR/$h"; then echo "   + $h"; else die "could not fetch $h"; fi
done

echo "== [2/6] WebView2.h -> $INCHDR/WebView2.h"
if [ ! -s "$INCHDR/WebView2.h" ]; then
  tmp="$(mktemp -d)"
  if curl -fsSL --max-time 120 \
       "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$WEBVIEW2_VERSION" \
       -o "$tmp/wv2.zip"; then
    python - "$tmp/wv2.zip" "$INCHDR/WebView2.h" <<'PY'
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1])
name = next(n for n in zf.namelist() if n.endswith('build/native/include/WebView2.h'))
open(sys.argv[2], 'wb').write(zf.read(name))
print('   + WebView2.h')
PY
    [ -s "$INCHDR/WebView2.h" ] || die "extracted WebView2.h is empty"
  else
    die "could not download WebView2.h"
  fi
  rm -rf "$tmp"
else
  echo "   = WebView2.h present"
fi

echo "== [3/6] tiny_client.h -> $GEN/tiny_client.h  (from runtime/tiny.js)"
if [ ! -s "$TJS/runtime/tiny.js" ]; then die "missing $TJS/runtime/tiny.js"; fi
python - "$TJS/runtime/tiny.js" "$GEN/tiny_client.h" <<'PY'
import sys
js = open(sys.argv[1], encoding='utf-8').read()
assert ')TINYJS' not in js, 'raw-string delimiter collision in tiny.js'
open(sys.argv[2], 'w', encoding='utf-8').write(
    '// GENERATED from runtime/tiny.js - do not edit.\n'
    'static const char TINY_CLIENT_JS[] = R"TINYJS(' + js + ')TINYJS";\n')
print('   + tiny_client.h')
PY

echo "== [4/6] derive launcher-win.cc  (base + patch, checkout untouched)"
cp -f "$ROOT/patches/base/launcher-win.cc.orig" "$GEN/launcher-win.cc" || die "cannot stage source"
( cd "$GEN" && patch -p0 --quiet launcher-win.cc < "$ROOT/patches/launcher-win-typephp.patch" ) \
  || die "launcher-win-typephp.patch did not apply to the saved base"
echo "   + $GEN/launcher-win.cc"

echo "== [5/6] compiling launcher-win.exe"
g++ -std=c++17 -O2 -static \
    -I"$SHIMHDR" -I"$INCHDR" -I"$TJS/native/include" -I"$GEN" \
    -o "$BUILD/launcher-win.exe" "$GEN/launcher-win.cc" -mwindows \
    -lole32 -loleaut32 -lshell32 -lshlwapi -luser32 -ladvapi32 -lversion \
    -lgdi32 -lgdiplus -lcomdlg32 -lwinmm -ldwmapi -luuid -lcrypt32 \
  || die "launcher compile failed"
ls -la "$BUILD/launcher-win.exe"

echo "== [6/6] assembling runtime/"
RT="$BUILD/runtime"
mkdir -p "$RT"
cp -f "$BUILD/launcher-win.exe" "$RT/launcher-win.exe"
have_shim=0; have_app=0
[ -f "$BUILD/backend_shell.exe" ] && { cp -f "$BUILD/backend_shell.exe" "$RT/backend.exe"; have_shim=1; }
[ -f "$BUILD/app.exe" ]           && { cp -f "$BUILD/app.exe"           "$RT/app.exe";     have_app=1; }
[ "$have_shim" -eq 1 ] && echo "   = backend.exe (shim)"  || echo "   ! shim missing — run tools/build-all.bat first"
[ "$have_app"  -eq 1 ] && echo "   = app.exe (PHP AOT)"  || echo "   ! app.exe missing — run tools/build-all.bat first"

if [ "$INSTALL" -eq 1 ]; then
  echo "== --install: deploying into $TJS/native/"
  cp -f "$BUILD/launcher-win.exe" "$TJS/native/launcher-win.exe"
  [ "$have_shim" -eq 1 ] && cp -f "$BUILD/backend_shell.exe" "$TJS/native/backend.exe"
  [ "$have_app"  -eq 1 ] && cp -f "$BUILD/app.exe"           "$TJS/native/app.exe"
  echo "   = installed (bare \`tinyjs dev --typephp\` now works)"
fi

echo
echo "== done.  run the demo:"
echo "   cd \"$ROOT/demo\" && \"$TJS/bin/tjs.exe\" run \"$TJS/cli.js\" dev --typephp"
if [ "$INSTALL" -eq 0 ]; then
  echo
  echo "   or, without installing into the checkout:"
  echo "   TINYJS_LAUNCHER=\"$RT/launcher-win.exe\" \"$TJS/bin/tjs.exe\" run \"$TJS/cli.js\" dev --typephp"
fi
