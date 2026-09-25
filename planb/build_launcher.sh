#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build native/launcher-win.exe for the TypePHP (aot-compiler) bridge, plus the
# two runtime sidecars the launcher needs next to it (backend.exe = shim,
# app.exe = PHP backend). One command, idempotent, offline-friendly once the
# headers are cached.
#
#   usage:  bash planb/build_launcher.sh [tinyjsapp-dir]
#   default tinyjsapp-dir = D:/git/web/tinyjsapp-0.42.0
#
# Why a script: the launcher needs three app-level WinRT headers that
# MinGW-Builds does NOT ship, and MinGW-Builds' *base* WinRT headers are
# near-empty stubs. We overlay a complete headline set from mingw-w64 into
# native/winrt-shim/ and put it FIRST on the include path with -I (using
# -idirafter instead lets the local stubs win and yields ~41 cryptic
# "'ABI::Windows::...' has not been declared" errors).
# ---------------------------------------------------------------------------
set -uo pipefail

TJS="${1:-D:/git/web/tinyjsapp-0.42.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="$TJS/native"
SHIM="$NATIVE/winrt-shim"
WEBVIEW2_VERSION="1.0.2903.40"

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

[[ -d "$NATIVE" ]] || { echo "!! not a tinyjsapp checkout: $NATIVE"; exit 1; }
mkdir -p "$SHIM"

fetch_url() { # fetch_url <relative-path> <out-file>
  local rel="$1" out="$2" u
  for u in \
    "https://xget.xi-xu.me/gh/mingw-w64/mingw-w64/raw/master/mingw-w64-headers/include/$rel" \
    "https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/$rel" \
    "https://cdn.jsdelivr.net/gh/mingw-w64/mingw-w64@master/mingw-w64-headers/include/$rel" ; do
    if curl -fsSL --max-time 45 "$u" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "== [1/4] winrt-shim headers ($SHIM)"
for h in "${SHIM_HEADERS[@]}"; do
  if [[ -s "$SHIM/$h" ]]; then continue; fi
  if fetch_url "$h" "$SHIM/$h"; then echo "   + $h"; else echo "   ! FAILED $h"; exit 1; fi
done

echo "== [2/4] WebView2.h + tiny_client.h"
if [[ ! -s "$NATIVE/include/WebView2.h" ]]; then
  tmp="$(mktemp -d)"
  if curl -fsSL --max-time 120 \
       "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$WEBVIEW2_VERSION" \
       -o "$tmp/wv2.zip"; then
    python - "$tmp/wv2.zip" "$NATIVE/include/WebView2.h" <<'PY'
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1])
name = next(n for n in zf.namelist() if n.endswith('build/native/include/WebView2.h'))
open(sys.argv[2], 'wb').write(zf.read(name))
print('   + WebView2.h')
PY
  else
    echo "   ! could not download WebView2.h"; exit 1
  fi
  rm -rf "$tmp"
else
  echo "   = WebView2.h present"
fi

if [[ ! -s "$NATIVE/tiny_client.h" ]]; then
  python - "$TJS/runtime/tiny.js" "$NATIVE/tiny_client.h" <<'PY'
import sys
js = open(sys.argv[1], encoding='utf-8').read()
assert ')TINYJS' not in js, 'raw-string delimiter collision in tiny.js'
open(sys.argv[2], 'w', encoding='utf-8').write(
    '// GENERATED from runtime/tiny.js - do not edit.\n'
    'static const char TINY_CLIENT_JS[] = R"TINYJS(' + js + ')TINYJS";\n')
print('   + tiny_client.h')
PY
else
  echo "   = tiny_client.h present"
fi

echo "== [3/4] compiling launcher-win.exe"
cd "$TJS"
g++ -std=c++17 -O2 -static -Inative/winrt-shim -Inative/include -Inative \
    -o native/launcher-win.exe native/launcher-win.cc -mwindows \
    -lole32 -loleaut32 -lshell32 -lshlwapi -luser32 -ladvapi32 -lversion \
    -lgdi32 -lgdiplus -lcomdlg32 -lwinmm -ldwmapi -luuid -lcrypt32 || {
  echo "!! launcher compile failed"; exit 1; }
ls -la native/launcher-win.exe

echo "== [4/4] deploying sidecars next to the launcher"
if [[ -x "$HERE/backend_shell.exe" && -x "$HERE/app.exe" ]]; then
  cp -f "$HERE/backend_shell.exe" "$NATIVE/backend.exe"
  cp -f "$HERE/app.exe"         "$NATIVE/app.exe"
  echo "   = backend.exe (shim) + app.exe (PHP AOT) deployed"
else
  echo "   ! run planb/build_all.bat first (needs backend_shell.exe + app.exe)"
fi

echo
echo "== done.  run:"
echo "   cd \"$NATIVE\" && ./launcher-win.exe --typephp \"$HERE/www/index.html\" \"My App\" 960x640"
