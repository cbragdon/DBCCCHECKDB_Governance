# DBCC CHECKDB Governance Strategy

## The Problem

SQL Server has a built-in health check called **DBCC CHECKDB**. It scans
every page in a database looking for corruption — physical damage, broken
index/allocation structures, data that's silently gone bad — the kind of
damage that doesn't announce itself until you try to read the wrong page
and get an error, or worse, silent bad data. It's the closest thing SQL
Server has to a full-body scan, and skipping it regularly is how small,
fixable corruption turns into a lost database.

The catch: running CHECKDB isn't free. It needs a snapshot of the database
and heavy use of tempdb, and on a large database that extra need can be
substantial. Without planning ahead, the check itself can fail or run the
server out of space — right when you need it working.

## The Solution

This project provides safe, repeatable scheduling and pre-flight validation
around CHECKDB, and it works the same way whether the database lives on a
**regular SQL Server VM** or an **Azure SQL Managed Instance (MI)** — same
governance, same checks, same reporting, regardless of platform.

Before the checks are ever turned on, it estimates how much extra
disk/tempdb space each database's CHECKDB run will need and compares that
to what's actually available, calling out real shortfalls instead of vague
"verify this yourself" reminders. It also tiers the workload — small
databases get a full check regularly, while very large databases (VLDBs)
get checked in rotating pieces over time so no single run risks the
business. And every time it runs, it re-validates space and tempdb
headroom automatically, so conditions that changed since setup get caught
before they cause a failure.

**Importantly, this isn't a replacement for your maintenance framework** —
it's a wrapper built on top of **Ola Hallengren's Maintenance Solution**,
specifically his `DatabaseIntegrityCheck` (CHECKDB) component. It doesn't
touch backups or index/statistics maintenance (that's `IndexOptimize`, a
separate part of Hallengren's toolkit) — it adds tiering strategy, capacity
planning, and pre-flight safety on top of the integrity-check piece
Hallengren already provides.

This folder contains a complete, deployable strategy for running `DBCC CHECKDB`
integrity checks across a SQL Server estate with mixed database sizes
(from ~10 GB up to 32+ TB), built on top of **Ola Hallengren's SQL Server
Maintenance Solution**.

## Contents

See [`File-Reference.md`](File-Reference.md) for a full description of every
file in this folder and what it does.

## Prerequisites

1. **Ola Hallengren's Maintenance Solution** must already be installed on every
   target instance. Download `MaintenanceSolution.sql` (or just
   `DatabaseIntegrityCheck.sql` if you only want integrity checks) from:
   - https://ola.hallengren.com/
   - https://github.com/olahallengren/sql-server-maintenance-solution
2. SQL Server Agent must be enabled (default on box product and Managed Instance;
   not applicable/needed for Azure SQL Database, which this solution does not target).
3. The maintenance database must be at **compatibility level 110 or higher**
   (Ola Hallengren's `DatabaseIntegrityCheck` does not compile below 110).
   `Install-DBCCGovernanceToolkit.ps1` checks this and stops cleanly for a
   lower level. The databases being *checked* can be at any level.

## Quick Start

```sql
-- 1. Install Ola Hallengren's MaintenanceSolution.sql first (not included here).

-- 2. Deploy the procedures to the same database as Hallengren's scripts
--    (a DEDICATED maintenance database, e.g. [DBAdmin] or [DBA] - NEVER [master]).
--    :r needs SQLCMD mode in SSMS. Check_DiskAndTempdbHeadroom first: the
--    others call it. (Or run Install-DBCCGovernanceToolkit.ps1, which deploys
--    all six and installs Hallengren's prerequisite if it is missing.)
:r Split_DatabaseList.sql
:r Check_DiskAndTempdbHeadroom.sql
:r Run_TieredIntegrityCheck.sql
:r Rotate_VLDB_ObjectLevelChecks.sql
:r Run_LargeTier_WeeklyFullCheck.sql
:r Precheck_RequiredSpaceForSetup.sql

-- 3. Edit @MaintenanceDB (must not be 'master') and @VLDBDatabaseList in
--    Deploy_SQLAgentJobs.sql if you have VLDB databases, then deploy the
--    SQL Agent jobs (nightly tiered check, weekly VLDB rotation,
--    weekly Large-tier full check):
:r Deploy_SQLAgentJobs.sql

-- 4. Test manually before relying on the schedule:
EXEC dbo.Run_TieredIntegrityCheck;

-- 5. Monitor for failures AND interrupted/orphaned runs (e.g. after a patching
--    reboot mid-check):
:r Monitor_CommandLog_Status.sql

-- 6. After the jobs have run a few times, verify the schedule doesn't create
--    overlapping runs (violates the sequential-execution sizing assumption):
:r Check_JobScheduleOverlap.sql
EXEC dbo.Check_JobScheduleOverlap;

-- 7. (Optional, recommended after any threshold/logic edit) Run the
--    regression test suite - no dependencies, safe on any database:
:r Tests_CoreLogic.sql
```

## Testing

Two levels of tests, both self-checking (each prints PASS/FAIL rows and a
`N test(s) run, N passed, 0 failed` line, and raises severity 16 on any
failure):

- `Tests_CoreLogic.sql` checks copies of the core expressions (tier
  boundaries, materiality, overlap math). It needs nothing installed.
- `tests/checks/*.sql` run the **installed** procedures against throwaway
  `DBCCGovTest_*` databases: tier routing with `PHYSICAL_ONLY`/`MAXDOP`,
  simulated availability-group roles, awkward database names (`&`, `'`,
  `,`), the VLDB rotation (coverage, time limit, dropped tables), the
  tempdb free-space figure, and the job-overlap verdicts including runs that
  cross midnight. Where a real 500 GB database or real `msdb` jobs would be
  needed, the check builds a test copy of the installed procedure with a few
  counted text edits (scaled tier sizes, test tables) and runs that.

`tests/Run-Checks.ps1` runs all of them on a test instance: it creates a
disposable maintenance database at each compatibility level you give it,
installs the toolkit with the installer, runs every check, and drops it
again:

```powershell
.\tests\Run-Checks.ps1 -ServerName localhost -CompatibilityLevel 100,110,120,130,140,150,160,170
.\tests\Run-Checks.ps1 -ServerName localhost -CompatibilityLevel 100,110,120,130,140,150,160,170 -LegacyCardinalityEstimation
```

The latest results are in
[`docs/LOCAL_TEST_RESULTS_20261026.md`](docs/LOCAL_TEST_RESULTS_20261026.md).

See `Deployment-Guide.md` for full details, and `Tiering-Strategy.md` /
`Platform-Compatibility.md` for the reasoning behind the design decisions.

## Scope / Not Included

- Backup jobs and index/statistics maintenance (use Hallengren's
  `DatabaseBackup` and `IndexOptimize` procedures directly — this repo is
  integrity-check-focused only).
- Alerting/notification integration (email, Teams, PagerDuty, etc.) — hook
  into `CommandLog` or SQL Agent job failure notifications per your existing
  monitoring stack.
- Azure SQL Database (single-database PaaS) — use Hallengren's
  `MaintenanceSolutionAzureSQLDatabase.sql` instead; the procs in this folder
  intentionally reject that platform (`EngineEdition = 5`).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for what to include in a report, the tests a change must pass, and the rules every change keeps.

## License

[MIT](LICENSE). The vendored Ola Hallengren Maintenance Solution files in
`vendor/OlaHallengrenMaintenanceSolution/` are covered by their own MIT license,
reproduced in that folder's [README](vendor/OlaHallengrenMaintenanceSolution/README.md).
