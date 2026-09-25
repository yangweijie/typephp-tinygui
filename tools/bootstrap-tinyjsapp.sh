#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Move a tinyjsapp checkout between three known states.
#
#   bash tools/bootstrap-tinyjsapp.sh status            # what state is it in?
#   bash tools/bootstrap-tinyjsapp.sh patch             # make it TypePHP-capable
#   bash tools/bootstrap-tinyjsapp.sh patch --launcher  # ...and patch the C++ too
#   bash tools/bootstrap-tinyjsapp.sh restore           # back to pristine v0.42.0
#
# Only ONE of the two patched files has to be patched in place:
#
#   cli.js               YES -- TOOL_DIR is derived from its own location
#                        (`new URL('.', import.meta.url)`), so the CLI has to run
#                        from the checkout and therefore has to be patched there.
#   launcher-win.cc      NO  -- tools/build-launcher.sh derives its own copy from
#                        patches/base/ + the patch, so the checkout's copy can
#                        stay pristine. `patch --launcher` is offered only for
#                        people who want the old in-place workflow.
#
# Because both files are rebuilt from patches/base/, the checkout is never
# hand-edited and can always be reasoned about -- `status` hashes the files and
# tells you plain which of the three states you are in.
#
#   usage: bash tools/bootstrap-tinyjsapp.sh [status|patch|restore] [tinyjsapp-dir]
#   env:   TINYJSAPP=/path/to/tinyjsapp-0.42.0
# ---------------------------------------------------------------------------
set -uo pipefail

CMD="${1:-patch}"
shift || true
WANT_LAUNCHER=0
POSARGS=()
for a in "$@"; do
  case "$a" in
    --launcher) WANT_LAUNCHER=1 ;;
    *) POSARGS+=("$a") ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TJS="${POSARGS[0]:-${TINYJSAPP:-D:/git/web/tinyjsapp-0.42.0}}"
PATCHES="$ROOT/patches"
RESIDUE="$ROOT/build/checkout-residue"

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
plain(){ printf '   %s\n' "$*"; }
warn() { printf '   !!   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*"; exit 1; }

[ -d "$TJS" ]        || die "not a directory: $TJS
   pass the checkout as arg 2, or set TINYJSAPP=/path/to/tinyjsapp-0.42.0"
[ -f "$TJS/cli.js" ] || die "no cli.js in $TJS — is this a tinyjsapp checkout?"
[ -f "$PATCHES/base/cli.js.orig" ] || die "missing $PATCHES/base/cli.js.orig"

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# restore_from_base <base> <target> [patch]
restore_from_base() {
  local base="$1" target="$2" patch="${3:-}"
  [ -f "$base" ] || die "missing base: $base"
  cp -f "$base" "$target" || die "cannot write $target"
  if [ -n "$patch" ]; then
    [ -f "$patch" ] || die "missing patch: $patch"
    ( cd "$(dirname "$target")" && patch -p0 --quiet "$(basename "$target")" < "$patch" ) \
      || die "patch did not apply cleanly: $patch"
  fi
}

# state_of <rel> <base> <patch>  ->  pristine | PATCHED | modified
state_of() {
  # NB: do not fold this into one `local a="$1" b="$a"` line. bash 5.3 expands
  # every word of a `local` before assigning any of them, so b would read an
  # unset a and `set -u` kills the script. Older bash happens to work, which
  # makes this a portability trap rather than a syntax error.
  local rel base patch t
  rel="$1"; base="$2"; patch="$3"; t="$TJS/$rel"
  [ -f "$t" ] || { printf 'MISSING'; return; }
  [ "$(sha "$t")" = "$(sha "$base")" ] && { printf 'pristine'; return; }
  local tmp
  tmp="$(mktemp -d)"
  cp -f "$base" "$tmp/x"
  if ( cd "$tmp" && patch -p0 --quiet x < "$patch" >/dev/null 2>&1 ); then
    if [ "$(sha "$t")" = "$(sha "$tmp/x")" ]; then rm -rf "$tmp"; printf 'PATCHED'; return; fi
  fi
  rm -rf "$tmp"; printf 'MODIFIED (not ours - drifted?)'
}

report_status() {
  say "checkout state — $TJS"
  printf '   %-26s %s\n' "cli.js" \
    "$(state_of cli.js "$PATCHES/base/cli.js.orig" "$PATCHES/cli-typephp.patch")"
  printf '   %-26s %s\n' "native/launcher-win.cc" \
    "$(state_of native/launcher-win.cc "$PATCHES/base/launcher-win.cc.orig" \
                "$PATCHES/launcher-win-typephp.patch")"

  local found=0
  for f in native/backend.exe native/app.exe native/winrt-shim \
           native/launcher-win.cc.orig.bak native/_build.log; do
    [ -e "$TJS/$f" ] && { printf '   %-26s ours, in the checkout\n' "$f"; found=$((found+1)); }
  done
  [ "$found" -eq 0 ] && printf '   %-26s %s\n' "(our artifacts)" "none in the checkout"
  return 0
}

case "$CMD" in
  status) report_status ;;

  patch)
    say "patching $TJS"
    restore_from_base "$PATCHES/base/cli.js.orig" "$TJS/cli.js" "$PATCHES/cli-typephp.patch"
    ok "cli.js                  <- base + cli-typephp.patch  (required in place)"
    if [ "$WANT_LAUNCHER" -eq 1 ]; then
      restore_from_base "$PATCHES/base/launcher-win.cc.orig" "$TJS/native/launcher-win.cc" \
                        "$PATCHES/launcher-win-typephp.patch"
      ok "native/launcher-win.cc  <- base + launcher-win-typephp.patch  (--launcher)"
    else
      # Leave it pristine: tools/build-launcher.sh compiles its own derived copy.
      [ -f "$PATCHES/base/launcher-win.cc.orig" ] \
        && cp -f "$PATCHES/base/launcher-win.cc.orig" "$TJS/native/launcher-win.cc" \
        && ok "native/launcher-win.cc  <- pristine (unused: we build out-of-tree)"
    fi
    [ -f "$TJS/native/launcher-win.cc.orig.bak" ] && rm -f "$TJS/native/launcher-win.cc.orig.bak" \
      && ok "removed the stale native/launcher-win.cc.orig.bak"

    # Keep the checkout's launcher BINARY newer than its now-pristine source.
    #
    # cli.js has a dev-checkout convenience (ensureLauncherFresh, "dev" checkouts
    # with no VERSION file): if native/launcher-win.cc is newer than
    # native/launcher-win.exe it re-runs setup.ps1 before `tinyjs dev`. Restoring
    # the .cc above is exactly what makes it look newer -- and that rebuild cannot
    # work here: upstream's setup.ps1 expects the Windows SDK's WinRT headers,
    # while our MinGW overlay lives in build/winrt-shim on purpose. Left alone,
    # the first `tinyjs dev --typephp` dies with
    #   native/launcher-win.cc:71: fatal error: windows.data.xml.dom.h: No such file
    # So: install our own (equally valid) build, then bump its mtime past the .cc.
    if [ -f "$ROOT/build/launcher-win.exe" ]; then
      cp -f "$ROOT/build/launcher-win.exe" "$TJS/native/launcher-win.exe"
      touch "$TJS/native/launcher-win.exe"
      ok "native/launcher-win.exe  <- our build (fresh mtime: no auto-rebuild)"
    elif [ -f "$TJS/native/launcher-win.exe" ]; then
      touch "$TJS/native/launcher-win.exe"
      ok "native/launcher-win.exe  <- touched (suppresses the auto-rebuild)"
    else
      warn "no native/launcher-win.exe — 'tinyjs dev' will try setup.ps1 here and"
      warn "fail on MinGW. Run tools/build-launcher.sh --install instead."
    fi

    # The shim has to live here too, and that is not optional: the patched CLI
    # hard-codes TOOL_DIR + 'native/backend.exe' for both
    #   `tinyjs dev --typephp`   (the launcher spawns it as its backend) and
    #   `tinyjs build --typephp` (it doubles as the packaged entry, shipped
    #                             renamed to <name>.exe)
    # 128 KB, and it is the one binary upstream's layout expects to find here.
    if [ -f "$ROOT/build/backend_shell.exe" ]; then
      cp -f "$ROOT/build/backend_shell.exe" "$TJS/native/backend.exe"
      ok "native/backend.exe       <- our shim (required by dev + build)"
    else
      warn "no build/backend_shell.exe — run tools/build-all.bat, then re-run patch"
    fi
    # NOT installed: native/app.exe. The PHP backend is per-project; the demo
    # points at its own via "typephp".app in tinyjs.json.
    plain ""
    plain "next: tools/build-all.bat            (Windows: shim + PHP backend)"
    plain "      tools/build-launcher.sh        (launcher -> build/runtime/)"
    ;;

  restore)
    say "restoring $TJS to pristine v0.42.0"
    restore_from_base "$PATCHES/base/cli.js.orig" "$TJS/cli.js"
    ok "cli.js                  <- pristine"
    restore_from_base "$PATCHES/base/launcher-win.cc.orig" "$TJS/native/launcher-win.cc"
    ok "native/launcher-win.cc  <- pristine"

    # Our artifacts — upstream's setup never creates these. Moved, not deleted.
    moved=0
    for f in native/launcher-win.cc.orig.bak native/backend.exe native/app.exe \
             native/winrt-shim native/_build.log native/_syntax.log native/_syntax_i.log; do
      if [ -e "$TJS/$f" ]; then
        mkdir -p "$RESIDUE/$(dirname "$f")"
        mv -f "$TJS/$f" "$RESIDUE/$f" && ok "moved out: $f" && moved=$((moved+1))
      fi
    done
    [ "$moved" -eq 0 ] && plain "= nothing of ours was in the checkout"

    plain ""
    plain "kept on purpose — upstream's own build products, already gitignored there:"
    for f in native/launcher-win.exe native/tiny_client.h native/include/WebView2.h; do
      [ -e "$TJS/$f" ] && plain "  $f"
    done
    plain ""
    plain "next: bash tools/bootstrap-tinyjsapp.sh patch    (to use it again)"
    ;;

  *)
    die "unknown command: $CMD
   usage: bash tools/bootstrap-tinyjsapp.sh [status|patch|restore] [--launcher] [tinyjsapp-dir]"
    ;;
esac
