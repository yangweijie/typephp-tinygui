#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Locate the typephp-gui repo root from anywhere inside it.
#
# Why this exists: this kit has two supported homes, and both must work.
#
#   1. In-tree          <repo>/test/posix/       sources live at
#                                                <repo>/shim/backend_shell.cpp
#                                                <repo>/src/backend.php
#   2. Standalone       <somewhere>/posix-test/  the kit is copied out of the
#                                                repo and shipped on its own
#                                                (it is synced into the
#                                                tinyjsapp-typephp-bridge
#                                                skill), with backend_shell.cpp
#                                                sitting right beside it.
#
# Hard-coding `../backend_shell.cpp` breaks home (1); hard-coding the repo
# path breaks home (2). So: detect, then fall back.
#
# Marker: composer.json. It is the one file guaranteed to sit at the repo root
# and nowhere else, so a walk up the tree cannot stop too early.
# ---------------------------------------------------------------------------

# typephp_repo_root <start-dir>  ->  prints the repo root, or nothing.
typephp_repo_root() {
  local d="${1:-$PWD}"
  # Resolve to an absolute path first so the walk terminates predictably.
  d="$(cd "$d" 2>/dev/null && pwd)" || return 1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/composer.json" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

# typephp_locate <kit-dir>  ->  sets these in the caller's scope:
#   TP_ROOT          repo root, or "" when the kit is standalone
#   TP_SHIM_SRC      backend_shell.cpp
#   TP_BACKEND_DEF   default backend.php for tier 2 / the stderr probe
typephp_locate() {
  local kit="$1"
  TP_ROOT="$(typephp_repo_root "$kit" || true)"
  if [ -n "$TP_ROOT" ]; then
    TP_SHIM_SRC="$TP_ROOT/shim/backend_shell.cpp"
    TP_BACKEND_DEF="$TP_ROOT/src/backend.php"
  else
    # Standalone: the shim and the default backend are the kit's neighbours.
    TP_SHIM_SRC="$kit/../backend_shell.cpp"
    TP_BACKEND_DEF="$kit/../backend.php"
  fi
}
