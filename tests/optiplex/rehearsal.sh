#!/usr/bin/env bash
# Rehearsal VM for the Optiplex (impure, run on the PC). Installs nixosConfigurations.optiplex-rehearsal-restore
# with the REAL nixos-anywhere command into a qemu VM, unlocks the LUKS disk over initrd SSH from this
# machine, and runs the checks of the tier "rehearsal" (optiplex.vmTest.checks).
#
#   tests/optiplex/rehearsal.sh up [--dry-run]   create images, install, unlock, run the "restore" phase checks
#   tests/optiplex/rehearsal.sh ssh [cmd...]     ssh to the running VM as yannik (port 25560)
#   tests/optiplex/rehearsal.sh normal           deploy .#optiplex-rehearsal (restoreMode off) and run the "normal" checks
#   tests/optiplex/rehearsal.sh checks <phase>   run the checks of a phase again (restore|normal)
#   tests/optiplex/rehearsal.sh down             stop the VM, wipe images and every copied key
#
# --dry-run: uses the committed TEST secrets and the public snakeoil key instead of real ones
#   (flake output optiplex-rehearsal-dryrun). Nothing real is needed; the staging cert check cannot pass there
#   (dummy Porkbun credentials) and is skipped.
# Real run: set REHEARSAL_HOSTKEYS to a directory with etc/ssh/ssh_host_ed25519_key and ssh_host_rsa_key
#   (a copy of the Optiplex's host keys, so the real sops files decrypt: the --extra-files path is rehearsed
#   too). It is copied into the work dir and shredded by `down`. The VM then needs the PC's ssh key in the
#   authorized keys of yannik (machines/user.nix) - ssh-agent or ~/.ssh/config as usual.
#
# What stays real: the nixos-anywhere command (--extra-files, --disk-encryption-keys), the disko layout,
# the initrd unlock on 2222, the LAN address 192.168.178.20 (qemu user networking on 192.168.178.0/24 shadows
# the real LAN, so the VM can never reach or collide with the live box; ports are forwarded to 127.0.0.1 only).
# What differs: the installer is a NixOS VM that is already running (no kexec phase; the kexec rehearsal is
# separate, see the ticket), the disk is an NVMe at a different by-id name (overlay-rehearsal.nix).
#
# Real State: restore it from Backup into the Data disk by hand once `up` is done (restic restore as root in the
# VM; never forget/prune). Resource needs: ~60 GB for the Data image (sparse), 8 GB RAM, 4 cores.
# Environment: REHEARSAL_DIR (work dir, default /var/tmp/optiplex-rehearsal), DATA_SIZE (default 60G),
# REHEARSAL_RAM (default 8192), NIXOS_ANYWHERE (flake ref, default github:nix-community/nixos-anywhere).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${REHEARSAL_DIR:-/var/tmp/optiplex-rehearsal}"
DATA_SIZE="${DATA_SIZE:-60G}"
RAM="${REHEARSAL_RAM:-8192}"
NIXOS_ANYWHERE="${NIXOS_ANYWHERE:-github:nix-community/nixos-anywhere}"
DATA_UUID=70ca9b25-a1cd-46fa-bcbd-66780935c999
HOST=192.168.178.20
if command -v nixos-rebuild >/dev/null; then NIXOS_REBUILD=(nixos-rebuild); else NIXOS_REBUILD=(nix run "nixpkgs#nixos-rebuild" --); fi
cmd="${1:-}"; shift || true
if [ -e "$W/dryrun" ]; then IDFILE="$W/id_snakeoil"; IDONLY=yes; fi

log() { printf '\n==> %s\n' "$*"; }
die() { echo "rehearsal: $*" >&2; exit 1; }
state() { cat "$W/$1" 2>/dev/null || true; }

sshopts_for() { # <known_hosts file>
  echo "-o UserKnownHostsFile=$1 -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=${IDONLY:-no} ${IDFILE:+-i $IDFILE}"
}

main_ssh() { # ssh to the booted VM as yannik
  # shellcheck disable=SC2046
  ssh $(sshopts_for "$W/kh_main") -p 25560 yannik@127.0.0.1 "$@"
}

wait_for() { # <description> <tries> <command...>
  local what="$1" tries="$2"; shift 2
  for _ in $(seq 1 "$tries"); do "$@" >/dev/null 2>&1 && return 0; sleep 3; done
  die "timed out waiting for $what"
}

start_qemu_installed() { # boots the NVMe disk through OVMF + systemd-boot
  local q ovmf
  q="$(cat "$W/qemu.path")/bin/qemu-system-x86_64"
  ovmf="$(cat "$W/ovmf.path")/FV"
  [ -e "$W/OVMF_VARS.fd" ] || cp "$ovmf/OVMF_VARS.fd" "$W/OVMF_VARS.fd"; chmod u+w "$W/OVMF_VARS.fd"
  "$q" -enable-kvm -cpu host -smp 4 -m "$RAM" -nographic -serial "file:$W/console.log" -monitor none \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf/OVMF_CODE.fd" \
    -drive "if=pflash,format=raw,unit=1,file=$W/OVMF_VARS.fd" \
    -drive "file=$W/system.img,if=none,id=sys,format=raw" -device nvme,serial=REHEARSAL0001,drive=sys,bootindex=1 \
    -drive "file=$W/data.img,if=none,id=data,format=raw" -device virtio-blk-pci,drive=data \
    -netdev "user,id=n0,net=192.168.178.0/24,host=192.168.178.1,hostfwd=tcp:127.0.0.1:2222-192.168.178.20:2222,hostfwd=tcp:127.0.0.1:25560-192.168.178.20:25560,hostfwd=tcp:127.0.0.1:8443-192.168.178.20:443" \
    -device "virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56" &
  echo $! > "$W/qemu.pid"
}

do_down() {
  log "stopping the VM, wiping images and keys"
  for p in "$W/qemu.pid" "$W/installer.pid"; do
    [ -e "$p" ] && kill "$(cat "$p")" 2>/dev/null || true
  done
  sleep 1
  if [ -d "$W" ]; then
    find "$W" -type f \( -name '*key*' -o -name 'secret*' -o -name 'ssh_host_*' -o -name 'id_*' \) -exec shred -u {} + 2>/dev/null || true
    rm -rf "$W"
  fi
}

do_checks() { # <phase>
  local phase="$1" checks
  local pkg=optiplex-rehearsal-checks
  [ -e "$W/dryrun" ] && pkg=optiplex-rehearsal-dryrun-checks
  checks="$(nix build --no-link --print-out-paths "$repo#$pkg-$phase")"
  # shellcheck disable=SC2046
  REHEARSAL_SSH="ssh $(sshopts_for "$W/kh_main") -p 25560 yannik@127.0.0.1" python3 -I "$repo/tests/optiplex/rehearsal-shim.py" "$checks"
}

case "$cmd" in
  up)
    dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    [ -e "$W" ] && die "$W exists; run '$0 down' first"
    [ -c /dev/kvm ] || die "no /dev/kvm"
    avail_gb=$(df -BG --output=avail "$(dirname "$W")" | tail -1 | tr -dc 0-9)
    [ "$avail_gb" -ge 100 ] || echo "WARNING: only ${avail_gb} GB free under $(dirname "$W"); the plan assumes ~100 GB" >&2
    mkdir -p "$W"; chmod 700 "$W"
    trap 'echo "up failed; the VM and images are kept in $W for inspection. Run: $0 down"' ERR
    cd "$repo"

    log "building the pieces"
    nix build --no-link --print-out-paths .#optiplex-rehearsal-qemu > "$W/qemu.path"
    nix build --no-link --print-out-paths .#optiplex-rehearsal-ovmf > "$W/ovmf.path"
    installer="$(nix build --no-link --print-out-paths .#optiplex-rehearsal-installer)"
    if [ "$dry" = 1 ]; then
      flake_attr=optiplex-rehearsal-dryrun; touch "$W/dryrun"
      install -m600 "$(nix build --no-link --print-out-paths .#test-ssh-key)" "$W/id_snakeoil"
      installer_key="$W/id_snakeoil"; IDFILE="$W/id_snakeoil"; IDONLY=yes
    else
      flake_attr=optiplex-rehearsal-restore
      [ -n "${REHEARSAL_HOSTKEYS:-}" ] && [ -e "$REHEARSAL_HOSTKEYS/etc/ssh/ssh_host_ed25519_key" ] \
        || die "set REHEARSAL_HOSTKEYS to a dir with etc/ssh/ssh_host_{ed25519,rsa}_key (copy of the host keys), or use --dry-run"
      # the installer VM only trusts the public snakeoil key; nixos-anywhere talks to it with that
      install -m600 "$(nix build --no-link --print-out-paths .#test-ssh-key)" "$W/id_snakeoil"
      installer_key="$W/id_snakeoil"
    fi

    log "images: System disk (NVMe), Data disk (ext4, real UUID, sparse $DATA_SIZE)"
    truncate -s 24G "$W/system.img"
    truncate -s "$DATA_SIZE" "$W/data.img"
    mkdir -p "$W/seed/state"
    mkfs.ext4 -q -F -U "$DATA_UUID" -L tbssd -E root_owner=0:0 -d "$W/seed" "$W/data.img"

    log "keys: LUKS passphrase, dedicated initrd host key, main host keys (--extra-files)"
    umask 077
    head -c 24 /dev/urandom | base64 -w0 > "$W/secret.key"
    mkdir -p "$W/extra/etc/secrets/initrd" "$W/extra/etc/ssh"
    ssh-keygen -q -t ed25519 -N '' -C rehearsal-initrd -f "$W/extra/etc/secrets/initrd/ssh_host_ed25519_key"
    if [ "$dry" = 1 ]; then
      ssh-keygen -q -t ed25519 -N '' -C rehearsal-main -f "$W/extra/etc/ssh/ssh_host_ed25519_key"
      ssh-keygen -q -t rsa -b 4096 -N '' -C rehearsal-main -f "$W/extra/etc/ssh/ssh_host_rsa_key"
    else
      cp "$REHEARSAL_HOSTKEYS"/etc/ssh/ssh_host_ed25519_key "$REHEARSAL_HOSTKEYS"/etc/ssh/ssh_host_rsa_key "$W/extra/etc/ssh/"
      ssh-keygen -y -f "$W/extra/etc/ssh/ssh_host_ed25519_key" > "$W/extra/etc/ssh/ssh_host_ed25519_key.pub"
    fi
    # nixos-anywhere keeps the modes of the --extra-files tree. /etc/ssh must stay 0755: sshd's unprivileged
    # child reads /etc/ssh/authorized_keys.d/<user> and a 0700 /etc/ssh (from umask 077) locks everybody out.
    chmod 755 "$W/extra" "$W/extra/etc" "$W/extra/etc/ssh"
    chmod 700 "$W/extra/etc/secrets" "$W/extra/etc/secrets/initrd"
    echo "[127.0.0.1]:2222 $(cut -d' ' -f1,2 "$W/extra/etc/secrets/initrd/ssh_host_ed25519_key.pub")" > "$W/kh_initrd"
    echo "[127.0.0.1]:25560 $(cut -d' ' -f1,2 "$W/extra/etc/ssh/ssh_host_ed25519_key.pub")" > "$W/kh_main"
    cmp -s <(cut -d' ' -f2 "$W/extra/etc/secrets/initrd/ssh_host_ed25519_key.pub") <(cut -d' ' -f2 "$W/extra/etc/ssh/ssh_host_ed25519_key.pub") \
      && die "initrd key equals the main key"

    log "starting the installer VM (blank NVMe System disk, Data disk attached)"
    export NIX_DISK_IMAGE="$W/installer-root.qcow2"
    export QEMU_NET_OPTS="net=192.168.178.0/24,host=192.168.178.1,hostfwd=tcp:127.0.0.1:2200-:22"
    export QEMU_OPTS="-cpu host -drive file=$W/system.img,if=none,id=sys,format=raw -device nvme,serial=REHEARSAL0001,drive=sys -drive file=$W/data.img,if=none,id=data,format=raw -device virtio-blk-pci,drive=data"
    ( "$installer"/bin/run-*-vm > "$W/installer.log" 2>&1 & echo $! > "$W/installer.pid" )
    ISSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -i $installer_key -o IdentitiesOnly=yes -p 2200 root@127.0.0.1"
    wait_for "the installer VM (ssh on 2200)" 120 $ISSH true
    # the disk must be the one the config expects (by-id name of the qemu NVMe)
    $ISSH 'ls /dev/disk/by-id/ | grep -q nvme-QEMU_NVMe_Ctrl_REHEARSAL0001' || die "NVMe System disk not visible in the installer"

    log "nixos-anywhere (disko + install; --extra-files, --disk-encryption-keys)"
    nix run "$NIXOS_ANYWHERE" -- \
      --flake ".#$flake_attr" \
      --extra-files "$W/extra" \
      --disk-encryption-keys /tmp/secret.key "$W/secret.key" \
      --phases disko,install \
      --ssh-port 2200 -i "$installer_key" \
      --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no \
      --build-on local \
      root@127.0.0.1

    log "restarting from the installed NVMe disk (OVMF, systemd-boot)"
    $ISSH 'sync' || true
    kill "$(cat "$W/installer.pid")"; rm -f "$W/installer.pid"; sleep 2
    start_qemu_installed

    log "unlock over initrd SSH on 2222 from this machine"
    # qemu's port forward accepts connections before the guest listens, so probe with a real ssh login
    # (host key pinned to the dedicated initrd key) instead of a port check
    initrd_ssh() { ssh $(sshopts_for "$W/kh_initrd") -p 2222 root@127.0.0.1 "$@"; }
    # shellcheck disable=SC2046
    wait_for "the initrd sshd on 2222 (ssh as root; for a real run the PC's key must be in yannik's authorized keys)" 200 initrd_ssh true
    # shellcheck disable=SC2046
    ssh $(sshopts_for "$W/kh_initrd") -p 2222 root@127.0.0.1 'systemd-tty-ask-password-agent --query' < "$W/secret.key" || true
    log "waiting for the booted system on 25560 (host key pinned to the MAIN key)"
    wait_for "sshd on 25560" 200 main_ssh true
    main_ssh 'hostname; systemctl is-system-running || true; findmnt -n -o TARGET,SOURCE,OPTIONS /; swapon --show'

    log "checks, phase restore"
    do_checks restore
    trap - ERR
    cat <<EOF

The rehearsal VM is up (restoreMode on). Next:
  $0 ssh                     shell as yannik (sudo -i for root)
  restore State from Backup into /state (restic restore as root; never forget/prune), run the service rehearsals
  $0 normal                  the normal deploy (restoreMode off) + phase "normal" checks
  $0 down                    stop and wipe everything (images, keys)
Console log: $W/console.log
EOF
    ;;
  ssh) main_ssh "$@" ;;
  normal)
    [ -d "$W" ] || die "no rehearsal running"
    cd "$repo"
    attr=optiplex-rehearsal; [ -e "$W/dryrun" ] && attr=optiplex-rehearsal-dryrun-normal
    NIX_SSHOPTS="-o UserKnownHostsFile=$W/kh_main -p 25560 ${IDFILE:+-i $IDFILE -o IdentitiesOnly=yes}" \
      "${NIXOS_REBUILD[@]}" switch --flake ".#$attr" --target-host yannik@127.0.0.1 --sudo \
      || echo "(nixos-rebuild exited non-zero: expected when a VM-only unit fails, e.g. smartd; the failed-units check decides)"
    do_checks normal
    ;;
  checks) [ -d "$W" ] || die "no rehearsal running"; do_checks "${1:?phase: restore|normal}" ;;
  down) do_down ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
