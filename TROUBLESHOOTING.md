# Troubleshooting

Quick reference first; the longer cases follow below it.

| Symptom | Cause / fix |
|---|---|
| `cannot reach PostgreSQL … check pg_hba` | The probe query failed. Verify host/port/user/password, and that `pg_hba.conf` allows the source IP with `md5`/`scram`. |
| `cannot pull a postgres:<n> client image` | Registry unreachable. Pre-pull on a connected host, push to `registry.example.com`, and set `image:` on the entry to your mirrored tag. |
| MySQL dump fails on `PROCESS privilege` | Already handled with `--no-tablespaces`; if a custom `dump_args` overrides it, put it back. |
| `pg_restore: error: could not execute query … already exists` | Target isn't empty. Use `--drop`, or set `clean: true` on the target for `--clean --if-exists`. |
| `function X(...) does not exist` … `during inlining` while COPYing a table | See [Restore fails: function does not exist during inlining](#restore-fails-function-does-not-exist-during-inlining). |
| `pg_restore: error: unsupported version (…) in file header` | Restoring a dump into an **older** PostgreSQL major. Not supported; see [POSTGRES_SUPPORT.md](POSTGRES_SUPPORT.md). |
| `write /dev/stdout: broken pipe` after a restore error | Harmless: the dump reader was still writing when the restore stopped on the real error printed above it. |
| `data verification FAILED` after a restore | See [Reading a data verification report](#reading-a-data-verification-report). |
| Need to see *which* values differ | `dbtool compare TARGET --latest NAME --sample schema.table`; see [Looking at the rows](#looking-at-the-rows---sample). |
| `checksum MISMATCH … refusing to restore it` | The dump changed after it was written (disk/copy damage, or edited). Use another dump; `dbtool verify FILE` to confirm. |
| Restore is slow | Custom/directory dumps restore with `-j <jobs>`; raise `jobs` in `defaults` or on the target entry. (`--search-path` restores are single-stream.) |
| `zstd not installed — falling back to gzip` | Install `zstd`, or set `compression: gzip` to silence it. |

## Restore fails: function does not exist during inlining

```
pg_restore: error: COPY failed for table "model_run_bindings": ERROR:  function model_capabilities_contract_valid(jsonb, text) does not exist
…
CONTEXT:  SQL function "model_role_capabilities_eligible" during inlining
COPY model_run_bindings, line 1: "…"
```

**You do not need to run the app's migrations on the target first.** The dump already
carries the full schema, and migrating first fails the same way.

### Cause

The dump is fine; the schema depends on `search_path`.

- A table has a `CHECK` constraint that calls a `LANGUAGE sql` function (here
  `model_role_capabilities_eligible`).
- That function's body calls another function **without a schema prefix**
  (`model_capabilities_contract_valid(...)` instead of `app.model_capabilities_contract_valid(...)`),
  and the function has no `SET search_path` of its own.
- pg_dump makes every restore run with `search_path = ''` (deliberately, for security).
  When COPY loads rows, the CHECK runs, the inner name cannot be resolved, and the restore
  stops.

The application never sees this because its connections have a `search_path` set. So
**every** plain restore of such a database fails, even onto the server it came from;
`verify: full` does not catch it because it reads the archive without restoring it.

### Fix while restoring

```bash
dbtool restore --latest <name> -t <target> --drop --search-path auto
```

- `--search-path auto` reads which schemas own functions in the dump and restores with
  `<those schemas>,public`.
- Or name them yourself: `--search-path app,public`.
- Or set it on the target in `dbtool.yml` so you never have to pass it:

  ```yaml
  targets:
    staging_pg:
      url: "postgresql://postgres:${STAGING_PG_PASSWORD}@10.0.0.9:5432/app_dev"
      create: true
      search_path: auto
  ```

dbtool rewrites only the dump's one `set_config('search_path', '', false)` statement and
restores single-stream (`pg_restore | psql`, so `-j` is not used). No object in the schema is
changed.

**`--search-path public` is not enough when the app uses its own schema.** If the app's DSN
sets `options=-c search_path=app`, its tables and functions live in `app`, not `public`, and
the restore fails again with the same error. Use `auto`, or find the schema on the source:

```sql
SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = '<the missing function>';
```

When a restore fails this way, dbtool prints the schemas the dump's functions live in, and
says when the `search_path` you gave missed them.

With `migrate`: a streaming migrate has no dump file to read schemas from, so `auto` needs
`--via-file`; otherwise name the schemas (`--search-path app,public`).

Use `--drop` (or `clean: true`) when retrying: a failed restore leaves a half-restored database.

### Lasting fix (in the application's schema)

Give the outer function its own `search_path`, or schema-qualify the inner call, in a new
migration:

```sql
ALTER FUNCTION model_role_capabilities_eligible(jsonb, text) SET search_path = app;
-- or, in the function body:  app.model_capabilities_contract_valid(...)
```

Do this for every SQL function used in a CHECK, index or generated column that calls other
functions unqualified. After that, plain restores work and `--search-path` is not needed.

## Reading a data verification report

`--verify-data`, `compare` and `drill` print what differs and write the full table to
`<backup_dir>/reports/verify_<target>_<time>.txt`.

| Status | Against the **dump** (or the source snapshot) | What to do |
|---|---|---|
| `OK rows` / `OK rows+checksum` | Identical. | Nothing to do. |
| `MISSING in restored` | The dump has data for a table that the restore doesn't have. | The restore failed part-way, or a filter (`restore_args`, `-n`) skipped it. Restore again. |
| `ROW COUNT DIFFERS (±N)` | Rows were lost or added. | Restore again with `--drop`. Check for triggers on the target that insert or delete during load. |
| `DATA DIFFERS (checksum)` | Same number of rows, different values. | See the checksum caveats below. Otherwise the copy is corrupt; restore again. |
| `SEQUENCE BEHIND` | A sequence is lower than in the dump. | New inserts would collide with existing ids. Fix it with `SELECT setval(...)` or restore again. |
| `OBJECT COUNT DIFFERS` | Functions, indexes, constraints, triggers or views are missing or extra. | Look for errors in the restore log. A target that was not empty (no `--drop`) shows extras. |
| `only in restored` (warning) | The target has a table that the dump doesn't. | The target was not empty. Use `--drop` for a clean copy. |
| `source +N rows since backup` (info) | The live source has changed since the dump. | Expected on a live system. Not a restore problem. |

Without a dump fingerprint (comparing two live databases), every difference is reported as
a failure, because dbtool cannot tell writes made after the backup apart from real loss.
Compare against the dump (`--latest NAME` or `--dump FILE`) for an exact verdict.

**Checksum caveats.** Checksums hash each row's text form. dbtool fixes the session settings
that change that text (`TimeZone`, `DateStyle`, `IntervalStyle`, `extra_float_digits`,
`bytea_output`, `lc_monetary`), so the same data hashes the same on both sides. A checksum
can still differ while the data is the same if:
- the target runs a different PostgreSQL **major** version and a type's text form changed
  between versions;
- a column type has no stable text form;
- a type's output depends on the server's locale.

In those cases rely on `counts`, and look at the rows with `--sample` (below).

### Looking at the rows: `--sample`

`dbtool compare TARGET --latest NAME --sample schema.table --rows 5` prints random rows from the
restored database, the dump and the live source side by side. For a `DATA DIFFERS (checksum)`
table, this shows which column holds the difference.

| Row verdict | Meaning |
|---|---|
| `MATCHES dump` | Every column is identical. |
| `DIFFERS from dump (N column(s))` | The restored row differs. Look at the `DIFF` cells; a value that looks the same is often trailing whitespace or a float digit. |
| `NOT IN DUMP` | The row exists in the restored database but not in the dump: the target was not empty, or something inserted it after the restore. |
| `changed in source since backup` / `deleted in source since backup` | The live source changed after the dump. Information only. |

Messages you may see:
- `has no primary key or NOT NULL unique key`: name the columns that identify a row with
  `--key col1,col2`.
- `does not identify a row ... uniquely`: the `--key` columns repeat in the table; add the columns
  that make a row unique.
- `is ambiguous`: write it as `schema.table`.
- `is partitioned`: sample one of its partitions. The dump holds data per partition.
- `could not load the dump's rows into a temp table`: the target user cannot create
  temporary tables (or the target is a read-only standby). Grant `TEMP` on the database, or
  sample against a writable copy.
