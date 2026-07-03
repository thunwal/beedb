# beedb

PostgreSQL 18 + PostGIS 3.6 database server, Dockerized and managed as code.

---

## Overview

Bringing up beedb on a fresh VM is a three-phase workflow:

1. **Prepare the VM** — run `vm-setup.sh`. See [First-time VM setup](#first-time-vm-setup).
2. **Start the database container** — configure `.env`, run `docker compose up -d`. See [Starting the database](#starting-the-database).
3. **Populate the database** — restore from a Dropbox backup (see [Backup and restore databases](#backup-and-restore-databases)) or migrate from an old server (see [Migrating the databases to a new server](#migrating-the-databases-to-a-new-server)). Skip if starting with an empty database.

The remaining chapters cover day-to-day operations: remote access, deploying
code changes, and the ongoing backup / restore workflow.

---

## How remote access works

beedb runs inside Docker on the VM with **no ports exposed to the internet
except SSH (22)**. PostgreSQL binds to loopback only (`127.0.0.1:5432:5432` in
`docker-compose.yml`) and `ufw` blocks everything except SSH. Any remote
access — shell, database, or the outbound Dropbox upload — either goes
through the VM's SSH daemon or is initiated by the VM itself over HTTPS.

### The main SSH key

A single self-generated RSA key, `beekey_openssh2`, is written to the ubuntu
user's `authorized_keys` by `vm-setup.sh`. It serves both purposes:

| Purpose | How |
|---|---|
| Shell access to the VM | Normal SSH login |
| PostgreSQL access | SSH forwards local port 5432 to the container |

### Shell into the VM

```bash
ssh ubuntu@<VM_IP> -i <PATH_TO>/beekey_openssh2
```

This is what later chapters mean when they say "SSH into the VM".

### Connect to PostgreSQL through the tunnel

PostgreSQL has no SSH daemon of its own. When you open a tunnel, your local
client connects to the VM on port 22 and SSH forwards traffic on your local
port 5432 through Docker's internal network to the database. From any local
tool it then looks like PostgreSQL is running on your own machine.

Open the tunnel in the background:

```bash
ssh -L 5432:localhost:5432 -Nf ubuntu@<VM_IP> \
    -i <PATH_TO>/beekey_openssh2
```

Then connect exactly as if PostgreSQL were running locally:

```bash
psql -h localhost -U postgres -d beedb
```

### Optional: `~/.ssh/config` shortcut

Add this block on your local machine to avoid typing the full command every time:

```sshconfig
Host beedb
    HostName      <VM_IP>
    User          ubuntu
    IdentityFile  <PATH_TO>/beekey_openssh2

Host beedb-tunnel
    HostName      <VM_IP>
    User          ubuntu
    IdentityFile  <PATH_TO>/beekey_openssh2
    LocalForward  5432 localhost:5432
```

Then:
```bash
ssh beedb              # shell on the VM
ssh -Nf beedb-tunnel   # open the DB tunnel in the background
```

### Git and Dropbox

- **Git:** the repository is public, so the VM uses HTTPS with no credentials
  — no deploy key needed.
- **Dropbox:** the backup and restore scripts talk to Dropbox over HTTPS using
  an OAuth 2 refresh token stored in `.env`. Independent of SSH.

### Optional SSH key for the DB migration

A **second SSH key** — `beedb_migration` — is used only during a one-off
migration from an old server. See
[Migrating the databases to a new server](#migrating-the-databases-to-a-new-server);
it has no ongoing role after migration finishes and can be deleted afterwards.

---

## First-time VM setup

All setup runs directly from the cloned repository — no file copying needed.

### 1. Clone the repo on the VM

SSH into the VM (see [How remote access works](#how-remote-access-works)), then clone:

```bash
git clone https://github.com/thunwal/beedb.git beedb
```

### 2. Run the setup script

```bash
cd beedb
sudo bash vm-setup.sh
```

This will:
- Disable password authentication and root SSH login
- Configure `ufw` to allow port 22 only — port 5432 is never exposed
- Install Docker and Docker Compose

---

## Starting the database

On the VM, inside the beedb directory:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

The `.env` file holds three PostgreSQL settings that the container reads on first start
to initialise the database:

| Variable | What it is | Default |
|---|---|---|
| `POSTGRES_USER` | The PostgreSQL superuser (equivalent to the built-in `postgres` admin) | `postgres` |
| `POSTGRES_PASSWORD` | The password for that superuser | *(set this to something strong)* |
| `POSTGRES_DB` | The name of the database created on first start | `postgres` |

These are **database credentials only** — they have nothing to do with your SSH key or
the Linux `ubuntu` user on the VM. You use them whenever you connect to PostgreSQL, e.g.
`psql -h localhost -U postgres -d beedb` will prompt for `POSTGRES_PASSWORD`.

The username (`postgres`) and database name (`beedb`) can be left as-is.
**Change `POSTGRES_PASSWORD`** to something strong — it is your only defence if the SSH
tunnel or firewall were ever misconfigured.

These values are set once. If you change them after the container has started, you must
also update them inside the database manually, or delete the data volume and start fresh.

When you configured the .env file, start the docker container:

```bash
docker compose up -d
```

---

## Deploying changes to the VM

After pushing changes from your local machine, they need to be pulled and applied on the VM.

SSH into the VM (see [How remote access works](#how-remote-access-works)), then:

```bash
cd beedb
git pull
docker compose up -d
```

`docker compose up -d` is safe to run at any time — it only recreates the container if
its configuration actually changed. The database volume is never touched.

### What each type of change requires

| What changed | Action needed |
|---|---|
| `docker-compose.yml` or `.env` | `git pull && docker compose up -d` |
| `scripts/*` | `git pull` — the updated version is picked up next time the script runs (cron for `backup.sh`, ad-hoc for the others) |
| `vm-setup.sh` | Nothing — only re-run when provisioning a new VM |
| `init/*.sql` | **Not applied automatically** — see note below |

### `init/` SQL files are only executed once

Docker runs the scripts in `init/` exactly once: when the database volume is first
created. They are not re-run on restart or after a `git pull`.

To apply a change to an `init/` file after the database already exists, run the SQL
directly:

```bash
# On the VM:
docker compose exec db psql -U postgres -d beedb -f /docker-entrypoint-initdb.d/01_extensions.sql
```

Because all statements use `IF NOT EXISTS`, re-running the file is safe.

---

## Backup and restore databases

`scripts/backup.sh` dumps the database, uploads the dump to Dropbox, applies a
retention policy on Dropbox, keeps only the most recent dump locally, and mails
the outcome via `ssmtp`. It is designed to run daily from cron.

### One-off usage

```bash
# Create a timestamped dump in ./backups/, upload it, and rotate old files
bash scripts/backup.sh

# Restore from a local dump file
bash scripts/restore.sh backups/beedb_20260510T120000.dump
```

### Restore from a Dropbox backup

For disaster recovery (fresh VM, corrupted data, or rolling back to an earlier
snapshot), `scripts/restore_from_dropbox.sh` fetches a dump from Dropbox and
pipes it into `pg_restore`:

```bash
# Restore the most recent backup
bash scripts/restore_from_dropbox.sh

# Or restore a specific file
bash scripts/restore_from_dropbox.sh beedb_20260703T013000.dump
```

Prerequisites: the container is running (`docker compose up -d`), and `.env`
holds the same Dropbox credentials the backup script uses.

If you'd rather grab the file by hand, download it via the Dropbox web UI,
`scp` it into `~/beedb/backups/` on the VM, and run
`bash scripts/restore.sh backups/<file>.dump`.

### Retention on Dropbox

- Every backup for the last 14 days (daily)
- The Monday backup for the last 60 days (weekly, ~2 months)
- The first-Monday-of-month backup for the last 365 days (monthly, ~1 year)

Anything else in `DROPBOX_FOLDER` that matches `beedb_YYYYMMDDTHHMMSS.dump` is
deleted after each run. Files that do not match the naming pattern are left
alone.

### Configure `.env`

Add these to the VM's `.env` alongside the PostgreSQL settings:

```env
DROPBOX_APP_KEY=...
DROPBOX_APP_SECRET=...
DROPBOX_REFRESH_TOKEN=...
DROPBOX_FOLDER=/beedb-backups        # optional, this is the default

BACKUP_MAIL_FROM=beedb@example.com   # leave BACKUP_MAIL_TO empty to disable mail
BACKUP_MAIL_TO="you@example.com other@example.com"
```

The refresh token comes from the Dropbox App Console. Create an app with
`files.content.write` and `files.content.read` scopes, then generate a
long-lived refresh token via OAuth 2.

### Configure `ssmtp` (only if you want mail)

`ssmtp` is installed by `vm-setup.sh` but not configured. Edit
`/etc/ssmtp/ssmtp.conf` with your SMTP relay credentials, e.g. for GMX:

```conf
root=<from-address>
mailhub=mail.gmx.net:587
UseSTARTTLS=YES
AuthUser=<smtp-user>
AuthPass=<smtp-password>
FromLineOverride=YES
```

### Schedule the daily run

On the VM, add a cron entry for the `ubuntu` user:

```bash
crontab -e
```

```cron
30 1 * * * cd /home/ubuntu/beedb && bash scripts/backup.sh >> /home/ubuntu/beedb-backup.log 2>&1
```

That runs the backup at 01:30 every day and appends stdout/stderr to
`~/beedb-backup.log`. The mail (if configured) carries a one-line status
subject; the log has the full detail.

---

## Migrating the databases to a new server

`scripts/restore_from_db_server` pulls each database directly from the old
VM into the new Docker postgres over SSH. Run it on the **new** server. The
database list is hardcoded in the script (currently `beecovie` and
`msculpturalis`); edit it there if that changes.

### Preparation

**1. On the NEW server — generate a dedicated migration SSH key:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/beedb_migration -N ''
cat ~/.ssh/beedb_migration.pub
```

**2. On the OLD server — install that public key:**

Paste the ed25519 public key from step 1 into authorized_keys:

```bash
nano ~/.ssh/authorized_keys
```

**3. On the OLD server — allow passwordless sudo for `pg_dump[all]`:**

```bash
sudo tee /etc/sudoers.d/pg-migration >/dev/null <<'EOF'
ubuntu ALL=(postgres) NOPASSWD: /usr/bin/pg_dumpall, /usr/bin/pg_dump
EOF
sudo chmod 440 /etc/sudoers.d/pg-migration
sudo visudo -c
```

`sudo visudo -c` should list every file in `/etc/sudoers.d/` as `parsed OK`.
**Important:** `sudo` silently ignores any file in that directory that isn't
mode `0440` — if `visudo -c` reports `bad permissions, should be mode 0440` for
any file, that rule is not being applied. Either `sudo chmod 440 <file>` or
`sudo rm <file>` (do this from a shell that still has an active sudo session,
in case the fix goes wrong).

Quick check from the NEW server that steps 2 and 3 both work:

```bash
ssh -i ~/.ssh/beedb_migration ubuntu@<old-vm-ip> \
    'sudo -n -u postgres pg_dumpall --globals-only | head -5'
```

`-n` makes sudo fail rather than prompt. If you see `CREATE ROLE` lines, you're
ready to run the migration.

### Run the migration

```bash
bash scripts/restore_from_db_server
```

It prompts for the old server's IP, then drops and recreates each target
database on the new server and streams the dump over SSH into `pg_restore`.

Every role is migrated with its password **except** the `postgres` role
itself: the script filters the `CREATE/ALTER ROLE postgres ...` lines out of
`pg_dumpall`'s output so the new server's `postgres` password (set via `.env`)
is preserved. All other roles keep their old-server passwords, so applications
that connect as e.g. `crohrbach_editor` or `geoserver_read_all` continue to
work without any manual password reset.

If PostGIS extension errors appear after restore, run inside the container:

```bash
docker compose exec db psql -U postgres -d <dbname> \
  -c "SELECT postgis_extensions_upgrade();"
```

