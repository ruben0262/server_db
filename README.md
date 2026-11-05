# server_db

MongoDB for every app on the LAN: one server on Proxmox at `192.168.50.20`, pulled from this repository
onto its LXC. Any machine on 192.168.50.x reaches it on MongoDB's own port, each app in its own database
with its own login, exactly as it reached Atlas, with a different `MONGODB_URI`. Watched by Uptime Kuma.
Backed up (Phase 2) every hour to the LXC's backup disk and copied to a PC on the LAN whenever it is on,
each backup checked by restoring it. It costs nothing a month. Why it is built this way:
[DESIGN.md](DESIGN.md). The order to build it in, with a check at each step: [ROADMAP.md](ROADMAP.md).

| File | What it is |
|---|---|
| `Dockerfile` | The image: MongoDB 8.0.34 with `mongod.conf` built in |
| `mongod.conf` | Its settings: a login always, zstd storage, slow queries logged |
| `compose.yml` | How it runs: the LXC's LAN address, the data folder, the cache size |
| `bin/sdb` | Every operation |
| `server_db.env.example` | The settings to fill in, as `certificates/server_db.env` |
| `tests/import_test.sh` | `bin/sdb import`, and Phase 1 without backups, on any machine |
| `tests/backup_test.sh` | The backup chain and its alerts, on any machine with restic |

Everything runs through one command, `bin/sdb`:

| Command | What it does |
|---|---|
| `bin/sdb init` | Makes the data folder, and the backup repositories once they are set (a rebuilt LXC gets its backups back from the copy) |
| `bin/sdb up` | Builds the image, starts MongoDB or applies a change, and waits until it answers |
| `bin/sdb status` | Running?, version, each database's size, the disks, the newest backup and copy |
| `bin/sdb add-app NAME` | A database and a login for one app; prints its `MONGODB_URI` once |
| `bin/sdb import NAME [FROM]` | Copies an app's database from another MongoDB (Atlas) into NAME here, and compares every collection's documents and indexes with the source's |
| `bin/sdb shell [DB]` | MongoDB's shell, as the administrator |
| `bin/sdb health` | MongoDB healthy and the disks not full, told to Uptime Kuma (every minute, by itself) |
| `bin/sdb backup` | Every database to the backup disk (hourly, by itself) |
| `bin/sdb copy` | Every backup the PC is missing, if it is on (every 15 minutes, by itself) |
| `bin/sdb drill` | Restores the newest backup into a throwaway MongoDB and checks it (weekly, by itself) |
| `bin/sdb restore [ID]` | Puts a backup back over the live data, after asking |
| `sudo bin/sdb install` | Docker at boot, and the timers for whatever is set up |

Until Phase 2 sets `RESTIC_REPOSITORY`, the backup commands say they are not set up yet and stop, and
`install` installs no backup timer.

## Setting it up (Phase 1)

### 1. The LXC (Proxmox)
A Proxmox container (LXC) named `db`, Debian 13, like the apps' LXC, with MongoDB in Docker inside it
(DESIGN.md, "Decision 1").

**The template.** Proxmox → the host → `local` storage → CT Templates → Templates → `debian-13-standard`
→ Download.

**The LXC.** Create CT, tab by tab; what is not listed stays as it is:

| Tab | Setting |
|---|---|
| General | Hostname `db`. **Unprivileged container ✓**, **Nesting ✓**. A root password, and your SSH public key if you like |
| Template | `debian-13-standard` |
| Disks | rootfs **16 GB**. Add → Mount Point: `mp0`, **100 GB on SSD/NVMe storage**, path **`/srv/server-db`**: the data |
| CPU | **2** cores |
| Memory | **8192** MB (4096 at the least: DESIGN.md, "Speed"); swap 1024 |
| Network | `eth0`, bridge `vmbr0` (the LAN), IPv4 **Static**: `192.168.50.20/24`, gateway the router, usually `192.168.50.1` |
| DNS | use host settings |

Leave "Start after created" off. Then on `db`:
- Options → **Features**: **keyctl ✓** and **nesting ✓**: what Docker inside it needs. If the apps' LXC
  has more for its Docker (Options → Features, and `/etc/pve/lxc/ID.conf` on the host), give `db` the
  same.
- Options → **Start at boot ✓**, **Start/Shutdown order `1`**, **Startup delay `60`**. On the apps'
  LXC: order `2`. After a power cut the database is up a minute before the apps, and at shutdown the apps
  stop first.

The backup disk is a second mount point, added in Phase 2 while the LXC runs.

**Its address.** From the laptop first, `ping -c 2 192.168.50.20` must get no answer: nothing else has it.
On the router, reserve `192.168.50.20` for the LXC's MAC address (`db` → Network → `eth0`), so it never
hands that address to another device.

**On the Proxmox host, once** (its shell): MongoDB checks `vm.max_map_count` at start and warns below
102400; the kernel is the host's, so it is set there. 262144 is the usual value, and harms no other guest:
```bash
echo 'vm.max_map_count = 262144' > /etc/sysctl.d/90-mongodb.conf && sysctl --system | grep max_map_count
```

**Start it, and in its console** (`db` → Start, then Console; log in as root):
```bash
apt update && apt full-upgrade -y
apt install -y sudo curl git openssl
timedatectl set-timezone Europe/Budapest     # yours: the Sunday drill and the logs use local time
adduser ruben                                # your account; the examples say ruben
usermod -aG sudo ruben
```

**From the laptop**, as that account: `ssh-copy-id ruben@192.168.50.20`, then `ssh ruben@192.168.50.20`.
- Docker, as on the apps' LXC, and your account allowed to use it:
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  exit                                       # and ssh in again: the docker group applies from the next login
  ```
  Then `docker run --rm hello-world` prints its greeting, and `docker compose version` answers.
- The data disk is already mounted, by Proxmox; it only needs to be yours:
  ```bash
  sudo chown "$USER": /srv/server-db && df -h /srv/server-db   # about 98G
  ```
- On the router: **no port forward to 27017**. MongoDB is published on the LXC's LAN address only.

### 2. From GitHub onto the LXC
The repository is `https://github.com/ruben0262/server_db.git`, public. Nothing secret is in it:
`certificates/` (the passwords) is never committed, and the data lives on the LXC's data disk.
```bash
git clone https://github.com/ruben0262/server_db.git ~/server_db && cd ~/server_db
mkdir -p certificates && cp server_db.env.example certificates/server_db.env && chmod 600 certificates/server_db.env
sed -i "s|^SDB_ROOT_PASSWORD=.*|SDB_ROOT_PASSWORD=$(openssl rand -hex 24)|" certificates/server_db.env
```
That is every Phase 1 setting but one, optional: `SDB_KUMA_HEALTH` (Alerts, below), with
`nano certificates/server_db.env`. The rest is already right for this LXC; the backup settings stay empty
until Phase 2. If the repository is ever made private, the LXC needs a read-only deploy key to pull it:
`ssh-keygen -t ed25519 -f ~/.ssh/github_server_db`, its `.pub` under GitHub → server_db → Settings →
Deploy keys, and the `git@github.com:ruben0262/server_db.git` address.

### 3. Alerts (Uptime Kuma)
In Uptime Kuma, **Add New Monitor** → type **Push**. Its **Push URL** (all of it) goes in the setting
beside it. Retries: 0; the interval already holds the grace.

| Monitor | Heartbeat interval | Setting | Goes down when |
|---|---|---|---|
| `server_db health` | 180 s | `SDB_KUMA_HEALTH` | MongoDB is unhealthy or stopped, a disk passes 85%, or the LXC has said nothing for 3 minutes |

If Uptime Kuma runs on the LAN, add one more: type **MongoDB**, connection string
`mongodb://192.168.50.20:27017`, interval 60 s. It connects the way the apps do and asks for a ping,
which needs no login. (Type **TCP Port**, host `192.168.50.20`, port `27017`, if yours has no MongoDB type.)

Phase 2 adds three more: Backups, below.

### 4. Start it
```bash
bin/sdb init             # the data folder
bin/sdb up               # builds the image: "server_db is up at 192.168.50.20:27017"
sudo bin/sdb install     # Docker at boot, and the health check every minute
bin/sdb status
```
From another machine on the LAN, `nc -zv 192.168.50.20 27017` connects.

### 5. An app's login
```bash
bin/sdb add-app mahoraga
```
- It prints `MONGODB_URI=…` and `MONGODB_DB=mahoraga`. Put them in that app's settings; for
  Mahoraga, that's `certificates/server.env`. That string is how the app reaches its data: its driver
  speaks to MongoDB's port directly, as it did to Atlas (DESIGN.md, "Decision 4").
- The password is shown once. To change it later: `bin/sdb shell mahoraga`, then
  `db.changeUserPassword(...)`.
- Each app the same way: its own database, its own login, which cannot read any other app's.

### 6. An app's data, from where it is now
```bash
bin/sdb import mahoraga            # the database is called mahoraga at the source too
bin/sdb import mahoraga job_search # or it is called job_search there
```
- It asks for the source's connection string (for Atlas, the `MONGODB_URI` the app uses now), without
  showing it, and keeps it off every command line.
- It lists the source first: a wrong string, an unreachable source, or a database name with nothing in it
  stops here, with nothing changed.
- If the database here already has collections, it asks before replacing them.
- After the copy it lists every collection side by side, documents and indexes, and ends "every
  collection arrived" only if all are the same. Stop the app's writers first (ROADMAP, step 5), or the
  numbers differ by what they wrote meanwhile; then run it again, it replaces.

Moving Mahoraga, step by step: ROADMAP, step 5.

### Updating server_db itself
```bash
cd ~/server_db && git pull --ff-only && bin/sdb up && sudo bin/sdb install
```
`up` rebuilds the image only if the Dockerfile or `mongod.conf` changed, and restarts MongoDB only then;
`install` rewrites the timers, in case they changed.

## Backups (Phase 2)

Once Mahoraga runs here (ROADMAP, Phase 2). Every backup goes first to the LXC's backup disk, every hour;
the PC gets a copy whenever it is on (DESIGN.md, "Backups").

### The backup disk
Proxmox: `db` → Resources → Add → Mount Point: `mp1`, 100 GB, path `/srv/server-db-backups`, on a
different physical disk from the data if the host has one. It can be added while the LXC runs. Then in it:
```bash
sudo chown "$USER": /srv/server-db-backups
sudo apt install -y restic       # Debian 13's is 0.18; Debian 12's 0.14 is too old (no --retry-lock)
```

### The PC that holds the copy
The PC is off much of the time, and that is fine: every 15 minutes the LXC tries it, and the first time it
answers it gets every backup it missed. It needs SSH, a folder with room for as much as the backup disk
holds, and a fixed address. These steps are for a Linux PC; a Windows PC can hold it too, with
different steps.

On the PC:
```bash
sudo apt install -y openssh-server
sudo adduser sdbcopy                       # an account for the copy and nothing else; a password for now
sudo mkdir -p /srv/server-db-copy && sudo chown sdbcopy: /srv/server-db-copy
```
On the router, reserve the PC's address too, e.g. `192.168.50.30`.

On the LXC, a key, and a name for the PC that holds its address and how to give up on it quickly:
```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
cat >> ~/.ssh/config <<'EOF'
Host backup-pc
  HostName 192.168.50.30
  User sdbcopy
  IdentityFile ~/.ssh/id_ed25519
  # An off PC is given up on in seconds, and one switched off during a copy within a minute.
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 4
EOF
ssh-copy-id -i ~/.ssh/id_ed25519 backup-pc   # the password from adduser, this once
ssh backup-pc true                           # asks nothing now: the copy can log in by itself
```
Then on the PC, `sudo passwd -l sdbcopy`: the LXC's key is the only way in.

### Their alerts
Three more Push monitors in Uptime Kuma, as in Alerts above:

| Monitor | Heartbeat interval | Setting | Goes down when |
|---|---|---|---|
| `server_db backup` | 5400 s (an hour and a half) | `SDB_KUMA_BACKUP` | a backup fails, a disk passes 85%, or none for an hour and a half |
| `server_db drill` | 691200 s (8 days) | `SDB_KUMA_DRILL` | the drill fails, or none for 8 days |
| `server_db copy` | 259200 s (3 days) | `SDB_KUMA_COPY` | a copy fails while the PC answers, or none has arrived for 3 days: the PC was off that long |

The copy's interval is how long the PC may stay off before you hear about it: make it what suits you.

### Start them
In `certificates/server_db.env`: `RESTIC_REPOSITORY=/srv/server-db-backups`,
`SDB_COPY_REPOSITORY=sftp:backup-pc:/srv/server-db-copy`, `RESTIC_PASSWORD` (`openssl rand -base64 36`),
and the three Push URLs. **Put `RESTIC_PASSWORD` in your password manager too.** Without it, no backup can
be read, on the LXC or on the PC. Then, with the PC on:
```bash
bin/sdb init             # the backup repositories: the backup disk's and the PC's
sudo bin/sdb install     # adds the hourly backup, the copy every 15 minutes, the Sunday drill
bin/sdb backup           # the first backup now, rather than at the next hour
bin/sdb copy             # and to the PC
bin/sdb drill            # and prove it restores
bin/sdb status
```

## When something is wrong

- **An alert from Uptime Kuma.** Its message says what; `bin/sdb status` shows the rest.
  - **health**: `bin/sdb status`, then `docker compose -f compose.yml logs --tail 50 mongo`.
  - **backup**: `journalctl -u server-db-backup -n 50` says why, and which repository.
  - **drill**: `journalctl -u server-db-drill -n 80` lists every collection with its live count and its
    backup count.
  - **copy**, quiet for 3 days: the PC has been off. Turn it on for a quarter of an hour; the next copy
    sends everything. If it was on, `journalctl -u server-db-copy -n 20` says why (it prints the first
    thing ssh or restic said), e.g. a changed address, or `ssh backup-pc true` asking for a password.
- **An app is slow.** `docker compose -f compose.yml logs mongo | grep "Slow query"`: every query over
  200 ms, with how it ran.
- **An import says DIFFERS.** The source's app was still writing: stop it, and `bin/sdb import` again.
  If it was stopped, the collections marked are the ones to look at, with `bin/sdb shell NAME` here and
  the source's own shell.
- **Data deleted or broken.**
  - Before Phase 2: Mahoraga's own nightly backup (`deploy/scripts/restore.py` in its LXC), or Atlas as it
    was at the move.
  - With backups: stop the apps that write; `bin/sdb restore` (the newest backup), or
    `bin/sdb restore <ID>` with an ID from the list it shows; start the apps.
- **The LXC is gone, or the whole server.**
  1. Build a new LXC with Phase 1's steps 1 and 2 (and, with backups, the backup disk, and its key in
     `sdbcopy`'s `~/.ssh/authorized_keys` on the PC), and the **same** `certificates/server_db.env`.
  2. With the PC on, `bin/sdb init`. If the backup disk is new, every backup comes back from the PC first.
  3. `bin/sdb up`, then `bin/sdb restore`. Backups are filed under one name (`server-db`), so the new LXC
     finds them.
- **Looking around from a laptop on the LAN:** connect to `192.168.50.20:27017` with an app's login
  (MongoDB Compass, or `mongosh "$MONGODB_URI"`). Never open 27017 to the internet.

## What was tested

**2026-11-05, on a laptop:**
- `tests/import_test.sh`, 24 checks, all passing, with Docker stood in for and `bin/sdb`'s own copy
  script run against stand-ins for mongodump and mongorestore. Before backups are set up, `init` makes the
  data folder, `backup` refuses and says why, `status` says so. `import` refuses a string that is not a
  MongoDB one, a stopped MongoDB, a source database with nothing in it, and a bad name, before copying
  anything; it restores into the right database as the administrator; it passes the source's string in
  the container's environment and a private file quoted for YAML, never on a command line, and the file
  is gone after; it asks before replacing, and `no` changes nothing; it fails, marking the collection,
  when one is a document short, missing an index, or missing; it reads a source database with another
  name; a copy that fails half way says so.
- `tests/backup_test.sh` (restic 0.18.1; Debian 13 installs 0.18, and ROADMAP step 10 runs it in
  the LXC), against real restic repositories, 43 checks, all passing. `init` with the PC off
  makes nothing and says so; with it on, it makes both repositories with the same chunking. A backup goes
  to the first repository only, and Uptime Kuma hears "up" at the Push URL with its own `?status=up…`
  removed; a copy sends it to the PC; with the PC off, backups go on, the copy exits 0, says why, and
  sends no alert; the PC back, one copy sends every hour it missed and Mahoraga's archive; `status` lists
  the newest of each in both, or says the PC is not reachable and when a copy last arrived; a copy that
  breaks while the PC answers alerts; a rebuilt LXC's `init` brings every backup back from the PC, and the
  next copy sends only the new hour; a failed dump stores nothing and alerts; health alerts when MongoDB
  is unhealthy or stopped; a disk past its alert line alerts from both.
- The timers `install` writes pass `systemd-analyze verify`; with Phase 1's settings it installs no
  backup timer. `compose.yml` passes Docker's own check with the example settings.

**2026-11-04, on a laptop:**
- `mongod.conf` with MongoDB 8.0.34 itself: a write without a login is refused; collections are stored
  with zstd; slow queries are logged over 200 ms.
- `compose.yml` passes Docker's own check, building from the `Dockerfile` and publishing on the LAN
  address only.
- Mahoraga at full size, 1.5 million jobs, on 2 cores with a 1.5 GB cache: DESIGN.md, "Speed".

**2026-11-03, on a laptop**, with `bin/sdb` and a stand-in for Docker running the same MongoDB:
`init`, `up`, `add-app` (and refusing a second one), `status`; backups (1–2 seconds each); the drill,
which fails when a collection with data is missing from the backup; a failed dump stores nothing and
alerts; a nearly full disk alerts; `restore` brings back deleted data; an app's login is refused
another database.

**Not run yet:** building and running the image with Docker; `bin/sdb import` with the real mongodump,
mongorestore and mongosh, against Atlas; `sudo bin/sdb install`; the real Uptime Kuma. ROADMAP steps 3
to 5 do all of them on the LXC, and step 5's import, comparing every collection, proves the copy.
Phase 2's SSH to the real PC and the drill: steps 8 to 10.
