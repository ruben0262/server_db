# server_db: design

One database server on the Proxmox machine for every app we make, starting with Mahoraga (the job
search platform). It replaces MongoDB Atlas, whose plan holds 512 MB.

## Why now

Mahoraga is moving from searching job boards for each person's words to reading every new job and
matching the words itself. That scales with the number of jobs, not the number of people, but it
keeps more jobs. Measured on 2026-11-03:

| | Jobs a day | Over the 30 days kept |
|---|---|---|
| Four small feeds kept whole (shipped) | ~530 | ~50 MB |
| Just Join IT kept whole (waiting on this) | ~2,650 | ~330 MB |
| LinkedIn read by country and hour | not measured yet | likely several GB |

A stored job is 1.3–8.5 KB (4.2 KB for Just Join IT); 9,846 of them take 49 MB. Atlas's 512 MB is
already the ceiling for the second row alone.

## Decision 1: run MongoDB itself, not a look-alike

The goal is "use it just like MongoDB". The only thing that does that exactly is MongoDB: the
Community edition, version 8.0.34, the same one Atlas and the laptops run. Apps change one setting
(`MONGODB_URI`) and nothing else. Every driver, tool, index and query already works.

A home-made server that imitates MongoDB would need months of work. It would also be the least
reliable part of every app, holding the data that matters most.

## Decision 2: its own VM

A VM called `db` on Proxmox, apart from the apps' VM. Rebuilding or restarting an app never touches
the database, and an app using too much memory (Mahoraga's PDF maker runs Chrome) cannot starve it.

| | Size | Why |
|---|---|---|
| CPU | 2 cores | Queries here are index lookups; 2 leaves room for backups |
| Memory | 4 GB | 1.5 GB of cache holds every index and the busy data many times over |
| Data disk | 100 GB, on SSD/NVMe | Years of the measured growth, and room to keep LinkedIn jobs too |
| System disk | 16 GB | Ubuntu Server 24.04 and Docker |

Grow any of these later in Proxmox; nothing in server_db fixes them. The cache follows
`SDB_CACHE_GB`.

### Disk

Collections are compressed with **zstd**, not MongoDB's default snappy. Measured 2026-11-04 on
Mahoraga's 24,452 stored jobs (110 MB of data): snappy 58.5 MB on disk, zstd 36.3 MB, zlib 39.9 MB.
It applies to collections created after the setting, which is every one here: the copy from Atlas
creates them. Mahoraga's jobs, once every country it reads is kept (40,000–70,000 a day for the EU
and the UK, ~5 KB each), are about 0.07–0.12 GB of disk a day, 2–4 GB for the 30 days kept.

## Decision 3: one server now, a second when there is a second machine

**What one server means.** If the VM or the Proxmox host is down, the apps are down until it is back.
A MongoDB "replica set" keeps a second copy that takes over in seconds, but only on a different
machine. Two copies on the same host fail together, so a replica set here would add parts and no
safety.

**When to add one.** When there is a second machine: a second Proxmox node, or a small VPS. The
change is:
1. Restart with `--replSet rs0`.
2. Add the member.
3. Put `replicaSet=rs0` into each app's `MONGODB_URI`.

The data stays where it is.

## Staying up

- **MongoDB restarts itself** if it stops (`restart: unless-stopped`).
- **It starts with the VM.** Docker starts at boot (`bin/sdb install`), and so does the VM (Proxmox:
  Options → Start at boot).
- **A health check runs every 30 seconds.** `bin/sdb up` waits for it, and `bin/sdb status` shows it.
- **One fixed version.** `mongo:8.0.34` never changes on its own. To upgrade: back up, change the line
  in `compose.yml`, run `bin/sdb up`, then `bin/sdb drill`.
- **Alerts reach you.** The backup reports a failure when:
  - the data disk passes `SDB_DISK_ALERT` (85%);
  - the dump fails;
  - the upload fails.

  It reports through healthchecks.io, which emails you when a job says it failed, or stops reporting
  at all. That second case is how a VM that is off gets noticed.

## Backups

| | |
|---|---|
| What | Every database, users and their logins included: one `mongodump` |
| How often | Every hour (`server-db-backup.timer`) |
| Where | A Cloudflare R2 bucket, through restic: off the machine, encrypted before it leaves |
| Kept | Every hour for 2 days, every day for 30 days, every month for a year |
| Checked | Every Sunday, `bin/sdb drill` restores the newest backup into a throwaway MongoDB, and fails unless every collection that has data now has data in the backup |
| Lost at worst | The last hour |
| Back in | About 15 minutes for today's size: `bin/sdb restore` |

**Measured on 2026-11-03**, with the local copy of Mahoraga (9,846 jobs, 50 MB dumped):
- An hourly backup took 1–2 seconds.
- Two backups took **13.5 MB** stored together. restic compresses, and stores again only what
  changed; dumping one collection at a time keeps unchanged ones byte for byte the same.

**Cost.** R2's free tier is 10 GB stored, with no fee to download. At the measured rate that is years
of backups for today's data; after it, $0.015 per GB a month.

**A dump finishes before it is sent.** A dump that dies half way is never stored as a backup. Tested:
a failed dump added no snapshot, and reported the failure.

**Not covered here.** Files on the apps' VM, such as Mahoraga's corpus archive (`archive/`), which
is the only copy of a job after it ages out. That VM needs its own restic job to the same bucket. It
should be a separate task, with its own check.

**A second layer, optional.** Proxmox's own nightly backup of the whole `db` VM, kept on the host. It
restores the machine as it was, which is quicker after a broken upgrade. Off-site, restic is still
the one that counts.

## Security

- **Logins are always on.** One administrator for `bin/sdb`. Each app has its own login (`bin/sdb
  add-app NAME`), which can read and write its own database, and change its indexes and rules, and
  nothing else. Tested: Mahoraga's login was refused another database.
- **Never on the internet.** Port 27017 opens only on the VM's address on Proxmox's private bridge
  (`SDB_BIND`). The VM's firewall lets in only the apps' VM.
- **Reaching it from a laptop.** An SSH tunnel to the VM, never an open port. Tests keep using the
  laptop's own local MongoDB; nothing tests against this server.
- **Passwords never appear on the VM's command line.** The administrator's password stays inside the
  container's settings.
- **Settings live in `certificates/server_db.env`** (chmod 600, never in git). The restic password is
  the one secret whose loss loses every backup, so it goes in a password manager too.

## Moving Mahoraga from Atlas

About ten minutes, with the alerts and harvest paused, never the site.
1. `bin/sdb add-app mahoraga`, and keep the `MONGODB_URI` it prints.
2. On the apps' VM, stop the writers:
   - `sudo systemctl stop harvester.timer`
   - `deploy/compose.sh stop notifier`
3. Copy, with the tools in the MongoDB image:
   ```bash
   docker run --rm mongo:8.0.34 sh -c \
     'mongodump --uri "$ATLAS" --db mahoraga --archive | mongorestore --uri "$NEW" --archive'
   ```
   with `ATLAS` and `NEW` passed in by `-e`.
4. Put the new `MONGODB_URI` in `certificates/server.env`, then run `deploy/deploy.sh`. It applies
   Mahoraga's schema to the new database, and checks the site.
5. Start the timer and the notifier again. Leave Atlas untouched for a week, as the way back, then
   delete it.

Then, in Mahoraga:
- Just Join IT stops being filtered (`KEYWORD_FILTER_SOURCES`).
- The LinkedIn measurement goes ahead.

## For the owner to decide

1. **Where backups go.** Cloudflare R2 (recommended, since the Cloudflare account exists) or
   Backblaze B2. Either works with restic unchanged.
2. **The VM's size.** The table above is the recommendation.
3. **Mahoraga's own nightly backup** (`deploy/backup.timer`). It writes to the apps' VM only, without
   the postings. Once server_db's hourly off-site backup has passed its first drill, it is a second
   mechanism for the same job. Retire it then (CLAUDE.md §1 and §3), or keep it as a portable export?
4. **Off-site backup of the apps' VM files** (Mahoraga's `archive/`). A separate job, to build next.
