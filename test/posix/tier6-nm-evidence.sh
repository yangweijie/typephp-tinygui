#!/usr/bin/env bash
# Generate the [4b]/[4c] link-gap evidence for tier 6, inside the container.
# Everything here is a measurement over the composed nano object sets; no claim is
# restated from the driver's own output.
#
# COLD-DIR RULE: this reads whatever object sets are in $W. If an experiment patched
# the vendor tree and rebuilt in place, the counts here describe THAT build, not the
# driver run you mean (Phase 25 hit exactly this: a local php::Args::get patch left
# 242 objects with define=[variant-*.o] where the cold Phase 24 run had 240 and
# define=[]). Re-run test/posix/tier6-nano-aggregate.sh from a cold /tmp/tpgui-tier6
# first, or pass WORK=/some/other/dir.
set -u
W="${WORK:-/tmp/tpgui-tier6}"
BIG="${BIG:-$W/nanobuild}"
CTRL="${CTRL:-$W/ctrlbuild}"
OUT="$W/closure-nm.txt"

scan_refs() {   # <objects-dir> -> object names that reference php::Args::get
  find "$1" -name '*.o' -print0 | while IFS= read -r -d '' o; do
    if nm -C --undefined-only "$o" 2>/dev/null | grep -q 'php::Args::get(unsigned long) const'; then
      basename "$o"
    fi
  done
}

scan_defs() {   # <objects-dir> -> object names that DEFINE php::Args::get
  find "$1" -name '*.o' -print0 | while IFS= read -r -d '' o; do
    if nm -C --defined-only "$o" 2>/dev/null | grep -q 'php::Args::get(unsigned long) const'; then
      basename "$o"
    fi
  done
}

{
  echo "# tier-6 link-gap evidence — generated $(date -u +%Y-%m-%dT%H:%M:%SZ) inside container tgl"
  echo "# toolchain: $(g++ --version | head -1) | $(ld --version | head -1)"
  echo "# phpx: $(grep -m1 '\"version\"' /work/tpc/vendor/swoole/phpx/composer.json 2>/dev/null || echo '?')"
  echo "# provenance: ${PROV_NOTE:-built from the object sets/logs the last tier-6 driver run left in $W}"
  echo
  echo "== php::Args::get over the composed nano object sets"
  for b in "$BIG" "$CTRL"; do
    d="$b/cache/objects"
    printf '  %s: objects=%s define=[%s] reference=[%s]\n' \
      "$(basename "$b")" "$(find "$d" -name '*.o' | wc -l)" \
      "$(scan_defs "$d" | tr '\n' ' ')" "$(scan_refs "$d" | tr '\n' ' ')"
  done
  echo
  echo "== the closure translation unit in both builds (same content hash => same TU)"
  for b in "$BIG" "$CTRL"; do
    ls "$b"/cache/objects/nano/closure-*.o 2>/dev/null | while read -r o; do
      printf '  %s %s\n' "$(sha256sum "$o" | cut -c1-16)" "$(basename "$o")"
    done
  done
  echo
  echo "== what the linker said (aggregate build log)"
  grep -m1 -B1 "undefined reference to .php::Args::get" "$W/nano-agg.log" | sed 's/^/  /'
  echo
  echo "== what the control build log ends with"
  tail -2 "$W/nano-ctrl.log" | sed 's/^/  /'
  echo
  echo "== the control binary runs"
  "$W/app-ctrl"; echo "  rc=$?"
  echo
  echo "== composed nano runtime module set (which extensions each build keeps alive)"
  for b in "$BIG" "$CTRL"; do
    printf '  %s: %s\n' "$(basename "$b")" \
      "$(grep -o '&[a-z_]*_m\(odule_entry\|odule\)' "$b/composer_extensions.cpp" 2>/dev/null | tr -d '&' | tr '\n' ' ')"
  done
  echo "  (# These are C *variables*; a dependency string is matched against an entry's ->name field."
  echo "  #  basic_functions_module is named \"standard\" (ext/standard/basic_functions.c), and the ONLY"
  echo '  #  module named "Core" is a static zend_module_entry (zend_builtin_module) in'
  echo "  #  Zend/zend_builtin_functions.c — static, so no generated composer array can reference it."
  echo "  #  ⇒ keeping basic_functions does NOT make ZEND_MOD_REQUIRED(\"Core\") satisfiable: any build"
  echo "  #  that declares that dep dies at startup (\"Unable to start PHP Nano extensions\"), the"
  echo "  #  aggregate included. Its own deps are printed next; measured in"
  echo "  #  evidence/linux/25-deps-vs-modules.txt. [4d] below is the minimal case.)"
  for b in "$BIG" "$CTRL"; do
    [ -d "$b" ] || continue
    printf '  %s generated deps: %s\n' "$(basename "$b")" \
      "$(grep -h -o 'ZEND_MOD_REQUIRED("[A-Za-z_]*")' "$b"/extension-*.cc 2>/dev/null | sort -u | tr '\n' ' ')"
  done
  echo
  echo "== [4d] the startup probe: three lines of PHP that link and still cannot start"
  TRAPD="$W/trapbuild"
  if [ -f "$TRAPD/composer_extensions.cpp" ]; then
    echo "  module set  : $(grep -o '&[a-z_]*_m\(odule_entry\|odule\)' "$TRAPD/composer_extensions.cpp" | tr -d '&' | tr '\n' ' ')"
    echo "  generated dep: $(grep -h ZEND_MOD_REQUIRED "$TRAPD"/extension-*.cc | tr -s ' ')"
    echo "  build outcome: $(tail -1 "$W/nano-trap.log")"
    "$W/app-trap"; echo "  startup rc=$?"
  else
    echo "  (no $TRAPD — run test/posix/tier6-nano-aggregate.sh; its [4d] step produces it)"
  fi
} > "$OUT" 2>&1
wc -c "$OUT"
cat "$OUT"
