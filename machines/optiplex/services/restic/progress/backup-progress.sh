#!/usr/bin/env bash
# Live progress of a Backup run, for the progress page (index.html next to this script, served as
# gate.opti.plex). Two callers: arch-gate.sh (the pre-Cutover gate, on Arch) and the nightly NixOS job
# (services/restic.nix, which wraps restic and runs this script through optiplex-backup-progress).
# Can be run by hand to test. Publishing never fails the caller: problems go to stderr and the exit
# status stays 0, so a broken progress page cannot stop the Backup.
#
#   backup-progress.sh init                       create the status directory and copy in the page
#   backup-progress.sh set <phase> [message]      write a phase change (phases: starting, dumps, sqlite,
#                                                 local, backup, snapshots, done, failed)
#   backup-progress.sh feed                       read `restic backup --json` on stdin, publish its status
#                                                 lines at most every 2 s; every other line goes to stdout
#
# The published file (progress.json) holds phase, message and the numbers restic reports. No paths, no
# secrets. Needs jq. Environment: BACKUP_STATUS_DIR replaces the status directory (default: the Arch
# gate directory), BACKUP_PAGE_SRC replaces the page that `init` copies in.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${BACKUP_STATUS_DIR:-/srv/http/opti.plex/gate}"
PAGE_SRC="${BACKUP_PAGE_SRC:-$HERE/index.html}"
THROTTLE=2

warn() { echo "backup-progress: $* (progress not published, the backup goes on)" >&2; }

# stdin: one JSON object. Replaces progress.json atomically, so the page never reads half a file.
# Empty input (a failed jq) keeps the last good file.
publish() {
  local body tmp
  body="$(cat)"
  [[ -n $body ]] || return 0
  tmp="$(mktemp "$DIR/.progress.XXXXXX")" || { warn "cannot create a temporary file in $DIR"; return 0; }
  if printf '%s\n' "$body" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$DIR/progress.json"; then
    return 0
  fi
  rm -f "$tmp"
  warn "cannot write $DIR/progress.json"
  return 0
}

now() { date +%s; }

cmd_init() {
  if ! { install -d -m 0755 "$DIR" && install -m 0644 "$PAGE_SRC" "$DIR/index.html"; } 2>/dev/null; then
    warn "cannot prepare $DIR (is it writable by root?)"
  fi
  return 0
}

cmd_set() {
  local phase="${1:?set needs a phase}" message="${2:-}"
  jq -cn --arg phase "$phase" --arg message "$message" --argjson updated "$(now)" \
    '{phase: $phase, message: $message, updated: $updated, percent: null, bytes_done: null, total_bytes: null,
      files_done: null, total_files: null, seconds_elapsed: null, seconds_remaining: null}' 2>/dev/null \
    | publish
  return 0
}

cmd_feed() {
  local line last=0 t
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *'"message_type":"status"'* ]]; then
      t="$(now)"
      ((t - last < THROTTLE)) && continue
      last=$t
      # restic reports percent_done as a fraction of 1 and may omit fields early on
      jq -cn --argjson r "$line" --argjson updated "$t" '{
          phase: "backup", message: "Uploading to Scaleway", updated: $updated,
          percent: (if $r.percent_done == null then null else ($r.percent_done * 100 | floor) end),
          bytes_done: ($r.bytes_done // null), total_bytes: ($r.total_bytes // null),
          files_done: ($r.files_done // null), total_files: ($r.total_files // null),
          seconds_elapsed: ($r.seconds_elapsed // null), seconds_remaining: ($r.seconds_remaining // null)}' \
        2>/dev/null | publish
    elif [[ $line == *'"message_type":"summary"'* ]]; then
      # The last line of a finished backup: the totals, so the bar ends at 100 % before the pruning.
      jq -cn --argjson r "$line" --argjson updated "$(now)" '{
          phase: "backup", message: "Upload complete", updated: $updated, percent: 100,
          bytes_done: ($r.total_bytes_processed // null), total_bytes: ($r.total_bytes_processed // null),
          files_done: ($r.total_files_processed // null), total_files: ($r.total_files_processed // null),
          seconds_elapsed: ($r.total_duration // null), seconds_remaining: 0}' \
        2>/dev/null | publish
      printf '%s\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done
  return 0
}

case "${1:-}" in
  init) cmd_init ;;
  set) shift; cmd_set "$@" ;;
  feed) cmd_feed ;;
  *) echo "usage: backup-progress.sh init | set <phase> [message] | feed" >&2; exit 2 ;;
esac
exit 0
