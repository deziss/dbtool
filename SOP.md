# Standard operating procedure: backup, restore, migration

How to run PostgreSQL (and MySQL) backups, restores and server moves with dbtool, and the
evidence each step must leave behind. Every step names the dbtool command that does it, so
the procedure and the tool stay in step.

The principles behind it:

- **A backup only counts once it has been restored.** Proving the file can be read is not
  enough. Restore drills are scheduled, not optional.
- **Verify against a fixed reference.** The live source keeps changing, so a restore is
  checked against the dump's own snapshot, not against whatever the source holds now.
- **3-2-1.** Three copies, on two kinds of storage, one of them off the box (`s3:` upload).
- **Nothing destructive happens without a prompt** (`--drop`), and nothing irreversible
  happens before the backup that undoes it.
- **Every run leaves a record:** a log line, a `.meta.json`, a `.fingerprint.tsv` and, after
  a verification, a report under `<backup_dir>/reports/`.

## Targets to agree on first

| Measure | Meaning | Where dbtool shows it |
|---|---|---|
| **RPO** (recovery point objective) | How much data you can afford to lose; set by the backup interval. | The backup timer (`systemd/dbtool-backup.timer`); `drill` prints the age of the backup it restored. |
| **RTO** (recovery time objective) | How long a recovery may take. | `drill` prints how long restore plus verify took. |
| Retention | How far back you can go. | `retention_days`, `retention_min_keep`. |

dbtool takes logical dumps. Its RPO is the interval between backups. If you need
point-in-time recovery (RPO in minutes), run WAL archiving (pgBackRest, WAL-G or Barman)
alongside it. Use dbtool for portable copies, migrations and drills.

---

## 1. Backup

### Set up once

1. Store the config at `/etc/dbtool/dbtool.yml` (mode 600) and keep secrets in `env_file`,
   never in git.
2. In `defaults`, set:
   - `verify: full`: read the whole archive back before accepting the dump;
   - `fingerprint: counts`, or `full` for content checksums;
   - `include_globals: true`: also back up roles and grants;
   - `retention_*` to match your agreed retention;
   - `s3:` for the off-box copy.
3. Run `dbtool discover`. Every database marked `NOT BACKED UP` gets an entry, or a written
   reason why it doesn't need one.
4. Run `dbtool test --deep`. It must pass: the server is reachable, the backup user has the
   right privileges, the client version matches the server, and every database dumps.
5. Enable the systemd timer and `notify:`, so a failed backup alerts someone.

### What every backup run does (automatically)

| Step | Standard | dbtool |
|---|---|---|
| Consistent copy | One snapshot for the whole database. | pg_dump runs in a single transaction, using the exported snapshot. |
| Data fingerprint | Row counts (plus checksums with `full`) and sequences, taken in **the same snapshot** pg_dump uses. | `<dump>.fingerprint.tsv` |
| Integrity | The archive must be readable end to end. | `verify: full`, then `.sha256` |
| Metadata | Source, server version, format, size, time. | `.meta.json` |
| Atomic write | No half-written file may look like a backup. | Writes to a `.part` file and renames it only after the dump succeeds and verifies. |
| Off-box copy | Second location. | `s3:` upload of the dump and all its sidecars |
| Retention | Prune old dumps, but always keep the newest N. | `prune` runs after `backup all` |
| Roles and grants | Needed to restore onto a new server. | `globals_*.sql` per server |

### Checks

- **Daily:** the timer ran and no failure alert fired (`journalctl -u dbtool-backup`,
  `/var/log/dbtool.log`).
- **Weekly:** `dbtool list` shows a fresh dump for every database; spot-check one with
  `dbtool verify <file>`.
- **Monthly** (or after a schema change), run a restore drill, see [section 4](#4-restore-drill).

---

## 2. Restore

### Before you restore

1. **Choose the dump.** Use `--latest NAME` or a specific `-f FILE`, and note its timestamp:
   that is the point you are restoring to.
2. **Check compatibility.** The target's PostgreSQL major version must be the same as the
   source's or newer ([POSTGRES_SUPPORT.md](POSTGRES_SUPPORT.md)). Extensions used by the
   source must be installed on the target.
3. **Restore roles first** on a new server: `psql -f globals_<server>_*.sql`.
4. **Check space.** Free space on the target should be at least 2× the database size.
5. **Plan for the target's current contents.** Never restore over a database that is in use.
   Restore into a new name with `--database`, or schedule a window and use `--drop`.
6. **Decide on `search_path`.** If the app keeps its tables in its own schema, use
   `--search-path auto`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Run

```bash
dbtool restore --latest app_prod -t staging_pg --drop --search-path auto --verify-data full
```

dbtool then does the following:
1. Refuses the dump if its `.sha256` does not match.
2. Asks before dropping the target, then creates it and restores.
3. Runs `ANALYZE`, because planner statistics are not part of a dump.
4. **Verifies the data.** It compares the restored database with the dump's fingerprint
   (exact) and, when `--latest` names a configured source, with the live source (drift is
   reported as information only). It writes a report and exits with status 1 if anything
   differs.

### Accept the restore when

- the verification is green: every table matches the dump on row count (and checksum in
  `full` mode), no sequence is behind, and the object counts match;
- a row sample of the most important tables (`dbtool compare <target> --latest <name> --sample
  schema.table --rows 5`) shows `MATCHES dump` for every row;
- the application starts against the restored database and passes a smoke test;
- the report path is recorded in the change ticket.

**If verification fails, do not put the database into service.** Read the report:
`MISSING`, `ROW COUNT DIFFERS`, `DATA DIFFERS` or `SEQUENCE BEHIND` against the **dump**
means the restore is wrong. A difference against the **live source** only means the source
changed after the backup.

---

## 3. Migration (server to server)

### Plan

1. Agree the window, the freeze on writes (if any), the rollback path and who decides go/no-go.
2. Run `dbtool test` on both ends, then `dbtool test --deep` on the source.
3. Check that the target is the same PostgreSQL major or newer, with the same extensions.
   Restore roles with globals.
4. Rehearse: `dbtool migrate --from app_prod --to new_pg --create --via-file --verify-data -n`
   (a dry run), then one real run into a scratch database. Note how long it took; that is
   your downtime estimate.

### Cut-over

```bash
dbtool backup app_prod                                   # safety net, fingerprinted
# stop writes to the source (application in maintenance mode, or revoke write)
dbtool migrate --from app_prod --to new_pg --drop --verify-data full -y
#   streaming: source fingerprinted in the snapshot pg_dump uses -> exact check
#   add --search-path auto with --via-file for apps that use their own schema
```

1. The verification must be green. If it isn't, stop and roll back (the application stays on
   the source).
2. Point the application at the new server and run its smoke test.
3. Keep the source **read-only and running** until the new server has run cleanly in
   production for the agreed period; that is your rollback.
4. After that period, take a final backup of the source and then decommission it.

### Evidence to keep

The safety-net dump and its `.fingerprint.tsv`, the verification report, the dbtool log for
the window, and the go/no-go decision.

---

## 4. Restore drill

Prove on a schedule that recovery works and meets RPO and RTO:

```bash
dbtool drill app_prod -t drill_scratch --full -y
```

A drill:
1. restores the newest backup into a scratch target (it must be listed under `targets:`);
2. verifies the data against the dump;
3. prints `DRILL PASSED`, with the backup's age (RPO) and how long restore plus verify took
   (RTO);
4. drops the scratch database (`--keep` leaves it in place for inspection).

It also writes a `DRILL … result=pass` line to the log, so your monitoring can alert when no
drill has passed recently. Run it monthly for every important database (a second systemd
timer works well), and after major upgrades or schema changes.

---

## 5. Roles and responsibilities (fill in)

| Activity | Owner | Frequency |
|---|---|---|
| Backup monitoring | | daily |
| Restore drill | | monthly |
| Restore into production | | on incident, needs approval |
| Migration go/no-go | | per change |
