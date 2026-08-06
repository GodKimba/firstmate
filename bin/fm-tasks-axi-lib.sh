# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.

FM_TASKS_AXI_MIN=0.2.4

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

# Decode one string field from tasks-axi's TOON detail output through the same
# TOON package that owns tasks-axi's scalar presentation and escape syntax.
# The field must appear exactly once at detail indentation, and malformed,
# duplicate, non-string, or otherwise ambiguous output refuses.
fm_tasks_axi_show_string() {  # <show-output> <field>
  local output=$1 field=$2 cli
  case "$field" in
    ''|*[!A-Za-z0-9_]*) return 2 ;;
  esac
  cli=${REAL_TASKS_AXI:-$(command -v tasks-axi 2>/dev/null || true)}
  [ -n "$cli" ] || return 2
  # shellcheck disable=SC2016 # JavaScript template expressions are literal input to Node.
  printf '%s\n' "$output" | node --input-type=module -e '
    import { realpathSync, readFileSync } from "node:fs";
    import { createRequire } from "node:module";
    import { pathToFileURL } from "node:url";

    const [cli, field] = process.argv.slice(1);
    const require = createRequire(pathToFileURL(realpathSync(cli)));
    const codec = await import(pathToFileURL(require.resolve("@toon-format/toon")));
    const prefix = `  ${field}: `;
    const matches = readFileSync(0, "utf8")
      .split(/\r?\n/)
      .filter((line) => line.startsWith(prefix));
    if (matches.length !== 1) process.exit(2);
    let decoded;
    try {
      decoded = codec.decode(`value: ${matches[0].slice(prefix.length)}`);
    } catch {
      process.exit(2);
    }
    if (decoded === null || typeof decoded !== "object"
        || Array.isArray(decoded) || Object.keys(decoded).length !== 1
        || typeof decoded.value !== "string") process.exit(2);
    process.stdout.write(decoded.value);
  ' "$cli" "$field" 2>/dev/null
}

fm_tasks_axi_compatible() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
