# PostgreSQL version support

dbtool asks the server for its version on every run (`SHOW server_version`) and picks a
client of at least that major version: your native `pg_dump`/`pg_restore` if it is new
enough, otherwise the `postgres:<major>-alpine` container (falling back to `postgres:<major>`).
So support depends mostly on which client images exist and on what pg_dump itself supports.

Legend: ✅ supported · ⚠️ works with a limit (see note) · ❌ not supported

## Server versions

| Server major | Backup (custom / plain / directory) | Restore | Migrate (streaming) | Globals (`include_globals`) | `discover` / `test --deep` | `--search-path` restore | Client image | Verified |
|---|---|---|---|---|---|---|---|---|
| 18 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:18-alpine` | native 18 client against a 17 server |
| 17 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:17-alpine` | CI on every push; manual round-trip in docker and native mode |
| 16 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:16-alpine` | by design, not in CI |
| 15 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:15-alpine` | by design, not in CI |
| 14 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:14-alpine` | by design, not in CI |
| 13 (EOL) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:13-alpine` | by design, not in CI |
| 10 – 12 (EOL) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `postgres:1x-alpine` | by design, not in CI |
| 9.4 – 9.6 (EOL) | ✅ | ✅ | ✅ | ⚠️ [1] | ✅ | ✅ [2] | `postgres:9.x-alpine` | not tested |
| 9.2 – 9.3 (EOL) | ✅ | ⚠️ [3] | ⚠️ [3] | ⚠️ [1] | ✅ | ⚠️ [2] | `postgres:9.x` | not tested |
| < 9.2 | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | — | modern pg_dump refuses these servers |

1. A non-superuser gets globals without role passwords via `--no-role-passwords`, which
   `pg_dumpall` only has from 10. On 9.x, run globals as a superuser.
2. The rewrite targets the `set_config('search_path', '', false)` line that pg_dump has
   emitted since 10.3 / 9.6.8 / 9.5.12 / 9.4.17 / 9.3.22. A dump made by an older client
   has no such line: dbtool warns and restores it unchanged (it never needed the fix).
3. `clean: true` uses `--clean --if-exists`, which needs pg_restore 9.4+. Leave `clean`
   off for these targets.

## Restoring or migrating across versions

The client is chosen from the **target** server, and pg_restore cannot read an archive
written by a newer pg_dump.

| Source → target | Restore a dump | Migrate (streaming) | Migrate `--via-file` |
|---|---|---|---|
| Same major | ✅ | ✅ | ✅ |
| Older → newer (upgrade, e.g. 15 → 17) | ✅ | ✅ | ✅ |
| Newer → older (downgrade, e.g. 17 → 15) | ❌ `unsupported version in file header` | ❌ | ❌ |

For a downgrade, dump as plain SQL (`format: plain`) and expect to fix any syntax the
older server lacks by hand.

## Client selection

| `docker:` setting | Native client ≥ server major | Native client older / missing |
|---|---|---|
| `auto` (default) | native | container `postgres:<major>-alpine`; with no docker, the older native client and a warning |
| `always` | container | container |
| `never` | native | native with a warning (may fail); missing client is an error |

Set `image:` on an entry to pin a specific client image (for example a private mirror).

## Notes

- Extensions (PostGIS, pgvector, TimescaleDB …) must already be installed on the target
  server. dbtool restores the `CREATE EXTENSION`, not the extension's binaries.
- Managed services (RDS, Cloud SQL, Azure) work as long as the user can read every table.
  Globals from these need `--no-role-passwords`, which dbtool adds automatically for a
  non-superuser.
- MySQL / MariaDB support is not covered here.
