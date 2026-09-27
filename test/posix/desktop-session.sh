#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 23 — Linux REAL DESKTOP SESSION acceptance. Run INSIDE the container.
#
# tier-4/22b/22d proved transport + render + lifecycle under BARE Xvfb. Xvfb has
# no window manager, no compositor, no session bus and no tray host, so every
# behaviour that only exists when a *desktop* is present was, by admission,
# unproven. This driver stands one up and asserts on it:
#
#   [A] real session, real app (shim + PHP backend + demo page)
#       A1 the window is WM-managed: reparented, _NET_FRAME_EXTENTS, _NET_WM_NAME
#       A2 a compositor owns _NET_WM_CM_S0 while the window is mapped
#       A3 WM-driven state rides back as WINSTATE frames (minimize, maximize)
#       A4 the frame round trip still completes inside a session (regression)
#       A5 HiDPI: GDK_SCALE=2 doubles the X window's PIXEL geometry
#   [B] launcher desktop integrations, driven by mock_shim.py because our PHP
#       backend exposes menu.set but NOT tray.set / hotkey.register (a real gap,
#       recorded in test/posix/README.md — the harness injects the frames an API
#       that had it would send)
#       B1 the tray registers with an SNI watcher; props + dbusmenu layout read
#       B2 tray menu clicks come back as TRAY <id> / TRAYCLICK pipe frames
#       B3 HKREG + a synthetic keypress -> HOTKEY <id> (root-window XGrabKey)
#       B4 negative control: an unregistered combo yields no HOTKEY
#   [C] the pipe->page leg the mock cannot reach: Protocol::decode maps
#       TRAY/TRAYCLICK onto page events — and HOTKEY onto nothing, which is
#       reported as a gap rather than silently passing.
#
# Requirements: tools/build-linux.sh's deps plus openbox, picom, xdotool,
# wmctrl, x11-utils (xprop/xwininfo), imagemagick (import), python3-dbus,
# python3-gi, dbus-x11.
#
# Evidence (all under $WORK): shim.log shim-hidpi.log mock.log sni*.json
# tray-icon*.png shot-*.png session-report.txt
# ---------------------------------------------------------------------------
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/tpgui-desktop}"; mkdir -p "$WORK"
DISPLAY_NUM="${DISPLAY_NUM:-:97}"
SCREEN="${SCREEN:-1440x900x24}"
TITLE="${TITLE:-TypePHP Desktop}"
RPT="$WORK/session-report.txt"; : > "$RPT"
KEEP="${KEEP:-0}"            # 1 = leave the session up for manual poking

fail=0
note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }
gap()  { printf '   GAP  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }
rec()  { note "$*"; printf '%s\n' "$*" >> "$RPT"; }
count() { grep -c "$1" "$2" 2>/dev/null; }        # 0 on no match, empty if no file
n0()   { local v; v=$(count "$1" "$2"); printf '%s' "${v:-0}"; }

# _NET_WM_CM_S0 is an X *selection*, not a root property — `xprop -root` can
# never show it (that is why the first draft of this driver reported "picom
# died?" while picom was happily alive). Ask the server who owns it.
cm_owner() {
  DISPLAY="$DISPLAY_NUM" python3 - <<'PY' 2>/dev/null
import ctypes, ctypes.util, sys
lib = ctypes.util.find_library("X11")
if not lib:
    sys.exit(3)
x = ctypes.cdll.LoadLibrary(lib)
x.XOpenDisplay.restype = ctypes.c_void_p
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XGetSelectionOwner.restype = ctypes.c_ulong
x.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
d = x.XOpenDisplay(None)
if not d:
    sys.exit(3)
own = x.XGetSelectionOwner(d, x.XInternAtom(d, b"_NET_WM_CM_S0", 0))
if own:
    print("0x%x" % own)
PY
}

# The shim unlinks its own endpoint on a clean exit; SIGTERM skips that path.
# So close the *launcher* and let EOF take the shim down, then assert the unlink.
close_shim() {                          # <launcher pid> <shim pid> <sock> <label>
  local lpid=$1 spid=$2 sock=$3 label=$4
  [ -n "$lpid" ] && kill "$lpid" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$spid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$spid" 2>/dev/null; then
    bad "$label shim survived launcher exit; killing it"
    kill "$spid" 2>/dev/null
  else
    ok "$label shim exited on its own at client EOF"
  fi
  wait "$spid" 2>/dev/null               # reap it, so teardown sees no <defunct>
  SHIM_PID=""
  if [ -e "$sock" ]; then bad "$label endpoint $sock left behind"
  else ok "$label endpoint $sock unlinked"; fi
}

cleanup() {
  [ "$KEEP" = 1 ] && { note "KEEP=1 — leaving the session running"; return 0; }
  for pid in "${L4_PID:-}" "${L3_PID:-}" "${L2_PID:-}" "${SHIM_PID:-}" \
             "${MOCK_PID:-}" "${SNI_PID:-}" "${PICOM_PID:-}" "${OB_PID:-}" \
             "${DBUS_PID:-}" "${XVFB_PID:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  pkill -f 'launcher-linux' 2>/dev/null
  rm -f "$WORK"/*.sock 2>/dev/null
  return 0
}
trap cleanup EXIT

for want in Xvfb openbox picom xdotool wmctrl xprop xwininfo xdpyinfo import dbus-launch; do
  command -v "$want" >/dev/null || { echo "missing tool: $want"; exit 2; }
done
python3 -c 'import dbus, gi' 2>/dev/null || { echo "python3-dbus / python3-gi missing"; exit 2; }

# ---------------------------------------------------------------- build ----
sect "[0] build shim + pristine launcher-linux"
if [ "${SKIP_BUILD:-0}" = 1 ] && [ -x "$ROOT/build/launcher-linux" ]; then
  ok "reusing build/ from a previous run"
else
  ( cd "$ROOT" && bash tools/build-linux.sh ) >"$WORK/build.log" 2>&1 \
    && ok "tools/build-linux.sh" || { bad "build failed, see $WORK/build.log"; exit 2; }
fi
SHIM="$ROOT/build/backend_shell"; LAUNCH="$ROOT/build/launcher-linux"
BACKEND="$ROOT/bin/run-backend.php"; FRONT="$ROOT/demo/src/frontend/index.html"
[ -x "$SHIM" ] && [ -x "$LAUNCH" ] || { bad "build/backend_shell or build/launcher-linux absent"; exit 2; }
ok "launcher $(stat -c %s "$LAUNCH")B  shim $(stat -c %s "$SHIM")B"

# --------------------------------------------------------------- session ----
sect "[1] Xvfb + session bus + window manager + compositor + SNI host"
Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN" >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY="$DISPLAY_NUM"
sleep 1.5
kill -0 $XVFB_PID || { bad "Xvfb died"; exit 2; }
ok "Xvfb $DISPLAY_NUM ($SCREEN)"

eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS
DBUS_PID="$DBUS_SESSION_BUS_PID"
dbus-send --session --dest=org.freedesktop.DBus --print-reply \
  /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1 \
  && ok "session bus up (pid $DBUS_PID)" || { bad "no session bus"; exit 2; }

openbox >/dev/null 2>&1 & OB_PID=$!
wm=""
for _ in $(seq 1 25); do
  wm=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -o '0x[0-9a-f]*' | tail -n1)
  [ -n "$wm" ] && break
  sleep 0.4
done
[ -n "$wm" ] || { bad "no window manager claimed _NET_SUPPORTING_WM_CHECK"; exit 2; }
wmname=$(xprop -id "$wm" _NET_WM_NAME 2>/dev/null | sed -n 's/.*= "\(.*\)"/\1/p')
ok "WM running: ${wmname:-?} ($wm)"

CM0=$(cm_owner)
[ -z "$CM0" ] && ok "no compositor owns _NET_WM_CM_S0 yet (baseline for A2)" \
               || note "baseline: compositor owner $CM0 already present"
# --vsync is fatal here: picom 9's xrender backend finds no vsync method on
# Xvfb (no GLX/SGI-sync/UDRF) and aborts with "Failed to initialize the
# backend", which the first draft of this driver mistook for a session fault.
picom --backend xrender >"$WORK/picom.log" 2>&1 & PICOM_PID=$!
CM=""
for _ in $(seq 1 20); do
  CM=$(cm_owner)
  [ -n "$CM" ] && break
  sleep 0.4
done
kill -0 $PICOM_PID 2>/dev/null || { bad "picom died: $(tail -3 "$WORK/picom.log" | tr '\n' ' ')"; }
if [ -n "$CM" ]; then
  ok "A2 compositor owns the _NET_WM_CM_S0 selection (window $CM)"
else
  bad "A2 no _NET_WM_CM_S0 owner — picom never became the compositor"
fi
rec "session: WM=${wmname:-?} compositor=${CM:-none} bus=$DBUS_SESSION_BUS_ADDRESS screen=$SCREEN"

python3 "$ROOT/test/posix/sni_host.py" --report "$WORK/sni.json" \
  --icon-png "$WORK/tray-icon.png" --timeout 120 >"$WORK/sni.out" 2>&1 &
SNI_PID=$!
have_watcher=0
for _ in $(seq 1 25); do
  if dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
       org.freedesktop.DBus.NameHasOwner string:org.kde.StatusNotifierWatcher 2>/dev/null \
       | grep -q "boolean true"; then have_watcher=1; break; fi
  sleep 0.3
done
[ "$have_watcher" = 1 ] && ok "SNI watcher owns org.kde.StatusNotifierWatcher" \
                        || { bad "no StatusNotifierWatcher on the bus"; cat "$WORK/sni.out"; }

find_window() {                       # <title> -> decimal window id, ~12s wait
  # GTK creates an InputOnly WM_CLIENT_LEADER window that carries the same
  # _NET_WM_NAME as the toplevel; xdotool finds it FIRST and it is 10x10 and
  # unmapped. Only a viewable window is the app, so filter on that — otherwise
  # every geometry/WM assertion silently measures the leader.
  for _ in $(seq 1 30); do
    for wid in $(xdotool search --name "^$1\$" 2>/dev/null); do
      if xwininfo -id "$(hexid "$wid")" 2>/dev/null | grep -q 'Map State: IsViewable'; then
        printf '%s' "$wid"; return 0
      fi
    done
    sleep 0.4
  done
  return 1
}
hexid() { printf '0x%x' "$1"; }

# ---------------------------------------------------------------- [A] -----
sect "[A] the real app inside the real session (shim + PHP backend + demo page)"
SOCK="$WORK/app.sock"; rm -f "$SOCK"
TYPEPHP_SHELL_LOG="$WORK/shim.log" TYPEPHP_APP="$BACKEND" TYPEPHP_CWD="$ROOT/demo" \
  "$SHIM" "$SOCK" & SHIM_PID=$!
sleep 1
"$LAUNCH" "$FRONT" "$SOCK" "$TITLE" 640x400 0.1.0 >"$WORK/launcher.out" 2>&1 &
L2_PID=$!
WID=$(find_window "$TITLE") || bad "window never appeared"
[ -n "${WID:-}" ] && ok "window $WID mapped under the WM" || WID=""

if [ -n "$WID" ]; then
  WIDH=$(hexid "$WID")
  # Two format traps, both verified against the live session:
  #   * `xwininfo -root` starts with a BLANK line, so anchoring on line 1 finds
  #     nothing — match the "xwininfo: Window id:" header wherever it lands.
  #   * plain `xwininfo -id` has NO Parent line at all; only `-tree` prints one.
  # The first draft hit both and concluded the WM never reparented us.
  ROOTID=$(xwininfo -root 2>/dev/null | sed -n 's/^xwininfo: Window id: *\(0x[0-9a-f]*\).*/\1/p' | head -n1)
  parent=$(xwininfo -tree -id "$WIDH" 2>/dev/null | sed -n 's/^[[:space:]]*[Pp]arent [Ww]indow id: *\(0x[0-9a-f]*\).*/\1/p' | head -n1)
  if [ -n "$parent" ] && [ -n "$ROOTID" ] && [ "$parent" != "$ROOTID" ]; then
    ok "A1 reparented by the WM (parent $parent, root $ROOTID)"
  else
    bad "A1 not reparented (parent=${parent:-?} root=${ROOTID:-?})"
  fi
  fe=$(xprop -id "$WIDH" _NET_FRAME_EXTENTS 2>/dev/null)
  case "$fe" in
    *"_NET_FRAME_EXTENTS"*) : ;;
    *)                      bad "A1 no _NET_FRAME_EXTENTS property" ;;
  esac
  # xprop prints `NET_FRAME_EXTENTS(CARDINAL) = 1, 1, 20, 5` — the value is
  # after "= ", not inside parentheses.
  case "$fe" in
    *"= 0, 0, 0, 0"*) bad "A1 _NET_FRAME_EXTENTS all zero — undecorated" ;;
    *"= "*[1-9]*)     ok "A1 $fe" ;;
    *)               bad "A1 unreadable _NET_FRAME_EXTENTS: $fe" ;;
  esac
  wn=$(xprop -id "$WIDH" _NET_WM_NAME 2>/dev/null | sed -n 's/.*= "\(.*\)"/\1/p')
  [ "$wn" = "$TITLE" ] && ok "A1 _NET_WM_NAME=$wn" || bad "A1 _NET_WM_NAME='$wn' != '$TITLE'"
  # The clincher: the client's offset INSIDE its new parent must equal the
  # border the WM just published. Decoration and geometry agree, so this is not
  # a property some other client happens to have set.
  ry=$(xwininfo -id "$WIDH" 2>/dev/null | sed -n 's/.*Relative upper-left Y: *\([0-9-]*\).*/\1/p')
  top=$(printf '%s' "$fe" | sed -n 's/.*= *[0-9]*, *[0-9]*, *\([0-9]*\).*/\1/p')
  [ -n "$ry" ] && [ "$ry" = "$top" ] \
    && ok "A1 client sits ${ry}px below its frame top (matches _NET_FRAME_EXTENTS)" \
    || bad "A1 relative Y=${ry:-?} disagrees with frame top extent=${top:-?}"
  rec "A1 managed: parent=$parent root=$ROOTID |${fe#*: } | title=$wn | relY=${ry:-?}"
fi

for _ in $(seq 1 30); do
  grep -q 'WINDOW-E2E OK ping=pong in [0-9]*ms' "$WORK/shim.log" 2>/dev/null && break
  sleep 0.5
done
CALLS=$(n0 'L->P: CALL' "$WORK/shim.log"); RETS=$(n0 'P->L: RET' "$WORK/shim.log")
MARK=$(grep -m1 -o 'WINDOW-E2E OK ping=pong in [0-9]*ms' "$WORK/shim.log" 2>/dev/null || true)
if [ "$CALLS" -ge 13 ] && [ "$RETS" -ge 13 ] && [ -n "$MARK" ]; then
  ok "A4 CALL=$CALLS RET=$RETS | $MARK"
else
  bad "A4 frame round trip incomplete (CALL=$CALLS RET=$RETS mark=${MARK:-none})"
fi
rec "A4 frames: CALL=$CALLS RET=$RETS ${MARK:-none}"

if [ -n "$WID" ]; then
  b=$(n0 '"minimized":true' "$WORK/shim.log")
  xdotool windowminimize "$WID" 2>/dev/null; sleep 1.5
  a=$(n0 '"minimized":true' "$WORK/shim.log")
  [ "$a" -gt "$b" ] && ok "A3 minimize -> WINSTATE minimized:true ($b -> $a)" \
                     || bad "A3 no minimized:true WINSTATE after xdotool windowminimize"
  xdotool windowactivate "$WID" 2>/dev/null; sleep 0.6
  b=$(n0 '"maximized":true' "$WORK/shim.log")
  wmctrl -ir "$WIDH" -b add,maximized_vert,maximized_horz 2>/dev/null; sleep 1.5
  a=$(n0 '"maximized":true' "$WORK/shim.log")
  [ "$a" -gt "$b" ] && ok "A3 maximize -> WINSTATE maximized:true ($b -> $a)" \
                     || bad "A3 no maximized:true WINSTATE after wmctrl maximize"
  w=$(xwininfo -id "$WIDH" 2>/dev/null | sed -n 's/.*Width: *\([0-9]*\).*/\1/p')
  [ "${w:-0}" -gt 700 ] && ok "A3 client width followed the frame (${w}px)" \
                        || bad "A3 client width still ${w:-?}px after maximize"
  rec "A3 WM events: minimized=$a maximized=$a width-after-maximize=${w:-?}px"

  import -window root "$WORK/shot-session.png" 2>/dev/null \
    && ok "shot-session.png (WM decorations + compositor)" \
    || note "import of the root failed"
  import -window "$WIDH" "$WORK/shot-window.png" 2>/dev/null && ok "shot-window.png (client)"
  # Not a restatement of the startup check: the client pixel geometry above is
  # only non-trivially composited if the selection is STILL owned while our
  # window is mapped, and the window must be redirected for that to be true.
  CMAP=$(cm_owner)
  if [ -n "$CMAP" ]; then
    ok "A2 compositor ${CMAP} still owns _NET_WM_CM_S0 with $WIDH mapped (shot-session.png)"
  else
    bad "A2 compositor lost the selection while the window was mapped"
  fi
  rec "A2 compositor: owner=${CMAP:-none} baseline=${CM0:-none} window=$WIDH picom_alive=$(kill -0 $PICOM_PID 2>/dev/null && echo yes || echo no) ext=$(xdpyinfo 2>/dev/null | grep -c 'Composite')"
fi

sect "[A5] high DPI (GDK_SCALE=2)"
close_shim "$L2_PID" "$SHIM_PID" "$SOCK" A
SOCK2="$WORK/app2.sock"; rm -f "$SOCK2"
TYPEPHP_SHELL_LOG="$WORK/shim-hidpi.log" TYPEPHP_APP="$BACKEND" TYPEPHP_CWD="$ROOT/demo" \
  "$SHIM" "$SOCK2" & SHIM_PID=$!
sleep 1
GDK_SCALE=2 GDK_DPI_SCALE=1 "$LAUNCH" "$FRONT" "$SOCK2" "${TITLE}-HiDPI" 640x400 0.1.0 \
  >"$WORK/launcher-hidpi.out" 2>&1 &
L3_PID=$!
WID2=$(find_window "${TITLE}-HiDPI") || bad "HiDPI window never appeared"
if [ -n "${WID2:-}" ]; then
  sleep 2; WID2H=$(hexid "$WID2")
  hw=$(xwininfo -id "$WID2H" 2>/dev/null | sed -n 's/.*Width: *\([0-9]*\).*/\1/p')
  hh=$(xwininfo -id "$WID2H" 2>/dev/null | sed -n 's/.*Height: *\([0-9]*\).*/\1/p')
  if [ "${hw:-0}" -ge 1200 ] && [ "${hh:-0}" -ge 700 ]; then
    ok "A5 GDK_SCALE=2: ${hw}x${hh}px for a 640x400 logical window (2x)"
  else
    bad "A5 scale 2 gave ${hw:-?}x${hh:-?}px — expected ~1280x800"
  fi
  import -window "$WID2H" "$WORK/shot-hidpi.png" 2>/dev/null && ok "shot-hidpi.png"
  rec "A5 hidpi: logical=640x400 physical=${hw:-?}x${hh:-?} (GDK_SCALE=2)"
fi
close_shim "${L3_PID:-}" "$SHIM_PID" "$SOCK2" A5

# ---------------------------------------------------------------- [B] -----
sect "[B] tray + global hotkey (frames the PHP backend cannot emit yet)"
{
  printf 'TRAYBEGIN desktop-tray\\t%s/demo/icon.png\\t0\\ttypephp desktop acceptance\\t1\n' "$ROOT"
  printf 'ITEM tray-hello\\tSay hello\\t\\t\n'
  printf 'ITEM tray-note\\tWrite a note\\t\\t\n'
  printf 'TRAYEND\n'
  printf 'HKREG boss\\tctrl+alt+shift+F12\n'
} > "$WORK/frames.txt"

MOCK_SOCK="$WORK/mock.sock"; rm -f "$MOCK_SOCK"
python3 "$ROOT/test/posix/mock_shim.py" "$MOCK_SOCK" --log "$WORK/mock.log" \
  --inject "$WORK/frames.txt" --inject-after 3 >"$WORK/mock.out" 2>&1 & MOCK_PID=$!
sleep 1
"$LAUNCH" "$FRONT" "$MOCK_SOCK" "${TITLE}-Tray" 640x400 0.1.0 \
  >"$WORK/launcher-tray.out" 2>&1 &
L4_PID=$!
WID3=$(find_window "${TITLE}-Tray") || note "tray-session window not found (not fatal)"
sleep 4
ok "frames injected: $(n0 'injected' "$WORK/mock.log") line(s)"

python3 "$ROOT/test/posix/sni_host.py" --report "$WORK/sni-click.json" \
  --icon-png "$WORK/tray-icon2.png" --timeout 20 --click 'Say hello' \
  >"$WORK/sni-click.out" 2>&1; rc=$?
if [ $rc -eq 0 ]; then
  ok "B1 a tray host saw the item and read its props + dbusmenu"
  python3 - "$WORK/sni-click.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for it in d.get("items", []):
    p = it.get("props", {})
    print("        item Id=%r Status=%r IconName=%r pixmap=%s Menu=%s"
          % (p.get("Id"), p.get("Status"), p.get("IconName"),
             p.get("IconPixmap", {}).get("pixels"), p.get("Menu")))
    for row in it.get("dbusmenu", {}).get("items", []):
        print("        menu  id=%s label=%r type=%r" % (row["id"], row["label"], row["type"]))
PY
else
  bad "B1 sni_host exited rc=$rc — the item never registered"; cat "$WORK/sni-click.out"
fi
sleep 1.5
grep -q 'L->P: TRAY tray-hello' "$WORK/mock.log" 2>/dev/null \
  && ok "B2 tray menu click -> 'TRAY tray-hello' on the pipe" \
  || { bad "B2 no TRAY tray-hello frame"; tail -n 6 "$WORK/mock.log"; }

python3 "$ROOT/test/posix/sni_host.py" --report "$WORK/sni-open.json" \
  --timeout 15 --click 'desktop-tray' >"$WORK/sni-open.out" 2>&1
sleep 1.5
grep -q 'L->P: TRAYCLICK' "$WORK/mock.log" 2>/dev/null \
  && ok "B2 primary tray item click -> 'TRAYCLICK' on the pipe" \
  || bad "B2 no TRAYCLICK frame after clicking the primary item"

xdotool key --clearmodifiers ctrl+alt+shift+F12 2>/dev/null; sleep 1.2
grep -q 'L->P: HOTKEY boss' "$WORK/mock.log" 2>/dev/null \
  && ok "B3 ctrl+alt+shift+F12 -> 'HOTKEY boss' (XGrabKey on the root window works)" \
  || { bad "B3 no HOTKEY boss frame"; tail -n 8 "$WORK/mock.log"; }
# Baseline AFTER the F12 assertion: taken before it, the count legitimately
# moves 0 -> 1 across the two presses and the negative control "fails" on the
# very grab it is meant to prove works.
b=$(n0 'L->P: HOTKEY ' "$WORK/mock.log")
xdotool key --clearmodifiers ctrl+alt+shift+F11 2>/dev/null; sleep 1.2
xdotool key --clearmodifiers super+F12 2>/dev/null; sleep 1.2
a=$(n0 'L->P: HOTKEY ' "$WORK/mock.log")
[ "$a" = "$b" ] && ok "B4 negative control: F11 and bare-F12 added no HOTKEY ($b -> $a)" \
                 || bad "B4 negative control failed: HOTKEY count moved $b -> $a"
rec "B tray/hotkey: TRAY=$(n0 'L->P: TRAY tray-hello' "$WORK/mock.log") TRAYCLICK=$(n0 'L->P: TRAYCLICK' "$WORK/mock.log") HOTKEY=$(n0 'L->P: HOTKEY boss' "$WORK/mock.log")"
import -window root "$WORK/shot-tray.png" 2>/dev/null && ok "shot-tray.png"

kill $L4_PID 2>/dev/null; wait $L4_PID 2>/dev/null
kill $MOCK_PID 2>/dev/null; wait $MOCK_PID 2>/dev/null

# ---------------------------------------------------------------- [C] -----
sect "[C] pipe -> page events (the leg the mock cannot reach)"
cat > "$WORK/protocol_leg.php" <<'PHP'
<?php
require $argv[1] . '/gui/php/src/Tiny/Gui/Protocol.php';
use Tiny\Gui\Protocol;
$bad = 0;
foreach (["TRAY tray-hello", "TRAYCLICK", "HOTKEY boss"] as $l) {
    $m = Protocol::decode($l);
    printf("  %-16s -> type=%-12s event=%s\n", $l, $m['type'], $m['event'] ?? '-');
}
if ((Protocol::decode("TRAY tray-hello")["event"] ?? null) !== "tray") $bad = 1;
if ((Protocol::decode("TRAYCLICK")["event"] ?? null) !== "trayclick") $bad = 1;
$hotkey = Protocol::decode("HOTKEY boss");
if (($hotkey["event"] ?? null) !== "hotkey") {
    echo "  HOTKEY is not decoded into a page event: type=" . $hotkey['type'] . "\n";
    exit(2);
}
exit($bad);
PHP
php "$WORK/protocol_leg.php" "$ROOT" >"$WORK/protocol-leg.txt" 2>&1; crc=$?
sed -n 's/^/   /p' "$WORK/protocol-leg.txt"
case $crc in
  0) ok "C1 TRAY/TRAYCLICK/HOTKEY all decode into page events" ;;
  2) gap "C1 TRAY/TRAYCLICK decode into page events, but HOTKEY is dropped."
     note "        The launcher's global hotkey fires (B3) and the frame reaches"
     note "        the pipe, yet Protocol::decode has no 'HOTKEY ' branch, so no"
     note "        page handler can ever see it. Product gap, not a session fault."
     rec "C1 gap: HOTKEY -> ignore in Protocol::decode (tray/trayclick OK)" ;;
  *) bad "C1 Protocol::decode broke (rc=$crc)" ;;
esac

# ------------------------------------------------------------ teardown ----
sect "[X] teardown"
kill $SNI_PID 2>/dev/null; wait $SNI_PID 2>/dev/null
kill $MOCK_PID 2>/dev/null; wait $MOCK_PID 2>/dev/null
kill $L4_PID 2>/dev/null; wait $L4_PID 2>/dev/null
pkill -f 'launcher-linux' 2>/dev/null; sleep 2
# A <defunct> entry is a child this script has already killed and is about to
# reap via `wait` — it is not a live survivor, and the first draft counted it
# as one.
left=$(pgrep -af 'launcher-linux|backend_shell|run-backend.php' 2>/dev/null | grep -v '<defunct>' || true)
if [ -z "$left" ]; then
  ok "no launcher/shim/backend left running"
else
  bad "survivors:"; printf '%s\n' "$left" | sed 's/^/        /'
fi
# Product endpoints only: the two shims were closed via launcher EOF above, so
# any app*.sock here would be a real unlink leak. mock.sock belongs to the
# harness and is removed by hand.
prod_socks=$(ls "$WORK"/app*.sock 2>/dev/null || true)
if [ -z "$prod_socks" ]; then ok "no product AF_UNIX endpoint left"
else bad "endpoint(s) left: $(printf '%s' "$prod_socks" | tr '\n' ' ')"; fi
rm -f "$WORK"/mock.sock 2>/dev/null
rec "X teardown: survivors=${left:-none} product-sockets=${prod_socks:-none}"

echo
echo "== desktop-session result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
echo "== evidence in $WORK"
ls -1 "$WORK" | sed 's/^/   /'
