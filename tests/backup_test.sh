#!/usr/bin/env bash
# The backup chain and its alerts, end to end, on any machine with restic: `bin/sdb init`, `backup`,
# `copy`, `health` and `status` against two real restic repositories (the first, and the copy on "the
# PC"), with stand-ins for Docker (a made-up dump, a health state), for Uptime Kuma (curl, which writes
# down every push) and, once, for a copy that breaks. What it proves: a backup never waits on the PC; the
# PC being off is not a failure and sends no alert; when it is back it gets every hour it missed, and
# Mahoraga's archive; a copy that breaks while the PC answers is an alert; a failed dump, a full disk
# and an unhealthy MongoDB are alerts. The real container, mongodump and the drill are proved on the
# server (ROADMAP.md, step 10).
#
#   tests/backup_test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }

# A copy of the tool, so the test never reads or writes this checkout's own certificates/.
mkdir -p "$WORK/root/bin" "$WORK/root/certificates" "$WORK/path"
cp "$HERE/bin/sdb" "$HERE/compose.yml" "$WORK/root/"
mv "$WORK/root/sdb" "$WORK/root/bin/sdb"
cat > "$WORK/root/certificates/server_db.env" <<ENV
SDB_BIND=192.168.50.229
SDB_DATA=$WORK/data
SDB_CACHE_GB=0.25
SDB_ROOT_USER=admin
SDB_ROOT_PASSWORD=test
SDB_DISK_ALERT=100   # a comment after a value, as the file allows
RESTIC_REPOSITORY=$WORK/first
SDB_COPY_REPOSITORY=$WORK/pc
RESTIC_PASSWORD="test-password"
SDB_KUMA_BACKUP='https://kuma.test/api/push/backup?status=up&msg=OK&ping='
SDB_KUMA_COPY=https://kuma.test/api/push/copy
SDB_KUMA_HEALTH=https://kuma.test/api/push/health?status=up&msg=OK&ping=
ENV

# Read as written (bin/sdb's load_settings): the Push URL's & unquoted, a comment after the alert line,
# the password in double quotes. Read any other way, the checks below fail.

# Docker, stood in for. `exec ... mongodump` writes a dump that changes each time (the hour's new data)
# on top of a part that does not; `ps` answers $HEALTH; mongosh answers like a MongoDB with nothing in it.
cat > "$WORK/path/docker" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *mongodump*) [ -z "${DUMP_FAILS:-}" ] || exit 1
    head -c 2000000 /dev/zero; date +%s%N; cat "$DUMP_EXTRA" 2>/dev/null; exit 0 ;;
  *"ps mongo --format {{.Health}}"*) echo "${HEALTH:-}" ;;
  *"ps mongo"*) echo "server-db-mongo-1: Up 3 hours (healthy)" ;;
  *mongosh*) echo "MongoDB 8.0.34" ;;
  *) echo "the stand-in docker was asked something this test does not expect: $*" >&2; exit 1 ;;
esac
SHIM
# Uptime Kuma, stood in for: every push is one line, "URL status=… msg=…".
cat > "$WORK/path/curl" <<'SHIM'
#!/usr/bin/env bash
# KUMA_UNREACHABLE: as on the db LXC before its DNS knew uptimekuma.home.
[ -z "${KUMA_UNREACHABLE:-}" ] || { echo "curl: (6) Could not resolve host: kuma.test" >&2; exit 6; }
line=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-urlencode) line="$line $2"; shift ;;
    -m|--retry|-o) shift ;;
    -*) ;;
    *) line="$1$line" ;;
  esac
  shift
done
echo "$line" >> "$KUMA_LOG"
SHIM
# restic, with two ways to fail. PC_OFF: anything that touches the PC's repository fails at once, as
# restic does when ssh cannot reach a PC that is off. FAIL_COPY: `copy` fails as a full disk on the PC would.
REAL_RESTIC="$(command -v restic)"
cat > "$WORK/path/restic" <<SHIM
#!/usr/bin/env bash
if [ -n "\${PC_OFF:-}" ] && [[ " \$* " == *" $WORK/pc "* ]]; then
  echo "subprocess ssh: ssh: connect to host 192.168.50.30 port 22: No route to host" >&2
  echo "Fatal: unable to open repository at sftp:backup-pc:/srv/server-db-copy: unable to start the sftp session" >&2
  exit 1
fi
if [ -n "\${FAIL_COPY:-}" ] && [[ " \$* " == *" copy "* ]]; then echo "stand-in: no space left on the PC" >&2; exit 1; fi
exec "$REAL_RESTIC" "\$@"
SHIM
chmod +x "$WORK/path/"*
export PATH="$WORK/path:$PATH" DUMP_EXTRA="$WORK/extra" KUMA_LOG="$WORK/kuma.log"
touch "$KUMA_LOG"
sdb() { "$WORK/root/bin/sdb" "$@"; }
# Run it, keeping its exit status in $status, its output in $WORK/out and its errors in $WORK/err.
run() { if sdb "$@" >"$WORK/out" 2>"$WORK/err"; then status=0; else status=$?; fi; }
snapshots() { RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$1" snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
# The snapshots a repository holds, by the id they were first made under: a copy keeps its source's.
made() { RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$1" snapshots --json | python3 -c '
import json, sys; print(" ".join(sorted(s.get("original") or s["id"] for s in json.load(sys.stdin))))'; }
# The last push to one monitor, and how many it has had.
last_push() { grep "/push/$1 " "$KUMA_LOG" | tail -1; }
pushes() { grep -c "/push/$1 " "$KUMA_LOG" || true; }

# The chunking a repository cuts files with: the same in both is what lets a copy send only what is new.
chunker() { RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$1" cat config | python3 -c 'import json,sys; print(json.load(sys.stdin)["chunker_polynomial"])'; }

echo "init with the PC off: nothing is made"
PC_OFF=1 run init
check "it exits non-zero, and says to turn the PC on" "[ $status -ne 0 ] && grep -q 'is the machine that holds it on' '$WORK/err'"
check "and no backup repository was made" "[ ! -e '$WORK/first/config' ]"

echo "init: both repositories"
sdb init >/dev/null
check "the first repository exists" "[ -f '$WORK/first/config' ]"
check "the copy's repository exists" "[ -f '$WORK/pc/config' ]"
check "both cut files the same way" "[ \"\$(chunker '$WORK/first')\" = \"\$(chunker '$WORK/pc')\" ]"

echo "backup: to the first only"
echo "hour one" > "$WORK/extra"; run backup
check "it exits 0" "[ $status -eq 0 ]"
check "one snapshot in the first" "[ \$(snapshots '$WORK/first') = 1 ]"
check "nothing in the copy yet: the backup never waits on the PC" "[ \$(snapshots '$WORK/pc') = 0 ]"
check "Kuma hears 'up', with how long it took" "last_push backup | grep -q 'status=up msg=backed up .* ping='"
check "at the Push URL without its own ?status=up&msg=OK" "last_push backup | grep -q '^https://kuma.test/api/push/backup '"

echo "copy: the PC is on"
run copy
check "it exits 0" "[ $status -eq 0 ]"
check "the copy holds the first's snapshot" "[ \"\$(made '$WORK/first')\" = \"\$(made '$WORK/pc')\" ]"
check "Kuma hears 'up'" "last_push copy | grep -q 'status=up'"
check "and when it arrived is written down" "[ -s '$WORK/last-copy' ]"

echo "the PC is off for two hours"
export PC_OFF=1
copy_pushes=$(pushes copy)
echo "hour two" > "$WORK/extra"; run backup
check "the backup exits 0" "[ $status -eq 0 ]"
check "and Kuma hears 'up'" "last_push backup | grep -q 'status=up'"
run copy
check "the copy exits 0: an off PC is not a failure" "[ $status -eq 0 ]"
check "and says it waits, and why" "grep -q 'not reachable; it gets everything the next time it is. subprocess ssh: ssh: connect to host 192.168.50.30 port 22: No route to host' '$WORK/out'"
echo "hour three" > "$WORK/extra"; sdb backup >/dev/null; sdb copy >/dev/null
check "Kuma hears nothing from the copy: its interval decides when that is an alert" "[ \$(pushes copy) = $copy_pushes ]"
run status
check "status says the copy is not reachable, and when one last arrived" "grep -q 'not reachable now (off?); a copy last arrived: 20' '$WORK/out'"
check "and lists the newest backup" "grep -A1 '^newest backups' '$WORK/out' | grep -q ' server-db '"

echo "Mahoraga's apps' LXC stores its archive in the first, at night"
mkdir -p "$WORK/archive" && echo "jobs of 2026-10" > "$WORK/archive/corpus-2026-10.jsonl.xz"
RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$WORK/first" backup --quiet --host mahoraga-archive "$WORK/archive"

echo "the PC is back: the next copy sends everything it missed"
unset PC_OFF
run copy
check "it exits 0" "[ $status -eq 0 ]"
check "the copy holds exactly what the first holds" "[ \"\$(made '$WORK/first')\" = \"\$(made '$WORK/pc')\" ]"
check "Mahoraga's archive among it" "RESTIC_PASSWORD=test-password '$REAL_RESTIC' -r '$WORK/pc' snapshots --host mahoraga-archive --json | grep -q mahoraga-archive"
RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$WORK/pc" dump --host server-db latest "$WORK/dump/all.archive" > "$WORK/read"
check "the copy's newest is hour three's dump" "tail -c 11 '$WORK/read' | grep -q 'hour three'"
check "Kuma hears 'up'" "last_push copy | grep -q 'status=up'"
run status
check "status lists the copy's newest of each: server-db's and the archive's" \
  "grep -A2 '^newest in the copy' '$WORK/out' | grep -q ' server-db ' && grep -A2 '^newest in the copy' '$WORK/out' | grep -q ' mahoraga-archive '"

echo "the PC answers, but the copy breaks (its disk is full)"
echo "hour four" > "$WORK/extra"; sdb backup >/dev/null
FAIL_COPY=1 run copy
check "it exits non-zero" "[ $status -ne 0 ]"
check "and Kuma hears 'down', with why" "last_push copy | grep -q 'status=down msg=copy FAILED: .* answered'"

echo "the server is gone, the PC is not: a new LXC, a new backup disk, the same settings"
rm -rf "$WORK/first"
pc_before="$(made "$WORK/pc")"
PC_OFF=1 run init
check "init with the PC off exits non-zero and makes no empty repository" "[ $status -ne 0 ] && [ ! -e '$WORK/first/config' ]"
run init
check "init exits 0" "[ $status -eq 0 ]"
check "and brings every backup back from the copy" "[ \"\$(made '$WORK/first')\" = '$pc_before' ]"
RESTIC_PASSWORD=test-password "$REAL_RESTIC" -r "$WORK/first" dump --host server-db latest "$WORK/dump/all.archive" > "$WORK/read"
check "the newest it brought back is the copy's newest, hour three's" "tail -c 11 '$WORK/read' | grep -q 'hour three'"
echo "hour six" > "$WORK/extra"; sdb backup >/dev/null; sdb copy >/dev/null
check "the next copy sends the new hour, and the history it came from is not doubled" \
  "[ \"\$(made '$WORK/first')\" = \"\$(made '$WORK/pc')\" ] && [ \"\$(made '$WORK/pc')\" != '$pc_before' ]"

echo "the dump fails"
before=$(snapshots "$WORK/first")
DUMP_FAILS=1 run backup
check "it exits non-zero" "[ $status -ne 0 ]"
check "stores nothing" "[ \$(snapshots '$WORK/first') = $before ]"
check "and Kuma hears 'down', with why" "last_push backup | grep -q 'status=down msg=backup FAILED: the dump did not finish'"

echo "health"
HEALTH=healthy run health
check "healthy: exits 0, Kuma hears 'up'" "[ $status -eq 0 ] && last_push health | grep -q 'status=up msg=healthy'"
HEALTH=unhealthy run health
check "unhealthy: exits non-zero, Kuma hears 'down'" "[ $status -ne 0 ] && last_push health | grep -q 'status=down msg=MongoDB is unhealthy'"
HEALTH='' run health
check "not running: Kuma hears 'down'" "last_push health | grep -q 'status=down msg=MongoDB is not running'"

echo "Uptime Kuma cannot be reached"
KUMA_UNREACHABLE=1 HEALTH=healthy run health
check "health says Kuma was NOT told, and curl's reason, once" \
  "grep -q 'healthy (Uptime Kuma NOT told: it could not be reached)' '$WORK/out' && [ \$(grep -c 'Could not resolve host' '$WORK/err') = 1 ]"
echo "hour seven" > "$WORK/extra"; KUMA_UNREACHABLE=1 run backup
check "a backup that worked still exits 0: Kuma is not its outcome" "[ $status -eq 0 ] && grep -q 'backed up' '$WORK/out'"
KUMA_UNREACHABLE=1 run copy
check "and so does a copy" "[ $status -eq 0 ] && grep -q 'copied' '$WORK/out'"

echo "a disk past SDB_DISK_ALERT"
sed -i 's/^SDB_DISK_ALERT=.*/SDB_DISK_ALERT=1/' "$WORK/root/certificates/server_db.env"
if [ "$(df --output=pcent "$WORK" | tail -1 | tr -dc 0-9)" -ge 1 ]; then
  echo "hour five" > "$WORK/extra"; run backup
  check "the backup is stored, but exits non-zero" "[ $status -ne 0 ] && grep -q 'backed up, but the disk holding' '$WORK/err'"
  check "and Kuma hears 'down', with why" "last_push backup | grep -q 'status=down msg=backed up, but the disk holding .* full'"
  HEALTH=healthy run health
  check "health says so too" "[ $status -ne 0 ] && last_push health | grep -q 'status=down msg=the disk holding'"
fi

echo
[ "$fails" -eq 0 ] && echo "backup chain: all checks passed" || { echo "backup chain: $fails check(s) FAILED"; exit 1; }
