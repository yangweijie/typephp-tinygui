#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build + run the TypePHP GUI on macOS (packaged direction).
#
#   usage:  bash tools/build-macos.sh [--run]
#           --run   after building, stage the demo app folder and launch it
#
# Produces (under build/):
#   backend_shell            the shim (POSIX branch, AF_UNIX)
#   launcher-macos           the native WKWebView host (pristine vendor source)
#   include/webview/         vendored webview headers, downloaded once
#   gen/                     tiny_client.h (embedded gui/runtime/tiny.js)
#   mac-app/                 staged packaged-mode app (with --run)
#                            Demo(=shim) + Demo.conf + launcher-macos + frontend/
#
# Dev direction (`tgui dev`, `--typephp`) is still Windows-only; on macOS the
# entry IS the shim and it spawns the STOCK launcher `<html> <socket> …` —
# the same contract launcher-win/launcher-linux use upstream.
#
# The backend is the system-PHP shebang script bin/run-backend.php (tpc AOT is
# a Windows-only toolchain); the POSIX shim `execv`s it with no argv, which is
# exactly why that file carries `#!/usr/bin/env php`.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
GEN="$BUILD/gen"
INCHDR="$BUILD/include"
WEBVIEW="$INCHDR/webview"
TINYJSAPP_TAG="main"   # upstream ref the vendored headers came from

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

RUN=0
for a in "$@"; do case "$a" in --run) RUN=1 ;; esac; done

[ -f "$ROOT/gui/host/src/launcher-macos.cc" ] || die "missing gui/host/src/launcher-macos.cc"
[ -f "$ROOT/gui/runtime/tiny.js" ]            || die "missing gui/runtime/tiny.js"
command -v clang++ >/dev/null 2>&1            || die "clang++ not found (xcode-select --install)"

echo "== [1/5] tiny_client.h (embed gui/runtime/tiny.js) =="
sh "$ROOT/gui/host/script/gen-client.sh" || die "gen-client.sh failed"
[ -s "$ROOT/gui/host/src/tiny_client.h" ] || die "tiny_client.h not generated"
mkdir -p "$GEN" && cp -f "$ROOT/gui/host/src/tiny_client.h" "$GEN/tiny_client.h"

echo "== [2/5] vendored webview headers ($WEBVIEW) =="
# launcher-macos.cc includes "webview.h" (deprecated forwarder) -> webview/webview.h,
# the new-style header-only webview lib (api.h + c_api_impl.hh + detail/**).
# Same copy upstream ships under native/include/webview/ in tinyjsapp.
if [ ! -s "$WEBVIEW/c_api_impl.hh" ]; then
  tmp="$(mktemp -d)"
  for base in \
    "https://xget.fnthink.top/gh/tarwin/tinyjsapp/archive/refs/heads/$TINYJSAPP_TAG.tar.gz" \
    "https://codeload.github.com/tarwin/tinyjsapp/tar.gz/refs/heads/$TINYJSAPP_TAG" ; do
    echo "   fetching $base"
    curl -fsSL --max-time 180 "$base" -o "$tmp/tjs.tgz" && [ -s "$tmp/tjs.tgz" ] && break
  done
  [ -s "$tmp/tjs.tgz" ] || die "could not download tinyjsapp archive (webview headers)"
  ( cd "$tmp" && tar -xzf tjs.tgz "tinyjsapp-$TINYJSAPP_TAG/native/include/webview" ) \
    || die "tinyjsapp archive lacks native/include/webview"
  mkdir -p "$INCHDR" && rm -rf "$WEBVIEW" \
    && cp -R "$tmp/tinyjsapp-$TINYJSAPP_TAG/native/include/webview" "$WEBVIEW"
  rm -rf "$tmp"
  echo "   + $(find "$WEBVIEW" -type f | wc -l | tr -d ' ') files"
else
  echo "   = present (cache)"
fi

echo "== [3/5] shim (POSIX branch) -> build/backend_shell =="
clang++ -std=c++17 -Wall -Wextra -O2 -o "$BUILD/backend_shell" "$ROOT/shim/backend_shell.cpp" \
  || die "shim compile failed"

echo "== [4/5] launcher-macos -> build/launcher-macos =="
# Objective-C++ with MANUAL reference counting: the source uses @interface
# blocks plus release/autorelease and raw void*<->id casts, so -x objective-c++
# is required (a .cc is plain C++ otherwise) and -fobjc-arc is forbidden.
clang++ -x objective-c++ -std=c++17 -mmacos-version-min=12.0 \
  -I "$INCHDR" -I "$ROOT/gui/host/include" -I "$ROOT/gui/host/src" -O2 \
  -o "$BUILD/launcher-macos" "$ROOT/gui/host/src/launcher-macos.cc" \
  -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers \
  -framework AVFoundation -framework CoreMedia -framework CoreImage \
  -framework CoreAudio -framework AudioToolbox -framework IOKit \
  -framework ScreenCaptureKit -framework Speech -framework ServiceManagement \
  -framework Carbon -framework Metal -framework QuartzCore \
  -framework Vision -framework MediaPlayer -framework LocalAuthentication \
  -framework CoreWLAN -framework UserNotifications -framework Quartz \
  -framework QuickLookThumbnailing -framework Security \
  || die "launcher-macos compile failed"

if [ "$RUN" -eq 0 ]; then
  ls -la "$BUILD/backend_shell" "$BUILD/launcher-macos"
  echo "done. run:  bash tools/build-macos.sh --run"
  exit 0
fi

echo "== [5/5] stage packaged-mode app + launch =="
APP="$BUILD/mac-app"
rm -rf "$APP" && mkdir -p "$APP/frontend"
cp -R "$ROOT/demo/src/frontend/." "$APP/frontend/"
cp -f "$BUILD/backend_shell"  "$APP/Demo"
cp -f "$BUILD/launcher-macos" "$APP/launcher-macos"
chmod +x "$APP/Demo" "$APP/launcher-macos" "$ROOT/bin/run-backend.php"
cat > "$APP/Demo.conf" <<EOF
html=frontend/index.html
title=TypePHP Demo (macOS)
size=1100x760
version=0.1.0
app=$ROOT/bin/run-backend.php
launcher=$APP/launcher-macos
EOF
# argv-less: argc==1 -> the shim becomes the entry, serves the AF_UNIX endpoint,
# spawns the stock launcher + the PHP backend. Close the window to quit.
( cd "$APP" && TYPEPHP_SHELL_LOG="$APP/shim.log" TYPEPHP_APP_ROOT="$ROOT" ./Demo )
echo "app folder: $APP   log: $APP/shim.log"
