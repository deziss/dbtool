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
