# server_db: design

One MongoDB on the Proxmox server for every app we make, at `192.168.50.229`, reachable from any machine
on the LAN (192.168.50.x), each app with its own database and login. Backed up every hour to the LXC's
backup disk and copied to a PC on the LAN whenever it is on; watched by Uptime Kuma. Mahoraga (the job
search platform) is the first; it moves here from MongoDB Atlas, whose free plan holds 512 MB.

How to build it, step by step: [ROADMAP.md](ROADMAP.md). The commands: [README.md](README.md).

## What it costs: nothing a month

| | Cost |
|---|---|
| MongoDB Community 8.0.34 | Free, self-hosted, any size. Its licence (SSPL) only asks something of companies that sell MongoDB itself as a service to others, which this is not |
| Docker, Debian, restic | Free |
| The LXC | Runs on the Proxmox host you have: its electricity only |
| Backups on the LXC's backup disk, and the copy on the PC | Free |
| A copy off the premises | Optional, later. Free ways: a disk kept at another address (restic to it over SSH, or a USB disk swapped weekly). Cloudflare R2 is free up to 10 GB, then $0.015 per GB a month |
| Alerts (Uptime Kuma) | Already running; four push monitors and one MongoDB monitor |

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

## Decision 1: its own LXC, like the apps'

A Proxmox container (LXC) called `db`, Debian 13, apart from the apps' LXC: the owner runs the apps in an
LXC, and the database the same way (owner, 2026-11-05). Rebuilding or restarting an app never touches the
database, and an app using too much memory (Mahoraga's PDF maker runs Chrome) cannot starve it: each LXC
has its own memory limit. MongoDB runs in Docker inside it, as the apps do in theirs.

| | Size | Why |
|---|---|---|
| CPU | 2 cores | Measured at full size on 2 cores (Speed, below) |
| Memory | **8 GB, 3.5 GB of it MongoDB's cache**; 4 GB and 1.5 GB at the least | Measured: the jobs the Jobs page reads (the last 8 days, ~1.9 GB) fit in 3.5 GB, not in 1.5, and every match then reads from memory (Speed, below) |
| Data: mount point `mp0` at `/srv/server-db` | 100 GB, on SSD/NVMe | Mahoraga's month is 2.5 GB: the rest is room for every other app, and growth |
| Backups (Phase 2): mount point `mp1` at `/srv/server-db-backups` | 100 GB, on a **different** physical disk if the host has one | Where every backup goes first (Backups, below), added while the LXC runs. On the same physical disk it still brings back a deleted database; the PC's copy is then what survives that disk |
| Root disk | 16 GB | Debian 13, Docker and its images |

Grow any of these later in Proxmox (Resources → the disk → Resize), while it runs; nothing in server_db
fixes them. Proxmox makes and mounts the mount points itself: nothing to format, nothing in fstab. The
cache follows `SDB_CACHE_GB`: about half the LXC's memory less 0.5 GB (3.5 on 8 GB, 1.5 on 4 GB).

### What an LXC asks for, and what is done about it

Against a VM it saves the second kernel, about 0.3–0.5 GB of the 8 GB, and starts in seconds. What it asks:

| | What it means | What is done |
|---|---|---|
| Docker inside it | Needs the LXC's **nesting** and **keyctl** features. Updates to Proxmox, runc or AppArmor have stopped Docker starting in LXCs before | The same features as the apps' LXC, so both work, or both break, together. Uptime Kuma's health monitor says so within 3 minutes, and the fix is the same in both |
| The kernel is the host's | Its version is the host's: Linux 6.19 through 7.0.13 crash MongoDB 8.0's allocator, and mongod refuses to start on them (SERVER-121912), as it did here on 2026-11-05. And the settings MongoDB's production notes ask for (`vm.max_map_count`, huge pages, swappiness) are set on the Proxmox host, for every guest | The image keeps the allocator off the kernel feature that crashes (`GLIBC_TUNABLES` in `Dockerfile`, measured) until the host runs 7.0.14 or later. `vm.max_map_count` raised on the host (README, "The LXC"), which MongoDB checks at start; the rest as Proxmox has them |
| Isolation | It shares the host's kernel | Only our own apps run beside it |

MongoDB stays in Docker rather than installed from apt in the LXC: one exact version (`Dockerfile`), the
drill's throwaway MongoDB the same image, an upgrade one line, and the same tools as the apps' LXC. If
memory runs short, the LXC grows (Proxmox, then `SDB_CACHE_GB`).

### Disk

Collections are stored with **zstd**, not MongoDB's default snappy (`mongod.conf`). Measured 2026-11-04
on Mahoraga's 24,452 stored jobs (110 MB of data): snappy 58.5 MB on disk, zstd 36.3 MB, zlib 39.9 MB;
at 1.5 million jobs, 7.1 GB of data took 2.5 GB. It applies to collections created after the setting,
which is every one here: the copy from Atlas creates them. Mahoraga at the EU's and the UK's volume:
~0.06–0.12 GB of disk a day, 2–4 GB for the 30 days it keeps.

## Decision 2: the image

`Dockerfile`: the official `mongo:8.0.34`, `mongod.conf` built in, and one setting for the host's kernel
(Decision 1: glibc keeps rseq, so MongoDB starts on Linux 6.19 through 7.0.13). `bin/sdb up` builds it on the
server; nothing else is pulled.

`mongod.conf` says:
- **a login, always** (`authorization: enabled`);
- **zstd** for every collection;
- **every query slower than 200 ms is written to the log**, with how it ran: how a slow app is found
  (`docker compose logs mongo | grep "Slow query"`).

What an LXC decides (its address, its cache) comes from `certificates/server_db.env` through `compose.yml`.
One exact version: upgraded on purpose (ROADMAP, "Later"), never by a pull that landed on a new one.

## Decision 3: reachable from the LAN, and only from it

- The LXC has a fixed address on the LAN, **`192.168.50.229/24`** (`SDB_BIND`; `.20`, the first choice, is
  the Xbox's, from the router's DHCP): set in the LXC, with the
  router as its gateway, and reserved on the router so it never hands that address to another device.
- MongoDB's port is published **on that address only**, never on 0.0.0.0. Every machine on 192.168.50.x
  reaches it; a network card added to the LXC later does not.
- **The router must not forward 27017.** Docker's published ports pass around the LXC's own firewall
  (ufw), so the address it is published on, and the router, are what keep it off the internet.
- A name instead of the address (optional): a DNS entry on the router, e.g. `db.lan` (`SDB_HOSTNAME`).
  `bin/sdb add-app` puts it in the connection string it prints.

From any machine on the LAN, an app connects with its own string:
`mongodb://NAME:PASSWORD@192.168.50.229:27017/NAME?authSource=NAME`.

## Decision 4: many apps, each in its own database

- `bin/sdb add-app NAME` makes a database called NAME and a login for it, prints its `MONGODB_URI` once,
  and stores the password nowhere else.
- That login can read and write its own database, and change its indexes and rules (`dbAdmin`), and
  nothing else. It cannot see another app's database, or make logins.
- The administrator's login is used only by `bin/sdb`, from inside the container. It is never in an app.
- All apps share one MongoDB, its cache and its disk. A busy app can slow the others, which shows in the
  slow-query log and `bin/sdb status` (each database's size). An app that outgrows sharing gets a second
  server_db on its own LXC, the same files, a different `SDB_BIND`.
- Tests never use this server: they use a MongoDB on the laptop (Mahoraga's `tests/conftest.py` refuses
  anything else).
- **What an app does with its data is the app's.** Mahoraga moves its old jobs to its archive every run,
  with its own login: server_db is not asked to.

### The endpoint is MongoDB's own: no API in front of it

How an app reaches its data is the port, `192.168.50.229:27017`, and its own `MONGODB_URI`: its MongoDB
driver (pymongo, for Mahoraga) speaks to it directly, every query, index and transaction, exactly as it
spoke to Atlas. That is the whole point of "use it just like MongoDB": an app changes one setting.

An HTTP API of our own in front of it (`/jobs`, `/users`, …) would be:
- **a rewrite of every app's data code**, from driver calls to HTTP calls, and an API to grow each time an
  app needs a query the API does not have;
- **slower**: Mahoraga makes ~16,000 round trips a harvest run (Speed, below), each one then an HTTP
  request and a translation, where now it is one message on the LAN;
- **a second way in**, with its own passwords to keep, beside MongoDB's logins, which already give each
  app its own database and nothing else.

So there is none. Each app gets its login from `bin/sdb add-app`; an app's data that is elsewhere comes in
with `bin/sdb import`; the operator looks at a database with `bin/sdb shell NAME` on the LXC, or MongoDB
Compass from a laptop on the LAN with that app's login.

## Decision 5: one server now, a second when there is a second machine

**What one server means.** The apps and the database are on the same Proxmox host: when it is down, both
are, and when it is back, both are, the database first (Staying up). Nothing is lost by that: no app
writes while it is down. A MongoDB "replica set" keeps a second copy that takes over in seconds, but only
on a different machine. Two copies on the same host fail together, so a replica set here would add parts
and no safety.

**When to add one.** When there is a second machine: another Proxmox node, a NAS that runs Docker, a
small VPS. The change: restart with `--replSet rs0`, add the member, put `replicaSet=rs0` in each app's
`MONGODB_URI`. The data stays where it is.

## Speed

**Next to the apps, not across the internet.** Measured 2026-11-04: each new job Mahoraga stores costs 9
round trips to the database (4 duplicate checks, the job, its country count, then 3 writes when its text
arrives), ~16,000 a run at the EU's and the UK's peak. On the same LAN each takes well under a
millisecond: seconds a run. A database across the internet answers in tens of milliseconds: minutes.

**At full size.** On a laptop limited to 2 cores and a 1.5 GB cache, like this LXC, with 1.5 million jobs
and 300 people searching for 3–12 words each in one to three countries:

| | 1.5 GB cache (4 GB LXC) | 3.5 GB cache (8 GB LXC) |
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
"or", the busiest person's match read 586,000 jobs and took over three minutes. ROADMAP step 13 runs the
same measurement on the real LXC (`scripts/scale_probe.py` in Mahoraga).

## Staying up

- **MongoDB restarts itself** if it stops (`restart: unless-stopped`).
- **It starts with the LXC.** Docker starts at boot (`bin/sdb install`), and so does the LXC (Proxmox:
  Options → Start at boot).
- **Before the apps, and after them on the way down.** Proxmox's start order: `db` first, a minute before
  the apps' LXC; at shutdown the reverse. An app that starts first anyway waits: its driver keeps trying
  for 10 seconds a query (Mahoraga's `serverSelectionTimeoutMS`), and connects as soon as MongoDB answers.
- **A health check every 30 seconds** (the image's). `bin/sdb up` waits for it; `bin/sdb status` shows it.
- **It shuts down cleanly**: a minute to write its cache to disk when the LXC reboots (`stop_grace_period`),
  where Docker's own default is 10 seconds.
- **Alerts reach you** through Uptime Kuma, already running. Each job tells a Push monitor "up", or
  "down" with why; a monitor that hears nothing for its interval goes down by itself (README, "Alerts",
  has the intervals):
  - **health**, every minute (`bin/sdb health`): down when MongoDB's check fails, a disk passes
    `SDB_DISK_ALERT` (85%), or the LXC goes quiet for 3 minutes;
  - and, when Kuma is on the LAN, a **MongoDB** monitor of its own, which connects the way the apps do;
  - with backups (Phase 2): **backup**, hourly, down when the dump fails, the backup disk refuses it, or a
    disk passes 85%; **drill**, Sundays, down when the newest backup does not restore with data in every
    collection; **copy**, down when a copy fails while the PC answers, or none has arrived for 3 days.

## Backups

**Phase 2: once Mahoraga runs here and its data is checked** (owner, 2026-11-05). Until then, nothing is
without a copy: Mahoraga's own nightly backup (`deploy/backup.timer`, kept 30 days in its LXC) reads
`MONGODB_URI`, so from the move it backs up server_db as it backed up Atlas; and Atlas stays as it was at
the move. With `RESTIC_REPOSITORY` empty, `bin/sdb` runs no backup and installs no backup timer.

From Phase 2: every database, users and their logins included: one `mongodump` every hour, written to a file, then
sent with restic, which encrypts before anything leaves the LXC and stores again only what changed.
Kept: every hour for 2 days, every day for 30, every month for a year. **Checked every Sunday**:
`bin/sdb drill` restores the newest into a throwaway MongoDB and fails unless every collection with
data now has data in the backup.

**Where they go: the backup disk first, then the PC.** The owner wants the data somewhere other than
the server, and has a PC on the LAN that is not always on. A backup cannot wait for a machine that may
be off, so the two have different jobs:

| | Setting | When | Survives | Restores in |
|---|---|---|---|---|
| **The LXC's backup disk** | `RESTIC_REPOSITORY=/srv/server-db-backups` | every hour, always: nothing it needs is ever off | a deleted or broken database, and a broken data disk when it is on another physical disk | minutes |
| **The PC** (the copy) | `SDB_COPY_REPOSITORY=sftp:backup-pc:/srv/server-db-copy` | every 15 minutes it is tried; when it answers, it gets every backup it is missing | the Proxmox host dying, with both of the LXC's disks | minutes, once a new LXC gets the backups back from it |

- **The PC being off is not a failure.** `bin/sdb copy` asks it first (ssh gives up in 10 seconds); if
  it does not answer, nothing is sent and nothing alerts. The next time it is on for a quarter of an hour,
  it receives every snapshot it missed, Mahoraga's archive too (proved by `tests/backup_test.sh`).
- **Hearing that it has been off too long.** Uptime Kuma's `copy` monitor hears only from a copy that
  arrived, and goes down when none has for its interval: 3 days, changed in Kuma, not here. A copy that
  starts and fails (the PC's disk full) alerts at once; a PC that answers ssh but has lost the folder
  looks like one that is off, and is heard of at 3 days.
- **What can be lost.** If the server dies, the PC holds everything up to the last time it was on: up
  to a day if it is on every day, up to 3 days before the alert says so. Leaving it on more, or one of
  the ways below, shortens that.
- **The same `RESTIC_PASSWORD` opens both**; lose it and no backup can be read. restic encrypts in the
  LXC, so the PC holds nothing readable without it.
- **Rebuilding from the PC.** A new LXC with the same settings and a new backup disk: `bin/sdb init`
  brings every backup back from the PC first (proved by the test), then `bin/sdb restore`.

**Not the PC alone.** As the only repository, every backup and every drill would fail while it is off,
and the alerts would cry wolf nightly. As the copy, it is tried until it answers.

**Ways to make the copy fresher or safer, later** (ROADMAP, "Later"):

| | Setting | What it changes | Costs |
|---|---|---|---|
| Wake-on-LAN: the LXC wakes the PC at night, copies, lets it sleep again | the PC's BIOS, and a few lines in `bin/sdb` | a copy every night, without leaving the PC on | nothing |
| A small machine that stays on (a Raspberry Pi with a USB disk, a NAS) instead of the PC | `sftp:…` to it | a copy within 15 minutes, always | ~€60–100 once, a few watts |
| Cloudflare R2 (or Backblaze B2, any S3) | `s3:https://ACCOUNT.r2.cloudflarestorage.com/server-db-backups` | survives the house, not just the server | free to 10 GB, then $0.015 per GB a month |
| A disk at another address, reached over SSH | `sftp:user@host:/backups/server-db` | survives the house | nothing |

**Measured 2026-11-03**, with 9,846 jobs (50 MB dumped): a backup took 1–2 seconds, and two took 13.5 MB
stored together. A month of Mahoraga at full size (7.1 GB of data) dumps to a few GB an hour, of which
restic stores only what changed.

**Optional, on the host:** Proxmox's own nightly backup of the whole `db` LXC, kept on the host. It brings
the machine back as it was, which is quicker after a broken upgrade; it does not replace the above.

**Files on the apps' LXC** are each app's to send: Mahoraga's job archive (`archive/`, xz files, the
only copy of a job once it leaves the database after its keep) goes to the backup disk nightly, with
restic in that LXC (ROADMAP, step 11), and on to the PC with every copy. Two jobs using the same
repository at once (that archive, the copy, an hourly prune) wait for each other rather than fail
(`--retry-lock`).

## Security

- **Logins are always on.** One administrator, for `bin/sdb` only; one login per app, for its own
  database only. Tested 2026-11-03: Mahoraga's login was refused another database; tested 2026-11-04:
  with the built-in settings, a write without a login is refused.
- **Never on the internet.** Published on the LXC's LAN address only, and not forwarded by the router.
- **Inside the LAN, traffic is not encrypted.** Logins use SCRAM, so a password never crosses the network
  as itself, but the data does. If guests or devices you do not control share 192.168.50.x, add TLS
  (ROADMAP, "Later"): a certificate made on the LXC, and `tls=true` in each app's string.
- **Passwords never appear on the LXC's command line.** The administrator's password stays inside the
  container's settings.
- **The PC is reached with a key, into an account for the copy only** (`sdbcopy`, its password locked),
  which owns one folder. Someone who took over the LXC could delete the copy; they could not read the PC's
  own files.
- **Settings live in `certificates/server_db.env`** (chmod 600, never in git). The restic password is the
  one secret whose loss loses every backup, so it goes in a password manager too.
- **The repository holds no secret and no data.** It goes to GitHub, private, and the LXC pulls it with a
  read-only deploy key; the passwords are in `certificates/` on the LXC only, and the data on its data disk.

## Moving Mahoraga from Atlas

About ten minutes, with the harvest and the notifier paused, never the site (ROADMAP, step 5).
1. `bin/sdb add-app mahoraga`, and keep the `MONGODB_URI` it prints.
2. A rehearsal with nothing paused: `bin/sdb import mahoraga`, with Atlas's string. It proves the string,
   that the LXC reaches Atlas, and how long the copy takes.
3. On the apps' LXC, stop the writers: `sudo systemctl stop harvester.timer` and
   `deploy/compose.sh stop notifier`.
4. `bin/sdb import mahoraga` again, replacing the rehearsal. It runs mongodump against Atlas and
   mongorestore here, inside the container, with Atlas's string kept off every command line. Then it
   **lists every collection on both sides, documents and indexes, and passes only if every one is the
   same**: that is what says all the data came across. Indexes come with the copy; `deploy/deploy.sh`
   applies any Mahoraga has added since.
5. Put the new `MONGODB_URI` in `certificates/server.env`, then run `deploy/deploy.sh`. It applies
   Mahoraga's indexes to the new database, and checks the site.
6. Start the timer and the notifier again. Leave Atlas untouched until Phase 2's first drill has passed,
   as the way back, then delete it.

## Decided by the owner, 2026-11-05

- **The address**: `192.168.50.229/24`.
- **An LXC like the apps'**: Debian 13, with MongoDB in Docker inside it (Decision 1).
- **Apps on MongoDB's own port**, each with its login: no API in front of it (Decision 4).
- **Host down is everything down**, apps and database together, and back together, the database first
  (Decision 5, Staying up).
- **Backups after Mahoraga runs here and its data is checked** (Phase 2): the LXC's backup disk first, and
  the copy on the PC on the LAN, whenever it is on (Backups).
- **Alerts**: Uptime Kuma, already running.

## For the owner to decide

1. **Phase 2: the PC's address**, reserved on the router, and whether it runs Linux (README, "The PC", is
   written for Linux).
2. **Whether the LXC gets a name** on the router (`SDB_HOSTNAME`).
3. **Mahoraga's own nightly backup** (`deploy/backup.timer`). Once server_db's backups have passed their
   first drill, it is a second mechanism for the same job: retire it, or keep it as a portable export.
