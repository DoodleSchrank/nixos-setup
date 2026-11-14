# Optiplex Cutover cheat sheet (USB installer route)

Every command the operator runs, in order, from the day before to sign-off. The why, the checks in full and the alternatives are in [`optiplex-cutover-runbook.md`](optiplex-cutover-runbook.md); the number in front of each block is the runbook step. Nothing here is new: each command is in the runbook, a script of `machines/optiplex/cutover/`, `infra/scaleway/`, `machines/optiplex/` or a rehearsal that ran. Secrets are never typed or printed.

**Bold** = the human is needed physically (stick, BIOS menu, FritzBox, Porkbun, Gitea UI, devices). **STOP** = a decision point: do not go on without the human's word.

Where: `PC`, `Arch` (root shell: `ssh optiplex`, then `sudo -i`), `Installer` (the stick), `NixOS` (`ssh optiplex`).

## Variables (define once; the Arch ones in the Arch root shell)

```sh
# PC
cd ~/nixos-setup                                        # the Cutover commit, git status clean
X=/run/user/$(id -u)/optiplex-cutover                   # tmpfs
HK=~/.local/share/optiplex-hostkeys
NIXOS_ANYWHERE=github:nix-community/nixos-anywhere/58132e1d1f813b845382a2aeca4203b18d2ac807
OPTI=192.168.178.20
inst() { ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@"$OPTI" "$@"; }   # the installer (new host key each boot)
# Arch
REPO_ARCH=~/cutover-repo
```

## Day before

**2.1** FritzBox (human): lower the DHCP lease time. **2.3** FritzBox (human): share UDP 49152-49252 to .20; 3478 and 51413 TCP+UDP. **2.2** Porkbun (human): note the records (apex A, `*` CNAME, TTLs).

**2.4** PC: add `Port 25580` to the `~/.ssh/config` aliases `story-review`, `issue`, `wiki`, `improve`.
```sh
ssh -G story-review | grep '^port '      # expect: port 25580 (same for the other three)
ssh -G optiplex | grep -E '^(hostname|port|user) '     # expect: 192.168.178.20, 25560, yannik (1.15)
```

**1.2, 1.3, 1.7** PC: preconditions.
```sh
nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel .#nixosConfigurations.optiplex.config.system.build.toplevel
drv=$(nix eval --raw .#checks.x86_64-linux.optiplex-vm.drvPath) && nix build "$drv^*" -L --no-link   # one VM run at a time, under 10 GB
for f in secrets/optiplex/*.yaml; do echo "== $f"; sops -d --output-type json "$f" | jq -r 'keys[]'; done
tests/optiplex/gen-test-secrets.sh --check
```
expect: builds pass; every file has its keys; the check reports only `gitea-runners.yaml`.

**2.5** PC: the `--extra-files` tree and the passphrase file (tmpfs).
```sh
umask 077; mkdir -p "$X"
[ -e $HK/etc/secrets/initrd/ssh_host_ed25519_key ] || { mkdir -p $HK/etc/secrets/initrd; ssh-keygen -q -t ed25519 -N '' -C optiplex-initrd -f $HK/etc/secrets/initrd/ssh_host_ed25519_key; }
rm -rf "$X/extra"; mkdir -p "$X/extra/etc/ssh" "$X/extra/etc/secrets/initrd"
cp $HK/etc/ssh/ssh_host_ed25519_key $HK/etc/ssh/ssh_host_rsa_key "$X/extra/etc/ssh/"
ssh-keygen -y -f "$X/extra/etc/ssh/ssh_host_ed25519_key" > "$X/extra/etc/ssh/ssh_host_ed25519_key.pub"
ssh-keygen -y -f "$X/extra/etc/ssh/ssh_host_rsa_key" > "$X/extra/etc/ssh/ssh_host_rsa_key.pub"
cp $HK/etc/secrets/initrd/ssh_host_ed25519_key "$X/extra/etc/secrets/initrd/"
chmod 755 "$X/extra" "$X/extra/etc" "$X/extra/etc/ssh"; chmod 700 "$X/extra/etc/secrets" "$X/extra/etc/secrets/initrd"
chmod 600 "$X"/extra/etc/ssh/ssh_host_{ed25519,rsa}_key "$X/extra/etc/secrets/initrd/ssh_host_ed25519_key"; chmod 644 "$X"/extra/etc/ssh/*.pub
sops -d --extract '["luks_passphrase"]' secrets/luks.yaml > "$X/secret.key"; chmod 600 "$X/secret.key"
wc -c < "$X/secret.key"                                  # expect: 64
stat -c '%a %n' $X/extra $X/extra/etc $X/extra/etc/ssh $X/extra/etc/secrets/initrd   # expect: 755 755 755 700
```

**2.7** PC to the stick. **Human picks the stick** (the empty 7.5 GB USB "Slim Line", `/dev/sdb` on Arch; never the 3.6 TB Data disk).
```sh
nix build .#nixosConfigurations.optiplex-installer.config.system.build.isoImage --out-link $X/installer
ssh optiplex 'lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS'
ls -l /dev/disk/by-id/ | grep usb          # on Arch: the stick's <by-id>
ssh optiplex 'sudo dd of=/dev/disk/by-id/<by-id> bs=4M conv=fsync status=none' < $X/installer/iso/*.iso
ssh optiplex 'sudo head -c <iso size in bytes> /dev/disk/by-id/<by-id> | sha256sum'; sha256sum $X/installer/iso/*.iso   # expect: equal
```
The ISO was booted once in qemu (UEFI): up in 16 s, DHCP, root ssh with the yannik keys, tools and the `r8169` module present. Not tested: the stick on the real BIOS and the real NIC.

**2.8, 3.1, 3.3** PC: pin and build ahead, then prove it offline.
```sh
nix build --no-link "$NIXOS_ANYWHERE"
nix flake archive
nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.optiplex.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.optiplex-restore.config.system.build.diskoScript
nix build --offline --no-link .#nixosConfigurations.optiplex-restore.config.system.build.toplevel .#nixosConfigurations.optiplex.config.system.build.toplevel .#nixosConfigurations.optiplex-restore.config.system.build.diskoScript
```
expect: the offline build fetches nothing. (PENDING 39B: the battle-tracker input.)

**2.9** Arch: clone, seed the Archive, pre-sync (repeat the last line daily).
```sh
git clone https://github.com/DoodleSchrank/nixos-setup.git $REPO_ARCH
git -C $REPO_ARCH checkout <the Cutover commit>; git -C $REPO_ARCH rev-parse HEAD      # expect: equals the PC's
rm -rf ~/gate-run; cd $REPO_ARCH
sudo machines/optiplex/cutover/sync-state.sh --dry-run
sudo machines/optiplex/cutover/sync-state.sh
```
expect: `/mnt/tbssd/archive/arch-optiplex/.zsh_history` exists; a second run transfers almost nothing.

**1.x** STOP: go/no-go of the day before (runbook section 1, ticket 43 gate): the human says go or a new date. No `pacman -Syu`, no reboot of Arch, **monitor and keyboard at the Optiplex, stick in it**.

## The window

**4.2** **FritzBox (human): DHCP DNS = the FritzBox itself (192.168.178.1). Pause the phone probe app.**
```sh
nmcli con up "$(nmcli -t -f NAME con show --active | head -1)"; getent hosts nnik.dev      # PC; expect: answers
```

**4.3** Version check (Arch, then PC).
```sh
pacman -Q matrix-synapse; mautrix-whatsapp --version; /srv/matrix-services/mautrix-telegram/mautrix-telegram --version
docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' gitea paperless-webserver-1 seafile vaultwarden homeassistant
cat /srv/homeassistant/.HA_VERSION; ls -l /mnt/tbssd/filesync/seafile | grep seafile-server-latest
for a in matrix-synapse gitea paperless vaultwarden home-assistant transmission postgresql; do printf '%s ' $a; nix eval --raw .#nixosConfigurations.optiplex.config.services.$a.package.version; echo; done   # PC
```
expect: Synapse 1.156.0 live, nothing newer than the lock (table in 4.3). **4.4** compare the 23 carried secrets by hash (runbook table). **STOP** on any difference.

**4.5** Arch: record the running state.
```sh
install -d -m 0700 /mnt/tbssd/cutover
{ docker ps --format '{{.Names}}'; echo ---; docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq); echo ---; systemctl list-units --type=service --state=running --no-legend; echo ---; nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv6.ignore-auto-dns con show "Wired connection 1"; } > /mnt/tbssd/cutover/arch-running.txt
curl -s http://127.0.0.1:8008/_matrix/key/v2/server | jq -r '.verify_keys | keys[]'      # note the key ID
```

**4.6** Arch: `docker stop gitea_runners-factory_runner-1 gitea_runners-factory_runner-2 gitea_runners-factory_runner-3`

**4.7** Arch, **with the human in the Gitea UI**: live-Gitea steps (runbook 4.7 has the full text).
```sh
docker exec gitea-db-1 pg_dump -U gitea -Fc gitea > /mnt/tbssd/cutover/gitea-pre-prune.dump
pg_restore -l /mnt/tbssd/cutover/gitea-pre-prune.dump > /dev/null
cat > /mnt/tbssd/cutover/gitea-counts.sql <<'SQL'
select 'issue', count(*) from issue union all select 'comment', count(*) from comment
union all select 'review', count(*) from review union all select 'repository', count(*) from repository;
SQL
docker exec -i gitea-db-1 psql -U gitea -d gitea -At < /mnt/tbssd/cutover/gitea-counts.sql | tee /mnt/tbssd/cutover/gitea-counts-before.txt
```
**Human, UI:** delete the webhook (repo `AItopia/battle-tracker`, Settings, Webhooks), the 4 Actions secrets, the packages `battle-tracker-web` and `bt-sync-server`; run the `cleanup_packages` cron; create the short-lived admin token `cutover-prune`.
```sh
docker exec gitea-db-1 psql -U gitea -d gitea -At -c 'select count(*) from webhook'     # expect: 0
read -rs GITEA_ADMIN_TOKEN; export GITEA_ADMIN_TOKEN
API=http://127.0.0.1:25579/api/v1
curl -fsS -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users?limit=50" | jq -r '.[].login' | grep -vx Yannik | sort > /mnt/tbssd/cutover/gitea-accounts.txt
wc -l < /mnt/tbssd/cutover/gitea-accounts.txt                       # expect: 31
first=$(head -1 /mnt/tbssd/cutover/gitea-accounts.txt)
curl -fsS -X DELETE -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users/$first"
docker exec -i gitea-db-1 psql -U gitea -d gitea -At < /mnt/tbssd/cutover/gitea-counts.sql > /mnt/tbssd/cutover/gitea-counts-after-first.txt
diff /mnt/tbssd/cutover/gitea-counts-before.txt /mnt/tbssd/cutover/gitea-counts-after-first.txt && echo SAME
```
**STOP** unless `SAME` (else restore the dump, runbook 4.7 item 6). Then:
```sh
tail -n +2 /mnt/tbssd/cutover/gitea-accounts.txt | while read -r u; do curl -fsS -X DELETE -H "Authorization: token $GITEA_ADMIN_TOKEN" "$API/admin/users/$u"; done
unset GITEA_ADMIN_TOKEN
```
**Human:** delete the `cutover-prune` token; **merge the battle-tracker Docker-deletion PR (PENDING 39B)**. expect: the user list shows only `Yannik`.

**4.8** Arch: stop every consumer. **Write down the time: the 24 h rollback time box starts.**
```sh
systemctl stop mautrix-whatsapp mautrix-telegram
systemctl stop synapse turnserver etesync etesync-caldav transmission nginx lighttpd filebrowser immo.nnik.dev cronie
docker stop gitea paperless-webserver-1 paperless-broker-1 seafile seadoc seafile-memcached homeassistant vaultwarden portainer bt-web bt-sync-server elabftw mysql
docker ps --format '{{.Names}}'          # expect: only gitea-db-1, paperless-db-1, seafile-mysql
systemctl list-units --type=service --state=running --no-legend    # expect: postgresql, pihole-FTL, sshd, NetworkManager, base units
```

**5.1** PC: the restic env file onto Arch.
```sh
sops -d --output-type json secrets/optiplex/restic.yaml \
  | jq -r '"RESTIC_REPOSITORY=s3:\(.s3_endpoint)/\(.s3_bucket)\nRESTIC_PASSWORD=\(.repository_password)\nAWS_ACCESS_KEY_ID=\(.s3_access_key_id)\nAWS_SECRET_ACCESS_KEY=\(.s3_secret_access_key)\nAWS_DEFAULT_REGION=\(.s3_region)"' \
  | ssh optiplex 'sudo install -m 0600 /dev/stdin /root/restic-gate.env'
ssh optiplex 'sudo head -1 /root/restic-gate.env'
```
expect: `RESTIC_REPOSITORY=s3:https://s3.fr-par.scw.cloud/nnik-optiplex-restic`

**5.2, 5.3, 5.4, 5.5** Arch: final gate run (DB servers still up), counts, stop DB servers, delta sync.
```sh
cd $REPO_ARCH
sudo infra/scaleway/arch-gate.sh --env-file /root/restic-gate.env --final --dry-run
sudo infra/scaleway/arch-gate.sh --env-file /root/restic-gate.env --final | tee /mnt/tbssd/cutover/arch-gate-final.log
sudo machines/optiplex/cutover/expected-counts.sh capture --host arch --out /mnt/tbssd/cutover/expected-arch.txt
docker stop $(docker ps -q); systemctl stop postgresql
sudo machines/optiplex/cutover/sync-state.sh --final 2>&1 | tee /mnt/tbssd/cutover/sync-state-final.log
sudo machines/optiplex/cutover/sync-state.sh --final --dry-run 2>&1 | grep -E 'regular files transferred|deleted files|deleting'
```
expect: `mode: final` in the dump `MANIFEST`; both snapshot IDs and `<DUMPDIR>` = `/mnt/tbssd/arch-gate/<STAMP>/dumps/<TS>` noted; the last command shows 0 transfers, no `deleting`.

**5.8, 5.9** Arch: `systemctl stop pihole-FTL`, then `systemctl list-units --type=service --state=running --no-legend; docker ps; sync` (expect: base units only, no containers).

**STOP:** is the log complete (snapshot IDs, dump directory, counts file, times)? The human says "shut down Arch".

**5.10** **Human at the Optiplex (monitor + keyboard, stick in).** Arch: `sync; systemctl poweroff`. **Human: power on, F12, choose the UEFI entry of the USB stick.**
```sh
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$OPTI 'uname -a; ethtool -i $(ls /sys/class/net | grep -v ^lo | head -1) | head -3; ls -d /sys/firmware/efi'
```
expect: answers as root on 22; driver `r8169`; `/sys/firmware/efi` exists. If not: **human** power-cycles and picks the NVMe (Arch), nothing was written.

**6.1, 6.2, 6.3, 6.4** Installer: look, image, verify, release the Data disk.
```sh
inst 'lsblk -o NAME,SIZE,MODEL,FSTYPE,UUID,MOUNTPOINTS; findmnt -rn | grep -E "nvme|/dev/sd"'     # expect: nothing mounted
inst 'rollback-image create --dry-run'
inst 'nohup rollback-image create > /root/rollback-create.log 2>&1 < /dev/null &'
inst 'tail -f /root/rollback-create.log'                       # expect: imaged in ... s
inst 'rollback-image verify --against-device'                  # expect: the disk still equals the image
inst 'cat /data/rollback/arch-nvme0n1.img.zst.sha256'          # note it
inst 'sync; umount /data; findmnt /data; echo rc=$?'           # expect: rc=1
```

**7** Installer: `inst 'ls -l /dev/disk/by-id/ | grep -i kioxia; lsblk -o NAME,MOUNTPOINTS; ls -d /sys/firmware/efi'` (expect: KIOXIA listed, nothing mounted).

**STOP:** the Rollback image is verified and its hash is noted. The human says "install".

**8** PC: install (restoreMode).
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
expect: exit 0.

**8.1** `inst 'sync; systemctl poweroff'`. **Human: when the box is off, pull the stick, power on.** (BIOS boots the stick or nothing: power off, stick out, F12, "Linux Boot Manager" of the NVMe.)
```sh
nc -z $OPTI 2222 && echo initrd-up       # expect: initrd-up
```

**9.1, 9.2** PC then NixOS: unlock and check restoreMode.
```sh
machines/optiplex/unlock-optiplex.sh
until ssh -o BatchMode=yes -o ConnectTimeout=5 optiplex true; do sleep 5; done       # expect: no host-key warning
ssh optiplex 'findmnt /mnt/tbssd /state; ip -br addr; sudo ls /run/secrets | wc -l; systemctl is-active postgresql mysql smartd; systemctl --failed --no-legend'
ssh optiplex 'sudo -u postgres psql -Atc "select datname from pg_database order by 1"; sudo mariadb -e "show databases"'
dig +short @$OPTI nnik.dev
```
expect: `.20`, `::20`, `fd65:c1a5:7d2b::20`; smartd active; no Kept service running.

**10.1** PC: is the copy complete?
```sh
scp machines/optiplex/cutover/expected-counts.sh optiplex:/tmp/
ssh optiplex 'sudo du -sh /state/*; sudo bash /tmp/expected-counts.sh capture --host nixos --skip-db --out /tmp/counts-files.txt; sudo bash /tmp/expected-counts.sh diff --common /mnt/tbssd/cutover/expected-arch.txt /tmp/counts-files.txt'
```
expect: equal except `files.gitea_repositories`.

**10.2 to 10.5** NixOS: restore.
```sh
ssh optiplex 'sudo optiplex-db-restore <DUMPDIR>'                         # PC rehearsal: 102 s total
ssh optiplex 'sudo optiplex-gitea-restore /mnt/tbssd/docker/volumes/gitea_data/_data'     # expect: 4 repositories restored
ssh optiplex 'sudo seafile-prepare-state'                                 # read the NOTE lines
ssh optiplex 'sudo bash -s -- forward' < machines/optiplex/services/transmission/restore.sh
ssh optiplex 'sudo bash /tmp/expected-counts.sh capture --host nixos --out /tmp/counts-full.txt; sudo bash /tmp/expected-counts.sh diff /mnt/tbssd/cutover/expected-arch.txt /tmp/counts-full.txt'
```
expect: every database checked; the last diff says all values equal. **STOP** on any difference or failed database (`optiplex-db-restore --reset <db>`, then `optiplex-db-restore <DUMPDIR> --only <db>`).
**10.7** edit the dashboard: `ssh -t optiplex 'sudoedit /state/www/opti.plex/index.html'` (Portainer and Pi-hole out, `http://healthchecks.opti.plex` in).

**11.1** **Human, Porkbun: delete the `*.nnik.dev` CNAME now** (not DuckDNS).
```sh
dig +short CNAME foo.nnik.dev @fortaleza.ns.porkbun.com      # expect: nothing
```

**STOP (point of no return, 11.2):** the human acknowledges that a rollback now loses what the new system writes.

**11.2, 11.3** PC: deploy, then watch.
```sh
nix run nixpkgs#nixos-rebuild -- switch --flake .#optiplex --build-host localhost --target-host optiplex --sudo
ssh optiplex 'journalctl -fu matrix-synapse'      # also: gitea, podman-seafile, paperless-scheduler, mautrix-whatsapp, mautrix-telegram
ssh optiplex 'curl -s http://127.0.0.1:8008/_matrix/key/v2/server | jq -r ".verify_keys | keys[]"'      # expect: the key ID of 4.5
ssh optiplex 'curl -fsS http://127.0.0.1:25577/api2/ping/'                                                  # expect: "pong"
ssh optiplex 'journalctl -u vaultwarden | grep -i "Private key"'                                            # expect: nothing
ssh optiplex 'transmission-remote 127.0.0.1:25559 -l | tail -2'                                             # expect: 97 torrents
```

**11.4** **Human:** the healthchecks first user.
```sh
ssh -t optiplex 'sudo healthchecks-manage createsuperuser'
ssh optiplex 'sudo systemctl start healthchecks-ensure'
```
expect: 5 checks at `http://healthchecks.opti.plex`; the two probe units go green.

**11.5 to 11.7** NixOS: ACME, the updater, state, Gitea.
```sh
ssh optiplex 'journalctl -u acme-order-renew-nnik.dev --no-pager | tail -20; sudo ddns-porkbun --dry-run; journalctl -u ddns-porkbun --no-pager | tail'
ssh optiplex 'readlink /run/current-system; systemctl --failed --no-legend'
nix path-info .#nixosConfigurations.optiplex.config.system.build.toplevel                   # PC; expect: equals readlink
ssh optiplex 'sudo optiplex-gitea doctor check --all'
ssh optiplex 'sudo grep -A4 "^\[actions\]" /state/gitea/custom/conf/app.ini'               # expect: RUN_RETENTION_DAYS = 0
```
**Human:** run the `cleanup_packages` cron once (Gitea UI). expect: a production Let's Encrypt certificate; four updater records; `--failed` empty.

**12.1, 12.2** **Human, FritzBox:** IPv6 shares to `::20` (80, 443, 8448, 51413, 3478, 49152-49252 UDP); **disable (not delete) the DynDNS**. **12.3**
```sh
dig +short nnik.dev A @9.9.9.9; dig +short nnik.dev AAAA @9.9.9.9; dig +short foo.nnik.dev A @9.9.9.9
```

## Verification (runbook 13; one pass, evidence into ticket 43)

**13.1** `ssh optiplex 'sudo systemctl reboot'`, then `machines/optiplex/unlock-optiplex.sh` and `until ssh -o BatchMode=yes optiplex true; do sleep 5; done`; `ssh optiplex 'sudo systemctl start notify-failure@verification-test.service'` (**human: the push arrives on the phone**).
**13.2** `dig @192.168.178.20 nnik.dev`; `echo | openssl s_client -connect nnik.dev:443 -servername nnik.dev 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName`.
**13.3 to 13.9 (human with devices):** public sites over IPv4 and IPv6 from mobile data; Element, both bridges, a TURN call; Gitea login, clone on 25580, packages, OAuth apps; Seafile 18 libraries, a share link, desktop and Android clients, no `me@example.com`; Vaultwarden, Paperless, Home Assistant (`ble_adv`), etesync; `pnp` and `pnp-backend` (PENDING 39B); transmission port 51413 on v4 and v6, NFS from the Shield, static sites.
**13.10**
```sh
ssh optiplex 'sudo systemctl start restic-backups-optiplex.service restic-backups-optiplex-local.service'
```
expect: both succeed; new bucket objects show "One Zone".

**STOP: go decision (14).** The human says "verified" inside the 24 h time box, or says rollback. Roll back if: install or unlock fails for good, a DB restore fails, Seafile 12 to 13 fails or its clients cannot sync, Matrix/Vaultwarden/Seafile/Gitea stays broken. Fixed forward: goolm (libolm fallback), HA Bluetooth, runners, IPv6.

## After verification (runbook 16)

**16.1 (PENDING 39B)** **Human:** the push webhook on `AItopia/battle-tracker` to the loopback receiver.
**16.2** runner tokens:
```sh
ssh optiplex 'sudo optiplex-gitea actions generate-runner-token --scope aitopia'     # trusted_token
ssh optiplex 'sudo optiplex-gitea actions generate-runner-token'                     # untrusted_token
# PC: build secrets/optiplex/gitea-runners.yaml from stdin (ticket 33's recipe), git add + commit, then:
nix run nixpkgs#nixos-rebuild -- switch --flake .#optiplex --build-host localhost --target-host optiplex --sudo
```
**16.3** **Human, FritzBox:** DHCP DNS back to `192.168.178.20`; DNSv6 server `fd65:c1a5:7d2b::20`. **16.4** credentials and the registry token (Gitea UI). **16.5** D&D import (restic excludes first). **16.6** `/movies` off the Shield. **16.9** phone: ntfy app and probes, un-pause them.

**16.8** next morning, PC: the first nightly Backup, then shred the tmpfs copies (keep `$HK`).
```sh
# restic snapshots and restic ls latest | grep -E 'ssh_host_(ed25519|rsa)_key|secrets/initrd' (runbook 16.8), for the bucket and /mnt/tbssd/restic-local; expect: a NixOS snapshot in both, host keys and initrd key listed
shred -u $X/secret.key $X/extra/etc/ssh/ssh_host_*_key $X/extra/etc/secrets/initrd/ssh_host_ed25519_key; rm -rf "$X"
```

## Rollback (runbook 15; the stick, a monitor and a keyboard are needed)

Decision first: log the cause, time box not over. **Human: power off, power on, F12, the UEFI entry of the stick.**
```sh
inst 'uname -a'                                                   # the installer answers
inst 'rollback-image status'                                      # mounts /data; shows size and hash (compare 6.3)
ssh -t -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$OPTI 'rollback-image restore'     # type the device path; expect: sha256 equals the image
ssh root@$OPTI 'TRRNT=/data/trrnt STATE_TR=/data/state/transmission SAVE=/data/cutover/trrnt-watch.orig bash -s -- back' < machines/optiplex/services/transmission/restore.sh
```
**Human:** Porkbun: delete the updater's four records (A and AAAA, apex and `*`), apex A back to the noted value, **then** re-create the `*` CNAME to `nnik.duckdns.org`. FritzBox: re-enable the DynDNS, IPv6 shares back to Arch's old interface ID, DHCP DNS back to `192.168.178.20`, undo the DNSv6 announcement. Then `inst 'sync; systemctl poweroff'`, **pull the stick, power on** (F12, NVMe if needed).
```sh
# Arch, root shell: start what does not start by itself (list in /mnt/tbssd/cutover/arch-running.txt; Seafile containers have restart=no)
docker start <each container of arch-running.txt>
```
Optional, human decides: restore `gitea-pre-prune.dump` (runbook 15.8). Tell users what is lost (15.9). Leave `/mnt/tbssd/state` in place.
