#!/usr/bin/env bash
# ROADMAP Phase 1 without Docker: `bin/sdb import` and the commands that run before backups are set up.
# Docker is stood in for. Asked to list a database it answers from files the test writes; asked to copy,
# it runs bin/sdb's own copy script with stand-ins for mongodump (which keeps the file it was given) and
# mongorestore (which keeps its arguments). What it proves: import refuses a wrong string, a stopped
# MongoDB and an empty source before copying anything; asks before replacing; passes the source's string
# in the environment and a private file, never on a command line; and passes only when every collection
# has the same documents and indexes on both sides. The real tools and Atlas: ROADMAP, step 5.
#
#   tests/import_test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }

mkdir -p "$WORK/root/bin" "$WORK/root/certificates" "$WORK/path" "$WORK/fakes"
cp "$HERE/bin/sdb" "$HERE/compose.yml" "$WORK/root/"
mv "$WORK/root/sdb" "$WORK/root/bin/sdb"
# Phase 1's settings: no backups yet.
cat > "$WORK/root/certificates/server_db.env" <<ENV
SDB_BIND=192.168.50.229
SDB_DATA=$WORK/data
SDB_CACHE_GB=0.25
SDB_ROOT_USER=admin
SDB_ROOT_PASSWORD=test
SDB_DISK_ALERT=100
RESTIC_REPOSITORY=
RESTIC_PASSWORD=
ENV

cat > "$WORK/path/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/docker.argv"
pwd > "$WORK/docker.pwd"
case "$*" in
  *"ps -q mongo"*) echo "${CID-cid123}" ;;
  *"ps mongo --format"*) echo "server-db-mongo-1: Up 3 hours (healthy)" ;;
  # The source, listed over its connection string.
  *"cid123 mongosh --nodb"*) printf '%s\n' "$SDB_SOURCE" > "$WORK/source.env"
    echo "Warning: a line mongosh might print first"; cat "$WORK/source.list" ;;
  # The copy: bin/sdb's own script, with the tools stood in for.
  *"cid123 bash -c "*) shift 4   # exec -e SDB_SOURCE cid123
    if PATH="$WORK/fakes:$PATH" MONGO_INITDB_ROOT_USERNAME=admin MONGO_INITDB_ROOT_PASSWORD=test "$@"; then
      touch "$WORK/copied"
    else exit 1; fi ;;
  # This side, as the administrator: before the copy and after it.
  *"exec mongosh"*) if [ -e "$WORK/copied" ]; then cat "$WORK/here.after"; else cat "$WORK/here.before"; fi ;;
  *) echo "the stand-in docker was asked something this test does not expect: $*" >&2; exit 1 ;;
esac
SHIM
cat > "$WORK/fakes/mongodump" <<'SHIM'
#!/usr/bin/env bash
[ -z "${DUMP_FAILS:-}" ] || { echo "stand-in mongodump: connection refused" >&2; exit 1; }
while [ $# -gt 0 ]; do [ "$1" = --config ] && { cp "$2" "$WORK/conf.seen"; echo "$2" > "$WORK/conf.path"; }; shift; done
echo "the archive"
SHIM
cat > "$WORK/fakes/mongorestore" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$WORK/restore.args"
cat > /dev/null
SHIM
chmod +x "$WORK/path/docker" "$WORK/fakes/"*
export PATH="$WORK/path:$PATH" WORK
sdb() { "$WORK/root/bin/sdb" "$@"; }
# `run INPUT ARGS…`: INPUT as what is typed, exit status in $status, output in out and err.
run() { local input="$1"; shift; if printf '%b' "$input" | sdb "$@" >"$WORK/out" 2>"$WORK/err"; then status=0; else status=$?; fi; }
fresh() { rm -f "$WORK/copied" "$WORK/conf.seen" "$WORK/conf.path" "$WORK/restore.args" "$WORK/docker.argv"; }

URI="mongodb+srv://mahoraga:S3cr'et@cluster0.ab12c.mongodb.net/?retryWrites=true&w=majority"
printf 'jobs 1200 4\nusers 3 2\ncounters 1 1\n' > "$WORK/source.list"
: > "$WORK/here.before"
printf 'users 3 2\ncounters 1 1\njobs 1200 4\n' > "$WORK/here.after"

echo "before backups are set up (Phase 1)"
run '' init
check "init makes the data folder and says backups come later" "[ $status -eq 0 ] && [ -d '$WORK/data' ] && grep -q 'Phase 2' '$WORK/out'"
run '' backup
check "backup refuses, and says why" "[ $status -eq 2 ] && grep -q 'not set up yet' '$WORK/err'"
run '' status
check "status says backups are not set up yet" "grep -q '^backups: not set up yet' '$WORK/out'"

echo "the same for root and the owner"
ln -s "$WORK/root/bin/sdb" "$WORK/sdb-link"
if "$WORK/sdb-link" status >"$WORK/out" 2>"$WORK/err"; then status=0; else status=$?; fi
check "through a link, as install puts /usr/local/bin/sdb, it finds its checkout" "[ $status -eq 0 ] && grep -q '^backups: not set up yet' '$WORK/out'"
# Root, stood in for: `id -u` says 0 until runuser has switched; runuser writes down how it was asked.
mkdir -p "$WORK/asroot"
cat > "$WORK/asroot/id" <<'SHIM'
#!/usr/bin/env bash
if [ "$*" = -u ] && [ -n "${FAKE_ROOT:-}" ]; then echo 0; else exec /usr/bin/id "$@"; fi
SHIM
cat > "$WORK/asroot/runuser" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$WORK/runuser.args"
while [ "$1" != -- ]; do shift; done; shift
FAKE_ROOT= exec "$@"
SHIM
chmod +x "$WORK/asroot/"*
# From root's own folder, as the Proxmox console starts in /root, which the owner cannot open.
mkdir -p "$WORK/roots-home"
if (cd "$WORK/roots-home" && PATH="$WORK/asroot:$PATH" FAKE_ROOT=1 "$WORK/sdb-link" status) >"$WORK/out" 2>"$WORK/err"; then status=0; else status=$?; fi
check "as root, it runs again as the checkout's owner, with the owner's home" \
  "grep -qx -- \"-u $(id -un) -- env HOME=$(getent passwd "$(id -un)" | cut -d: -f6) $WORK/root/bin/sdb status\" '$WORK/runuser.args'"
check "and does the same as for the owner" "[ $status -eq 0 ] && grep -q '^backups: not set up yet' '$WORK/out'"
check "from the checkout, not from the folder it was called in" "[ \"\$(cat '$WORK/docker.pwd')\" = '$WORK/root' ]"
rm -f "$WORK/runuser.args"
PATH="$WORK/asroot:$PATH" FAKE_ROOT=1 "$WORK/sdb-link" install >/dev/null 2>&1 || true
check "but install, which needs root, is not handed to the owner" "[ ! -e '$WORK/runuser.args' ]"

echo "import refuses before copying anything"
fresh; run 'hello\n' import mahoraga
check "a string that is not mongodb:// or mongodb+srv://" "[ $status -eq 2 ] && [ ! -e '$WORK/copied' ]"
fresh; CID='' run "$URI\n" import mahoraga
check "MongoDB not running here" "[ $status -ne 0 ] && grep -q 'bin/sdb up first' '$WORK/err' && [ ! -e '$WORK/copied' ]"
fresh; mv "$WORK/source.list" "$WORK/source.full"; : > "$WORK/source.list"; run "$URI\n" import mahoraga
check "a source with nothing in that database: a wrong name" "[ $status -ne 0 ] && grep -q 'no collections' '$WORK/err' && [ ! -e '$WORK/copied' ]"
mv "$WORK/source.full" "$WORK/source.list"
fresh; run '' import Mahoraga
check "a name that is not an app's" "[ $status -eq 2 ] && [ ! -e '$WORK/copied' ]"

echo "import into an empty database"
fresh; run "$URI\n" import mahoraga
check "it exits 0, every collection the same" "[ $status -eq 0 ] && grep -q 'every collection arrived: 3 collections, 1204 documents' '$WORK/out'"
check "it said what the source holds first" "grep -q \"'mahoraga' at the source: 3 collections, 1204 documents\" '$WORK/out'"
check "a line mongosh printed first is not taken for a collection" "! grep -q Warning '$WORK/out'"
check "mongorestore restores mahoraga into mahoraga, as the administrator" \
  "grep -q -- '-u admin .*--nsInclude mahoraga.\* --nsFrom mahoraga.\* --nsTo mahoraga.\*' '$WORK/restore.args'"
check "and replaces nothing" "[ -f '$WORK/restore.args' ] && ! grep -q -- --drop '$WORK/restore.args'"
check "the source's string reached the container in its environment" "[ \"\$(cat '$WORK/source.env')\" = \"\$URI\" ]"
check "and never a command line" "! grep -qF 'S3cr' '$WORK/docker.argv'"
check "mongodump got it in a file, quoted for YAML" "[ \"\$(cat '$WORK/conf.seen')\" = \"uri: 'mongodb+srv://mahoraga:S3cr''et@cluster0.ab12c.mongodb.net/?retryWrites=true&w=majority'\" ]"
check "which is gone afterwards" "[ -s '$WORK/conf.path' ] && [ ! -e \"\$(cat '$WORK/conf.path')\" ]"

echo "import over a database that has data"
printf 'jobs 10 4\n' > "$WORK/here.before"
fresh; run "$URI\nno\n" import mahoraga
check "it asks, and 'no' changes nothing" "[ $status -ne 0 ] && grep -q 'nothing changed' '$WORK/out' && [ ! -e '$WORK/copied' ]"
fresh; run "$URI\nyes\n" import mahoraga
check "'yes' replaces it" "[ $status -eq 0 ] && grep -q -- '--drop' '$WORK/restore.args'"
: > "$WORK/here.before"

echo "a copy that does not match"
printf 'users 3 2\ncounters 1 1\njobs 1199 4\n' > "$WORK/here.after"
fresh; run "$URI\n" import mahoraga
check "a collection short a document: exits non-zero" "[ $status -ne 0 ] && grep -q '1 collection(s) differ' '$WORK/err'"
check "and marks that collection, and only it" "grep 'DIFFERS' '$WORK/out' | grep -q '^  jobs ' && [ \$(grep -c DIFFERS '$WORK/out') = 1 ]"
printf 'users 3 1\ncounters 1 1\njobs 1200 4\n' > "$WORK/here.after"
fresh; run "$URI\n" import mahoraga
check "an index missing: exits non-zero" "[ $status -ne 0 ] && grep 'DIFFERS' '$WORK/out' | grep -q '^  users '"
printf 'users 3 2\njobs 1200 4\n' > "$WORK/here.after"
fresh; run "$URI\n" import mahoraga
check "a collection missing here: exits non-zero" "[ $status -ne 0 ] && grep 'DIFFERS' '$WORK/out' | grep -q '^  counters .* - '"
printf 'users 3 2\ncounters 1 1\njobs 1200 4\n' > "$WORK/here.after"

echo "a database with another name at the source"
fresh; run "$URI\n" import mahoraga job_search
check "it is read and restored under the new name" \
  "[ $status -eq 0 ] && grep -q -- '--nsInclude job_search.\* --nsFrom job_search.\* --nsTo mahoraga.\*' '$WORK/restore.args'"

echo "the copy fails half way"
fresh; DUMP_FAILS=1 run "$URI\n" import mahoraga
check "it exits non-zero and says to run it again" "[ $status -ne 0 ] && grep -q 'did not finish' '$WORK/err'"

echo
[ "$fails" -eq 0 ] && echo "import: all checks passed" || { echo "import: $fails check(s) FAILED"; exit 1; }
