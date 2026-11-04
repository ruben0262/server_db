#!/usr/bin/env bash
# The backup chain, end to end, on any machine with restic: `bin/sdb init` and `bin/sdb backup` against two
# real restic repositories (the first and its copy), with Docker stood in for by a script that answers
# `mongodump` with a made-up dump. What it proves: a backup reaches both repositories; the copy catches up
# on an hour it missed; a copy that fails says so and exits non-zero; what is read back is what was dumped.
# The real container, mongodump and the drill are proved on the server (ROADMAP.md, step 6).
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
SDB_BIND=192.168.50.20
SDB_DATA=$WORK/data
SDB_CACHE_GB=0.25
SDB_ROOT_USER=admin
SDB_ROOT_PASSWORD=test
SDB_DISK_ALERT=100
RESTIC_REPOSITORY=$WORK/first
SDB_OFFSITE_REPOSITORY=$WORK/copy
RESTIC_PASSWORD=test-password
ENV

# Docker, stood in for: `compose ... exec -T mongo sh -c "exec mongodump ..."` writes a dump that changes
# each time (the hour's new data) on top of a part that does not.
cat > "$WORK/path/docker" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *mongodump*) head -c 2000000 /dev/zero; date +%s%N; cat "$DUMP_EXTRA" 2>/dev/null; exit 0 ;;
  *) echo "the stand-in docker was asked something this test does not expect: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$WORK/path/docker"
export PATH="$WORK/path:$PATH" DUMP_EXTRA="$WORK/extra"
sdb() { "$WORK/root/bin/sdb" "$@"; }
snapshots() { RESTIC_PASSWORD=test-password restic -r "$1" snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
# The snapshots a repository holds, by the id they were first made under: a copy keeps its source's.
made() { RESTIC_PASSWORD=test-password restic -r "$1" snapshots --json | python3 -c '
import json, sys; print(" ".join(sorted(s.get("original") or s["id"] for s in json.load(sys.stdin))))'; }

echo "init: both repositories"
sdb init >/dev/null
check "the first repository exists" "[ -f '$WORK/first/config' ]"
check "the copy's repository exists" "[ -f '$WORK/copy/config' ]"

echo "backup: reaches both"
echo "hour one" > "$WORK/extra"; sdb backup >/dev/null
check "one snapshot in the first" "[ \$(snapshots '$WORK/first') = 1 ]"
check "one snapshot in the copy" "[ \$(snapshots '$WORK/copy') = 1 ]"

echo "the copy is unreachable for an hour"
mv "$WORK/copy" "$WORK/copy.away"
echo "hour two" > "$WORK/extra"
if sdb backup >/dev/null 2>"$WORK/err"; then status=0; else status=$?; fi
check "the backup exits non-zero" "[ $status -ne 0 ]"
check "and says the copy failed" "grep -q 'copy to .* FAILED' '$WORK/err'"
check "the first has an hour the copy has not" "[ \"\$(made '$WORK/first')\" != \"\$(made '$WORK/copy.away')\" ]"

echo "it is back: the next backup sends the hour it missed too"
mv "$WORK/copy.away" "$WORK/copy"
echo "hour three" > "$WORK/extra"; sdb backup >/dev/null
check "the copy holds exactly what the first holds" "[ \"\$(made '$WORK/first')\" = \"\$(made '$WORK/copy')\" ]"
RESTIC_PASSWORD=test-password restic -r "$WORK/copy" dump --host server-db latest "$WORK/dump/all.archive" > "$WORK/read"
check "the copy's newest is hour three's dump" "tail -c 11 '$WORK/read' | grep -q 'hour three'"

echo
[ "$fails" -eq 0 ] && echo "backup chain: all checks passed" || { echo "backup chain: $fails check(s) FAILED"; exit 1; }
