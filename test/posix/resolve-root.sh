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
#
# It also owns the two other "which home am I in?" policies every script needs:
# where scratch goes (typephp_default_work) and where the AF_UNIX socket can
# legally live (typephp_socket_path). Keeping them here rather than in each
# script is what makes `standalone must behave like in-tree` a single rule.
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

# ---------------------------------------------------------------------------
# typephp_default_work <kit-dir>  ->  sets TP_WORK
#
# The two homes want different scratch locations, and this is the same
# "standalone must not dirty what it ships" rule as typephp_locate:
#
#   in-tree     <kit>/.work          a normal build dir inside the repo; the
#                                    repo's .gitignore already covers it.
#   standalone  $TMPDIR/typephp-kit.XXXXXX
#                                    the kit ships INSIDE a skill under the user
#                                    profile. A copy that writes into its own
#                                    directory the moment it runs can no longer
#                                    be diffed against the original to prove the
#                                    two are in sync -- and it was exactly such
#                                    a diff that missed a stale copy once. So
#                                    scratch goes to a disposable temp dir, and
#                                    every script prints the path it used.
#
# Short by construction, which is what keeps the socket path under sun_path
# (see below) without a second temp dir in the normal case.
#
# An explicit WORK= wins and short-circuits both branches. That check is not
# just economy: all.sh exports WORK to its children, and a "default" that made
# a temp dir regardless left one *empty* temp dir per tier per run (nine of
# them, abandoned) because each child resolved a default it was never going to
# use.
typephp_default_work() {
  local kit="$1" d
  if [ -n "${WORK:-}" ]; then
    TP_WORK="$WORK"
    return 0
  fi
  if [ -n "${TP_ROOT:-}" ]; then
    TP_WORK="$kit/.work"
    return 0
  fi
  d="$(mktemp -d "${TMPDIR:-/tmp}/typephp-kit.XXXXXX" 2>/dev/null)" || d=""
  TP_WORK="${d:-$kit/.work}"
}

# ---------------------------------------------------------------------------
# typephp_socket_path <work-dir>  ->  sets in the caller's scope:
#     TP_SOCK       a socket path that fits sun_path
#     TP_SOCK_TMP   an extra temp dir it had to create, or "" when it reused
#                   <work-dir>
#
# A unix socket path is capped at ~108 bytes (sun_path) on Linux/Cygwin and 104
# on macOS. `$WORK/app.sock` looks harmless, but $WORK used to hang off the kit
# directory, and the kit ships inside a skill under the user profile:
#
#   /cygdrive/c/Users/<u>/.workbuddy/skills/<skill>/scripts/posix-test/.work/app.sock
#
# is 108 characters exactly -> bind() fails -> the runner reports the very
# unhelpful "socket never appeared", while the same kit passes in-tree purely
# because the repo path happens to be shorter. A nasty way to find out, and the
# reason `typephp_default_work` above exists. This function is the belt to that
# pair of braces: WORK can still be set from the environment to anything.
#
# Sets variables instead of printing: `SOCK="$(typephp_socket_path ...)"` would
# run in a subshell and TP_SOCK_TMP would be lost with it.
typephp_socket_path() {
  local work="$1" sock d
  TP_SOCK_TMP=""
  sock="$work/app.sock"
  if [ "${#sock}" -le 100 ]; then
    TP_SOCK="$sock"
    return 0
  fi
  d="$(mktemp -d "${TMPDIR:-/tmp}/tpkit.XXXXXX" 2>/dev/null)" || d=""
  if [ -n "$d" ] && [ -d "$d" ]; then
    TP_SOCK_TMP="$d"
    TP_SOCK="$d/app.sock"
  else
    TP_SOCK="$sock"        # last resort: the old behaviour
    # Do not fail silently -- a too-long path is the whole reason this exists.
    printf 'warning: no writable temp dir; socket path is %d bytes (limit ~108) and may fail: %s\n' \
           "${#TP_SOCK}" "$TP_SOCK" >&2
  fi
}

# Release whatever typephp_socket_path had to set up. No-op in the common case,
# where the socket lives in $WORK and runs to completion there.
typephp_socket_cleanup() {
  if [ -n "${TP_SOCK_TMP:-}" ] && [ -d "${TP_SOCK_TMP:-}" ]; then
    rm -rf "$TP_SOCK_TMP"
  fi
  return 0
}
