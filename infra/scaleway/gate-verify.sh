#!/usr/bin/env bash
# Verifies a restored arch-gate snapshot against the GATE-MANIFEST that arch-gate.sh wrote into it.
# Runs anywhere with restic's output on disk (the VM harness, the PC):
#
#   restic restore <snapshot id> --target /mnt/tbssd/gate-restore
#   infra/scaleway/gate-verify.sh /mnt/tbssd/gate-restore
#
# Checks: the checksums of the SQLite copies and the host keys, `PRAGMA integrity_check` of every SQLite
# copy, the file count of every State tree, and the MANIFEST of the database dumps. The dumps are then
# loaded by `optiplex-db-restore <restored dump directory>` (printed at the end), which is the Cutover's
# own restore step.
set -euo pipefail

root="${1:?usage: gate-verify.sh <restore root>}"
[[ -d $root ]] || { echo "gate-verify: $root is not a directory" >&2; exit 2; }

manifest="$(find "$root" -name GATE-MANIFEST -print -quit)"
[[ -n $manifest ]] || { echo "gate-verify: no GATE-MANIFEST below $root" >&2; exit 1; }
stage="$(dirname "$manifest")"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

echo "manifest: $manifest"
head -1 "$manifest"

# 1. checksums: relative lines are relative to the stage directory, absolute ones to the restore root
while read -r sum path; do
  [[ $sum =~ ^[0-9a-f]{64}$ ]] || continue
  if [[ $path == /* ]]; then file="$root$path"; else file="$stage/$path"; fi
  actual="$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)" || actual=""
  if [[ $actual == "$sum" ]]; then echo "ok   $path"; else bad "checksum of $path"; fi
done <"$manifest"

# 2. every SQLite copy is a sound database (checked on a scratch copy, a WAL header would create files)
for db in "$stage"/sqlite/*.sqlite3; do
  chk="$(mktemp)"
  cp "$db" "$chk"
  result="$(sqlite3 "$chk" 'PRAGMA integrity_check')"
  rm -f "$chk" "$chk-wal" "$chk-shm"
  if [[ $result == ok ]]; then echo "ok   integrity $(basename "$db")"; else bad "integrity_check of $db: $result"; fi
done

# 3. file counts of the State trees
while read -r kw n path; do
  [[ $kw == files ]] || continue
  got="$(find "$root$path" -type f 2>/dev/null | wc -l)"
  # excluded caches are not in the snapshot, so a tree may only have fewer files than the live one
  if ((got > n)); then bad "$path has $got files, the manifest says $n"; elif ((got == 0 && n > 0)); then echo "WARN $path has no file in the snapshot ($n live): fine only if everything in it is a cache"; else echo "ok   $path: $got of $n files (rest excluded)"; fi
done <"$manifest"

# 4. the dumps carry their own MANIFEST
dumps="$(find "$stage/dumps" -name MANIFEST -print -quit 2>/dev/null || true)"
if [[ -n $dumps ]]; then
  d="$(dirname "$dumps")"
  if (cd "$d" && grep -Ev '^(#|$)' MANIFEST | sha256sum --check --quiet --strict -); then echo "ok   dump MANIFEST"; else bad "dump MANIFEST"; fi
  echo "load them with: optiplex-db-restore $d"
else
  echo "note: no dumps in this snapshot (GATE_SKIP_DUMPS run?)"
fi

if ((fail == 0)); then echo "gate-verify: all good"; else echo "gate-verify: FAILED" >&2; exit 1; fi
