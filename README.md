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

## Quick Start

```sql
-- 1. Install Ola Hallengren's MaintenanceSolution.sql first (not included here).

-- 2. Deploy the tiering procedures to the same database as Hallengren's scripts
--    (commonly [master] or a dedicated [DBA] database):
:r Run_TieredIntegrityCheck.sql
:r Rotate_VLDB_ObjectLevelChecks.sql
:r Run_LargeTier_WeeklyFullCheck.sql

-- 3. Edit @VLDBDatabaseList in Deploy_SQLAgentJobs.sql if you have VLDB databases,
--    then deploy the SQL Agent jobs (nightly tiered check, weekly VLDB rotation,
--    weekly Large-tier full check):
:r Deploy_SQLAgentJobs.sql

-- 4. Test manually before relying on the schedule:
EXEC dbo.Run_TieredIntegrityCheck;

-- 5. Monitor for failures AND interrupted/orphaned runs (e.g. after a patching
--    reboot mid-check):
:r Monitor_CommandLog_Status.sql
```

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
