# Backup tooling on NixOS

Research for ticket 12 of the Optiplex migration map (`.scratch/optiplex-nixos-migration/issues/12-research-backup-tooling.md`). Researched 2026-11-06.

nixpkgs links are pinned to `nixos-unstable` at commit [`1d06008`](https://github.com/NixOS/nixpkgs/commit/1d060086d60cb76a40cf37109f979d88a5bd6396) so line anchors stay valid. Shorthand below: `N/` = `https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/`.

## Question

What are the NixOS-native options for the Optiplex's Backup (`services.restic.backups`, `services.borgbackup.jobs`, others)? For each: how does it handle database dumps (pre-hooks, `services.postgresqlBackup`, `services.mysqlBackup`), secrets via sops-nix, pruning, and monitoring/failure alerts? Which off-site targets does each support well (another LAN host, Hetzner Storage Box, Backblaze B2/S3)? Compare; don't decide.

## Short answer

- **Three serious NixOS-native candidates**: `services.restic.backups` (restic 0.19.1), `services.borgbackup.jobs` (Borg 1.4.5), and `services.borgmatic` (borgmatic 2.1.7, a Borg wrapper). Each restic or borgbackup job becomes a systemd oneshot service plus a timer. The borgmatic module ships upstream's single `borgmatic.service` and `borgmatic.timer` and renders YAML config. ([restic.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L458-L530), [borgbackup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L141-L202), [borgmatic.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix#L195-L207))
- **Targets are the main difference.** Restic speaks SFTP, its own REST server, S3 (including B2's S3 API), native B2 and anything rclone supports ([restic docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)). Borg 1.x only works with local paths or SSH, with `borg serve` running on the remote side ([Borg quickstart](https://borgbackup.readthedocs.io/en/1.4-maint/quickstart.html#remote-repositories)). That means **no B2/S3 for Borg**. Borg 2 adds S3/B2/rclone but upstream says it is beta and not for production ([borg master README](https://github.com/borgbackup/borg/blob/master/README.rst)).
- **Hetzner Storage Box works with both.** It runs `borg serve` on port 23 (1.1/1.2/1.4) and supports restic via SFTP or `rclone serve restic` over SSH. "External Reachability" must be enabled before a home server can reach it ([Hetzner docs](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/)).
- **Database dumps**: `services.postgresqlBackup` and `services.mysqlBackup` write compressed dumps to `/var/backup/{postgresql,mysql}` on a timer. Either tool can then back that directory up as ordinary files ([postgresql-backup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L42-L67), [mysql-backup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L60-L85)). The alternatives skip the staging copy on disk by streaming the dump: restic's `command` option, Borg's `dumpCommand`, or borgmatic's built-in PostgreSQL/MariaDB hooks.
- **Secrets**: restic takes file paths (`passwordFile`, `environmentFile`, `repositoryFile`, `rcloneConfigFile`). That fits sops-nix's `config.sops.secrets.<x>.path` and `sops.templates` directly. Borg takes `encryption.passCommand = "cat <path>"` and `environment.BORG_RSH = "ssh -i <path>"`. Both run as root by default, and sops-nix secrets default to `root:root`, so no extra `owner` is needed ([sops-nix README](https://github.com/Mic92/sops-nix#set-secret-permissionowner-and-allow-services-to-access-it)).
- **Pruning**: restic has `pruneOpts`, which runs `unlock` and `forget --prune` after each backup, plus optional `checkOpts`/`runCheck`. Borg has `prune.keep`, which runs `prune` followed by `compact` ([restic.nix L418-L424](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L418-L424), [borgbackup.nix L117-L128](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L117-L128)).
- **Monitoring**: the restic and borgbackup modules have **no built-in alerting**. The usual approach is NixOS's generic `systemd.services.<unit>.onFailure`/`onSuccess` (→ `OnFailure=`/`OnSuccess=`) pointing at a notifier unit, such as ntfy or a healthchecks.io ping ([systemd-unit-options.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/lib/systemd-unit-options.nix#L270-L287)). borgmatic has native monitoring hooks (Healthchecks, ntfy, Uptime Kuma, Apprise, …) ([borgmatic monitoring](https://torsion.org/borgmatic/how-to/monitor-your-backups/)).
- **Ransomware/compromise resistance**: Borg has append-only mode, either on a NixOS-hosted repo (`services.borgbackup.repos.<n>.authorizedKeysAppendOnly`) or on Hetzner. Restic gets it from `services.restic.server.appendOnly` (rest-server) or `rclone serve restic --append-only`. B2 has Object Lock ([borgbackup.nix L279-L288](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L279-L288), [restic-rest-server.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic-rest-server.nix#L29-L38), [B2 Object Lock](https://www.backblaze.com/docs/cloud-storage-object-lock)).
- **Two destinations** (e.g. LAN plus off-site): both upstreams recommend independent repos written by separate jobs, not syncing one repo to another. Restic also offers `restic copy` between repos ([Borg FAQ](https://borgbackup.readthedocs.io/en/1.4-maint/faq.html#can-i-copy-or-synchronize-my-repo-to-another-location), [restic copy](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories)).

## Details

### Inventory: what nixpkgs ships

`nixos/modules/services/backup/` contains, among others, `restic.nix`, `restic-rest-server.nix`, `borgbackup.nix`, `borgmatic.nix`, `postgresql-backup.nix`, `mysql-backup.nix`, `automysqlbackup.nix`, `pgbackrest.nix`, `btrbk.nix`, `duplicity.nix`, `duplicati.nix`, `rsnapshot.nix` and `tarsnap.nix` ([directory listing](https://github.com/NixOS/nixpkgs/tree/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup)). nixpkgs has no NixOS module for kopia or rustic, although both are packaged (kopia 0.23.1, rustic 0.11.4) ([kopia](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/ko/kopia/package.nix), [rustic](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/ru/rustic/package.nix)). Packaged versions: restic 0.19.1, borgbackup 1.4.5, borgmatic 2.1.7 ([restic pkg](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/re/restic/package.nix), [borgbackup pkg](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/bo/borgbackup/package.nix), [borgmatic pkg](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/bo/borgmatic/package.nix)).

`btrbk` does local btrfs snapshots and send/receive. It could complement a backup of the btrfs System disk, but it doesn't help the ext4 Data disk and doesn't produce an encrypted off-site copy, so this document doesn't cover it further.

### `services.restic.backups.<name>`

Module: [`N/restic.nix`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix)

- **Units**: generates `restic-backups-<name>.service` (`Type=oneshot`, `restartIfChanged = false`, after `network-online.target`). It also generates a timer that defaults to `OnCalendar=daily`, `Persistent=true`. `timerConfig = null` means the job only runs manually ([L180-L197](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L180-L197), [L455-L463](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L458-L463), [L523-L530](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L523-L530)). Runs as `root` by default (`user` option) ([L198](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L198)).
- **Wrapper**: `createWrapper` (default `true`) installs a `restic-<name>` command with the service's environment, which helps with `snapshots`/`mount`/`restore` by hand ([L303-L311](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L303-L311), [L532-L553](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L532-L553)).
- **Repo creation**: `initialize = true` runs `restic init` when `cat config` exits with code 10 ("repository does not exist") ([L230-L236](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L230-L236), [L494-L502](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L494-L502), [restic exit codes](https://restic.readthedocs.io/en/stable/075_scripting.html#exit-codes)).
- **What to back up**: `paths`, `exclude`, `dynamicFilesFrom` (a script that prints paths), **or** `command`, which is passed to `--stdin-from-command` ([L133-L178](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L133-L178), [L274-L283](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L274-L283)).
  - A job can't have both `paths` and `command`. The module puts both into one `restic backup` call, and restic refuses `--stdin-from-command` together with `--files-from` ([L464-L475](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L464-L475), [restic cmd_backup.go L306-L309](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L306-L309)). So streaming a DB dump means one extra job per dump stream.
- **Hooks**: `backupPrepareCommand` runs in `preStart` and `backupCleanupCommand` in `postStop` ([L285-L301](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L285-L301), [L488-L520](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L488-L520)). systemd runs `ExecStopPost`/`postStop` after a failed run as well ([systemd.service(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#ExecStopPost=)).
- **Pruning/checking**: a non-empty `pruneOpts` (e.g. `--keep-daily 7`) appends `restic unlock` and then `restic forget --prune <opts>` to `ExecStart`, after the backup. A non-empty `checkOpts`, or `runCheck = true`, appends `restic check <opts>` ([L238-L272](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L238-L272), [L418-L424](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L418-L424)). Upstream notes that prune locks the repo, which blocks backups while it runs. Upstream also advises running `check` after pruning ([restic forget docs](https://restic.readthedocs.io/en/stable/060_forget.html)). `check` doesn't read pack data unless `--read-data`/`--read-data-subset` is given ([restic check docs](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#checking-integrity-and-consistency)). A job with `paths = null`/`[]` and no `command` becomes a prune-only job ([L133-L148](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L133-L148)).
- **Exit codes**: restic exits with 3 when "backup could not read some source data". A unit in that state counts as failed, because systemd treats any non-zero exit of a oneshot as failure ([restic exit codes](https://restic.readthedocs.io/en/stable/075_scripting.html#exit-codes)).

### `services.borgbackup.jobs.<name>` (and `.repos.<name>`)

Module: [`N/borgbackup.nix`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix). NixOS manual chapter: [`N/borgbackup.md`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.md).

- **Units**: generates `borgbackup-job-<name>.service`, a generated bash script that runs at idle CPU/IO priority under `ProtectSystem=strict`. Only `~/.config/borg`, `~/.cache/borg`, local repos and `readWritePaths` are writable ([L141-L188](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L141-L188)). The timer uses `startAt` (default `daily`). **`persistentTimer` defaults to `false`**, so a run missed while the machine was off isn't made up unless you enable it ([L479-L503](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L479-L503), [L190-L201](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L190-L201)). Each job also gets a `borg-job-<name>` wrapper ([L356-L362](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L356-L362)).
- **Script flow**:
  1. `preHook`.
  2. `borg init` if the repo is missing (`doInit`, default `true`).
  3. `borg create` into `<archive>.failed`, renamed to the final name on success (`appendFailedSuffix`).
  4. `postCreate`.
  5. `prune` + `compact` (only if `prune.keep` is set), then `postPrune`.

  `postHook` always runs on exit, and `$exitStatus` holds the result ([L50-L129](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L50-L129), [L730-L776](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L730-L776)). `failOnWarnings` defaults to `true`, so Borg's exit code 1 (e.g. a file changed during backup) fails the unit ([L655-L662](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L655-L662)).
- **What to back up**: `paths` **or** `dumpCommand`, where the stdout of a program is stored as one archive. The two are mutually exclusive by assertion. `createCommand = "import-tar"` can ingest a tar stream ([L404-L442](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L404-L442), [L308-L318](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L308-L318)). As with restic, streaming a DB dump needs its own job.
- **Encryption**: `encryption.mode` (`repokey`, `repokey-blake2`, `keyfile`, … `none`) plus `passCommand` or `passphrase`. `passphrase` lands in the world-readable Nix store, so the module doc steers you to `passCommand` ([L543-L581](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L543-L581)).
- **Pruning**: `prune.keep = { daily = 7; weekly = 4; monthly = 6; within = "1d"; }` (values are ints or `"<n>[Hdwmy]"`), and `prune.prefix` limits pruning to the job's archives ([L686-L716](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L686-L716)). The module has **no `borg check` option**; you would add it in `postPrune`/`postHook` or as a separate unit.
- **Server side on NixOS**: `services.borgbackup.repos.<name>` creates a system user. Its SSH keys are forced to `borg serve --restrict-to-repository` (or `--restrict-to-path`), with optional `--append-only` (`authorizedKeysAppendOnly`) and `--storage-quota` ([L263-L301](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L263-L301), [L839-L930](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L839-L930)). This makes "another NixOS box on the LAN" a one-option server.
- **Append-only caveat**: append-only applies only to access through `borg serve`. `rm` on the repo still works, and pruning needs a non-append-only client ([Borg append-only notes](https://borgbackup.readthedocs.io/en/1.4-maint/usage/notes.html#append-only-mode-forbid-compaction)).

### `services.borgmatic`

Module: [`N/borgmatic.nix`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix)

- **Config**: `settings` (one config) or `configurations.<name>` (several) is freeform YAML, written to `/etc/borgmatic/config.yaml` or `/etc/borgmatic.d/<name>.yaml`. With `enableConfigCheck` (default `true`) it is validated at build time ([L141-L161](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix#L139-L161), [L163-L207](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix#L163-L207)).
- **Units**: uses upstream's packaged `borgmatic.service`/`borgmatic.timer` through `systemd.packages`. Every configuration runs in one unit and schedule, unlike the per-job units of the two modules above ([L197-L205](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix#L197-L205)).
- **Database hooks**: `postgresql_databases`, `mariadb_databases`, `mysql_databases` and `sqlite_databases`. The module fills in the Nix store paths for `pg_dump`/`pg_dumpall`/`mariadb-dump` etc. from `services.postgresql.package`/`services.mysql.package` ([L12-L65](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix#L12-L65)). borgmatic streams dumps into Borg through a named pipe without using temporary disk space, except for PostgreSQL's directory format ([borgmatic DB how-to](https://torsion.org/borgmatic/how-to/backup-your-databases/)). It can also restore them (`borgmatic restore`).
- **Monitoring**: built-in hooks for Healthchecks, ntfy, Uptime Kuma, Apprise, Pushover, Cronitor, Loki, Zabbix and others ([borgmatic monitoring](https://torsion.org/borgmatic/how-to/monitor-your-backups/), [monitoring reference](https://torsion.org/borgmatic/reference/configuration/monitoring/)).
- **Secrets**: borgmatic has credential support for files and systemd credentials ([borgmatic credentials](https://torsion.org/borgmatic/reference/configuration/credentials/)). A sops-nix secret path can be wired in as `encryption_passcommand: cat /run/secrets/...`.
- **Targets**: same as Borg (local/SSH only).

### Database dumps

**`services.postgresqlBackup`** ([`N/postgresql-backup.nix`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix))

- Runs as `postgres`. It runs `pg_dumpall` when `databases = []` (`backupAll`), otherwise one `postgresqlBackup-<db>` unit per DB running `pg_dump -C <db>` ([L94-L132](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L94-L132), [L189-L207](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L189-L207)).
- Writes `<location>/<db>.sql.gz` (gzip/zstd use `--rsyncable`, which helps dedup), keeps one `.prev` copy, and writes atomically through `.in-progress` with `umask 0077` ([L10-L59](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L10-L59)). Default location `/var/backup/postgresql`, mode `0700 postgres` ([L115-L121](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L115-L121), [L185](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L185)).
- Schedule: `startAt` (default `*-*-* 01:15:00`). This goes through the generic `startAt` → timer with only `OnCalendar` and no `Persistent` ([L84-L92](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix#L84-L92), [systemd.nix L828-L832](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/system/boot/systemd.nix#L828-L832)).

**`services.mysqlBackup`** ([`N/mysql-backup.nix`](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix))

- Creates a `mysqlbackup` system user and DB account (`SELECT, SHOW VIEW, TRIGGER, LOCK TABLES` on the listed DBs, via `services.mysql.ensureUsers`) ([L185-L212](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L185-L212)).
- Uses `mariadb-dump` on MariaDB ≥ 11 ([L10-L21](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L10-L21)).
- **`databases` must be listed explicitly** (default `[]`, so nothing is dumped). `singleTransaction` (for InnoDB consistency) defaults to `false` and can be set per DB ([L130-L157](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L130-L157)).
- Writes `/var/backup/mysql/<db>.gz` (gzip/xz/zstd) through `.tmp` + `mv`. The unit fails if any DB failed ([L60-L82](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L60-L82)).
- Timer `calendar` (default `01:15:00`), not persistent ([L214-L222](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix#L214-L222)).

**Ways to combine these with a backup tool:**

1. **Dump-then-files.** Enable the dump modules, schedule them before the backup, and include `/var/backup` in restic `paths` or Borg `paths`. Simple, and it leaves a local last-good dump for quick restores. The cost is disk space plus a timing dependency. Neither the dump modules nor the backup modules order themselves after each other, so you either schedule them apart or add `after`/`wants`/`requires` on the backup unit yourself.
2. **Dump inside the backup job's hook.** Call `systemctl start postgresqlBackup.service` (a oneshot, so it blocks until finished) from restic's `backupPrepareCommand` or Borg's `preHook`. Borg's `ProtectSystem=strict` only matters if the hook writes files itself, in which case add the path to `readWritePaths` ([L631-L643](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L631-L643)).
3. **Stream without staging.** Use restic `command = [ "${pkgs.sudo}/bin/sudo" "-u" "postgres" "pg_dumpall" ]` (example taken from the option itself, [L150-L163](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L150-L163)), Borg `dumpCommand`, or borgmatic DB hooks. The restic/Borg variants need a separate job (and repo snapshot stream) per dump command. Restic notes that `--stdin-from-command` aborts the snapshot if the command exits non-zero, while piping into `--stdin` hides dump failures ([restic backup docs](https://restic.readthedocs.io/en/stable/040_backup.html#reading-data-from-a-command)).

### Secrets with sops-nix

The repo already has sops-nix as a flake input, and the map's standing decision is to use it for secrets. sops-nix decrypts each secret to `/run/secrets/<name>` (in tmpfs), owned by `root:root` with mode `0400` unless `owner`/`mode` say otherwise. `sops.templates."<f>".content` with `config.sops.placeholder.<x>` renders composite files such as env files, available at `config.sops.templates."<f>".path` ([sops-nix README: permissions](https://github.com/Mic92/sops-nix#set-secret-permissionowner-and-allow-services-to-access-it), [templates](https://github.com/Mic92/sops-nix#templates)). `restartUnits` is available, but it matters little for timer-driven oneshots ([restart on change](https://github.com/Mic92/sops-nix#restartingreloading-systemd-units-on-secret-change)).

| Secret | restic | Borg / borgmatic |
| --- | --- | --- |
| Repo passphrase | `passwordFile = config.sops.secrets.restic-pw.path;` → `RESTIC_PASSWORD_FILE` ([L22-L29](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L22-L29), [L433-L437](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L433-L437)) | `encryption.passCommand = "cat ${config.sops.secrets.borg-pw.path}";` → `BORG_PASSCOMMAND` ([L131-L139](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L131-L139)) |
| S3/B2 keys | `environmentFile = config.sops.templates."restic-b2.env".path;` holding `AWS_ACCESS_KEY_ID=…`/`AWS_SECRET_ACCESS_KEY=…` ([L31-L38](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L31-L38), [restic S3](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3)) | n/a (no S3 in Borg 1.x) |
| SSH key (SFTP / Storage Box / LAN) | `extraOptions = [ "sftp.args='-i ${…path}'" ]` or an `/etc/ssh/ssh_config` / root `~/.ssh/config` entry ([restic SFTP](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#sftp)) | `environment.BORG_RSH = "ssh -i ${…path} -p 23";` ([module example L384-L395](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L384-L395)) |
| Repo URL (if private) | `repositoryFile` ([L125-L131](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix#L125-L131)) | none; `repo` is a plain string in the store |

Losing the repo passphrase (and, for Borg `keyfile` modes, the key file) makes the backup unrecoverable ([restic docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#local)). If the only copy sits inside sops-encrypted files that can be decrypted only with the Optiplex's SSH host key (wiped at Cutover) plus Yannik's key, Yannik's key is the single point of recovery.

### Monitoring and failure alerts

- Neither `restic.nix` nor `borgbackup.nix` has a notification option; a search of both modules for `onFailure`/`notify` turns up nothing. Every job is a normal systemd unit, so the generic NixOS options apply: `systemd.services."restic-backups-<n>".onFailure = [ "notify-failure@%n.service" ];` (and `onSuccess`). These map to `OnFailure=`/`OnSuccess=` ([systemd-unit-options.nix L270-L287](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/lib/systemd-unit-options.nix#L270-L287), [systemd-lib mapping](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/lib/systemd-lib.nix), [systemd.unit(5) OnFailure=](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#OnFailure=)). The template unit can `curl` ntfy or a Healthchecks `/fail` URL. Borg's `postHook` with `$exitStatus` is another place to ping.
- Failure alerts don't catch a backup that silently stops running, for example when the timer is gone or the box is down. A dead-man's-switch service such as healthchecks.io covers that: it alerts when no success ping arrives within the expected period ([healthchecks.io docs](https://healthchecks.io/docs/)). With systemd you'd ping on success via `onSuccess`, `backupCleanupCommand` or `postHook`.
- borgmatic has this built in (start/finish/fail pings to Healthchecks, ntfy, Uptime Kuma, …) ([borgmatic monitoring](https://torsion.org/borgmatic/how-to/monitor-your-backups/)).
- `services.restic.server.prometheus` exposes rest-server metrics if a restic REST server is self-hosted ([restic-rest-server.nix L54-L58](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic-rest-server.nix#L54-L58)).

### Off-site targets

**Another LAN host** (e.g. a NixOS PC). Not off-site, since it shares the location with the Optiplex, but it gives fast restores.
- Borg: `services.borgbackup.repos` on that host gives a key-restricted, optionally append-only, quota-limited repo ([L839-L930](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L839-L930)).
- restic: plain SFTP, or `services.restic.server` (rest-server) with `appendOnly`, `privateRepos` and htpasswd ([restic-rest-server.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic-rest-server.nix#L14-L65)).
- The job only succeeds when the LAN host is on.

**Hetzner Storage Box**
- Borg: SSH on port 23 runs `borg serve`. Versions `borg-1.1`, `borg-1.2` (default) and `borg-1.4` are selectable with `--remote-path`. Hetzner recommends pinning it; with nixpkgs' Borg 1.4.5 that would be `extraArgs = [ "--remote-path=borg-1.4" ]`. Append-only is supported ([Hetzner: BorgBackup](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/#borgbackup)). nixpkgs' `extraArgs` is passed to every borg call ([L778-L790](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix#L778-L790)).
- restic: "natively supported with the SFTP backend", or through rclone's restic server over SSH ([Hetzner: Restic](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/#restic), [rclone serve restic](https://rclone.org/commands/rclone_serve_restic/)).
- Access: port 23 needs "SSH support" enabled. Access from outside Hetzner's network (i.e. from home) also needs "External Reachability". Port 23 takes keys in OpenSSH format ([Hetzner: SSH access](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/#ssh-access-on-port-23), [key formats](https://docs.hetzner.com/storage/storage-box/general/#supported-ssh-key-algorithms)).
- Limits: unlimited traffic, max 10 simultaneous connections, sub-accounts confined to a sub-directory (one per host/purpose is possible), and provider-side snapshots that count against quota ([Hetzner: Storage Box overview](https://docs.hetzner.com/storage/storage-box/general/), [snapshots](https://docs.hetzner.com/storage/storage-box/snapshots/)).
- Pricing/sizes: [hetzner.com/storage/storage-box](https://www.hetzner.com/storage/storage-box/).

**Backblaze B2 / S3**
- restic only (among the stable tools). Upstream **recommends B2's S3-compatible API over restic's native `b2:` backend** because of error-handling issues in the B2 library. It also recommends the "Keep only the last version" lifecycle rule, since S3-style deletes only hide old versions ([restic: Backblaze B2](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#backblaze-b2), [B2 S3-compatible API](https://www.backblaze.com/docs/cloud-storage-s3-compatible-api), [B2 S3 app keys](https://www.backblaze.com/docs/cloud-storage-s3-compatible-app-keys), [B2 lifecycle rules](https://www.backblaze.com/docs/cloud-storage-lifecycle-rules)).
- Object Lock (governance/compliance, 1–3000 days) can make objects immutable. Once enabled on a bucket it can't be disabled ([B2 Object Lock](https://www.backblaze.com/docs/cloud-storage-object-lock)). Restic's `forget --prune` deletes pack files, so combining it with Object Lock needs care. Nothing in the restic docs fetched here describes an Object Lock workflow (see Open questions).
- Pricing: [backblaze.com/cloud-storage/pricing](https://www.backblaze.com/cloud-storage/pricing).
- Borg can reach B2/S3 only by syncing a local repo with rclone, which the Borg FAQ advises against ("If something goes wrong in repo, you will have the same issue in copy-of-repo") ([Borg FAQ](https://borgbackup.readthedocs.io/en/1.4-maint/faq.html#can-i-copy-or-synchronize-my-repo-to-another-location)). Borg 2 adds native `s3://`/`b2://`/`rclone:` but is beta: "DO NOT USE BORG2 FOR YOUR PRODUCTION BACKUPS" ([borg master README](https://github.com/borgbackup/borg/blob/master/README.rst)).

## Comparison table

| | restic (`services.restic.backups`) | Borg (`services.borgbackup.jobs`) | borgmatic (`services.borgmatic`) |
| --- | --- | --- | --- |
| Version in nixpkgs | 0.19.1 | 1.4.5 | 2.1.7 (on Borg 1.4.5) |
| systemd shape | one service + timer per job, `Persistent=true` by default | one service + timer per job, `persistentTimer = false` by default, idle CPU/IO, `ProtectSystem=strict` | one upstream unit + timer for all configs |
| Targets | local, SFTP, REST server, S3 (incl. B2 S3 API), native B2, rclone (anything) | local, SSH (`borg serve`) | same as Borg |
| LAN host server module | `services.restic.server` (append-only, private repos, Prometheus) | `services.borgbackup.repos` (forced `borg serve`, append-only, quota) | (uses `borgbackup.repos`) |
| Hetzner Storage Box | yes (SFTP, or rclone-restic over SSH) | yes (`borg serve` 1.1/1.2/1.4 on port 23) | yes |
| B2/S3 | yes (S3 API recommended) | no (only rclone-sync of a repo; Borg 2 beta) | no |
| DB dumps | `command` (stdin-from-command, one job per stream) or files from dump modules; `backupPrepareCommand` hook | `dumpCommand` (one job per stream) or files; `preHook`/`postHook` | native PostgreSQL/MariaDB/MySQL/SQLite hooks, streamed, restore built in |
| Secrets | file paths (`passwordFile`, `environmentFile`, `repositoryFile`, `rcloneConfigFile`) | `passCommand`, `environment` (`BORG_RSH`) | YAML `encryption_passcommand`, credential hooks |
| Retention | `pruneOpts` → `unlock` + `forget --prune` | `prune.keep` → `prune` + `compact` | `keep_*` + `compact` |
| Integrity check | `checkOpts`/`runCheck` | none (manual `borg check`) | `checks:` config ([consistency checks](https://torsion.org/borgmatic/reference/configuration/consistency-checks/)) |
| Failure alerts | none built in; `onFailure`/`onSuccess` | none built in; `onFailure`/`onSuccess`, `postHook` + `$exitStatus` | built-in Healthchecks/ntfy/Uptime Kuma/… |
| Manual CLI | `restic-<name>` wrapper | `borg-job-<name>` wrapper | `borgmatic` |

## Options / trade-offs (not a decision)

- **A. restic → Hetzner Storage Box (SFTP) and/or B2 (S3).** Covers every target asked about with one tool and fits sops-nix cleanly through file-path options. Dumps come from the NixOS dump modules plus `paths`, or from extra `command` jobs. Alerts need a small `onFailure` template you write yourself. Prune holds an exclusive lock, so long prunes on a large Data disk selection delay backups.
- **B. Borg (`borgbackup.jobs`) → Hetzner Storage Box and/or a NixOS LAN host (`borgbackup.repos`).** Has a well-trodden server side, append-only, `.failed` archive marking, a hardened unit and Hetzner's first-class Borg support. **Excludes B2/S3.** Missed runs aren't made up unless `persistentTimer = true`. No built-in check or alerts.
- **C. borgmatic → same targets as Borg.** Most batteries included: DB hooks with streaming and restore, plus monitoring hooks. You configure it as YAML through Nix rather than typed options, everything runs in one unit/schedule, and it has the same B2/S3 limitation as Borg.
- **D. Mix.** For example Borg/borgmatic to a LAN box or Storage Box, plus restic to B2 for a second, independent off-site copy. This follows the upstream "independent repos" advice, at the cost of two tools to learn and monitor.
- **Cross-cutting choices, whatever the tool:**
  - DB dumps staged on disk (simple, local last-good copy) or streamed (no staging, more jobs).
  - Append-only/immutable target or not.
  - One or two destinations.
  - How much of the 3.6 TB Data disk goes off-site, which drives cost on B2 and plan size on Hetzner.

## Open questions

- Which Data disk paths count as Backup material, as opposed to re-downloadable media? This decides off-site size and therefore provider/plan.
- Is a second LAN machine always on? If not, a LAN target only works opportunistically.
- Does Yannik want append-only/immutable off-site copies? Then pruning has to happen from a trusted machine or on a provider-side schedule.
- How well do restic and B2 Object Lock work together? Not covered by the restic pages read here; needs testing or further reading before relying on it.
- Where does the repo passphrase escrow live outside the Optiplex (password manager, paper)? If it only lives in sops files on the Optiplex, the backup is useless after total loss.
- Which notifier: self-hosted ntfy, healthchecks.io SaaS, or something already on the box?

## Sources

- nixpkgs (commit `1d060086d60cb76a40cf37109f979d88a5bd6396`):
  - [restic.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic.nix)
  - [restic-rest-server.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/restic-rest-server.nix)
  - [borgbackup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.nix)
  - [borgbackup.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgbackup.md)
  - [borgmatic.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/borgmatic.nix)
  - [postgresql-backup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/postgresql-backup.nix)
  - [mysql-backup.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/backup/mysql-backup.nix)
  - [systemd-unit-options.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/lib/systemd-unit-options.nix)
  - [systemd.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/system/boot/systemd.nix)
- restic docs:
  - [Preparing a new repository](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
  - [Backing up](https://restic.readthedocs.io/en/stable/040_backup.html)
  - [Working with repositories](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)
  - [Removing snapshots](https://restic.readthedocs.io/en/stable/060_forget.html)
  - [Scripting / exit codes](https://restic.readthedocs.io/en/stable/075_scripting.html)
  - [cmd_backup.go v0.19.1](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go)
- Borg docs:
  - [Quickstart](https://borgbackup.readthedocs.io/en/1.4-maint/quickstart.html)
  - [Usage notes (append-only)](https://borgbackup.readthedocs.io/en/1.4-maint/usage/notes.html#append-only-mode-forbid-compaction)
  - [FAQ](https://borgbackup.readthedocs.io/en/1.4-maint/faq.html)
  - [Borg 2 README](https://github.com/borgbackup/borg/blob/master/README.rst)
- borgmatic docs:
  - [Backup your databases](https://torsion.org/borgmatic/how-to/backup-your-databases/)
  - [Monitor your backups](https://torsion.org/borgmatic/how-to/monitor-your-backups/)
  - [Credentials](https://torsion.org/borgmatic/reference/configuration/credentials/)
- sops-nix: [README](https://github.com/Mic92/sops-nix/blob/master/README.md)
- Hetzner:
  - [Storage Box overview](https://docs.hetzner.com/storage/storage-box/general/)
  - [Access with SSH/rsync/BorgBackup](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/)
  - [Snapshots](https://docs.hetzner.com/storage/storage-box/snapshots/)
  - [Product page](https://www.hetzner.com/storage/storage-box/)
- Backblaze:
  - [S3-compatible API](https://www.backblaze.com/docs/cloud-storage-s3-compatible-api)
  - [S3 app keys](https://www.backblaze.com/docs/cloud-storage-s3-compatible-app-keys)
  - [Lifecycle rules](https://www.backblaze.com/docs/cloud-storage-lifecycle-rules)
  - [Object Lock](https://www.backblaze.com/docs/cloud-storage-object-lock)
  - [Pricing](https://www.backblaze.com/cloud-storage/pricing)
- Monitoring:
  - [systemd.unit(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#OnFailure=)
  - [healthchecks.io docs](https://healthchecks.io/docs/)
- rclone: [rclone serve restic](https://rclone.org/commands/rclone_serve_restic/)
