#!/usr/bin/env python3
"""seafile-prepare-state: make a carried Seafile 12 conf/ directory fit the Seafile 13 image.

Run by hand, as root, on the Optiplex after the copy of /mnt/tbssd/filesync/seafile into
/state/seafile and the restore of the three databases, before the first normal deploy.
Idempotent: a second run changes nothing.

What it does (upstream: manual.seafile.com/13.0/upgrade/upgrade_docker/):
  seafile.conf       drop [database] and [memcached]            (now: SEAFILE_MYSQL_DB_*, CACHE_PROVIDER)
  seafevents.conf    drop [DATABASE]                            (seafevents reads the environment now,
                                                                  the section only keeps a stale password)
  seahub_settings.py drop DATABASES and CACHES                  (same reason)
                     drop the SeaDoc and notification-server settings (neither is run)
                     replace the literal SECRET_KEY by a read of the mounted sops file
                     keep SERVICE_URL, FILE_SERVER_ROOT and everything else
  conf/__pycache__   delete (the compiled seahub_settings still holds the old SECRET_KEY and DB password)
  seahub-data/       make sure avatars/ and custom/ exist (thumbnail/ is a cache that is not carried)
  .optiplex-prepared marker that podman-seafile.service insists on
No secret value is copied anywhere, and no backup copy of the old files is made in /state: the
Arch-side original in /mnt/tbssd/filesync is the backup.
"""
import argparse
import ast
import os
import re
import shutil
import sys

SECRET_FILE = "/secrets/seahub_secret_key"  # path inside the container (see seafile.nix)
SECRET_MARK = "# SECRET_KEY: set by seafile-prepare-state, read from the sops secret"
SECRET_BLOCK = (
    SECRET_MARK + "\n"
    f"with open({SECRET_FILE!r}) as _secret_file:\n"
    "    SECRET_KEY = _secret_file.read().strip()\n"
)

DROP_NAMES = {
    "DATABASES",
    "CACHES",
    "SECRET_KEY",
    "ENABLE_SEADOC",
    "ENABLE_NOTIFICATION_SERVER",
    "NOTIFICATION_SERVER_URL",
    "INNER_NOTIFICATION_SERVER_URL",
}


def drop_name(name):
    return name in DROP_NAMES or name.startswith("SEADOC")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    """Atomic replace, keeping the mode of the old file."""
    tmp = path + ".prepare-tmp"
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode), "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def drop_sections(text, names):
    """Remove whole [section]s (case-insensitive) from an INI-style file."""
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        m = re.match(r"\s*\[([^\]]+)\]", line)
        if m:
            skipping = m.group(1).strip().lower() in names
        if not skipping:
            out.append(line)
    return "".join(out)


def prepare_seahub_settings(text):
    tree = ast.parse(text)
    drop = set()  # 0-based line numbers
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if drop_name(node.targets[0].id):
                drop.update(range(node.lineno - 1, node.end_lineno))
    lines = text.splitlines(keepends=True)
    kept = [line for i, line in enumerate(lines) if i not in drop]
    # Only the line of our own marker survives a second run (the `with` block is not an Assign).
    result = "".join(kept)
    if SECRET_MARK not in result:
        if result and not result.endswith("\n"):
            result += "\n"
        result += "\n" + SECRET_BLOCK
    ast.parse(result)  # never write a file that does not parse
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state-dir", default="/state/seafile")
    args = ap.parse_args()
    state = args.state_dir
    conf = os.path.join(state, "conf")

    if not os.path.isdir(os.path.join(state, "seafile-data")) or not os.path.isdir(conf):
        sys.exit(f"{state} has no seafile-data/ and conf/: copy /mnt/tbssd/filesync/seafile there first (see the Answer of ticket 34)")
    for name in ("seahub_settings.py", "seafile.conf"):
        if not os.path.isfile(os.path.join(conf, name)):
            sys.exit(f"{conf}/{name} is missing")

    changed = []

    def update(name, fn):
        path = os.path.join(conf, name)
        if not os.path.isfile(path):
            return
        old = read(path)
        new = fn(old)
        if new != old:
            write(path, new)
            changed.append(name)

    update("seafile.conf", lambda t: drop_sections(t, {"database", "memcached"}))
    update("seafevents.conf", lambda t: drop_sections(t, {"database"}))
    update("seahub_settings.py", prepare_seahub_settings)

    cache = os.path.join(conf, "__pycache__")
    if os.path.isdir(cache):
        shutil.rmtree(cache)
        changed.append("__pycache__ removed")

    for d in ("avatars", "custom"):
        os.makedirs(os.path.join(state, "seahub-data", d), exist_ok=True)

    # Leftovers that this script does not touch but that the operator should look at.
    left = []
    sf = read(os.path.join(conf, "seafile.conf"))
    if re.search(r"^\s*\[notification\]", sf, re.M | re.I):
        left.append("seafile.conf still has [notification] (the notification server is not run)")
    for name in sorted(os.listdir(conf)):
        p = os.path.join(conf, name)
        if os.path.isfile(p) and name != "seahub_settings.py" and re.search(r"^\s*(password|passwd)\s*=", read(p), re.M | re.I):
            left.append(f"conf/{name} still contains a password line")
    if os.path.exists(os.path.join(conf, ".env")):
        left.append("conf/.env exists (the container gets its environment from the unit, not from this file)")

    open(os.path.join(state, ".optiplex-prepared"), "a").close()
    print("changed: " + (", ".join(changed) if changed else "nothing (already prepared)"))
    for item in left:
        print("NOTE: " + item)


if __name__ == "__main__":
    main()
