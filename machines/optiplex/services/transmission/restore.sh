#!/usr/bin/env bash
# Ownership step of the Cutover for transmission (and its rollback), numeric ids only.
#
#   restore.sh forward   Arch ids (169) -> NixOS ids (70). Run as root on the Optiplex in
#                        restoreMode, after the State copy (see below).
#   restore.sh back      NixOS ids (70) -> Arch ids (169). Run as root before Arch's transmission
#                        starts again (Rollback), from whatever system has the Data disk mounted.
#
# What it touches
#   /mnt/tbssd/state/transmission   (forward only) chown -R 70:70, chmod -R g+w. This is the
#                        copied config dir; the copy itself is
#                          rsync -aHAX --numeric-ids <arch>:/var/lib/transmission/.config/transmission-daemon/ \
#                                /mnt/tbssd/state/transmission/.config/transmission-daemon/
#                        (settings.json, resume/, torrents/, queue.json, dht.dat, stats.json,
#                        bandwidth-groups.json, ... everything in the dir; mtimes must survive,
#                        otherwise transmission re-verifies).
#   /mnt/tbssd/trrnt     the directory itself, and every top-level entry owned by 169 or 70.
#                        Left alone: yannik's entries (watch/, transmit/, the stray file) and the
#                        root-owned config/ (old openvpn container; deleted with the Rollback
#                        image, not here). Symlinks are never followed.
#   /mnt/tbssd/trrnt/watch   yannik stays the owner. Its group becomes transmission (gid 70) and
#                        it gets g+w, so the daemon can rename the .torrent files it adds. The
#                        original owner:group and mode are saved on the first forward run and put
#                        back by `back`.
#
# Idempotent. Paths can be overridden for tests: TRRNT, STATE_TR, SAVE.
set -euo pipefail

mode=${1:?usage: restore.sh forward|back}
TRRNT=${TRRNT:-/mnt/tbssd/trrnt}
STATE_TR=${STATE_TR:-/mnt/tbssd/state/transmission}
SAVE=${SAVE:-/mnt/tbssd/cutover/trrnt-watch.orig}

case $mode in
  forward) from=169 to=70 ;;
  back) from=70 to=169 ;;
  *) echo "usage: restore.sh forward|back" >&2; exit 2 ;;
esac

if [ "$mode" = forward ]; then
  chown -hR 70:70 "$STATE_TR"
  find "$STATE_TR" ! -type l -exec chmod g+w {} +
fi

# the directory itself
chown -h "$to:$to" "$TRRNT"
chmod g+w "$TRRNT"

# top-level entries of the transmission user (either id, so a rerun finishes an interrupted run)
find "$TRRNT" -mindepth 1 -maxdepth 1 \( -user "$from" -o -user "$to" \) -print0 |
  while IFS= read -r -d '' entry; do
    chown -hR "$to:$to" "$entry"
    find "$entry" ! -type l -exec chmod g+w {} +
  done

# watch/: yannik's, but transmission needs to write to it
if [ -d "$TRRNT/watch" ]; then
  if [ "$mode" = forward ]; then
    if [ ! -e "$SAVE" ]; then
      mkdir -p "$(dirname "$SAVE")"
      stat -c '%u:%g %a' "$TRRNT/watch" >"$SAVE"
    fi
    chgrp 70 "$TRRNT/watch"
    chmod g+w "$TRRNT/watch"
  elif [ -e "$SAVE" ]; then
    read -r owner mod <"$SAVE"
    chown "$owner" "$TRRNT/watch"
    chmod "$mod" "$TRRNT/watch"
  else
    echo "no $SAVE: watch/ keeps group 70, check by hand that Arch's transmission (169) can write it" >&2
  fi
fi
