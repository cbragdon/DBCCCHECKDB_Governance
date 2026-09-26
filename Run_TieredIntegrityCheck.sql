/*
================================================================================
 Run_TieredIntegrityCheck.sql

 Purpose:
   Dynamic wrapper around Ola Hallengren's DatabaseIntegrityCheck stored
   procedure. Automatically buckets databases into Small / Medium / Large /
   VLDB tiers based on current size, and applies the appropriate DBCC CHECKDB
   strategy (full logical vs. PHYSICAL_ONLY) per tier.

   Also self-adapts to:
     - AlwaysOn Availability Group role (primary vs. secondary)
     - Azure SQL Managed Instance vs. box product (on-prem / IaaS VM)
     - SQL Server 2016 (pre/post SP2) vs. 2017+ support for @MaxDop

 Prerequisite:
   Ola Hallengren's Maintenance Solution must already be installed in this
   database (DatabaseIntegrityCheck procedure must exist). Download from:
     https://ola.hallengren.com/
   or
     https://github.com/olahallengren/sql-server-maintenance-solution

   Check_DiskAndTempdbHeadroom.sql must also be deployed to the same
   database first (called before Large/VLDB tier execution).

 Supported platforms:
   - SQL Server 2016 (SP2+) through SQL Server 2025 (box product)
   - Azure SQL Managed Instance (General Purpose and Business Critical)
   - NOT supported: Azure SQL Database (single-db PaaS) - use
     MaintenanceSolutionAzureSQLDatabase.sql from Hallengren's site instead.

 Tier thresholds (edit @Small/@Medium/@Large boundary variables below to tune):
   Small   : < 50 GB          -> full CHECKDB nightly
   Medium  : 50 GB - 500 GB   -> full CHECKDB nightly, time-boxed
   Large   : 500 GB - 2 TB    -> PHYSICAL_ONLY nightly, reduced MAXDOP on MI
   VLDB    : >= 2 TB          -> PHYSICAL_ONLY nightly; full logical coverage
             must be handled by a separate rotation/offload job (see
             Rotate_VLDB_ObjectLevelChecks.sql in this same folder).

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-25
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Run_TieredIntegrityCheck
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SmallDBs   NVARCHAR(MAX);
    DECLARE @MediumDBs  NVARCHAR(MAX);
    DECLARE @LargeDBs   NVARCHAR(MAX);
    DECLARE @VLDBs      NVARCHAR(MAX);
    DECLARE @IsPrimary  BIT;
    DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
    DECLARE @IsManagedInstance BIT = CASE WHEN @EngineEdition = 8 THEN 1 ELSE 0 END;
    DECLARE @Msg NVARCHAR(500);

    -- EngineEdition reference: 1=Personal/Express(legacy),2=Standard,3=Enterprise,
    -- 4=Express,5=Azure SQL DB,6=Azure Synapse,8=Azure SQL Managed Instance,
    -- 9=Azure SQL Edge,11=Azure Synapse serverless
    IF @EngineEdition = 5
    BEGIN
        RAISERROR('Azure SQL Database (single-db PaaS) is not supported here — use MaintenanceSolutionAzureSQLDatabase.sql instead.', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Tier size boundaries (GB) - adjust to your environment
    ------------------------------------------------------------------
    DECLARE @SmallMaxGB  DECIMAL(18,2) = 50;
    DECLARE @MediumMaxGB DECIMAL(18,2) = 500;
    DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;   -- 2 TB

    ------------------------------------------------------------------
    -- Detect actual @MaxDop support by build number, not assumption.
    -- MI is continuously patched -> always supported.
    -- Box product: SQL 2016 needs SP2+ (build >= 13.0.5026), 2017+ always OK.
    ------------------------------------------------------------------
    DECLARE @ProductMajorVersion INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
    DECLARE @ProductBuild        INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 2) AS INT);
    DECLARE @SupportsMaxDop BIT;

    SET @SupportsMaxDop =
        CASE
            WHEN @IsManagedInstance = 1 THEN 1                                   -- MI always current
            WHEN @ProductMajorVersion >= 14 THEN 1                               -- SQL 2017+
            WHEN @ProductMajorVersion = 13 AND @ProductBuild >= 5026 THEN 1       -- SQL 2016 SP2+
            ELSE 0
        END;

    IF @SupportsMaxDop = 0
        RAISERROR('INFO: This instance (build %d.%d) predates @MaxDop support for DatabaseIntegrityCheck. Running Large/VLDB tiers without @MaxDop.', 10, 1, @ProductMajorVersion, @ProductBuild);

    ------------------------------------------------------------------
    -- AlwaysOn AG role check. Returns NULL on standalone instances or
    -- General Purpose tier Managed Instance (no AG present) -> treat as
    -- primary so full checks are still allowed.
    ------------------------------------------------------------------
    SET @IsPrimary = ISNULL((
        SELECT CASE WHEN primary_replica = @@SERVERNAME THEN 1 ELSE 0 END
        FROM sys.dm_hadr_availability_group_states
    ), 1);

    ------------------------------------------------------------------
    -- Size-based tiering. Uses FOR XML PATH concatenation for
    -- SQL Server 2016 compatibility (STRING_AGG requires 2017+).
    ------------------------------------------------------------------
    ;WITH SizeCTE AS (
        SELECT
            d.name,
            SUM(mf.size) * 8.0 / 1024 / 1024 AS SizeGB
        FROM sys.databases d
        JOIN sys.master_files mf ON mf.database_id = d.database_id
        WHERE d.database_id > 4      -- exclude system databases
          AND d.state = 0            -- ONLINE only
        GROUP BY d.name
    )
    SELECT
        @SmallDBs  = STUFF((SELECT ',' + name FROM SizeCTE WHERE SizeGB < @SmallMaxGB FOR XML PATH('')), 1, 1, ''),
        @MediumDBs = STUFF((SELECT ',' + name FROM SizeCTE WHERE SizeGB >= @SmallMaxGB  AND SizeGB < @MediumMaxGB FOR XML PATH('')), 1, 1, ''),
        @LargeDBs  = STUFF((SELECT ',' + name FROM SizeCTE WHERE SizeGB >= @MediumMaxGB AND SizeGB < @LargeMaxGB  FOR XML PATH('')), 1, 1, ''),
        @VLDBs     = STUFF((SELECT ',' + name FROM SizeCTE WHERE SizeGB >= @LargeMaxGB  FOR XML PATH('')), 1, 1, '');

    ------------------------------------------------------------------
    -- MAXDOP tuning: reduced on Managed Instance to lower tempdb spill
    -- risk under shared compute/storage constraints.
    ------------------------------------------------------------------
    DECLARE @LargeMaxDop INT = CASE WHEN @IsManagedInstance = 1 THEN 2 ELSE 4 END;
    DECLARE @VLDBMaxDop  INT = CASE WHEN @IsManagedInstance = 1 THEN 1 ELSE 2 END;

    ------------------------------------------------------------------
    -- Tier 1: Small - full CHECKDB. Primary replica only.
    ------------------------------------------------------------------
    IF @SmallDBs IS NOT NULL AND @IsPrimary = 1
        EXEC dbo.DatabaseIntegrityCheck
            @Databases = @SmallDBs,
            @CheckCommands = 'CHECKDB',
            @LogToTable = 'Y';

    ------------------------------------------------------------------
    -- Tier 2: Medium - full CHECKDB, time-boxed. Primary replica only.
    ------------------------------------------------------------------
    IF @MediumDBs IS NOT NULL AND @IsPrimary = 1
        EXEC dbo.DatabaseIntegrityCheck
            @Databases = @MediumDBs,
            @CheckCommands = 'CHECKDB',
            @TimeLimit = 7200,     -- 2 hours
            @LogToTable = 'Y';

    ------------------------------------------------------------------
    -- Tier 3: Large - PHYSICAL_ONLY nightly. Safe on primary AND
    -- secondary replicas. Full logical check is a separate weekly job.
    -- @MaxDop only included when build-level support is confirmed.
    ------------------------------------------------------------------
    IF @LargeDBs IS NOT NULL
    BEGIN
        -- Pre-flight headroom check (tempdb logical/volume + target DB data-volume
        -- + IFI on box product; tempdb-logical-only on MI). Non-blocking - see
        -- Check_DiskAndTempdbHeadroom.sql for full rationale.
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @LargeDBs;

        DECLARE @SqlLarge NVARCHAR(MAX) = N'EXEC dbo.DatabaseIntegrityCheck
            @Databases = @p_Databases, @CheckCommands = ''CHECKDB'', @PhysicalOnly = ''Y'',
            @TimeLimit = @p_TimeLimit, @LogToTable = ''Y''' +
            CASE WHEN @SupportsMaxDop = 1 THEN N', @MaxDop = @p_MaxDop' ELSE N'' END;

        DECLARE @ParmsLarge NVARCHAR(MAX) = N'@p_Databases NVARCHAR(MAX), @p_TimeLimit INT' +
            CASE WHEN @SupportsMaxDop = 1 THEN N', @p_MaxDop INT' ELSE N'' END;

        IF @SupportsMaxDop = 1
            EXEC sp_executesql @SqlLarge, @ParmsLarge, @p_Databases = @LargeDBs, @p_TimeLimit = 14400, @p_MaxDop = @LargeMaxDop;
        ELSE
            EXEC sp_executesql @SqlLarge, @ParmsLarge, @p_Databases = @LargeDBs, @p_TimeLimit = 14400;
    END

    ------------------------------------------------------------------
    -- Tier 4: VLDB - PHYSICAL_ONLY nightly. Safe on primary AND
    -- secondary replicas. Full logical coverage handled by
    -- Rotate_VLDB_ObjectLevelChecks.sql or a restore-and-check job.
    ------------------------------------------------------------------
    IF @VLDBs IS NOT NULL
    BEGIN
        -- Pre-flight headroom check - see note on the Large tier block above.
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @VLDBs;

        DECLARE @SqlVLDB NVARCHAR(MAX) = N'EXEC dbo.DatabaseIntegrityCheck
            @Databases = @p_Databases, @CheckCommands = ''CHECKDB'', @PhysicalOnly = ''Y'',
            @TimeLimit = @p_TimeLimit, @LogToTable = ''Y''' +
            CASE WHEN @SupportsMaxDop = 1 THEN N', @MaxDop = @p_MaxDop' ELSE N'' END;

        DECLARE @ParmsVLDB NVARCHAR(MAX) = N'@p_Databases NVARCHAR(MAX), @p_TimeLimit INT' +
            CASE WHEN @SupportsMaxDop = 1 THEN N', @p_MaxDop INT' ELSE N'' END;

        IF @SupportsMaxDop = 1
            EXEC sp_executesql @SqlVLDB, @ParmsVLDB, @p_Databases = @VLDBs, @p_TimeLimit = 28800, @p_MaxDop = @VLDBMaxDop;
        ELSE
            EXEC sp_executesql @SqlVLDB, @ParmsVLDB, @p_Databases = @VLDBs, @p_TimeLimit = 28800;
    END
END
GO
