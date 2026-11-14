#!/usr/bin/env bash
# Pre-Cutover Backup gate: a manual restic run from the Arch box into the two repositories the NixOS
# timers will continue in: the Scaleway bucket (off-site) and a local repository on the Data disk
# (/mnt/tbssd/restic-local, the optiplex-local job in services/restic.nix). Both get the same stage and the
# same excludes. The Cutover does not start until the restore of the bucket snapshot succeeded
# (see "The pre-Cutover gate" in infra/scaleway/README.md).
#
# Runs on Arch as root, with restic (pacman), sqlite3 and the PostgreSQL 18 client installed. Not part of
# the NixOS config. The Cutover runbook runs it again with the final dumps (--final).
#
#   arch-gate.sh --env-file /root/restic-gate.env [--init] [--local-only] [--final] [--dry-run] [--keep-env]
#
# The env file holds the decrypted secrets (root-only, deleted by this script at exit unless --keep-env).
# Make it on the PC, never in the repo (README: "Making the env file"). Keys: RESTIC_REPOSITORY,
# RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION. The same RESTIC_PASSWORD
# opens the local repository, since the NixOS job uses one password for both.
#
#   --init        first run only: `restic init` in both repositories. Never done implicitly: a typo in a
#                 repository URL or path must not create a second repository. The local repository is
#                 created here, on the Data disk, so the initial copy is taken and initialised by the gate.
#   --local-only  back up to the local repository only and leave the bucket alone (the bucket snapshot
#                 2c253959 of 2026-11-10 stays the only off-site one). Use it for the initial local copy.
#   --final       the Cutover run: arch-db-dumps.sh --final (refuses while a consumer is running). It needs
#                 the DB servers up, so the Cutover runs it with every consumer stopped, the DB servers and
#                 Pi-hole still running; the DB servers are stopped only afterwards (ticket 46, decided 2026-11-14).
#   --dry-run     prepare nothing, print what would be backed up.
#
# What it backs up (--host optiplex --tag arch-gate; the bucket uploads use storage class ONEZONE_IA):
#   - the Kept services' State at its Arch locations (list below), minus the same caches and logs as the
#     NixOS job's excludes (machines/optiplex/services/restic.nix),
#   - fresh database dumps from machines/optiplex/cutover/arch-db-dumps.sh (pg_dump -Fc with the PG18
#     client from the native cluster and from the Gitea/Paperless PG14 containers, mariadb-dump of Seafile's
#     three databases, counts, MANIFEST),
#   - `sqlite3 .backup` copies of Vaultwarden, etesync and Home Assistant (the live files are excluded),
#     each checked with PRAGMA integrity_check,
#   - the host keys (ed25519 and rsa) and /mnt/tbssd/archive (.zsh_history, copied in before the wipe).
# Never the stale copies of the inventory (olddata, synapse_backup.sql, /data/compose/{33,34}/postgres,
# /vw-data, /opt/seafile/mysql/db): every source is listed by name below.
#
# Live progress: backup-progress.sh (machines/optiplex/services/restic/progress/) writes progress.json (and a
# copy of index.html) into the gate directory, /srv/http/opti.plex/gate on Arch (the opti.plex dashboard,
# assumed to serve /srv/http/opti.plex). The nightly NixOS job writes the same page after the Cutover.
# Needs jq; without jq the run goes on without the page. Publishing never stops the gate. The gate directory
# is excluded from the backup, since progress.json changes every few seconds.
#
# Test hooks (environment): GATE_PREFIX is put in front of every source path (a fake tree for a smoke
# test); GATE_STAGE_ROOT replaces /mnt/tbssd/arch-gate; GATE_SKIP_DUMPS=1 skips arch-db-dumps.sh;
# GATE_STATUS_DIR replaces the progress directory (the exclude follows it).
set -euo pipefail

ENV_FILE=""
INIT=0
LOCAL_ONLY=0
FINAL=0
DRY=0
KEEP_ENV=0

die() { echo "arch-gate: $*" >&2; exit 1; }
log() { echo ">> $*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift ;;
    --init) INIT=1 ;;
    --local-only) LOCAL_ONLY=1 ;;
    --final) FINAL=1 ;;
    --dry-run) DRY=1 ;;
    --keep-env) KEEP_ENV=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

P="${GATE_PREFIX:-}"
STAGE_ROOT="${GATE_STAGE_ROOT:-/mnt/tbssd/arch-gate}"
# The local repository, as the NixOS job's localRepository (services/restic.nix). Same password.
LOCAL_REPO="${GATE_LOCAL_REPO:-/mnt/tbssd/restic-local}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMPS_SCRIPT="$HERE/../../machines/optiplex/cutover/arch-db-dumps.sh"
CLASS=(-o s3.storage-class=ONEZONE_IA)

# Repository calls. The bucket takes the storage class; the local repository takes no backend options
# (restic rejects s3 options on a local backend). RESTIC_REPOSITORY from the env file is the bucket.
s3_restic() { restic "${CLASS[@]}" "$@"; }
local_restic() { restic -r "$LOCAL_REPO" "$@"; }

# --- live progress (optional): see the header. Never fails the gate.
PROGRESS="$HERE/../../machines/optiplex/services/restic/progress/backup-progress.sh"
GATE_DIR="${GATE_STATUS_DIR:-/srv/http/opti.plex/gate}"
export BACKUP_STATUS_DIR="$GATE_DIR"
PROGRESS_ON=0
PROGRESS_STARTED=0
if command -v jq >/dev/null; then
  PROGRESS_ON=1
else
  echo "arch-gate: jq is not installed, so no live progress page (the gate goes on)" >&2
fi
progress() { if ((PROGRESS_ON)); then "$PROGRESS" "$@"; fi; }
# stdin: restic's --json lines. Status lines go to the progress page, the rest to the terminal.
feed_progress() { if ((PROGRESS_ON)); then "$PROGRESS" feed; else cat; fi; }

[[ $EUID -eq 0 || -n ${GATE_PREFIX:-} ]] || die "run as root (the State is root-owned)"
for tool in restic sqlite3; do command -v "$tool" >/dev/null || die "$tool is not installed"; done
[[ -n $ENV_FILE && -r $ENV_FILE ]] || die "--env-file <file> is required (see --help)"

# --- the secrets: parsed, never sourced (a password may hold any character) -------------------------------
cleanup() {
  local rc=$?
  if ((rc != 0 && PROGRESS_STARTED)); then
    progress set failed "Stopped with an error (exit $rc). See the terminal on Arch."
  fi
  if ((!KEEP_ENV)) && [[ -f $ENV_FILE ]]; then
    shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
    log "deleted $ENV_FILE"
  fi
}
trap cleanup EXIT
[[ "$(stat -c %a "$ENV_FILE")" == 600 ]] || die "$ENV_FILE must be mode 0600"
while IFS= read -r line || [[ -n $line ]]; do
  [[ -z $line || $line == \#* ]] && continue
  key="${line%%=*}"
  case "$key" in
    RESTIC_REPOSITORY | RESTIC_PASSWORD | AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY | AWS_DEFAULT_REGION)
      export "$key=${line#*=}" ;;
    *) die "unexpected key $key in the env file" ;;
  esac
done <"$ENV_FILE"
for k in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
  [[ -n ${!k:-} ]] || die "$k is missing in the env file"
done

# --- sources -------------------------------------------------------------------------------------------------------
GITEA="$P/mnt/tbssd/docker/volumes/gitea_data/_data"
VW="$P/mnt/tbssd/docker/volumes/vaultwarden_data/_data"
HA="$P/srv/homeassistant"
ETE="$P/srv/etesync"
SEAFILE="$P/mnt/tbssd/filesync/seafile"
PAPERLESS_DATA="$P/mnt/tbssd/docker/volumes/paperless_data/_data"
PAPERLESS_MEDIA="$P/mnt/tbssd/docker/volumes/paperless_media/_data"

# State and keys. Every path must exist: a missing source is a mistake, not something to skip.
SOURCES=(
  "$P/var/lib/synapse/media_store"
  "$GITEA/git/repositories" "$GITEA/git/lfs"
  "$GITEA/gitea/attachments" "$GITEA/gitea/avatars" "$GITEA/gitea/repo-avatars" "$GITEA/gitea/actions_log"
  "$SEAFILE/conf" "$SEAFILE/ccnet" "$SEAFILE/seafile-data" "$SEAFILE/seahub-data"
  "$PAPERLESS_DATA" "$PAPERLESS_MEDIA"
  "$VW"
  "$HA"
  "$ETE/etebase/secret.txt" "$ETE/etebase/etebase-server.ini" "$ETE/media"
  "$P/root/.local/share/etesync-dav/etesync_creds" "$P/root/.local/share/etesync-dav/htpaswd"
  "$P/var/lib/transmission/.config/transmission-daemon"
  "$P/srv/http/immo.nnik.dev" "$P/srv/http/koke.nnik.dev" "$P/srv/http/www.ya.nnik.dev" "$P/srv/http/opti.plex"
  "$P/etc/ssh/ssh_host_ed25519_key" "$P/etc/ssh/ssh_host_ed25519_key.pub"
  "$P/etc/ssh/ssh_host_rsa_key" "$P/etc/ssh/ssh_host_rsa_key.pub"
  "$P/mnt/tbssd/archive"
)

# live SQLite database -> name of its copy
declare -A SQLITE=(
  [vaultwarden]="$VW/db.sqlite3"
  [etesync]="$ETE/etebase/db.sqlite3"
  [homeassistant]="$HA/home-assistant_v2.db"
)

# Excludes: the NixOS job's lists, translated to the Arch paths, plus the live SQLite files.
EXCLUDES=(
  "$P/var/lib/synapse/media_store/url_cache*"
  "$P/var/lib/synapse/media_store/remote_content" "$P/var/lib/synapse/media_store/remote_thumbnail"
  "$P/var/lib/synapse/media_store/local_thumbnails"
  "$GITEA/gitea/packages" "$GITEA/gitea/sessions" "$GITEA/gitea/indexers" "$GITEA/gitea/queues"
  "$GITEA/gitea/tmp" "$GITEA/gitea/repo-archive"
  "$SEAFILE/seahub-data/thumbnail" "$SEAFILE/logs" "$SEAFILE/conf/__pycache__"
  "$PAPERLESS_DATA/index" "$PAPERLESS_DATA/log"
  "$VW/icon_cache" "$VW/tmp"
  "$HA/home-assistant.log*" "$HA/.cache" "$HA/.ha_run.lock" "$HA/deps" "$HA/tts"
  "$GATE_DIR"   # the progress page itself, inside opti.plex
)
for live in "${SQLITE[@]}"; do
  EXCLUDES+=("$live" "$live-wal" "$live-shm" "$live-journal")
done

for s in "${SOURCES[@]}"; do
  [[ -e $s ]] || die "source $s does not exist (a typo, or the service moved)"
done
for live in "${SQLITE[@]}"; do
  [[ -f $live ]] || die "SQLite database $live does not exist"
done

if ((DRY)); then
  echo "repositories:"
  ((LOCAL_ONLY)) || echo "  bucket: ${RESTIC_REPOSITORY}"
  echo "  local:  $LOCAL_REPO"
  echo "would back up:"
  printf '  %s\n' "${SOURCES[@]}" "  + fresh dumps, SQLite copies in $STAGE_ROOT/<timestamp>/"
  echo "excluding:"
  printf '  %s\n' "${EXCLUDES[@]}"
  trap - EXIT
  exit 0
fi

PROGRESS_STARTED=1
progress init
progress set starting "Checking the repository"

# --- the repositories ------------------------------------------------------------------------------------------------
# The local one lives on the Data disk. Without the mount, restic would create the repository on the System
# disk, so the gate refuses. (A test run with GATE_LOCAL_REPO set skips the check.)
if [[ -z ${GATE_LOCAL_REPO:-} ]]; then
  mountpoint -q /mnt/tbssd || die "/mnt/tbssd is not mounted: the local repository would land on the System disk"
fi
if ((INIT)); then
  log "restic init (first run): local $LOCAL_REPO"
  local_restic init
  if ((!LOCAL_ONLY)); then
    log "restic init (first run): bucket"
    s3_restic init
  fi
else
  local_restic cat config >/dev/null || die "the local repository $LOCAL_REPO does not exist: re-run with --init for the very first run"
  ((LOCAL_ONLY)) || s3_restic cat config >/dev/null || die "the repository does not exist or is unreachable: re-run with --init only for the very first run, and check RESTIC_REPOSITORY"
fi

# --- stage: dumps and SQLite copies ----------------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$STAGE_ROOT/$STAMP"
install -d -m 0700 "$STAGE" "$STAGE/sqlite"

if [[ -z ${GATE_SKIP_DUMPS:-} ]]; then
  [[ -x $DUMPS_SCRIPT ]] || die "$DUMPS_SCRIPT not found: run this from a checkout of the repository"
  log "database dumps"
  progress set dumps "Dumping the databases"
  final_arg=()
  ((FINAL)) && final_arg=(--final)
  "$DUMPS_SCRIPT" "${final_arg[@]}" --out-root "$STAGE/dumps"
fi

log "SQLite copies"
progress set sqlite "Copying the SQLite databases"
for name in "${!SQLITE[@]}"; do
  live="${SQLITE[$name]}"
  sqlite3 -cmd '.timeout 60000' "$live" ".backup '$STAGE/sqlite/$name.sqlite3'"
  chk="$(mktemp)"
  cp "$STAGE/sqlite/$name.sqlite3" "$chk"
  result="$(sqlite3 "$chk" 'PRAGMA integrity_check')"
  rm -f "$chk" "$chk-wal" "$chk-shm"
  [[ $result == ok ]] || die "the copy of $live fails PRAGMA integrity_check: $result"
  echo "  $name ok"
done

# A manifest to verify the restore against: checksums of the copies and keys, file counts of the trees.
{
  echo "# arch-gate $STAMP (final=$FINAL)"
  (cd "$STAGE" && sha256sum sqlite/*.sqlite3)
  sha256sum "$P"/etc/ssh/ssh_host_{ed25519,rsa}_key{,.pub}
  for s in "${SOURCES[@]}"; do
    [[ -d $s ]] && printf 'files %s %s\n' "$(find "$s" -type f ! -path "$GATE_DIR/*" | wc -l)" "$s"
  done
} >"$STAGE/GATE-MANIFEST"

# --- the backup --------------------------------------------------------------------------------------------------------
EXCLUDE_FILE="$(mktemp)"
printf '%s\n' "${EXCLUDES[@]}" >"$EXCLUDE_FILE"
# The local copy goes first: it needs no network, so it is complete even when the upload fails afterwards.
log "restic backup to the local repository (tag arch-gate)"
progress set local "Copying to the local repository on the Data disk"
local_restic backup --host optiplex --tag arch-gate --exclude-file="$EXCLUDE_FILE" "${SOURCES[@]}" "$STAGE"
if ((!LOCAL_ONLY)); then
  log "restic backup to the bucket (tag arch-gate)"
  progress set backup "Starting the upload"
  # pipefail: a failed restic still fails the gate; the feed never fails
  s3_restic backup --json --host optiplex --tag arch-gate --exclude-file="$EXCLUDE_FILE" \
    "${SOURCES[@]}" "$STAGE" | feed_progress
fi
rm -f "$EXCLUDE_FILE"

log "snapshots tagged arch-gate"
progress set snapshots "Listing the snapshots"
local_restic snapshots --tag arch-gate
((LOCAL_ONLY)) || s3_restic snapshots --tag arch-gate
if ((LOCAL_ONLY)); then
  progress set "done" "Local copy finished (the bucket was not touched). The check steps are in the terminal on Arch."
else
  progress set "done" "Upload finished. The check steps are in the terminal on Arch."
fi
if ((LOCAL_ONLY)); then
  cat <<EOF

Next:
  1. Local copy: restic -r $LOCAL_REPO snapshots --tag arch-gate
     The bucket was not touched: its snapshot stays as it is (see infra/scaleway/README.md).
  2. The stage directory $STAGE stays on the Data disk until the Cutover is done.
EOF
else
  cat <<EOF

Next:
  0. Local copy: restic -r $LOCAL_REPO snapshots --tag arch-gate (the Data disk; the bucket is checked below)
  1. Storage class: the new objects must show One Zone (console: Object Storage, bucket, objects), or
       aws --endpoint-url https://s3.fr-par.scw.cloud s3api head-object --bucket nnik-optiplex-restic --key <key from: restic list packs | head -1 | sed 's|^|data/|'>
     -> "StorageClass": "ONEZONE_IA"
  2. Restore check in the VM harness: infra/scaleway/README.md, "The pre-Cutover gate".
  3. The stage directory $STAGE stays on the Data disk until the Cutover is done.
EOF
fi
