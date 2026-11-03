# server_db

MongoDB for every app on the Proxmox server: always on, backed up every hour off the machine, and
each backup checked by restoring it. Apps connect exactly as they did to Atlas, with a different
`MONGODB_URI`. Why it is built this way: [DESIGN.md](DESIGN.md).

Everything runs through one command, `bin/sdb`:

| Command | What it does |
|---|---|
| `bin/sdb init` | Makes the data folder and the backup repository (once) |
| `bin/sdb up` | Starts MongoDB, or applies a change, and waits until it answers |
| `bin/sdb status` | Running?, version, each database's size, the disk, the newest backup |
| `bin/sdb add-app NAME` | A database and a login for one app; prints its `MONGODB_URI` once |
| `bin/sdb shell [DB]` | MongoDB's shell, as the administrator |
| `bin/sdb backup` | Every database, off-site (hourly, by itself) |
| `bin/sdb drill` | Restores the newest backup into a throwaway copy and checks it (weekly, by itself) |
| `bin/sdb restore [ID]` | Puts a backup back over the live data, after asking |
| `sudo bin/sdb install` | The hourly and weekly timers, and Docker at boot |

## Setting it up

### 1. The VM (Proxmox)
- Create a VM named `db`: Ubuntu Server 24.04, 2 cores, 4 GB memory.
  - Disks: a 16 GB system disk, and a second **100 GB data disk** on SSD/NVMe storage.
  - Options → **Start at boot: yes**.
  - Network: the same bridge as the apps' VM.
  - In Ubuntu's installer, give it a fixed address on that bridge, e.g. `10.10.10.20`. That
    address is `SDB_BIND`.
- Mount the data disk at `/srv/server-db`:
  ```bash
  sudo mkfs.ext4 /dev/sdb && sudo mkdir -p /srv/server-db
  echo '/dev/sdb /srv/server-db ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab && sudo mount -a
  sudo chown "$USER" /srv/server-db
  ```
- Install the tools, and let your account use Docker:
  ```bash
  sudo apt update && sudo apt install -y docker.io docker-compose-v2 restic git openssl curl
  sudo usermod -aG docker "$USER"     # then log out and back in
  ```
- Firewall: SSH, and MongoDB from the apps' VM only (replace its address):
  ```bash
  sudo ufw allow OpenSSH && sudo ufw allow from 10.10.10.10 to any port 27017 proto tcp && sudo ufw enable
  ```

### 2. Somewhere off the machine for backups (Cloudflare R2)
- Cloudflare dashboard → R2 → **Create bucket**, named `server-db-backups`.
- R2 → **Manage API tokens** → Create: "Object Read & Write", this bucket only. Keep the Access Key
  ID and Secret: they are `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
- Your account ID, from the R2 overview page, goes in `RESTIC_REPOSITORY`.

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
bin/sdb init             # the data folder, and the backup repository in R2
bin/sdb up               # "server_db is up at 10.10.10.20:27017"
sudo bin/sdb install     # hourly backups, the Sunday drill, Docker at boot
bin/sdb backup           # the first backup now, rather than at the next hour
bin/sdb drill            # and prove it restores
bin/sdb status
```

### 6. An app's login
```bash
bin/sdb add-app mahoraga
```
- It prints `MONGODB_URI=…` and `MONGODB_DB=mahoraga`. Put them in that app's settings; for
  Mahoraga, that's `certificates/server.env`.
- The password is shown once. To change it later: `bin/sdb shell mahoraga`, then
  `db.changeUserPassword(...)`.

Moving Mahoraga's data from Atlas: [DESIGN.md](DESIGN.md#moving-mahoraga-from-atlas).

## When something is wrong

- **An alert email.** Run `bin/sdb status`.
  - If a backup failed, `journalctl -u server-db-backup -n 50` says why.
  - If the drill failed, `journalctl -u server-db-drill -n 80` lists every collection with its live
    count and its backup count.
- **Data deleted or broken.**
  1. Stop the apps that write.
  2. Run `bin/sdb restore` (the newest backup), or `bin/sdb restore <ID>` with an ID from the list it
     shows.
  3. Start the apps.
- **The VM is gone.**
  1. Build a new one with steps 1, 4 and 5, using the **same** `certificates/server_db.env`.
  2. Run `bin/sdb restore`. Backups are filed under one name (`server-db`), so the new VM finds them.
- **Laptop access**, to look around: `ssh -L 27017:10.10.10.20:27017 db`, then connect to
  `localhost:27017` with an app's login. Never open 27017 to the internet.

## What was tested (2026-11-03)

On a laptop, with `bin/sdb` itself, against MongoDB 8.0.34, restic and a local copy of Mahoraga's
data (9,846 jobs). Docker was replaced by a stand-in that runs the same MongoDB locally, because
Docker cannot run there:
- **Basics:** `init`, `up`, `add-app` (and refusing a second one), `status`.
- **Backups:** two backups, 1–2 seconds each, taking 13.5 MB stored together.
- **Drill:** passes; it **fails (exit 1, alert sent)** when a collection with data is missing from
  the newest backup.
- **A failed dump** stores nothing, and alerts.
- **A nearly full disk** alerts.
- **`restore`** brings back deleted data.
- **An app's login** can write, index and set rules in its own database, and is refused another.
- `compose.yml` passes Docker's own check.

**Not run yet:** the real container, R2, and `sudo bin/sdb install`. Step 5 does all three on the
VM, and the first `bin/sdb drill` there proves the whole path.
