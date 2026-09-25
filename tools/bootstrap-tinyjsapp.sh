#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Move a tinyjsapp checkout between three known states.
#
#   bash tools/bootstrap-tinyjsapp.sh status    # where is the checkout now?
#   bash tools/bootstrap-tinyjsapp.sh patch     # pristine + our patches  (default)
#   bash tools/bootstrap-tinyjsapp.sh restore   # pristine v0.42.0
#
# Why bother: `cli.js` and `native/launcher-win.cc` are upstream's files. We need
# to change both, but we do not want a checkout that has silently drifted and
# cannot be reasoned about later. So the baseline is kept in patches/base/ and
# these two files are always derived, never hand-edited.
#
# `status` is deliberately blunt: it hashes the files and compares.
#
#   usage: bash tools/bootstrap-tinyjsapp.sh [status|patch|restore] [tinyjsapp-dir]
#   env:   TINYJSAPP=/path/to/tinyjsapp-0.42.0
# ---------------------------------------------------------------------------
set -uo pipefail

CMD="${1:-patch}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TJS="${2:-${TINYJSAPP:-D:/git/web/tinyjsapp-0.42.0}}"
PATCHES="$ROOT/patches"

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
warn() { printf '   !!   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*"; exit 1; }

[ -d "$TJS" ]              || die "not a directory: $TJS
   pass the checkout as arg 2, or set TINYJSAPP=/path/to/tinyjsapp-0.42.0"
[ -f "$TJS/cli.js" ]       || die "no cli.js in $TJS — is this a tinyjsapp checkout?"
[ -f "$PATCHES/base/cli.js.orig" ] || die "missing $PATCHES/base/cli.js.orig"

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Rebuild a file from its saved base, optionally applying a patch.
# restore_from_base <base> <target> <patch|"">
restore_from_base() {
  local base="$1" target="$2" patch="$3"
  [ -f "$base" ] || die "missing base: $base"
  cp -f "$base" "$target" || die "cannot write $target"
  if [ -n "$patch" ]; then
    [ -f "$patch" ] || die "missing patch: $patch"
    ( cd "$(dirname "$target")" && patch -p0 --quiet "$(basename "$target")" < "$patch" ) \
      || die "patch did not apply cleanly: $patch"
  fi
}

report_status() {
  say "checkout state — $TJS"
  local pairs=(
    "cli.js|$PATCHES/base/cli.js.orig|$PATCHES/cli-typephp.patch"
    "native/launcher-win.cc|$PATCHES/base/launcher-win.cc.orig|$PATCHES/launcher-win-typephp.patch"
  )
  for p in "${pairs[@]}"; do
    IFS='|' read -r rel base patch <<<"$p"
    local t="$TJS/$rel"
    if [ ! -f "$t" ]; then warn "$rel — MISSING"; continue; fi
    if [ "$(sha "$t")" = "$(sha "$base")" ]; then
      printf '   %-24s pristine\n' "$rel"
    else
      # Derive what "patched" should hash to, then compare.
      local tmp; tmp="$(mktemp -d)"
      cp -f "$base" "$tmp/x" 2>/dev/null
      ( cd "$tmp" && patch -p0 --quiet x < "$patch" >/dev/null 2>&1 )
      if [ "$(sha "$t")" = "$(sha "$tmp/x")" ]; then
        printf '   %-24s PATCHED (our patch)\n' "$rel"
      else
        printf '   %-24s MODIFIED (not ours — drifted?)\n' "$rel"
      fi
      rm -rf "$tmp"
    fi
  done

  local extra=0
  for f in native/backend.exe native/app.exe native/launcher-win.exe \
           native/launcher-win.cc.orig.bak native/winrt-shim native/_build.log; do
    [ -e "$TJS/$f" ] && { printf '   %-24s present (ours: build output)\n' "$f"; extra=$((extra+1)); }
  done
  [ "$extra" -eq 0 ] && printf '   %-24s\n' "(no build output / shim installed)"
  return 0
}

case "$CMD" in
  status)
    report_status
    ;;

  patch)
    say "patching $TJS  (base -> patched)"
    restore_from_base "$PATCHES/base/cli.js.orig" "$TJS/cli.js" "$PATCHES/cli-typephp.patch"
    ok "cli.js          <- base + cli-typephp.patch"
    restore_from_base "$PATCHES/base/launcher-win.cc.orig" "$TJS/native/launcher-win.cc" \
                      "$PATCHES/launcher-win-typephp.patch"
    ok "launcher-win.cc <- base + launcher-win-typephp.patch"
    # Our own backup predates patches/base/ and is now redundant — drop it so the
    # checkout does not accumulate unexplained files.
    [ -f "$TJS/native/launcher-win.cc.orig.bak" ] && rm -f "$TJS/native/launcher-win.cc.orig.bak" \
      && ok "removed the stale native/launcher-win.cc.orig.bak"
    printf '\n   next: tools/build-all.bat (Windows)  or  tools/build-launcher.sh\n'
    ;;

  restore)
    say "restoring $TJS to pristine v0.42.0"
    restore_from_base "$PATCHES/base/cli.js.orig" "$TJS/cli.js" ""
    ok "cli.js          <- pristine"
    restore_from_base "$PATCHES/base/launcher-win.cc.orig" "$TJS/native/launcher-win.cc" ""
    ok "launcher-win.cc <- pristine"
    for f in native/launcher-win.cc.orig.bak; do
      [ -e "$TJS/$f" ] && rm -f "$TJS/$f" && ok "removed $f"
    done
    printf '\n   note: build output (native/launcher-win.exe, backend.exe, app.exe,\n'
    printf '         native/winrt-shim, native/*.log) is left alone — upstream\n'
    printf '         .gitignore already covers most of it. Delete by hand if you\n'
    printf '         want a byte-clean tree.\n'
    ;;

  *)
    die "unknown command: $CMD
   usage: bash tools/bootstrap-tinyjsapp.sh [status|patch|restore] [tinyjsapp-dir]"
    ;;
esac
