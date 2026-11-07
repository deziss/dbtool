# Changelog

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
