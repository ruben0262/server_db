# server_db: roadmap

From nothing to a database every app on the LAN uses, backed up, with each step checked before the
next. Run on the server unless a step says otherwise. Why each choice was made: [DESIGN.md](DESIGN.md).
The commands in detail: [README.md](README.md).

Tick a step when its **Check** passes. A step whose check fails is not done, however it looked.

## 0. Decide (15 minutes, no commands)

- [ ] **The VM's LAN address**, fixed: e.g. `192.168.50.20`. Reserve it on the router (DHCP reservation)
      or set it in the VM. It is `SDB_BIND`.
- [ ] **A name for it** (optional): e.g. `db.lan`, as a DNS entry on the router. It is `SDB_HOSTNAME`.
- [ ] **Where backups go first** (`RESTIC_REPOSITORY`), one of (DESIGN.md, "Backups"):
      - a second virtual disk on the VM, on a different physical disk of the Proxmox host from the data;
      - another machine on the LAN (a NAS, an old PC) over SSH;
      - an S3 bucket.
- [ ] **Where a copy goes** (`SDB_OFFSITE_REPOSITORY`, optional): somewhere that survives the house, e.g.
      Cloudflare R2 (free to 10 GB), or a disk at another address.
- [ ] **Alerts**: a free healthchecks.io account, or none (then nobody hears of a failed backup).

## 1. The VM (Proxmox, 20 minutes)

- [ ] Create VM `db`: Ubuntu Server 24.04, 2 cores, **8 GB memory** (4 at the least), a 16 GB system disk, a **100 GB data
      disk on SSD/NVMe**, and, if backups stay on the host, a **backup disk** on another physical disk.
      Network: the LAN bridge. Options → Start at boot: yes.
- [ ] Give it the address from step 0.
- [ ] Mount the data disk at `/srv/server-db` and the backup disk, if any, at `/srv/server-db-backups`
      (README, "The VM").
- [ ] `sudo apt install -y docker.io docker-compose-v2 restic git openssl curl` and
      `sudo usermod -aG docker "$USER"`, then log out and in.

**Check:** `docker run --rm hello-world` prints its greeting; `df -h /srv/server-db` shows the data disk.

## 2. The settings (10 minutes)

- [ ] `git clone` this folder to `~/server_db` (or copy it), then
      `mkdir -p certificates && cp server_db.env.example certificates/server_db.env && chmod 600 certificates/server_db.env`.
- [ ] Fill it in: `SDB_BIND`, `SDB_HOSTNAME`, `SDB_DATA`, `SDB_CACHE_GB`, the administrator's password,
      `RESTIC_REPOSITORY`, `SDB_OFFSITE_REPOSITORY`, `RESTIC_PASSWORD`, the alert links.
- [ ] Put `RESTIC_PASSWORD` in your password manager. Without it no backup can be read.

**Check:** `bin/sdb` prints its list of commands (it reads the settings first and stops if they are missing).

## 3. Start it (5 minutes)

- [ ] `bin/sdb init` makes the data folder and the backup repositories.
- [ ] `bin/sdb up` builds the image (Dockerfile: MongoDB 8.0.34 and mongod.conf) and starts it.
- [ ] `sudo bin/sdb install` installs the hourly backup, the Sunday drill, and Docker at boot.

**Check:** `bin/sdb up` ends with "server_db is up at …:27017"; `bin/sdb status` shows MongoDB 8.0.34 and
the data disk; `systemctl list-timers 'server-db-*'` lists both timers.

## 4. Reachable from the LAN, and only from it (10 minutes)

- [ ] From another machine on 192.168.50.x: `nc -zv 192.168.50.20 27017` connects.
- [ ] The router forwards nothing to port 27017 (its port-forwarding page).
- [ ] Reboot the VM once: `sudo reboot`, then `bin/sdb status` from it again.

**Check:** connects from the LAN; `bin/sdb status` says healthy after the reboot without anybody starting it.

## 5. The first backup and the first drill (10 minutes)

- [ ] `bin/sdb backup` sends a backup now rather than at the next hour.
- [ ] `bin/sdb drill` restores the newest one into a throwaway MongoDB and compares every collection.

**Check:** the backup says "backed up … in …s"; the drill says "drill passed"; `bin/sdb status` shows
the newest backup, and the newest copy if there is one. On the laptop, `tests/backup_test.sh` passes (it
proves the copy catches up after an hour it missed).

## 6. An app: Mahoraga (30 minutes, harvest paused, the site stays up)

- [ ] `bin/sdb add-app mahoraga` prints its `MONGODB_URI` and `MONGODB_DB`, once.
- [ ] Copy Atlas into it (DESIGN.md, "Moving Mahoraga from Atlas"): stop `harvester.timer` and the
      notifier, `mongodump` from Atlas into `mongorestore` here.
- [ ] Put the new `MONGODB_URI` in Mahoraga's `certificates/server.env`, then `deploy/deploy.sh`. It applies
      Mahoraga's indexes and checks the site answers.
- [ ] Start the timer and the notifier again. Leave Atlas as it is for a week: the way back.

**Check:** the site signs in and lists jobs; `bin/sdb status` shows `mahoraga` with its size; the next
hour's backup includes it (`bin/sdb drill` lists `mahoraga.*` collections).

## 6b. Mahoraga's archive, off the app VM (15 minutes)

Mahoraga moves every job older than its keep (15 days, Admin → Settings) out of the database into
compressed files in `archive/` on the app VM, every run, and they are kept for good. They are the only
copy of those jobs, so they go to the same backup repository, nightly. On the **app VM**:

- [ ] `sudo apt install -y restic`.
- [ ] `certificates/archive_backup.env` (chmod 600): the same `RESTIC_PASSWORD`, and a `RESTIC_REPOSITORY`
      this VM can reach: the db VM's backup disk over SSH
      (`sftp:USER@192.168.50.20:/srv/server-db-backups`, after `ssh-copy-id USER@192.168.50.20`), or the
      same bucket (`s3:…`, with its `AWS_*` keys).
- [ ] `crontab -e`, one line:
      `30 3 * * * cd ~/job-search-app && set -a && . certificates/archive_backup.env && restic backup archive --host mahoraga-archive --quiet`

**Check:** the next morning, `restic snapshots --host mahoraga-archive` (with the same settings loaded)
lists last night's; `restic ls latest --host mahoraga-archive | tail` shows yesterday's
`corpus-….jsonl.xz`.

## 7. Prove the speed at full size, on this server (40 minutes, nothing live touched)

The laptop's measurement (Mahoraga's CHANGELOG, 2026-11-04) ran on two cores and a 1.5 GB cache, like
this VM. Run it here to be sure:

- [ ] `bin/sdb add-app scale_probe` for a throwaway database.
- [ ] From Mahoraga's checkout on the app VM: `scripts/scale_probe.py build` then
      `scripts/scale_probe.py measure`, with `MONGODB_URI` set to the `scale_probe` login (the script
      refuses any database not named `scale_probe`).
- [ ] Drop it afterwards: `bin/sdb shell scale_probe`, then `db.dropDatabase()`.

**Check:** the busiest person's match under 2 s and the median under 0.5 s; a run's 1,800 new jobs
stored in under 30 s; a new word found everywhere in under 5 minutes. A number over its line goes back
to Mahoraga before step 8.

## 8. Keep everything (Mahoraga's `harvest-everything` branch)

- [ ] Merge the branch and deploy (Mahoraga's ROADMAP, Phase 8, items 27–31).
- [ ] Watch Admin → Corpus → "Jobs found by country" and `bin/sdb status` for a week.

**Check:** after a week, the data disk's growth per day is about what DESIGN.md, "Disk" says, and the
backups and drills have all passed (healthchecks.io shows no failure).

## 9. A second app (5 minutes each)

- [ ] `bin/sdb add-app NAME`, and its `MONGODB_URI` in that app's settings.

**Check:** the app connects, and its login cannot read `mahoraga` (DESIGN.md, "Many apps").

## Later, when there is a reason

- **A second machine** (another Proxmox node, a NAS that runs Docker): a replica set, so the database
  survives one machine (DESIGN.md, "One server now").
- **TLS inside the LAN**: if guests or devices you do not control share 192.168.50.x (DESIGN.md, "Security").
- **Upgrading MongoDB**: back up, change the `FROM` line in the Dockerfile, `bin/sdb up`, then `bin/sdb drill`.
