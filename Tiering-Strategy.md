# Tiering Strategy

There is no official Microsoft-defined size threshold for CHECKDB strategy —
these tiers are practical defaults based on typical runtime/I/O impact. Tune
the boundary variables (`@SmallMaxGB`, `@MediumMaxGB`, `@LargeMaxGB`) in
`Run_TieredIntegrityCheck.sql` to match observed runtimes in your environment;
size is a proxy for runtime/impact, not the real driver.

## Tiers

| Tier | Size Range (default) | Strategy | Frequency |
|---|---|---|---|
| **Small** | < 50 GB | Full `DBCC CHECKDB` | Nightly |
| **Medium** | 50 GB – 500 GB | Full `DBCC CHECKDB`, time-boxed (`@TimeLimit`) | Nightly |
| **Large** | 500 GB – 2 TB | `PHYSICAL_ONLY` nightly, reduced `@MaxDop` on Managed Instance; **full logical `CHECKDB` weekly** (`Run_LargeTier_WeeklyFullCheck.sql`) | Nightly (physical) + weekly (full logical) |
| **VLDB** | >= 2 TB | `PHYSICAL_ONLY` nightly + rotating `CHECKTABLE`/`CHECKALLOC`/`CHECKCATALOG` batches for full logical coverage over a multi-week cycle | Nightly (physical) + weekly (rotation) |

## Why size alone isn't the full picture

What actually determines the right tier for a specific database:

- **Measured CHECKDB runtime** in your environment — a heavily-indexed 2 TB
  OLTP database may take longer than a 5 TB mostly-static archive database.
  Baseline each database once (`DBCC CHECKDB WITH PHYSICAL_ONLY` and a full
  run) and bucket by *actual runtime*, not raw GB, if your environment
  deviates significantly from the size assumptions above.
- **Available maintenance window** — if a database can't finish within the
  window, it needs the VLDB-style rotation/offload treatment regardless of
  its GB size.
- **tempdb capacity** — CHECKDB needs internal snapshot space; high
  row/version churn increases this need independent of database size.
- **Corruption tolerance / business criticality** — a small but
  mission-critical database may warrant nightly full checks even if it would
  otherwise sit at the low end of a tier; a huge but low-priority archive
  database may only need monthly full logical coverage.

## Why the Large tier needs a separate weekly full-logical job

`PHYSICAL_ONLY` is a **modifier on `DBCC CHECKDB`**, not a distinct check —
Hallengren's `CommandLog.CommandType` logs both as `DBCC_CHECKDB` regardless
(the actual option used is only visible in the `Command` text column). This
means a database that only ever runs with `@PhysicalOnly = 'Y'` will **never**
receive catalog consistency or full cross-object logical validation, no
matter how many nights pass. `Run_LargeTier_WeeklyFullCheck.sql` closes this
gap for the Large tier by running a full (non-`PHYSICAL_ONLY`) `CHECKDB` on a
weekly cadence, time-boxed via `@TimeLimitSeconds`, and only on the primary
AG replica (full logical checks require primary-equivalent access - see
`Platform-Compatibility.md`).

## VLDB full logical coverage (why it's a separate job)

At 32 TB, a full `DBCC CHECKDB` is not practical nightly (runtime, tempdb,
I/O, and locking impact are all too high). The recommended approaches, in
order of preference:

1. **Rotate object-level checks** (`Rotate_VLDB_ObjectLevelChecks.sql`) —
   splits `CHECKTABLE` (plus `CHECKALLOC`/`CHECKCATALOG`) across a subset of
   tables per scheduled run, so every table gets a full logical check over a
   multi-week cycle, while nightly `PHYSICAL_ONLY` still catches torn
   pages/checksum failures every day.
2. **Offload to a restored backup copy** — restore the latest backup to a
   secondary/dedicated server and run full `DBCC CHECKDB` there instead of
   production. This validates the backup *and* checks integrity without
   burning production resources. Not included as a script here since it
   depends heavily on your restore/DR tooling, but pairs well with
   Hallengren's `DatabaseRestore` script.
3. **Always keep page checksum verification enabled** (default in modern SQL
   Server) so corruption is detected on every read/write, reducing reliance
   on CHECKDB alone for corruption detection between full logical passes.

## Tuning the thresholds

Edit these variables near the top of `Run_TieredIntegrityCheck.sql`:

```sql
DECLARE @SmallMaxGB  DECIMAL(18,2) = 50;
DECLARE @MediumMaxGB DECIMAL(18,2) = 500;
DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;   -- 2 TB
```

And in `Rotate_VLDB_ObjectLevelChecks.sql`, tune the rotation cadence:

```sql
@DaysInCycle INT = 7   -- number of scheduled runs to complete one full rotation
```
