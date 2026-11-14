#!/usr/bin/env bash
# Cutover copy of the Kept services' State from its Arch location to the State folder on the Data disk
# (/mnt/tbssd/state/<service>, bind-mounted as /state on NixOS). Plain bash, runs on Arch as root, is not part
# of the NixOS config. This is the copy table of docs/optiplex-cutover-runbook.md as rsync calls.
#
#   sync-state.sh [--final] [--dry-run] [--only <row>] [--list]
#
# Everything is copied, never moved: the Arch trees (and /mnt/tbssd/docker, /mnt/tbssd/filesync) stay as they
# were, because the rollback needs them. All calls use `rsync -aHAX --numeric-ids`, so mtimes survive (transmission
# re-verifies every torrent otherwise) and ids stay numeric.
#
#   (no flag)    pre-sync: only the rows marked "pre" (the big or slow trees), no --delete. Safe while Arch runs.
#                Run it days ahead and repeat it daily; it only transfers what changed.
#   --final      the downtime pass: every row, with --delete (the copy becomes exact). Refuses while a
#                consumer of a row is still running (units and containers listed below), because SQLite and WAL
#                files must be copied as a quiet pair. The DB servers do not count as consumers.
#   --dry-run    pass -n to rsync: print what would be transferred (file counts), create and change nothing.
#                Sources must exist even then: a missing source is a mistake, not something to skip.
#   --only <id>  just that row (see --list). Combines with the flags above.
#   --list       print the rows: id, when, source, target. Touches nothing.
#
# Rows (id: when  source -> /mnt/tbssd/state/...):
#   synapse       pre   /var/lib/synapse/media_store/                    -> synapse/media_store/      (--chown=224:224)
#   seafile       pre   /mnt/tbssd/filesync/seafile/{conf,seafile-data,seahub-data,ccnet} -> seafile/   (excludes: thumbnails, logs, __pycache__)
#   www           pre   /srv/http/{www.ya,koke,immo}.nnik.dev, opti.plex -> www/{ya,koke,immo,opti.plex}/   (--chown=1001:100)
#   archive       pre   /home/yannik/.zsh_history                        -> /mnt/tbssd/archive/arch-optiplex/
#   etesync       down  /srv/etesync/etebase/db.sqlite3, /srv/etesync/media/ -> etesync/
#   etesync-dav   down  /root/.local/share/etesync-dav/{etesync_creds,etebase_data.db} -> etesync-dav/
#   paperless     down  docker volumes paperless_data, paperless_media   -> paperless/, paperless/media/
#   vaultwarden   down  docker volume vaultwarden_data (no icon_cache, tmp, rsa_key*.pem) -> vaultwarden/
#   homeassistant down  /srv/homeassistant/ (no log, .cache, deps, tts, secrets.yaml) -> homeassistant/ (--chown=286:286)
#   transmission  down  /var/lib/transmission/.config/transmission-daemon/ -> transmission/.config/transmission-daemon/
# Not here on purpose: Gitea (one-shot `optiplex-gitea-restore` on NixOS reads the Docker volume from the Data disk)
# and the databases (arch-db-dumps.sh). The ownership steps that need the NixOS users are in the runbook (step 10).
#
# Test hooks (environment, harmless otherwise): SYNC_PREFIX is put in front of every path (a fake tree for a
# smoke test); SYNC_NO_CHOWN=1 drops --chown; SYNC_SKIP_CHECKS=1 skips the mount and consumer checks.
set -euo pipefail

FINAL=0
DRY=0
ONLY=""
LIST=0

die() { echo "sync-state: $*" >&2; exit 1; }
log() { echo ">> $*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --final) FINAL=1 ;;
    --dry-run) DRY=1 ;;
    --only) ONLY="${2:?--only needs a row id}"; shift ;;
    --list) LIST=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

P="${SYNC_PREFIX:-}"
DATA="$P/mnt/tbssd"
S="$DATA/state"
DOCKER_VOLS="$DATA/docker/volumes"
SEAFILE="$DATA/filesync/seafile"
ARCHIVE="$DATA/archive/arch-optiplex"

# id:when:description, in the order they run (the big pre-sync trees first)
ROWS=(
  "synapse:pre:Synapse media_store (25 GB)"
  "seafile:pre:Seafile conf, seafile-data, seahub-data, ccnet (22 GB of blocks)"
  "www:pre:static sites ya, koke, immo, opti.plex"
  "archive:pre:.zsh_history into /mnt/tbssd/archive/arch-optiplex"
  "etesync:down:etesync db.sqlite3 and media"
  "etesync-dav:down:etesync-dav etesync_creds and etebase_data.db"
  "paperless:down:paperless_data and paperless_media volumes"
  "vaultwarden:down:vaultwarden_data volume"
  "homeassistant:down:/srv/homeassistant"
  "transmission:down:transmission config dir"
)

# ---------------------------------------------------------------------------------------------------------
# Rows. copy <source> <target dir or file> [rsync options...]; target dirs are created first (not in --dry-run).
# ---------------------------------------------------------------------------------------------------------
OWN=()
own() { OWN=(); if [[ -z ${SYNC_NO_CHOWN:-} ]]; then OWN=("--chown=$1"); fi; } # own <uid:gid>: sets OWN for the next copy

row_synapse() {
  own 224:224
  copy "$P/var/lib/synapse/media_store/" "$S/synapse/media_store/" "${OWN[@]}"
}
row_seafile() {
  local d
  install_dir "$S/seafile"
  for d in conf seafile-data seahub-data ccnet; do
    if [[ -d $SEAFILE/$d ]]; then
      # no trailing slash on the source: rsync creates <target>/<d>/, and --delete stays inside it
      copy "$SEAFILE/$d" "$S/seafile/" --exclude='seahub-data/thumbnail/' --exclude='logs/' --exclude='conf/__pycache__/'
    elif [[ $d == ccnet ]]; then
      log "seafile: no ccnet/ next to the other trees (optional), skipping it"
    else
      die "seafile: $SEAFILE/$d does not exist"
    fi
  done
}
row_www() {
  own 1001:100 # yannik:users as state-www.service makes /state/www
  copy "$P/srv/http/www.ya.nnik.dev/" "$S/www/ya/" "${OWN[@]}" --chmod=a+rX
  copy "$P/srv/http/koke.nnik.dev/" "$S/www/koke/" "${OWN[@]}" --chmod=a+rX
  copy "$P/srv/http/immo.nnik.dev/" "$S/www/immo/" "${OWN[@]}" --chmod=a+rX
  # gate/ is the Arch backup progress page (arch-gate.sh); the NixOS job writes its own
  copy "$P/srv/http/opti.plex/" "$S/www/opti.plex/" "${OWN[@]}" --chmod=a+rX --exclude='/gate/'
}
row_archive() {
  ((DRY)) || install -d -m 0700 "$ARCHIVE"
  copy "$P/home/yannik/.zsh_history" "$ARCHIVE/"
}
row_etesync() {
  [[ ! -s $P/srv/etesync/etebase/db.sqlite3-wal ]] || die "etesync: a non-empty db.sqlite3-wal exists: is etesync really stopped?"
  copy "$P/srv/etesync/etebase/db.sqlite3" "$S/etesync/db.sqlite3" --mkpath
  copy "$P/srv/etesync/media/" "$S/etesync/media/"
}
row_etesync_dav() {
  local d="$P/root/.local/share/etesync-dav"
  install_dir "$S/etesync-dav"
  # htpaswd and secret.txt are not carried (sops); etebase_data.db is a cache: if it does not open on NixOS, delete it
  copy "$d/etesync_creds" "$S/etesync-dav/"
  copy "$d/etebase_data.db" "$S/etesync-dav/"
}
row_paperless() {
  install_dir "$S/paperless/media" "$S/paperless/consume"
  # media/ and consume/ belong to the second call and to the unit: protect them from the first call's --delete
  copy "$DOCKER_VOLS/paperless_data/_data/" "$S/paperless/" --exclude='/log/' --exclude='/media/' --exclude='/consume/'
  copy "$DOCKER_VOLS/paperless_media/_data/" "$S/paperless/media/"
}
row_vaultwarden() {
  # the key is placed by sops, the public key is derived: neither is copied. The volume stays untouched.
  copy "$DOCKER_VOLS/vaultwarden_data/_data/" "$S/vaultwarden/" --exclude='/icon_cache/' --exclude='/tmp/' --exclude='/rsa_key*.pem'
}
row_homeassistant() {
  if ((!DRY)); then
    if [[ -z ${SYNC_NO_CHOWN:-} ]]; then install -d -m 0700 -o 286 -g 286 "$S/homeassistant"; else install -d -m 0700 "$S/homeassistant"; fi
  fi
  own 286:286
  copy "$P/srv/homeassistant/" "$S/homeassistant/" "${OWN[@]}" \
    --exclude='home-assistant.log*' --exclude='/.ha_run.lock' --exclude='/.cache/' --exclude='/deps/' --exclude='/tts/' --exclude='/secrets.yaml'
}
row_transmission() {
  # the target is the module's config dir below its home; mtimes must survive
  copy "$P/var/lib/transmission/.config/transmission-daemon/" "$S/transmission/.config/transmission-daemon/" --mkpath
}

# consumers per downtime row: systemd units and container name patterns that must be stopped for --final
CONSUMER_UNITS=(synapse mautrix-whatsapp mautrix-telegram turnserver etesync etesync-caldav transmission)
CONSUMER_CONTAINER_RE='^(gitea|paperless|seafile|seadoc|vaultwarden|homeassistant|bt-)'
DB_CONTAINER_RE='^(gitea-db-1|paperless-db-1|seafile-mysql)$|redis|broker|memcached'

# ---------------------------------------------------------------------------------------------------------
install_dir() { # install_dir <dir>...  (not in --dry-run; an existing directory keeps its mode)
  ((DRY)) || mkdir -p "$@"
}

RSYNC_BASE=(-aHAX --numeric-ids --info=stats1)
copy() { # copy <source> <target> [rsync options...]
  local src=$1 dst=$2 args=("${RSYNC_BASE[@]}")
  shift 2
  [[ -e ${src%/} ]] || die "source $src does not exist (a typo, or the service moved)"
  ((FINAL)) && args+=(--delete)
  # a dry run must not create the target, but must still check every option: --mkpath lets rsync -n
  # accept a target that does not exist yet
  ((DRY)) && args+=(--dry-run --mkpath --info=stats2)
  args+=("$@")
  if ((!DRY)) && [[ $dst == */ ]]; then install_dir "$dst"; fi
  echo "-- rsync ${args[*]} $src $dst"
  rsync "${args[@]}" "$src" "$dst"
}

running_consumers() {
  local u names
  for u in "${CONSUMER_UNITS[@]}"; do
    systemctl is-active --quiet "$u.service" && echo "unit $u.service"
  done
  names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  grep -E "$CONSUMER_CONTAINER_RE" <<<"$names" | grep -Ev "$DB_CONTAINER_RE" | sed 's/^/container /' || true
}

if ((LIST)); then
  printf '%-14s %-5s %s\n' id when what
  for r in "${ROWS[@]}"; do
    IFS=: read -r id when what <<<"$r"
    printf '%-14s %-5s %s\n' "$id" "$when" "$what"
  done
  exit 0
fi

if [[ -z ${SYNC_SKIP_CHECKS:-} ]] && ((!DRY)); then
  [[ $EUID -eq 0 ]] || die "run as root (numeric ids, root-owned sources)"
  mountpoint -q /mnt/tbssd || die "/mnt/tbssd is not mounted: the copy would land on the System disk"
  if ((FINAL)); then
    active="$(running_consumers)"
    [[ -z $active ]] || die "--final needs the consumers stopped, still running:
$active"
  fi
fi
command -v rsync >/dev/null || die "rsync is not installed"

selected=0
for r in "${ROWS[@]}"; do
  IFS=: read -r id when _ <<<"$r"
  [[ -z $ONLY || $ONLY == "$id" ]] || continue
  if [[ -z $ONLY && $when == down && $FINAL == 0 ]]; then
    log "skip $id (downtime row: only with --final)"
    continue
  fi
  if [[ -n $ONLY && $when == down && $FINAL == 0 && $DRY == 0 ]]; then
    die "$id is a downtime row: run it with --final once its consumers are stopped (or add --dry-run)"
  fi
  selected=1
  log "row $id ($when)"
  start=$SECONDS
  "row_${id//-/_}"
  log "row $id done in $((SECONDS - start)) s"
done
((selected)) || die "no such row: $ONLY (see --list)"

if ((DRY)); then
  log "dry run: nothing was written"
else
  log "finished ($([[ $FINAL == 1 ]] && echo final || echo pre-sync))"
fi
