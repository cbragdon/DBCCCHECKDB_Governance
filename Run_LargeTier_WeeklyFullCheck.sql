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
 Updated: 2026-10-26
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Run_LargeTier_WeeklyFullCheck
    @TimeLimitSeconds INT = 21600   -- 6 hours; tune to your weekly maintenance window
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LargeDBs NVARCHAR(MAX);
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
    --
    -- Full logical CHECKDB requires primary-replica-equivalent access;
    -- it is not reliable against read-intent-only AG secondaries. The
    -- role is checked PER DATABASE, as in Run_TieredIntegrityCheck: a
    -- database is skipped only when this replica holds a secondary copy
    -- of it. Databases in no AG are always checked.
    ------------------------------------------------------------------
    -- DirectCheck: a name with a comma or a % cannot be carried exactly in DatabaseIntegrityCheck's @Databases
    -- (comma split, LIKE matching); such databases are checked directly below with the same full CHECKDB.
    DECLARE @Large TABLE (name SYSNAME PRIMARY KEY, IsPrimary BIT NOT NULL,
                          DirectCheck AS (CASE WHEN name LIKE N'%,%' OR name LIKE N'%[%]%' THEN 1 ELSE 0 END));
    DECLARE @StartTime DATETIME2 = SYSDATETIME();

    ;WITH SizeCTE AS (
        SELECT
            d.name,
            SUM(CAST(mf.size AS BIGINT)) * 8.0 / 1024 / 1024 AS SizeGB,
            CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states drs
                              WHERE drs.database_id = d.database_id AND drs.is_local = 1 AND drs.is_primary_replica = 0)
                 THEN 0 ELSE 1 END AS IsPrimary
        FROM sys.databases d
        JOIN sys.master_files mf ON mf.database_id = d.database_id
        WHERE d.database_id > 4
          AND d.state = 0
        GROUP BY d.name, d.database_id
    )
    INSERT INTO @Large (name, IsPrimary)
    SELECT name, IsPrimary FROM SizeCTE
    WHERE SizeGB >= @MediumMaxGB AND SizeGB < @LargeMaxGB;

    DECLARE @SkippedNames NVARCHAR(MAX) = STUFF((SELECT ', ' + QUOTENAME(name) FROM @Large WHERE IsPrimary = 0 ORDER BY name FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');
    IF @SkippedNames IS NOT NULL
        RAISERROR('INFO: skipping Large-tier database(s) that this replica is secondary for (full logical check runs on the primary; nightly PHYSICAL_ONLY still applies here): %s', 10, 1, @SkippedNames) WITH NOWAIT;

    -- TYPE + .value() keeps & < > unescaped; QUOTENAME makes
    -- DatabaseIntegrityCheck read each name literally.
    SELECT @LargeDBs = STUFF((
        SELECT ',' + QUOTENAME(name) FROM @Large
        WHERE IsPrimary = 1 AND DirectCheck = 0
        ORDER BY name
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 1, '');

    IF @LargeDBs IS NULL AND NOT EXISTS (SELECT 1 FROM @Large WHERE IsPrimary = 1 AND DirectCheck = 1)
    BEGIN
        DECLARE @MediumMaxGBInt INT = CAST(@MediumMaxGB AS INT);
        DECLARE @LargeMaxGBInt INT = CAST(@LargeMaxGB AS INT);
        RAISERROR('INFO: No databases to check in the Large tier (%d GB - %d GB) on this replica. Nothing to do.', 10, 1, @MediumMaxGBInt, @LargeMaxGBInt);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Pre-flight headroom check (tempdb logical/volume + target DB
    -- data-volume + IFI on box product; tempdb-logical-only on MI).
    -- Non-blocking - see Check_DiskAndTempdbHeadroom.sql for rationale.
    ------------------------------------------------------------------
    IF @LargeDBs IS NOT NULL
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

    IF @LargeDBs IS NOT NULL AND @SupportsMaxDop = 1
        EXEC sp_executesql @Sql, @Parms, @p_Databases = @LargeDBs, @p_TimeLimit = @TimeLimitSeconds, @p_MaxDop = @LargeMaxDop;
    ELSE IF @LargeDBs IS NOT NULL
        EXEC sp_executesql @Sql, @Parms, @p_Databases = @LargeDBs, @p_TimeLimit = @TimeLimitSeconds;

    ------------------------------------------------------------------
    -- Databases whose name contains a comma or a % (DirectCheck = 1):
    -- the same full CHECKDB, one at a time, through Hallengren's
    -- dbo.CommandExecute with the command text DatabaseIntegrityCheck
    -- builds (same dbo.CommandLog rows). Like @TimeLimit there, no new
    -- check starts once @TimeLimitSeconds has passed since this run began.
    ------------------------------------------------------------------
    DECLARE @DirectName SYSNAME, @DirectQuoted NVARCHAR(300), @DirectCmd NVARCHAR(MAX), @DirectRc INT, @DirectFailed INT = 0;
    DECLARE direct_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM @Large WHERE IsPrimary = 1 AND DirectCheck = 1 ORDER BY name;
    OPEN direct_cursor;
    FETCH NEXT FROM direct_cursor INTO @DirectName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @TimeLimitSeconds IS NOT NULL AND SYSDATETIME() >= DATEADD(SECOND, @TimeLimitSeconds, @StartTime)
        BEGIN
            RAISERROR('INFO: @TimeLimitSeconds reached; [%s] and any later direct checks were not started.', 10, 1, @DirectName) WITH NOWAIT;
            BREAK;
        END
        SET @DirectQuoted = QUOTENAME(@DirectName);
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @DirectQuoted;
        SET @DirectCmd = N'DBCC CHECKDB (' + QUOTENAME(@DirectName) + N') WITH ALL_ERRORMSGS'
            + CASE WHEN @SupportsMaxDop = 1 THEN N', MAXDOP = ' + CAST(@LargeMaxDop AS NVARCHAR(10)) ELSE N'' END;
        RAISERROR('INFO: checking [%s] directly: its name contains a comma or %%, which the @Databases list of DatabaseIntegrityCheck cannot carry exactly.', 10, 1, @DirectName) WITH NOWAIT;
        EXEC @DirectRc = dbo.CommandExecute @DatabaseContext = N'master', @Command = @DirectCmd, @CommandType = N'DBCC_CHECKDB', @Mode = 1,
             @DatabaseName = @DirectName, @LogToTable = N'Y', @Execute = N'Y';
        IF @DirectRc <> 0 SET @DirectFailed += 1;
        FETCH NEXT FROM direct_cursor INTO @DirectName;
    END
    CLOSE direct_cursor;
    DEALLOCATE direct_cursor;

    IF @DirectFailed > 0
        RAISERROR('%d database(s) checked directly reported errors; see dbo.CommandLog.', 16, 1, @DirectFailed);
END
GO
