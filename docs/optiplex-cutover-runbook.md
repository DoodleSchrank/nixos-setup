# Optiplex Cutover runbook

The ordered procedure for the **Cutover** of the **Optiplex**: Arch is stopped, the **System disk** is wiped, NixOS is installed and the **State** is restored. It covers everything from the go/no-go gate through the downtime window to the go decision, the rollback, and the follow-ups that come after verification.

- Written 2026-11-14 from ticket 42 of the migration (`.scratch/optiplex-nixos-migration/`, local only), its review notes and the measurements of the real-State rehearsal (ticket 48). The tickets of the individual services own the internals (State subpaths, ownership, upgrade steps); this document puts them in order and adds the cross-cutting steps.
- It is executed in ticket 43 (HITL): the agent runs the commands and keeps the log, the human works the FritzBox, Porkbun and the client devices and says go or no-go.
- **Status of the unverified parts.** Two tickets were still being worked on while this was written. Every step that rests on an unproven assumption carries a marker:
  - Ticket 45 (rehearsals) is resolved: the nixos-anywhere pin and the offline install flags are recorded and used below. **Decision 2026-11-14 (human): the Cutover goes the USB-installer route, not kexec** (the stock kexec installer has no `r8169` driver for the Optiplex's NIC: see 5.10). What the rehearsals could not show stays under "Not verified" at the end.
  - `PENDING 39B`: the battle-tracker service on the Optiplex (ticket 39, part B): flake input, the `pnp` vhosts, the deploy unit, the webhook, and the app-repo change that deletes the Docker deployment.
  - Open questions for the human are in Appendix B.

## 0. How to read this

### Actors and places

| Who | Meaning |
|---|---|
| **Human** | Yannik: FritzBox and Porkbun UIs, Gitea admin UI, devices, physical access, the go/no-go. |
| **Agent** | Runs the command in a terminal (on the PC, through ssh on Arch or the Optiplex) and records it in the log of ticket 43. Never improvises: a deviation is logged first. |

| Where | Meaning |
|---|---|
| **PC** | Yannik's desktop (Arch, repository checkout `~/nixos-setup`, age key, sops, nix). |
| **Arch** | The live server before the wipe (`ssh optiplex` while it is Arch: sshd on 25560, user `yannik`, passwordless sudo; root login is impossible). |
| **Installer** | The Optiplex booted from the installer USB stick (root ssh on port 22, our ISO `nixosConfigurations.optiplex-installer`). Needs the human at the box with monitor and keyboard. |
| **NixOS Optiplex** | The installed system (`ssh optiplex`, port 25560, user `yannik`, sudo). |

Every step lists **Who / where / time**, the **Do** (exact command or UI action) and the **Check** that proves it worked. Times are estimates unless the text says *measured*. Secrets appear only by sops file and key name, never as values. A command that needs a secret reads it from sops or from the host and pipes it; nothing is typed or printed.

### Conventions on the PC

Commands for **Arch** are written as typed in a root shell on Arch (`ssh optiplex`, then `sudo -i`); the same for the Optiplex once it is NixOS (`ssh optiplex`, `sudo`). Lines that start with `ssh`, `scp`, `nix`, `sops`, `curl` against the PC's own files, or that name the PC, run on the PC.

```sh
cd ~/nixos-setup                                  # the exact commit that was tested (git status clean)
X=/run/user/$(id -u)/optiplex-cutover             # tmpfs: --extra-files tree, passphrase file; shredded in 16.8
HK=~/.local/share/optiplex-hostkeys               # copy of the Optiplex's host keys (ticket 44 shreds it, not the Cutover)
NIXOS_ANYWHERE=github:nix-community/nixos-anywhere/58132e1d1f813b845382a2aeca4203b18d2ac807   # the pin of tests/optiplex/rehearsal.sh (ticket 45); bump deliberately, rehearse again
OPTI=192.168.178.20
```

`nixos-rebuild` on the PC (Arch) is `nix run nixpkgs#nixos-rebuild --`. The Optiplex deploys are built on the PC (`--build-host localhost`), because Paperless and the etesync overlay are not in the binary cache (the deploy command needs `NIX_SSHOPTS`: step 11.2). `nc` is not installed on the PC (step 8.1 uses `/dev/tcp`); the Optiplex has no `jq` and no `dig`, so JSON and DNS checks run from the PC (or use `curl ... | grep -o` on the box).

### Rules that hold for the whole window

1. **No `pacman -Syu` on Arch** until the Cutover is verified: it would move Synapse to 1.165.0, past the lock's 1.164.2 (a downgrade Synapse does not support), and PostgreSQL, coturn and transmission with it. Do not reboot Arch either: the four Seafile containers have `restart=no` and stay down.
2. **Arch trees are copied, never moved or modified.** `/mnt/tbssd/docker`, `/mnt/tbssd/filesync` and everything else on the Data disk stay as they were, because the rollback needs them. Stale copies are never restored: `/var/lib/postgres/olddata`, `synapse_backup.sql`, `/data/compose/{33,34}/postgres`, `/vw-data`, `/srv/elabftw`, `/opt/seafile/mysql/db`. elabFTW is dropped completely (no export, no step).
3. **Never start a service against an empty database.** The restore order is fixed: databases, per-service State, then the one normal deploy.
4. **Never forward port 2222** (initrd unlock) at the router.
5. **Deviations are logged in ticket 43 before they are run.**

### What the rehearsals measured (so the numbers below are not guesses)

Ticket 48 ran the whole restore on the real State in the rehearsal VM, on the PC (Ryzen 9 7900X, guest 4 vCPU and 7 GB RAM, NVMe-backed image). The Optiplex (Intel i5-10500T, 12 threads, 15 GB RAM, Data disk a SATA SSD) is slower: plan on a small multiple, not on the same numbers.

| What | Measured on the PC |
|---|---|
| `optiplex-db-restore`, all 8 databases | **102 s**; Synapse **87 s**; the other seven 0 to 7 s each (`seahub_db` 7 s, `gitea` and `seafile_db` 2 s) |
| Copy of the restored State tree into the VM (49.9 GB, 118,562 files) | 2 min 20 s |
| `restic restore` of the gate snapshot from the local repository to the PC (46.494 GiB) over ssh | 6 min 48 s |
| First normal deploy: every service active | within 25 s of the deploy (4 vCPU guest) |
| Synapse first start (1.156.0 data under 1.164.2) | 8.9 s |
| Gitea migration 1.26.4 to 28.3.0 (27 migrations) | about 1 s |
| Paperless (3.2.1 to 3.3.4, 3 migrations) | about 12 s |
| Seafile 12 to 13 | upgrade ran, 13.0.29, `/api2/ping/` = `"pong"`, 19 rows in `RepoInfo` (the 18 libraries plus the built-in template), 9 share links, 22 GB of blocks |
| Synapse dump on Arch (ticket 10) | 136 s |

Findings from that run that this runbook acts on: healthchecks needs its first user (step 11.4); `smartd` is red only in VMs (it must be green on the real disks); the bridges logged `One time key ... already exists` (a watch item, step 11.3); `optiplex-gitea` must run from a readable directory (fixed in the repo, ticket 48).

---

## 1. Preconditions (go/no-go list)

**Who:** agent runs the checks, human decides. **Where:** PC unless noted. **Time:** 1 to 2 h in total (the VM harness is most of it), done at least a day before. **Any open item means no-go and a new date.** The agent writes each result into the go/no-go log in ticket 43.

| # | Precondition | Check |
|---|---|---|
| 1.1 | Tickets 27 to 41, 45 to 48 are resolved. `PENDING 39B`: 39 (part B) is still open when this is written. | map `Open work` lines ticked |
| 1.2 | The toplevels build on the exact commit that will be deployed, and the tree is clean. | `git status --short` prints nothing; `git rev-parse HEAD` is noted in the log. `nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel .#nixosConfigurations.optiplex.config.system.build.toplevel` succeeds |
| 1.3 | The VM harness passes on the **committed** tree (a file that is not `git add`ed makes a flake build differ from the working tree). One run at a time, memory under 10 GB. | `drv=$(nix eval --raw .#checks.x86_64-linux.optiplex-vm.drvPath) && nix build "$drv^*" -L --no-link` passes (about 14 min, 835 s in ticket 46). Hard memory cap if needed: `sudo systemctl set-property --runtime nix-daemon.service MemoryHigh=9G MemoryMax=10G` |
| 1.4 | The rehearsals with real State passed (ticket 48): restore, DB restore with times, State placement, first normal deploy, goolm. The measured Synapse restore time is in section 18's timing table. | ticket 48 Answer |
| 1.5 | **Backup gate.** A restic run from Arch was restored and `gate-verify.sh` said "all good". The full State restore ran from the local repository: snapshot `5692f949` (2026-11-14 18:22, 118,562 files, 46.494 GiB; `ccnet/` is an empty directory on Arch, so nothing was ever missing). The bucket was test-restored on 2026-11-14 (snapshot `2c253959`: endpoint, credentials and One Zone retrieval work, the 3 SQLite copies match the manifest and pass `integrity_check`); no new bucket upload was made (decided). | the log of ticket 48 and human-todos |
| 1.6 | The local Backup repository exists and holds an `arch-gate` snapshot (the NixOS job `optiplex-local` never initialises it and would fail every night). If it does not: `sudo infra/scaleway/arch-gate.sh --env-file /root/restic-gate.env --init --local-only` on Arch (README "The pre-Cutover gate"). | on Arch: `ls /mnt/tbssd/restic-local/snapshots \| wc -l` is at least 1 |
| 1.7 | Every `secrets/optiplex/*.yaml` the config references exists with all its keys, and `gitea-runners.yaml` does **not** exist yet (the tokens come after the Cutover). | `for f in secrets/optiplex/*.yaml; do echo "== $f"; sops -d --output-type json "$f" \| jq -r 'keys[]'; done` (key names only); `tests/optiplex/gen-test-secrets.sh --check` reports only `gitea-runners.yaml`; `nix eval --json .#nixosConfigurations.optiplex.config.warnings` is `[]` |
| 1.8 | The LUKS passphrase is readable: `secrets/luks.yaml`, key `luks_passphrase`. There is no printout of it: the age key is the only way. | `sops -d --extract '["luks_passphrase"]' secrets/luks.yaml \| wc -c` prints 64 (a length, not the value) |
| 1.9 | Key custody (human): the age key (`~/.config/sops/age/keys.txt`) has a Vaultwarden copy and a printout, and so have the restic repository password, the bucket key and the OpenTofu state passphrase. `unlock-optiplex.sh` unlocked the rehearsal VM (ticket 45). | human confirms |
| 1.10 | The host-key copy on the PC is the live host's key, and its public half is the sops `optiplex` recipient. | `ssh-keygen -y -f $HK/etc/ssh/ssh_host_ed25519_key \| ssh-to-age` prints the `optiplex` age recipient of `secrets/.sops.yaml` (`grep -c "$(ssh-keygen -y -f $HK/etc/ssh/ssh_host_ed25519_key \| ssh-to-age)" secrets/.sops.yaml` is 1); `sha256sum $HK/etc/ssh/ssh_host_ed25519_key` equals `ssh optiplex 'sudo sha256sum /etc/ssh/ssh_host_ed25519_key'` (hash only) |
| 1.11 | Versions in the lock are not older than the live ones (migrations only go forward), and the live versions are the ones the rehearsal used. Day-of version check: step 4.3. | see step 4.3 |
| 1.12 | The Data disk has room: the Rollback image (at most 238 GB, the NVMe's size), about 35 GB of copied State, about 2.5 GB of dumps per run, the stage directories `arch-gate/<ts>` (1.9 GB per run so far) and the local restic repository (about 46 GiB, growing). Free was 712 G on 2026-11-14 before the local repository. | on Arch: `df -h /mnt/tbssd` shows at least 300 GB free; `du -sh /mnt/tbssd/{restic-local,arch-gate}` |
| 1.13 | The installer ISO is built and on the stick in the Optiplex (step 2.7), the nixos-anywhere pin is in the store (step 2.8), **a monitor and a keyboard are at the Optiplex for the whole install and for a rollback**. | steps 2.7, 2.8 |
| 1.14 | The PC can build and deploy with `git.nnik.dev` down (`PENDING 39B`): step 3.3 passes. | step 3.3 |
| 1.15 | `ssh optiplex` reaches the box **by address**, not by `opti.plex` (LAN DNS is the FritzBox during the window). | `ssh -G optiplex \| grep -E '^(hostname\|port\|user) '` shows `hostname 192.168.178.20`, `port 25560`, `user yannik` |
| 1.16 | The battle-tracker app-repo change that deletes the Docker deployment (`deploy-web.yml`, `sync-server-image.yml`, `deploy/docker-compose.yml`, the Dockerfiles, the Portainer runbook) is ready to merge. `PENDING 39B`. | PR open and reviewed |
| 1.17 | The window: 5 h blocked, the human at home with physical access to the Optiplex and a phone on mobile data. Nothing else is running on the LAN that the window would hurt (Matrix users are not warned, by decision). | human confirms |
| 1.18 | The **rollback time box**: decided 2026-11-11 as **24 h after Arch stops**. The wall-clock end is recorded at step 4.8. | log |

---

## 2. Days before (Arch keeps running)

Do these early; none of them hurts Arch.

### 2.1 Lower the FritzBox DHCP lease time
- **Who / where / time:** human, FritzBox UI, 5 min, **one day before**.
- **Do:** lower the DHCP lease time of the home network, so clients pick up the DNS change of step 4.2 quickly.
- **Check:** the PC's lease is short (`nmcli -f DHCP4.OPTION con show "$(nmcli -t -f NAME con show --active | head -1)" | grep -i lease`).

### 2.2 Porkbun: look at the TTLs and record the records
- **Who / where / time:** human, Porkbun UI, 10 min.
- **Do:** the earlier plan wanted 300 s TTLs; Porkbun's minimum is 600 s, so that is void. The zone has **no plain apex A record** (found on the day, 2026-11-15): it has the ALIAS records `nnik.dev` and `www.nnik.dev` (both to `nnik.duckdns.org`, TTL 600) and the `*` CNAME (to `nnik.duckdns.org`), and no AAAA (the clean starting state): nothing to lower. **Write the current records down again** (the two ALIAS records, the `*` CNAME, targets and TTLs) into the log on the day: the rollback restores exactly these (step 15.5). (The updater later writes TTL 600.)
- **Check:** the list is in the log.

### 2.3 FritzBox shares for coturn and 3478/51413
- **Who / where / time:** human, FritzBox UI, 10 min. Harmless for Arch.
- **Do:** add the port share **UDP 49152-49252 to 192.168.178.20** (the coturn relay range). Check that the shares for **3478** and **51413** cover **both TCP and UDP**. Do not add 2222.
- **Check:** the FritzBox share list shows the range and both protocols on 3478 and 51413.

### 2.4 `~/.ssh/config`: port 25580 for the four Gitea aliases
- **Who / where / time:** agent or human, PC, 2 min.
- **Do:** add `Port 25580` to the four portless aliases `story-review`, `issue`, `wiki`, `improve`. Gitea's built-in SSH is on 25580 on the new system; Arch's Gitea container also publishes 25580, so the aliases work on both.
- **Check:** `ssh -G story-review | grep '^port '` prints `port 25580` (repeat for the other three).

### 2.5 Generate the install keys and assemble the `--extra-files` tree
- **Who / where / time:** agent, PC, 5 min. Everything in the tmpfs directory `$X`; nothing of it touches the disk.
- **Do:**
  ```sh
  umask 077; mkdir -p "$X"
  # the dedicated initrd host key: made once, kept next to the host-key copy (never the main key)
  [ -e $HK/etc/secrets/initrd/ssh_host_ed25519_key ] || { mkdir -p $HK/etc/secrets/initrd; ssh-keygen -q -t ed25519 -N '' -C optiplex-initrd -f $HK/etc/secrets/initrd/ssh_host_ed25519_key; }
  rm -rf "$X/extra"; mkdir -p "$X/extra/etc/ssh" "$X/extra/etc/secrets/initrd"
  cp $HK/etc/ssh/ssh_host_ed25519_key $HK/etc/ssh/ssh_host_rsa_key "$X/extra/etc/ssh/"
  ssh-keygen -y -f "$X/extra/etc/ssh/ssh_host_ed25519_key" > "$X/extra/etc/ssh/ssh_host_ed25519_key.pub"
  ssh-keygen -y -f "$X/extra/etc/ssh/ssh_host_rsa_key" > "$X/extra/etc/ssh/ssh_host_rsa_key.pub"
  cp $HK/etc/secrets/initrd/ssh_host_ed25519_key "$X/extra/etc/secrets/initrd/"
  # nixos-anywhere keeps these modes: /etc and /etc/ssh must stay 0755 (a 0700 /etc/ssh locks yannik out of sshd at the first boot)
  chmod 755 "$X/extra" "$X/extra/etc" "$X/extra/etc/ssh"
  chmod 700 "$X/extra/etc/secrets" "$X/extra/etc/secrets/initrd"
  chmod 600 "$X"/extra/etc/ssh/ssh_host_{ed25519,rsa}_key "$X/extra/etc/secrets/initrd/ssh_host_ed25519_key"
  chmod 644 "$X"/extra/etc/ssh/*.pub
  # the LUKS passphrase file: no trailing newline, the remote path is the one disko's passwordFile names
  sops -d --extract '["luks_passphrase"]' secrets/luks.yaml > "$X/secret.key"; chmod 600 "$X/secret.key"
  ```
- **Check:** `stat -c '%a %n' $X/extra $X/extra/etc $X/extra/etc/ssh $X/extra/etc/secrets/initrd` prints 755, 755, 755, 700; the key files are 600; `wc -c < $X/secret.key` is 64; the initrd key differs from the main key (`diff <(cut -d' ' -f2 $HK/etc/secrets/initrd/ssh_host_ed25519_key.pub) <(cut -d' ' -f2 $X/extra/etc/ssh/ssh_host_ed25519_key.pub)` must **differ**; if `$HK/etc/secrets/initrd/…pub` is missing run `ssh-keygen -y` on it first); the main key fingerprint equals the live one: `ssh-keygen -lf $X/extra/etc/ssh/ssh_host_ed25519_key.pub` equals `ssh-keyscan -p 25560 $OPTI 2>/dev/null | ssh-keygen -lf - | grep ED25519`.

### 2.6 Check the installer's disk by-id
- **Who / where / time:** agent, Arch (read-only; a root shell there is `ssh optiplex`, then `sudo -i`), 1 min.
- **Do:** `ls -l /dev/disk/by-id/ | grep -i kioxia`.
- **Check:** the NVMe `nvme-KBG40ZNS256G_NVMe_KIOXIA_256GB_21LPG2BCQL42` is listed (the name in `machines/optiplex/disko.nix` and the default of `rollback-image.sh`).

### 2.7 Build the installer ISO and put it on the stick in the Optiplex
- **Who / where / time:** agent builds on the PC, **human confirms the device**, 10 min. **The stick is the install route** (the Cutover does not use kexec) and the rollback medium: monitor and keyboard are needed at the Optiplex from the start of the install (step 5.10) and again for a rollback (step 15).
- **Do:**
  ```sh
  nix build .#nixosConfigurations.optiplex-installer.config.system.build.isoImage --out-link $X/installer   # about 1.5 GB
  ssh optiplex 'lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS'
  ```
  The human identifies the **empty 7.5 GB USB stick** ("Slim Line", `/dev/sdb` on Arch, one partition `sdb1` with no filesystem; the human approved using it). The Data disk is the 3.6 TB SATA disk and must never be written. Then, with the stick's stable name `<by-id>` from `ls -l /dev/disk/by-id/ | grep usb`:
  ```sh
  ssh optiplex 'sudo dd of=/dev/disk/by-id/<by-id> bs=4M conv=fsync status=none' < $X/installer/iso/*.iso
  ```
- **Check:** `ssh optiplex 'sudo head -c <iso size in bytes> /dev/disk/by-id/<by-id> | sha256sum'` equals `sha256sum $X/installer/iso/*.iso`. The stick holds root-SSH for yannik's keys, zstd, pv, rsync, restic, ssh-to-age and the `rollback-image` command. The ISO was booted once in qemu on 2026-11-14 (UEFI, 2 GB RAM, user networking, a throwaway 2 GB disk): ssh was up after about 16 s, the address came by DHCP, root ssh with yannik's keys worked, `rollback-image`, zstd, pv, rsync, restic, ssh-to-age, sfdisk, cryptsetup, btrfs and ethtool were present and the kernel has the `r8169` module (qemu has a virtio NIC, so the real NIC stays untested). **Booting it on the real box cannot be tested without rebooting Arch (which must not happen) and is first done at the window.**

### 2.8 Pin nixos-anywhere
- **Who / where / time:** agent, PC, 5 min. There is no kexec tarball: the Cutover boots the stick.
- **Do:** `nix build --no-link "$NIXOS_ANYWHERE"` (the pinned ref of the conventions: nixos-anywhere itself is then in the store).
- **Check:** `nix run "$NIXOS_ANYWHERE" -- --help` prints the options used in steps 8 and 3.3 (`--phases`, `--extra-files`, `--disk-encryption-keys`, `--build-on`, `--no-substitute-on-destination`, `--no-use-machine-substituters`, `--store-paths`).

### 2.9 Seed the Archive and start the pre-sync
- **Who / where / time:** agent, Arch, 15 to 40 min the first time (Synapse media 25 GB and Seafile blocks 22 GB), minutes afterwards. The scripts run from a fresh clone on Arch at **the same commit as the PC** (`$REPO_ARCH`; the human pushes everything first).
- **Do:**
  ```sh
  REPO_ARCH=~/cutover-repo
  git clone https://github.com/DoodleSchrank/nixos-setup.git $REPO_ARCH      # public repository, no key needed
  git -C $REPO_ARCH checkout <the Cutover commit>; git -C $REPO_ARCH rev-parse HEAD     # equals the PC's
  rm -rf ~/gate-run                                                          # the throwaway partial copy of an earlier gate run
  cd $REPO_ARCH
  sudo machines/optiplex/cutover/sync-state.sh --list
  sudo machines/optiplex/cutover/sync-state.sh --dry-run          # sources exist, flags valid, file counts
  sudo machines/optiplex/cutover/sync-state.sh                    # pre-sync rows: synapse, seafile, www, archive (.zsh_history)
  ```
  Repeat the last command daily. It only transfers what changed and never deletes.
- **Check:** `/mnt/tbssd/archive/arch-optiplex/.zsh_history` exists (mode 0700 directory); `du -sh /mnt/tbssd/state/{synapse,seafile,www}` show roughly 25 GB, 22 GB, 130 MB; a second run reports almost no transfers.

### 2.10 Day before the window: the other checks
- **Who:** human and agent.
- **Do:** nothing runs on Arch that was not already there; no `pacman -Syu`; `docker ps -a` shows the four Seafile containers up (they have `restart=no`: if Arch rebooted since, start them); the phone is charged; the ntfy and probe apps are installed later (step 16.9).
- **Check:** `docker ps --format '{{.Names}}' | wc -l` on Arch is the number noted in the log of the last check.

---

## 3. Build ahead (PC)

**Who / where / time:** agent, PC, 20 to 60 min (the first build of everything), the day before. After this nothing in the window may need `git.nnik.dev`, LAN DNS or a cold build.

### 3.1 Put every locked input and both systems in the store
- **Do:**
  ```sh
  nix flake archive                                                       # every locked input, including the battle-tracker input from git.nnik.dev (PENDING 39B)
  nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel
  nix build --no-link .#nixosConfigurations.optiplex.config.system.build.toplevel
  nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.diskoScript
  ```
- **Check:** all four succeed; the two toplevel paths are noted in the log (`nix path-info`): the Optiplex must end on the second one (step 11.6).

### 3.2 Check the lock against the live versions
- Step 4.3 repeats this on the day. Here it decides the date: if the lock holds an older version than the live system for Synapse, Paperless, Vaultwarden, Home Assistant, Gitea or transmission, fix the config first.

### 3.3 Prove the build works with the network and `git.nnik.dev` unavailable
- **Do:** `nix build --offline --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel .#nixosConfigurations.optiplex.config.system.build.toplevel .#nixosConfigurations.optiplex-restore.config.system.build.diskoScript`
- **Check:** it completes without fetching anything (all paths are already in the store). `PENDING 39B`: until the battle-tracker input exists in `flake.lock` and has been archived, this is what proves that the locked input can be used while Gitea is down. Ticket 45 rehearsed the install with `--no-substitute-on-destination --no-use-machine-substituters --build-on local` (the PC pushes the closure; nothing needs the installer's network): step 8 uses those flags.

---

## 4. T-0 on Arch: start the window, live-Gitea steps, stop every consumer

**Time of the whole section:** 30 to 60 min. The rollback time box (24 h) starts when the first consumer is stopped (step 4.8).

### 4.1 Go and note the times
- **Who / where:** human decides, agent logs. PC.
- **Do:** the human says go. The agent records the start time in the log (the time-box end, 24 h after Arch stops, is filled in at step 4.8), the commit hash (`git rev-parse HEAD`), and the two toplevel paths of step 3.1.
- **Check:** ticket 43's go/no-go log is complete and signed off.

### 4.2 The FritzBox hands out itself as LAN DNS
- **Who / where / time:** human, FritzBox UI, 5 min.
- **Do:** set the DNS server that the FritzBox hands out by DHCP to the FritzBox itself, `192.168.178.1` (instead of `.20`, Arch's Pi-hole). Blocky on the new system cannot answer before the box is installed, and Pi-hole stops in step 5.8. The PC's own resolver is **not** edited by hand (the lease time was lowered in 2.1).
- **Check:** on the PC, renew the lease (`nmcli con up "$(nmcli -t -f NAME con show --active | head -1)"`) and `getent hosts nnik.dev` answers; `resolvectl status` or `/etc/resolv.conf` shows `192.168.178.1`.
- **Also here (human, phone, 1 min):** pause the phone's probe app, or decide to accept the host-down alerts for the window (the open point of ticket 43). Un-pause it in step 16.9.

### 4.3 Day-of version check and the rest of the Arch record
- **Who / where / time:** agent, Arch (read-only) and PC, 10 min. No `pacman -Syu` ran: `pacman -Q matrix-synapse` must still say **1.156.0**.
- **Do:**
  ```sh
  # on Arch (root shell)
  pacman -Q matrix-synapse; mautrix-whatsapp --version; /srv/matrix-services/mautrix-telegram/mautrix-telegram --version
  docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' gitea paperless-webserver-1 seafile vaultwarden homeassistant
  cat /srv/homeassistant/.HA_VERSION; ls -l /mnt/tbssd/filesync/seafile | grep seafile-server-latest
  # on the PC
  for a in matrix-synapse gitea paperless vaultwarden home-assistant transmission postgresql; do printf '%s ' $a; nix eval --raw .#nixosConfigurations.optiplex.config.services.$a.package.version; echo; done
  ```
- **Check:** the live versions equal the ones of 2026-11-14, or the lock is not older than them:

  | Component | Live on 2026-11-14 | In the lock (2026-11-14) | Rule |
  |---|---|---|---|
  | Synapse | 1.156.0 (pacman) | 1.164.2 | lock must be at least live; `synapse.nix` asserts at least 1.156.0 |
  | mautrix-whatsapp | v26.07+dev.09ec71d2 | 26.10 | lock not older |
  | mautrix-telegram | v26.10+dev.9621bd4c | main commit `a36e68b` (7 commits ahead of live) | a live commit later than `a36e68b` needs a bump of the pin |
  | coturn / transmission / PostgreSQL | 4.11.0 / 4.1.1 / 18.3 | module versions (transmission 4.1.4, PostgreSQL 18.6) | not older |
  | Gitea | 1.26.4 (`docker.gitea.com/gitea:latest`) | 28.3.0 | at least 28.3.0 (asserted) |
  | Paperless | 3.2.1 (`ghcr.io/paperless-ngx/paperless-ngx:3.2.1`) | 3.3.4 | at least 3.2.1 (asserted); if live is newer, raise `minVersion` |
  | Vaultwarden | 1.37.1 | 1.37.5 | at least 1.37.1 (asserted) |
  | Home Assistant | 2026.5.1 | 2026.10.4 | at least 2026.5.1 |
  | Seafile | 12.0.14 (`seafile-server-latest` link) | image `seafileltd/seafile-mc:13.0.29` | the 12.0.x of the rehearsal |

  The exact command that reads each live version was recorded only for some of them in ticket 47 (`pacman -Q`, `--version`, `docker inspect`, `.HA_VERSION`, the `seafile-server-latest` link); for Gitea and Paperless use the image tag from `docker inspect` (the rehearsal used these). Any difference the lock does not cover is no-go.

### 4.4 Carried secrets still equal the live values
- **Who / where / time:** agent, PC and Arch, 15 min, hashes only. One step before the wipe: after it the originals exist only in the Rollback image.
- **Do:** for each of the 23 carried values of ticket 47, part C, compare `sha256` of the live file or field with `sops -d --extract '["<key>"]' <file> | sha256sum`. The ticket kept the result, not the commands; the live sources are:

  | sops file: keys | Live source on Arch |
  |---|---|
  | `synapse.yaml`: `signing_key`, `macaroon_secret_key`, `form_secret`, `registration_shared_secret`, `password_pepper` | `/etc/synapse/nnik.dev.signing.key`; the other four are values in `/etc/synapse/homeserver.yaml` |
  | `vaultwarden.yaml`: `rsa_key` | `/mnt/tbssd/docker/volumes/vaultwarden_data/_data/rsa_key.pem` (the recipe is in ticket 35) |
  | `gitea.yaml`: `internal_token`, `lfs_jwt_secret`, `oauth2_jwt_secret` | `[security] INTERNAL_TOKEN`, `[server] LFS_JWT_SECRET`, `[oauth2] JWT_SECRET` of `.../gitea_data/_data/gitea/conf/app.ini` |
  | `gitea.yaml`: `jwt_private_pem`, `ssh_host_{ed25519,rsa,ecdsa}_key` | `gitea/jwt/private.pem` and `ssh/ssh_host_*_key` in the same volume |
  | `etesync.yaml`: `secret_key`, `dav_htpasswd` | `/srv/etesync/etebase/secret.txt` (stripped), `/root/.local/share/etesync-dav/htpaswd` |
  | `homeassistant.yaml`: `secrets_yaml` | `/srv/homeassistant/secrets.yaml` |
  | `seafile.yaml`: `seahub_secret_key` | `SECRET_KEY` in `/mnt/tbssd/filesync/seafile/conf/seahub_settings.py` (parsed, see ticket 34) |
  | `mautrix-whatsapp.yaml`, `mautrix-telegram.yaml`: `pickle_key`, `registration`, Telegram `api_id`, `api_hash` | `encryption.pickle_key` / `network.api_*` of each bridge's `config.yaml`; registrations: `/etc/synapse/appservices/{whatsapp,telegram}.yaml` (the copies Synapse loads) |

- **Check:** 23 of 23 equal. Any difference: stop, decide which value is right, fix the sops file, `git commit`, rebuild (step 3), and start the day-of checks again.

### 4.5 Record what is running, and Arch's resolver settings
- **Who / where / time:** agent, Arch, 2 min.
- **Do:**
  ```sh
  # on Arch (root shell)
  install -d -m 0700 /mnt/tbssd/cutover
  {
    docker ps --format '{{.Names}}'; echo ---
    docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq); echo ---
    systemctl list-units --type=service --state=running --no-legend; echo ---
    nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv6.ignore-auto-dns con show "Wired connection 1"
  } > /mnt/tbssd/cutover/arch-running.txt
  curl -s http://127.0.0.1:8008/_matrix/key/v2/server | jq -r '.verify_keys | keys[]'
  ```
  Containers with `restart: unless-stopped` that are stopped by hand do **not** start again after a rollback: this list is what the rollback replays (step 15.7). The last command is Synapse's signing key ID, noted in the log: after the Cutover the same ID must be served.
- **Check:** `/mnt/tbssd/cutover/arch-running.txt` lists the containers, the restart policies and the units.

### 4.6 Stop the Actions runner containers
- **Who / where / time:** agent, Arch, 1 min.
- **Do:** `docker stop gitea_runners-factory_runner-1 gitea_runners-factory_runner-2 gitea_runners-factory_runner-3`
- **Check:** `docker ps --format '{{.Names}}'` lists none of them.

### 4.7 The live-Gitea steps (before the final dump)
The pruning and the package deletion hit the Data-disk volume, and the Rollback image does not undo them, so the pre-prune dump comes first. Run on Arch (the Gitea container answers on `127.0.0.1:25579`; the admin session is the human's browser at `https://git.nnik.dev`). Decisions: plain delete, no purge (ticket 47, decided 2026-11-14).

1. **Pre-prune dump and before-counts.** Agent, Arch, 3 min.
   ```sh
   docker exec gitea-db-1 pg_dump -U gitea -Fc gitea > /mnt/tbssd/cutover/gitea-pre-prune.dump
   pg_restore -l /mnt/tbssd/cutover/gitea-pre-prune.dump > /dev/null
   cat > /mnt/tbssd/cutover/gitea-counts.sql <<'SQL'
   select 'issue', count(*) from issue union all select 'comment', count(*) from comment
   union all select 'review', count(*) from review union all select 'repository', count(*) from repository;
   SQL
   docker exec -i gitea-db-1 psql -U gitea -d gitea -At < /mnt/tbssd/cutover/gitea-counts.sql | tee /mnt/tbssd/cutover/gitea-counts-before.txt
   ```
   Check: the dump is non-empty and `pg_restore -l` reads it; the counts file exists. (The pruned accounts account for 185 issues, 549 pull requests, 6309 comments and 891 reviews; the table counts include everybody's.) If `psql` in the container asks for a credential, use the `nsenter` route of `machines/optiplex/cutover/arch-db-dumps.sh`.
2. **`RUN_RETENTION_DAYS = 0`: not set on the live Gitea.** The setting only exists in Gitea 28; on 1.26.4 it does nothing. The NixOS config sets it before the first start (`[actions] RUN_RETENTION_DAYS = 0`, ticket 32). Check it after the deploy (step 11.7).
3. **Delete the webhook to `192.168.178.21:9100`.** Human, Gitea UI (Site Administration, Webhooks, and the webhooks of the four repositories; ticket 24 does not say which one holds it). Check: `docker exec gitea-db-1 psql -U gitea -d gitea -At -c 'select count(*) from webhook'` prints 0.
4. **Delete the four Actions secrets of `AItopia/battle-tracker`** (`REGISTRY_USER`, `REGISTRY_TOKEN`, `BT_SYNC_BASE_URL`, `PORTAINER_WEBHOOK_URL`). Human, repository Settings, Actions, Secrets. Check: the secrets page is empty.
5. **Delete the two registry packages** `battle-tracker-web` (125 versions) and `bt-sync-server` (19), both owned by the organisation `AItopia`; keep `flutter-ci` and `flutter-android-ci`. Human, `AItopia`, Packages, each package, Settings, delete. Then run the package-cleanup cron once (Site Administration, Monitoring, Cron Tasks, `cleanup_packages`). Check: both are gone from the package list; `du -sh /mnt/tbssd/docker/volumes/gitea_data/_data/gitea/packages` is smaller than before (about 2.6 GB less; note the numbers in the log).
6. **Prune the 31 accounts: plain delete, never purge.** Everybody except `Yannik`; the four `*-bot` accounts included. A purge would also delete their 185 issues, 549 pull requests, 6309 comments and 891 reviews. **Not tested on 1.26.4 so far** (ticket 48 did not record the check; Appendix B question 4), so this step verifies after the first account and stops if anything drops. Human creates a short-lived admin token in the UI (Settings, Applications; name it `cutover-prune`) with the scopes **`write:admin` and `write:organization`** (a token without a valid scope answers 401) and types it **himself** into the hidden `read -rs` prompt on Arch: the token never goes into the chat, a file or the shell history.
   ```sh
   read -rs GITEA_ADMIN_TOKEN; export GITEA_ADMIN_TOKEN        # on Arch, never into a file or the shell history
   API=http://127.0.0.1:25579/api/v1
   curl -fsS -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users?limit=50" | jq -r '.[].login' | grep -vx Yannik | sort > /mnt/tbssd/cutover/gitea-accounts.txt
   wc -l < /mnt/tbssd/cutover/gitea-accounts.txt                  # 31
   # 8 of the 31 are members of the organisation AItopia (team `slaves`); Gitea answers 422 Unprocessable Entity to the delete while a user is an org member
   for u in bt-design bt-implement bt-plan bt-registry bt-review bt-spec bt-test bt-verify; do curl -fsS -X DELETE -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/orgs/AItopia/members/$u"; done
   first=$(head -1 /mnt/tbssd/cutover/gitea-accounts.txt)
   curl -fsS -X DELETE -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users/$first"      # no purge parameter
   ```
   Then re-run the counts and compare:
   ```sh
   docker exec -i gitea-db-1 psql -U gitea -d gitea -At < /mnt/tbssd/cutover/gitea-counts.sql > /mnt/tbssd/cutover/gitea-counts-after-first.txt
   diff /mnt/tbssd/cutover/gitea-counts-before.txt /mnt/tbssd/cutover/gitea-counts-after-first.txt && echo SAME
   ```
   They must be **identical** (removing the org memberships changes no count), and a pull request written by `bt-review` still renders in the browser. If the counts drop: stop, restore `gitea-pre-prune.dump` into the container's database (`docker exec -i gitea-db-1 pg_restore -U gitea -d gitea --clean --if-exists < ...` after stopping Gitea), and decide again with the human. If they are identical:
   ```sh
   tail -n +2 /mnt/tbssd/cutover/gitea-accounts.txt | while read -r u; do curl -fsS -X DELETE -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users/$u"; done
   ```
   If the loop prints a failure for some account (the `422` above: an org member that was missed), remove the membership and run the loop again (a second pass; the accounts that are already gone fail harmlessly). Then the human deletes the `cutover-prune` token in the UI, and `unset GITEA_ADMIN_TOKEN`.
   Check: `curl ... "$API/admin/users?limit=50" | jq -r '.[].login'` lists only `Yannik`; the counts file after equals the one before; the 3 OAuth applications still exist (human, UI).
7. **Merge the battle-tracker "drop the Docker deployment" change on the live Gitea** (`PENDING 39B`: the change is prepared by ticket 39; the human merges it here). It must be in before the final dump. Check: `deploy-web.yml`, `sync-server-image.yml` and `deploy/` are gone from `main`.

### 4.8 Stop every consumer (the time box starts here)
- **Who / where / time:** agent, Arch, 5 min.
- **Do:** stop the bridges first, then Synapse (never both bridge sets at once), then everything else. The DB servers (`postgresql.service`, the containers `gitea-db-1`, `paperless-db-1`, `seafile-mysql`) and Pi-hole **stay up**; `cronie` stays stopped so no scheduled job (the cron restarts of Synapse and the bridges every 4 to 6 hours) starts a write.
  ```sh
  systemctl stop mautrix-whatsapp mautrix-telegram mautrix-signal
  systemctl stop synapse turnserver etesync etesync-caldav transmission nginx lighttpd filebrowser immo.nnik.dev cronie
  systemctl stop nfs-server nfs-mountd nfsdcld nfs-idmapd
  docker stop gitea paperless-webserver-1 paperless-broker-1 seafile seadoc seafile-memcached homeassistant vaultwarden portainer bt-web bt-sync-server elabftw mysql
  ```
  (`mysql` is elabFTW's container; elabFTW is dropped. `mautrix-signal` is the retired Signal bridge, still running on Arch. The NFS units serve `/movies` and `/mnt/tbssd/trrnt` read-only, no clients: they must be off before the final gate too.) `systemctl stop nginx` takes minutes and ends `failed (timeout)`: open Matrix long-poll connections hold it, systemd kills it; harmless. Anything else the check below lists, except the base units, is stopped now, not after the dump.
- **Check:** `docker ps --format '{{.Names}}'` shows only `gitea-db-1`, `paperless-db-1`, `seafile-mysql`; `systemctl list-units --type=service --state=running --no-legend` shows only `postgresql`, `pihole-FTL`, `sshd`, `NetworkManager` and the base units. **Record the time: this is when Arch stops; the rollback time box ends 24 h later.**

---

## 5. Final dumps, final restic run, delta sync, hand-over

**Decided 2026-11-14 (ticket 46, human), replacing the 2026-11-11 order:** every consumer off, then the final gate run while the DB servers are still up (it takes its own dumps and the SQLite copies, then runs restic; Pi-hole still resolves), then stop the DB servers, then the delta sync (State is already quiet), then stop Pi-hole, then kexec. There is no `--dumps-dir`; do not repeat `pg_dump` or `mariadb-dump` by hand.

### 5.1 The restic environment file
- **Who / where / time:** agent, PC to Arch, 2 min. The script shreds it when it ends.
- **Do:**
  ```sh
  sops -d --output-type json secrets/optiplex/restic.yaml \
    | jq -r '"RESTIC_REPOSITORY=s3:\(.s3_endpoint)/\(.s3_bucket)\nRESTIC_PASSWORD=\(.repository_password)\nAWS_ACCESS_KEY_ID=\(.s3_access_key_id)\nAWS_SECRET_ACCESS_KEY=\(.s3_secret_access_key)\nAWS_DEFAULT_REGION=\(.s3_region)"' \
    | ssh optiplex 'sudo install -m 0600 /dev/stdin /root/restic-gate.env'
  ```
- **Check:** `ssh optiplex 'sudo head -1 /root/restic-gate.env'` (the file is on Arch) reads `RESTIC_REPOSITORY=s3:s3.fr-par.scw.cloud/nnik-optiplex-restic` (no `https://`: restic uses https by default, so it is equivalent).

### 5.2 The final gate run
- **Who / where / time:** agent, Arch, **dumps about 5 min** (the Synapse dump alone took 136 s) plus the incremental restic runs (the bulk was uploaded by earlier runs): **measured 7 min** on the day (08:34:58 to 08:41:49).
- **Do:**
  ```sh
  cd $REPO_ARCH
  sudo infra/scaleway/arch-gate.sh --env-file /root/restic-gate.env --final --dry-run     # sources exist
  sudo infra/scaleway/arch-gate.sh --env-file /root/restic-gate.env --final | tee /mnt/tbssd/cutover/arch-gate-final.log
  ```
  This runs `arch-db-dumps.sh --final` (it refuses while any consumer runs) into `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>/`, takes the `sqlite3 .backup` copies of Vaultwarden, etesync and Home Assistant, then backs up the Arch source paths (as the earlier gate runs did, **not** `/mnt/tbssd/state`) into the local repository first and then into the bucket.
- **Check:** the script prints both snapshot lists; `grep '^# mode:' /mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>/MANIFEST` says `final`; eight dumps exist and are non-empty; record the **local and the bucket snapshot IDs**, the stage path (`<STAMP>`) and the dump directory path `<DUMPDIR>` = `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>` in the log. **That path is what step 10.2 restores** (not `/mnt/tbssd/cutover-dumps/<ts>/`, which the older tickets name: Appendix B, contradiction 2). Storage class of the new bucket objects: "One Zone" (`infra/scaleway/README.md`).
- **Retention:** the nightly NixOS job (`--keep-daily 7 --keep-weekly 4 --keep-monthly 6 --group-by host`, tags ignored) keeps one snapshot per day, so **the first nightly Backup prunes the final `arch-gate` snapshots of the same day**. The Arch data stays in the Rollback image and on the Data disk. If the final gate snapshot must survive, tag-protect it before the first nightly (`restic tag --set keep <id>`, then `--keep-tag keep` on the job's forget) or copy it to another repository.

### 5.3 Capture the service-level counts on Arch
- **Who / where / time:** agent, Arch, 5 min (the file trees are counted; the DB servers must still be up).
- **Do:** `sudo machines/optiplex/cutover/expected-counts.sh capture --host arch --out /mnt/tbssd/cutover/expected-arch.txt`
- **Check:** the file lists Synapse events and `max_stream_ordering`, Gitea repositories, users, issues, comments and reviews, Paperless documents, Seafile libraries and share links, every table of the Vaultwarden and etesync SQLite databases (Vaultwarden users 3; ciphers were 288 when this was written and 297 on the day), transmission torrents (97 when written; 96 in the count file and 97 in `transmission-remote -l` on the day), and the file counts of the copied trees. This is live drift: **the values of `expected-arch.txt` are the reference, not the numbers in this runbook.**

### 5.4 Stop what is left, the DB servers included
- **Who / where / time:** agent, Arch, 2 min. Pi-hole stays up until 5.8.
- **Do:** `docker stop $(docker ps -q); systemctl stop postgresql`; then every other unit that `systemctl list-units --type=service --state=running` still lists, except `sshd`, `NetworkManager`, `pihole-FTL` and the base units (`mautrix-signal` and the NFS units `nfs-server nfs-mountd nfsdcld nfs-idmapd` belong to the 4.8 list; if one still runs, stop it now).
- **Check:** `docker ps` is empty; `ss -tulpn` lists only sshd (25560), pihole-FTL (53, 123 and its web port) and the base services.

### 5.5 The delta sync (the downtime rows)
- **Who / where / time:** agent, Arch, **measured about 1 min** for `--final` (the downtime rows are small: Vaultwarden 6.7 MB, Home Assistant 65 MB, Paperless about 150 MB, plus whatever changed in the pre-synced trees).
- **Do:**
  ```sh
  cd $REPO_ARCH
  sudo machines/optiplex/cutover/sync-state.sh --final 2>&1 | tee /mnt/tbssd/cutover/sync-state-final.log
  sudo machines/optiplex/cutover/sync-state.sh --final --dry-run 2>&1 | grep -E 'regular files transferred|deleted files|deleting'
  ```
  `--final` runs every row with `--delete` and refuses while a consumer is still running. The copy table is section 17.
- **Check:** the second command shows `Number of regular files transferred: 0` for every row and no `deleting` line; the log ends with `finished (final)`.

### 5.6 Gitea: nothing to copy here
- The Gitea files are not copied on Arch: `optiplex-gitea-restore` (step 10.3) reads `/mnt/tbssd/docker/volumes/gitea_data/_data` on the Data disk after the install, as a one-shot. (Ticket 42's copy table wanted a pre-sync of Gitea's repositories and packages; ticket 32's tool refuses to merge into a used tree, so there is none: Appendix B, contradiction 3.)

### 5.7 (no resolver edit any more)
- With the USB route nothing runs on Arch after the final restic run that needs DNS (the installer runs from the stick with the FritzBox as its DNS by DHCP). The earlier step "point Arch's resolver at the FritzBox before Pi-hole stops" belonged to kexec and is dropped. Arch's resolver is not changed, so the rollback has nothing to undo there.

### 5.8 Stop Pi-hole
- **Who / where / time:** agent, Arch, 1 min.
- **Do:** `systemctl stop pihole-FTL`
- **Check:** `ss -tulpn | grep ':53 '` shows nothing on port 53 (the LAN already uses the FritzBox, step 4.2).

### 5.9 Last look, then `sync`
- **Who / where / time:** agent, Arch, 2 min.
- **Do:** `systemctl list-units --type=service --state=running --no-legend; docker ps; sync`. Record the result in the log.
- **Check:** only the base units (sshd, NetworkManager, journald, ...) run; `docker ps` is empty. The final restic snapshot IDs, the dump directory and the count file are in the log. **From here on Arch's data does not change.**

### 5.10 Shut Arch down and boot the installer stick
- **Who / where / time:** agent on Arch, **human at the Optiplex** (monitor and keyboard attached, the stick in a USB port), 5 to 10 min.
- **Why not kexec (decision 2026-11-14):** the stock kexec installer of ticket 45 has a 147-module set whose only network drivers are `virtio_net`, `net_failover` and `vmxnet3`, and its kernel has no `r8169`. The Optiplex's NIC (`enp2s0`) is `r8169`, so a kexec installer would come up **without network** on the real box. It was rehearsed in a VM (virtio) and works there; it is not used. The installed system is fine (`machines/optiplex/hardware.nix` lists `r8169` in the initrd), and so is our ISO (full kernel modules).
- **Do:**
  1. On Arch: `sync; systemctl poweroff`. Wait until the box is off (the human sees the power LED off; `ping` stops).
  2. **Human:** power on and press the Dell BIOS boot menu key (F12) at the logo; choose the **UEFI** entry of the USB stick (the "UEFI:" one, not a legacy one: the system installs a UEFI boot entry). If the BIOS offers no stick entry, it does not boot it: stop here and see "If the stick does not boot" below.
  3. The installer gets its address by DHCP (the FritzBox reserves `.20` for the NIC's MAC) and uses the FritzBox as DNS. It answers as `root` on port 22 for yannik's keys; the PC's known_hosts is not used for it (new host key each time).
- **Check (first thing):** from the PC `ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$OPTI 'uname -a; ethtool -i $(ls /sys/class/net | grep -v ^lo | head -1) | head -3; ls -d /sys/firmware/efi'` answers, the driver line says **`r8169`**, and `/sys/firmware/efi` exists (booted in UEFI mode). If it does not answer: look at the monitor (no address? wrong boot entry?), then `ip -br addr` on the console.
- **If the stick does not boot** (no BIOS entry, or no network): nothing has been written to the disks. The human power-cycles and chooses the NVMe in the boot menu: Arch boots again (its Seafile containers have `restart=no` and stay down: start them by hand, step 15.7). Retry with another USB port or after re-writing the stick (step 2.7).

---

## 6. The Rollback image (installer)

A full copy of the Arch System disk, taken from inside the installer while the NVMe is not mounted, so it is consistent. Only the System disk: the Data disk is never imaged.

**Who / where / time:** agent, Installer, **about 41 min, measured on the day** (create 1404 s, 99 GB on disk; verify 1076 s). The ISO has `zstd`, `pv`, `sfdisk` and the `rollback-image` command.

### 6.1 Look at the disks
- **Do:**
  ```sh
  inst() { ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@"$OPTI" "$@"; }     # the installer's host key is new: not recorded
  inst 'lsblk -o NAME,SIZE,MODEL,FSTYPE,UUID,MOUNTPOINTS; findmnt -rn | grep -E "nvme|/dev/sd"'
  ```
- **Check:** `nvme0n1` (KIOXIA, 238.5 GiB, the Arch ESP, btrfs and swap partitions) shows **no mountpoint**; the Data disk (ext4, UUID `70ca9b25-a1cd-46fa-bcbd-66780935c999`) is not mounted either.

### 6.2 Make the image
- **Do:**
  ```sh
  inst 'rollback-image create --dry-run'
  inst 'nohup rollback-image create > /root/rollback-create.log 2>&1 < /dev/null &'
  inst 'tail -f /root/rollback-create.log'
  ```
  `rollback-image` is `machines/optiplex/cutover/rollback-image.sh` built into the ISO. It mounts the Data disk at **`/data`** (never under `/mnt`: disko mounts the new System disk there), streams the whole NVMe through `zstd -T0` into **`/data/rollback/arch-nvme0n1.img.zst`** (that is `/mnt/tbssd/rollback/` on the Data disk) and writes, beside it, the raw `sha256` (`.sha256`), `sfdisk -d` (`.sfdisk`) and the size (`.size`) in a directory with mode 0700 (the image holds the whole Arch System disk, keys and passwords included). The raw hash and the compression run on one single read of the disk. It refuses when the device is mounted, the image exists, or the Data disk has less free space than the device is big.
- **Check:** the log ends with `imaged in ... s`; `ls -l /data/rollback/` lists the four files.

### 6.3 Verify it
- **Do:** `inst 'rollback-image verify --against-device'`
- **Check:** `zstd -t` passes, the decompressed `sha256` equals the recorded raw one, and the disk still equals the image. Write into the log: the image path, its size on disk, the raw `sha256` (`inst 'cat /data/rollback/arch-nvme0n1.img.zst.sha256'`) and the time it took.

### 6.4 Release the Data disk
- **Do:** `inst 'sync; umount /data; findmnt /data; echo rc=$?'`
- **Check:** `findmnt /data` prints nothing (rc=1). Disko must not run before this.

---

## 7. Pre-install checks (installer)

**Who / where / time:** agent, Installer, 3 min (`inst` is the ssh function of step 6.1).

- **Do:**
  ```sh
  inst 'ip -br link; ip -br addr; ethtool -i $(ls /sys/class/net | grep -v ^lo | head -1) | head -2'
  inst 'ls -l /dev/disk/by-id/ | grep -i kioxia; lsblk -o NAME,MOUNTPOINTS'
  inst 'getent hosts cache.nixos.org'
  ```
- **Check:**
  - the NIC with MAC `a4:bb:6d:7f:65:61` is there, driver `r8169` (the initrd network of the new system matches it by MAC, not by the name `enp2s0`, so a different name in the installer is fine);
  - the KIOXIA NVMe is listed under the by-id name disko targets;
  - nothing is mounted (the Data disk was released in 6.4);
  - `inst 'ls -d /sys/firmware/efi'` exists (UEFI boot);
  - DNS works from the installer (the FritzBox hands out itself). The install itself does not need it (offline flags, step 8).

---

## 8. Install (nixos-anywhere, `restoreMode`)

**Who / where / time:** agent, PC to Installer, **under 4 min, measured on the day** (10:23:38 to 10:27:18; the PC pushes the whole closure over the LAN: 175 s in the VM rehearsal). After the Rollback image is verified and the Data disk is released. The install is of **`.#optiplex-restore`**, never `.#optiplex`: PostgreSQL and MariaDB run with their roles and empty databases and every Kept service is off. `PENDING 45`: the rehearsal ran the same flags with `--phases disko,install` against a VM that was already an installer, and the pinned nixos-anywhere ref; whether `reboot` belongs in the phase list and whether `--store-paths` is needed are recorded there.

- **Do:**
  ```sh
  nix run "$NIXOS_ANYWHERE" -- --flake .#optiplex-restore \
    --extra-files "$X/extra" \
    --disk-encryption-keys /tmp/secret.key "$X/secret.key" \
    --phases disko,install \
    --no-substitute-on-destination --no-use-machine-substituters \
    --build-on local \
    --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no \
    root@$OPTI
  ```
  These are the flags ticket 45 rehearsed (`--phases disko,install`; the `reboot` phase could not be rehearsed in a qemu direct boot, so it is not used: the reboot is done by hand below, where the stick can be dealt with). Harmless noise: `umount: /mnt: not mounted` at the start of disko.
- **Check:** the command exits 0.

### 8.1 First boot from the NVMe, not from the stick
- **Who / where / time:** agent, then **human at the box**, 5 min.
- **Do:** `inst 'sync; systemctl poweroff'`. When the box is off, **the human pulls the stick**, then powers on. The installed system's boot entry ("Linux Boot Manager", written by the install as the first UEFI entry) boots the NVMe and stops in the initrd waiting for the passphrase.
- **If the BIOS boots the stick again or finds no system** (the stick still in, or the entry missing): power off, make sure the stick is out, power on and press F12; choose the NVMe's "Linux Boot Manager" entry (or the NVMe by name). Never type a passphrase at the console: the unlock is the script (step 9.1).
- **Check:** `ping $OPTI` answers within two minutes (the initrd network) and `timeout 5 bash -c "echo > /dev/tcp/$OPTI/2222" && echo initrd-up` prints `initrd-up` (port 2222 only answers in the initrd; `nc` is not installed on the PC).

---

## 9. First unlock and `restoreMode` checks

### 9.1 Unlock from the PC
- **Who / where / time:** agent, PC (human present, LAN only), 2 to 5 min (cold reboot plus unlock **measured about 2 min**). The unlock is rehearsed in the VM with this very script (exit 0); the first time on the real NIC is now.
- **Do:**
  ```sh
  machines/optiplex/unlock-optiplex.sh
  until ssh -o BatchMode=yes -o ConnectTimeout=5 optiplex true; do sleep 5; done
  ```
  The script pipes the LUKS passphrase from `secrets/luks.yaml` (sops) into the initrd's password agent on port 2222; the first connection records the initrd host key in `~/.ssh/known_hosts.optiplex-initrd`.
- **Check:**
  - the script ends with `unlock: passphrase sent to the initrd on 192.168.178.20:2222; the boot continues.`;
  - the recorded initrd key matches the one that was installed: `ssh-keygen -lf $X/extra/etc/secrets/initrd/ssh_host_ed25519_key.pub` equals `ssh-keygen -l -F "[$OPTI]:2222" -f ~/.ssh/known_hosts.optiplex-initrd`;
  - `ssh optiplex true` succeeds **without a host-key warning**: that proves the `--extra-files` host key is the old one (the unlock itself is not tested on the real hardware yet).

### 9.2 `restoreMode` checks
- **Who / where / time:** agent, NixOS Optiplex, 5 min.
- **Do:**
  ```sh
  ssh optiplex 'findmnt /mnt/tbssd /state; ip -br addr; sudo ls /run/secrets | wc -l; systemctl is-active postgresql mysql smartd; systemctl --failed --no-legend'
  ssh optiplex 'sudo -u postgres psql -Atc "select datname from pg_database order by 1"; sudo mariadb -e "show databases"'
  ssh optiplex 'systemctl list-units --type=service --state=running --no-legend | cut -d" " -f1'
  dig +short @$OPTI nnik.dev
  ```
- **Check:**
  - `/mnt/tbssd` (ext4, the Data disk) and `/state` (bind mount of `/mnt/tbssd/state`) are mounted, and `/state` holds the copied State (`ls /state`);
  - `ip addr` shows `192.168.178.20`, the global `<prefix>::20` and `fd65:c1a5:7d2b::20`;
  - `/run/secrets` is populated;
  - PostgreSQL and MariaDB are active; the databases `matrix-synapse`, `mautrix-whatsapp`, `mautrix-telegram`, `gitea`, `paperless` and `ccnet_db`, `seafile_db`, `seahub_db` exist (empty);
  - **`smartd` is active** (red only in VMs; here it must be green: if not, that is a real finding about the disks);
  - **no Kept service unit is running** (restoreMode keeps the users, the sops secrets and the edge: Caddy, blocky, and the ACME unit);
  - `dig @$OPTI nnik.dev` answers (blocky). The ACME unit may already have issued the real certificate (it had, on the day: step 11.5): watch `journalctl -u acme-order-renew-nnik.dev` (the unit is `acme-order-renew-nnik.dev.service`, not `acme-nnik.dev.service`). Each real issuance counts against Let's Encrypt's 5 duplicate certificates per week.

---

## 10. Restore (NixOS Optiplex in `restoreMode`)

**Who / where:** agent runs, human watches; NixOS Optiplex through `ssh optiplex`, root through `sudo`. **Time:** 15 to 30 min (estimate). The State was copied to `/mnt/tbssd/state` on Arch (step 5.5) and survived the wipe on the Data disk. The Kept units are not running: the service users, the sops secrets and `/state` exist. Per-service internals (paths, ownership, upgrade steps) are in the tickets named in each step.

`DUMPDIR` is the dump directory step 5.2 recorded, `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>`.

### 10.1 Is the copy complete?
- **Do:**
  ```sh
  scp machines/optiplex/cutover/expected-counts.sh optiplex:/tmp/
  ssh optiplex 'sudo du -sh /state/*; sudo bash /tmp/expected-counts.sh capture --host nixos --skip-db --out /tmp/counts-files.txt; sudo bash /tmp/expected-counts.sh diff --common /mnt/tbssd/cutover/expected-arch.txt /tmp/counts-files.txt'
  ```
  The script was fixed after the first run (it needed `LC_ALL=C` and the NixOS database name `matrix-synapse`): an old copy needs `LC_ALL=C` in front of `bash`.
- **Check:** the file counts and the SQLite table counts (Vaultwarden, etesync) equal Arch's. **One difference is expected at this point:** `files.gitea_repositories` (restored in 10.3). Sizes: about 25 GB Synapse media, 22 GB Seafile blocks.

### 10.2 The databases: `optiplex-db-restore`
- **Do:** `ssh optiplex 'sudo optiplex-db-restore <DUMPDIR>' 2>&1 | tee` into the log (the script has no consumers to stop: none exists in `restoreMode`). `optiplex-db-restore --help` prints its procedure.
- **Time:** **measured 181 s in total on the Optiplex on the day (Synapse 163 s)**; 102 s on the PC in the rehearsal (Synapse 87 s; `seahub_db` 7 s; the rest 0 to 2 s each). The old "15 to 30 min" estimate was wrong by an order of magnitude. Record the real per-database times in the log.
- **Check:** exit 0; for each database the script reports MANIFEST ok, objects owned by the service role, row counts equal to `counts/*.tsv`, and `matrix-synapse` is still C/C. A `WARNING` about `whatsapp`'s collation version came with the dump (glibc bump on Arch): known, the restore uses the builtin C.UTF-8. On a failed database: `optiplex-db-restore --reset <db>`, then `optiplex-db-restore <DUMPDIR> --only <db>`.

### 10.3 Gitea: `optiplex-gitea-restore`
- **Do:** `ssh optiplex 'sudo optiplex-gitea-restore /mnt/tbssd/docker/volumes/gitea_data/_data'`
- **Time:** minutes (128 MB of repositories plus the two kept registry packages); not measured.
- **Check:** it reports 4 repositories restored (all in `AItopia`, plus 3 wikis on disk) and ownership `gitea:gitea`. It is a one-shot: it refuses a second run, and refuses while `gitea.service` is active. The Docker volume is only read.

### 10.4 Seafile: `seafile-prepare-state`
- **Do:** `ssh optiplex 'sudo seafile-prepare-state'` (the container refuses to start without its marker).
- **Check:** read its NOTE lines (the real, hand-edited `seahub_settings.py` has only been seen by ticket 48's script run, which did not record problems); `sudo grep -rE 'password|SECRET_KEY' /state/seafile/conf` finds nothing besides the line that reads the secret file; `/state/seafile/.optiplex-prepared` exists.

### 10.5 transmission: ownership forward
- **Do:** `ssh optiplex 'sudo bash -s -- forward' < machines/optiplex/services/transmission/restore.sh`
- **Check:** `stat -c '%u:%g' /mnt/tbssd/trrnt /state/transmission` print `70:70`; yannik's `watch/`, `transmit/` and `config/` were left alone (`watch/` has group 70 and `g+w`); `/mnt/tbssd/cutover/trrnt-watch.orig` exists (the rollback needs it).

### 10.6 What needs no manual step
- Synapse media was copied with `--chown=224:224` (check: `stat -c '%u:%g %a' /state/synapse/media_store`). Vaultwarden, Paperless, Home Assistant and etesync fix their own ownership in their units' pre-start on every start. The Seafile copy keeps root ownership (the container runs as root). The static sites are `yannik:users` (1001:100).
- Retired State is not restored. `/mnt/tbssd/docker`, `/mnt/tbssd/filesync` stay as Arch left them.

### 10.7 The dashboard links
- **Who / time:** agent or human, 5 min.
- **Do:** `ssh optiplex 'sudo cat /state/www/opti.plex/index.html'` (1 KB, a link bar loading each LAN service into an iframe); edit it with `sudoedit`: remove Portainer and Pi-hole, add `http://healthchecks.opti.plex` (the gate page `gate.opti.plex` is served by Caddy; link it if wanted). The file is not in the repository.
- **Check:** after the deploy the five links (`transmission`, `paperless`, `homeassistant`, `healthchecks`, `gate`) load in `http://opti.plex`.

### 10.8 Everything counted again
- **Do:** `ssh optiplex 'sudo bash /tmp/expected-counts.sh capture --host nixos --out /tmp/counts-full.txt; sudo bash /tmp/expected-counts.sh diff /mnt/tbssd/cutover/expected-arch.txt /tmp/counts-full.txt'`
- **Check:** **all values equal** (Synapse events and `max_stream_ordering`, Gitea, Paperless, Seafile libraries and share links, Vaultwarden users and ciphers, transmission, every file tree; the values of `expected-arch.txt` are the reference, not the numbers in this runbook: step 5.3). Any difference is a no-go for step 11 until explained.

---

## 11. Normal deploy (the point after which a rollback loses new data)

### 11.1 Delete the three DuckDNS records at Porkbun, now
- **Who / where / time:** human, Porkbun UI, 5 min.
- **Why this order (decided here; the old text disagreed with itself):** `ddns-porkbun` starts with the first normal deploy, and it cannot create an A or AAAA record on a name that has a CNAME or ALIAS. The zone has three such records (step 2.2): the ALIAS `nnik.dev`, the ALIAS `www.nnik.dev` and the `*` CNAME, all to `nnik.duckdns.org`. While any of them exists the updater fails: `*.nnik.dev is a CNAME; delete it first`, or HTTP 400 `create A nnik.dev failed` for the apex (a push to ntfy every 5 minutes). Arch is stopped, so nothing is lost by deleting them now, and the rollback restores them (step 15.5). Do **not** delete DuckDNS.
- **Do:** delete the ALIAS `nnik.dev`, the ALIAS `www.nnik.dev` and the `*` CNAME of `nnik.dev` in the Porkbun UI, **before the first updater run**. The updater then creates A and AAAA for `nnik.dev` and `*.nnik.dev` (`www` is covered by `*`): step 11.5.
- **Check:** `dig +short CNAME foo.nnik.dev @fortaleza.ns.porkbun.com` (the authoritative server, no cache) and `dig +short A nnik.dev @fortaleza.ns.porkbun.com` print nothing.

### 11.2 Deploy
- **Who / where / time:** agent, PC to NixOS Optiplex, **about 4 min, measured on the day** (everything is already built, so most of it is copying the closure). Human acknowledges: **from here a rollback loses what is written to the new system.**
- **Do:**
  ```sh
  NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nix run nixpkgs#nixos-rebuild -- switch --flake .#optiplex --build-host localhost --target-host optiplex --sudo
  ```
  (a plain `nixos-rebuild --flake .#optiplex --target-host optiplex` would build on the box, and Paperless and the etesync overlay are not in the binary cache.) `--build-host localhost` ssh-es to the PC itself: on a PC whose `known_hosts` lacks `localhost` it fails at once with `Host key verification failed` (nothing is changed on the box), hence the `NIX_SSHOPTS`.
- **Check:** the PC's toplevel path equals the one noted in 3.1 (step 11.6). Exit 0, **or exit 4** with `switching to system configuration ... failed (status 4)`: some units failed to start, but the system is switched (`ssh optiplex readlink /run/current-system`). Right after the first deploy exactly `healthchecks-lan-probes` and `healthchecks-units-ok` (no first user yet: step 11.4) are expected red, and `ddns-porkbun` until the Porkbun records are deleted (step 11.1). Anything else is a finding.

### 11.3 Watch the first starts
- **Who / where / time:** agent, NixOS Optiplex, 10 to 15 min. In the rehearsal everything was up within 25 s of the deploy; the Optiplex is slower and its migrations run on real data for the first time on this hardware.
- **Do and check, one line per service** (`journalctl -fu <unit>` in a second terminal while the deploy runs):
  - **Synapse** (`matrix-synapse`): schema migration 1.156 to 1.164 (rehearsal: first start 8.9 s; the unit allows 30 min). Check (no `jq` on the box): `ssh optiplex 'curl -s http://127.0.0.1:8008/_matrix/key/v2/server' | jq -r '.verify_keys | keys[]'` prints the **signing key ID noted in step 4.5**.
  - **Bridges** (`mautrix-whatsapp`, `mautrix-telegram`): start on the restored databases (main DB upgrade, crypto DB 21 to 22 in the rehearsal). **Watch item:** the rehearsal logged `Failed to share keys: One time key ... already exists` on every start; the dumps there were taken with the services running, so with the stopped-service final dump it should not occur. Look for it in the journals right away; if it appears, note it and carry on (not a rollback trigger).
  - **Gitea:** `gitea migrate` 1.26.4 to 28.3.0 (rehearsal: 27 migrations, about 1 s; the unit allows 15 min).
  - **Seafile** (`podman-seafile`): the image runs the 12 to 13 upgrade by itself. Check: `curl -fsS http://127.0.0.1:25577/api2/ping/` prints `"pong"`, `podman logs seafile` has no `Traceback`.
  - **Paperless:** `paperless-scheduler`'s pre-start runs `migrate` (3.2.1 to 3.3.4, rehearsal about 12 s) and the reindex; nothing serves before it is done.
  - **Home Assistant:** starts on the real `.storage` (2026.5.1 to 2026.10.4 in the rehearsal); its errors about unreachable devices are network, not data.
  - **Vaultwarden:** `curl -fsS https://pw.nnik.dev/alive` after DNS (step 12), or `curl -fsS --resolve pw.nnik.dev:443:127.0.0.1 https://pw.nnik.dev/alive` from the box; `journalctl -u vaultwarden | grep -i 'Private key'` must print **nothing** (a "created" line means the sops key was not used).
  - **etesync** (`etebase-server`, `etesync-dav`): `migrate` and `collectstatic` run in the pre-start.
  - **transmission:** active; `transmission-remote 127.0.0.1:25559 -l` lists as many torrents as `expected-arch.txt` has (97 in `-l` on the day, 96 in the count file; step 5.3), none "Verifying".

### 11.4 healthchecks: the first user (a deliberate step)
- **Who / where / time:** human (the password goes to Vaultwarden), NixOS Optiplex, 3 min. Until this runs, the units `healthchecks-lan-probes` and `healthchecks-units-ok` are **red and page ntfy** through `notify-failure@` (HTTP 404, there is no project yet).
- **Do:**
  ```sh
  ssh -t optiplex 'sudo healthchecks-manage createsuperuser'          # asks for the email and a password; this also creates the project
  ssh optiplex 'sudo systemctl start healthchecks-ensure'
  ```
  The non-interactive form (`createsuperuser --email <email> --password <password>`, as ticket 48 used it; `--noinput` does not exist) puts the password in the process list and the shell history: use the prompt. A harmless `Add a 'default' entry to MAILERS` hint is printed.
- **Check:** `http://healthchecks.opti.plex` (LAN) shows 5 checks (`backup-nightly`, `backup-check`, `lan-paperless`, `lan-homeassistant`, `units-ok`) and the two probe units go green within 5 minutes. The superuser password is stored in Vaultwarden.

### 11.5 ACME and the DDNS updater
- **Who / where / time:** agent, NixOS Optiplex, 5 min.
- **Do:** `ssh optiplex 'journalctl -u acme-order-renew-nnik.dev --no-pager | tail -20; sudo ddns-porkbun --dry-run; journalctl -u ddns-porkbun --no-pager | tail'` (the ACME unit is `acme-order-renew-nnik.dev.service`, not `acme-nnik.dev.service`; the updater timer fires at once after the deploy, so the dry run may say "nothing to change"). With the three records of 11.1 gone, `ssh optiplex 'sudo systemctl start ddns-porkbun'` creates the A and AAAA records now (if it ran earlier and failed, this is the rerun). Check with `dig +short A nnik.dev @fortaleza.ns.porkbun.com` from the PC.
- **Check:** the real Let's Encrypt (production) certificate for `nnik.dev` and `*.nnik.dev` is issued (on the day it was already issued during the first boot in `restoreMode`: issuer YE2, valid to 2027-02-13, so this can be checked right after the unlock); the Porkbun zone has four records, A and AAAA for the apex and for `*` (TTL 600), and no CNAME. The updater fails loudly with no AAAA if the host has no global `...::20` address: then check `ip -6 addr` and the router's IPv6. **As soon as the records exist, do the FritzBox DNS fix at the top of step 12** (not after verification): the LAN cannot reach the sites until then.

### 11.6 Systems state
- **Do:** `ssh optiplex 'readlink /run/current-system; systemctl --failed --no-legend'`
- **Check:** the path equals the toplevel built from the committed config with `restoreMode` off (`nix path-info .#nixosConfigurations.optiplex.config.system.build.toplevel` on the PC); **`systemctl --failed` is empty** after 11.4 (before it: exactly the two healthchecks probe units). `smartd` is active.

### 11.7 Gitea after the deploy
- **Who / where / time:** agent, NixOS Optiplex, human for the UI, 5 min.
- **Do:**
  ```sh
  ssh optiplex 'sudo optiplex-gitea doctor check --all'                                  # without --all it checks nothing
  ssh optiplex 'sudo grep -A4 "^\[actions\]" /state/gitea/custom/conf/app.ini'          # RUN_RETENTION_DAYS = 0
  ```
  The human runs the `cleanup_packages` cron once in the UI (Site Administration, Monitoring, Cron Tasks).
- **Check:** `doctor` ran 13 checks without errors (a warning for an LFS object without a row is harmless; so is `Found 12212 Action entries without existing user` after the prune: activity-feed rows of the deleted accounts); `RUN_RETENTION_DAYS = 0`; the cron ran.

---

## 12. DNS and FritzBox (the DNS part right after 11.5; the shares after the LAN checks of step 13.1 to 13.3)

The FritzBox hands out **itself** as DNS during the window (step 4.2), but **not past the moment the updater has created the AAAA records (step 11.5): do the fix below right then, before 12.1 and not after verification.** The AAAA `2a02:8108:3184:3600::20` is inside the LAN's own prefix, so the FritzBox's DNS rebind protection returns EMPTY answers (NOERROR, 0 answers) for every `*.nnik.dev` name to LAN clients that use it as DNS. Symptom: the sites are unreachable from the LAN and fine from mobile data. The fix, one of:
- set the FritzBox "local DNS server" / the DHCP DNS server to `192.168.178.20` (blocky) and the DNSv6 server to `fd65:c1a5:7d2b::20` (Home Network, Network, Network Settings); on the day the FritzBox was set to forward LAN DNS to blocky and it worked; or
- add `nnik.dev` as a host name exception under Home Network, Network, Network Settings, Additional Settings, DNS rebind protection.

Public names now come from Porkbun (11.5); LAN names are checked by address until this is done. Step 16.3 only re-checks it.

### 12.1 Re-point the FritzBox IPv6 shares at `::20`
- **Who / where / time:** human, FritzBox UI, 10 min.
- **Do:** the shares for 80, 443, 8448, 51413 (TCP and UDP), 3478 (TCP and UDP) and 49152-49252 (UDP) must point at the Optiplex's new IPv6 interface ID `::20` (the old address was a NetworkManager stable-privacy one). The FritzBox shows the device by its current addresses: select the Optiplex entry that carries the `...::20` address.
- **Check:** from the phone on **mobile data** over IPv6 (or `curl -6 -sI https://nnik.dev/_matrix/client/versions` from an IPv6 host outside the LAN): 443 and 8448 answer.

### 12.2 Disable the FritzBox DynDNS (disable, do not delete)
- **Who / where / time:** human, FritzBox UI, 2 min.
- **Do:** untick "use DynDNS" for the `nnik.duckdns.org` entry. **Leave the entry and the DuckDNS account in place:** a rollback needs both (ticket 44 deletes them after the Rollback image's lifetime).
- **Check:** the FritzBox shows DynDNS off. In Porkbun nothing points at `nnik.duckdns.org` any more (11.1).

### 12.3 Public records
- **Who / where / time:** human, 3 min.
- **Check:** `dig +short nnik.dev A @9.9.9.9`, `dig +short nnik.dev AAAA @9.9.9.9`, `dig +short foo.nnik.dev A @9.9.9.9` and `... AAAA` each answer with the updater's address (the Porkbun UI shows exactly four records of the updater and nothing else for `nnik.dev` except what you noted in 2.2).

---

## 13. Verification checklist

**Who:** agent runs the commands, human works the devices and confirms; evidence goes into ticket 43's log, one line per check. Fix a small defect in the repo (commit, deploy), never on the host only. A bigger defect is either a rollback (step 14) or a new ticket.

### 13.1 Host
- **Reboot and unlock (human, 5 min):** `ssh optiplex 'sudo systemctl reboot'`, then `machines/optiplex/unlock-optiplex.sh` and `until ssh -o BatchMode=yes optiplex true; do sleep 5; done`. All Kept services are back; `systemctl --failed` is empty.
- `ssh -p 25560 optiplex` shows no host-key warning (proves `--extra-files`).
- `ip -br addr`: `192.168.178.20`, `<prefix>::20`, `fd65:c1a5:7d2b::20`. `findmnt /state` is the bind mount from the Data disk.
- `systemctl --failed` empty. `smartd` running. A test push: `sudo systemctl start notify-failure@verification-test.service` reaches the ntfy app on the Android phone.
- `readlink /run/current-system` equals the built toplevel (step 11.6), `restoreMode` off.

### 13.2 DNS and TLS
- blocky: `dig @192.168.178.20 nnik.dev` returns the host addresses (split horizon); an ad domain from the carried lists is blocked.
- Public A and AAAA records come from the updater; the CNAME and the DynDNS are gone; **nothing points at DuckDNS**.
- The served certificate is **Let's Encrypt production** (not staging) and covers `nnik.dev` and `*.nnik.dev`: `echo | openssl s_client -connect nnik.dev:443 -servername nnik.dev 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName`.

### 13.3 Caddy, from outside the LAN (phone on mobile data)
- Every public site answers over IPv4 and IPv6: `nnik.dev`, `git`, `pw`, `filesync`, `etesync`, `dav`, `ntfy`, `ya`, `koke`, `immo`, `pnp`, `pnp-backend` (the last two `PENDING 39B`).
- `www.nnik.dev` redirects (308); unknown names abort; LAN vhosts abort when reached from the public IP (a forged Host header, for example `curl -sk --resolve paperless.opti.plex:443:<public ip> https://paperless.opti.plex/`). **Port 2222 is not open from outside**; only the intended ports are.

### 13.4 Matrix
- `curl -s https://nnik.dev/.well-known/matrix/client | jq .` and `.../server` are valid JSON; the federation tester passes on `:8448`.
- Element: log in as `ya` and `anna`, send and receive. Public registration is off.
- A bridged **WhatsApp** and a bridged **Telegram** room decrypt and send for each logged-in user (goolm on the restored pickles); double puppeting works. Watch for the one-time-key line (11.3). A TURN call works through the relay range.
- The signing key ID equals the one of step 4.5.

### 13.5 Gitea
- `Yannik` logs in; the admin user list shows only `Yannik`; the 3 OAuth apps work (tea, Git Credential Manager).
- `git clone git@git.nnik.dev:AItopia/<repo>.git` on port 25580 with **no host-key warning** (the carried host keys), and over HTTPS.
- Packages `flutter-ci` and `flutter-android-ci` are present and a pull of one from the registry works; `battle-tracker-web` and `bt-sync-server` are gone.
- Pull requests written by deleted accounts still render (plain delete kept them); the `issue`, `comment` and `review` counts equal `expected-arch.txt`.
- The webhook to the loopback receiver is created in 16.1 (`PENDING 39B`).

### 13.6 Seafile
- The server is 13 (`/api2/ping/` `"pong"`; version 13.0.29); `filesync.nnik.dev` web login; **the 18 libraries** (19 rows in `RepoInfo` counts the built-in template); a public share link opens (9 exist).
- **The Seafile admin password is not the old 4-digit `INIT_` value, and no default admin `me@example.com` exists** (a wrongly restored empty database would create it).
- Sync works from the Linux desktops (PC, Acer), Windows and Android (Pixel 6a; NoteAir5C with Obsidian) with the 9.0.x clients. This is the one check that needed real clients and was deferred past the rehearsal; if it fails the way back is the Rollback image.

### 13.7 Vaultwarden, Paperless, Home Assistant, etesync
- **Vaultwarden:** web vault login; clients sync without logging out; an attachment opens; websocket live sync works (a change on one device appears on another); `journalctl -u vaultwarden` shows real client IPs, not `127.0.0.1`.
- **Paperless** (`http://paperless.opti.plex`, LAN): a re-login is expected (new secret key); the document count equals `expected-arch.txt`; open a document and its thumbnail; `sudo paperless-manage document_sanity_checker` has no error (one info about a document without OCR text is known); a consumed upload appears.
- **Home Assistant** (`http://homeassistant.opti.plex`): version 2026.10.4, integrations load, **UB500 Bluetooth with `ble_adv` switches the lampsmart light** with no "Missing required permissions" repair (fallback: an ESPHome `ble_adv_proxy`), `cast` and `heos` devices are discovered (if not, open UDP 5353/1900), tplink works, the Pixel's companion app connects.
- **etesync:** the EteSync app (Android) logs in against `etesync.nnik.dev`; Thunderbird/DAVx5 syncs through `dav.nnik.dev` with the existing DAV password; `https://dav.nnik.dev/.web/` opens from the LAN.

### 13.8 battle-tracker (`PENDING 39B`)
- `https://pnp.nnik.dev/` loads and Settings, Sync shows that sync is configured; `https://pnp-backend.nnik.dev/health` returns 200; `battle-tracker-deploy.service` runs on its hourly timer (`systemctl list-timers battle-tracker-deploy.timer`; `systemctl start battle-tracker-deploy` once, and check that it does not fail).
- Not Cutover related, seen on the day: the pipeline check of PR #573 failed on a timing assertion (`test_actual_threaded_broker_slow_dns_cannot_start_late_post`, 0.27 s vs 0.2 s) and `Build flutter-android-ci image` had also failed on `main` earlier: flaky or pre-existing.

### 13.9 transmission, NFS, static sites
- transmission: web UI on `http://transmission.opti.plex` (LAN); the torrents resumed with **no re-verify**; port **51413 connectable on IPv4 and IPv6** (an outside port test); a new download is group-writable: `stat -c '%U:%G %a' /trrnt/<newfile>` is `transmission:transmission 664`. Re-login yannik once so the new `transmission` group applies.
- NFS: the Shield (`192.168.178.38`) plays a file from `/mnt/tbssd/trrnt`.
- Static sites `ya`, `koke`, `immo` and the `opti.plex` dashboard load.

### 13.10 Backup and monitoring
- A manual run of the NixOS Backup into the same repository: `ssh optiplex 'sudo systemctl start restic-backups-optiplex.service'` (bucket) and `restic-backups-optiplex-local.service` (the local repository, which the gate created); both succeed (first runs on the day: bucket 10.6 min, local 13.3 min). The new bucket objects show **"One Zone"** (`infra/scaleway/README.md`, storage-class check).
- healthchecks: pings arrive (`backup-nightly` after the manual run, `units-ok`, `lan-*`); the two LAN probes are green.
- The phone's probe app watches the public sites (step 16.9).

### 13.11 The two runner VMs (no VM test exists any more)
Their tokens come after verification (step 16.2), but the host side can be checked now: `systemctl status microvm@runner-trusted microvm@runner-untrusted` are inactive/idle (no `gitea-runners.yaml` yet, by design) and the nftables tables for the VM bridge exist (`nft list tables`). After the tokens: registration, labels and the firewall from inside a job are checked in step 16.2.

### 13.12 Sign-off
The human says "verified". The agent writes the date into ticket 43 (the Rollback image's lifetime in ticket 44 counts from it) and the time-box check: **verification must finish inside the 24 h of step 4.8**; after it the rollback is by decision only.

---

## 14. Go decision and rollback trigger

The human decides, at the end of step 13 and at any earlier red item. **The time box is 24 h after Arch stops** (decided 2026-11-11; the earlier "4 h" is void): the wall-clock end (the time at step 4.8 plus 24 h) is in the log. Within it a rollback is an ordinary decision; after it Gitea 28 and Seafile 13 have been written to for a day and rolling back means losing that.

**Roll back** if any of these happens before the time box ends:
- the install or the unlock fails and cannot be fixed;
- a database restore fails and `--reset` plus a retry does not fix it;
- the Seafile 12 to 13 upgrade fails, or the clients cannot sync with Seafile 13 (the way back is the Rollback image; `/mnt/tbssd/filesync` and Docker's MariaDB volume were never written to);
- Matrix, Vaultwarden, Seafile or Gitea stays broken, or the Gitea migration fails.

**Fixed forward, not rolled back:** the goolm bridges failing on the restored pickles (switch to libolm with a narrow `permittedInsecurePackages`, build and deploy), Home Assistant Bluetooth (an ESPHome `ble_adv_proxy`), the runner VMs, IPv6, the dashboard, healthchecks.

**What a rollback costs, by stage:**

| Stage reached | What the rollback is | What is lost |
|---|---|---|
| Before step 4.7 | nothing to roll back; stop the window | nothing |
| 4.7 done, Arch still on disk (up to step 5.10) | no image needed: start the stopped containers and units again (list in `arch-running.txt`), undo the resolver edit (15.6), optionally restore `gitea-pre-prune.dump` | the pruned Gitea accounts and the two packages unless the dump is restored |
| Rollback image taken, install not yet run | the human pulls the stick and boots the NVMe (Arch) again; start the containers of `arch-running.txt` | nothing |
| Installed, before the normal deploy (11.2) | steps 15.1 to 15.8 | nothing new on NixOS |
| After the normal deploy | steps 15.1 to 15.8, plus step 15.9 | messages, Vaultwarden items and documents created after 11.2; a WhatsApp re-login may be needed |

Going ahead (a clean step 13 and the human's "verified") **starts the Rollback image's lifetime** (ticket 44: 14 to about 60 days, then deletion, then the DuckDNS account and the FritzBox DynDNS entry go).

---

## 15. Rollback steps

**The rollback needs the stick, a monitor and a keyboard at the Optiplex, plainly: the same installer ISO that installed the system restores Arch (the NixOS system has no tool to overwrite its own System disk, and if it does not boot at all there is nothing else).** Keep the stick in the box until the Rollback image's lifetime is over (ticket 44). **Who / where / time:** the agent runs the commands (PC and Installer), the human does Porkbun, the FritzBox and the physical boot; 60 to 120 min (the image write is 20 to 30 min of it, estimate; creating the image took 23 min on the day, the write-back was not measured). Log the cause first. **A rollback does not resolve ticket 43**: its findings go into the service tickets or the harness, and a new Cutover date follows.

1. **Boot the installer stick** (human at the box): power off (a running NixOS: `sudo systemctl poweroff`), power on, F12, the **UEFI** entry of the stick, as in step 5.10. Check: `ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$OPTI uname -a` answers (use `inst` of step 6.1).
2. **Mount the Data disk at `/data`.** `rollback-image status` mounts it (never under `/mnt`) and prints the recorded size, hash and partition table. Check: it prints the image path and the raw `sha256` noted in step 6.3.
3. **Write the image back.** `rollback-image restore` (it asks you to type the device path; or `--yes`), about 20 to 30 min (estimate). It writes `zstd -dc | dd conv=fsync`, re-reads the disk and compares the `sha256` with the recorded raw one. On the stick the command is `rollback-image` (`inst 'rollback-image restore'`, typed confirmation; the typed answer comes from a terminal: use `ssh -t`). Check: `restored and read back in ... s: sha256 equals the image`.
4. **Give `/mnt/tbssd/trrnt` back to Arch's transmission, before Arch boots** (it would otherwise find files owned by 70): with the Data disk still mounted at `/data`:
   ```sh
   ssh root@$OPTI 'TRRNT=/data/trrnt STATE_TR=/data/state/transmission SAVE=/data/cutover/trrnt-watch.orig bash -s -- back' < machines/optiplex/services/transmission/restore.sh
   ```
   Check: `stat -c '%u:%g' /data/trrnt` is `169:169`; yannik's `watch/` has its original owner and mode.
5. **Public DNS** (human, Porkbun, **unconditionally, not only "if the DNS change happened"**): the updater may have written records. Look at the zone and delete the updater's four records (A and AAAA for the apex and for `*`), and **then** re-create the three records of step 2.2: the ALIAS `nnik.dev`, the ALIAS `www.nnik.dev` and the CNAME `*`, all to `nnik.duckdns.org`, TTL 600. A CNAME or ALIAS cannot coexist with A and AAAA records on the same name, so the order matters. Check: `dig +short foo.nnik.dev @9.9.9.9` resolves through `nnik.duckdns.org` again (allow the 600 s TTL), `dig +short nnik.dev AAAA` prints nothing, and `dig +short A nnik.dev @fortaleza.ns.porkbun.com` answers.
6. **FritzBox** (human): re-enable the DynDNS entry for `nnik.duckdns.org`; re-point the IPv6 port shares back to Arch's old interface ID (the coturn relay share UDP 49152-49252 can stay); set the DHCP DNS server back to `192.168.178.20` (Pi-hole); if step 12 or 16.3 already announced `fd65:c1a5:7d2b::20` as the DNSv6 server, or the rebind exception for `nnik.dev` was added, undo that (the FritzBox announces itself, as before).
7. **Boot Arch** (`inst 'sync; systemctl poweroff'`, the human pulls the stick, powers on; if the BIOS does not start Arch, F12 and the NVMe entry; the PC's known_hosts entry for `$OPTI:25560` matches, since the host key is the same). The native units start on boot; **containers do not**: `docker start` every container listed in `/mnt/tbssd/cutover/arch-running.txt` (the four Seafile containers have `restart=no` and stay down after **any** reboot of Arch, and containers stopped by hand with `unless-stopped` stay stopped), the runners included; start the native units of that list that are down. Start the bridges after Synapse, never both bridge sets at once. If the UEFI boot entry does not boot Arch (the install changed it), Arch's GRUB also lives in the fallback path `/boot/EFI/boot` on the ESP (ticket 47 saw `/boot/EFI/{Dell,GRUB,boot}`): pick it in the BIOS boot menu, or fix the entry with `efibootmgr` from the stick. Not rehearsed.
8. **Optionally restore the pre-prune Gitea dump** (human decides): stop `gitea`, then `docker exec -i gitea-db-1 pg_restore -U gitea -d gitea --clean --if-exists < /mnt/tbssd/cutover/gitea-pre-prune.dump`, start `gitea`. It brings back the 31 accounts, their tokens and SSH keys and the Actions secrets; the blobs of the two deleted packages are gone for good (retired). Not rehearsed.
9. **Tell users what is lost:** Matrix messages, Vaultwarden items, Paperless documents and Seafile changes made after step 11.2. A WhatsApp re-login may be needed if the NixOS bridges advanced their sessions (Telegram too).
10. **Leave `/mnt/tbssd/state`, `arch-gate/`, `cutover/` and the dumps in place** (a retry reuses them; `sync-state.sh --final` makes the copies exact again). Check: Arch's services answer on their old State (Matrix `https://nnik.dev/_matrix/client/versions`, Gitea, Seafile, Vaultwarden, Paperless, Home Assistant, transmission), `systemctl --failed` is empty, the old Pi-hole answers DNS on `.20`.

---

## 16. Follow-ups after verification (run in ticket 43)

Listed here so the runbook is complete. The first three can run in parallel.

1. **battle-tracker push webhook** (`PENDING 39B`): needs the new Gitea. Human, Gitea UI, 5 min, `AItopia/battle-tracker`, Settings, Webhooks: a Gitea webhook to the loopback receiver `http://127.0.0.1:<port>/...` (port and path in `machines/optiplex/services/battle-tracker.nix` once it exists), branch filter `main`. The webhook allow-list is `loopback` only. Check: a push to `main` starts `battle-tracker-deploy.service` (`journalctl -u battle-tracker-deploy`). Until it exists the hourly timer covers deploys.
2. **Runner tokens** (agent for the commands, human for the UI; PC and NixOS Optiplex; 30 min plus the first job): on the Optiplex `sudo optiplex-gitea actions generate-runner-token --scope aitopia` (the trusted token) and `sudo optiplex-gitea actions generate-runner-token` (the untrusted, instance-wide one). On the PC, build `secrets/optiplex/gitea-runners.yaml` (keys `trusted_token`, `untrusted_token`) from stdin without clear text on disk, encrypted to `yannik` and `optiplex` (the recipe is in ticket 33's Answer), `git add` and commit it, deploy (`NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nix run nixpkgs#nixos-rebuild -- switch --flake .#optiplex --build-host localhost --target-host optiplex --sudo`). Check: both runners online in the Gitea admin UI: `runner-trusted` (org `aitopia`, labels `ubuntu-latest`, `ubuntu-24.04`) and `runner-untrusted` (instance, labels `shared`, `shared-24.04`); `systemctl status microvm@runner-trusted microvm@runner-untrusted`; the weekly wipe timer `gitea-runner-untrusted-wipe.timer` exists. **Because the VM test was removed:** run a job on each runner and check the registration, the labels, job routing (an `aitopia` job on the trusted VM, a `shared` job on the untrusted one) and the firewall from inside a job (the internet and `git.nnik.dev` work; the router, a LAN host, the host's 25580 and 25560 and `transmission.opti.plex` do not). Then **delete the ghost runner rows 1 to 17**: the 17 old rows (ids 1 to 17) cannot be deleted in the Gitea UI of this version soft-delete them in the database exactly as Gitea does, in one transaction: `sudo -u postgres psql -d gitea -c "update action_runner set deleted = extract(epoch from now())::bigint where id between 1 and 17 and deleted is null"` (only the ids of rows that are offline; the new runners have higher ids; undo: `set deleted = null`; the historical `action_task` rows keep their runner ids).
3. **FritzBox** (human, FritzBox UI and a phone on mobile data, 15 min): re-check from outside over IPv6 that 443, 8448 and 51413 are reachable; confirm UDP 49152-49252 and TCP+UDP on 3478 and 51413. The DNS part was already done at step 12 (the rebind protection blocks `*.nnik.dev` for LAN clients once the AAAA records exist); if it was not, set the DHCP DNS server back to `192.168.178.20` (blocky) and announce `fd65:c1a5:7d2b::20` as the **DNSv6 server** (Home Network, Network, Network Settings, IPv6; before that the FritzBox announces itself). Check: a LAN client resolves through blocky (ad domains blocked, `opti.plex` and `*.nnik.dev` names resolve), on IPv4 and IPv6. The step-4.2 change is undone here.
4. **Credentials** (human, Gitea UI and the repositories' settings, 1 to 2 h): recreate the accounts that may use Actions and the agent pipeline accounts (`bt-*`, `factory-*`, `mdc-*`, `demo-*`, `bt-registry`), or repoint the pipeline at `Yannik`; create a registry token and set `REGISTRY_USER` and `REGISTRY_TOKEN` as Actions secrets; re-enter `BT_SYNC_BASE_URL` only if a workflow still needs it (`PORTAINER_WEBHOOK_URL` is obsolete). Then rerun `factory` `ci.yml` and one `build-flutter-ci` run on the trusted VM until both are green (`build-flutter-ci` starts its own `dockerd &`, which clashes with the socket the runner mounts: it needs its own `--host=unix://...` socket). Check: a `build-flutter-ci` push to the registry succeeds.
5. **D&D library import** (human and agent, NixOS Optiplex; the order is fixed; it takes hours of wall time, not agent time): (1) create an empty Seafile library; (2) add restic excludes for its `/state/seafile/seafile-data/storage/{blocks,fs,commits}/<library-id>` to `excludes.seafile` in `machines/optiplex/services/restic.nix` and **deploy before the first byte is imported**; (3) import (for example `seaf-cli` on the Optiplex); (4) check the count (13,167 files) and the size (about 168 GB); (5) delete `/mnt/tbssd/cloud`. Check: the next nightly snapshot did not grow by about 168 GB.
6. **Remove the `/movies` source on the Shield** (`192.168.178.38`), human, 5 min. It keeps mounting `/mnt/tbssd/trrnt` read-only.
7. **Seafile admin password** (also in 13.6): not the old 4-digit `INIT_` value, no `me@example.com`.
8. **First nightly Backup** (the next morning, agent, PC and NixOS Optiplex, 10 min): `restic snapshots` shows a snapshot from the NixOS job in the bucket **and** in `/mnt/tbssd/restic-local`, the new objects show "One Zone", and the snapshot lists the host keys and the initrd key: `restic ls latest | grep -E 'ssh_host_(ed25519|rsa)_key|secrets/initrd'`. Only then **shred the PC's tmpfs copies**: `shred -u $X/secret.key $X/extra/etc/ssh/ssh_host_*_key $X/extra/etc/secrets/initrd/ssh_host_ed25519_key; rm -rf "$X"` (the tmpfs also vanishes at reboot). **Retention:** the nightly job keeps one snapshot per day, so its first run prunes the final `arch-gate` snapshots of the same day (step 5.2): tag-protect or copy the final gate snapshot before that run if it must survive. **Do not** shred `$HK` (`~/.local/share/optiplex-hostkeys`): a retry or a rollback-and-retry needs it. Ticket 44 shreds it after the Rollback image's lifetime (its note has the command and the `find` that proves nothing is left).
9. **Phone** (human, 15 min): the ntfy app (server `https://ntfy.nnik.dev`, topic `optiplex`, user `yannik`, password in Vaultwarden) and the open-source probe app with the probe list of `machines/optiplex/monitoring-probes.md`. **Un-pause the external probes** that step 4.2 paused (they are the host-down alert; a power cut means the box waits for `unlock-optiplex.sh`).
10. **Seafile and the other real-client checks** that 13 left open, the `http:` YAML Repair of Home Assistant (if it shows up), and the DNS TTLs: the old plan to raise TTLs back is void (they were never lowered; Porkbun's minimum is 600 s).
11. **Close-out** (agent, PC, 10 min): write the ticket 43 Answer, set it resolved, add the line to the map's "Decisions so far", **record the verification date** for ticket 44. Delete nothing of the Rollback image or `/mnt/tbssd/docker` (ticket 44).

---

## 17. Copy table

One row per Kept service. All rows are rsync copies with `-aHAX --numeric-ids` made by `machines/optiplex/cutover/sync-state.sh` on Arch (`sudo machines/optiplex/cutover/sync-state.sh --list` prints the rows; no flag is the pre-sync, `--final` the downtime pass with `--delete`). Targets are under `/mnt/tbssd/state` (`/state` on NixOS). The Arch trees are never changed. **Rows whose source is on the System disk must be finished before the wipe** (they are lost with it); the Docker volumes and `/mnt/tbssd/filesync` are on the Data disk and could be copied after the install, but the script copies all of them on Arch so that one pass is the whole State.

| Service | Arch source | Target (`/mnt/tbssd/state/`) | When | System disk (before the wipe)? | Owner after restore | Defined in |
|---|---|---|---|---|---|---|
| Synapse media | `/var/lib/synapse/media_store/` | `synapse/media_store/` | pre-sync (25 GB), delta in `--final` | yes | `224:224` (matrix-synapse), set by the copy (`--chown`) | ticket 31 |
| etesync | `/srv/etesync/etebase/db.sqlite3`, `/srv/etesync/media/` | `etesync/db.sqlite3`, `etesync/media/` | downtime only (SQLite) | yes | etesync user (uid 940), fixed by the unit | ticket 38 |
| etesync-dav | `/root/.local/share/etesync-dav/{etesync_creds,etebase_data.db}` | `etesync-dav/` | downtime only | yes | uid 941, fixed by the unit | ticket 38 |
| Gitea | `/mnt/tbssd/docker/volumes/gitea_data/_data/`: `git/repositories`, `git/lfs`, `gitea/{packages,attachments,avatars,repo-avatars,actions_log,home}`; **not** sessions, indexers, queues, tmp, repo-archive, `conf`, `jwt`, `ssh` | `gitea/{repositories,data/...}` | downtime, on NixOS: `optiplex-gitea-restore` (one-shot), step 10.3 | no (Data disk) | `gitea:gitea` (uid 950) | ticket 32 |
| Seafile | `/mnt/tbssd/filesync/seafile/{conf,seafile-data,seahub-data,ccnet}`, excluding `seahub-data/thumbnail/`, `logs/`, `conf/__pycache__/` | `seafile/` | pre-sync (22 GB), delta in `--final` | no (Data disk), copied so the Arch tree stays untouched | root (the container); then `seafile-prepare-state` (step 10.4) | ticket 34 |
| Paperless | volumes `paperless_data` (without `log/`) and `paperless_media` under `/mnt/tbssd/docker/volumes/` | `paperless/`, `paperless/media/` | downtime (about 150 MB) | no | `315:315`, fixed by the unit | ticket 36 |
| Vaultwarden | volume `vaultwarden_data` without `icon_cache/`, `tmp/`, `rsa_key*.pem` | `vaultwarden/` | downtime only (SQLite and WAL) | no | `960:960`, fixed by the unit | ticket 35 |
| Home Assistant | `/srv/homeassistant/` without `home-assistant.log*`, `.ha_run.lock`, `.cache/`, `deps/`, `tts/`, `secrets.yaml` (sops) | `homeassistant/` | downtime only | yes | `286:286`, set by the copy | ticket 37 |
| transmission | `/var/lib/transmission/.config/transmission-daemon/` | `transmission/.config/transmission-daemon/` | downtime only | yes | `70:70`, `restore.sh forward` (step 10.5); `/mnt/tbssd/trrnt` is chowned there too | ticket 40 |
| Static sites | `/srv/http/www.ya.nnik.dev`, `koke.nnik.dev`, `immo.nnik.dev`, `opti.plex` (not `gate/`) | `www/ya`, `www/koke`, `www/immo`, `www/opti.plex` | pre-sync (130 MB) | yes | `1001:100` (yannik:users) | tickets 21, 28 |
| Archive | `/home/yannik/.zsh_history` | `/mnt/tbssd/archive/arch-optiplex/` (outside `state/`, in the Backup) | pre-sync | yes | root, mode 0700 | ticket 02 |
| Databases (8) | native PG18 (`synapse`, `whatsapp`, `telegram`), PG14 containers `gitea-db-1`, `paperless-db-1`, MariaDB container `seafile-mysql` (`ccnet_db`, `seafile_db`, `seahub_db`) | `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>/` | by `arch-gate.sh --final` (step 5.2) with every consumer off, then `optiplex-db-restore` (step 10.2) | Data disk | restored by role, `--no-owner --no-acl --role=<role>` | tickets 29, 20 |
| battle-tracker | nothing: the sync State is empty | `battle-tracker/` is created by the unit | - | - | `bt-sync` (uid 961) | ticket 39 |

Not copied, on purpose: every Retired service (elabFTW, Portainer, Pi-hole, the Signal bridge, maubot, invidious, ...), Tandoor, the WireGuard keys, other homes, `id_rsa`. Their State survives only in the Rollback image.

---

## 18. Timing table

The window is **about 3 to 4.75 h** if nothing goes wrong; book 5 h. **Measured on the day (2026-11-15): about 3 h from "go" to "verified".** Rows marked "measured on the day" are from that run; other "measured" rows are from the real-State rehearsal on the PC (Ryzen 9 7900X, 4 vCPU and 7 GB for the guest, NVMe image); the Optiplex (i5-10500T, 15 GB, SATA Data disk) is slower. Estimates from the first draft of the ticket are marked as such.

| Step | First estimate | Now | Basis |
|---|---|---|---|
| 4.2 to 4.7 FritzBox DNS, version and secret checks, Gitea pre-dump steps | 15 min | 20 to 30 min | estimate (31 accounts, 4 UI steps) |
| 4.8 Stop every consumer | (in the above) | 5 min | estimate |
| 5.2 Final gate run: dumps + SQLite copies + restic (local, then bucket) | dumps 5 min, restic at most 30 min | **7 min** | **measured on the day** (08:34:58 to 08:41:49); Synapse dump 136 s on Arch (ticket 10) |
| 5.3 to 5.5 Counts, stop DB servers, delta sync | 10 min | 10 to 15 min | estimate (the downtime rows are about 250 MB); `sync-state.sh --final` alone **about 1 min, measured on the day** |
| 5.8 to 5.10 Pi-hole, shutdown, human boots the stick (BIOS menu) | "shutdown + USB boot 5 min" | 5 to 10 min | estimate; first boot of the stick on this box |
| 6 Rollback image + verify | 20 to 30 min | **41 min** | **measured on the day**: create 1404 s (99 GB on disk), verify 1076 s |
| 7 and 8 Pre-install checks + install (disko, closure push from the PC), 8.1 power-off and stick out | install 10 to 20 min | install **under 4 min** | **measured on the day** (nixos-anywhere 10:23:38 to 10:27:18); closure push 175 s in the VM rehearsal; the rest estimate |
| 9 Unlock + restoreMode checks | 5 min | 5 min | estimate; cold reboot plus unlock about 2 min (measured on the day) |
| 10.1 to 10.8 Restore: **database restore** | **15 to 30 min** | **Optiplex: 181 s total, Synapse 163 s** (PC rehearsal: 102 s, Synapse 87 s) | **measured on the day**; the old figure was wrong |
| 10.3 to 10.8 Restore: Gitea copy, `seafile-prepare-state`, transmission chown, counts | (in the above) | 5 to 15 min | estimate |
| 11.1 to 11.7 Normal deploy + first starts + healthchecks step | 15 to 30 min | first deploy **about 4 min**; the rest 15 to 30 min | deploy measured on the day; **PC rehearsal: every service up within 25 s**, Synapse first start 8.9 s, Gitea migrations about 1 s, Paperless about 12 s |
| 12 DNS and FritzBox | 10 min | 10 to 20 min | estimate |
| 13 Verification | 45 to 60 min | 45 to 60 min | estimate (Seafile and the bridges need real clients) |
| 13.10 First Backups from NixOS (manual run) | - | bucket 10.6 min, local 13.3 min | measured on the day |
| **Total** | **3.5 to 4.5 h** | **about 3 h** from "go" to "verified" | measured on the day (the ranges above sum to 3 to 4.75 h) |

Time box for the rollback decision: **24 h after Arch stops**, not part of the window.

---

## Appendix A: where every item went

Each item of the map's lines for the Cutover runbook and Cutover execution, the coordinator notes, and every point of the tickets' scope and review notes, mapped to the step that carries it. The map's "Not yet specified" section is empty (the fog graduated into tickets 27 to 44); the lines mapped here are the map's *Open work after the plan review* entries for 42, 43 and 44 and the standing decisions of its Notes.

### A.1 Coordinator notes
| Note | Step |
|---|---|
| DuckDNS and the FritzBox DynDNS are only **disabled** at the Cutover; deleting DuckDNS belongs to ticket 44; a rollback restores the CNAME and re-enables the DynDNS | 11.1 (CNAME deleted, DuckDNS kept), 12.2 (disable only), 15.5 and 15.6 (restore), ticket 44 (deletion) |
| The **final restic run**, order decided 2026-11-14: consumers off, `arch-gate.sh --final` with the DB servers up, then stop the DB servers, delta sync, stop Pi-hole, kexec | 4.8, 5.1 to 5.10 |
| The flake input comes from `git.nnik.dev`, down during the window: **build from the locked input offline** | 3.1, 3.3, 1.14 (`PENDING 39B`) |
| The push **webhook can only be created once the new Gitea is up** | 16.1 (`PENDING 39B`) |

### A.2 The map
| Map line | Step |
|---|---|
| 42 Cutover runbook (the whole ticket; its review note is a checklist of errors, missing rows and stale text) | this document; each checklist item in A.4 |
| 43 Cutover execution and 44 Rollback image lifetime ("each has a review note that corrects its checklists") | A.5, A.6 |
| 45 (rehearsals, pin), 46 (the final order, DDNS off in restoreMode, gate), 47 (sweep), 48 (real-State rehearsal) | 5.10, 8; 5, 11.1; 4, 5.7; 10 and the measured table in 0 |
| 39 Part B (battle-tracker): no `pnp`/`pnp-backend` vhost yet | 1.16, 3.3, 4.7 item 7, 13.3, 13.8, 16.1 |
| Map Notes: same hardware, one big-bang Cutover, Rollback image of the Arch System disk onto the Data disk before the wipe | 6 |
| Map Notes: install with disko and nixos-anywhere, LUKS and btrfs on the System disk only | 8 |
| Map Notes: deploy `nixos-rebuild --flake .#optiplex --target-host optiplex` from the PC | 11.2 (with `--build-host localhost`) |
| Map Notes: State folder, copied not moved | 17, 5.5 |

### A.3 Ticket 42, Scope sections 1 to 16 and "Also in scope"
| Scope item | Step |
|---|---|
| 1 Preconditions (27 to 41 done, toplevel builds, harness, Backup gate, secrets keys, `ssh-to-age`, space) | 1.1 to 1.13 |
| 2 Days before: TTL, FritzBox UDP share, ssh aliases, LUKS, `--extra-files`, ISO, `.zsh_history`, pre-sync, calendar | 2.1 to 2.10 (TTL: 2.2, void) |
| 3 Build ahead | 3.1 to 3.3 |
| 4 T-0: record running state, resolver, stop runners, live-Gitea steps, stop consumers, DB servers stay up | 4.1 to 4.8 |
| 5 Final dumps, delta sync, final restic, hand-over to the installer | 5.1 to 5.10 |
| 6 Rollback image | 6.1 to 6.4 |
| 7 Pre-install checks | 7 |
| 8 Install | 8 |
| 9 First unlock and restoreMode checks | 9.1, 9.2 |
| 10 Restore (DB restore, counts, per-service fix-ups, transmission chown) | 10.1 to 10.8 |
| 11 Normal deploy and the watched first starts | 11.1 to 11.7 |
| 12 DNS and FritzBox | 12.1 to 12.3, 11.1 |
| 13 Verification checklist | 13.1 to 13.12 |
| 14 Go decision and rollback trigger | 14 |
| 15 Rollback steps | 15 |
| 16 Follow-ups | 16 |
| Copy table | 17 |
| Helper scripts: `sync-state.sh`, `rollback-image.sh`, `chown-trrnt.sh`, `expected-counts.sh` | 2.9, 5.5 (sync-state); 6 (rollback-image); 10.5, 15.4 (`chown-trrnt.sh` is `machines/optiplex/services/transmission/restore.sh`, ticket 40 has `forward` and `back`; no second script); 5.3, 10.1, 10.8 (expected-counts) |
| Installer ISO `nixosConfigurations.optiplex-installer` | 2.7, 6, 15.1 |
| Timing table | 18 |
| Inputs: stale copies never restored | 0, rule 2 |
| Inputs: live-Gitea steps (retention, webhook, prune, Actions secrets, registry packages, ssh aliases) | 4.7, 2.4, 11.7 |
| Inputs: elabFTW dropped; `.zsh_history`; D&D library after verification | 0 rule 2, 2.9, 16.5 |
| Inputs: transmission and NFS (copy, chown 70, rollback chown 169, `/movies`) | 10.5, 15.4, 16.6, 13.9 |
| Inputs: static sites | 17, 10.7 |
| Inputs: public DNS and router (CNAME, updater, AAAA `::20`, FritzBox shares, UDP 49152-49252) | 11.1, 11.5, 12, 2.3 |
| Inputs: battle-tracker (pull-based deploy, deletions go live with the Cutover, offline input) | 1.16, 3.3, 4.7 item 7, 16.1 |
| Inputs: runner tokens, Actions accounts and registry token, Seafile admin password | 16.2, 16.4, 13.6 |
| Inputs: rehearsal and verification (Seafile 12 to 13 with the 9.0.x clients; goolm fallback is libolm, not a rollback; UB500; Synapse messages lost on rollback) | 13.6, 14, 13.7, 15.9 |
| Open points: service users in restoreMode | resolved: users, secrets and `/state/<service>` exist in restoreMode (ticket 27); 10.6 |
| Open points: LAN DNS in the window | 4.2 (the FritzBox hands out itself), 16.3 |
| Open points: imaging route | decided 2026-11-14: the USB installer (5.10, 2.7); kexec is not used (5.10 says why); the stick is also the rollback medium (15.1) |
| Open points: `RUN_RETENTION_DAYS` | 4.7 item 2, 11.7 |
| Open points: Seafile block store (copy, `/mnt/tbssd/filesync` untouched) | 17, 5.5 |
| Open points: Let's Encrypt rate limit (5 duplicates a week) | 9.2, 11.5 |
| Open points: rollback time box | 1.18, 14 |
| Open points: sizing (split the scripts and ISO off) | done: helper scripts and the ISO are separate files |

### A.4 Ticket 42, the plan-review note (2026-11-14)
| Item of the checklist | Step |
|---|---|
| kexec command cannot connect (25560, `AllowUsers yannik`): void with the USB route (no kexec); the install is `.#optiplex-restore` as `root@` on 22 | 5.10, 8 |
| Arch has no DNS when kexec fetches its tarball: void with the USB route (the installer uses the FritzBox's DNS by DHCP; the install pushes the closure from the PC with the offline flags) | 5.7, 8 |
| The final restic run: `--final` needs the DB servers; backs up the Arch source paths | 5.2 |
| One dump directory, not `/mnt/tbssd/cutover/dumps/`; call the scripts | 5.2, 10.2 |
| The DDNS updater does not wait for step 12: rollback deletes records unconditionally; pick one CNAME order | 11.1, 15.5 |
| The local Backup repository must exist before the wipe | 1.6 |
| Seafile row: `conf/`, `seafile-data/`, `seahub-data/`, `ccnet/` with the excludes | 17 |
| Mark which rows must finish before the wipe | 17 |
| Step 10 names each tool (`optiplex-db-restore`, `optiplex-gitea-restore`, `seafile-prepare-state`, `transmission/restore.sh forward`, `--chown=224:224`, the others) | 10.2 to 10.6 |
| Dashboard links | 10.7 |
| After the deploy: `doctor check --all`, `cleanup_packages` once, ghost runner rows | 11.7, 16.2 |
| LUKS: no Vaultwarden entry or printout; sops extract; `unlock-optiplex.sh` | 2.5, 9.1, 1.8, 1.9 |
| Time box 24 h, not 4 h | 14 |
| LAN DNS: the FritzBox hands out itself; drop the PC resolver step and "still hands out .20" | 4.2, 16.3 |
| TTL: Porkbun minimum is 600 s | 2.2, 16.10 |
| ACME: watch `acme-order-renew-nnik.dev.service` | 9.2, 11.5 |
| Deploy command: `--build-host localhost`, `nix run nixpkgs#nixos-rebuild` | 11.2 |
| Timing table: kexec hand-over, measured times | 18 |
| Space check includes the local repository, the stage directories and the dumps | 1.12 |
| Day-of version check against the lock; no `pacman -Syu` | 4.3, 0 rule 1 |
| Carried secrets equal live, hashes only | 4.4 |
| Gitea account pruning: exact method | 4.7 item 6 |
| `--extra-files` modes | 2.5 |
| If kexec fails, nothing is written yet: with the stick, if it does not boot nothing is written either; the human boots the NVMe again | 5.10 |
| Rollback medium: the stick with monitor and keyboard (no kexec) | 15.1, 2.7 |

### A.5 Notes of tickets 45 to 48 and the Gitea decision
| Note | Step |
|---|---|
| 46: step 5 order; DDNS off in `optiplex-restore`; a fresh gate run with `ccnet/`; runner VM checks added to verification | 5, 11.5, 15.5; 1.5; 13.11, 16.2 |
| 47: kexec access and the resolver command (void with the USB route), Secure Boot off (nothing to switch off for the stick), space, `pacman -Syu`, 31 accounts, live versions, Seafile `restart=no` | 5.10, 5.7, 4.3, 1.12, 4.7, 0, 2.10, 15.7 |
| 47: Gitea plain delete, compare `issue`, `comment`, `review` counts, stop and restore on a drop | 4.7 items 1 and 6 |
| 48: DB restore 102 s (Synapse 87 s); healthchecks first user; bridge "one time key"; `smartd` red only in VMs | 0 (table), 10.2, 11.4, 11.3, 9.2 and 11.6 |
| 45: kexec rehearsal (the stock tarball lacks `r8169`, so the USB route), Rollback image capture, pinned nixos-anywhere, offline install flags, `unlock-optiplex.sh` rehearsed | 5.10, 2.8, 6, 8, 9.1 |

### A.6 Ticket 43 (execution, verification, follow-ups)
| Item | Step |
|---|---|
| Go/no-go gate | 1 |
| Execution log: times, Rollback image path and size, restic snapshot ID of the final run, deviations | 4.1, 5.2, 6.3, 10.2, 13.12 |
| Rollback, if the trigger fires; a rollback does not resolve the ticket | 14, 15 |
| Verification: host, DNS and TLS, Caddy, Matrix, Gitea, Seafile, other services, Backup and monitoring, the first `restic-backups-optiplex-local` run, the updater's four records and nothing at DuckDNS | 13.1 to 13.10 |
| Follow-ups in order: runner tokens, FritzBox IPv6, credentials, D&D import; ghost runner rows; healthchecks password to Vaultwarden; `/movies` | 16.2, 16.3, 16.4, 16.5, 16.2, 11.4, 16.6 |
| Close-out and the verification date | 16.11 |
| Open point: external monitor during the window | 4.2 (pause the phone probes, or accept the host-down alerts), 16.9 (un-pause) |
| Open point: downtime notice | decided: no warning (0 rule list, 1.17) |

### A.7 Ticket 44 hand-offs
| Item | Step |
|---|---|
| The deletion list gets `/mnt/tbssd/cutover-dumps/` (not used now), `/mnt/tbssd/cutover/`, `/mnt/tbssd/arch-gate/`, `/mnt/tbssd/rollback/`; keep `restic-local` | the paths the runbook creates: 4.5, 5.2, 6.2; ticket 44 owns the deletion |
| Shred the PC's host-key copy after the Rollback image's lifetime, not at the Cutover | 16.8 |
| The DuckDNS account and the FritzBox DynDNS entry are deleted by ticket 44 | 12.2, 14 |

---

## Appendix B: open questions and contradictions

**Questions for the human** (all answered by the human on 2026-11-14)
1. *Bucket restore:* a test restore of `2c253959` was done and the bucket path was proven with a slice; the final snapshot is not restored beforehand.
2. *Physical readiness:* use the stick that sits in the Optiplex (`/dev/sdb` on Arch, 7.5 GB, one partition without a filesystem). Booting it from the BIOS is first tried at the window, with monitor and keyboard attached.
3. *`$REPO_ARCH`:* a fresh clone of `git@github.com:DoodleSchrank/nixos-setup.git` (the repository is public, https works too) at the Cutover commit; the human pushes everything before. Delete Arch's throwaway `~/gate-run`.
4. *Gitea plain delete:* no extra rehearsal; the in-window check of step 4.7 item 6 stands.
5. *The `192.168.178.21:9100` webhook:* exactly one webhook, id 1, a repository webhook on `AItopia/battle-tracker` (Settings, Webhooks).
6. *FritzBox UI:* described by setting, not by menu path: enough.

**Contradictions between tickets, and how this runbook resolved them**
1. *Order of the final restic run.* Ticket 42's step 5 and ticket 43's open point say "every service off, then the run is the last thing"; ticket 46's decision (2026-11-14) replaced it. Followed: ticket 46 (steps 5.2 to 5.5).
2. *Dump directory.* Tickets 29, 31, 32, 34, 36 and ticket 42 name `/mnt/tbssd/cutover-dumps/<ts>/`; with `arch-gate.sh --final` (no `--dumps-dir`) the final dumps land in `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>/`. Followed: the gate's path (5.2, 10.2). `arch-db-dumps.sh` still writes to `cutover-dumps` when run on its own.
3. *Gitea pre-sync.* Ticket 42's copy table says "pre-sync of repos and packages"; ticket 32's `optiplex-gitea-restore` is a one-shot that refuses to merge. Followed: ticket 32 (copy on NixOS, step 10.3).
4. *`RUN_RETENTION_DAYS` on the live Gitea.* Tickets 24 and 43 say to set it live; it does nothing on 1.26.4 and ticket 42's own open point says the NixOS config sets it. Followed: the config (4.7 item 2, 11.7).
5. *CNAME deletion order.* Ticket 28 deletes the `*` CNAME before the first normal deploy; ticket 42 step 12 deleted it after. Followed: ticket 28 (11.1), because the updater starts with the deploy.
6. *FritzBox IPv6 shares.* Ticket 42 re-points them in step 12 (before the IPv6 checks); ticket 43 lists it as a follow-up after verification. Followed: step 12.1 (the verification needs IPv6), with the follow-up as a re-check (16.3).
7. *LAN DNS.* Ticket 42's step 4 and 12 mention the PC's resolver and "the FritzBox still hands out `.20`"; the review decision is the FritzBox handing out itself, and `.20` and the DNSv6 `fd65:c1a5:7d2b::20` after verification. Followed: the decision (4.2, 16.3).
8. *Host-key copy shredding.* Ticket 42's follow-up shreds the `--extra-files` tree after the first Backup; ticket 44 shreds `~/.local/share/optiplex-hostkeys` after the Rollback image's lifetime. Followed: both, as two different things (16.8).
9. *Install route and rollback medium.* Tickets 42, 43 and the to-do list chose kexec with the stick as a fallback; ticket 45's finding (the stock kexec installer has no `r8169`) and the human's decision of 2026-11-14 make **the stick the primary route**. Followed: the stick, with a monitor and a keyboard at the box, for the install and for the rollback (5.10, 8.1, 15.1).
10. *Seafile library count.* "18 libraries" (the API) and 19 rows in `RepoInfo` (ticket 48: the built-in template is the 19th). Both are used where they apply.
11. *`chown-trrnt.sh`.* Ticket 42 asks for it; ticket 40 already has `transmission/restore.sh forward|back`. No second script was written.

**Not verified at the time of writing** (so the Cutover day will tell): the stick booting on this BIOS and the r8169 NIC in the installer (the ISO is full-kernel; booted once in qemu only); the first boot of the installed NVMe (`reboot` phase not used); the initrd unlock on the real hardware; `smartd` on the real disks; the Seafile 9.0.x clients against 13; UB500 Bluetooth; the Optiplex's real restore, imaging and deploy times; `rollback-image.sh` on the real NVMe (it was exercised only against a file); booting the stick; the first nightly Backup from NixOS.
