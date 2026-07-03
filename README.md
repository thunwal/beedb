# beedb

PostgreSQL 18 + PostGIS 3.6 database server, Dockerized and managed as code. Tested on Ubuntu 26.04 LTS as Docker host.

Includes specific tooling required to manage the server for [BeeRadar.info](https://beeradar.info/), such as SSH login to the Docker host and a DB backup upload to Dropbox.

---

## Overview

Bringing up beedb on a fresh Docker host is a three-phase workflow:

1. **Prepare the host** — run `host-setup.sh`. See [Setup the Docker host](#setup-the-docker-host).
2. **Start the database container** — configure `.env`, run `docker compose up -d`. See [Initialize the database container](#initialize-the-database-container).
3. **Populate the database** — restore from a Dropbox backup (see [Backup and restore databases](#backup-and-restore-databases)) or migrate from an old server (see [Migrating the databases to a new server](#migrating-the-databases-to-a-new-server)). Skip if starting with an empty database.

The remaining chapters cover day-to-day operations: remote access, deploying
code changes, and the ongoing backup / restore workflow.

---

## How the remote access works

beedb runs inside Docker on the host with **no ports exposed to the internet
except SSH (22)**. PostgreSQL binds to loopback only (`127.0.0.1:5432:5432` in
`docker-compose.yml`) and `ufw` blocks everything except SSH. Any remote
access — shell, database, or the outbound Dropbox upload — either goes
through the host's SSH daemon or is initiated by the host itself over HTTPS.

### The main SSH key

A single self-generated RSA key, `beekey_openssh2`, is written to the ubuntu
user's `authorized_keys` by `host-setup.sh`. It serves both purposes:

| Purpose | How |
|---|---|
| Shell access to the host | Normal SSH login |
| PostgreSQL access | SSH forwards local port 5432 to the container |

### Shell into the host

```bash
ssh ubuntu@<HOST_IP> -i <PATH_TO>/beekey_openssh2
```

This is what later chapters mean when they say "SSH into the host".

### Connect to PostgreSQL through the tunnel

PostgreSQL has no SSH daemon of its own. When you open a tunnel, your local
client connects to the host on port 22 and SSH forwards traffic on your local
port 5432 through Docker's internal network to the database. From any local
tool it then looks like PostgreSQL is running on your own machine.

Open the tunnel in the background:

```bash
ssh -L 5432:localhost:5432 -Nf ubuntu@<HOST_IP> \
    -i <PATH_TO>/beekey_openssh2
```

Then connect exactly as if PostgreSQL were running locally:

```bash
psql -h localhost -U postgres -d postgres
```

### Optional: `~/.ssh/config` shortcut

Add this block on your local machine to avoid typing the full command every time:

```sshconfig
Host beedb
    HostName      <HOST_IP>
    User          ubuntu
    IdentityFile  <PATH_TO>/beekey_openssh2

Host beedb-tunnel
    HostName      <HOST_IP>
    User          ubuntu
    IdentityFile  <PATH_TO>/beekey_openssh2
    LocalForward  5432 localhost:5432
```

Then:
```bash
ssh beedb              # shell on the host
ssh -Nf beedb-tunnel   # open the DB tunnel in the background
```

### Git and Dropbox

- **Git:** the repository is public, so the host uses HTTPS with no credentials
  — no deploy key needed.
- **Dropbox:** the backup and restore scripts talk to Dropbox over HTTPS using
  an OAuth 2 refresh token stored in `.env`. Independent of SSH.

### Optional SSH key for the DB migration

A **second SSH key** — `beedb_migration` — is used only during a one-off
migration from an old server. See
[Migrating the databases to a new server](#migrating-the-databases-to-a-new-server);
it has no ongoing role after migration finishes and can be deleted afterwards.

---

## Setup the Docker host

### 1. Clone the repo on the host

SSH into the host (see [How remote access works](#how-remote-access-works)), then clone the beedb repository:

```bash
git clone https://github.com/thunwal/beedb.git beedb
```

### 2. Run the setup script

```bash
cd beedb
sudo bash host-setup.sh
```

This will:
- Disable password authentication and root SSH login
- Configure `ufw` to allow port 22 only — port 5432 is never exposed
- Install Docker and Docker Compose
- Install a daily cron entry that runs `scripts/backup.sh` at 01:30

### 3. Prepare `.env` file

Create an `.env` file in the beedb directory:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

It holds sensitive configuration (passwords, tokens) and is not tracked by git.

---

## Initialize the database container

### 1. Configure `.env` for the database

Set the PostgreSQL superuser password in `.env`:

```env
POSTGRES_PASSWORD=<something strong>
```

The superuser (`postgres`) and the initial database (`postgres`) are hardcoded in
`docker-compose.yml`. `POSTGRES_PASSWORD` is a database credential only — unrelated
to your SSH key or the Linux `ubuntu` user on the host. You use it whenever you
connect to PostgreSQL, e.g. `psql -h localhost -U postgres` will prompt for it.

**Choose a strong password** — it is your only defence if the SSH tunnel or
firewall were ever misconfigured.

The password is set on first container start. If you change it later, also update
it inside the database manually, or delete the data volume and start fresh.

### 2. Start the database container

When you configured the .env file, start the docker container:

```bash
docker compose up -d
```

---

## Deploying host setup changes

After pushing changes to the remote repository, they need to be pulled and applied on the host.

SSH into the host (see [How remote access works](#how-remote-access-works)), then:

```bash
cd beedb
git pull
```

Then test the script you changed, or, in case of changes to `docker-compose.yml`:

```bash
docker compose up -d
```

`docker compose up -d` is safe to run at any time — it only recreates the container if
its configuration actually changed. The database volume is never touched.

### Note: `init/` SQL files are only executed once

Docker runs the scripts in `init/` exactly once: when the database volume is first
created. They are not re-run on restart or after a `git pull`.

To apply a change to an `init/` file after the database already exists, run the SQL
directly:

```bash
docker compose exec db psql -U postgres -d postgres -f /docker-entrypoint-initdb.d/01_extensions.sql
```

Because all statements use `IF NOT EXISTS`, re-running the file is safe.

---

## Backup and restore databases

`scripts/backup.sh` auto-discovers every user database on the server, dumps
each one, uploads the dumps to Dropbox, applies a retention policy on Dropbox,
keeps only the most recent dumps locally, and mails the outcome via `ssmtp`.
It is designed to run daily from cron.

Each dump is named `<dbname>_YYYYMMDDTHHMMSS.dump` — one file per database per
run. Adding or removing a database (e.g. via the migration script) is picked
up automatically on the next run; no config change needed.

### One-off usage

```bash
# Dump every user database, upload each, and rotate old files
bash scripts/backup.sh

# Restore a single database from a local dump file. The target database name
# is taken from the filename, so <dbname>_YYYYMMDDTHHMMSS.dump is required.
bash scripts/restore.sh backups/beecovie_20260510T120000.dump
```

### Restore from a Dropbox backup

For disaster recovery (fresh Docker host, corrupted data, or rolling back to an earlier
snapshot), `scripts/restore_from_dropbox.sh` fetches one dump from Dropbox and
restores it:

```bash
# Restore the latest backup for a specific database
bash scripts/restore_from_dropbox.sh beecovie

# Or restore a specific file
bash scripts/restore_from_dropbox.sh beecovie_20260703T013000.dump
```

The script restores one database per invocation. To restore several after a
disaster, run it once per database.

Prerequisites: the container is running (`docker compose up -d`), and `.env`
holds the same Dropbox credentials the backup script uses.

If you'd rather grab the file by hand, download it via the Dropbox web UI,
`scp` it into `~/beedb/backups/` on the host, and run
`bash scripts/restore.sh backups/<file>.dump`.

### Retention on Dropbox

Applied per file, based on the timestamp in the filename (shared across all
databases):

- Every backup for the last 14 days (daily)
- The Monday backup for the last 60 days (weekly, ~2 months)
- The first-Monday-of-month backup for the last 365 days (monthly, ~1 year)

Anything else in `DROPBOX_FOLDER` that matches `<dbname>_YYYYMMDDTHHMMSS.dump`
is deleted after each run. Files that do not match the naming pattern are left
alone.

### Configure `.env` for the backup

Configure these in the host's `.env` alongside the PostgreSQL settings:

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

### Configure `ssmtp` (only if you want mail notifications)

`ssmtp` is installed by `host-setup.sh` but not configured. Edit
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

`host-setup.sh` already installed this cron entry for the `ubuntu` user:

```cron
30 1 * * * cd /home/ubuntu/beedb && bash scripts/backup.sh >> /home/ubuntu/beedb-backup.log 2>&1
```

That runs the backup at 01:30 every day and appends stdout/stderr to
`~/beedb-backup.log`. The mail (if configured) carries a one-line status
subject; the log has the full detail.

Verify with `crontab -l` on the host. To change the time or destination, edit
with `crontab -e`.

---

## Migrating databases to a new server

`scripts/restore_from_db_server` pulls each database directly from the old
server into the new Docker postgres over SSH. Run it on the **new** server. The
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
ssh -i ~/.ssh/beedb_migration ubuntu@<old-host-ip> \
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

