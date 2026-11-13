# dbtool — PostgreSQL / MySQL backup, restore & server-to-server migration

[![ci](https://github.com/deziss/dbtool/actions/workflows/ci.yml/badge.svg)](https://github.com/deziss/dbtool/actions/workflows/ci.yml)
[![license: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

One shell script, one config file (YAML **or** JSON). Handles **any server version** by
detecting the version at connect time and picking a matching client — native binaries when
they're new enough, otherwise a throwaway `postgres:<major>` / `mysql:<major.minor>` /
`mariadb:<major.minor>` container. Nothing is installed permanently.
Which PostgreSQL versions work for what: [POSTGRES_SUPPORT.md](POSTGRES_SUPPORT.md).
Something failing: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
Operating procedure for backups, restores, migrations and restore drills: [SOP.md](SOP.md).

> **Your real config never belongs in git.** Copy an example, fill it in, and keep it at
> `/etc/dbtool/dbtool.yml`. `.gitignore` already blocks `dbtool.yml`/`dbtool.env`/dumps —
> only the `*.example.*` templates are tracked. See [Security](#security).

## Install

```bash
git clone https://github.com/deziss/dbtool.git && cd dbtool
sudo ./install.sh                 # add --systemd for the nightly timer

# edit /etc/dbtool/dbtool.yml and /etc/dbtool/dbtool.env, then:
dbtool test --deep
```

`install.sh` puts the script in `/opt/dbtool`, links `/usr/local/bin/dbtool`, and
refreshes the examples in `/etc/dbtool`. Override with `PREFIX=`, `BIN=`, `CONF=`.

## Updating

Re-running the installer is the whole update, and it never touches your
`dbtool.yml` or `dbtool.env`:

```bash
cd dbtool && git pull && sudo ./install.sh
```

Without a checkout on the box, replace the script in place:

```bash
sudo dbtool self-update            # downloads, parses and version-checks before swapping
dbtool self-update --check         # report only; exit 10 when an update is due
```

`self-update` follows the newest [published release](https://github.com/deziss/dbtool/releases).
It refuses anything that is not a dbtool or does not parse, keeps the previous version
beside it as `dbtool.sh.v<old>.bak`, and installs by rename so the running process is
never rewritten under itself. It will not install an older remote unless you pass
`--force`. `--main` follows the development branch instead; `DBTOOL_REPO=` points at a
fork and `DBTOOL_UPDATE_URL=` overrides the lot. Version in `dbtool --version`, changes
in [CHANGELOG.md](CHANGELOG.md).

### Cutting a release

Releases are published by pushing a tag — the workflow refuses one that disagrees with
`DBTOOL_VERSION`, takes the notes from `CHANGELOG.md`, and attaches `dbtool.sh` and
`install.sh`:

```bash
# bump readonly DBTOOL_VERSION in dbtool.sh, add a CHANGELOG section, commit
git tag -a v1.4.0 -m "dbtool v1.4.0" && git push origin v1.4.0
```

Requirements: `bash` 4+, `python3` (stdlib only — PyYAML is used if present, otherwise a
built-in YAML subset parser handles the config), and either native `psql`/`pg_dump`/`mysql`/
`mysqldump` or a usable `docker`. Optional: `zstd` or `pigz`, `mc`/`aws` for off-box copies,
`curl` for the failure webhook. GNU `find`/`date` assumed (any normal Linux distro).

The config is found in this order: `-c FILE` → `$DBTOOL_CONFIG` → `./dbtool.yml|.yaml|.json`
→ next to the script → `/etc/dbtool/dbtool.yml|.yaml|.json`.

## Config

Every connection can be given either as a URL or as separate fields — mix freely, explicit
fields win over the URL. The URL parser understands SQLAlchemy-style dialects, so the DSN
already in your `.env` works unchanged:

```yaml
env_file: /etc/dbtool/dbtool.env      # ${DB_HOST} etc. come from here

databases:
  - name: app_dev
    url: "postgresql+asyncpg://app_user:${APP_PG_PASSWORD}@${DB_HOST}:5432/app_dev"

  - name: crm_mysql
    engine: mysql               # postgres | mysql (MariaDB is detected automatically)
    host: db-primary.example.com
    port: 3306
    user: crm_user
    password_env: CRM_DB_PASSWORD   # or password: / password_file:
    database: crm_mysql
```

Recognised per-entry keys: `engine`, `host`, `port`, `user`, `password`, `password_env`,
`password_file`, `database`, `sslmode`, `charset`, `format`, `jobs`, `schema_only`,
`data_only`, `no_owner`, `clean`, `create`, `enabled`, `image`, `exclude_tables`, `exclude_table_data`,
`include_tables`, `schemas`, `exclude_schemas`, `dump_args`, `restore_args`, `search_path`
(targets: the `search_path` a PostgreSQL restore runs with, see [Restore](#restore)).
Aliases are accepted where obvious (`username`/`uname`, `pass`/`passwd`, `db`/`dbname`,
`hostname`, `type`/`driver`, `dsn`/`database_url`).

`defaults` controls `backup_dir`, `log_file`, `retention_days`, `retention_min_keep`,
`keep_daily|weekly|monthly|yearly`, `retention_max_size`, `min_free_space`,
`compression` (`zstd|gzip|none`), `compression_level`, `zstd_long`,
`pg_compression` (`gzip|zstd|lz4|none`), `pg_compress_level`, `format` (`custom|plain|directory`),
`jobs`, `docker` (`auto|always|never`), `docker_network`, `timeout`, `timestamp_format`,
`verify` (`full|header|none`), `fingerprint` (`counts|full|none`), `include_globals`, `lock` and
`maintenance_db`.

`databases:` are backup sources; `targets:` are restore/migration destinations. The JSON file
is byte-for-byte the same structure — use whichever you prefer.

### Targets

A target is where `restore -t` and `migrate --to` write. It takes the same connection keys as
a database entry, plus the restore-side ones:

```yaml
targets:
  staging_pg:
    url: "postgresql://postgres:${STAGING_PG_PASSWORD}@10.0.0.9:5432/app_dev"
    create: true                    # CREATE DATABASE if it is missing
    clean: false                    # pg_restore --clean --if-exists (overwrite objects in place)
    search_path: auto               # optional: auto | app,public (see TROUBLESHOOTING.md)
    restore_args: ["--no-owner", "--no-privileges"]
    jobs: 4                         # parallel restore workers

  new_server_mysql:
    engine: mysql
    url: "mysql://root:${NEW_MYSQL_PASSWORD}@10.0.0.10:3306/crm"
    create: true
```

| Key | Effect on restore / migrate |
|---|---|
| `database` (or the URL path) | Database written to; `--database` / `--target-db` overrides it per run. |
| `create` | Create the database if missing (same as `--create`). |
| `clean` | PostgreSQL: drop and recreate each object before restoring it. `--drop` instead drops the whole database first, after a prompt. |
| `search_path` | PostgreSQL: `search_path` the restore runs with; `--search-path` overrides it per run. |
| `verify_data` | PostgreSQL: `counts` or `full` — check the data after every restore/migrate into this target (`--verify-data` / `--no-verify-data` per run). |
| `restore_args` | Extra arguments passed to `pg_restore`. |
| `jobs` | Parallel `pg_restore` workers (not used with `search_path`). |
| `image` | Pin the client container image. |

`-t` also accepts a name from `databases:`, which restores back onto that source (useful to
copy one server's dump onto another configured server). A `targets:` entry is the safer
choice: the database you back up from is never written to by accident, and the restore-side
keys above live in one place.

## Everyday use

```bash
dbtool test                                   # connect + print server versions
dbtool test --deep                            # + privileges, client match, trial dump of every db
dbtool discover                               # what is on these servers that the config misses
dbtool backup all                             # everything enabled, plus cluster globals
dbtool backup app_dev,crm_mysql               # a subset
dbtool globals                                # roles/grants only, one file per server
dbtool list                                   # sources, targets, local dumps
dbtool verify /backup/db/app_dev_*.dump       # checksum + full dump read
dbtool compare app_dev staging_pg --latest app_dev --full   # restored data vs dump vs live source
dbtool drill app_dev -t drill_scratch -y      # restore drill: restore, verify, RPO/RTO, drop
dbtool prune                                  # apply retention now
```

Only one dbtool may work on a `backup_dir` at a time — a second run exits immediately instead
of racing the first (`lock: false` disables it).

Every dump lands as `<name>_<engine>_<db>_<timestamp>.<ext>` plus a `.sha256` and a
`.meta.json` recording the source, server version, format and size. Dumps are written to a
`.part` file, and the rename happens only after the dump command exited 0 **and** the archive
read back completely — `pg_restore -f /dev/null` for custom format, full decompression plus the
writer's completion marker for plain SQL. Listing an archive header is not enough: a dump
truncated by a timeout or a dropped connection still lists a complete table of contents. Set
`verify: header` for the cheap check, or `verify: none` to skip it.

## Back up every database on a server

`backup all` dumps the entries in the config, so a database created later is
silently not backed up. Give an entry `all_databases: true` and it stands for the
whole server instead — dbtool asks the server what it has, every run:

```yaml
databases:
  - name: pg_main
    engine: postgres
    host: db-primary.example.com
    port: 5432
    user: postgres
    password_env: APP_PG_PASSWORD
    all_databases: true
    exclude_databases: ["postgres", "test_*"]   # globs; include_databases also works
```

Each database becomes its own dump labelled `<entry>_<db>`, so retention, restore and
verification stay per-database:

```
pg_main_orders_postgres_orders_20261107-020000.dump
pg_main_billing_postgres_billing_20261107-020000.dump
dbtool restore --latest pg_main_orders -t staging_pg --create -y
```

Enumeration needs the maintenance database (`postgres` by default, `maintenance_db:`
to change it) and reports only databases the role may `CONNECT` to — one role without
rights to a database means that database is skipped, which is why `test --deep` exists.

`dbtool discover` lists what each configured server holds, with sizes, marking anything
the config does not cover and printing an entry to paste. It also works against a URL
that is not in the config at all:

```bash
dbtool discover
dbtool discover --url 'postgresql://user:pass@10.0.0.5:5432/postgres'
```

## Preflight

`dbtool test` checks connectivity and versions. `dbtool test --deep` answers the
question that matters before you trust a schedule — *will every database actually
dump?*

```
OK s192: postgres 18.4 at 10.10.110.192:5432/postgres
    maintenance db 'postgres': reachable (all_databases, --create, --drop)
    role 'nuhire_user': superuser — globals include role passwords
    databases readable by this role (5): nuhire_dev nuhire_local nuhire_prod postgres postgres_nuhire
    client: native pg_dump 18 >= server 18 — OK
OK     dumpable: nuhire_dev
OK     dumpable: nuhire_local
```

Without `--deep` the first five lines still run; `--deep` adds a real `--schema-only`
dump of each database through the same client the backup would use. It exits non-zero
if any check fails, so it works as a cron guard or a post-deploy gate.

## Roles and grants

A per-database dump contains no roles, no cluster-level grants and no tablespaces, so restoring
one onto a fresh server leaves every `GRANT` dangling. `dbtool globals` dumps them per server
(deduplicated by host:port), and `backup all` includes them unless `include_globals: false`:

```bash
dbtool globals
# -> globals_<host>_<port>_postgres_globals_<ts>.sql.zst   (mode 0600)
zstd -dc /backup/db/globals_*.sql.zst | psql -h newhost -U postgres   # restore these first
```

Role password hashes live in `pg_authid`, which is superuser-only. When the configured user
isn't a superuser dbtool warns and falls back to `--no-role-passwords` instead of failing —
those roles restore without passwords, and you set them by hand.

## Restore

```bash
# newest dump of app_dev into the 'staging_pg' target, creating the DB if needed
dbtool restore --latest app_dev -t staging_pg --create

# a specific file, into a different database name, wiping the target first
dbtool restore -f /backup/db/app_dev_postgres_app_dev_20260907-020000.dump \
       -t staging_pg --database app_qa --drop
```

`-t` accepts a name from `targets:` or from `databases:` (restoring back over the source).
`--drop` prompts before destroying anything; add `-y` to skip the prompt in scripts.
You do not need to run your app's migrations on the target first: the dump carries the schema.

```bash
# schema whose CHECK constraints call SQL functions that call other functions unqualified
dbtool restore --latest app_dev -t staging_pg --drop --search-path auto
dbtool restore --latest app_dev -t staging_pg --drop --search-path app,public   # or name them
```

`--search-path` is for schemas whose SQL functions call other functions without a schema
prefix; such restores otherwise fail with `function … does not exist … during inlining`.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#restore-fails-function-does-not-exist-during-inlining).

## Verify restored data

A restore that finishes without errors can still be incomplete. dbtool checks the data itself.

- **At backup** it records `<dump>.fingerprint.tsv`, with per-table row counts, sequence values
  and object counts. With `fingerprint: full` it also records an order-independent checksum of
  every row. It takes these in **the same snapshot pg_dump uses**, so they describe exactly what
  is in the dump, even on a busy source.
- **After restore or migrate**, `--verify-data [counts|full]` (or `verify_data:` on the
  target) fingerprints the restored database and compares it. The command exits with status 1
  if any table, sequence or object differs.
- **At any time**, `dbtool compare` runs the same check.

```bash
dbtool restore --latest app_dev -t staging_pg --drop --verify-data full
dbtool compare staging_pg --latest app_dev --full             # restored vs dump (+ live source)
dbtool compare app_dev staging_pg --full                      # two live databases
dbtool migrate --from app_prod --to new_pg --drop --verify-data full -y   # exact, even while the source takes writes
```

| Reference | Exact? | When |
|---|---|---|
| Dump fingerprint (`.fingerprint.tsv`) | yes, taken in the dump's snapshot | dumps made by 1.3.0+ |
| Dump data (COPY rows counted from the file) | row counts only | older dumps without a fingerprint |
| Live source | no: shows the drift since the backup, reported as information | `--latest NAME` of a configured source, or `compare SOURCE TARGET` |

### Look at the rows themselves

Counts and checksums tell you *that* a table differs. `--sample` shows *what* the rows hold. It
picks N random rows from the restored database by primary key and reads the same keys from the
dump and the live source. Each column is printed side by side, with differences marked:

```bash
dbtool compare staging_pg --latest app_dev --sample app.orders --rows 3
dbtool compare staging_pg --latest app_dev --sample app.orders --where "id = 4711"
dbtool compare staging_pg --latest app_dev --sample app.audit_log --key event_id,ts   # table without a PK
```

```
-- row 1/3  key: id=4711
  COLUMN    RESTORED                    DUMP    SOURCE(now)
  id        4711                        =       =
  status    paid                        =       DIFF refunded
  payload   \x8a3f1c0e9b... (20480 bytes)  =       =
  => MATCHES dump; changed in source since backup (1 column(s))
```

- `=` means the value equals the restored one. `DIFF@N` on a long value gives the position of
  the first differing character.
- Values print as COPY text (a tab is `\t`, a newline `\n`, a backslash `\\`); `NULL` is NULL and an
  empty string is `''`. A long value is cut with its length; a `bytea` shows as hex with its size
  in bytes.
- Dump rows go into a `TEMP` table on the target first, so all three sides print with the same
  session settings (time zone, date style, float digits, bytea format).
- The command exits with status 1 if a row differs from the dump. When no dump is given, it
  exits 1 if a row differs from the source. A change on the live source since the backup is
  information only.
- Options: `--rows N` (default 5), `--key c1,c2` (for a table without a primary key or a
  `NOT NULL` unique key), `--where SQL` (restricts which rows can be picked), `--width N` (the
  column width, default 40). `--sample` can be given more than once. A report is saved to
  `<backup_dir>/reports/sample_*.txt`.

`--verify-data` also runs `ANALYZE` after the load. `--no-analyze` skips that, and the
analyze step runs on every PostgreSQL restore anyway. Each check writes a full report to
`<backup_dir>/reports/`. `dbtool drill NAME -t SCRATCH` combines restore, verify and drop, and
reports the backup's age (RPO) and how long the recovery took (RTO). See [SOP.md](SOP.md).

## Migrate to another server

Streams `pg_dump | pg_restore` (or `mysqldump | mysql`) directly between the two hosts — no
intermediate file, no disk pressure:

```bash
dbtool migrate --from app_prod --to new_server_pg --create -y
dbtool migrate --from crm_mysql  --to new_server_mysql --target-db crm_mysql_v2 --create -y
```

Add `--via-file` if you'd rather keep the dump on disk (it takes a normal backup, then restores
it — good for cut-overs where you want an artifact to fall back to). The tool resolves clients
for source and target independently, so migrating **PostgreSQL 12 → 17** or **MySQL 5.7 → 8.4**
works from one box (downgrades such as 17 → 15 do not; see
[POSTGRES_SUPPORT.md](POSTGRES_SUPPORT.md)). `--search-path` works here too, as for `restore`
(`auto` needs a dump file, so combine it with `--via-file`). Cross-engine (Postgres → MySQL) is refused deliberately; that needs an ETL
tool, not a dump pipe.

Typical cut-over:

```bash
dbtool test                                        # both ends reachable
dbtool migrate --from app_prod --to new_server_pg --create -n   # dry run
dbtool backup app_prod                          # safety net
dbtool migrate --from app_prod --to new_server_pg --create -y
# tool prints the target table count; then point the app at the new host
```

## Scheduling

systemd (preferred):

```bash
sudo cp systemd/dbtool-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dbtool-backup.timer
systemctl list-timers dbtool-backup.timer
sudo systemctl start dbtool-backup.service   # run once now
journalctl -u dbtool-backup.service -f
```

cron:

```cron
0 2 * * * DBTOOL_CONFIG=/etc/dbtool/dbtool.yml /opt/dbtool/dbtool.sh backup all -y -q >> /var/log/dbtool-cron.log 2>&1
```

`-y` matters in both cases: without it a `--drop` prompt would block forever. `-q` keeps
output to warnings and errors so cron only mails you when something is wrong.

## Notes on the choices

**Version matching, not "latest client wins."** `pg_dump` refuses to dump a server newer than
itself, and `mysqldump` 8 against 5.7 trips over `information_schema` differences. `docker: auto`
uses your native client when its major version is at least the server's, and otherwise pulls the
exact matching image once and reuses it. Set `docker: never` on hosts without Docker, or
`always` if you'd rather never depend on what's installed.

**Passwords never appear in `ps`.** PostgreSQL goes through `PGPASSWORD` in the process
environment (or `-e` for the container); MySQL gets a `0600` `--defaults-extra-file` written into
a private temp dir that's deleted on exit. `--no-password` is passed to `pg_dump` so a missing
credential fails immediately instead of hanging on a prompt.

**Format defaults.** PostgreSQL uses custom format (`-Fc`) — compressed, and restorable
selectively and in parallel. `directory` adds parallel *dumping* (`-j`) for large databases and
is tarred afterwards. `plain` is there when you want readable SQL. MySQL dumps are plain SQL with
`--single-transaction --quick --hex-blob --no-tablespaces`, so InnoDB tables are consistent
without locking, and `--set-gtid-purged=OFF` is added only for real MySQL (MariaDB rejects it).

**Retention has a floor.** `retention_days` alone will happily delete everything if a database
hasn't been backed up in a while; `retention_min_keep` guarantees the N newest dumps per database
survive regardless of age.

## Retention and disk space

`prune` runs after every `backup all`, and on its own with `dbtool prune`. Use `dbtool -n prune`
to see what it would delete, and why. All rules apply per database:

| Key | Effect |
|---|---|
| `retention_days: 14` | Keep every dump younger than this. |
| `retention_min_keep: 3` | Always keep the N newest dumps, whatever their age. |
| `keep_daily: 7`, `keep_weekly: 4`, `keep_monthly: 6`, `keep_yearly: 2` | Grandfather-father-son retention. Past `retention_days`, keep the newest dump of each of the last N days, ISO weeks, months and years that have one. With `retention_days: 0`, everything not picked by these rules goes. |
| `retention_max_size: 200G` | A cap on the total size of all dumps in `backup_dir`. The oldest go first until the rest fit, but never below `retention_min_keep` (at least 1) per database. |
| `min_free_space: 20G` | Before each dump, if less than this is free, prune first; if still short, refuse to dump instead of filling the disk. |
| `s3.keep_remote: false` | Also delete the off-box copy (dump plus sidecars) of everything pruned locally. With `true` (the default), set an expiry lifecycle rule on the bucket. `--no-upload` also skips remote deletion. |

For example, `retention_days: 7` with `keep_weekly: 4, keep_monthly: 12` holds 7 daily, 4
weekly and 12 monthly dumps: about 23 files, covering a year.

### Making dumps smaller

| Option | Effect | Notes |
|---|---|---|
| `exclude_table_data: [django_session, "*_log"]` (per entry) | Dumps the table definition but none of its rows. Often the largest saving: logs, sessions, caches, queues. | PostgreSQL only; uses pg_dump patterns. The restored tables are empty, and data verification expects that. |
| `exclude_tables` (per entry) | Leaves the table out entirely. | Restores without it; use for throwaway tables only. |
| `pg_compression: zstd` | pg_dump's own compression for custom/directory format. zstd gives smaller dumps than gzip at the same speed. | Needs PostgreSQL 16+ on the server; otherwise dbtool says so and uses gzip. |
| `pg_compress_level: 9` | Higher means smaller and slower: gzip 1-9, zstd 1-22, lz4 1-12. | |
| `compression: zstd`, `compression_level: 9` | Compression of plain/directory/MySQL dumps. zstd 3 (the default) is fast; 9-12 is usually a good balance; 19 is slow. | 20-22 enables `--ultra` (a lot of memory). |
| `zstd_long: true` | Long-distance matching (`--long=27`): finds repeats up to 128 MB apart. Helps on large, repetitive data. | Reading the dump back needs no extra flag. |
| `format: plain` + `compression: zstd` | Often the smallest file for text-heavy data, but restores single-threaded and cannot pick single tables. | `custom` stays the default. |

Measure on your own data: run a backup, check the size in `dbtool list`, change one setting,
and back up again.

**Restore is never silently destructive.** `--drop` prompts, and for PostgreSQL it terminates
existing backends first (otherwise `DROP DATABASE` fails with "database is being accessed by
other users"). Plain-SQL restores run with `ON_ERROR_STOP=1` so failures surface instead of
scrolling past.

**Bound to your nginx/127.0.0.1 pattern.** Containers run with `--network host`
(`docker_network` in the config), so a database listening only on `127.0.0.1` is reachable from
the containerised client exactly as it is from the host.

## Troubleshooting

Symptoms, causes and fixes are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md), including
restores that fail with `function … does not exist … during inlining`.

## Security

- **Nothing real is committed.** `.gitignore` blocks every live config (`dbtool.yml`,
  `dbtool.yaml`, `dbtool.json`, `dbtool.*.yml`), every env/dotenv file, `*.pass`/`*.pem`/
  `*.key`, and every backup artifact (`*.dump`, `*.sql*`, `*.sha256`, `*.meta.json`). The
  tracked `*.example.*` files contain placeholder hostnames and `${VAR}` references only, and
  CI fails the build if a live config or a hardcoded credential ever gets staged.
- **Put passwords in the env file, not the config.** Use `password_env: MY_VAR` (or
  `password_file:`) and keep `dbtool.env` at mode `0600`. Inline `password:` works but ends up
  in your config file.
- **Credentials never reach `ps`.** PostgreSQL uses `PGPASSWORD` in the process environment;
  MySQL gets a `0600` `--defaults-extra-file` in a private temp dir removed on exit.
- **Dumps are as sensitive as the database.** `/backup/db` should be `0700` and owned by the
  user running dbtool; enable the `s3:` block only against a bucket you control. Globals files
  are written `0600` because they can carry role password hashes.
- Found a vulnerability? Open a private security advisory on GitHub rather than a public issue.

## Contributing

```bash
bash -n dbtool.sh                                   # syntax
shellcheck --severity=error --shell=bash dbtool.sh  # lint
```

CI runs both, parses the example configs, and does a full backup → verify → restore →
row-count round-trip against a `postgres:17` service container. Keep `dbtool.sh` dependency
free (bash + python3 stdlib) and update both example configs when you add a config key.

## License

GNU Affero General Public License v3.0 or later — see [LICENSE](LICENSE).

Copyright (C) 2026 Anshu Kushwaha. dbtool is free software: you may redistribute and modify it
under the AGPL. It comes with **no warranty**. The AGPL's network clause (section 13) matters
if you expose dbtool through a service — anyone interacting with it over a network must be
offered the corresponding source, including your modifications. Running it privately on your
own servers carries no such obligation.
