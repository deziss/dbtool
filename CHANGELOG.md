# Changelog

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
