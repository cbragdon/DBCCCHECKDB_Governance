# Deployment Guide

## Step 0: Capacity planning (run before anything else)

Before installing anything, run `Precheck_RequiredSpaceForSetup.sql` against
the target instance to estimate how much disk/tempdb (box product) or
instance storage (Managed Instance) headroom your databases' CHECKDB runs
will need, and compare it to what's currently available:

```sql
:r Precheck_RequiredSpaceForSetup.sql
EXEC dbo.Precheck_RequiredSpaceForSetup;   -- or @Databases = 'DB1,DB2' for a subset
```

**When to run this:** the tempdb recommendation includes a live, point-in-time
snapshot of tempdb's currently-used space, added to CHECKDB's own estimated
footprint - this stands in for whatever else is normally consuming tempdb
concurrently (application workload, other jobs, version store, temp tables).
Run it during a **representative busy/peak period** (mid business day, your
regular ETL/reporting load, or an overlapping maintenance window) - not right
after a restart/failover (tempdb is freshly empty) and not during a known
quiet/idle window, either of which will understate the true requirement. For
extra confidence, run it a few times across a business day/week at your
busiest known windows and use the highest observed `CurrentTempdbUsedGB`.

Review the `Recommendation` column in both result sets (per-database
volume/instance headroom, and tempdb sizing). If it flags `ADD SPACE` /
`ADD INSTANCE STORAGE` / a tempdb shortfall, provision that space **now**,
before Step 5 (SQL Agent job deployment) puts these checks on a schedule —
it's much easier to resize ahead of time than to react to a failed run.
These are heuristic estimates (see the script's header comments); re-run it
after your first few live check runs, cross-referencing actual observed
headroom in `Monitor_CommandLog_Status.sql`, to refine the percentage
parameters for next time.

**Shortfall materiality threshold:** `ShortfallGB` alone doesn't tell
you whether a gap is worth acting on — both result sets' recommendations
are built from a point-in-time baseline/DMV snapshot plus a rough
heuristic, so small deltas are common and don't necessarily indicate a
real risk. Each result set only treats a shortfall as actionable
(`IsShortfallMaterial = 1`) once it clears **both** an absolute floor
(`@MinMaterialShortfallGB`, default 2 GB) and a relative floor
(`@MinMaterialShortfallPct`, default 10% of the recommended/required size)
— e.g. a 0.88 GB tempdb shortfall against a ~7 GB recommendation, or a
small GB gap below the volume/instance storage target, stays under both
floors and reports "OK (within estimate margin)" rather than an actionable
warning. Widen these parameters if your baseline snapshots are noisy
run-to-run, or tighten them once you're more confident in your estimate.

**Instance name (result set 2):** the tempdb result set's first column is
`InstanceName` (from `SERVERPROPERTY('ServerName')`), so output rows are
identifiable when you capture and consolidate results from multiple
lab/production instances (e.g. comparing the MI vs. a VM side by side).

**Service tier (`ServiceTier` column):** on MI, both result sets detect
the service tier (`GeneralPurpose` vs. `BusinessCritical`, via
`sys.server_resource_stats.sku`) and the `Recommendation` text is tailored
accordingly — GP suggests scaling storage/vCores or checking whether
Next-gen General Purpose is available for the instance; BC suggests
increasing vCores (its storage is local SSD tied to compute). The tempdb
result set's `ServiceTier` column shows the detected value directly
(`GeneralPurpose`, `BusinessCritical`, `Unknown` if it couldn't be
determined, or `VM` when run against a box-product SQL Server instance).
**Note:** "Next-gen General Purpose" cannot be distinguished from classic GP via any
DMV/T-SQL query (it's an ARM/control-plane-only setting) — both report
`sku = 'GeneralPurpose'` and are treated identically by the script; if a
GP-tier sizing issue comes up, also check the Azure portal to see whether
Next-gen GP is already enabled or available as an upgrade path.

**Tempdb growth-safety check (box product only):** a material tempdb
shortfall used to just say "verify autogrowth + adequate free space" —
now the script actually checks. When the tempdb shortfall is material on
a box-product instance, it inspects `sys.master_files`/
`sys.dm_os_volume_stats` for every tempdb data file and reports
`TempdbVolumeMountPoint`, `TempdbVolumeFreeGB`, `TempdbAutogrowthEnabled`,
and `TempdbMaxSizeCapGB` (worst-case across files: any file with
autogrowth disabled or a restrictive max-size cap, and the volume with
the least free space, wins). The `Recommendation` then tells you which
case you're in:
- **"...NO ISSUE: autogrowth is enabled, no restrictive max size cap, and
  X GB free..."** — autogrowth can absorb the shortfall automatically
  during the first live runs (though pre-growing tempdb manually still
  avoids growth-pause overhead mid-check).
- **"...ISSUE FOUND: ..."** — names the specific blocker(s): autogrowth
  disabled on a file, a max-size cap below the target, and/or the volume
  hosting tempdb has less free space than the shortfall itself. Resolve
  the named issue (enable autogrowth, raise/remove the cap, or add disk
  space / add a tempdb file on a different volume) before relying on
  autogrowth to cover the gap.

This check doesn't apply on Managed Instance (tempdb sizing there is
fixed by service tier and isn't manually resizable), so these four
columns report `NULL` for MI rows.

**Data-file growth-safety check (box product only, result set 1):** the
same class of check applies to the per-database volume headroom result
set — but with a twist, since "ADD SPACE" there means adding physical
disk capacity, not something SQL Server can autogrow into on its own.
Once you add that disk space, can the database's own data file(s)
actually use it? `DataFileAutogrowthEnabled` and `DataFileMaxSizeCapGB`
report whether the affected database has autogrowth disabled or a
restrictive max-size cap on its data file(s). If the volume shortfall is
material AND either of those is a problem, the `Recommendation` appends
a note explaining that adding disk space alone won't fully solve it — the
file-level setting (enable autogrowth, and/or raise or remove the max-size
cap) needs adjusting too. Not applicable on Managed Instance (storage
there is a shared instance-wide quota, not governed by per-file settings),
so both columns report `NULL` for MI rows.

## Step 1: Install Ola Hallengren's Maintenance Solution

If not already installed on the target instance, download and run
`MaintenanceSolution.sql` (recommended, includes backups + integrity checks +
index maintenance) or just `DatabaseIntegrityCheck.sql` (integrity checks
only) from:

- https://ola.hallengren.com/
- https://github.com/olahallengren/sql-server-maintenance-solution

Choose an install database — a **dedicated maintenance database** (e.g.
`[DBAdmin]` or `[DBA]`) — **never `[master]`**. Note which one you choose;
the procedures in this folder must be deployed to the **same database**.

Confirm install succeeded:

```sql
SELECT OBJECT_ID('dbo.DatabaseIntegrityCheck');  -- should return a non-NULL object_id
```

## Step 2: Deploy the tiering procedures

In the same database as Step 1, run in order:

```
Check_DiskAndTempdbHeadroom.sql       -- pre-flight headroom check called by all three
                                       -- procedures below; must be deployed first
                                       -- (on Managed Instance, gives GP/BC tier-specific
                                       -- remedy wording in its warnings - see Step 0's
                                       -- "Managed Instance service tier" note, same
                                       -- detection/limitation applies here)
Run_TieredIntegrityCheck.sql
Rotate_VLDB_ObjectLevelChecks.sql     -- only needed if you have VLDB (>= 2 TB) databases
Run_LargeTier_WeeklyFullCheck.sql     -- provides full logical coverage for the Large tier
                                       -- (500 GB - 2 TB), which otherwise only gets
                                       -- PHYSICAL_ONLY checks nightly
```

**Deploying via `sqlcmd`:** several scripts in this folder contain non-ASCII
characters (e.g. em-dashes `—` in comments/warning messages) and are saved
as UTF-8 without a byte-order mark. Plain `sqlcmd -i <file>.sql` on Windows
reads the file using the system's ANSI codepage by default, which silently
corrupts those characters — they'll still deploy and run without error, but
the corrupted bytes get baked into the compiled procedure and any messages/
`CommandLog` rows it produces (confirmed via live testing: an em-dash was
stored as garbage bytes, decodable back to the correct character only after
redeploying correctly). Always deploy with the UTF-8 input codepage
explicitly:

```
sqlcmd -S <server> -d <database> -G -C -i Check_DiskAndTempdbHeadroom.sql -f 65001
```

(`-f 65001` applies to every script in this folder, not just this one; SSMS's
"Execute" / `:r` do not have this problem since they detect file encoding
correctly.)

## Step 3: Tune thresholds for your environment (optional but recommended)

Open `Run_TieredIntegrityCheck.sql` and review/adjust:

```sql
DECLARE @SmallMaxGB  DECIMAL(18,2) = 50;
DECLARE @MediumMaxGB DECIMAL(18,2) = 500;
DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;   -- 2 TB
DECLARE @MinFreePctThreshold DECIMAL(5,2) = 20.0; -- tempdb free-space warning threshold
```

**Important:** `Run_LargeTier_WeeklyFullCheck.sql` has its own copies of
`@MediumMaxGB`/`@LargeMaxGB` (it needs the same tier boundaries to identify
which databases are "Large"). If you change the thresholds in
`Run_TieredIntegrityCheck.sql`, update the matching values in
`Run_LargeTier_WeeklyFullCheck.sql` as well so both stay in sync.

See `Tiering-Strategy.md` for guidance on setting these based on measured
CHECKDB runtime rather than raw size, if your environment's databases don't
match the size-based assumptions.

## Step 4: Test manually before scheduling

```sql
EXEC dbo.Run_TieredIntegrityCheck;
```

Review output/messages for:
- Tempdb free-space warnings
- `@MaxDop` support detection message (if running on pre-SP2 SQL 2016)
- Confirm expected databases were picked up by each tier (query
  `dbo.CommandLog` — Hallengren's logging table — to verify which databases
  and commands actually ran)

```sql
SELECT TOP 50 *
FROM dbo.CommandLog
ORDER BY StartTime DESC;
```

If you have VLDB databases, also test the rotation procedure manually:

```sql
EXEC dbo.Rotate_VLDB_ObjectLevelChecks
    @VLDBDatabases = 'YourVLDBDatabase1,YourVLDBDatabase2',
    @DaysInCycle = 7,
    @TimeLimitSeconds = 21600;

SELECT * FROM dbo.VLDB_CheckRotationLog ORDER BY LastCheckedDate;
```

If you have Large-tier databases, also test the weekly full-logical check
procedure manually (this can run considerably longer than the nightly
`PHYSICAL_ONLY` check on the same database - budget accordingly):

```sql
EXEC dbo.Run_LargeTier_WeeklyFullCheck @TimeLimitSeconds = 21600;
```

Use `Monitor_CommandLog_Status.sql` (see Step 7) to confirm it selected the
correct database(s) and produced a full (non-`PHYSICAL_ONLY`) `CHECKDB`
command.

## Step 5: Deploy SQL Agent jobs

1. Open `Deploy_SQLAgentJobs.sql`.
2. **Required:** set `@MaintenanceDB` (appears three times, once per job
   block) to the same database you used in Step 1/2 — e.g. `'DBAdmin'`. This
   has **no default and must be edited**: the script deliberately
   `RAISERROR`s and stops if left as the placeholder `'YourMaintenanceDB'`
   or set to `'master'`, since no procedure in this project (or Ola
   Hallengren's toolkit) should ever be deployed to `master`.
3. Update `@VLDBDatabaseList` (appears twice: once as a variable, once inline
   in the job step `@command`) with your actual VLDB database names, or
   remove/skip Job 2 entirely if you have no VLDB-tier databases.
4. Run the script.
5. Verify all three jobs were created:

```sql
SELECT name, enabled FROM msdb.dbo.sysjobs
WHERE name IN (N'DBA - Nightly Tiered Integrity Check', N'DBA - Weekly VLDB Object Rotation Check', N'DBA - Weekly Large Tier Full Check');
```

Job 3 (`DBA - Weekly Large Tier Full Check`) needs no per-database
configuration — it calls `Run_LargeTier_WeeklyFullCheck`, which identifies
Large-tier databases dynamically the same way `Run_TieredIntegrityCheck`
does. Only deploy/enable it if you actually have Large-tier (500 GB - 2 TB)
databases; otherwise it's a no-op (logs an informational message and exits).

**Verify the schedule doesn't create overlapping runs.** All three default
schedules start at 01:00 (nightly job daily, both weekly jobs on their
respective day) — if the nightly job is still running a Large/VLDB
PHYSICAL_ONLY check when a weekly job kicks off, both compete for the same
disk/tempdb headroom at once, silently invalidating the sequential-execution
assumption behind the sizing report in Step 0. Deploy and run
`Check_JobScheduleOverlap.sql` after the jobs have executed at least once
(ideally a few times, across their heaviest workload):

```sql
:r Check_JobScheduleOverlap.sql
EXEC dbo.Check_JobScheduleOverlap;
```

It flags any pair of jobs whose scheduled windows can genuinely overlap
based on OBSERVED run history (not a guess), and suggests either
rescheduling with a wider buffer or re-sizing headroom for the sum of the
overlapping jobs' concurrent needs. Pairs show `UNKNOWN (no run history
yet)` until both jobs involved have completed at least one run.

## Step 6: Deploy to AlwaysOn AG secondary replicas / additional instances

For each additional replica or standalone instance in your estate, repeat
Steps 1–5 identically. `Run_TieredIntegrityCheck` and
`Run_LargeTier_WeeklyFullCheck` self-detect AG role, Managed Instance vs. box
product, and `@MaxDop` build support at execution time — no per-instance
script edits are required beyond the size thresholds in Step 3, which can be
identical across all instances unless your environments differ
significantly. `Run_LargeTier_WeeklyFullCheck` also skips execution entirely
on non-primary replicas (full logical checks require primary-equivalent
access), so it's safe to deploy identically to every replica.

## Step 7: Monitoring / ongoing operations

- Use `Monitor_CommandLog_Status.sql` regularly (or adapt its logic into
  existing monitoring/alerting) instead of querying `dbo.CommandLog` raw.
  It correctly distinguishes:
  - **Succeeded** / **Failed** — completed runs, with measured duration.
  - **Running** — genuinely still executing (started after the instance's
    current start time).
  - **Interrupted (Server Restarted)** — a check was cut short by a SQL
    Server restart, crash, failover, or OS reboot (e.g. patching) mid-run.
    `CommandExecute.sql`'s insert-then-update logging pattern means the
    completion `UPDATE` never runs if the connection is severed abruptly, so
    these rows are permanently left with `EndTime`/`ErrorNumber` both
    `NULL` — indistinguishable from "still running" unless you cross-check
    against `sys.dm_os_sys_info.sqlserver_start_time` as this script does.
    **Alert on this status** — it means that database has NOT received a
    complete check since the interruption and should be re-run.
- Additional things to watch for:
  - Any `PHYSICAL_ONLY` run for VLDB/Large databases that failed or hit
    `@TimeLimit` — indicates the maintenance window is too short and either
    the schedule or `@TimeLimit` needs adjusting.
  - `dbo.VLDB_CheckRotationLog.LastCheckedDate` values that are unexpectedly
    old — indicates the rotation job isn't completing full cycles in the
    expected timeframe (increase frequency or reduce `@DaysInCycle`).
- SQL Agent job history (`msdb.dbo.sysjobhistory`) for job-level
  success/failure, independent of individual database-level results within
  `CommandLog`.
- Consider wiring SQL Agent job failure notifications (operator email, or
  your existing alerting integration) on all three jobs — not included here
  since it depends on your existing alerting stack.

## Uninstall / rollback

```sql
-- Remove SQL Agent jobs
EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Nightly Tiered Integrity Check';
EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Weekly VLDB Object Rotation Check';
EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Weekly Large Tier Full Check';

-- Remove procedures and rotation tracking table (run in the database from Step 1/2)
DROP PROCEDURE IF EXISTS dbo.Run_TieredIntegrityCheck;
DROP PROCEDURE IF EXISTS dbo.Rotate_VLDB_ObjectLevelChecks;
DROP PROCEDURE IF EXISTS dbo.Run_LargeTier_WeeklyFullCheck;
DROP TABLE IF EXISTS dbo.VLDB_CheckRotationLog;

-- Ola Hallengren's own procedures/objects are left untouched; remove
-- separately per Hallengren's documentation if desired.
```
