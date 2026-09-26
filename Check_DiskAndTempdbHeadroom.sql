/*
================================================================================
 Check_DiskAndTempdbHeadroom.sql

 Purpose:
   Shared pre-flight headroom check called immediately before any Large/VLDB
   tier DBCC work (full CHECKDB, PHYSICAL_ONLY CHECKDB, or rotated
   CHECKALLOC/CHECKCATALOG/CHECKTABLE). Raises non-blocking warning messages
   (informational, severity 10) - it never stops a run, it only surfaces risk
   so an operator/alert pipeline can catch it before or during a long check.

   Checks performed:
     1. Tempdb LOGICAL fullness (already-allocated tempdb file space in use).
        Both platforms.
     2. Physical storage headroom for growth of OTHER databases, not just
        tempdb/the target database:
          - Box product: tempdb's underlying VOLUME free space - autogrowth
            can still fail even when tempdb is logically not full, if the
            disk itself is full.
          - Managed Instance: INSTANCE-WIDE provisioned storage headroom
            (sys.server_resource_stats) - MI data/log storage is a SHARED
            quota across every database on the instance (General Purpose:
            shared remote Premium Storage quota; Business Critical: shared
            local SSD). Low headroom here can block ANY database's data/log
            growth during or after a long-running check, not just the
            target database's - this is the check that answers "can other
            databases still grow (e.g. transaction log growth) if this
            check runs" for MI, where per-target-DB volume stats
            (dm_os_volume_stats) are unreliable (see note below).
     3. The target database's (or databases') own data-file VOLUME free
        space - DBCC CHECKDB/CHECKTABLE/CHECKALLOC create an internal NTFS
        sparse-file snapshot on the SAME volume as the database's data files
        (unless run WITH TABLOCK), sized roughly proportional to write
        activity during the check. Box product only.
     4. Instant File Initialization (IFI) status - informational only; does
        not affect available space, but affects how fast tempdb/data file
        growth completes if it is needed mid-run. Box product only.

 Logging:
   Every warning/informational message raised via RAISERROR is ALSO written
   as a row to Ola Hallengren's dbo.CommandLog table (CommandType =
   'HEADROOM_CHECK'), so headroom risk is captured in the same persisted,
   queryable history as CHECKDB itself - not just transient SQL Agent job
   output that may be truncated or unwatched. ErrorNumber = 1 marks a fired
   warning/info row (ErrorMessage populated); ErrorNumber = 0 is reserved but
   not currently emitted for clean/no-warning checks (kept quiet to avoid
   flooding CommandLog on every nightly/rotation run). Logging is skipped
   silently (no error) if dbo.CommandLog does not exist yet, or if
   @LogToCommandLog = 0. See Monitor_CommandLog_Status.sql for a report that
   includes these rows.

 IMPORTANT - Managed Instance limitation (confirmed via live testing against
 a lab Managed Instance):
   sys.dm_os_volume_stats returns NONSENSICAL values on Azure SQL Managed
   Instance (observed: available_bytes > total_bytes for the same volume) -
   MI storage is virtualized/auto-expanding and this DMV is not a meaningful
   representation of true headroom there. sys.dm_server_services (used for
   the IFI check) also returns ZERO rows on MI. Checks #3 and #4 are
   therefore SKIPPED on Managed Instance (EngineEdition = 8). Check #2 is
   NOT skipped on MI - it uses master.sys.server_resource_stats instead,
   which is the documented, reliable source for instance-wide storage
   headroom on MI (both General Purpose and Business Critical), and is the
   only way to detect a shared-storage risk to OTHER databases on the
   instance (dm_os_volume_stats cannot, since it reports per-file/volume
   figures that are meaningless on MI's virtualized storage). This
   complements, not replaces, the existing MI tempdb-capacity guidance
   already in Run_TieredIntegrityCheck.sql (MI tempdb capacity is fixed by
   service tier, not manually expandable).

   MI SERVICE TIER DETECTION: both check #1 (tempdb) and check #2
   (instance-wide storage) also read master.sys.server_resource_stats.sku
   ('GeneralPurpose' vs 'BusinessCritical') to give tier-specific remedy
   text (e.g. GP -> scale storage/vCores or check Next-gen GP eligibility;
   BC -> increase vCores). "Next-gen General Purpose" (Elastic SAN-backed
   GP) is an ARM/control-plane-only distinction and is NOT detectable via
   any DMV or T-SQL - classic and Next-gen GP both report sku =
   'GeneralPurpose' (and can share hardware_generation = 'Gen5'), so both
   are treated identically as 'GeneralPurpose' below; the GP-tier message
   suggests checking the Azure portal for Next-gen GP availability as one
   possible remedy. If the sku fetch fails (permission/DMV not populated),
   messages fall back to generic MI wording.

 Usage:
   EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @LargeDBs;
   -- @TargetDatabases is a comma-separated list, e.g. the same list passed
   -- to DatabaseIntegrityCheck's @Databases parameter for that tier/run.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Check_DiskAndTempdbHeadroom
    @TargetDatabases           NVARCHAR(MAX),
    @MinTempdbFreePct          DECIMAL(5,2) = 20.0,  -- warn if tempdb logical free space below this %
    @MinVolumeFreePct          DECIMAL(5,2) = 15.0,  -- warn if underlying disk volume free space below this % (box product)
    @MinInstanceStorageFreePct DECIMAL(5,2) = 15.0,  -- warn if MI instance-wide provisioned storage free space below this %
    @LogToCommandLog           BIT = 1               -- also persist warnings/info to dbo.CommandLog
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
    DECLARE @IsManagedInstance BIT = CASE WHEN @EngineEdition = 8 THEN 1 ELSE 0 END;
    DECLARE @Msg NVARCHAR(1000);
    DECLARE @HasCommandLog BIT = CASE WHEN @LogToCommandLog = 1
        AND OBJECT_ID('dbo.CommandLog') IS NOT NULL THEN 1 ELSE 0 END;

    ------------------------------------------------------------------
    -- Local helper logic (no local procs in T-SQL): every RAISERROR call
    -- below is immediately followed by a matching CommandLog INSERT so the
    -- warning survives beyond the SQL Agent job step's transient output.
    -- @LogDbName is set just before each block to the database the message
    -- pertains to (tempdb, the worst-offending target DB, or NULL for
    -- instance-wide/MI-skip/IFI notes).
    ------------------------------------------------------------------
    DECLARE @LogDbName NVARCHAR(256), @Now DATETIME2(7);

    ------------------------------------------------------------------
    -- MI service tier (GP vs BC) detection, fetched once up front so both
    -- checks #1 (tempdb) and #2 (instance-wide storage) below can give
    -- tier-specific remedy guidance. Fetched once up front (before check #1
    -- needs it) via its own lightweight TRY/CATCH query.
    --
    -- LIMITATION: "Next-gen General Purpose" (Elastic SAN-backed GP) is an
    -- ARM/control-plane-only distinction and is NOT detectable via any DMV
    -- or T-SQL - sys.server_resource_stats.sku reports 'GeneralPurpose' for
    -- both classic and Next-gen GP, and hardware_generation can be 'Gen5'
    -- for both as well. Both are therefore treated identically below as
    -- 'GeneralPurpose'; the GP-tier message suggests checking the Azure
    -- portal for Next-gen GP availability as one possible remedy.
    ------------------------------------------------------------------
    DECLARE @ServiceTier NVARCHAR(50) = NULL;

    ------------------------------------------------------------------
    -- 1) Tempdb LOGICAL fullness (space already allocated to tempdb's
    --    files that is currently in use). Meaningful on both platforms.
    ------------------------------------------------------------------
    DECLARE @TempdbFreeMB DECIMAL(18,2), @TempdbFreePct DECIMAL(5,2), @TempdbTotalMB DECIMAL(18,2);

    SELECT
        @TempdbTotalMB = SUM(size) * 8.0 / 1024,
        @TempdbFreeMB  = SUM(CASE WHEN type = 0 THEN size ELSE 0 END) * 8.0 / 1024
            - (SELECT SUM(unallocated_extent_page_count) * 8.0 / 1024 FROM tempdb.sys.dm_db_file_space_usage)
    FROM tempdb.sys.database_files;

    SET @TempdbFreePct = CASE WHEN @TempdbTotalMB > 0 THEN (@TempdbFreeMB / @TempdbTotalMB) * 100 ELSE 0 END;

    IF @IsManagedInstance = 1
    BEGIN
        BEGIN TRY
            SELECT TOP (1) @ServiceTier = sku
            FROM master.sys.server_resource_stats
            ORDER BY end_time DESC;
        END TRY
        BEGIN CATCH
            -- Insufficient permission or DMV not yet populated - leave NULL,
            -- messages fall back to generic MI guidance.
        END CATCH
    END

    IF @TempdbFreePct < @MinTempdbFreePct
    BEGIN
        SET @Msg = CASE
            WHEN @IsManagedInstance = 1 AND @ServiceTier = 'BusinessCritical'
                THEN 'WARNING (Managed Instance - Business Critical): tempdb logical free space ' + CAST(@TempdbFreePct AS VARCHAR(10))
                 + '% is below threshold. BC tempdb runs on dedicated local SSD sized by vCore count and cannot be manually '
                 + 'expanded — increase vCores, or reduce concurrent/large CHECKDB jobs, or split VLDB CHECKTABLE batches smaller.'
            WHEN @IsManagedInstance = 1 AND @ServiceTier = 'GeneralPurpose'
                THEN 'WARNING (Managed Instance - General Purpose): tempdb logical free space ' + CAST(@TempdbFreePct AS VARCHAR(10))
                 + '% is below threshold. GP tempdb capacity is fixed by vCore count and cannot be manually expanded — '
                 + 'increase vCores, check whether Next-gen General Purpose is available/enabled (not detectable from T-SQL — '
                 + 'verify in the Azure portal), or reduce concurrent CHECKDB jobs / split VLDB CHECKTABLE batches smaller.'
            WHEN @IsManagedInstance = 1
                THEN 'WARNING (Managed Instance): tempdb logical free space ' + CAST(@TempdbFreePct AS VARCHAR(10))
                 + '% is below threshold. MI tempdb is capped by service tier and cannot be manually expanded (tier could not '
                 + 'be determined — needs VIEW SERVER STATE / VIEW DATABASE PERFORMANCE STATE) — '
                 + 'consider reducing concurrent CHECKDB jobs, splitting VLDB CHECKTABLE batches smaller, or scaling up tier.'
            ELSE 'WARNING (VM): tempdb logical free space ' + CAST(@TempdbFreePct AS VARCHAR(10))
                 + '% is below threshold. Verify autogrowth is enabled and sufficient disk space exists '
                 + 'on the tempdb volume before running large-tier CHECKDB.'
        END;
        RAISERROR('%s', 10, 1, @Msg);

        IF @HasCommandLog = 1
        BEGIN
            SET @Now = SYSDATETIME();
            INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
            VALUES ('tempdb', @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
        END
    END

    -- Everything below relies on sys.dm_os_volume_stats / sys.dm_server_services,
    -- both of which are unreliable or unavailable on Managed Instance (see header
    -- note). Checks #3/#4 are skipped on MI; check #2 instead uses the reliable
    -- MI-specific DMV below.
    IF @IsManagedInstance = 1
    BEGIN
        ------------------------------------------------------------------
        -- 2) MI: INSTANCE-WIDE provisioned storage headroom. Data/log
        --    storage on MI is a SHARED quota across every database on the
        --    instance (GP: shared remote Premium Storage quota; BC: shared
        --    local SSD - tempdb is excluded from these figures on both
        --    tiers, since tempdb has its own separate local SSD allocation).
        --    Low headroom here means ANY database's data/log growth (e.g.
        --    transaction log growth from unrelated activity) could be
        --    blocked, independent of the target database(s) being checked.
        ------------------------------------------------------------------
        DECLARE @ReservedStorageMB DECIMAL(18,2), @UsedStorageMB DECIMAL(18,2), @InstanceFreePct DECIMAL(5,2);

        BEGIN TRY
            SELECT TOP (1)
                @ReservedStorageMB = reserved_storage_mb,
                @UsedStorageMB     = storage_space_used_mb
            FROM master.sys.server_resource_stats
            ORDER BY end_time DESC;
        END TRY
        BEGIN CATCH
            -- Insufficient permission (needs VIEW SERVER STATE / VIEW DATABASE
            -- PERFORMANCE STATE) or DMV not yet populated - skip silently,
            -- @ReservedStorageMB stays NULL so the check below is bypassed.
        END CATCH

        SET @InstanceFreePct = CASE WHEN @ReservedStorageMB > 0
            THEN (@ReservedStorageMB - @UsedStorageMB) * 100.0 / @ReservedStorageMB
            ELSE NULL END;

        IF @InstanceFreePct IS NOT NULL AND @InstanceFreePct < @MinInstanceStorageFreePct
        BEGIN
            SET @Msg = 'WARNING (Managed Instance): instance-wide provisioned storage free space '
                + CAST(@InstanceFreePct AS VARCHAR(10)) + '% (reserved ' + CAST(@ReservedStorageMB AS VARCHAR(20))
                + ' MB, used ' + CAST(@UsedStorageMB AS VARCHAR(20))
                + ' MB) is below threshold. MI data/log storage is a SHARED instance-wide quota (GP: shared '
                + 'remote storage; BC: shared local SSD) — low headroom can block THIS OR ANY OTHER database''s '
                + 'data/log growth, independent of tempdb. '
                + CASE
                    WHEN @ServiceTier = 'BusinessCritical'
                        THEN 'Business Critical storage is local SSD sized by vCore count — increase vCores, or archive/shrink data.'
                    WHEN @ServiceTier = 'GeneralPurpose'
                        THEN 'General Purpose storage can be increased directly (reserved storage in the Azure portal/ARM), or check whether Next-gen General Purpose is available/enabled for this instance (higher IOPS/throughput — not detectable from T-SQL, verify in the Azure portal), or archive/shrink data.'
                    ELSE 'Consider archiving/shrinking data, or scaling up storage (tier could not be determined — needs VIEW SERVER STATE / VIEW DATABASE PERFORMANCE STATE).'
                END;
            RAISERROR('%s', 10, 1, @Msg);

            IF @HasCommandLog = 1
            BEGIN
                SET @Now = SYSDATETIME();
                INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
                VALUES (NULL, @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
            END
        END

        SET @Msg = 'INFO (Managed Instance): per-volume/IFI headroom checks (tempdb volume, target DB data volume, IFI) are skipped - MI storage is virtualized and sys.dm_os_volume_stats / sys.dm_server_services do not report meaningful values on this platform. Instance-wide storage headroom was checked instead (see above).';
        RAISERROR('%s', 10, 1, @Msg);

        IF @HasCommandLog = 1
        BEGIN
            SET @Now = SYSDATETIME();
            INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
            VALUES (NULL, @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
        END
        RETURN;
    END

    ------------------------------------------------------------------
    -- 2) Box product only: tempdb's underlying VOLUME free space -
    --    autogrowth headroom. Worst-case (MIN) across all volumes hosting
    --    any tempdb file. (MI equivalent is handled above and returns
    --    before reaching this point.)
    ------------------------------------------------------------------
    DECLARE @TempdbVolMinFreePct DECIMAL(5,2);
    DECLARE @TempdbVolMountPoint NVARCHAR(260);

    ;WITH TempdbVol AS (
        SELECT
            vs.volume_mount_point,
            vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS FreePct
        FROM sys.master_files mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        WHERE mf.database_id = DB_ID('tempdb')
    )
    SELECT TOP 1 @TempdbVolMinFreePct = FreePct, @TempdbVolMountPoint = volume_mount_point
    FROM TempdbVol ORDER BY FreePct ASC;

    IF @TempdbVolMinFreePct IS NOT NULL AND @TempdbVolMinFreePct < @MinVolumeFreePct
    BEGIN
        SET @Msg = 'WARNING (VM): tempdb volume ' + @TempdbVolMountPoint + ' has only '
            + CAST(@TempdbVolMinFreePct AS VARCHAR(10))
            + '% free disk space. Tempdb autogrowth may fail mid-run even though tempdb''s '
            + 'currently-allocated space is not full. Verify free disk space before running large-tier CHECKDB.';
        RAISERROR('%s', 10, 1, @Msg);

        IF @HasCommandLog = 1
        BEGIN
            SET @Now = SYSDATETIME();
            INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
            VALUES ('tempdb', @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
        END
    END

    ------------------------------------------------------------------
    -- 3) Target database(s) data-file VOLUME free space - DBCC CHECKDB /
    --    CHECKTABLE / CHECKALLOC build an internal snapshot on the SAME
    --    volume as the database's own data files (unless WITH TABLOCK).
    --    Worst-case (MIN) across all target databases/volumes.
    ------------------------------------------------------------------
    DECLARE @DbVolMinFreePct DECIMAL(5,2);
    DECLARE @WorstDb NVARCHAR(260);
    DECLARE @WorstDbVolMountPoint NVARCHAR(260);

    ;WITH DbVol AS (
        SELECT
            d.name AS DatabaseName,
            vs.volume_mount_point,
            vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS FreePct
        FROM STRING_SPLIT(@TargetDatabases, ',') s
        JOIN sys.databases d ON d.name = LTRIM(RTRIM(s.value))
        JOIN sys.master_files mf ON mf.database_id = d.database_id AND mf.type = 0   -- data files only
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    )
    SELECT TOP 1 @DbVolMinFreePct = FreePct, @WorstDb = DatabaseName, @WorstDbVolMountPoint = volume_mount_point
    FROM DbVol ORDER BY FreePct ASC;

    IF @DbVolMinFreePct IS NOT NULL AND @DbVolMinFreePct < @MinVolumeFreePct
    BEGIN
        SET @Msg = 'WARNING (VM): data volume ' + @WorstDbVolMountPoint + ' hosting [' + @WorstDb
            + '] has only ' + CAST(@DbVolMinFreePct AS VARCHAR(10))
            + '% free disk space. DBCC creates an internal database snapshot on this volume — '
            + 'insufficient headroom can abort the check mid-run (independent of tempdb space).';
        RAISERROR('%s', 10, 1, @Msg);

        IF @HasCommandLog = 1
        BEGIN
            SET @Now = SYSDATETIME();
            SET @LogDbName = @WorstDb;
            INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
            VALUES (@LogDbName, @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
        END
    END

    ------------------------------------------------------------------
    -- 4) Instant File Initialization status - informational only. Does
    --    not block or affect available space, only growth speed.
    ------------------------------------------------------------------
    BEGIN TRY
        DECLARE @IFI CHAR(1);

        SELECT TOP 1 @IFI = instant_file_initialization_enabled
        FROM sys.dm_server_services
        WHERE servicename LIKE N'SQL Server (%';

        IF @IFI = 'N'
        BEGIN
            SET @Msg = 'INFO (VM): Instant File Initialization is disabled. Tempdb/data file growth needed during this run will be slower (zero-initialization). Consider granting SE_MANAGE_VOLUME_NAME to the SQL Server service account.';
            RAISERROR('%s', 10, 1, @Msg);

            IF @HasCommandLog = 1
            BEGIN
                SET @Now = SYSDATETIME();
                INSERT INTO dbo.CommandLog (DatabaseName, Command, CommandType, StartTime, EndTime, ErrorNumber, ErrorMessage)
                VALUES (NULL, @Msg, 'HEADROOM_CHECK', @Now, @Now, 1, @Msg);
            END
        END
    END TRY
    BEGIN CATCH
        -- sys.dm_server_services unavailable/insufficient permission on this instance - skip silently.
    END CATCH
END
GO
