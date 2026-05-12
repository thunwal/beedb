# beedb

PostgreSQL 18 + PostGIS 3.6 database server, Dockerized and managed as code.

---

## SSH keys explained

There is exactly **one SSH key** involved: `beekey_openssh2` (a self-generated RSA key),
written to the ubuntu user's `authorized_keys` by `vm-setup.sh`. It serves both purposes:

| Purpose | How |
|---|---|
| Shell access to the VM | Normal SSH login |
| PostgreSQL tunnel | SSH forwards local port 5432 to the container |

The repository is public, so the VM can `git clone` and `git pull` over HTTPS with no
credentials at all — no deploy key needed.

### How the DB tunnel works

PostgreSQL runs inside Docker with **no SSH daemon** of its own. It is unreachable from
the internet. When you open an SSH tunnel, your client connects to the VM on port 22 and
SSH forwards traffic on your local port 5432 through Docker's internal network to the
database. From any local tool it looks like a PostgreSQL server running on your own
machine.

---

## First-time VM setup

All setup runs directly from the cloned repository — no file copying needed.

### 1. Clone the repo on the VM

```bash
ssh ubuntu@91.92.140.33 -i /home/christa/kDrive/Dokumente/informatik/beekey_openssh2
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

```bash
# On the VM, inside the beedb directory:
cp .env.example .env
chmod 600 .env
nano .env
docker compose up -d
```

The `.env` file holds three PostgreSQL settings that the container reads on first start
to initialise the database:

| Variable | What it is | Default |
|---|---|---|
| `POSTGRES_USER` | The PostgreSQL superuser (equivalent to the built-in `postgres` admin) | `postgres` |
| `POSTGRES_PASSWORD` | The password for that superuser | *(set this to something strong)* |
| `POSTGRES_DB` | The name of the database created on first start | `beedb` |

These are **database credentials only** — they have nothing to do with your SSH key or
the Linux `ubuntu` user on the VM. You use them whenever you connect to PostgreSQL, e.g.
`psql -h localhost -U postgres -d beedb` will prompt for `POSTGRES_PASSWORD`.

The username (`postgres`) and database name (`beedb`) can be left as-is.
**Change `POSTGRES_PASSWORD`** to something strong — it is your only defence if the SSH
tunnel or firewall were ever misconfigured.

These values are set once. If you change them after the container has started, you must
also update them inside the database manually, or delete the data volume and start fresh.

---

## Deploying changes

After pushing changes from your local machine, they need to be pulled and applied on the VM.

### Manually (SSH in and update)

```bash
ssh ubuntu@91.92.140.33 -i /home/christa/kDrive/Dokumente/informatik/beekey_openssh2
cd ~/beedb
git pull
docker compose up -d
```

`docker compose up -d` is safe to run at any time — it only recreates the container if
its configuration actually changed. The database volume is never touched.

### One command from your local machine

```bash
bash scripts/deploy.sh 91.92.140.33
```

### What each type of change requires

| What changed | Action needed |
|---|---|
| `docker-compose.yml` or `.env` | `git pull && docker compose up -d` |
| `scripts/` or `vm-setup.sh` | Nothing on the VM — these run locally or during initial setup only |
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

## Connecting to PostgreSQL

### Open the tunnel

```bash
ssh -L 5432:localhost:5432 -Nf ubuntu@91.92.140.33 \
    -i /home/christa/kDrive/Dokumente/informatik/beekey_openssh2
```

### Connect to the database

With the tunnel open, connect exactly as if PostgreSQL were running locally:

```bash
psql -h localhost -U postgres -d beedb
```

### Optional: `~/.ssh/config` shortcut

Add this block on your local machine to avoid typing the full command every time:

```sshconfig
Host beedb
    HostName      91.92.140.33
    User          ubuntu
    IdentityFile  /home/christa/kDrive/Dokumente/informatik/beekey_openssh2

Host beedb-tunnel
    HostName      91.92.140.33
    User          ubuntu
    IdentityFile  /home/christa/kDrive/Dokumente/informatik/beekey_openssh2
    LocalForward  5432 localhost:5432
```

Then:
```bash
ssh beedb              # shell on the VM
ssh -Nf beedb-tunnel   # open the DB tunnel in the background
```

---

## Backup and restore

```bash
# Create a timestamped dump in ./backups/
bash scripts/backup.sh

# Restore from a dump file
bash scripts/restore.sh backups/beedb_20260510T120000.dump
```

---

## Migrating data from the old server

**On the old VM:**

```bash
pg_dump -U postgres -Fc <dbname> > beedb_migration.dump
```

**Copy to your local machine or directly to the new VM:**

```bash
KEY=/home/christa/kDrive/Dokumente/informatik/beekey_openssh2
scp -i "$KEY" ubuntu@<old-vm-ip>:~/beedb_migration.dump .
scp -i "$KEY" beedb_migration.dump ubuntu@91.92.140.33:~/
```

**On the new VM, after `docker compose up -d`:**

```bash
bash scripts/restore.sh ~/beedb_migration.dump
```

If PostGIS extension errors appear after restore, run inside the container:

```bash
docker compose exec db psql -U postgres -d beedb \
  -c "SELECT postgis_extensions_upgrade();"
```

---

## Rebuilding from scratch

```bash
# 1. Provision a new VM on Exoscale (use console or Exoscale's key for initial access)

# 2. Clone the repo and run setup
KEY=/home/christa/kDrive/Dokumente/informatik/beekey_openssh2
ssh -i "$KEY" ubuntu@<new-vm-ip>
git clone https://github.com/thunwal/beedb.git beedb && cd beedb
sudo bash vm-setup.sh

# 3. Configure and restore
cp .env.example .env && chmod 600 .env && nano .env
docker compose up -d
bash scripts/restore.sh <latest-backup.dump>
```
