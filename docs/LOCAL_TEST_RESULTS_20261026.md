# Local test results - 2026-10-26

Test instance: SQL Server 2025 Developer Edition (17.0, box product), local,
Windows authentication, sysadmin. Windows PowerShell 5.1. Every database
used was created for the test and dropped afterwards; the instance's
database, Agent job and schedule lists were compared with a snapshot taken
before testing and were identical afterwards.

## What was wrong (all reproduced on the original code first)

| # | Defect | Fixed in |
|---|---|---|
| 1 | Installer failed out of the box on Windows PowerShell 5.1: `$PSScriptRoot` is empty in a `param()` default when the script uses `[CmdletBinding()]`, so it could not find its own `.sql` files unless `-ScriptFolder` was passed. | `Install-DBCCGovernanceToolkit.ps1` |
| 2 | Databases with `&`, `<` or `>` in the name were never checked, and the run still reported success: `FOR XML PATH('')` turned `R&D` into `R&amp;D`, which `DatabaseIntegrityCheck` reported as nonexistent. | `Run_TieredIntegrityCheck.sql`, `Run_LargeTier_WeeklyFullCheck.sql`, `Rotate_VLDB_ObjectLevelChecks.sql` |
| 3 | The tempdb free-space figure was inverted (it computed used space): an almost empty tempdb (97.5% free) warned "1.98% free", an almost full one (9.8% free) did not warn. | `Check_DiskAndTempdbHeadroom.sql` |
| 4 | The VLDB rotation stamped every table in the batch as checked even when `@TimeLimitSeconds` stopped `DatabaseIntegrityCheck` first (0 of 300 checked, 300 stamped), so unchecked tables waited a full cycle. | `Rotate_VLDB_ObjectLevelChecks.sql` |
| 5 | The rotation failed with error 102 on a database name containing an apostrophe (name concatenated into dynamic SQL), and dropped tables stayed in the rotation log forever. | `Rotate_VLDB_ObjectLevelChecks.sql` |
| 6 | `STRING_SPLIT` made the rotation, the headroom check and `Precheck_RequiredSpaceForSetup @Databases` fail (error 208) in a maintenance database below compatibility level 130; Hallengren's `DatabaseIntegrityCheck` does not compile below 110; neither was documented. | the three procedures (portable splitter), installer (stops cleanly below 110), docs |
| 7 | The overlap check missed runs that cross midnight (nightly job at 23:00 for 4h vs a Wednesday 01:00 job reported "OK"). | `Check_JobScheduleOverlap.sql` |
| 8 | AG role was decided per instance with a subquery over `sys.dm_hadr_availability_group_states`: with more than one AG the run failed (error 512) and nothing was checked; on a replica that is secondary for one AG, databases in no AG were skipped too. | `Run_TieredIntegrityCheck.sql`, `Run_LargeTier_WeeklyFullCheck.sql` (per database, `sys.dm_hadr_database_replica_states`) |
| 9 | `Deploy_SQLAgentJobs.sql` ignored `@VLDBDatabaseList`: job 2's step always ran the placeholder list and failed at run time ("Database 'YourVLDBDatabase1' does not exist"). | `Deploy_SQLAgentJobs.sql` (step built from the variable; job skipped while it is the placeholder) |
| 10 | `Tests_CoreLogic.sql` tests copies of expressions, so it passed 27/27 with three faults planted in the real procedure. | new `tests/checks/*.sql` and `tests/Run-Checks.ps1`, which run the installed procedures |
| 11 | Found while running the job script for real: if any schedule named `Nightly 01:00` (or one of the other two names) already exists in msdb, `sp_attach_schedule @schedule_name` fails with error 14371 and the job is left without a schedule. | `Deploy_SQLAgentJobs.sql` (attach by the new `@schedule_id`) |

Also changed:
- The installer passes `-I` to sqlcmd, so the procedures are created with
  `QUOTED_IDENTIFIER ON` (they were OFF; no failure had been observed).
- `Monitor_CommandLog_Status.sql` has a third result set: rotation
  `CHECKTABLE`/`CHECKALLOC`/`CHECKCATALOG` checks from the last 14 days that
  did not succeed (they were not reported anywhere).
- A database whose name contains a comma cannot be passed to
  `DatabaseIntegrityCheck`; it is now left out with a WARNING instead of
  silently. Tier sizes are summed as `bigint` (no overflow above 16 TB).
- Docs: Quick Start now deploys `Check_DiskAndTempdbHeadroom.sql` (the other
  procedures call it), the compatibility requirement, per-database AG role,
  the new tests, and a complete uninstall list.

## Results

### 1. New self-checking tests at every compatibility level

`tests/Run-Checks.ps1 -CompatibilityLevel 100,110,120,130,140,150,160,170`,
once with the legacy cardinality estimator off and once on. For each level it
creates a disposable maintenance database, installs with the installer (no
`-ScriptFolder`), checks `QUOTED_IDENTIFIER`, and runs every check.

| Level (each with legacy CE off and on) | Installer | QUOTED_IDENTIFIER | Tests_CoreLogic | 01 Tiering | 02 Rotation | 03 Headroom | 04 Overlap |
|---|---|---|---|---|---|---|---|
| 100 | refuses cleanly ("needs 110 or higher") | - | - | - | - | - | - |
| 110, 120, 130, 140, 150, 160, 170 | SUCCESS | 6/6 ON | 27/27 | 12/12 | 9/9 | 5/5 | 9/9 |

100 of 100 rows passed.

### 2. Do the new tests catch real defects?

- Against the original procedures from `main`, all four checks fail: 02 on
  the time limit, dropped table, awkward names and second database; 03 on
  both tempdb readings and the bracketed target; 04 on cross-midnight and the
  week wrap; 01 stops because the procedure no longer matches what it
  expects.
- 11 faults planted one at a time in the fixed procedures - each was caught
  by the check meant to catch it:

| Fault | Caught by |
|---|---|
| Large/VLDB lose `PHYSICAL_ONLY` | 01 (3 assertions) |
| Small/Medium boundary `<` changed to `<=` | 01 (boundary database checked twice) |
| VLDB tier never runs | 01 |
| Small tier ignores the secondary role | 01 |
| Small list built without `TYPE` (escapes `&`) | 01 |
| Weekly check ignores the secondary role | 01 |
| Rotation stamps the whole batch | 02 |
| Rotation keeps dropped tables | 02 |
| Tempdb free space inverted | 03 (both fill levels) |
| Overlap without the week wrap | 04 |
| Overlap on one day only | 04 (4 scenarios) |

After restoring the fixed code, all four checks pass again.

### 3. The fixed procedures, unmodified, over the whole instance

Maintenance database at level 150, installed with the installer. Targets: one
database per compatibility level 100-170 x legacy CE off/on (16), a genuine
50 GB Medium-tier database, names with `&`, `'` and `,`, a database with a
corrupted page (`DBCC WRITEPAGE`), plus the instance's own user databases.

- `Run_TieredIntegrityCheck`: 27 of 28 online user databases checked in
  351 s; the only one left out is the comma name, with its WARNING. All 16
  compatibility-level targets: full `CHECKDB`, no errors. `R&D` and
  `O'Brien`: checked. 50 GB database: full `CHECKDB` (Medium tier).
  Corrupted database: error 8976 reported, and 24 databases were still
  checked after it.
- Rotation on the corrupted database: the clean table is stamped, the
  corrupt one is not; INFO message "1 of 2 table(s) in this rotation batch
  were checked".
- Monitor: the corrupted database shows as Failed in result set 1, and its
  failed `CHECKTABLE` is listed in the new result set 3.
- `Run_LargeTier_WeeklyFullCheck` with no Large-tier database: clean INFO
  message, no error.
- `Precheck_RequiredSpaceForSetup @Databases = N'[DCG_R&D], DCG_T_110_0'` in
  a level-110 maintenance database: runs, returns exactly those two.

### 4. `Deploy_SQLAgentJobs.sql` run for real in msdb

Jobs pointed at the disposable maintenance database; every job and schedule
was deleted afterwards and msdb matched the snapshot.

| Step | Result |
|---|---|
| Original script | 3 jobs created, but job 2's step is `@VLDBDatabases = 'YourVLDBDatabase1,YourVLDBDatabase2'`; run, it fails: "Database 'YourVLDBDatabase1' does not exist" (defect 9). |
| Original script, a schedule named `Nightly 01:00` already present | Msg 14371 "There are two or more schedules named ..."; job 1 left with 0 schedules (defect 11). |
| Fixed script, same pre-existing schedule | 3 jobs, owner `sa`, step database = the maintenance database, 1 schedule each with the right type/day/time (Daily 01:00, Sunday 01:00, Wednesday 01:00), job server set; the pre-existing schedule untouched; no errors. Job 2's step: `@VLDBDatabases = N'DCG_V_Rot,DCG_O''Brien'` (apostrophe kept). |
| Fixed script run again | no change (3 jobs, schedule count unchanged). |
| All three jobs started | Nightly: Succeeded (223 s, 25 databases checked). Rotation: Succeeded (both listed databases checked). Large-tier weekly: Succeeded. |
| `Check_JobScheduleOverlap` on the real msdb history | Nightly vs Sunday rotation: OVERLAP RISK (both start 01:00); nightly vs Wednesday Large-tier: OK, because that job ran for 0 s; rotation vs Large-tier: not paired (no shared day). |
| Fixed script, `@VLDBDatabaseList` left as the placeholder | jobs 1 and 3 created, job 2 not, with an INFO message. |

## Not tested

- A real availability group: roles were simulated by replacing
  `sys.dm_hadr_database_replica_states` with a test table (tests/checks/01).
  The real DMV query ran on this standalone instance, where it returns no
  rows.
- Azure SQL Managed Instance, and SQL Server 2016-2022.
- Real 500 GB / 2 TB databases: tier boundaries were scaled down to
  0.25 / 0.5 / 0.75 GB in a test copy of the installed procedure.
- `Get-MIServiceTierDetail.ps1` (needs Azure): syntax check only.
