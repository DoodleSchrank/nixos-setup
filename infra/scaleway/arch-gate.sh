#!/usr/bin/env bash
# Pre-Cutover Backup gate: a manual restic run from the Arch box into the same repository the NixOS
# timer will continue in. The Cutover does not start until the restore of this snapshot succeeded
# (see "The pre-Cutover gate" in infra/scaleway/README.md).
#
# Runs on Arch as root, with restic (pacman), sqlite3 and the PostgreSQL 18 client installed. Not part of
# the NixOS config. The Cutover runbook runs it again with the final dumps (--final).
#
#   arch-gate.sh --env-file /root/restic-gate.env [--init] [--final] [--dry-run] [--keep-env]
#
# The env file holds the decrypted secrets (root-only, deleted by this script at exit unless --keep-env).
# Make it on the PC, never in the repo (README: "Making the env file"). Keys: RESTIC_REPOSITORY,
# RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION.
#
#   --init     first run only: `restic init`. Never done implicitly: a typo in the repository URL must
#              not create a second repository.
#   --final    the Cutover run: arch-db-dumps.sh --final (refuses while a consumer is running).
#   --dry-run  prepare nothing, print what would be backed up.
#
# What it backs up (--host optiplex --tag arch-gate, storage class ONEZONE_IA on every upload):
#   - the Kept services' State at its Arch locations (list below), minus the same caches and logs as the
#     NixOS job's excludes (machines/optiplex/services/restic.nix),
#   - fresh database dumps from machines/optiplex/cutover/arch-db-dumps.sh (pg_dump -Fc with the PG18
#     client from the native cluster and from the Gitea/Paperless PG14 containers, mariadb-dump of Seafile's
#     three databases, counts, MANIFEST),
#   - `sqlite3 .backup` copies of Vaultwarden, etesync and Home Assistant (the live files are excluded),
#     each checked with PRAGMA integrity_check,
#   - the host keys (ed25519 and rsa) and /mnt/tbssd/archive (put the final elabFTW export into
#     /mnt/tbssd/archive/elabftw/ before the run).
# Never the stale copies of the inventory (olddata, synapse_backup.sql, /data/compose/{33,34}/postgres,
# /vw-data, /opt/seafile/mysql/db): every source is listed by name below.
#
# Test hooks (environment): GATE_PREFIX is put in front of every source path (a fake tree for a smoke
# test); GATE_STAGE_ROOT replaces /mnt/tbssd/arch-gate; GATE_SKIP_DUMPS=1 skips arch-db-dumps.sh.
set -euo pipefail

ENV_FILE=""
INIT=0
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMPS_SCRIPT="$HERE/../../machines/optiplex/cutover/arch-db-dumps.sh"
CLASS=(-o s3.storage-class=ONEZONE_IA)

[[ $EUID -eq 0 || -n ${GATE_PREFIX:-} ]] || die "run as root (the State is root-owned)"
for tool in restic sqlite3; do command -v "$tool" >/dev/null || die "$tool is not installed"; done
[[ -n $ENV_FILE && -r $ENV_FILE ]] || die "--env-file <file> is required (see --help)"

# --- the secrets: parsed, never sourced (a password may hold any character) -------------------------------
cleanup() {
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
  "$SEAFILE/conf" "$SEAFILE/seafile-data" "$SEAFILE/seahub-data"
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
  echo "would back up:"
  printf '  %s\n' "${SOURCES[@]}" "  + fresh dumps, SQLite copies in $STAGE_ROOT/<timestamp>/"
  echo "excluding:"
  printf '  %s\n' "${EXCLUDES[@]}"
  trap - EXIT
  exit 0
fi

# --- the repository --------------------------------------------------------------------------------------------------
if ((INIT)); then
  log "restic init (first run)"
  restic "${CLASS[@]}" init
else
  restic "${CLASS[@]}" cat config >/dev/null || die "the repository does not exist or is unreachable: re-run with --init only for the very first run, and check RESTIC_REPOSITORY"
fi

# --- stage: dumps and SQLite copies ----------------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$STAGE_ROOT/$STAMP"
install -d -m 0700 "$STAGE" "$STAGE/sqlite"

if [[ -z ${GATE_SKIP_DUMPS:-} ]]; then
  [[ -x $DUMPS_SCRIPT ]] || die "$DUMPS_SCRIPT not found: run this from a checkout of the repository"
  log "database dumps"
  final_arg=()
  ((FINAL)) && final_arg=(--final)
  "$DUMPS_SCRIPT" "${final_arg[@]}" --out-root "$STAGE/dumps"
fi

log "SQLite copies"
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
    [[ -d $s ]] && printf 'files %s %s\n' "$(find "$s" -type f | wc -l)" "$s"
  done
} >"$STAGE/GATE-MANIFEST"

# --- the backup --------------------------------------------------------------------------------------------------------
EXCLUDE_FILE="$(mktemp)"
printf '%s\n' "${EXCLUDES[@]}" >"$EXCLUDE_FILE"
log "restic backup (tag arch-gate)"
restic "${CLASS[@]}" backup --host optiplex --tag arch-gate --exclude-file="$EXCLUDE_FILE" \
  "${SOURCES[@]}" "$STAGE"
rm -f "$EXCLUDE_FILE"

log "snapshots tagged arch-gate"
restic "${CLASS[@]}" snapshots --tag arch-gate
cat <<EOF

Next:
  1. Storage class: the new objects must show One Zone (console: Object Storage, bucket, objects), or
       aws --endpoint-url https://s3.fr-par.scw.cloud s3api head-object --bucket nnik-optiplex-restic --key <key from: restic list packs | head -1 | sed 's|^|data/|'>
     -> "StorageClass": "ONEZONE_IA"
  2. Restore check in the VM harness: infra/scaleway/README.md, "The pre-Cutover gate".
  3. The stage directory $STAGE stays on the Data disk until the Cutover is done.
EOF
