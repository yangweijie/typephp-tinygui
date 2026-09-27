#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-bundle-linux.sh — structural checks on a Linux app dir built by
# `tgui build` (Phase 22c).
#
#   usage: bash tools/verify-bundle-linux.sh dist/<name>
#
# This verifies the LAYOUT, not the runtime: every check here is a precondition
# the live end-to-end run (Phase 22d) relies on, stated so a failure points at
# the file that is wrong. It deliberately re-implements the shim's own conf
# resolution (stem = basename up to the FIRST '.', keys trimmed, relative paths
# resolved against the exe dir) — if the two ever disagree, a bundle could
# "verify" and still not start.
#
# Exit: 0 all good · 1 a check failed · 2 the script itself could not run.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D1="${1:-}"
[ -n "$D1" ] || { echo "usage: $0 <dist-app-dir>" >&2; exit 2; }
D="$(cd "$D1" 2>/dev/null && pwd)" || { echo "not a directory: $D1" >&2; exit 2; }
[ -n "$D" ] || exit 2

fail=0
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }
info() { printf '   ·    %s\n' "$*"; }

NAME="$(basename "$D")"

# --- 1. the three pieces exist, and the entry is where the shim will look ----
ENT="$D/$NAME"
CONF="$D/$NAME.conf"
LAU="$D/launcher-linux"
[ -f "$ENT" ]  || bad "entry missing: $ENT (tgui build names it after the dir)"
[ -f "$CONF" ] || bad "conf missing: $CONF"
[ -f "$LAU" ]  || bad "launcher missing: $LAU"
[ "$fail" = 0 ] || { echo; echo "== bundle checks: FAIL"; exit 1; }

# --- 2. ELF sanity + host-arch agreement ------------------------------------
elf_desc() { # <file> -> "ELF64 aarch64" | "ELF32 x86_64" | "not-elf"
  local f="$1" sig class machine
  sig="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$sig" = "7f454c46" ] || { printf 'not-elf'; return; }
  class="$(od -An -j4 -N1 -tu1 "$f" | tr -d ' \n')"
  machine="$(od -An -j18 -N1 -tu1 "$f" | tr -d ' \n')"
  # e_machine: 0x3e=64 x86_64, 0xb7=183 aarch64, 0x28=40 arm, 0xf7=247 riscv
  case "$machine" in
    62)  printf 'ELF%s x86_64'  "$([ "$class" = 2 ] && echo 64 || echo 32)" ;;
    183) printf 'ELF%s aarch64' "$([ "$class" = 2 ] && echo 64 || echo 32)" ;;
    40)  printf 'ELF%s arm'     "$([ "$class" = 2 ] && echo 64 || echo 32)" ;;
    *)   printf 'ELF%s e_machine=%s' "$class" "$machine" ;;
  esac
}
HOST="$(uname -m)"
for b in "$ENT" "$LAU"; do
  desc="$(elf_desc "$b")"
  [ "$desc" = "not-elf" ] && { bad "$(basename "$b"): not an ELF binary"; continue; }
  case "$HOST" in
    x86_64|aarch64) case "$desc" in *"$HOST"*) ok "$(basename "$b") — $desc (matches host)";;
                    *) bad "$(basename "$b") — $desc does not match host $HOST";; esac ;;
    *) info "$(basename "$b") — $desc (host '$HOST' has no arch rule, not compared)" ;;
  esac
done

# --- 3. exec bits -----------------------------------------------------------
# The entry and launcher are execv'd; run-backend.php is execv'd DIRECTLY with
# no argv (the shim has no idea it is a script), so its exec bit + shebang are
# load-bearing, not cosmetic.
for x in "$ENT" "$LAU" "$D/app/bin/run-backend.php"; do
  [ -f "$x" ] || { bad "not present to check: $x"; continue; }
  [ -x "$x" ] && ok "exec bit — ${x#"$D"/}" || bad "NOT executable: ${x#"$D"/}"
done
SB="$(head -c 2 "$D/app/bin/run-backend.php" 2>/dev/null)"
if [ "$SB" = "#!" ]; then
  ok "backend starts with '#!' — the shim classifies it as a stock-PHP app (TYPEPHP_APP_KIND=stock)"
else
  bad "app/bin/run-backend.php has no shebang (got '$SB') — execv would fail at spawn"
fi

# --- 4. conf re-parsed with the SHIM's semantics ----------------------------
STEM="${NAME%%.*}"
[ "$STEM" = "$NAME" ] || bad "entry stem stops at the first '.': the shim will read $D/$STEM.conf, not $CONF"
conf_get() { # conf_get <key> — 'key=value', trimmed, '#' comments, first '=' splits
  awk -F= -v k="$1" '
    { line=$0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line) }
    line ~ /^#/ || line == "" { next }
    line !~ /=/ { next }
    { key=line; sub(/=.*/, "", key); val=line; sub(/^[^=]*=?/, "", val) }
    key == k { sub(/^[ \t]+/, "", val); sub(/[ \t\r]+$/, "", val); print val; exit }
  ' "$D/$STEM.conf"
}
HTML="$(conf_get html)"; APP="$(conf_get app)"; LKEY="$(conf_get launcher)"
TITLE="$(conf_get title)"; SIZEV="$(conf_get size)"; VER="$(conf_get version)"
ICONS="$(conf_get icon)"
[ -n "$HTML" ]  && [ -f "$D/$HTML" ]  && ok "conf html=$HTML resolves"  || bad "conf html='$HTML' missing or unresolved"
[ -n "$APP" ]   && [ -f "$D/$APP" ]   && ok "conf app=$APP resolves"    || bad "conf app='$APP' missing or unresolved"
[ -n "$LKEY" ]  && [ -f "$D/$LKEY" ]  && ok "conf launcher=$LKEY resolves" || bad "conf launcher='$LKEY' missing or unresolved"
if [ -n "$ICONS" ]; then
  [ -f "$D/$ICONS" ] && ok "conf icon=$ICONS resolves (shim exports it as TINYJS_ICON)" \
                     || bad "conf icon='$ICONS' does not exist"
fi
[ -n "$TITLE" ] || bad "conf title empty"
printf '%s' "$SIZEV" | grep -Eq '^[0-9]+x[0-9]+$' && ok "conf size=$SIZEV" || bad "conf size='$SIZEV' is not WxH"
[ -n "$VER" ]   && ok "conf version=$VER" || bad "conf version empty"

# --- 5. the backend mirror is complete and byte-identical --------------------
# app/ mirrors repo paths so require __DIR__.'/../src/backend.php' and the
# gui/php framework requires resolve without a single edited byte.
mirror_one() { # mirror_one <repo-relative path>
  if [ ! -f "$ROOT/$1" ]; then bad "source gone from the repo: $1"; return; fi
  if [ ! -f "$D/app/$1" ]; then bad "not mirrored: app/$1"; return; fi
  cmp -s "$ROOT/$1" "$D/app/$1" && ok "identical: app/$1" || bad "DIFFERS from repo: app/$1"
}
mirror_one bin/run-backend.php
mirror_one src/backend.php
N=0; NB=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  N=$((N + 1))
  [ -f "$D/app/$rel" ] && cmp -s "$f" "$D/app/$rel" || { NB=$((NB + 1)); bad "mirror broken/drifted: app/$rel"; }
done < <(find "$ROOT/gui/php/src" -type f | sort)
[ "$NB" = 0 ] && ok "gui/php mirror complete: $N files under app/gui/php/src"

# --- 6. the AF_UNIX endpoint actually fits in sun_path -----------------------
SOCKPATH="$D/app.sock"
if [ "${#SOCKPATH}" -lt 108 ]; then
  ok "endpoint fits sun_path (${#SOCKPATH}/108): $SOCKPATH"
else
  info "endpoint path is ${#SOCKPATH}B >= sun_path 108B — the shim will fall back to /tmp/tinyjs-typephp-<pid>.sock (works; just not this path)"
fi

# --- 7. what the TARGET machine must provide ---------------------------------
if command -v php >/dev/null 2>&1; then
  ok "php on PATH here ($(php -r 'echo PHP_VERSION;' 2>/dev/null)) — same requirement applies on the target"
else
  info "no php on this PATH; the bundle needs a stock php >= 8.1 on the target to start"
fi
if command -v ldd >/dev/null 2>&1; then
  libs="$(ldd "$LAU" 2>/dev/null | awk '/gtk|webkit|ayatana|X11|Xtst/ {print $1}' | sort -u | tr '\n' ' ')"
  [ -n "$libs" ] && info "target must provide (dynamic deps of launcher-linux): $libs"
  if ldd "$LAU" 2>/dev/null | grep -q 'not found'; then
    bad "launcher-linux has UNRESOLVED deps here: $(ldd "$LAU" | awk '/not found/{print $1}' | tr '\n' ' ')"
  else
    ok "launcher-linux deps all resolve on this machine"
  fi
fi

echo
if [ "$fail" = 0 ]; then echo "== bundle checks: PASS ($D)"; else echo "== bundle checks: FAIL ($D)"; fi
exit $fail
