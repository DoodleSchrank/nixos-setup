# VM checks of the Backup (plugged into the harness through optiplex.vmTest, see machines/optiplex/vm-test.nix).
# restic runs against a LOCAL repository: the real unit, with only RESTIC_REPOSITORY_FILE replaced by a
# runtime drop-in. The real bucket is never contacted (the test secrets point at s3.test.invalid anyway).
#
#   zz-backup-job      the nightly job: snapshot contents, excludes, dumps, SQLite copies, healthchecks ping,
#                      the check job, the guards
#   zz-backup-restore  the restore rehearsal: back to restoreMode (quiescent), a failing job (a required mount
#                      fails, as a missing Data disk would) posts to ntfy, a second snapshot, the State and both database servers
#                      are wiped, optiplex-backup-restore puts everything back from that snapshot, then
#                      the normal deploy comes up on the restored State
#
# Both run late (name order) and leave the host in the normal configuration.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  bk = cfg.backup;
  job = config.services.restic.backups.optiplex;

  repo = "/var/lib/test-restic-repo";
  passwordFile = config.sops.secrets."restic/repository_password".path;
  restic = "${pkgs.restic}/bin/restic -r ${repo} --password-file ${passwordFile}";
  sqlite = "${pkgs.sqlite}/bin/sqlite3";
  hcManage = "healthchecks-manage";

  wrapPy = name: body: "def ${name}():\n" + lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" body) + "\n${name}()\n";

  # Directories under excluded paths that get a canary file, so that "absent from the snapshot" means something.
  canaryDirs = [
    "/state/gitea/data/packages"
    "/state/seafile/seahub-data/thumbnail"
    "/state/synapse/media_store/url_cache"
    "/state/synapse/media_store/local_thumbnails"
    "/state/vaultwarden/icon_cache"
    "/state/vaultwarden/tmp"
    "/state/homeassistant/.cache"
  ];
  canaryFiles = ["/state/homeassistant/home-assistant.log.1"]; # matches the glob in the excludes

  # The excludes minus globs, as Python data
  excludePatterns = builtins.toJSON job.exclude;
  nightlyPaths = builtins.toJSON job.paths;
  sqliteSources = builtins.toJSON bk.sqlite;

  # Row counts of every table of a PostgreSQL database (same query as optiplex-db-restore's counts check).
  pgCounts = pkgs.writeText "bk-pg-counts.sql" ''
    select n.nspname, c.relname,
      (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, ''')))[1]::text::bigint
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'r' and n.nspname <> 'information_schema' and n.nspname !~ '^pg_'
    order by n.nspname collate "C", c.relname collate "C";
  '';
in {
  optiplex.vmTest.fixtures."zz-backup".script = ''
    install -d -m 0755 /mnt/tbssd/archive
    echo "zsh history canary" > /mnt/tbssd/archive/.zsh_history
    # the initrd host key is placed by nixos-anywhere on the real host, no VM has it
    install -D -m 0600 /dev/null /etc/secrets/initrd/ssh_host_ed25519_key
    echo "test-only initrd host key" > /etc/secrets/initrd/ssh_host_ed25519_key
    install -d -m 0755 /state/backup-canary
    echo keep > /state/backup-canary/keep
    echo owned > /state/backup-canary/owned
    chmod 640 /state/backup-canary/owned
    ${lib.concatMapStrings (d: ''
        install -d -m 0755 ${d}
        echo canary > ${d}/zz-canary
      '')
      canaryDirs}
    ${lib.concatMapStrings (f: "echo canary > ${f}\n") canaryFiles}
  '';

  optiplex.vmTest.checks."zz-backup-job".script = wrapPy "bk_job" ''
    import json
    from fnmatch import fnmatch

    # --- the guards, as built ---
    props = optiplex.succeed("systemctl show -p RequiresMountsFor restic-backups-optiplex.service")
    assert "/state" in props and "/mnt/tbssd" in props, props
    optiplex.succeed("systemctl cat restic-backups-optiplex.service | grep -q 's3.storage-class=ONEZONE_IA'")
    optiplex.succeed("systemctl cat restic-backups-optiplex.service | grep -q 'OnSuccess=optiplex-hc-ping@backup-nightly.service'")
    optiplex.succeed("systemctl cat restic-backups-optiplex-check.service | grep -q 'read-data-subset=10%'")
    # the VM never runs the timers
    optiplex.fail("systemctl is-enabled restic-backups-optiplex.timer")

    # --- a local repository instead of the bucket: the real units, only the repository replaced ---
    optiplex.succeed("echo ${repo} > /run/test-restic-repo")
    for unit in ("restic-backups-optiplex", "restic-backups-optiplex-check"):
        optiplex.succeed(f"install -d /run/systemd/system/{unit}.service.d")
        optiplex.succeed(f"printf '[Service]\\nEnvironment=RESTIC_REPOSITORY_FILE=/run/test-restic-repo\\n' > /run/systemd/system/{unit}.service.d/10-test-repo.conf")
    optiplex.succeed("systemctl daemon-reload")
    optiplex.succeed("${restic} init")

    # --- healthchecks: an account (the human step), the ping key and the checks (healthchecks-ensure) ---
    optiplex.wait_for_unit("healthchecks.service")
    optiplex.wait_until_succeeds("curl -fsS -o /dev/null http://127.0.0.1:25582/")
    optiplex.execute("${hcManage} createsuperuser --email test@example.org --password test-password-1234 < /dev/null")  # the healthchecks check may have made it
    optiplex.succeed("systemctl start healthchecks-ensure.service")
    checks = optiplex.succeed("${hcManage} shell -v 0 -c \"from hc.api.models import Check; print(sorted((c.slug, int(c.timeout.total_seconds()), int(c.grace.total_seconds())) for c in Check.objects.exclude(slug='my-first-check')))\"").strip()
    assert checks == "[('backup-check', 604800, 86400), ('backup-nightly', 86400, 10800), ('lan-homeassistant', 300, 600), ('lan-paperless', 300, 600), ('units-ok', 300, 600)]", checks

    # --- the SQLite sources: wait for the services; a service this run does not have gets a plain database ---
    for name, path in json.loads('${sqliteSources}').items():
        if name != "healthchecks":
            unit = {"homeassistant": "home-assistant"}.get(name, name) + ".service"
            if optiplex.execute(f"systemctl is-active {unit}")[0] == 0:
                optiplex.wait_until_succeeds(f"test -f {path}", timeout=180)
        if optiplex.execute(f"test -f {path}")[0] != 0:
            d = path.rsplit("/", 1)[0]
            optiplex.succeed(f"install -d {d}; ${sqlite} {path} 'create table bk_probe(x); insert into bk_probe values (1);'")

    # --- run the job ---
    optiplex.succeed("systemctl start restic-backups-optiplex.service")
    snaps = json.loads(optiplex.succeed("${restic} snapshots --json"))
    assert len(snaps) == 1, snaps
    snap = snaps[0]
    assert snap["hostname"] == "optiplex" and snap["tags"] == ["nightly"], snap
    for p in json.loads('${nightlyPaths}'):
        assert p in snap["paths"], (p, snap["paths"])
    listing = optiplex.succeed("${restic} ls latest").splitlines()

    def in_snapshot(p):
        return p in listing

    # --- contents: dumps, SQLite copies, host keys, archive, a plain State canary ---
    for db in ${builtins.toJSON cfg.databases.postgresql}:
        assert in_snapshot(f"/var/backup/postgresql/{db}.sql"), db
        head = optiplex.succeed(f"head -c 5 /var/backup/postgresql/{db}.sql")
        assert head == "PGDMP", (db, head)  # custom format, not compressed
        optiplex.succeed(f"${config.services.postgresql.finalPackage}/bin/pg_restore --list /var/backup/postgresql/{db}.sql >/dev/null")
    for db in ${builtins.toJSON cfg.databases.mariadb}:
        assert in_snapshot(f"/var/backup/mysql/{db}.gz"), db
        optiplex.succeed(f"${pkgs.gzip}/bin/zcat /var/backup/mysql/{db}.gz | grep -q 'Dump completed'")
    for name in json.loads('${sqliteSources}'):
        copy = f"/var/backup/sqlite/{name}.sqlite3"
        assert in_snapshot(copy), copy
        assert optiplex.succeed(f"cp {copy} /tmp/bk-copy.db && ${sqlite} /tmp/bk-copy.db 'PRAGMA integrity_check'; rm -f /tmp/bk-copy.db*").strip() == "ok", copy
    for p in ("/etc/ssh/ssh_host_ed25519_key", "/etc/ssh/ssh_host_ed25519_key.pub", "/etc/ssh/ssh_host_rsa_key",
              "/etc/ssh/ssh_host_rsa_key.pub", "/etc/secrets/initrd/ssh_host_ed25519_key",
              "/mnt/tbssd/archive/.zsh_history", "/state/backup-canary/keep"):
        assert in_snapshot(p), p

    # --- excludes: the canaries exist on disk and are not in the snapshot; nothing matches an exclude ---
    for d in ${builtins.toJSON canaryDirs}:
        optiplex.succeed(f"test -e {d}/zz-canary")
        assert not in_snapshot(f"{d}/zz-canary"), d
    for f in ${builtins.toJSON canaryFiles}:
        optiplex.succeed(f"test -e {f}")
        assert not in_snapshot(f), f
    for line in listing:
        for pat in json.loads('${excludePatterns}'):
            assert not (line == pat or line.startswith(pat + "/") or fnmatch(line, pat)), (line, pat)
    # the live databases are gone from the snapshot, their copies are in
    optiplex.succeed("test -d /state/postgresql && test -d /state/mariadb")
    assert not in_snapshot("/state/postgresql") and not in_snapshot("/state/mariadb")
    for path in json.loads('${sqliteSources}').values():
        assert not in_snapshot(path), path

    # --- success pings healthchecks (onSuccess), the previous dump of the next run stays out ---
    optiplex.wait_until_succeeds("${hcManage} shell -v 0 -c \"from hc.api.models import Check; c = Check.objects.get(slug='backup-nightly'); print(c.n_pings, c.status)\" | grep -qx '1 up'", timeout=60)
    optiplex.succeed("systemctl start restic-backups-optiplex.service")
    optiplex.succeed("ls /var/backup/postgresql/*.prev.sql >/dev/null")
    assert len(json.loads(optiplex.succeed("${restic} snapshots --json"))) == 2
    assert not [l for l in optiplex.succeed("${restic} ls latest").splitlines() if l.endswith(".prev.sql")]

    # --- the weekly check job: a check-only unit that pings backup-check ---
    optiplex.succeed("systemctl start restic-backups-optiplex-check.service")
    optiplex.wait_until_succeeds("${hcManage} shell -v 0 -c \"from hc.api.models import Check; c = Check.objects.get(slug='backup-check'); print(c.n_pings, c.status)\" | grep -qx '1 up'", timeout=60)
  '';

  optiplex.vmTest.checks."zz-backup-restore".script = wrapPy "bk_restore" ''
    import json, re

    def pg_counts(db):
        return optiplex.succeed(f"runuser -u postgres -- psql -X -d {db} -At -F '\\t' -f ${pgCounts} | md5sum").split()[0]

    def maria_dump(db):
        return optiplex.succeed(f"mariadb-dump --protocol=socket -uroot --single-transaction {db} | grep -v '^-- Dump completed' | md5sum").split()[0]

    def sqlite_dump(path):
        # on a copy in /tmp: a root-run sqlite3 on the live file could leave root-owned -wal/-shm files behind
        return optiplex.succeed(f"cp {path} /tmp/bk-dump.db && ${sqlite} /tmp/bk-dump.db .dump | md5sum; rm -f /tmp/bk-dump.db*").split()[0]

    # --- 1. back to restoreMode: every Kept service stops, the databases stay up ---
    rc, out = optiplex.execute("/run/booted-system/bin/switch-to-configuration test 2>&1")
    assert rc in (0, 4), out
    optiplex.succeed("test \"$(cat /etc/optiplex-restore-mode)\" = 1")
    optiplex.succeed("systemctl is-active postgresql.service mysql.service")
    optiplex.fail("systemctl is-active gitea.service vaultwarden.service healthchecks.service")
    optiplex.succeed("systemctl reset-failed || true")

    # --- 2. a mount the job requires fails (a missing Data disk): the job fails, notify-failure@ posts to ntfy ---
    # A real unmount cannot be kept in a VM (systemd mounts /state again for the job, and the harness stacks a
    # second /state), so the job gets one more required mount that cannot be mounted.
    seen = int(optiplex.succeed("grep -c 'restic-backups-optiplex.service failed on optiplex' /tmp/ntfy.log || true").strip())
    optiplex.succeed("printf '[Mount]\\nWhat=none\\nWhere=/mnt/missingdisk\\nType=nosuchfs\\n' > /run/systemd/system/mnt-missingdisk.mount")
    optiplex.succeed("install -d /run/systemd/system/restic-backups-optiplex.service.d")
    optiplex.succeed("printf '[Unit]\\nRequiresMountsFor=/mnt/missingdisk/x\\n' > /run/systemd/system/restic-backups-optiplex.service.d/20-missing-mount.conf")
    optiplex.succeed("systemctl daemon-reload")
    optiplex.fail("systemctl start restic-backups-optiplex.service")
    optiplex.wait_until_succeeds(f"test \"$(grep -c 'restic-backups-optiplex.service failed on optiplex' /tmp/ntfy.log)\" -gt {seen}", timeout=60)
    optiplex.succeed("rm /run/systemd/system/restic-backups-optiplex.service.d/20-missing-mount.conf /run/systemd/system/mnt-missing*.mount; systemctl daemon-reload; systemctl reset-failed || true")

    # --- 3. the snapshot to restore: a quiescent run in restoreMode (the units exist, only the timers do not) ---
    optiplex.succeed("chown 1234:4321 /state/backup-canary/owned")
    optiplex.succeed("systemctl start restic-backups-optiplex.service")
    optiplex.succeed("systemctl reset-failed || true")  # the ping fails: healthchecks is off in restoreMode
    counts = {db: pg_counts(db) for db in ${builtins.toJSON cfg.databases.postgresql}}
    dumps = {db: maria_dump(db) for db in ${builtins.toJSON cfg.databases.mariadb}}
    # what the snapshot holds: the copies taken by this very run
    sqlites = {n: sqlite_dump(f"/var/backup/sqlite/{n}.sqlite3") for n in json.loads('${sqliteSources}')}
    owners = {p: optiplex.succeed(f"stat -c %u:%g {p.rsplit('/', 1)[0]}").strip() for p in json.loads('${sqliteSources}').values()}

    # --- 4. disaster: State, dumps and both database servers are gone ---
    optiplex.succeed("systemctl stop postgresql.service mysql.service postgresql-synapse-db.service postgresql-setup.service postgresql-state-dir.service mariadb-seafile-setup.service mariadb-state-dir.service")
    optiplex.succeed("shopt -s dotglob; rm -rf /state/* /var/backup/* /mnt/tbssd/archive")
    optiplex.succeed("test -z \"$(ls -A /state)\"")
    optiplex.succeed("systemctl start multi-user.target")
    optiplex.wait_for_unit("postgresql.target")
    optiplex.wait_for_unit("mariadb-seafile-setup.service")
    optiplex.succeed("systemctl reset-failed || true")

    # --- 5. restore from the local repository (the wrapper restic-optiplex would use the bucket) ---
    optiplex.succeed("printf '#!/bin/sh\\nexec ${restic} \"$@\"\\n' > /run/restic-local; chmod +x /run/restic-local")
    out = optiplex.succeed("OPTIPLEX_RESTIC=/run/restic-local optiplex-backup-restore --snapshot latest --hostkeys 2>&1")
    print(out)
    assert "optiplex-db-restore" in out and "SQLite: " in out, out

    # --- 6. everything is back ---
    assert optiplex.succeed("stat -c %u:%g:%a /state/backup-canary/owned").strip() == "1234:4321:640", "ids and mode are restored as they were"
    optiplex.succeed("test \"$(cat /mnt/tbssd/archive/.zsh_history)\" = 'zsh history canary'")
    for db, c in counts.items():
        assert pg_counts(db) == c, db
    for db, d in dumps.items():
        assert maria_dump(db) == d, db
    for n, p in json.loads('${sqliteSources}').items():
        assert sqlite_dump(p) == sqlites[n], n
        assert optiplex.succeed(f"stat -c %u:%g {p}").strip() == owners[p], p
    # nothing in the snapshot that must not be there came back
    for d in ${builtins.toJSON canaryDirs}:
        optiplex.fail(f"test -e {d}/zz-canary")
    # a dry run of the nightly job sees no new and no changed file
    dry = optiplex.succeed("${pkgs.restic}/bin/restic -r ${repo} --password-file ${passwordFile} backup --dry-run --host optiplex --ignore-ctime --ignore-inode --exclude-file=${pkgs.writeText "exclude-patterns" (lib.concatStringsSep "\n" job.exclude)} ${lib.concatStringsSep " " (map lib.escapeShellArg job.paths)} 2>&1")
    print(dry)
    m = re.search(r"Files:\s+(\d+) new,\s+(\d+) changed", dry)
    assert m and m.groups() == ("0", "0"), dry

    # --- 7. the normal deploy comes up on the restored State ---
    rc, out = optiplex.execute("/run/current-system/specialisation/normal/bin/switch-to-configuration test 2>&1")
    assert rc in (0, 4), out
    optiplex.wait_for_unit("healthchecks.service")
    optiplex.wait_until_succeeds("curl -fsS -o /dev/null http://127.0.0.1:25582/", timeout=120)
    # every Kept service starts again: leave the host settled for the checks that follow (ssh, firewall)
    optiplex.wait_until_succeeds("test \"$(systemctl list-jobs --no-legend | wc -l)\" = 0", timeout=900)
    # the account, the project, the ping key and the pings of the first run survived (restored SQLite copy)
    st = optiplex.succeed("${hcManage} shell -v 0 -c \"from hc.accounts.models import Project; from hc.api.models import Check; print(Project.objects.count(), Check.objects.get(slug='backup-nightly').n_pings)\"").split()
    assert st[0] == "1" and int(st[1]) >= 1, st
    optiplex.succeed("systemctl is-active postgresql.service mysql.service")
  '';
}
