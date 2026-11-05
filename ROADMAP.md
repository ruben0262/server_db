# server_db: roadmap

From nothing to a database every app on the LAN uses, with each step checked before the next. Three
phases: **1** the LXC, from this repository, and Mahoraga's data moved onto it and checked; **2** backups,
once that works; **3** full size, and more apps. Run in the `db` LXC unless a step says otherwise. Why each
choice was made: [DESIGN.md](DESIGN.md). The commands in detail: [README.md](README.md).

Tick a step when its **Check** passes. A step whose check fails is not done, however it looked.

# Phase 1: the database, and Mahoraga on it

## 0. Decide

- [x] **The LXC's LAN address**: **`192.168.50.229/24`**, gateway the router. Set in the LXC, and reserved on
      the router. It is `SDB_BIND`.
- [x] **An LXC like the apps'**: Debian 13, with MongoDB in Docker inside it (DESIGN.md, "Decision 1").
- [x] **Apps reach it on MongoDB's own port**, `192.168.50.229:27017`, with their own login: no API in
      front of it (DESIGN.md, "Decision 4").
- [x] **Alerts**: Uptime Kuma, already running.
- [x] **Backups after Mahoraga runs here** (Phase 2). Until then Mahoraga's own nightly backup keeps
      running, against server_db, and Atlas stays as it was at the move.
- [ ] **A name for the LXC** (optional): e.g. `db.lan`, as a DNS entry on the router. It is `SDB_HOSTNAME`.

## 1. The LXC (Proxmox, 20 minutes)

- [x] Create CT `db` from `debian-13-standard` (README, "The LXC", has every field): unprivileged, 2
      cores, **8 GB memory** (4 at the least), a 16 GB root disk, and a mount point `mp0` at
      `/srv/server-db`, **100 GB on SSD/NVMe**. Network: the LAN bridge, static `192.168.50.229/24`, gateway
      the router.
- [x] Options → Features: **keyctl** and **nesting**, as on the apps' LXC; Start at boot; **Start/Shutdown
      order 1, startup delay 60**. On the apps' LXC: order 2, so after a power cut the database is up
      before the apps, and the apps stop first.
- [x] Reserve `192.168.50.229` on the router for the LXC's MAC address.
- [x] On the Proxmox host: `vm.max_map_count = 262144`.
- [x] In the LXC, as root: `apt install -y sudo curl git openssl`, your account in the `sudo` group. As
      that account: Docker (`curl -fsSL https://get.docker.com | sudo sh`), and the `docker` group, then
      log out and in. `sudo chown "$USER": /srv/server-db`.

**Check:** `ip -br addr` shows `192.168.50.229/24`; `docker run --rm hello-world` prints its greeting;
`docker compose version` answers; `df -h /srv/server-db` shows the 100 GB mount point; on the host,
`sysctl vm.max_map_count` says 262144.

## 2. From GitHub onto the LXC (10 minutes)

- [x] `git clone https://github.com/ruben0262/server_db.git ~/server_db` (public: no password and no data
      is in it; `certificates/` never goes in git, and the data lives on the LXC's data disk).
- [x] `certificates/server_db.env` from the example, with a new `SDB_ROOT_PASSWORD` (README, "From GitHub
      onto the LXC"). Everything else in Phase 1 is already right for this LXC.
- [x] In Uptime Kuma, a Push monitor `server_db health`, heartbeat interval 180 s; its Push URL is
      `SDB_KUMA_HEALTH`.

**Check:** `git -C ~/server_db pull --ff-only` says "Already up to date"; `bin/sdb` prints its list of
commands (it reads the settings first and stops if they are missing).

## 3. Start it (5 minutes)

- [x] `bin/sdb init` makes the data folder.
- [x] `bin/sdb up` builds the image (Dockerfile: MongoDB 8.0.34 and mongod.conf) and starts it.
- [x] `sudo bin/sdb install`: Docker at boot, and the health check every minute.

**Check:** `bin/sdb up` ends with "server_db is up at 192.168.50.229:27017"; `bin/sdb status` shows MongoDB
8.0.34 and the data disk; within three minutes, Uptime Kuma's `server_db health` is up.

## 4. Reachable from the LAN, and only from it (10 minutes)

- [x] From the apps' LXC: `nc -zv 192.168.50.229 27017` connects.
- [ ] If Uptime Kuma runs on the LAN, a monitor of type MongoDB on `mongodb://192.168.50.229:27017`
      (README, "Alerts").
- [ ] The router forwards nothing to port 27017 (its port-forwarding page).
- [ ] Reboot the LXC once: `sudo reboot`, then `bin/sdb status` from it again.

**Check:** connects from the LAN; `bin/sdb status` says healthy after the reboot without anybody starting
it; Uptime Kuma's health monitor is up again within three minutes of the reboot.

## 5. Mahoraga: from Atlas to here (30 minutes, harvest paused, the site stays up)

- [x] `bin/sdb add-app mahoraga` prints its `MONGODB_URI` and `MONGODB_DB`, once. Keep them.
- [x] A rehearsal, nothing paused: `bin/sdb import mahoraga`, and paste Atlas's `MONGODB_URI` (the one in
      Mahoraga's `certificates/server.env` now). It proves the string, that this LXC reaches Atlas (it
      leaves from the same public address as the apps' LXC, which Atlas already lets in), and how long the
      copy takes. Here the counts may differ by what Mahoraga wrote meanwhile.
- [x] On the apps' LXC, stop what writes: `sudo systemctl stop harvester.timer` and
      `deploy/compose.sh stop notifier`, and let a harvest that is running finish
      (`systemctl status harvester.service` says inactive).
- [x] `bin/sdb import mahoraga` again, and `yes` to replace the rehearsal. It compares every collection,
      documents and indexes, with Atlas's.
- [x] Put the new `MONGODB_URI` in Mahoraga's `certificates/server.env`, then `deploy/deploy.sh`. It applies
      Mahoraga's indexes and checks the site answers.
- [x] Start the timer and the notifier again. Leave Atlas as it is: the way back, and the copy of the data
      as it was at the move until Phase 2.

**Check:** the import ends "every collection arrived: … collections, … documents, and their indexes",
with no collection marked DIFFERS; the site signs in and lists jobs; after the next harvest, `bin/sdb
status` shows `mahoraga` larger than before it.

## 6. A week on it

- [ ] Watch Uptime Kuma, `bin/sdb status`, and the slow-query log
      (`docker compose -f compose.yml logs mongo | grep "Slow query"`).
- [ ] Mahoraga's own nightly backup (`deploy/backup.timer`) now reads from here: the next morning, a new
      file in `~/backups` on the apps' LXC. Until Phase 2, that is the backup.

**Check:** a week with no alert in Uptime Kuma, and a new file from Mahoraga's nightly backup each morning.

# Phase 2: backups

## 7. The backup disk (15 minutes)

- [ ] Proxmox: `db` → Resources → Add → Mount Point: `mp1`, 100 GB, path `/srv/server-db-backups`, on a
      different physical disk from the data if the host has one. It can be added while the LXC runs.
- [ ] `sudo chown "$USER": /srv/server-db-backups`, and `sudo apt install -y restic` (README, "The backup
      disk").

**Check:** `df -h /srv/server-db-backups` shows it.

## 8. The PC that holds the copy (15 minutes, the PC on)

- [ ] **Its address**, reserved on the router: e.g. `192.168.50.30`. README, "The PC", is written for a
      Linux PC.
- [ ] On the PC: `openssh-server`, an account `sdbcopy`, and `/srv/server-db-copy` it owns.
- [ ] On the LXC: a key, the `backup-pc` entry in `~/.ssh/config`, `ssh-copy-id backup-pc`.
- [ ] On the PC: `sudo passwd -l sdbcopy`.

**Check:** on the LXC, `ssh backup-pc true` returns at once and asks nothing. With the PC off,
`ssh backup-pc true` fails within 10 seconds.

## 9. The settings, the alerts, the timers (15 minutes, the PC on)

- [ ] In Uptime Kuma, three more Push monitors: `server_db backup`, `drill`, `copy`, with the intervals in
      README, "Alerts".
- [ ] In `certificates/server_db.env`: `RESTIC_REPOSITORY=/srv/server-db-backups`,
      `SDB_COPY_REPOSITORY=sftp:backup-pc:/srv/server-db-copy`, `RESTIC_PASSWORD`
      (`openssl rand -base64 36`), the three Push URLs.
- [ ] Put `RESTIC_PASSWORD` in your password manager. Without it no backup can be read.
- [ ] `bin/sdb init` makes both backup repositories; `sudo bin/sdb install` adds the hourly backup, the
      copy every 15 minutes, and the Sunday drill.

**Check:** `systemctl list-timers 'server-db-*'` lists four timers.

## 10. The first backup, copy and drill (15 minutes, the PC on)

- [ ] `bin/sdb backup` sends a backup now rather than at the next hour.
- [ ] `bin/sdb copy` sends it to the PC.
- [ ] `bin/sdb drill` restores the newest one into a throwaway MongoDB and compares every collection.
- [ ] The PC off: switch it off for an hour, then on again for a quarter of an hour.

**Check:** the backup says "backed up … in …s"; the copy says "copied"; the drill says "drill passed" and
lists `mahoraga.*` collections; Uptime Kuma shows all four `server_db` monitors up, with nothing gone down
while the PC was off; after it was back on, `bin/sdb status` shows the same newest backup on the backup
disk and in the copy. On the laptop, `tests/backup_test.sh` passes.

## 11. Mahoraga's archive, off the apps' LXC (15 minutes)

Mahoraga moves every job older than its keep (15 days, Admin → Settings) out of the database into
compressed files in `archive/` on the apps' LXC, every run, and they are kept for good. They are the only
copy of those jobs, so they go to the same backup repository, nightly, and from there to the PC with
every copy. On **the apps' LXC**:

- [ ] `sudo apt install -y restic`.
- [ ] `ssh-keygen -t ed25519` if it has no key, then `ssh-copy-id USER@192.168.50.229` (your account on
      the db LXC).
- [ ] `certificates/archive_backup.env` (chmod 600): the same `RESTIC_PASSWORD`, and
      `RESTIC_REPOSITORY=sftp:USER@192.168.50.229:/srv/server-db-backups`.
- [ ] `crontab -e`, one line (it waits, rather than fails, if the db LXC is pruning at that moment):
      `30 3 * * * cd ~/job-search-app && set -a && . certificates/archive_backup.env && restic backup archive --host mahoraga-archive --retry-lock 30m --quiet`

**Check:** the next morning, `restic snapshots --host mahoraga-archive` (with the same settings loaded)
lists last night's; `restic ls latest --host mahoraga-archive | tail` shows yesterday's
`corpus-….jsonl.xz`; on the db LXC, `bin/sdb status` lists `mahoraga-archive` under the backups and,
once the PC has been on, the copy.

## 12. Atlas, and Mahoraga's own backup

- [ ] Once step 10's drill has passed: delete the Atlas cluster, or keep it a while longer.
- [ ] Mahoraga's own nightly backup: retire it, or keep it as a portable export (DESIGN.md, "For the
      owner to decide").

# Phase 3: full size, and more apps

## 13. Prove the speed at full size, on this server (40 minutes, at a quiet time)

The laptop's measurement (Mahoraga's CHANGELOG, 2026-11-04) ran on two cores with a 1.5 GB and a 3.5 GB
cache; this LXC has two cores and 8 GB. Run it here to be sure. It writes ~7 GB into this server and pushes
Mahoraga's own jobs out of the cache for a while, so the site is slower until it ends.

- [ ] On the db LXC: `bin/sdb add-app scale_probe`, for a throwaway database. Keep the `MONGODB_URI` it
      prints.
- [ ] On the apps' LXC, in Mahoraga's checkout, with the harvester's own image (the `scripts/` folder
      mounted into it; the script refuses any database but `scale_probe`, and only reads Mahoraga's jobs,
      to copy them):
      ```bash
      cd ~/job-search-app && git pull --ff-only && deploy/compose.sh build harvester
      PROBE_URI='…'                                        # what add-app printed for scale_probe
      set -a && . certificates/server.env && set +a        # Mahoraga's own MONGODB_URI, to copy jobs from
      probe() { deploy/compose.sh run --rm --no-deps -v "$PWD/scripts:/app/scripts:ro" --entrypoint python \
                  -e MONGODB_URI="$PROBE_URI" -e SOURCE_URI="$MONGODB_URI" -e SOURCE_DB=mahoraga \
                  harvester scripts/scale_probe.py "$@"; }
      probe build      # ~11 minutes: 1.5 million jobs, 30 days, 300 people
      probe measure    # ~25 minutes: the Jobs page for everybody, two new words, a run's new jobs
      ```
- [ ] Drop it afterwards, on the db LXC: `bin/sdb shell scale_probe`, then `db.dropDatabase()` and
      `db.dropUser('scale_probe')`.

**Check:** the busiest person's match under 2 s and the median under 0.5 s; a run's 1,800 new jobs
stored in under 30 s; a new word found everywhere in under 5 minutes. A number over its line goes back
to Mahoraga before step 14.

## 14. Keep everything (Mahoraga's `harvest-everything` branch)

- [ ] Merge the branch and deploy (Mahoraga's ROADMAP, Phase 8, items 27–31).
- [ ] Watch Admin → Corpus → "Jobs found by country" and `bin/sdb status` for a week.

**Check:** after a week, the data disk's growth per day is about what DESIGN.md, "Disk" says, and the
backups, copies and drills have all passed (Uptime Kuma shows no failure).

## 15. A second app (5 minutes each)

- [ ] `bin/sdb add-app NAME`, and its `MONGODB_URI` in that app's settings. Data it has elsewhere:
      `bin/sdb import NAME`.

**Check:** the app connects, and its login cannot read `mahoraga` (DESIGN.md, "Many apps").

## Later, when there is a reason

- **A copy off the premises too**: the PC is in the same house as the server. Cloudflare R2 (free to
  10 GB) or a disk at another address, as the copy instead of the PC or beside it (DESIGN.md, "Backups").
- **The PC woken for its copy** (Wake-on-LAN), or a small always-on machine instead of it, if the PC is off
  for longer than the copy's alert allows (DESIGN.md, "Backups").
- **A second machine** (another Proxmox node, a NAS that runs Docker): a replica set, so the database
  survives one machine (DESIGN.md, "One server now").
- **TLS inside the LAN**: if guests or devices you do not control share 192.168.50.x (DESIGN.md, "Security").
- **Upgrading MongoDB**: back up, change the `FROM` line in the Dockerfile, `bin/sdb up`, then `bin/sdb drill`.
- **The host on Linux 7.0.14 or later** (`uname -r`): remove the `GLIBC_TUNABLES` line from the Dockerfile,
  `bin/sdb up`, and MongoDB's allocator uses its per-CPU caches again (DESIGN.md, "Decision 1").
