/*
================================================================================
 Deploy_SQLAgentJobs.sql

 Purpose:
   Creates the SQL Agent jobs that call the tiered integrity check procedures.
   Run this AFTER:
     1. Ola Hallengren's MaintenanceSolution.sql (or DatabaseIntegrityCheck.sql)
        has been installed in the target maintenance database (commonly [master]
        or a dedicated [DBA] database).
     2. Run_TieredIntegrityCheck.sql has been deployed to the SAME database.
     3. Rotate_VLDB_ObjectLevelChecks.sql has been deployed to the SAME database
        (only needed if you have VLDB-tier databases).

 NOTE for Azure SQL Managed Instance:
   MI supports SQL Agent jobs natively (unlike Azure SQL Database), so this
   script works unchanged on MI. Confirm the SQL Agent service/feature is
   enabled for your MI instance (it is by default).

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-25
================================================================================
*/

USE msdb;
GO

DECLARE @MaintenanceDB SYSNAME = N'master';  -- change to your maintenance DB if different
DECLARE @JobOwner SYSNAME = N'sa';           -- change to your standard job-owner login

------------------------------------------------------------------
-- Job 1: Nightly tiered integrity check (Small/Medium full CHECKDB,
-- Large/VLDB PHYSICAL_ONLY). Safe to run on primary AND secondary
-- AG replicas identically - the proc self-detects role.
------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Nightly Tiered Integrity Check')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - Nightly Tiered Integrity Check',
        @enabled = 1,
        @description = N'Runs Run_TieredIntegrityCheck to apply size-based DBCC CHECKDB strategy across all databases.',
        @owner_login_name = @JobOwner;

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'DBA - Nightly Tiered Integrity Check',
        @step_name = N'Run Tiered Integrity Check',
        @subsystem = N'TSQL',
        @database_name = @MaintenanceDB,
        @command = N'EXEC dbo.Run_TieredIntegrityCheck;',
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 1,
        @retry_interval = 5;

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'Nightly 01:00',
        @freq_type = 4,              -- daily
        @freq_interval = 1,
        @active_start_time = 010000; -- 01:00:00

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'DBA - Nightly Tiered Integrity Check',
        @schedule_name = N'Nightly 01:00';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'DBA - Nightly Tiered Integrity Check',
        @server_name = N'(local)';
END
GO

------------------------------------------------------------------
-- Job 2: Weekly VLDB object-level rotation (full logical coverage
-- for databases too large for nightly full CHECKDB). Only needed if
-- you have VLDB-tier (>= 2 TB) databases.
------------------------------------------------------------------
DECLARE @MaintenanceDB SYSNAME = N'master';
DECLARE @JobOwner SYSNAME = N'sa';
DECLARE @VLDBDatabaseList NVARCHAR(MAX) = N'YourVLDBDatabase1,YourVLDBDatabase2'; -- EDIT ME

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Weekly VLDB Object Rotation Check')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - Weekly VLDB Object Rotation Check',
        @enabled = 1,
        @description = N'Runs Rotate_VLDB_ObjectLevelChecks to provide full logical CHECKTABLE coverage over a multi-week cycle for VLDB-tier databases.',
        @owner_login_name = @JobOwner;

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'DBA - Weekly VLDB Object Rotation Check',
        @step_name = N'Run VLDB Rotation Check',
        @subsystem = N'TSQL',
        @database_name = @MaintenanceDB,
        @command = N'EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = ''YourVLDBDatabase1,YourVLDBDatabase2'', @DaysInCycle = 7, @TimeLimitSeconds = 21600;', -- EDIT database list
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 1,
        @retry_interval = 15;

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'Weekly Sunday 01:00',
        @freq_type = 8,               -- weekly
        @freq_interval = 1,           -- Sunday
        @freq_recurrence_factor = 1,
        @active_start_time = 010000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'DBA - Weekly VLDB Object Rotation Check',
        @schedule_name = N'Weekly Sunday 01:00';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'DBA - Weekly VLDB Object Rotation Check',
        @server_name = N'(local)';
END
GO

------------------------------------------------------------------
-- Job 3: Weekly Large-tier full logical CHECKDB (500 GB - 2 TB
-- databases only). Nightly checks for this tier are PHYSICAL_ONLY -
-- PHYSICAL_ONLY is a modifier on CHECKDB, not a separate check, so
-- full logical coverage (catalog consistency, cross-object checks)
-- never happens for this tier unless run separately. Scheduled on a
-- different night than Job 2 to avoid both large-scale checks
-- contending for the same maintenance window.
------------------------------------------------------------------
DECLARE @MaintenanceDB SYSNAME = N'master';
DECLARE @JobOwner SYSNAME = N'sa';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Weekly Large Tier Full Check')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - Weekly Large Tier Full Check',
        @enabled = 1,
        @description = N'Runs Run_LargeTier_WeeklyFullCheck to provide full logical DBCC CHECKDB coverage (not PHYSICAL_ONLY) for Large-tier (500 GB - 2 TB) databases, which only receive PHYSICAL_ONLY checks nightly.',
        @owner_login_name = @JobOwner;

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'DBA - Weekly Large Tier Full Check',
        @step_name = N'Run Large Tier Full Check',
        @subsystem = N'TSQL',
        @database_name = @MaintenanceDB,
        @command = N'EXEC dbo.Run_LargeTier_WeeklyFullCheck @TimeLimitSeconds = 21600;',
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 1,
        @retry_interval = 15;

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'Weekly Wednesday 01:00',
        @freq_type = 8,               -- weekly
        @freq_interval = 8,           -- Wednesday
        @freq_recurrence_factor = 1,
        @active_start_time = 010000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'DBA - Weekly Large Tier Full Check',
        @schedule_name = N'Weekly Wednesday 01:00';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'DBA - Weekly Large Tier Full Check',
        @server_name = N'(local)';
END
GO
