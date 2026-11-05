# server_db: design

One MongoDB on the Proxmox server for every app we make, reachable from any machine on the LAN
(192.168.50.x), each app with its own database and login, backed up every hour. Mahoraga (the job
search platform) is the first; it moves here from MongoDB Atlas, whose free plan holds 512 MB.

How to build it, step by step: [ROADMAP.md](ROADMAP.md). The commands: [README.md](README.md).

## What it costs: nothing a month

| | Cost |
|---|---|
| MongoDB Community 8.0.34 | Free, self-hosted, any size. Its licence (SSPL) only asks something of companies that sell MongoDB itself as a service to others, which this is not |
| Docker, Ubuntu Server, restic | Free |
| The VM | Runs on the Proxmox host you have: its electricity only |
| Backups on your own disks or another machine on the LAN | Free |
| A copy off the premises | Optional. Free ways: a disk kept at another address (restic to it over SSH, or a USB disk swapped weekly). Cloudflare R2 is free up to 10 GB, then $0.015 per GB a month |
| Alerts (healthchecks.io) | Free plan, 20 checks; two are used |

**Why not build our own database, or use another kind?** A home-made database would take months and
be the least reliable part of every app, holding the data that matters most. PostgreSQL is free too,
but Mahoraga is written for MongoDB: changing would be a rewrite, for no gain. The goal is "use it just
like MongoDB", and the only thing that does that exactly is MongoDB: apps change one setting
(`MONGODB_URI`) and nothing else.

## Why now

Mahoraga is moving from asking job boards for each person's words to reading every new job in the
countries people pick, and matching the words itself. Measured 2026-11-04:

| | |
|---|---|
| New LinkedIn jobs, the EU and the UK | 750 (09:50) to 1,500 (11:00) every 15 minutes: 40,000–70,000 a day |
| A stored job | 4.7 KB of data on average |
| A month of them (1.5 million) | 7.1 GB of data, **2.5 GB on disk** (zstd), 0.45 GB of indexes |

Atlas's 512 MB holds about two days of that.

## Decision 1: its own VM

A VM called `db` on Proxmox, apart from the apps' VM. Rebuilding or restarting an app never touches the
database, and an app using too much memory (Mahoraga's PDF maker runs Chrome) cannot starve it.

| | Size | Why |
|---|---|---|
| CPU | 2 cores | Measured at full size on 2 cores (Speed, below) |
| Memory | **8 GB, 3.5 GB of it MongoDB's cache**; 4 GB and 1.5 GB at the least | Measured: the jobs the Jobs page reads (the last 8 days, ~1.9 GB) fit in 3.5 GB, not in 1.5, and every match then reads from memory (Speed, below) |
| Data disk | 100 GB, on SSD/NVMe | Mahoraga's month is 2.5 GB: the rest is room for every other app, and growth |
| Backup disk | 100 GB, on a **different** physical disk | If backups stay on the host (Backups, below) |
| System disk | 16 GB | Ubuntu Server 24.04 and Docker |

Grow any of these later in Proxmox; nothing in server_db fixes them. The cache follows `SDB_CACHE_GB`:
about half the VM's memory less 0.5 GB (3.5 on 8 GB, 1.5 on 4 GB).

### Disk

Collections are stored with **zstd**, not MongoDB's default snappy (`mongod.conf`). Measured 2026-11-04
on Mahoraga's 24,452 stored jobs (110 MB of data): snappy 58.5 MB on disk, zstd 36.3 MB, zlib 39.9 MB;
at 1.5 million jobs, 7.1 GB of data took 2.5 GB. It applies to collections created after the setting,
which is every one here: the copy from Atlas creates them. Mahoraga at the EU's and the UK's volume:
~0.06–0.12 GB of disk a day, 2–4 GB for the 30 days it keeps.

## Decision 2: the image

`Dockerfile`: the official `mongo:8.0.34`, and `mongod.conf` built in. `bin/sdb up` builds it on the
server; nothing else is pulled.

`mongod.conf` says:
- **a login, always** (`authorization: enabled`);
- **zstd** for every collection;
- **every query slower than 200 ms is written to the log**, with how it ran: how a slow app is found
  (`docker compose logs mongo | grep "Slow query"`).

What a VM decides (its address, its cache) comes from `certificates/server_db.env` through `compose.yml`.
One exact version: upgraded on purpose (ROADMAP, "Later"), never by a pull that landed on a new one.

## Decision 3: reachable from the LAN, and only from it

- The VM has a fixed address on the LAN, e.g. `192.168.50.20` (`SDB_BIND`): a DHCP reservation on the
  router, or set in the VM.
- MongoDB's port is published **on that address only**, never on 0.0.0.0. Every machine on 192.168.50.x
  reaches it; a network card added to the VM later does not.
- **The router must not forward 27017.** Docker's published ports pass around the VM's own firewall
  (ufw), so the address it is published on, and the router, are what keep it off the internet.
- A name instead of the address (optional): a DNS entry on the router, e.g. `db.lan` (`SDB_HOSTNAME`).
  `bin/sdb add-app` puts it in the connection string it prints.

From any machine on the LAN, an app connects with its own string:
`mongodb://NAME:PASSWORD@192.168.50.20:27017/NAME?authSource=NAME`.

## Decision 4: many apps, each in its own database

- `bin/sdb add-app NAME` makes a database called NAME and a login for it, prints its `MONGODB_URI` once,
  and stores the password nowhere else.
- That login can read and write its own database, and change its indexes and rules (`dbAdmin`), and
  nothing else. It cannot see another app's database, or make logins.
- The administrator's login is used only by `bin/sdb`, from inside the container. It is never in an app.
- All apps share one MongoDB, its cache and its disk. A busy app can slow the others, which shows in the
  slow-query log and `bin/sdb status` (each database's size). An app that outgrows sharing gets a second
  server_db on its own VM, the same files, a different `SDB_BIND`.
- Tests never use this server: they use a MongoDB on the laptop (Mahoraga's `tests/conftest.py` refuses
  anything else).
- **What an app does with its data is the app's.** Mahoraga moves its old jobs to its archive every run,
  with its own login: server_db is not asked to. So server_db has no control endpoint of its own; one would
  be a second way in, with its own password to keep, for work an app already does. An operator acts on a
  database with `bin/sdb shell NAME`, or from a laptop on the LAN with that app's login (MongoDB Compass).

## Decision 5: one server now, a second when there is a second machine

**What one server means.** If the VM or the Proxmox host is down, the apps are down until it is back. A
MongoDB "replica set" keeps a second copy that takes over in seconds, but only on a different machine.
Two copies on the same host fail together, so a replica set here would add parts and no safety.

**When to add one.** When there is a second machine: another Proxmox node, a NAS that runs Docker, a
small VPS. The change: restart with `--replSet rs0`, add the member, put `replicaSet=rs0` in each app's
`MONGODB_URI`. The data stays where it is.

## Speed

**Next to the apps, not across the internet.** Measured 2026-11-04: each new job Mahoraga stores costs 9
round trips to the database (4 duplicate checks, the job, its country count, then 3 writes when its text
arrives), ~16,000 a run at the EU's and the UK's peak. On the same LAN each takes well under a
millisecond: seconds a run. A database across the internet answers in tens of milliseconds: minutes.

**At full size.** On a laptop limited to 2 cores and a 1.5 GB cache, like this VM, with 1.5 million jobs
and 300 people searching for 3–12 words each in one to three countries:

| | 1.5 GB cache (4 GB VM) | 3.5 GB cache (8 GB VM) |
|---|---|---|
| Jobs page, everybody: median | ~550 ms | ~450 ms |
| 90% of people under | ~1.5 s | ~1.1 s |
| The slowest person | ~2 s | ~2 s |
| A new word, found in every job that can still be shown | 70–97 s, in one or two harvest runs | |
| A person's page while their new word is searched for | 1.6–1.8 s, every job kept | |
| One run's 1,800 new jobs: stored, texts saved, words found | 12 s, 45 s, 13 s | |

With the bigger cache the jobs a match reads (the last 8 days, ~1.9 GB) stay in memory, and the second
look at a page is as fast as the first (the smaller cache read them from disk each time). Mahoraga's
own target for its Jobs page is under 300 ms: at this size it is not met yet. A match reads whole jobs,
~4.7 KB each and mostly description, where it needs a few fields; keeping descriptions in a collection
of their own is the next thing Mahoraga measures. More cores do not shorten one match; they let more
run at once.

Mahoraga's match was rewritten for this on 2026-11-04 (its CHANGELOG): asked as one question with an
"or", the busiest person's match read 586,000 jobs and took over three minutes. ROADMAP step 7 runs the
same measurement on the real VM (`scripts/scale_probe.py` in Mahoraga).

## Staying up

- **MongoDB restarts itself** if it stops (`restart: unless-stopped`).
- **It starts with the VM.** Docker starts at boot (`bin/sdb install`), and so does the VM (Proxmox:
  Options → Start at boot).
- **A health check every 30 seconds** (the image's). `bin/sdb up` waits for it; `bin/sdb status` shows it.
- **Alerts reach you** through healthchecks.io, which emails when a job reports a failure or stops
  reporting at all (that is how a VM that is off gets noticed). A backup reports a failure when:
  - the dump fails, or either repository refuses it;
  - the data disk passes `SDB_DISK_ALERT` (85%).

## Backups

Every database, users and their logins included: one `mongodump` every hour, written to a file, then
sent with restic, which encrypts before anything leaves the VM and stores again only what changed.
Kept: every hour for 2 days, every day for 30, every month for a year. **Checked every Sunday**:
`bin/sdb drill` restores the newest into a throwaway MongoDB and fails unless every collection with
data now has data in the backup.

**Where they go.** Two settings: where every backup goes first (`RESTIC_REPOSITORY`), and optionally a
second place each one is copied to straight after (`SDB_OFFSITE_REPOSITORY`). Any of these, for either:

| Where | Setting | Restores in | Survives | Costs |
|---|---|---|---|---|
| A second disk of the VM, on another physical disk of the host | `/srv/server-db-backups` | minutes | a deleted database, a broken data disk | nothing |
| Another machine on the LAN (a NAS, an old PC) | `sftp:user@192.168.50.30:/backups/server-db` | minutes | the Proxmox host dying | nothing |
| A disk at another address, reached over SSH | `sftp:user@host:/backups/server-db` | an hour or two | the house | nothing |
| Cloudflare R2 (or Backblaze B2, any S3) | `s3:https://ACCOUNT.r2.cloudflarestorage.com/server-db-backups` | ~15 minutes for today's size | the house | free to 10 GB, then $0.015 per GB a month |

**Recommended:** first a disk or machine on the LAN (fast to restore from, free), and a copy off the
premises. A copy that fails reports a failure, and the next hour sends what it missed (proved by
`tests/backup_test.sh`). The same `RESTIC_PASSWORD` opens both; lose it and no backup can be read.

**Measured 2026-11-03**, with 9,846 jobs (50 MB dumped): a backup took 1–2 seconds, and two took 13.5 MB
stored together. A month of Mahoraga at full size (7.1 GB of data) dumps to a few GB an hour, of which
restic stores only what changed.

**Optional, on the host:** Proxmox's own nightly backup of the whole `db` VM, kept on the host. It brings
the machine back as it was, which is quicker after a broken upgrade; it does not replace the above.

**Files on the apps' VM** are each app's to send: Mahoraga's job archive (`archive/`, xz files, the
only copy of a job once it leaves the database after its keep) goes to the same repository nightly, with
restic on that VM (ROADMAP, step 6b).

## Security

- **Logins are always on.** One administrator, for `bin/sdb` only; one login per app, for its own
  database only. Tested 2026-11-03: Mahoraga's login was refused another database; tested 2026-11-04:
  with the built-in settings, a write without a login is refused.
- **Never on the internet.** Published on the VM's LAN address only, and not forwarded by the router.
- **Inside the LAN, traffic is not encrypted.** Logins use SCRAM, so a password never crosses the network
  as itself, but the data does. If guests or devices you do not control share 192.168.50.x, add TLS
  (ROADMAP, "Later"): a certificate made on the VM, and `tls=true` in each app's string.
- **Passwords never appear on the VM's command line.** The administrator's password stays inside the
  container's settings.
- **Settings live in `certificates/server_db.env`** (chmod 600, never in git). The restic password is the
  one secret whose loss loses every backup, so it goes in a password manager too.

## Moving Mahoraga from Atlas

About ten minutes, with the alerts and harvest paused, never the site (ROADMAP, step 6).
1. `bin/sdb add-app mahoraga`, and keep the `MONGODB_URI` it prints.
2. On the apps' VM, stop the writers: `sudo systemctl stop harvester.timer` and
   `deploy/compose.sh stop notifier`.
3. Copy, with the tools in the MongoDB image:
   ```bash
   docker run --rm -e ATLAS -e NEW mongo:8.0.34 sh -c \
     'mongodump --uri "$ATLAS" --db mahoraga --archive | mongorestore --uri "$NEW" --archive'
   ```
4. Put the new `MONGODB_URI` in `certificates/server.env`, then run `deploy/deploy.sh`. It applies
   Mahoraga's indexes to the new database, and checks the site.
5. Start the timer and the notifier again. Leave Atlas untouched for a week, as the way back, then
   delete it.

## For the owner to decide

1. **Where backups go first, and where the copy goes** (Backups, above). Recommended: a disk or machine on
   the LAN, and a copy off the premises.
2. **The VM's address** on 192.168.50.x, and whether it gets a name on the router.
3. **Mahoraga's own nightly backup** (`deploy/backup.timer`). Once server_db's backups have passed their
   first drill, it is a second mechanism for the same job: retire it, or keep it as a portable export.
