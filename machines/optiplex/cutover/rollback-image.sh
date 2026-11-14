#!/usr/bin/env bash
# The Rollback image: a full copy of the Arch System disk on the Data disk, taken from inside the installer
# (the kexec installer or the installer USB) while the NVMe is not mounted, and the way back. Plain bash for
# a root shell in the installer, not part of the NixOS config. The installer ISO (nixosConfigurations.optiplex-installer)
# carries this script as `rollback-image`.
#
#   rollback-image.sh create  [--dry-run]
#   rollback-image.sh verify  [--dry-run] [--against-device]
#   rollback-image.sh restore [--dry-run] [--yes]
#   rollback-image.sh status
#
#   create    mounts the Data disk at /data (never under /mnt: disko mounts the new System disk there), then
#             streams the whole System disk through zstd into <dir>/arch-nvme0n1.img.zst. Beside it:
#             .sha256 (sha256 of the raw device, computed on the same pass), .sfdisk (`sfdisk -d`) and .size.
#             Refuses when the device or one of its partitions is mounted, when the image exists, or when the Data disk
#             has less free space than the device is big (the worst case: incompressible data).
#   verify    `zstd -t`, then decompresses and compares the sha256 with the recorded raw one. With
#             --against-device it also hashes the disk itself (it must still equal the image: nothing wrote to it).
#   restore   the rollback: writes the image back to the device (zstd -dc | dd conv=fsync), re-reads the device and
#             compares the sha256. Destroys whatever is on the device, so it needs --yes or a typed confirmation.
#   status    prints the recorded size, hash and the sfdisk table, and the image size on disk.
#   --dry-run runs every check and prints what would be done; writes and mounts nothing.
#
# Environment (defaults are the Optiplex's):
#   ROLLBACK_DEVICE    the Arch System disk (KIOXIA NVMe, /dev/disk/by-id/nvme-KBG40ZNS256G_NVMe_KIOXIA_256GB_21LPG2BCQL42)
#   ROLLBACK_DATA_DEV  the Data disk (/dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999)
#   ROLLBACK_MOUNT     where the Data disk is mounted (/data)
#   ROLLBACK_DIR       the image's directory (<mount>/rollback = /mnt/tbssd/rollback on the Data disk)
# Test hooks: ROLLBACK_ALLOW_FILE=1 accepts a regular file as the device; ROLLBACK_SKIP_MOUNT=1 neither
# mounts nor checks the Data disk (ROLLBACK_DIR must then exist or be creatable).
set -euo pipefail

DEVICE="${ROLLBACK_DEVICE:-/dev/disk/by-id/nvme-KBG40ZNS256G_NVMe_KIOXIA_256GB_21LPG2BCQL42}"
DATA_DEV="${ROLLBACK_DATA_DEV:-/dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999}"
MOUNT="${ROLLBACK_MOUNT:-/data}"
DIR="${ROLLBACK_DIR:-$MOUNT/rollback}"
IMG="$DIR/arch-nvme0n1.img.zst"

DRY=0
YES=0
AGAINST=0
MODE="${1:-}"
[[ $MODE == -h || $MODE == --help ]] && MODE=help
shift || true

die() { echo "rollback-image: $*" >&2; exit 1; }
log() { echo ">> $*" >&2; }
usage() { sed -n '/^# The Rollback image/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --against-device) AGAINST=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

case "$MODE" in
  create | verify | restore | status) ;;
  help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# ---- helpers ----------------------------------------------------------------------------------------------------
need() { local t; for t in "$@"; do command -v "$t" >/dev/null || die "$t is not installed (the installer ISO has it)"; done; }
progress() { # progress <total bytes>: a pipe with a progress bar when pv exists
  if command -v pv >/dev/null; then pv -ptebar -s "$1"; else cat; fi
}
dev_size() {
  if [[ -b $DEVICE ]]; then blockdev --getsize64 "$DEVICE"; else stat -c %s "$DEVICE"; fi
}
check_device() {
  if [[ -b $DEVICE ]]; then
    :
  elif [[ -f $DEVICE && -n ${ROLLBACK_ALLOW_FILE:-} ]]; then
    :
  else
    die "$DEVICE is not a block device"
  fi
}
check_unmounted() {
  [[ -b $DEVICE ]] || return 0
  if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -q .; then
    die "$DEVICE (or a partition of it) is mounted: run this from the installer, not from the running system"
  fi
}
mount_data() {
  [[ -z ${ROLLBACK_SKIP_MOUNT:-} ]] || return 0
  case "$MOUNT" in /mnt | /mnt/*) die "mount the Data disk at /data, never under /mnt (disko mounts the new System disk there)" ;; esac
  if mountpoint -q "$MOUNT"; then
    log "$MOUNT is already mounted"
    return 0
  fi
  [[ -b $(readlink -f "$DATA_DEV") ]] || die "the Data disk $DATA_DEV does not exist"
  if ((DRY)); then
    log "(dry run) would mount $DATA_DEV at $MOUNT"
    return 0
  fi
  mkdir -p "$MOUNT"
  mount "$DATA_DEV" "$MOUNT"
}
read_recorded() {
  [[ -f $IMG ]] || die "no image at $IMG"
  [[ -f $IMG.sha256 && -f $IMG.size ]] || die "$IMG.sha256 or $IMG.size is missing"
  RAW_SHA="$(cut -d' ' -f1 <"$IMG.sha256")"
  RAW_SIZE="$(cat "$IMG.size")"
  [[ $RAW_SHA =~ ^[0-9a-f]{64}$ ]] || die "$IMG.sha256 does not hold a sha256"
  [[ $RAW_SIZE =~ ^[0-9]+$ ]] || die "$IMG.size does not hold a size"
}

# ---- modes --------------------------------------------------------------------------------------------------------
do_create() {
  need zstd sha256sum sfdisk dd lsblk mountpoint
  check_device
  check_unmounted
  mount_data
  local size free
  size="$(dev_size)"
  [[ -d $DIR ]] || { ((DRY)) || mkdir -p "$DIR"; }
  [[ ! -e $IMG && ! -e $IMG.part ]] || die "$IMG (or its .part) exists already: a Rollback image is never overwritten"
  if [[ -d $DIR ]]; then
    free="$(df --output=avail -B1 "$DIR" | tail -1 | tr -d ' ')"
    ((free > size)) || die "only $free bytes free in $DIR, the device is $size bytes"
    log "free in $DIR: $((free / 1000000000)) GB, device: $((size / 1000000000)) GB"
  fi
  if ((DRY)); then
    log "(dry run) would write $IMG, $IMG.sha256, $IMG.sfdisk, $IMG.size from $DEVICE ($size bytes)"
    sfdisk -d "$DEVICE" >/dev/null || die "sfdisk cannot read the partition table of $DEVICE"
    return 0
  fi
  # the image holds the whole Arch System disk (keys, passwords): only root may read it
  chmod 700 "$DIR"
  umask 077
  sfdisk -d "$DEVICE" >"$IMG.sfdisk" || die "sfdisk -d failed"
  echo "$size" >"$IMG.size"
  local fifo shapid rc
  fifo="$(mktemp -u "$DIR/.fifo.XXXXXX")"
  mkfifo "$fifo"
  sha256sum <"$fifo" >"$IMG.sha256.part" &
  shapid=$!
  log "imaging $DEVICE ($size bytes) -> $IMG (zstd -T0)"
  local start=$SECONDS
  set +e
  dd if="$DEVICE" bs=16M iflag=fullblock status=none | progress "$size" | tee "$fifo" | zstd -T0 -3 -q -o "$IMG.part"
  rc=("${PIPESTATUS[@]}")
  set -e
  wait "$shapid" || true
  rm -f "$fifo"
  for r in "${rc[@]}"; do
    ((r == 0)) || { rm -f "$IMG.part" "$IMG.sha256.part"; die "the imaging pipeline failed (exit codes ${rc[*]})"; }
  done
  sync
  mv "$IMG.part" "$IMG"
  sed 's/  -$/  raw-device/' "$IMG.sha256.part" >"$IMG.sha256"
  rm -f "$IMG.sha256.part"
  sync
  log "imaged in $((SECONDS - start)) s: $(du -h "$IMG" | cut -f1) on disk, raw sha256 $(cut -c1-16 "$IMG.sha256")..."
  log "next: rollback-image.sh verify, then sync and umount $MOUNT before disko runs"
}

do_verify() {
  need zstd sha256sum
  mount_data
  read_recorded
  log "image: $(du -h "$IMG" | cut -f1) on disk, raw size $RAW_SIZE bytes"
  if ((DRY)); then
    log "(dry run) would run zstd -t and compare the decompressed sha256 with $IMG.sha256"
    return 0
  fi
  zstd -t -q "$IMG" || die "zstd -t failed: the image is damaged"
  local got start=$SECONDS
  got="$(zstd -dc -T0 "$IMG" | progress "$RAW_SIZE" | sha256sum | cut -d' ' -f1)"
  [[ $got == "$RAW_SHA" ]] || die "VERIFY FAILED: decompressed sha256 $got differs from the recorded $RAW_SHA"
  log "image verified in $((SECONDS - start)) s: decompresses to the recorded sha256"
  if ((AGAINST)); then
    need blockdev
    check_device
    check_unmounted
    got="$(head -c "$RAW_SIZE" "$DEVICE" | progress "$RAW_SIZE" | sha256sum | cut -d' ' -f1)"
    [[ $got == "$RAW_SHA" ]] || die "the disk $DEVICE no longer equals the image (sha256 $got)"
    log "the disk still equals the image"
  fi
}

do_restore() {
  need zstd sha256sum dd lsblk mountpoint
  check_device
  check_unmounted
  mount_data
  read_recorded
  local size answer
  size="$(dev_size)"
  ((size >= RAW_SIZE)) || die "$DEVICE is $size bytes, the image needs $RAW_SIZE"
  log "restore: $IMG ($RAW_SIZE bytes raw) -> $DEVICE ($size bytes). This overwrites the whole disk."
  if ((DRY)); then
    log "(dry run) would write the image, then read $RAW_SIZE bytes back and compare the sha256"
    return 0
  fi
  if ((!YES)); then
    read -r -p "type the device path to confirm: " answer
    [[ $answer == "$DEVICE" ]] || die "not confirmed"
  fi
  local start=$SECONDS
  zstd -dc -T0 "$IMG" | progress "$RAW_SIZE" | dd of="$DEVICE" bs=16M iflag=fullblock conv=fsync,notrunc status=none
  sync
  if [[ -b $DEVICE ]]; then blockdev --rereadpt "$DEVICE" || log "WARNING: could not re-read the partition table, reboot before using the disk"; fi
  local got
  got="$(head -c "$RAW_SIZE" "$DEVICE" | progress "$RAW_SIZE" | sha256sum | cut -d' ' -f1)"
  [[ $got == "$RAW_SHA" ]] || die "RESTORE CHECK FAILED: the disk reads back as $got, the image says $RAW_SHA"
  log "restored and read back in $((SECONDS - start)) s: sha256 equals the image"
  log "next: chown /mnt/tbssd/trrnt back to 169:169 BEFORE booting Arch (transmission/restore.sh back), then boot"
}

do_status() {
  mount_data
  read_recorded
  echo "image:    $IMG ($(du -h "$IMG" | cut -f1) on disk)"
  echo "raw size: $RAW_SIZE bytes"
  echo "raw sha:  $RAW_SHA"
  echo "table:"
  sed 's/^/  /' "$IMG.sfdisk" 2>/dev/null || echo "  (no $IMG.sfdisk)"
}

case "$MODE" in
  create) do_create ;;
  verify) do_verify ;;
  restore) do_restore ;;
  status) do_status ;;
esac
