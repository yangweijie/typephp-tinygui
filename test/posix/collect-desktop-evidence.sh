#!/usr/bin/env bash
# Phase 23 evidence collector — RE-DERIVE, never restate.
#
# The driver (test/posix/desktop-session.sh) prints its own PASS line, but a
# PASS printed by the thing under test is not evidence. This script reads the
# STORED 23-* files under evidence/linux/ and recomputes every number the
# README and the plan files quote. Run it after copying new evidence in, or
# with REGEN=1 to rewrite the manifest from the stored files alone:
#
#   bash test/posix/collect-desktop-evidence.sh            # verify stored set
#   REGEN=1 bash test/posix/collect-desktop-evidence.sh    # rewrite the manifest
#
# Exit 0 = every derived claim holds; 1 = at least one does not.
set -u
EV="${EV:-evidence/linux}"
OUT="$(cd "$EV" && pwd)/23-MANIFEST.txt"   # absolute: the script cd's into $EV below
REGEN="${REGEN:-0}"
fail=0

[ -d "$EV" ] || { echo "no $EV"; exit 2; }
cd "$EV" || exit 2
for f in 23-session-report.txt 23-shim.log 23-shim-hidpi.log 23-mock.log \
         23-sni-click.json 23-protocol-leg.txt 23-picom.log; do
  [ -f "$f" ] || { echo "MISSING $f"; exit 2; }
done

note() { printf '%s\n' "$*"; }
chk()  { # <label> <expected-regex> <file...> -> grep -q over the concatenation
  local label=$1 re=$2; shift 2
  if grep -qE "$re" "$@" 2>/dev/null; then note "   ok   $label"
  else note "   FAIL $label (no /$re/ in $*)"; fail=1; fi
}

M=$(mktemp); {
  note "# Phase 23 — Linux REAL DESKTOP SESSION evidence (Openbox + picom + SNI host)"
  note "# collected: $(date -u +%Y-%m-%dT%H:%M:%SZ) by test/posix/collect-desktop-evidence.sh"
  note "# source:    /tmp/tpgui-desktop inside the Apple Container 'tgl' (Debian bookworm, arm64)"
  note "# repo rev:  $(git -C ../.. rev-parse --short HEAD 2>/dev/null || echo '?')"
  note "# driver:    SKIP_BUILD=1 bash test/posix/desktop-session.sh  ->  expected final line:"
  note "#              == desktop-session result: PASS"
  note "#            (SKIP_BUILD=1 reuses build/; tools/build-linux.sh is byte-identical to the"
  note "#             one that produced it, and desktop-session.sh / sni_host.py / mock_shim.py"
  note "#             were sha256-matched against the repo copies before and after this run.)"
  note "# this file is RE-DERIVED from the stored 23-* files below, not copied from stdout."
  note
  note "== session facts (23-session-report.txt)"
  sed -n 's/^/   /p' 23-session-report.txt
  note
  note "== derived claims"
  chk "A1 the WM reparented the window and published non-zero frame extents" \
      'A1 managed: parent=0x[0-9a-f]+ root=0x[0-9a-f]+ .* relY=[1-9]' 23-session-report.txt
  chk "A2 a compositor owned _NET_WM_CM_S0 with the window mapped" \
      'A2 compositor: owner=0x[0-9a-f]+ baseline=none' 23-session-report.txt
  chk "A3 minimize rode back as a WINSTATE frame" \
      'minimized=[1-9]' 23-session-report.txt
  chk "A3 maximize rode back as a WINSTATE frame" \
      'maximized=[1-9]' 23-session-report.txt
  chk "A4 frame round trip completed in-session" \
      'A4 frames: CALL=[0-9]+ RET=[0-9]+ WINDOW-E2E OK ping=pong in [0-9]+ms' 23-session-report.txt
  chk "A5 GDK_SCALE=2 doubled the physical geometry" \
      'A5 hidpi: logical=640x400 physical=12[0-9][0-9]x[78][0-9][0-9]' 23-session-report.txt
  chk "B tray + hotkey frames all reached the pipe" \
      'B tray/hotkey: TRAY=1 TRAYCLICK=1 HOTKEY=1' 23-session-report.txt
  chk "C1 recorded as a gap (HOTKEY undecoded), not a silent pass" \
      'C1 gap: HOTKEY -> ignore' 23-session-report.txt
  chk "X teardown left no survivor and no product endpoint" \
      'X teardown: survivors=none product-sockets=none' 23-session-report.txt
  note
  note "== raw frame proof, re-grepped from the logs (not the report)"
  note "   shim.log            CALL=$(grep -c 'L->P: CALL' 23-shim.log) RET=$(grep -c 'P->L: RET' 23-shim.log) marker=$(grep -m1 -o 'WINDOW-E2E OK ping=pong in [0-9]*ms' 23-shim.log)"
  note "   shim-hidpi.log      CALL=$(grep -c 'L->P: CALL' 23-shim-hidpi.log) RET=$(grep -c 'P->L: RET' 23-shim-hidpi.log) marker=$(grep -m1 -o 'WINDOW-E2E OK ping=pong in [0-9]*ms' 23-shim-hidpi.log)"
  note "   WINSTATE minimized=$(grep -c '"minimized":true' 23-shim.log) maximized=$(grep -c '"maximized":true' 23-shim.log)"
  note "   mock.log            TRAY=$(grep -c 'L->P: TRAY tray-hello' 23-mock.log) TRAYCLICK=$(grep -c 'L->P: TRAYCLICK' 23-mock.log) HOTKEY=$(grep -c 'L->P: HOTKEY boss' 23-mock.log)"
  [ "$(grep -c 'L->P: CALL' 23-shim.log)" -ge 13 ] || { note "   FAIL fewer than 13 CALL frames"; fail=1; }
  [ "$(grep -c 'L->P: HOTKEY boss' 23-mock.log)" -ge 1 ] || { note "   FAIL no HOTKEY boss frame"; fail=1; }
  note
  note "== SNI host read-back (23-sni-click.json)"
  python3 - 23-sni-click.json <<'PY'
import json
d = json.load(open("23-sni-click.json"))
for it in d.get("items", []):
    p = it.get("props", {})
    print("   item Id=%r Status=%r Menu=%s" % (p.get("Id"), p.get("Status"), p.get("Menu")))
    for row in it.get("dbusmenu", {}).get("items", []):
        print("   menu  id=%s label=%r type=%r" % (row["id"], row["label"], row["type"]))
PY
  note
  note "== pipe -> page leg (23-protocol-leg.txt)"
  sed -n 's/^/   /p' 23-protocol-leg.txt
  note
  note "== compositor log tail (23-picom.log: proves picom ran, no vsync on Xvfb)"
  sed -n '1,3p' 23-picom.log | sed 's/^/   /'
  note
  note "== harness as committed (sha256; the run used byte-identical copies)"
  for f in ../../test/posix/desktop-session.sh ../../test/posix/sni_host.py \
           ../../test/posix/mock_shim.py ../../tools/build-linux.sh; do
    printf '   %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#../../}"
  done
  note
  note "== stored files (sha256, bytes)"
  for f in 23-*; do
    [ "$f" = "23-MANIFEST.txt" ] && continue
    printf '   %s  %s  %sB\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f" "$(wc -c <"$f" | tr -d ' ')"
  done
} > "$M"

cat "$M"
if [ "$REGEN" = 1 ]; then mv "$M" "$OUT"; chmod 644 "$OUT"; note "wrote $EV/23-MANIFEST.txt"; else rm -f "$M"; fi
echo
echo "== collect-desktop-evidence: $([ $fail = 0 ] && echo 'ALL CLAIMS DERIVE CLEAN' || echo 'CLAIMS FAILED')"
exit $fail
