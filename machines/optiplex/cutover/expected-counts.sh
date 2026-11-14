#!/usr/bin/env bash
# Service-level counts that must be equal on Arch (after the last write, before the wipe) and on the Optiplex
# (after the restore, before the first normal deploy). One `key=value` per line. Plain bash, runs as root.
# The per-table counts of the eight databases are already compared by arch-db-dumps.sh / optiplex-db-restore
# (counts/*.tsv); this script adds what those do not see: the meaning of the numbers a human would check
# (Synapse events and stream position, Gitea repositories and issues, Paperless documents, Seafile libraries,
# every table of the two SQLite databases) and the copied file trees.
#
#   expected-counts.sh capture [--host arch|nixos] [--out FILE] [--skip-db] [--dry-run]
#   expected-counts.sh diff [--common] <arch file> <nixos file>
#
#   capture   --host defaults to the OS (Arch or NixOS). Prints the counts, and writes them to FILE when --out is given
#             (on Arch: /mnt/tbssd/cutover/expected-arch.txt; on NixOS: a scratch file, then `diff`).
#             Run it with the consumers stopped; the DB servers must be up (PostgreSQL, the Gitea and Paperless
#             containers on Arch, MariaDB or the Seafile MariaDB container).
#   --skip-db skip the PostgreSQL and MariaDB queries (file counts and SQLite only). Same keys are then missing on
#             both sides, so `diff` of two such files is meaningful.
#   --dry-run print every key and the command that would produce it; run nothing.
#   diff      compares two capture files (comment lines ignored), lists every key that differs or is on one side only,
#             exits 1 if there is any difference. With --common only the keys present in both files are compared
#             (a --skip-db capture on NixOS before the databases are restored against the full Arch capture).
#
# Where it reads (Arch | NixOS):
#   PostgreSQL     native PG18 via `runuser -u postgres -- psql -h /run/postgresql`, gitea and paperless inside their
#                  PG14 containers | `runuser -u postgres -- psql -d <db>` (peer auth, socket)
#   MariaDB        `docker exec seafile-mysql ... mariadb` (root password from the container's own environment) |
#                  `mariadb` as root over the socket
#   SQLite         vaultwarden_data/db.sqlite3 and /srv/etesync/etebase/db.sqlite3 | /state/{vaultwarden,etesync}/db.sqlite3
#   file trees     Synapse media, Seafile blocks, Gitea repositories, Paperless originals, transmission resume files,
#                  the four static sites
# sqlite3 is not installed on the Optiplex: the script then uses `nix shell nixpkgs#sqlite -c sqlite3` (needs the
# network) or a sqlite3 found in the Nix store.
# Test hooks: COUNTS_PREFIX is put in front of every file path (a fake tree); no database is touched with --skip-db.
set -euo pipefail

die() { echo "expected-counts: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

MODE="${1:-}"
shift || true
HOST=""
OUT=""
SKIP_DB=0
DRY=0
DIFF_ARGS=()
COMMON=0
while (($#)); do
  case "$1" in
    --host) HOST="${2:?--host arch|nixos}"; shift ;;
    --out) OUT="${2:?--out needs a file}"; shift ;;
    --skip-db) SKIP_DB=1 ;;
    --dry-run) DRY=1 ;;
    --common) COMMON=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) DIFF_ARGS+=("$1") ;;
  esac
  shift
done
[[ $MODE != -h && $MODE != --help ]] || { usage; exit 0; }

# ---------------------------------------------------------------------------------------------------------
do_diff() {
  ((${#DIFF_ARGS[@]} == 2)) || die "usage: expected-counts.sh diff [--common] <arch file> <nixos file>"
  local a="${DIFF_ARGS[0]}" b="${DIFF_ARGS[1]}" ka kb common
  [[ -r $a && -r $b ]] || die "cannot read $a or $b"
  ka="$(grep -v '^#' "$a" | LC_ALL=C sort)"
  kb="$(grep -v '^#' "$b" | LC_ALL=C sort)"
  if ((COMMON)); then
    # keep only the keys that both files have
    common="$(comm -12 <(cut -d= -f1 <<<"$ka") <(cut -d= -f1 <<<"$kb"))"
    ka="$(awk -F= 'NR==FNR { k[$1] = 1; next } $1 in k' <(printf '%s\n' "$common") - <<<"$ka")"
    kb="$(awk -F= 'NR==FNR { k[$1] = 1; next } $1 in k' <(printf '%s\n' "$common") - <<<"$kb")"
  fi
  if diff -u --label "$a" --label "$b" <(printf '%s\n' "$ka") <(printf '%s\n' "$kb"); then
    echo "expected-counts: all $(grep -c . <<<"$ka") compared values are equal"
  else
    echo "expected-counts: DIFFERENCES (lines with - are $a, lines with + are $b)" >&2
    return 1
  fi
}

# sqlite3 on this host: PATH, else nix shell, else a copy in the store
sq() {
  if command -v sqlite3 >/dev/null; then
    sqlite3 "$@"
  elif command -v nix >/dev/null && nix shell nixpkgs#sqlite -c true 2>/dev/null; then
    nix shell nixpkgs#sqlite -c sqlite3 "$@"
  else
    local f
    f="$(compgen -G '/nix/store/*-sqlite-*-bin/bin/sqlite3' | head -1)" || true
    [[ -n $f ]] || die "no sqlite3 available (install it or give the host network access for nix shell)"
    "$f" "$@"
  fi
}

# ---------------------------------------------------------------------------------------------------------
P="${COUNTS_PREFIX:-}"
RESULT=()

if [[ -z $HOST && $MODE == capture ]]; then
  if grep -qi '^ID=nixos' "$P/etc/os-release" 2>/dev/null || [[ -d /run/current-system ]]; then HOST=nixos; else HOST=arch; fi
fi

# add <key> <command description> <command...>: runs the command, stores key=value
add() {
  local key=$1 desc=$2 val
  shift 2
  if ((DRY)); then
    printf '%-34s %s\n' "$key" "$desc"
    return 0
  fi
  val="$("$@")" || die "$key failed: $desc"
  [[ -n $val ]] || die "$key is empty: $desc"
  RESULT+=("$key=$val")
  echo "$key=$val" >&2
}

files_in() { # <dir> [prune subdir]: number of regular files below it
  [[ -d $1 ]] || { echo "missing:$1" >&2; return 1; }
  if [[ -n ${2:-} ]]; then find "$1" -path "$1/$2" -prune -o -type f -print | wc -l; else find "$1" -type f | wc -l; fi
}

sqlite_tables() { # <label> <db file>: one count per table
  local label=$1 db=$2 t n
  [[ -f $db ]] || die "$db does not exist"
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    if ((DRY)); then
      printf '%-34s %s\n' "$label.$t" "sqlite3 -readonly $db 'select count(*) from \"$t\"'"
    else
      n="$(sq -readonly "$db" "select count(*) from \"$t\"")" || die "$label.$t failed"
      RESULT+=("$label.$t=$n")
      echo "$label.$t=$n" >&2
    fi
  done < <(sq -readonly "$db" "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name")
}

pg() { # <db> <sql> [container role]
  local db=$1 sql=$2
  if [[ $HOST == arch ]]; then
    if [[ -n ${3:-} ]]; then
      docker exec "$3" psql -X -At -U "$4" -d "$db" -c "$sql"
    else
      runuser -u postgres -- psql -X -At -h /run/postgresql -U postgres -d "$db" -c "$sql"
    fi
  else
    runuser -u postgres -- psql -X -At -d "$db" -c "$sql"
  fi
}
# shellcheck disable=SC2016  # $0 is for the container's sh, not for this shell
maria() { # <sql>
  if [[ $HOST == arch ]]; then
    docker exec seafile-mysql sh -c 'MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD} exec mariadb -uroot -N -B -e "$0"' "$1"
  else
    mariadb -N -B -e "$1"
  fi
}

do_capture() {
  [[ $HOST == arch || $HOST == nixos ]] || die "--host must be arch or nixos"
  if ((!DRY)) && [[ -z ${COUNTS_PREFIX:-} ]]; then [[ $EUID -eq 0 ]] || die "run as root"; fi

  local media blocks gitea_repos originals resume sites_ya sites_koke sites_immo sites_opti sqlite_vw sqlite_ete
  if [[ $HOST == arch ]]; then
    media="$P/var/lib/synapse/media_store"
    blocks="$P/mnt/tbssd/filesync/seafile/seafile-data/storage/blocks"
    gitea_repos="$P/mnt/tbssd/docker/volumes/gitea_data/_data/git/repositories"
    originals="$P/mnt/tbssd/docker/volumes/paperless_media/_data/documents/originals"
    resume="$P/var/lib/transmission/.config/transmission-daemon/resume"
    sites_ya="$P/srv/http/www.ya.nnik.dev"
    sites_koke="$P/srv/http/koke.nnik.dev"
    sites_immo="$P/srv/http/immo.nnik.dev"
    sites_opti="$P/srv/http/opti.plex"
    sqlite_vw="$P/mnt/tbssd/docker/volumes/vaultwarden_data/_data/db.sqlite3"
    sqlite_ete="$P/srv/etesync/etebase/db.sqlite3"
  else
    media="$P/state/synapse/media_store"
    blocks="$P/state/seafile/seafile-data/storage/blocks"
    gitea_repos="$P/state/gitea/repositories"
    originals="$P/state/paperless/media/documents/originals"
    resume="$P/state/transmission/.config/transmission-daemon/resume"
    sites_ya="$P/state/www/ya"
    sites_koke="$P/state/www/koke"
    sites_immo="$P/state/www/immo"
    sites_opti="$P/state/www/opti.plex"
    sqlite_vw="$P/state/vaultwarden/db.sqlite3"
    sqlite_ete="$P/state/etesync/db.sqlite3"
  fi

  if ((!SKIP_DB)); then
    add synapse.events "select count(*) from events (PostgreSQL synapse)" pg synapse "select count(*) from events"
    add synapse.max_stream_ordering "select max(stream_ordering) from events" pg synapse "select max(stream_ordering) from events"
    add synapse.users "select count(*) from users" pg synapse "select count(*) from users"
    add synapse.rooms "select count(*) from rooms" pg synapse "select count(*) from rooms"
    local g=(gitea)
    [[ $HOST == arch ]] && g=(gitea gitea-db-1 gitea)
    local t
    for t in repository '"user"' issue comment review; do
      add "gitea.${t//\"/}" "select count(*) from $t (PostgreSQL gitea)" pg "${g[0]}" "select count(*) from $t" "${g[@]:1}"
    done
    local pl=(paperless)
    [[ $HOST == arch ]] && pl=(paperless paperless-db-1 paperless)
    add paperless.documents "select count(*) from documents_document" pg "${pl[0]}" "select count(*) from documents_document" "${pl[@]:1}"
    add seafile.libraries "select count(*) from seafile_db.RepoInfo (19 in the rehearsal: the 18 plus the built-in template)" maria "select count(*) from seafile_db.RepoInfo"
    add seafile.share_links "select count(*) from seahub_db.share_fileshare (9 expected)" maria "select count(*) from seahub_db.share_fileshare"
  fi

  sqlite_tables vaultwarden "$sqlite_vw"
  sqlite_tables etesync "$sqlite_ete"
  # shellcheck disable=SC2016  # the snippets are for the inner bash
  add transmission.torrents "resume files in $resume (97 expected)" bash -c 'ls "$1" | grep -c "\.resume$"' _ "$resume"
  add files.synapse_media "regular files below $media" files_in "$media"
  add files.seafile_blocks "regular files below $blocks" files_in "$blocks"
  # shellcheck disable=SC2016
  add files.gitea_repositories "directories *.git two levels below $gitea_repos" bash -c 'find "$1" -mindepth 2 -maxdepth 2 -name "*.git" -type d | wc -l' _ "$gitea_repos"
  add files.paperless_originals "regular files below $originals" files_in "$originals"
  add files.www_ya "regular files below $sites_ya" files_in "$sites_ya"
  add files.www_koke "regular files below $sites_koke" files_in "$sites_koke"
  add files.www_immo "regular files below $sites_immo" files_in "$sites_immo"
  add files.www_opti_plex "regular files below $sites_opti, without gate/" files_in "$sites_opti" gate

  ((DRY)) && return 0
  local header
  header="# expected-counts host=$HOST date=$(date -u +%Y-%m-%dT%H:%M:%SZ) skip-db=$SKIP_DB"
  if [[ -n $OUT ]]; then
    { echo "$header"; printf '%s\n' "${RESULT[@]}" | LC_ALL=C sort; } >"$OUT"
    echo "expected-counts: ${#RESULT[@]} values written to $OUT" >&2
  else
    { echo "$header"; printf '%s\n' "${RESULT[@]}" | LC_ALL=C sort; }
  fi
}

case "$MODE" in
  capture) do_capture ;;
  diff) do_diff ;;
  *) usage >&2; exit 2 ;;
esac
