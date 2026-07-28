#!/usr/bin/env bash
# Shared gh-axi compatibility probe for bootstrap and GitHub mutation boundaries.
# Usage: . bin/fm-gh-axi-lib.sh
# Compatible means gh-axi --version reports 0.1.28 or newer and
# `gh-axi api --help` advertises --jq.

FM_GH_AXI_MIN_MAJOR=0
FM_GH_AXI_MIN_MINOR=1
FM_GH_AXI_MIN_PATCH=28

fm_gh_axi_min_version() {
  printf '%s\n' 0.1.28
}

fm_gh_axi_version_parts() {
  local output
  command -v gh-axi >/dev/null 2>&1 || return 1
  output=$(gh-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1
}

fm_gh_axi_api_supports_jq() {
  local output
  output=$(gh-axi api --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -Eq '(^|[^[:alnum:]_-])--jq([^[:alnum:]_-]|$)'
}

fm_gh_axi_compatible() {
  local parts major minor patch extra
  parts=$(fm_gh_axi_version_parts) || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  if [ "$major" -gt "$FM_GH_AXI_MIN_MAJOR" ]; then
    :
  elif [ "$major" -lt "$FM_GH_AXI_MIN_MAJOR" ]; then
    return 1
  elif [ "$minor" -gt "$FM_GH_AXI_MIN_MINOR" ]; then
    :
  elif [ "$minor" -lt "$FM_GH_AXI_MIN_MINOR" ]; then
    return 1
  elif [ "$patch" -lt "$FM_GH_AXI_MIN_PATCH" ]; then
    return 1
  fi
  fm_gh_axi_api_supports_jq
}
