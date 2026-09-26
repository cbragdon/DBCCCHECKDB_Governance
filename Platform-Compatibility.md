# Platform Compatibility

## Supported Versions & Platforms

| Platform | Support Level |
|---|---|
| SQL Server 2016 (SP2+) | Full support |
| SQL Server 2016 (pre-SP2) | Supported, but `@MaxDop` auto-disabled by build detection (see below) |
| SQL Server 2017 – 2025 | Full support |
| Azure SQL Managed Instance (General Purpose & Business Critical) | Full support |
| Azure SQL Database (single-db PaaS) | **Not supported** — `Run_TieredIntegrityCheck` explicitly rejects `EngineEdition = 5`. Use Hallengren's `MaintenanceSolutionAzureSQLDatabase.sql` instead. |

## Ola Hallengren's Maintenance Solution

Confirmed to fully support SQL Server 2025 (including new features like ZSTD
backup compression) and Azure SQL Managed Instance via the standard
`MaintenanceSolution.sql` / `DatabaseIntegrityCheck.sql` — no special/separate
script is required for MI (that's only needed for Azure SQL Database).

The scripts in this folder build **on top of** Hallengren's
`DatabaseIntegrityCheck` procedure; they do not replace or modify it.

## AlwaysOn Availability Groups

- `DBCC CHECKDB` with full logical checks requires read/write-capable access
  and cannot reliably run against read-intent-only secondary replicas —
  logical/extended logical checks can fail silently or error there.
- **`PHYSICAL_ONLY` checks are safe on both primary and secondary replicas.**
- `Run_TieredIntegrityCheck` detects AG role via
  `sys.dm_hadr_availability_group_states` and:
  - Runs Small/Medium tier **full CHECKDB only on the primary**.
  - Runs Large/VLDB tier **`PHYSICAL_ONLY` on both primary and secondary**
    replicas (identical job/schedule can be deployed to every replica).
- On standalone instances or General Purpose tier Managed Instance (no AG
  present), the role check returns `NULL` and is treated as primary, so full
  checks are not skipped incorrectly.
- Business Critical tier Managed Instance uses AG-based HA internally, so the
  same AG-role logic applies there without modification.

## Azure SQL Managed Instance specifics

- `EngineEdition = 8` identifies Managed Instance (detected automatically).
- MI tempdb capacity is **fixed by service tier/vCore** and cannot be
  manually grown — `Run_TieredIntegrityCheck`'s tempdb free-space warning
  message is worded differently for MI (recommends scaling up tier / reducing
  concurrent jobs) vs. box product (recommends checking autogrowth/disk
  space).
- `@MaxDop` is reduced on MI for Large/VLDB tiers (2 and 1, vs. 4 and 2 on box
  product) to lower tempdb spill risk under MI's shared compute/storage
  model.
- MI supports SQL Agent jobs natively, so `Deploy_SQLAgentJobs.sql` works
  unchanged.

## `@MaxDop` build-level compatibility

`DatabaseIntegrityCheck`'s `@MaxDop` parameter requires:

- SQL Server 2016 **SP2 or later** (build >= 13.0.5026), or
- SQL Server 2017 or later, or
- Azure SQL Managed Instance (always current — always supported)

`Run_TieredIntegrityCheck` detects this automatically by parsing
`SERVERPROPERTY('ProductVersion')` and conditionally includes `@MaxDop` in
the generated `EXEC` call via dynamic SQL (`sp_executesql`) — **no manual
per-instance tracking is required**. If a pre-SP2 2016 instance is detected,
an informational message is raised (non-blocking) noting that the tier ran
without `@MaxDop`.

## JSON Indexes (SQL Server 2025 / Managed Instance)

SQL Server 2025 introduces a native `JSON` data type and `CREATE JSON INDEX`.
**No special handling is required** in this solution:

- `DBCC CHECKDB` treats JSON indexes like any other index type — it validates
  the JSON index B-tree structure and metadata consistency automatically as
  part of standard logical and physical checks.
- JSON indexes require a clustered primary key on the table (enforced by SQL
  Server itself at `CREATE JSON INDEX` time, not something this solution
  needs to check for).
- These checks only activate when the database is at compatibility level 170
  (SQL Server 2025). Databases at lower compatibility levels simply won't
  have JSON indexes to check, so behavior is unaffected either way.

## Known risk: tempdb resource exhaustion on Large/VLDB full logical checks

Live testing on a 1.5TB Large-tier database (`WINS_Analysis`, a lab box-product
instance) surfaced a real-world failure mode that is distinct from
database corruption and worth planning for before enabling
`Run_LargeTier_WeeklyFullCheck` (or any full, non-`PHYSICAL_ONLY` CHECKDB)
against your largest databases:

- The full logical `CHECKDB` (with `DATA_PURITY`) failed after ~1h13m with
  **`Msg 823, Severity 24, State 6`**, terminating the check abnormally.
- The error log showed the true cause was **not** page corruption but a
  **tempdb write failure**:
  ```
  Error: 823, Severity: 24, State: 12.
  The operating system returned error 1450 (Insufficient system resources
  exist to complete the requested service.) to SQL Server during a write at
  offset ... in file 'T:\SQL_TempDB\tempdev3.ndf'.
  ```
- OS error **1450** is a Windows-level resource-exhaustion condition
  (commonly non-paged pool / outstanding I/O request limits under sustained
  heavy I/O), not a storage/disk corruption event. Full logical checks
  against multi-hundred-GB/TB databases generate substantial tempdb worktable
  activity (sorts for index/allocation validation), and an undersized or
  resource-constrained tempdb volume can exhaust OS-level I/O resources
  before it runs out of free space.
- **This is a gap in the current tempdb safeguard**: the free-space warning
  built into `Run_TieredIntegrityCheck` / `Run_LargeTier_WeeklyFullCheck`
  checks *capacity* (bytes free), not *system-level I/O resource pressure*,
  so it will not predict or prevent this failure mode.

**Before enabling full-logical checks (`Run_LargeTier_WeeklyFullCheck`, or
any VLDB full CHECKDB) against your largest databases in production:**

- Confirm the tempdb volume has generous free space headroom (not just
  "enough," but substantial margin) for the size of database being checked.
- Review host/VM-level I/O and memory limits (especially on virtualized or
  resource-capped environments) — sustained high-IOPS workloads like a full
  CHECKDB on a multi-TB database can trigger OS resource exhaustion even when
  disk space itself is not the constraint.
- Consider running the first full-logical check for a new Large/VLDB
  database during a low-activity maintenance window, and monitor
  `sys.dm_os_sys_info` / OS perf counters (available non-paged pool,
  outstanding I/Os) while it runs, rather than assuming success on the first
  attempt.
- A failure of this kind does **not** indicate database corruption — verify
  by checking the error log message text (look for `Error 823` combined with
  an OS-level error like 1450, vs. genuine consistency errors like 8928/8944)
  before treating it as a corruption incident.

## Version detection reference

`Run_TieredIntegrityCheck` uses:

```sql
SERVERPROPERTY('EngineEdition')   -- 8 = Managed Instance, 5 = Azure SQL DB (rejected)
SERVERPROPERTY('ProductVersion')  -- parsed via PARSENAME for major version / build number
```

EngineEdition reference values:

| Value | Meaning |
|---|---|
| 1 | Personal/Express (legacy) |
| 2 | Standard |
| 3 | Enterprise |
| 4 | Express |
| 5 | Azure SQL Database |
| 6 | Azure Synapse Analytics |
| 8 | Azure SQL Managed Instance |
| 9 | Azure SQL Edge |
| 11 | Azure Synapse serverless SQL pool |
