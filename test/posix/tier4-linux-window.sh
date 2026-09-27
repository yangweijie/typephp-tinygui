#!/usr/bin/env bash
# Phase 21d tier-4 driver — run INSIDE the Linux container/dev machine.
#
# Proves the packaged (stock) direction end-to-end with the REAL upstream
# `launcher-linux` (GTK3 + WebKit2GTK 4.1) against our shim and the stock PHP
# backend — the one combination Cygwin/macOS could never cover:
#   true glibc + AF_UNIX + GTK/WebKit window + real frames.
#
# Layout expectation: run from the repo root (or anywhere; paths are resolved
# from $0). Requirements: g++, php, pkg-config, libgtk-3-dev,
# libwebkit2gtk-4.1-dev, libayatana-appindicator3-dev (optional — auto
# disabled), xvfb, and either xwd/imagemagick for the screenshot.
#
# Evidence produced:
#   $WORK/launcher-linux   built binary
#   $WORK/shim.log         full CALL/RET frame log from the shim
#   $WORK/shot.png         screenshot of the live window under Xvfb (best effort)
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # script lives in test/posix/ -> repo root
WORK="${WORK:-/tmp/tpgui-tier4}"; mkdir -p "$WORK"
SHIM_SRC="$ROOT/shim/backend_shell.cpp"
LINUX_SRC="$ROOT/gui/host/src/launcher-linux.cc"
INC="$ROOT/gui/host/include"
BACKEND="$ROOT/bin/run-backend.php"
FRONT="$ROOT/demo/src/frontend/index.html"
SLOG="$WORK/shim.log"
LOUT="$WORK/launcher.out"
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
SCREENSHOT="${SCREENSHOT:-1}"

fail=0
note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }

command -v g++ >/dev/null || { echo "g++ missing"; exit 2; }
command -v php >/dev/null || { echo "php missing"; exit 2; }
php -r 'exit(PHP_VERSION_ID >= 80000 ? 0 : 1);' || { echo "php >= 8.1 required"; exit 2; }

note "[1/5] build shim"
g++ -std=c++17 -O2 -o "$WORK/backend_shell" "$SHIM_SRC" -lpthread \
  && ok "shim built" || { bad "shim build failed"; exit 2; }

note "[2/5] build launcher-linux (GTK3 + webkit2gtk-4.1)"
PKGS="gtk+-3.0 webkit2gtk-4.1"
EXTRA_FLAGS=""
# pkg-config name differs by distro: Fedora/Arch use libayatana-appindicator3.0,
# Debian/Ubuntu ship ayatana-appindicator3-0.1. Probe both.
IND=$(pkg-config --exists libayatana-appindicator3.0 && echo libayatana-appindicator3.0 \
       || (pkg-config --exists ayatana-appindicator3-0.1 && echo ayatana-appindicator3-0.1) || true)
[ -n "$IND" ] && { PKGS="$PKGS $IND"; EXTRA_FLAGS="-DTINYJS_APPINDICATOR"; }
# TINYJS_PIPEWIRE stays undefined: the container has no pipewire; the
# #ifndef fallback path is exactly what we want compiled.
g++ -std=c++17 -O2 -I"$INC" -o "$WORK/launcher-linux" "$LINUX_SRC" \
    $(pkg-config --cflags $PKGS) $EXTRA_FLAGS $(pkg-config --libs $PKGS) \
    -lX11 -lXtst \
  && ok "launcher-linux built" || { bad "launcher-linux build failed"; exit 2; }

note "[3/5] start Xvfb $DISPLAY_NUM"
Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY="$DISPLAY_NUM"
sleep 1
kill -0 $XVFB_PID && ok "Xvfb up (pid $XVFB_PID)" || { bad "Xvfb died"; exit 2; }

note "[4/5] launch the chain (shim launch mode via direct spawn args)"
# Drive it the dev direction: launcher <html> <socket>, shim connects out? No —
# the ONLY direction launcher-linux speaks is client-to-server: it takes
# `<html> <socket>` and CONNECTS to a server the shim owns. So start the shim
# in dev-mode server position: spawn shim with an explicit endpoint arg, then
# spawn launcher pointing at it (mirrors how tinyjs's own CLI does it).
SOCK="$WORK/app.sock"
[ -S "$SOCK" ] && rm -f "$SOCK"
TYPEPHP_SHELL_LOG="$SLOG" TYPEPHP_APP="$BACKEND" TYPEPHP_CWD="$ROOT/demo" \
  "$WORK/backend_shell" "$SOCK" &
SHIM_PID=$!
sleep 1
kill -0 $SHIM_PID && ok "shim up (pid $SHIM_PID, log $SLOG)" || { bad "shim died"; cat "$SLOG"; exit 1; }

"$WORK/launcher-linux" "$FRONT" "$SOCK" "TypePHP Linux" 960x640 0.1.0 \
  >"$LOUT" 2>&1 &
L_PID=$!
sleep 6
kill -0 $L_PID && ok "launcher up (pid $L_PID)" || { bad "launcher died"; tail -5 "$LOUT"; }

note "[5/5] evidence"
CALLS=$(grep -c 'L->P: CALL' "$SLOG" 2>/dev/null || echo 0)
RETS=$(grep -c 'P->L: RET' "$SLOG" 2>/dev/null || echo 0)
E2E=$(grep -m1 -o 'WINDOW-E2E OK ping=pong in [0-9]*ms' "$SLOG" || true)
note "frames: CALL=$CALLS RET=$RETS ${E2E:+| $E2E}"
[ "$CALLS" -ge 13 ] && [ "$RETS" -ge 13 ] && ok ">=13/13 CALL/RET" || bad "frame round-trip incomplete"
[ -n "$E2E" ] && ok "window e2e marker present" || bad "no WINDOW-E2E marker"

if [ "$SCREENSHOT" = 1 ]; then
  if command -v import >/dev/null; then import -window root "$WORK/shot.png" && ok "shot.png (ImageMagick)"
  elif command -v xwd >/dev/null && command -v convert >/dev/null; then
    xwd -root -silent | convert xwd:- "$WORK/shot.png" && ok "shot.png (xwd)"
  else note "no screenshot tool (xvfbgrab/xwd/imagemagick) — skipping"; fi
fi

# teardown
[ -n "${L_PID:-}" ] && kill $L_PID 2>/dev/null
sleep 1
kill -0 $SHIM_PID 2>/dev/null && { bad "shim survived launcher exit"; } || ok "shim exited with launcher"
pkill -P $$ Xvfb 2>/dev/null; kill $XVFB_PID 2>/dev/null
[ -e "$SOCK" ] && { rm -f "$SOCK"; note "socket file removed"; }

echo; echo "== tier-4 result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
