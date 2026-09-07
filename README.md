# dbtool — PostgreSQL / MySQL backup, restore & server-to-server migration

[![ci](https://github.com/deziss/dbtool/actions/workflows/ci.yml/badge.svg)](https://github.com/deziss/dbtool/actions/workflows/ci.yml)
[![license: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

One shell script, one config file (YAML **or** JSON). Handles **any server version** by
detecting the version at connect time and picking a matching client — native binaries when
they're new enough, otherwise a throwaway `postgres:<major>` / `mysql:<major.minor>` /
`mariadb:<major.minor>` container. Nothing is installed permanently.

```
dbtool/
├── dbtool.sh                 # the tool (self-contained, no companion files needed)
├── dbtool.example.yml        # config, YAML flavour
├── dbtool.example.json       # same config, JSON flavour
├── dbtool.env.example        # secrets referenced as ${VAR} from the config
├── systemd/
│   ├── dbtool-backup.service
│   └── dbtool-backup.timer
├── .github/workflows/ci.yml  # shellcheck + a real backup/restore round-trip
└── LICENSE                   # GNU AGPL v3
```

> **Your real config never belongs in git.** Copy an example, fill it in, and keep it at
> `/etc/dbtool/dbtool.yml`. `.gitignore` already blocks `dbtool.yml`/`dbtool.env`/dumps —
> only the `*.example.*` templates are tracked. See [Security](#security).

## Install

```bash
sudo mkdir -p /opt/dbtool /etc/dbtool /backup/db
sudo install -m 0755 dbtool.sh /opt/dbtool/dbtool.sh
sudo install -m 0640 dbtool.example.yml /etc/dbtool/dbtool.yml
sudo install -m 0600 dbtool.env.example /etc/dbtool/dbtool.env
sudo ln -sf /opt/dbtool/dbtool.sh /usr/local/bin/dbtool

# edit /etc/dbtool/dbtool.yml and /etc/dbtool/dbtool.env, then:
dbtool -c /etc/dbtool/dbtool.yml test
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
`data_only`, `no_owner`, `clean`, `create`, `enabled`, `image`, `exclude_tables`,
`include_tables`, `schemas`, `exclude_schemas`, `dump_args`, `restore_args`.
Aliases are accepted where obvious (`username`/`uname`, `pass`/`passwd`, `db`/`dbname`,
`hostname`, `type`/`driver`, `dsn`/`database_url`).

`defaults` controls `backup_dir`, `log_file`, `retention_days`, `retention_min_keep`,
`compression` (`zstd|gzip|none`), `pg_compress_level`, `format` (`custom|plain|directory`),
`jobs`, `docker` (`auto|always|never`), `docker_network`, `timeout`, `timestamp_format`.

`databases:` are backup sources; `targets:` are restore/migration destinations. The JSON file
is byte-for-byte the same structure — use whichever you prefer.

## Everyday use

```bash
dbtool test                                   # connect + print server versions
dbtool backup all                             # everything enabled
dbtool backup app_dev,crm_mysql           # a subset
dbtool list                                   # sources, targets, local dumps
dbtool verify /backup/db/app_dev_*.dump    # checksum + real dump integrity
dbtool prune                                  # apply retention now
```

Every dump lands as `<name>_<engine>_<db>_<timestamp>.<ext>` plus a `.sha256` and a
`.meta.json` recording the source, server version, format and size. Dumps are written to a
`.part` file and only renamed after they verify, so a half-finished dump can never be mistaken
for a good one.

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
works from one box. Cross-engine (Postgres → MySQL) is refused deliberately; that needs an ETL
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

**Restore is never silently destructive.** `--drop` prompts, and for PostgreSQL it terminates
existing backends first (otherwise `DROP DATABASE` fails with "database is being accessed by
other users"). Plain-SQL restores run with `ON_ERROR_STOP=1` so failures surface instead of
scrolling past.

**Bound to your nginx/127.0.0.1 pattern.** Containers run with `--network host`
(`docker_network` in the config), so a database listening only on `127.0.0.1` is reachable from
the containerised client exactly as it is from the host.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cannot reach PostgreSQL … check pg_hba` | The probe query failed. Verify host/port/user/password, and that `pg_hba.conf` allows the source IP with `md5`/`scram`. |
| `cannot pull a postgres:<n> client image` | Registry unreachable. Pre-pull on a connected host, push to `registry.example.com`, and set `image:` on the entry to your mirrored tag. |
| MySQL dump fails on `PROCESS privilege` | Already handled with `--no-tablespaces`; if a custom `dump_args` overrides it, put it back. |
| `pg_restore: error: could not execute query … already exists` | Target isn't empty. Use `--drop`, or set `clean: true` on the target for `--clean --if-exists`. |
| Restore is slow | Custom/directory dumps restore with `-j <jobs>`; raise `jobs` in `defaults` or on the target entry. |
| `zstd not installed — falling back to gzip` | Install `zstd`, or set `compression: gzip` to silence it. |

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
  user running dbtool; enable the `s3:` block only against a bucket you control.
- **Roles are not included.** Per-database dumps carry no cluster-level roles or grants. Take
  those separately, and treat the output as secret — it contains password hashes unless you
  pass `--no-role-passwords`:

  ```bash
  pg_dumpall -h db-primary.example.com -U postgres --globals-only > globals.sql
  ```

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
