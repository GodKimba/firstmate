#!/usr/bin/env bash
# Shared primary-home predicate for tracked hooks that must act only in a genuine
# firstmate primary home: the main home or a persistent secondmate home, both of
# which operate a fleet.
# This file is sourced by hook entrypoints and has no side effects on source.
#
# LAUNCH IDENTITY is the authoritative signal, checked first and owned here.
# bin/fm-spawn.sh stamps FM_CREW_TASK=<task-id> onto the launch command of every
# ordinary kind=ship and kind=scout direct report, and clears it for a
# --secondmate launch, so the variable states positively what firstmate launched
# this process as. An ordinary worker is never a primary no matter what its
# checkout looks like.
#
# Why an explicit signal rather than checkout shape alone: the historical test
# below (a "plain checkout" is primary, a linked git worktree is not) infers role
# from filesystem shape, and that inference has two holes when the worker's own
# project IS this repo. A worktree provider that hands back a full clone rather
# than a linked worktree makes git-dir equal git-common-dir, and the effective
# state directory is resolved from an inherited FM_HOME that can name a real
# coordinator home while FM_ROOT names the worker's own copy. Either one lets a
# worker read as a primary, at which point Pi auto-loads this repo's tracked
# primary extensions from the trusted worker checkout and the coordinator
# startup instruction reaches an implementation worker. FM_CREW_TASK closes both
# because it does not depend on paths, prompts, lock outcomes, or pane names.
#
# The shape test is retained beneath it as the backstop for a worker whose
# environment lost the variable.

# Return 0 when this process was launched as an ordinary firstmate crewmate
# (kind=ship or kind=scout).
#
# A NON-EMPTY value is the identity; empty is deliberately NOT the identity. A
# launch-line assignment can only clear a variable by setting it empty
# (`FM_CREW_TASK= pi ...`), which is exactly how a secondmate coordinator sheds
# an ambient identity inherited from the pane that spawned it. Keying on presence
# alone would read that clear as a worker and silently strip every secondmate's
# own startup nudge.
fm_launched_as_crewmate() {
  [ -n "${FM_CREW_TASK:-}" ]
}

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# An ordinary crewmate launch identity refuses first and unconditionally, so a
# worker is never a primary even when its checkout looks like one.
# A valid secondmate marker then force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  fm_launched_as_crewmate && return 1
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
