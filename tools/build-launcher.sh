#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build gui/host/src/launcher-win.exe for the TypePHP GUI framework.
#
#   usage:  bash tools/build-launcher.sh [--install]
#           --install   also copy the runtime trio into build/runtime/
#
# The host source is OWNED by this repo (gui/host/src/launcher-win.cc, with the
# --typephp feature already merged in-tree) — there is no external tinyjsapp
# checkout and no patch step. See gui/README.md.
#
# Produces (under build/):
#   gen/launcher-win.cc     copied from gui/host/src/ (already carries --typephp)
#   launcher-win.exe        the native GUI host
#   runtime/                launcher-win.exe + backend_shell.exe (shim) + app.exe
#   winrt-shim/ include/    downloaded build deps, cached between runs
#
# The host needs three app-level WinRT headers MinGW-Builds does not ship; we
# overlay a complete set from mingw-w64 and put it FIRST on the include path.
# ---------------------------------------------------------------------------
set -uo pipefail

INSTALL=0
for a in "$@"; do case "$a" in --install) INSTALL=1 ;; esac; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/gui/host"
BUILD="$ROOT/build"
GEN="$BUILD/gen"
SHIMHDR="$BUILD/winrt-shim"
INCHDR="$BUILD/include"
WEBVIEW2_VERSION="1.0.2903.40"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

[ -f "$HOST/src/launcher-win.cc" ]            || die "missing $HOST/src/launcher-win.cc (vendored host)"
[ -f "$HOST/include/webview.h" ]              || die "missing $HOST/include/webview.h"
[ -f "$HOST/runtime/tiny.js" ]                || die "missing $HOST/runtime/tiny.js"

mkdir -p "$BUILD" "$GEN" "$SHIMHDR" "$INCHDR"
cd "$ROOT" || die "cannot cd $ROOT"

fetch_url() { # fetch_url <relative-path> <out-file>
  local rel="$1" out="$2" u
  for u in \
    "https://xget.fnthink.top/gh/mingw-w64/mingw-w64/raw/master/mingw-w64-headers/include/$rel" \
    "https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/$rel" \
    "https://cdn.jsdelivr.net/gh/mingw-w64/mingw-w64@master/mingw-w64-headers/include/$rel" ; do
    if curl -fsSL --max-time 45 "$u" -o "$out" 2>/dev/null && [ -s "$out" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "== [1/5] winrt-shim headers ($SHIMHDR)"
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
for h in "${SHIM_HEADERS[@]}"; do
  [ -s "$SHIMHDR/$h" ] && continue
  fetch_url "$h" "$SHIMHDR/$h" && echo "   + $h" || die "could not fetch $h"
done

echo "== [2/5] WebView2.h -> $INCHDR/WebView2.h"
if [ ! -s "$INCHDR/WebView2.h" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 120 \
    "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$WEBVIEW2_VERSION" \
    -o "$tmp/wv2.zip" || die "could not download WebView2.h"
  python - "$tmp/wv2.zip" "$INCHDR/WebView2.h" <<'PY'
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1])
name = next(n for n in zf.namelist() if n.endswith('build/native/include/WebView2.h'))
open(sys.argv[2], 'wb').write(zf.read(name))
PY
  [ -s "$INCHDR/WebView2.h" ] || die "extracted WebView2.h is empty"
  rm -rf "$tmp"
else
  echo "   = WebView2.h present"
fi

echo "== [3/5] tiny_client.h -> $GEN/tiny_client.h  (from gui/runtime/tiny.js)"
python - "$HOST/runtime/tiny.js" "$GEN/tiny_client.h" <<'PY'
import sys
js = open(sys.argv[1], encoding='utf-8').read()
assert ')TINYJS' not in js, 'raw-string delimiter collision in tiny.js'
open(sys.argv[2], 'w', encoding='utf-8').write(
    '// GENERATED from gui/runtime/tiny.js - do not edit.\n'
    'static const char TINY_CLIENT_JS[] = R"TINYJS(' + js + ')TINYJS";\n')
PY
echo "   + tiny_client.h"

echo "== [4/5] stage launcher source (vendored, already carries --typephp)"
cp -f "$HOST/src/launcher-win.cc" "$GEN/launcher-win.cc" || die "cannot stage source"
echo "   + $GEN/launcher-win.cc"

echo "== [5/5] compiling launcher-win.exe"
g++ -std=c++17 -O2 -static \
    -I"$SHIMHDR" -I"$INCHDR" -I"$HOST/include" -I"$GEN" \
    -o "$BUILD/launcher-win.exe" "$GEN/launcher-win.cc" -mwindows \
    -lole32 -loleaut32 -lshell32 -lshlwapi -luser32 -ladvapi32 -lversion \
    -lgdi32 -lgdiplus -lcomdlg32 -lwinmm -ldwmapi -luuid -lcrypt32 \
  || die "launcher compile failed"
ls -la "$BUILD/launcher-win.exe"

RT="$BUILD/runtime"
mkdir -p "$RT"
cp -f "$BUILD/launcher-win.exe" "$RT/launcher-win.exe"
have_shim=0; have_app=0
[ -f "$BUILD/backend_shell.exe" ] && { cp -f "$BUILD/backend_shell.exe" "$RT/backend.exe"; have_shim=1; }
[ -f "$BUILD/app.exe" ]           && { cp -f "$BUILD/app.exe"           "$RT/app.exe";     have_app=1; }
[ "$have_shim" -eq 1 ] && echo "   = backend.exe (shim)"  || echo "   ! shim missing — run tools/build-all.bat first"
[ "$have_app"  -eq 1 ] && echo "   = app.exe (PHP AOT)"  || echo "   ! app.exe missing — run tools/build-all.bat first"

if [ "$INSTALL" -eq 1 ]; then
  echo "== --install: runtime trio ready in $RT/"
fi

echo
echo "== done. run the demo:"
echo "   cd \"$ROOT/demo\" && bash \"$ROOT/gui/bin/tgui\" dev"
