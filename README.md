# server_db

MongoDB for every app on the LAN: one server on Proxmox, reachable from any machine on 192.168.50.x,
each app in its own database with its own login, backed up every hour and each backup checked by
restoring it. Apps connect exactly as they did to Atlas, with a different `MONGODB_URI`. It costs
nothing a month. Why it is built this way: [DESIGN.md](DESIGN.md). The order to build it in, with a
check at each step: [ROADMAP.md](ROADMAP.md).

| File | What it is |
|---|---|
| `Dockerfile` | The image: MongoDB 8.0.34 with `mongod.conf` built in |
| `mongod.conf` | Its settings: a login always, zstd storage, slow queries logged |
| `compose.yml` | How it runs: the VM's LAN address, the data folder, the cache size |
| `bin/sdb` | Every operation |
| `server_db.env.example` | The settings to fill in, as `certificates/server_db.env` |
| `tests/backup_test.sh` | The backup chain, on any machine with restic |

Everything runs through one command, `bin/sdb`:

| Command | What it does |
|---|---|
| `bin/sdb init` | Makes the data folder and the backup repositories (once) |
| `bin/sdb up` | Builds the image, starts MongoDB or applies a change, and waits until it answers |
| `bin/sdb status` | Running?, version, each database's size, the disk, the newest backup and copy |
| `bin/sdb add-app NAME` | A database and a login for one app; prints its `MONGODB_URI` once |
| `bin/sdb shell [DB]` | MongoDB's shell, as the administrator |
| `bin/sdb backup` | Every database to the backup repository, then to its copy (hourly, by itself) |
| `bin/sdb drill` | Restores the newest backup into a throwaway copy and checks it (weekly, by itself) |
| `bin/sdb restore [ID]` | Puts a backup back over the live data, after asking |
| `sudo bin/sdb install` | The hourly and weekly timers, and Docker at boot |

## Setting it up

### 1. The VM (Proxmox)
- Create a VM named `db`: Ubuntu Server 24.04, 2 cores, 8 GB memory (4 GB at the least: DESIGN.md, "Speed").
  - Disks: a 16 GB system disk, a **100 GB data disk** on SSD/NVMe storage, and, if backups stay on this
    host, a **100 GB backup disk** on a different physical disk from the data disk.
  - Network: the LAN bridge, the one the other machines on 192.168.50.x are on.
  - Options → **Start at boot: yes**.
- Give it a fixed LAN address, e.g. `192.168.50.20`: a DHCP reservation on the router, or a static
  address in Ubuntu's installer. That address is `SDB_BIND`.
- Mount the data disk at `/srv/server-db`, and the backup disk, if any, at `/srv/server-db-backups`
  (`lsblk` shows which is which):
  ```bash
  sudo mkfs.ext4 /dev/sdb && sudo mkdir -p /srv/server-db
  echo '/dev/sdb /srv/server-db ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  sudo mkfs.ext4 /dev/sdc && sudo mkdir -p /srv/server-db-backups
  echo '/dev/sdc /srv/server-db-backups ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  sudo mount -a && sudo chown "$USER" /srv/server-db /srv/server-db-backups
  ```
- Install the tools, and let your account use Docker:
  ```bash
  sudo apt update && sudo apt install -y docker.io docker-compose-v2 restic git openssl curl
  sudo usermod -aG docker "$USER"     # then log out and back in
  ```
- On the router: **no port forward to 27017**. MongoDB is published on the VM's LAN address only.

### 2. Where backups go
Pick where every backup goes first (`RESTIC_REPOSITORY`) and, optionally, where each is copied to
(`SDB_OFFSITE_REPOSITORY`). The options and what each survives: [DESIGN.md, "Backups"](DESIGN.md#backups).
- **The backup disk** from step 1: `RESTIC_REPOSITORY=/srv/server-db-backups`. Nothing more to set up.
- **Another machine on the LAN, over SSH:** an account there that this VM can log into with a key
  (`ssh-keygen`, then `ssh-copy-id backup@192.168.50.30`), and
  `RESTIC_REPOSITORY=sftp:backup@192.168.50.30:/backups/server-db`.
- **Cloudflare R2** (free to 10 GB): R2 → **Create bucket** `server-db-backups`; R2 → **Manage API
  tokens** → "Object Read & Write", this bucket only. The Access Key ID and Secret are
  `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; your account ID goes in the `s3:` address.

### 3. Alerts (healthchecks.io, free)
- Sign up, and create two checks:
  - `backup`: period 1 hour, grace 30 minutes;
  - `drill`: period 1 week, grace 1 day.
- Their ping URLs are `SDB_PING_BACKUP` and `SDB_PING_DRILL`. It emails you when either reports a
  failure, or goes quiet.

### 4. The settings
```bash
git clone <this repository> ~/server_db && cd ~/server_db
mkdir -p certificates && cp server_db.env.example certificates/server_db.env && chmod 600 certificates/server_db.env
nano certificates/server_db.env
```
- Each line says what it is.
- Make the two passwords with the commands written beside them.
- **Put `RESTIC_PASSWORD` in your password manager too.** Without it, no backup can be read.

### 5. Start it
```bash
bin/sdb init             # the data folder, and the backup repositories
bin/sdb up               # builds the image: "server_db is up at 192.168.50.20:27017"
sudo bin/sdb install     # hourly backups, the Sunday drill, Docker at boot
bin/sdb backup           # the first backup now, rather than at the next hour
bin/sdb drill            # and prove it restores
bin/sdb status
```
From another machine on the LAN, `nc -zv 192.168.50.20 27017` connects.

### 6. An app's login
```bash
bin/sdb add-app mahoraga
```
- It prints `MONGODB_URI=…` and `MONGODB_DB=mahoraga`. Put them in that app's settings; for
  Mahoraga, that's `certificates/server.env`.
- The password is shown once. To change it later: `bin/sdb shell mahoraga`, then
  `db.changeUserPassword(...)`.
- Each app the same way: its own database, its own login, which cannot read any other app's.

Moving Mahoraga's data from Atlas: [DESIGN.md](DESIGN.md#moving-mahoraga-from-atlas).

## When something is wrong

- **An alert email.** Run `bin/sdb status`.
  - If a backup failed, `journalctl -u server-db-backup -n 50` says why, and which repository.
  - If the drill failed, `journalctl -u server-db-drill -n 80` lists every collection with its live
    count and its backup count.
- **An app is slow.** `docker compose -f compose.yml logs mongo | grep "Slow query"`: every query over
  200 ms, with how it ran.
- **Data deleted or broken.**
  1. Stop the apps that write.
  2. Run `bin/sdb restore` (the newest backup), or `bin/sdb restore <ID>` with an ID from the list it
     shows.
  3. Start the apps.
- **The VM is gone.**
  1. Build a new one with steps 1, 4 and 5, using the **same** `certificates/server_db.env`.
  2. Run `bin/sdb restore`. Backups are filed under one name (`server-db`), so the new VM finds them.
- **Looking around from a laptop on the LAN:** connect to `192.168.50.20:27017` with an app's login
  (MongoDB Compass, or `mongosh "$MONGODB_URI"`). Never open 27017 to the internet.

## What was tested

**2026-11-04, on a laptop:**
- `mongod.conf` with MongoDB 8.0.34 itself: a write without a login is refused; collections are stored
  with zstd; slow queries are logged over 200 ms.
- `compose.yml` passes Docker's own check, building from the `Dockerfile` and publishing on the LAN
  address only.
- `tests/backup_test.sh`, against real restic repositories: a backup reaches the first repository and
  its copy; a copy that cannot be reached makes the backup fail and say so; the next backup sends the
  copy what it missed; what is read back from the copy is what was dumped. 9 checks, all passing.
- Mahoraga at full size, 1.5 million jobs, on 2 cores with a 1.5 GB cache: DESIGN.md, "Speed".

**2026-11-03, on a laptop**, with `bin/sdb` and a stand-in for Docker running the same MongoDB:
`init`, `up`, `add-app` (and refusing a second one), `status`; backups (1–2 seconds each); the drill,
which fails when a collection with data is missing from the backup; a failed dump stores nothing and
alerts; a nearly full disk alerts; `restore` brings back deleted data; an app's login is refused
another database.

**Not run yet:** building and running the image with Docker, R2, and `sudo bin/sdb install`. ROADMAP
steps 3 to 5 do all three on the VM, and the first `bin/sdb drill` there proves the whole path.
