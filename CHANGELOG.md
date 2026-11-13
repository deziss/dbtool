# Changelog

## 1.4.1

- `compare --sample` failed under gawk with a UTF-8 locale (`Invalid collation character`).
  It then printed `OK` with empty counts instead of failing. The view no longer uses
  byte-range regexes and runs with `LC_ALL=C`; an awk failure or a missing result now stops
  with an error.

## 1.4.0

- `dbtool compare … --sample SCHEMA.TABLE [--rows N]` picks random rows from the restored
  database by primary key (or a NOT NULL unique key, or `--key`). It reads the same rows from
  the dump and the live source and prints each column side by side, marking differences.
  Dump rows are loaded into a `TEMP` table on the target, so values print identically
  whatever the time zone or settings of the session that made the dump. The command exits 1
  if a row differs from the dump (or from the source when no dump is given), and writes a
  report to `<backup_dir>/reports/sample_*.txt`. `--where` narrows which rows can be picked;
  `--width` sets the column width.
- **Retention:**
  - Grandfather-father-son rules `keep_daily`, `keep_weekly`, `keep_monthly` and
    `keep_yearly` keep the newest dump of each of the last N periods once it is past
    `retention_days`.
  - `retention_max_size` caps the total size of all dumps, pruning the oldest first and never
    going below `retention_min_keep`.
  - `min_free_space` makes a backup prune first, then refuse to start rather than fill the
    disk.
  - `prune` reports the space freed, and `-n prune` says why each file would go.
- **Docker clients under systemd `PrivateTmp=true` (the shipped timer unit):**
  - MySQL-via-docker used to bind-mount its option file from dbtool's temp dir under `/tmp`.
    dockerd cannot see that directory and mounted an empty one, so timer backups ran without
    credentials. The option file now reaches the container through an environment variable.
  - Directory-format restore, `compare` and `--sample` extract into
    `<backup_dir>/.staging/` instead of `/tmp`, for the same reason.
  - The next backup removes staging directories more than a day old, including the copies
    earlier versions left behind.
- **Credentials no longer appear in `ps`.** `PGPASSWORD` was passed as `env PGPASSWORD=…` and
  `docker run -e PGPASSWORD=…`; it now goes through the environment only.
- Each MySQL client call gets its own option file. A streaming MySQL migrate shared one file
  between source and target, so either side could connect with the other's login.
- `test --deep` checked only the first entry when the client ran in docker: `docker run -i`
  consumed the loop's input. Fixed.
- MySQL `discover` listed one database named `0` (`||` is OR in MySQL). Fixed.
- A MySQL password containing a backslash failed through the option file. It is now escaped.
- A relative `backup_dir` is resolved to an absolute path, which Docker bind mounts need.
- `s3.keep_remote: false` now works: pruning also deletes the off-box copy and its sidecars.
  Previously the key was documented but ignored.
- **Smaller dumps:**
  - `exclude_table_data` (per entry, PostgreSQL) keeps a table's definition but drops its
    rows. The fingerprint records those tables as empty, so verification still passes.
  - `pg_compression: zstd|lz4|gzip|none` selects pg_dump's own compression for custom and
    directory dumps (zstd and lz4 need PostgreSQL 16+; otherwise dbtool falls back to gzip).
  - `compression_level` and `zstd_long` tune the compression of plain, directory and MySQL
    dumps.
- Directory-format backups no longer leave an uncompressed copy under
  `<backup_dir>/.staging/` (it was never removed; delete any old `*.dir` folders there).
- A streaming `migrate --verify-data` from an entry with `exclude_table_data` now expects those
  tables empty on the target, as `backup` and `restore` already did.
- Whole-number settings such as `keep_weekly: 08` no longer break bash arithmetic, and sizes
  like `5.5.5M` are rejected.

## 1.3.0

- **Data verification.** Backups write `<dump>.fingerprint.tsv`, containing per-table row
  counts (plus an order-independent content checksum with `fingerprint: full`), sequence values
  and object counts. These are taken in the same exported snapshot pg_dump uses, so they
  describe exactly what is in the dump, even on a live source.
- `restore` / `migrate --verify-data [counts|full]` (or `verify_data:` on a target) compare the
  restored database with the dump's fingerprint and, for `--latest` of a configured source,
  with the live source. Drift on the live source is reported as information only. Exits 1 on
  any difference and writes a report to `<backup_dir>/reports/`. A streaming migrate
  fingerprints the source in the snapshot it streams from.
- `dbtool compare [SOURCE] TARGET [--dump FILE | --latest NAME] [--full]` runs the same check at
  any time. For older dumps without a fingerprint it counts the rows in the dump's COPY data.
- `dbtool drill NAME -t SCRATCH` is a restore drill: it restores the newest backup, verifies
  it, prints the backup's age (RPO) and how long recovery took (RTO), then drops the scratch
  database.
- A restore now **refuses** a dump whose `.sha256` does not match (it used to warn and carry
  on), and runs `ANALYZE` after loading (`--no-analyze` to skip).
- `SOP.md`: the operating procedure for backup, restore, migration and restore drills.
- Entries filtered with `exclude_tables` / `schemas` / `-t` / `-n` record only the tables
  pg_dump really carries (asked of pg_dump in the same snapshot); object counts are not
  recorded for them. Inheritance parents are counted `ONLY`.
- `drill` refuses a target that points at a database a configured source backs up.

## 1.2.3

- `--search-path auto` builds the search_path from the schemas that own functions in
  the dump, plus `public`. Apps that migrate into their own schema (a DSN with
  `options=-c search_path=app`) failed with `--search-path public`, because the
  functions are not in `public`.
- The failure hint now lists the schemas that own functions in the dump, and says
  when a given search_path missed them.
- Mixed-case schema names are quoted in the `auto` search_path.
- A streaming `migrate` refuses `search_path: auto` before `--drop` touches the target
  (it has no dump file to read schemas from; use `--via-file` or name them).
- Docs: troubleshooting moved to `TROUBLESHOOTING.md`, with a full write-up of the
  "does not exist … during inlining" restore failure; README documents `targets:`
  and no longer carries the file tree.

## 1.2.2

- `restore` / `migrate --search-path public` (or `search_path:` on a target) restore a
  PostgreSQL dump whose CHECK constraints call SQL functions that name other functions
  without a schema. pg_restore runs with an empty `search_path`, so those failed with
  `function … does not exist … during inlining`; dbtool now rewrites that one statement
  and restores single-stream. A failed restore that hits this prints the fix.
- `POSTGRES_SUPPORT.md`: which PostgreSQL server versions each command supports, which
  cross-version restores and migrations work, and how the client is chosen.

## 1.2.1

- `self-update` now tracks the newest **published release** instead of the `main`
  branch; `--main` (or `DBTOOL_UPDATE_CHANNEL=main`) follows the branch, and
  `DBTOOL_UPDATE_URL` still overrides both. `DBTOOL_REPO` points it at a fork.
- Pushing a `vX.Y.Z` tag publishes the GitHub release: the workflow refuses a tag
  that disagrees with `DBTOOL_VERSION`, takes the notes from this file, and attaches
  `dbtool.sh` and `install.sh`.

## 1.2.0

- `all_databases: true` turns an entry into a whole server: dbtool enumerates the
  databases on every run, so one created later is backed up without a config change.
  `include_databases` / `exclude_databases` take globs. Each database becomes its own
  dump labelled `<entry>_<db>`.
- `discover [name|all] [--url DSN]` lists what a server actually holds, with sizes,
  marks what the config does not cover, and prints an entry to paste.
- `test --deep` proves a schedule will work: maintenance-database access, role
  privileges, client/server compatibility, and a real `--schema-only` dump of every
  database. Non-zero exit, so it can gate cron.
- `self-update [--check]` replaces the installed script with the latest release
  (verified to parse and to carry a version before it is swapped in).
- `install.sh` installs or updates in one command and never overwrites an existing
  `dbtool.yml` / `dbtool.env`.
- A whole-server entry is no longer a lookup group — prune takes its groups from the
  label in each sidecar, and `--latest <server-entry>` refuses with the usable labels.
- `maintenance_db` setting (default `postgres`).

## 1.1.x

- A dump killed mid-stream was reported as a successful backup: errexit was suppressed
  inside the per-database subshell, and verification only listed the archive header.
  Dumps are now read back in full (`verify: full|header|none`).
- `--latest` could restore a different database, and prune could delete the only copy
  of one, because lookups globbed `<entry>_*` and matched longer sibling entries.
- `globals` command for cluster roles and grants, included in `backup all`.
- `flock` on the backup directory; directory-format dumps stage next to the backups
  instead of in `/tmp`.
- A dry run no longer creates `.part` files, and orphaned ones are swept.
- A failed connection reports the real reason instead of a generic message.
