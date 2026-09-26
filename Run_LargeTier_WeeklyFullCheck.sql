/*
================================================================================
 Run_LargeTier_WeeklyFullCheck.sql

 Purpose:
   Companion to Run_TieredIntegrityCheck.sql. The Large tier (500GB - 2TB by
   default) only receives PHYSICAL_ONLY checks nightly from
   Run_TieredIntegrityCheck - PHYSICAL_ONLY is a modifier on DBCC CHECKDB, not
   a separate check, so full LOGICAL coverage (catalog consistency, allocation
   structures beyond physical page checksums, cross-object logical
   consistency) is never exercised for that tier unless run separately.

   This procedure runs a full (non-PHYSICAL_ONLY) DBCC CHECKDB against
   Large-tier databases only, intended for a weekly schedule (lower frequency
   than the nightly PHYSICAL_ONLY pass, since full logical checks take
   materially longer and carry more I/O/locking impact).

   VLDB-tier databases (>= 2TB) are NOT included here - they use
   Rotate_VLDB_ObjectLevelChecks.sql instead, since even a weekly full logical
   CHECKDB is often impractical at that scale.

 Recommended schedule:
   Weekly, on a different night than Rotate_VLDB_ObjectLevelChecks, to avoid
   both large-scale checks contending for the same maintenance window.

 Prerequisite: Ola Hallengren's DatabaseIntegrityCheck must be installed in
 the same database as Run_TieredIntegrityCheck.sql. Check_DiskAndTempdbHeadroom.sql
 must also be deployed to the same database first.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-25
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Run_LargeTier_WeeklyFullCheck
    @TimeLimitSeconds INT = 21600   -- 6 hours; tune to your weekly maintenance window
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LargeDBs NVARCHAR(MAX);
    DECLARE @IsPrimary BIT;
    DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
    DECLARE @IsManagedInstance BIT = CASE WHEN @EngineEdition = 8 THEN 1 ELSE 0 END;

    IF @EngineEdition = 5
    BEGIN
        RAISERROR('Azure SQL Database (single-db PaaS) is not supported here — use MaintenanceSolutionAzureSQLDatabase.sql instead.', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Same tier boundaries as Run_TieredIntegrityCheck.sql. Keep these
    -- two values in sync between both scripts (or centralize into a
    -- config table if you want a single source of truth - see
    -- Deployment-Guide.md for a note on this).
    ------------------------------------------------------------------
    DECLARE @MediumMaxGB DECIMAL(18,2) = 500;
    DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;   -- 2 TB

    ------------------------------------------------------------------
    -- Full logical CHECKDB requires primary-replica-equivalent access;
    -- it is not reliable against read-intent-only AG secondaries. Runs
    -- only on primary (or standalone/no-AG instances, where the role
    -- check returns NULL and is treated as primary).
    ------------------------------------------------------------------
    SET @IsPrimary = ISNULL((
        SELECT CASE WHEN primary_replica = @@SERVERNAME THEN 1 ELSE 0 END
        FROM sys.dm_hadr_availability_group_states
    ), 1);

    IF @IsPrimary = 0
    BEGIN
        RAISERROR('INFO: This replica is not primary. Skipping weekly full logical check (requires primary-equivalent access). Nightly PHYSICAL_ONLY checks still apply on this replica via Run_TieredIntegrityCheck.', 10, 1);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Build @MaxDop support detection identical to Run_TieredIntegrityCheck.sql
    ------------------------------------------------------------------
    DECLARE @ProductMajorVersion INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
    DECLARE @ProductBuild        INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 2) AS INT);
    DECLARE @SupportsMaxDop BIT;

    SET @SupportsMaxDop =
        CASE
            WHEN @IsManagedInstance = 1 THEN 1
            WHEN @ProductMajorVersion >= 14 THEN 1
            WHEN @ProductMajorVersion = 13 AND @ProductBuild >= 5026 THEN 1
            ELSE 0
        END;

    DECLARE @LargeMaxDop INT = CASE WHEN @IsManagedInstance = 1 THEN 2 ELSE 4 END;

    ------------------------------------------------------------------
    -- Identify Large-tier databases only (same boundaries as the
    -- nightly proc). VLDB (>= @LargeMaxGB) is deliberately excluded.
    ------------------------------------------------------------------
    ;WITH SizeCTE AS (
        SELECT
            d.name,
            SUM(mf.size) * 8.0 / 1024 / 1024 AS SizeGB
        FROM sys.databases d
        JOIN sys.master_files mf ON mf.database_id = d.database_id
        WHERE d.database_id > 4
          AND d.state = 0
        GROUP BY d.name
    )
    SELECT @LargeDBs = STUFF((
        SELECT ',' + name FROM SizeCTE
        WHERE SizeGB >= @MediumMaxGB AND SizeGB < @LargeMaxGB
        FOR XML PATH('')
    ), 1, 1, '');

    IF @LargeDBs IS NULL
    BEGIN
        DECLARE @MediumMaxGBInt INT = CAST(@MediumMaxGB AS INT);
        DECLARE @LargeMaxGBInt INT = CAST(@LargeMaxGB AS INT);
        RAISERROR('INFO: No databases currently fall in the Large tier (%d GB - %d GB). Nothing to do.', 10, 1, @MediumMaxGBInt, @LargeMaxGBInt);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Pre-flight headroom check (tempdb logical/volume + target DB
    -- data-volume + IFI on box product; tempdb-logical-only on MI).
    -- Non-blocking - see Check_DiskAndTempdbHeadroom.sql for rationale.
    ------------------------------------------------------------------
    EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @LargeDBs;

    ------------------------------------------------------------------
    -- Full (non-PHYSICAL_ONLY) CHECKDB, time-boxed. @MaxDop only
    -- included when build-level support is confirmed (see
    -- Run_TieredIntegrityCheck.sql for the detection rationale).
    ------------------------------------------------------------------
    DECLARE @Sql NVARCHAR(MAX) = N'EXEC dbo.DatabaseIntegrityCheck
        @Databases = @p_Databases, @CheckCommands = ''CHECKDB'',
        @TimeLimit = @p_TimeLimit, @LogToTable = ''Y''' +
        CASE WHEN @SupportsMaxDop = 1 THEN N', @MaxDop = @p_MaxDop' ELSE N'' END;

    DECLARE @Parms NVARCHAR(MAX) = N'@p_Databases NVARCHAR(MAX), @p_TimeLimit INT' +
        CASE WHEN @SupportsMaxDop = 1 THEN N', @p_MaxDop INT' ELSE N'' END;

    IF @SupportsMaxDop = 1
        EXEC sp_executesql @Sql, @Parms, @p_Databases = @LargeDBs, @p_TimeLimit = @TimeLimitSeconds, @p_MaxDop = @LargeMaxDop;
    ELSE
        EXEC sp_executesql @Sql, @Parms, @p_Databases = @LargeDBs, @p_TimeLimit = @TimeLimitSeconds;
END
GO
