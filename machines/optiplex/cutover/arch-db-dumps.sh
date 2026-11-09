#!/usr/bin/env bash
# Cutover dump of the live databases on the Arch box, one dump per target database.
# Plain bash, runs on Arch as root, is not part of the NixOS config. Its counterpart on the
# new system is `optiplex-db-restore` (machines/optiplex/services/databases.nix).
#
#   arch-db-dumps.sh [--final] [--dry-run] [--out-root DIR]
#
# Output: DIR/<UTC timestamp>/   (DIR defaults to /mnt/tbssd/cutover-dumps: Data disk, outside /state)
#   postgresql/<target>.dump     pg_dump -Fc from the PG18 pg_dump (also for the PG14 containers)
#   mariadb/<target>.sql         mariadb-dump --single-transaction, one DB per file, no CREATE DATABASE
#   counts/<target>.tsv          exact count(*) per base table: schema, table, rows
#   MANIFEST                     versions, date, mode, sizes and sha256sum of every file
#
# Sources are hard-coded below (live name -> target name), so no stale copy can be picked up.
#
#   --final      the Cutover dump. Refuses to run unless every consumer is stopped (Synapse, both
#                bridges, the Gitea, Paperless and Seafile app containers). The DB servers stay up.
#                Without --final it is a live rehearsal dump (counts may differ from the dump by
#                writes that happen in between).
#   --dry-run    print the source -> target pairs and touch nothing
#   --out-root   where the timestamped directory goes
#
# Test hooks (environment, used by the nixosTest `optiplex-databases`, harmless otherwise):
#   PG_DUMP, PSQL, PG_RESTORE   the PG18 client binaries (default: from PATH)
set -euo pipefail

OUT_ROOT=/mnt/tbssd/cutover-dumps
FINAL=0
DRY=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "arch-db-dumps: $*" >&2; exit 1; }
log() { echo ">> $*" >&2; }

while (($#)); do
  case "$1" in
    --final) FINAL=1 ;;
    --dry-run) DRY=1 ;;
    --out-root) OUT_ROOT="${2:?--out-root needs a directory}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

PG_DUMP="${PG_DUMP:-pg_dump}"
PSQL="${PSQL:-psql}"

# kind|container|live database|live role|target name
#   arch       the native PG18 on Arch: socket /run/postgresql, user postgres (trust)
#   container  a PG14 container: the host's PG18 client inside the container's network namespace
PG_SOURCES=(
  "arch||synapse|postgres|matrix-synapse"
  "arch||whatsapp|postgres|mautrix-whatsapp"
  "arch||telegram|postgres|mautrix-telegram"
  "container|gitea-db-1|gitea|gitea|gitea"
  "container|paperless-db-1|paperless|paperless|paperless"
)
# container|live database|target name   (one container, root password from its own environment)
MARIADB_CONTAINER=seafile-mysql
MARIADB_SOURCES=(
  "ccnet_db|ccnet_db"
  "seafile_db|seafile_db"
  "seahub_db|seahub_db"
)

# Consumers that must be stopped for --final.
CONSUMER_UNITS=(synapse mautrix-whatsapp mautrix-telegram)
CONSUMER_CONTAINER_RE='^(gitea|paperless|seafile|seadoc)'
DB_CONTAINER_RE='^(gitea-db-1|paperless-db-1|seafile-mysql)$|redis|broker|memcached'

if ((DRY)); then
  echo "# source -> target (dump directory: $OUT_ROOT/<UTC timestamp>/)"
  for rec in "${PG_SOURCES[@]}"; do
    IFS='|' read -r kind ctr src _user target <<<"$rec"
    case $kind in
      arch) from="arch-native PG18 db '$src'" ;;
      *) from="container '$ctr' db '$src'" ;;
    esac
    printf 'postgresql  %-45s -> postgresql/%s.dump\n' "$from" "$target"
  done
  for rec in "${MARIADB_SOURCES[@]}"; do
    IFS='|' read -r src target <<<"$rec"
    printf 'mariadb     %-45s -> mariadb/%s.sql\n' "container '$MARIADB_CONTAINER' db '$src'" "$target"
  done
  exit 0
fi

[[ $EUID -eq 0 ]] || die "run as root (nsenter, docker exec, runuser)"

pg_major() { "$PG_DUMP" --version | sed -E 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/'; }
(("$(pg_major)" >= 18)) || die "$PG_DUMP is PostgreSQL $("$PG_DUMP" --version); need the PG18 pg_dump"

# --- consumers ---------------------------------------------------------------------------
running_consumers() {
  local u names
  for u in "${CONSUMER_UNITS[@]}"; do
    systemctl is-active --quiet "$u.service" && echo "unit $u.service"
  done
  names="$(docker ps --format '{{.Names}}')"
  grep -E "$CONSUMER_CONTAINER_RE" <<<"$names" | grep -Ev "$DB_CONTAINER_RE" | sed 's/^/container /' || true
}
if ((FINAL)); then
  active="$(running_consumers)"
  [[ -z $active ]] || die "--final needs the consumers stopped, still running:
$active"
else
  log "rehearsal dump (no --final): consumers are not stopped, counts may differ from the dumps"
fi

# --- output directory --------------------------------------------------------------------
umask 077
ts="$(date -u +%Y%m%dT%H%M%SZ)"
final_dir="$OUT_ROOT/$ts"
[[ ! -e $final_dir ]] || die "$final_dir exists already"
work="$OUT_ROOT/.$ts.partial"
mkdir -p "$work/postgresql" "$work/mariadb" "$work/counts"
log "writing to $work (renamed to $final_dir when complete)"

# --- PostgreSQL --------------------------------------------------------------------------
# pg_client <kind> <container> <role> <binary> args...: run a PG client against that source
pg_client() {
  local kind=$1 ctr=$2 role=$3 bin=$4 pid
  shift 4
  case $kind in
    arch)
      runuser -u postgres -- "$bin" -h /run/postgresql -U postgres "$@"
      ;;
    container)
      pid="$(docker inspect -f '{{.State.Pid}}' "$ctr")"
      [[ $pid =~ ^[1-9][0-9]*$ ]] || die "container $ctr is not running"
      # Relies on the image's local trust lines (127.0.0.1); the caller falls back to docker exec.
      nsenter --net="/proc/$pid/ns/net" "$bin" -h 127.0.0.1 -p 5432 -U "$role" "$@"
      ;;
  esac
}

# The same query on both sides (the restore script has its own copy of it): every base table in a
# non-system schema, exact rows.
PG_COUNTS_SQL="select n.nspname, c.relname,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::bigint
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and n.nspname <> 'information_schema' and n.nspname !~ '^pg_'
order by n.nspname collate \"C\", c.relname collate \"C\""

dump_postgresql() {
  local kind=$1 ctr=$2 src=$3 role=$4 target=$5
  local out="$work/postgresql/$target.dump" cnt="$work/counts/$target.tsv"
  log "postgresql $src -> $target"
  pg_client "$kind" "$ctr" "$role" "$PSQL" -X -At -F $'\t' -d "$src" -c "$PG_COUNTS_SQL" | LC_ALL=C sort >"$cnt.tmp"
  mv "$cnt.tmp" "$cnt"
  if ! pg_client "$kind" "$ctr" "$role" "$PG_DUMP" -d "$src" -Fc >"$out"; then
    [[ $kind == container ]] || die "pg_dump of $src failed"
    log "WARNING: the nsenter dump of $ctr failed, falling back to the container's own PG14 pg_dump"
    docker exec "$ctr" pg_dump -U "$role" -Fc "$src" >"$out" || die "pg_dump of $src failed"
  fi
  "${PG_RESTORE:-pg_restore}" -l "$out" >/dev/null || die "$out is not a readable pg_dump archive"
  [[ -s $out ]] || die "$out is empty"
}

# --- MariaDB -----------------------------------------------------------------------------
# The root password never leaves the container: it is read from the container's own environment
# inside sh -c. The database name is "$0" of that sh, so nothing is interpolated.
# shellcheck disable=SC2016  # the snippets are meant for the container's sh, not for this shell
maria_exec() { # <sh snippet using "$0" as the database> <database>
  docker exec "$MARIADB_CONTAINER" sh -c "MYSQL_PWD=\${MARIADB_ROOT_PASSWORD:-\$MYSQL_ROOT_PASSWORD} $1" "$2"
}

maria_counts() { # <database>
  local db=$1 tables t sql=""
  # shellcheck disable=SC2016
  tables="$(maria_exec 'exec mariadb -uroot -N -B -e "select table_name from information_schema.tables where table_schema = \"$0\" and table_type = \"BASE TABLE\"" "$0"' "$db" | LC_ALL=C sort)"
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    sql+="select '$db', '$t', count(*) from \`$db\`.\`$t\`;"$'\n'
  done <<<"$tables"
  [[ -n $sql ]] || return 0
  # the SQL goes over stdin of the container's client
  printf '%s' "$sql" | docker exec -i "$MARIADB_CONTAINER" sh -c 'MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD} exec mariadb -uroot -N -B' | LC_ALL=C sort
}

dump_mariadb() {
  local src=$1 target=$2
  local out="$work/mariadb/$target.sql"
  log "mariadb $src -> $target"
  maria_counts "$src" >"$work/counts/$target.tsv"
  # shellcheck disable=SC2016
  maria_exec 'exec mariadb-dump -uroot --single-transaction --routines --triggers --events --hex-blob "$0"' "$src" >"$out" \
    || die "mariadb-dump of $src failed"
  tail -n 3 "$out" | grep -q -- '-- Dump completed' || die "$out looks truncated (no 'Dump completed' trailer)"
}

# --- run ---------------------------------------------------------------------------------
for rec in "${PG_SOURCES[@]}"; do
  IFS='|' read -r kind ctr src role target <<<"$rec"
  dump_postgresql "$kind" "$ctr" "$src" "$role" "$target"
done
for rec in "${MARIADB_SOURCES[@]}"; do
  IFS='|' read -r src target <<<"$rec"
  dump_mariadb "$src" "$target"
done

# --- MANIFEST ----------------------------------------------------------------------------
mode=rehearsal
((FINAL)) && mode=final
{
  echo "# arch-db-dumps MANIFEST"
  echo "# date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# mode: $mode"
  echo "# host: $(hostname)"
  echo "# pg_dump: $("$PG_DUMP" --version)"
  for rec in "${PG_SOURCES[@]}"; do
    IFS='|' read -r kind ctr src role target <<<"$rec"
    echo "# source postgresql $target <- ${ctr:-arch-native}/$src: $(pg_client "$kind" "$ctr" "$role" "$PSQL" -X -At -d "$src" -c 'show server_version')"
  done
  echo "# source mariadb <- $MARIADB_CONTAINER: $(docker exec "$MARIADB_CONTAINER" mariadb-dump --version)"
  (cd "$work" && find . -type f ! -name MANIFEST -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
    echo "# size $(stat -c %s "$f") $f"
  done)
  (cd "$work" && find . -type f ! -name MANIFEST -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum)
} >"$work/MANIFEST"

mv "$work" "$final_dir"
log "done: $final_dir"
cat "$final_dir/MANIFEST" >&2
