/*
================================================================================
 Precheck_RequiredSpaceForSetup.sql

 Purpose:
   ONE-TIME (or periodic) capacity-planning report to run BEFORE deploying
   the SQL Agent jobs (Deployment-Guide.md Step 5), so you can add disk
   space or resize tempdb/MI storage ahead of time rather than discovering a
   shortfall on the first live run. This is NOT the same as
   Check_DiskAndTempdbHeadroom.sql, which is a lightweight pre-flight check
   run automatically before every actual Large/VLDB-tier execution once the
   jobs are live - this script is the up-front sizing exercise for INITIAL
   SETUP, covering every database (not just Large/VLDB) and estimating
   tempdb's steady-state requirement, not just its current headroom.

 IMPORTANT - these are heuristic ESTIMATES, not guarantees:
   The DBCC CHECKDB internal snapshot (data volume) and tempdb usage both
   depend on how many pages change during the check (write activity,
   fragmentation, index maintenance overlap, WITH TABLOCK usage,
   PHYSICAL_ONLY vs full logical checks, MAXDOP) - none of which can be
   known in advance for a database that has never been checked. The
   percentages below are commonly-cited conservative planning heuristics
   (not a Microsoft-guaranteed figure):
     - Snapshot headroom ~ 10% of data size for PHYSICAL_ONLY (lighter,
       page-level only, no internal consistency structures built).
     - Snapshot headroom ~ 20% of data size for full logical CHECKDB
       (heavier - allocation/logical checks read more, and busier databases
       generate more copy-on-write snapshot activity during a longer run).
     - Tempdb steady-state size ~ CURRENT tempdb usage baseline (see below)
       PLUS 10% of your single LARGEST database's data size for CHECKDB's
       own footprint (checks generally run sequentially within a job step,
       so CHECKDB only needs to cover the worst SINGLE concurrent check,
       not the sum of every database - see caveat below if you customize
       Hallengren's jobs to run checks in parallel).
   ADJUST these percentages (@HeadroomPctPhysicalOnly,
   @HeadroomPctFullCheckdb, @TempdbPctOfLargestDB) upward for databases with
   heavy write workloads, high fragmentation, or if using
   @ExtendedLogicalChecks = 'Y'. Re-run Check_DiskAndTempdbHeadroom.sql's
   history (via Monitor_CommandLog_Status.sql) after the first few real
   runs to see actual observed headroom and refine these percentages for
   next time.

 Tempdb baseline usage snapshot - WHEN TO RUN THIS:
   The tempdb recommendation includes a live snapshot of tempdb's CURRENTLY
   USED space (tempdb.sys.dm_db_file_space_usage), added to the CHECKDB
   estimate, as a stand-in for whatever else is concurrently consuming
   tempdb (application workload, other jobs, RCSI/snapshot version store,
   temp tables, spills, index maintenance) - CHECKDB does not run in
   isolation on a real instance, and sizing for CHECKDB alone understates
   the true requirement. Because this is a single POINT-IN-TIME snapshot,
   WHEN you run this script matters:
     - DO run it during a representative BUSY/PEAK period - e.g. mid
       business day, during your regular ETL/reporting load, or during an
       overlapping maintenance window (index maintenance, other backups) -
       whatever reflects realistic concurrent tempdb pressure on this
       instance.
     - DO NOT run it right after a service restart/failover (tempdb is
       recreated empty and will show a near-zero, misleadingly low
       baseline) or during a known quiet/idle window (overnight with no
       jobs running) - either will understate the true requirement.
     - For a more robust figure, run it several times across a business
       day/week at your busiest known windows and use the HIGHEST observed
       `CurrentTempdbUsedGB` across those runs, rather than relying on a
       single execution.

 Caveat - concurrent job overlap:
   This report assumes checks run sequentially (Hallengren's default
   behavior within a single DatabaseIntegrityCheck call). If your schedule
   allows the nightly tiered check, the VLDB rotation job, and the weekly
   Large-tier full check to overlap in time, tempdb/volume headroom must
   cover the SUM of whatever runs concurrently, not just the single largest
   database - space your schedules apart or size up further if overlap is
   possible.

 Platform handling:
   - Box product: reports per-database data-file VOLUME free space
     (worst-case volume if a database spans multiple drives), via
     sys.dm_os_volume_stats.
   - Managed Instance: sys.dm_os_volume_stats is unreliable on MI (see
     Check_DiskAndTempdbHeadroom.sql header for details) - instead reports
     INSTANCE-WIDE provisioned storage headroom via
     master.sys.server_resource_stats, since MI storage (data/log) is a
     shared quota across every database on the instance, not a per-database
     volume. Tempdb is separately provisioned by service tier on MI and not
     manually resizable - the tempdb section below is informational only
     there (use it to judge whether to reduce concurrent job scope or scale
     up the service tier, not to "add space" directly).

 Materiality threshold - avoiding false alarms on estimate noise:
   Applies to BOTH result sets - the per-database/instance volume headroom
   check (result set 1, ShortfallGB/IsShortfallMaterial columns) and the
   tempdb sizing check (result set 2). All these figures are built from
   point-in-time snapshots plus rough heuristics (see above) - none are
   precise to the GB. A tiny ShortfallGB (e.g. under a GB) is far more
   likely to be normal snapshot-to-snapshot variance or heuristic
   imprecision than a real capacity risk, and flagging it identically to a
   large shortfall would train operators to ignore the warning. A shortfall
   is only treated as ACTIONABLE (and gets the ADD SPACE / ADD INSTANCE
   STORAGE / tier-remedy Recommendation text) when it exceeds
   BOTH:
     - @MinMaterialShortfallGB (an absolute floor, default 2 GB), AND
     - @MinMaterialShortfallPct of the relevant recommended/required size
       (a relative floor, default 10%) - RecommendedTempdbSizeGB for result
       set 2, or the target free-space amount (VolumeTotalGB /
       InstanceTotalGB x @MinVolumeFreePctAfterWork) for result set 1 - so
       the threshold scales sensibly whether the footprint is small or
       very large.
   A shortfall below this bar still shows in ShortfallGB/IsShortfallMaterial
   for transparency, but the Recommendation reads "OK (within estimate
   margin)" rather than prompting action. Widen either parameter if you find
   your baseline snapshots are noisy run-to-run (see WHEN TO RUN THIS
   above), or tighten them once you have more confidence in your estimate.

 Tempdb growth-safety check (box product only) - closing the "verify
 autogrowth" gap:
   A material tempdb shortfall on box product used to just say "ADD ~X GB
   to tempdb (or verify autogrowth + adequate free space...)" - a manual
   reminder, not an actual validation. Now, whenever result set 2's tempdb
   shortfall is material on a box-product instance, the script inspects
   sys.master_files / sys.dm_os_volume_stats for every tempdb DATA file and
   reports the worst case across them:
     - TempdbAutogrowthEnabled - 0 if ANY tempdb data file has autogrowth
       disabled (growth = 0).
     - TempdbMaxSizeCapGB - the lowest configured max size among files that
       have one (NULL if none are capped/all are unlimited).
     - TempdbVolumeMountPoint / TempdbVolumeFreeGB - the volume hosting
       tempdb with the LEAST free space (worst case if tempdb spans
       multiple drives).
   The Recommendation text then differentiates:
     - "...NO ISSUE: autogrowth is enabled, no restrictive max size cap,
       and X GB free..." - autogrowth can cover the shortfall automatically
       during the first live runs (pre-growing manually still avoids
       growth-pause overhead mid-check, but there's no real risk).
     - "...ISSUE FOUND: ..." - names the specific blocker(s): autogrowth
       disabled, a max-size cap below the target, and/or the volume having
       less free space than the shortfall itself - so a genuine capacity
       risk is called out explicitly instead of a generic "verify" note.
   Not applicable on Managed Instance (tempdb there is a fixed allocation by
   service tier, not manually resizable) - these four columns are NULL for
   MI rows.

 Usage:
   EXEC dbo.Precheck_RequiredSpaceForSetup;                          -- all user databases
   EXEC dbo.Precheck_RequiredSpaceForSetup @Databases = 'DB1,DB2';   -- specific databases only
   -- Result set 2 also returns InstanceName (SERVERPROPERTY('ServerName'))
   -- as the first column, so results are identifiable when consolidating
   -- output captured from multiple instances/lab systems.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Precheck_RequiredSpaceForSetup
    @Databases                 NVARCHAR(MAX) = NULL,   -- comma-separated list; NULL = all user databases
    @SmallMaxGB                DECIMAL(18,2) = 50,      -- must match Run_TieredIntegrityCheck.sql tier boundaries
    @MediumMaxGB               DECIMAL(18,2) = 500,
    @LargeMaxGB                DECIMAL(18,2) = 2048,    -- 2 TB
    @HeadroomPctPhysicalOnly   DECIMAL(5,2)  = 10.0,    -- estimated snapshot headroom, PHYSICAL_ONLY (% of data size)
    @HeadroomPctFullCheckdb    DECIMAL(5,2)  = 20.0,    -- estimated snapshot headroom, full CHECKDB (% of data size)
    @TempdbPctOfLargestDB      DECIMAL(5,2)  = 10.0,    -- estimated tempdb need (% of largest DB's data size)
    @MinVolumeFreePctAfterWork DECIMAL(5,2)  = 15.0,    -- desired free % remaining AFTER the estimated headroom is consumed
    @MinMaterialShortfallGB    DECIMAL(18,2) = 2.0,     -- floor below which a tempdb shortfall is treated as estimate noise, not actionable
    @MinMaterialShortfallPct   DECIMAL(5,2)  = 10.0     -- shortfall must also exceed this % of RecommendedTempdbSizeGB to be actionable
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
    DECLARE @IsManagedInstance BIT = CASE WHEN @EngineEdition = 8 THEN 1 ELSE 0 END;

    ------------------------------------------------------------------
    -- MI service tier detection (General Purpose vs Business Critical).
    -- sys.server_resource_stats.sku reliably returns 'GeneralPurpose' or
    -- 'BusinessCritical' on Managed Instance - confirmed via live query
    -- (this column does NOT exist on the Azure SQL Database edition of
    -- this same-named DMV, only on MI). NULL on box product, or on MI if
    -- permission is missing (needs VIEW SERVER STATE / VIEW DATABASE
    -- PERFORMANCE STATE) / the DMV has no rows yet.
    --
    -- IMPORTANT - "Next-gen General Purpose" is NOT detectable via T-SQL:
    -- confirmed against Microsoft's own documentation - it is an ARM/
    -- control-plane-only distinction (the `IsGeneralPurposeV2`/`--gpv2`
    -- flag), invisible to any DMV. A Next-gen GP instance still reports
    -- sku = 'GeneralPurpose' here, and can even report the SAME
    -- hardware_generation ('Gen5') as classic GP. Both tiers are
    -- therefore treated identically below as 'GeneralPurpose' - the
    -- GP-tier recommendation message mentions checking the Azure portal
    -- for whether a Next-gen GP upgrade is available/enabled, since this
    -- script cannot determine that for you.
    --
    -- Fetched later (result set 1's MI branch), alongside the existing
    -- reserved/used storage query, to avoid a redundant round-trip.
    ------------------------------------------------------------------
    DECLARE @MIServiceTier NVARCHAR(50) = NULL;

    ------------------------------------------------------------------
    -- Database inventory + tiering (mirrors Run_TieredIntegrityCheck.sql's
    -- logic so tiers reported here match what the live jobs will select).
    ------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;

    ;WITH SizeCTE AS (
        SELECT
            d.name AS DatabaseName,
            SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END) * 8.0 / 1024 / 1024 AS DataSizeGB,
            SUM(CASE WHEN mf.type = 1 THEN mf.size ELSE 0 END) * 8.0 / 1024 / 1024 AS LogSizeGB
        FROM sys.databases d
        JOIN sys.master_files mf ON mf.database_id = d.database_id
        WHERE d.database_id > 4    -- exclude system databases
          AND d.state = 0          -- ONLINE only
          AND (@Databases IS NULL OR d.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Databases, ',')))
        GROUP BY d.name
    )
    SELECT
        DatabaseName,
        DataSizeGB,
        LogSizeGB,
        DataSizeGB + LogSizeGB AS TotalSizeGB,
        Tier = CASE
            WHEN DataSizeGB + LogSizeGB < @SmallMaxGB  THEN 'Small'
            WHEN DataSizeGB + LogSizeGB < @MediumMaxGB THEN 'Medium'
            WHEN DataSizeGB + LogSizeGB < @LargeMaxGB  THEN 'Large'
            ELSE 'VLDB'
        END,
        EstSnapshotHeadroomGB_PhysicalOnly = CAST(DataSizeGB * @HeadroomPctPhysicalOnly / 100.0 AS DECIMAL(18,2)),
        EstSnapshotHeadroomGB_FullCheckdb  = CAST(DataSizeGB * @HeadroomPctFullCheckdb  / 100.0 AS DECIMAL(18,2))
    INTO #Databases
    FROM SizeCTE;

    IF NOT EXISTS (SELECT 1 FROM #Databases)
    BEGIN
        RAISERROR('No matching databases found (check @Databases list, or confirm databases are ONLINE).', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Result set 1: per-database sizing + estimated headroom need vs.
    -- CURRENT available space.
    ------------------------------------------------------------------
    IF @IsManagedInstance = 0
    BEGIN
        ------------------------------------------------------------------
        -- Box product: worst-case (MIN free%) data-file volume per database,
        -- since a database can span multiple drives/filegroups.
        ------------------------------------------------------------------
        ;WITH DbVol AS (
            SELECT
                d.name AS DatabaseName,
                vs.volume_mount_point,
                vs.total_bytes / 1024.0 / 1024 / 1024 AS VolumeTotalGB,
                vs.available_bytes / 1024.0 / 1024 / 1024 AS VolumeFreeGB,
                vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS VolumeFreePct,
                ROW_NUMBER() OVER (PARTITION BY d.name ORDER BY vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) ASC) AS rn
            FROM sys.databases d
            JOIN sys.master_files mf ON mf.database_id = d.database_id AND mf.type = 0   -- data files only
            CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
            WHERE d.name IN (SELECT DatabaseName FROM #Databases)
        )
        SELECT
            db.DatabaseName,
            db.Tier,
            db.DataSizeGB,
            db.LogSizeGB,
            db.TotalSizeGB,
            db.EstSnapshotHeadroomGB_PhysicalOnly,
            db.EstSnapshotHeadroomGB_FullCheckdb,
            v.volume_mount_point AS VolumeMountPoint,
            CAST(v.VolumeTotalGB AS DECIMAL(18,2)) AS VolumeTotalGB,
            CAST(v.VolumeFreeGB AS DECIMAL(18,2)) AS VolumeFreeGB,
            CAST(v.VolumeFreePct AS DECIMAL(5,2)) AS VolumeFreePctNow,
            ProjectedFreeGB_AfterFullCheckdb = CAST(v.VolumeFreeGB - db.EstSnapshotHeadroomGB_FullCheckdb AS DECIMAL(18,2)),
            ProjectedFreePct_AfterFullCheckdb = CAST((v.VolumeFreeGB - db.EstSnapshotHeadroomGB_FullCheckdb) * 100.0 / NULLIF(v.VolumeTotalGB, 0) AS DECIMAL(5,2)),
            ShortfallGB          = shortfall.ShortfallGB,
            IsShortfallMaterial  = mat.IsShortfallMaterial,
            Recommendation = CASE
                WHEN v.VolumeFreeGB IS NULL THEN 'UNKNOWN - could not read volume stats'
                WHEN mat.IsShortfallMaterial = 1
                    THEN 'ADD SPACE - projected free % after a full CHECKDB falls below ' + CAST(@MinVolumeFreePctAfterWork AS VARCHAR(10)) + '% target (add at least '
                        + CAST(shortfall.ShortfallGB AS VARCHAR(20)) + ' GB)'
                WHEN shortfall.ShortfallGB > 0
                    THEN 'OK (within estimate margin) - a small ' + CAST(shortfall.ShortfallGB AS VARCHAR(20)) + ' GB gap below the ' + CAST(@MinVolumeFreePctAfterWork AS VARCHAR(10))
                        + '% target exists but is below the materiality threshold (' + CAST(@MinMaterialShortfallGB AS VARCHAR(10)) + ' GB / ' + CAST(@MinMaterialShortfallPct AS VARCHAR(10))
                        + '% of the target free space) - likely estimate imprecision, not a real capacity risk.'
                ELSE 'OK'
            END
        FROM #Databases db
        LEFT JOIN DbVol v ON v.DatabaseName = db.DatabaseName AND v.rn = 1
        CROSS APPLY (
            -- Required free space to still meet @MinVolumeFreePctAfterWork
            -- after the estimated full-CHECKDB snapshot headroom is consumed.
            SELECT
                ReqFreeGB   = v.VolumeTotalGB * @MinVolumeFreePctAfterWork / 100.0,
                ShortfallGB = CASE WHEN v.VolumeFreeGB IS NULL THEN NULL
                    ELSE CAST(
                        CASE WHEN (v.VolumeTotalGB * @MinVolumeFreePctAfterWork / 100.0) - (v.VolumeFreeGB - db.EstSnapshotHeadroomGB_FullCheckdb) > 0
                            THEN (v.VolumeTotalGB * @MinVolumeFreePctAfterWork / 100.0) - (v.VolumeFreeGB - db.EstSnapshotHeadroomGB_FullCheckdb)
                            ELSE 0 END AS DECIMAL(18,2))
                    END
        ) shortfall
        CROSS APPLY (
            -- Same materiality gating as the tempdb section (Result Set 2):
            -- must clear BOTH an absolute floor and a relative floor.
            SELECT IsShortfallMaterial = CASE
                WHEN shortfall.ShortfallGB IS NULL THEN NULL
                WHEN shortfall.ShortfallGB > @MinMaterialShortfallGB
                    AND shortfall.ShortfallGB > (shortfall.ReqFreeGB * @MinMaterialShortfallPct / 100.0)
                    THEN 1 ELSE 0 END
        ) mat
        ORDER BY db.TotalSizeGB DESC;
    END
    ELSE
    BEGIN
        ------------------------------------------------------------------
        -- Managed Instance: single instance-wide storage figure applies to
        -- every database (shared quota) - report it once per database for
        -- consistency with the box-product result set shape, so the same
        -- downstream reporting/export logic works on both platforms.
        ------------------------------------------------------------------
        DECLARE @ReservedStorageMB DECIMAL(18,2), @UsedStorageMB DECIMAL(18,2);

        BEGIN TRY
            SELECT TOP (1)
                @ReservedStorageMB = reserved_storage_mb,
                @UsedStorageMB     = storage_space_used_mb,
                @MIServiceTier     = sku
            FROM master.sys.server_resource_stats
            ORDER BY end_time DESC;
        END TRY
        BEGIN CATCH
            -- Insufficient permission (VIEW SERVER STATE / VIEW DATABASE
            -- PERFORMANCE STATE) - leave NULL, reported as UNKNOWN below.
        END CATCH

        DECLARE @InstanceFreeGB DECIMAL(18,2) = (@ReservedStorageMB - @UsedStorageMB) / 1024.0;
        DECLARE @InstanceTotalGB DECIMAL(18,2) = @ReservedStorageMB / 1024.0;

        -- Worst case for MI is the single largest database's full-check
        -- headroom, NOT the sum, since checks run sequentially per job.
        DECLARE @WorstCaseHeadroomGB DECIMAL(18,2) = (SELECT MAX(EstSnapshotHeadroomGB_FullCheckdb) FROM #Databases);
        DECLARE @InstProjectedFreeGB DECIMAL(18,2) = @InstanceFreeGB - @WorstCaseHeadroomGB;
        DECLARE @InstReqFreeGB DECIMAL(18,2) = @InstanceTotalGB * @MinVolumeFreePctAfterWork / 100.0;

        -- Same materiality gating as the tempdb section (Result Set 2):
        -- must clear BOTH an absolute floor and a relative floor.
        DECLARE @InstShortfallGB DECIMAL(18,2) = CASE WHEN @InstanceTotalGB IS NULL THEN NULL
            ELSE CAST(CASE WHEN @InstReqFreeGB - @InstProjectedFreeGB > 0 THEN @InstReqFreeGB - @InstProjectedFreeGB ELSE 0 END AS DECIMAL(18,2)) END;
        DECLARE @InstIsShortfallMaterial BIT = CASE
            WHEN @InstShortfallGB IS NULL THEN NULL
            WHEN @InstShortfallGB > @MinMaterialShortfallGB AND @InstShortfallGB > (@InstReqFreeGB * @MinMaterialShortfallPct / 100.0)
                THEN 1 ELSE 0 END;

        SELECT
            db.DatabaseName,
            db.Tier,
            db.DataSizeGB,
            db.LogSizeGB,
            db.TotalSizeGB,
            db.EstSnapshotHeadroomGB_PhysicalOnly,
            db.EstSnapshotHeadroomGB_FullCheckdb,
            VolumeMountPoint = '(instance-wide, shared)',
            VolumeTotalGB = @InstanceTotalGB,
            VolumeFreeGB = @InstanceFreeGB,
            VolumeFreePctNow = CAST(@InstanceFreeGB * 100.0 / NULLIF(@InstanceTotalGB, 0) AS DECIMAL(5,2)),
            ProjectedFreeGB_AfterFullCheckdb = CAST(@InstProjectedFreeGB AS DECIMAL(18,2)),
            ProjectedFreePct_AfterFullCheckdb = CAST(@InstProjectedFreeGB * 100.0 / NULLIF(@InstanceTotalGB, 0) AS DECIMAL(5,2)),
            ShortfallGB          = @InstShortfallGB,
            IsShortfallMaterial  = @InstIsShortfallMaterial,
            Recommendation = CASE
                WHEN @InstanceTotalGB IS NULL THEN 'UNKNOWN - insufficient permission or DMV not yet populated (needs VIEW SERVER STATE / VIEW DATABASE PERFORMANCE STATE)'
                WHEN @InstIsShortfallMaterial = 0 AND @InstShortfallGB > 0
                    THEN 'OK (within estimate margin) - a small ' + CAST(@InstShortfallGB AS VARCHAR(20)) + ' GB gap below the ' + CAST(@MinVolumeFreePctAfterWork AS VARCHAR(10))
                        + '% target exists but is below the materiality threshold (' + CAST(@MinMaterialShortfallGB AS VARCHAR(10)) + ' GB / ' + CAST(@MinMaterialShortfallPct AS VARCHAR(10))
                        + '% of the target free space) - likely estimate imprecision, not a real capacity risk.'
                WHEN @InstIsShortfallMaterial = 1
                    THEN 'ADD INSTANCE STORAGE - shared headroom after the worst-case single full CHECKDB falls below ' + CAST(@MinVolumeFreePctAfterWork AS VARCHAR(10)) + '% target. '
                        + CASE
                            WHEN @MIServiceTier = 'BusinessCritical'
                                THEN 'Business Critical storage is local SSD sized by vCore count - increase vCores, or reduce which databases run full logical checks concurrently.'
                            WHEN @MIServiceTier = 'GeneralPurpose'
                                THEN 'General Purpose storage can be resized directly (increase reserved storage in the Azure portal/ARM), or check whether upgrading to Next-gen General Purpose is available for this instance (higher IOPS/throughput at the same baseline cost - not detectable from T-SQL, verify in the Azure portal under Compute + storage).'
                            ELSE 'Scale up MI storage (tier/SKU could not be determined - see UNKNOWN case above for permission requirements).'
                        END
                ELSE 'OK'
            END
        FROM #Databases db
        ORDER BY db.TotalSizeGB DESC;
    END

    ------------------------------------------------------------------
    -- Result set 2: tempdb sizing recommendation.
    -- Includes a live snapshot of tempdb's CURRENTLY USED space as a
    -- baseline proxy for concurrent tempdb consumers other than CHECKDB
    -- (application workload, other jobs, version store, etc.) - see the
    -- header comment "WHEN TO RUN THIS" for guidance on capturing this at
    -- a representative busy/peak time, not right after a restart or
    -- during an idle window.
    ------------------------------------------------------------------
    DECLARE @CurrentTempdbSizeGB DECIMAL(18,2);
    SELECT @CurrentTempdbSizeGB = SUM(size) * 8.0 / 1024 / 1024 FROM tempdb.sys.database_files;

    DECLARE @InstanceName NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));

    DECLARE @CurrentTempdbUsedGB DECIMAL(18,2);
    SELECT @CurrentTempdbUsedGB = SUM(total_page_count - unallocated_extent_page_count) * 8.0 / 1024 / 1024
    FROM tempdb.sys.dm_db_file_space_usage;

    DECLARE @LargestDBSizeGB DECIMAL(18,2);
    SELECT @LargestDBSizeGB = MAX(DataSizeGB) FROM #Databases;

    DECLARE @EstCheckdbTempdbNeedGB DECIMAL(18,2) = CAST(@LargestDBSizeGB * @TempdbPctOfLargestDB / 100.0 AS DECIMAL(18,2));
    DECLARE @RecommendedTempdbSizeGB DECIMAL(18,2) = CAST(ISNULL(@CurrentTempdbUsedGB, 0) + @EstCheckdbTempdbNeedGB AS DECIMAL(18,2));

    DECLARE @ShortfallGB DECIMAL(18,2) = CASE WHEN @RecommendedTempdbSizeGB > @CurrentTempdbSizeGB
                                        THEN CAST(@RecommendedTempdbSizeGB - @CurrentTempdbSizeGB AS DECIMAL(18,2))
                                        ELSE 0 END;

    -- A shortfall only counts as ACTIONABLE once it clears BOTH an absolute
    -- floor and a relative floor (see header "Materiality threshold") - this
    -- avoids flagging sub-GB deltas that are really just baseline snapshot
    -- noise or heuristic imprecision as if they were a real capacity risk.
    DECLARE @IsShortfallMaterial BIT = CASE
        WHEN @ShortfallGB > @MinMaterialShortfallGB
            AND @ShortfallGB > (@RecommendedTempdbSizeGB * @MinMaterialShortfallPct / 100.0)
            THEN 1 ELSE 0 END;

    ------------------------------------------------------------------
    -- Close the loop on "ADD ~X GB to tempdb": that's meaningless advice
    -- on its own without knowing whether tempdb CAN actually grow that
    -- much. Box product only (checked live via sys.dm_os_volume_stats /
    -- sys.master_files - unreliable/not applicable on MI, whose tempdb is
    -- a fixed allocation by service tier and not manually resizable, per
    -- the existing MI-specific Recommendation branches below).
    --   - Autogrowth DISABLED (growth = 0) on any tempdb data file blocks
    --     automatic growth entirely, regardless of volume free space.
    --   - A file-level max_size cap below the recommended size blocks
    --     growth once that cap is hit, even with autogrowth enabled and
    --     the volume otherwise having room.
    --   - Insufficient free space on the volume hosting tempdb's data
    --     file(s) blocks growth even with autogrowth enabled and no cap.
    -- Worst case (any file/volume with an issue) is reported, matching the
    -- worst-case pattern used elsewhere in this script.
    ------------------------------------------------------------------
    DECLARE @TempdbVolumeMountPoint NVARCHAR(260) = NULL;
    DECLARE @TempdbVolumeFreeGB     DECIMAL(18,2) = NULL;
    DECLARE @TempdbAutogrowthEnabled BIT          = NULL;
    DECLARE @TempdbMaxSizeCapGB     DECIMAL(18,2) = NULL;   -- NULL = no cap (unlimited) on any tempdb data file

    IF @IsManagedInstance = 0
    BEGIN
        DECLARE @TempdbFileInfo TABLE (
            GrowthEnabled     BIT,
            MaxSizeGB         DECIMAL(18,2) NULL,
            VolumeMountPoint  NVARCHAR(260),
            VolumeFreeGB      DECIMAL(18,2),
            VolumeFreePct     DECIMAL(5,2)
        );

        BEGIN TRY
            INSERT INTO @TempdbFileInfo (GrowthEnabled, MaxSizeGB, VolumeMountPoint, VolumeFreeGB, VolumeFreePct)
            SELECT
                CASE WHEN mf.growth = 0 THEN 0 ELSE 1 END,
                CASE WHEN mf.max_size = -1 THEN NULL ELSE CAST(mf.max_size * 8.0 / 1024 / 1024 AS DECIMAL(18,2)) END,
                vs.volume_mount_point,
                CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS DECIMAL(18,2)),
                CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS DECIMAL(5,2))
            FROM sys.master_files mf
            CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
            WHERE mf.database_id = DB_ID('tempdb') AND mf.type = 0;   -- data files only
        END TRY
        BEGIN CATCH
            -- Insufficient permission or DMV unavailable - leave everything
            -- NULL, the Recommendation text below calls this out explicitly
            -- rather than silently assuming growth is safe.
        END CATCH

        SELECT @TempdbAutogrowthEnabled = MIN(CAST(GrowthEnabled AS INT)) FROM @TempdbFileInfo;
        SELECT @TempdbMaxSizeCapGB = MIN(MaxSizeGB) FROM @TempdbFileInfo WHERE MaxSizeGB IS NOT NULL;
        SELECT TOP (1) @TempdbVolumeMountPoint = VolumeMountPoint, @TempdbVolumeFreeGB = VolumeFreeGB
        FROM @TempdbFileInfo ORDER BY VolumeFreePct ASC;
    END

    DECLARE @TempdbVolumeSufficient BIT = CASE
        WHEN @IsManagedInstance = 1 THEN NULL
        WHEN @ShortfallGB <= 0 THEN 1
        WHEN @TempdbVolumeFreeGB IS NULL THEN NULL   -- could not read volume stats
        WHEN @TempdbVolumeFreeGB >= @ShortfallGB THEN 1
        ELSE 0 END;

    DECLARE @TempdbMaxSizeAllowsGrowth BIT = CASE
        WHEN @IsManagedInstance = 1 THEN NULL
        WHEN @TempdbMaxSizeCapGB IS NULL THEN 1        -- unlimited
        WHEN @TempdbMaxSizeCapGB >= @RecommendedTempdbSizeGB THEN 1
        ELSE 0 END;

    -- Concatenate every distinct problem found so the Recommendation calls
    -- out ALL blockers, not just the first one encountered.
    DECLARE @TempdbGrowthIssues NVARCHAR(1000) = '';
    IF @IsManagedInstance = 0 AND @IsShortfallMaterial = 1
    BEGIN
        IF @TempdbAutogrowthEnabled = 0
            SET @TempdbGrowthIssues += 'Autogrowth is DISABLED on at least one tempdb data file, so it will NOT grow automatically. ';
        IF @TempdbMaxSizeAllowsGrowth = 0
            SET @TempdbGrowthIssues += 'Tempdb has a maximum size limit of ' + CAST(@TempdbMaxSizeCapGB AS VARCHAR(20))
                + ' GB, below the recommended ' + CAST(@RecommendedTempdbSizeGB AS VARCHAR(20)) + ' GB - increase or remove this growth limit. ';
        IF @TempdbVolumeSufficient = 0
            SET @TempdbGrowthIssues += 'Volume ' + ISNULL(@TempdbVolumeMountPoint, '?') + ' hosting tempdb has only '
                + CAST(@TempdbVolumeFreeGB AS VARCHAR(20)) + ' GB free, less than the ' + CAST(@ShortfallGB AS VARCHAR(20))
                + ' GB shortfall - add disk space (or add a tempdb file on a different volume) before relying on autogrowth. ';
        IF @TempdbVolumeFreeGB IS NULL AND @TempdbAutogrowthEnabled IS NULL
            SET @TempdbGrowthIssues += 'Could not read tempdb file/volume details (insufficient permission or sys.dm_os_volume_stats unavailable) - manually verify autogrowth and free disk space. ';
    END

    SELECT
        InstanceName              = @InstanceName,
        ServiceTier               = ISNULL(@MIServiceTier, CASE WHEN @IsManagedInstance = 1 THEN 'Unknown' ELSE 'VM' END),
        CurrentTempdbSizeGB      = @CurrentTempdbSizeGB,
        CurrentTempdbUsedGB      = @CurrentTempdbUsedGB,          -- point-in-time baseline snapshot - see header re: WHEN to capture this
        LargestDatabaseDataGB    = @LargestDBSizeGB,
        EstCheckdbTempdbNeedGB   = @EstCheckdbTempdbNeedGB,       -- CHECKDB's own estimated footprint, in isolation
        RecommendedTempdbSizeGB  = @RecommendedTempdbSizeGB,      -- = CurrentTempdbUsedGB (baseline) + EstCheckdbTempdbNeedGB
        ShortfallGB              = @ShortfallGB,
        IsShortfallMaterial      = @IsShortfallMaterial,          -- 0 = shortfall (if any) is within estimate noise - see header "Materiality threshold"
        TempdbVolumeMountPoint   = @TempdbVolumeMountPoint,       -- box product only; NULL on MI (fixed allocation, not a resizable volume concept)
        TempdbVolumeFreeGB       = @TempdbVolumeFreeGB,
        TempdbAutogrowthEnabled  = @TempdbAutogrowthEnabled,      -- 0 = at least one tempdb data file has growth disabled
        TempdbMaxSizeCapGB       = @TempdbMaxSizeCapGB,           -- NULL = no cap (unlimited) on any tempdb data file
        Recommendation = CASE
            WHEN @ShortfallGB > 0 AND @IsShortfallMaterial = 0
                THEN 'OK (within estimate margin) - a small ' + CAST(@ShortfallGB AS VARCHAR(20)) + ' GB shortfall exists but is below the materiality threshold ('
                    + CAST(@MinMaterialShortfallGB AS VARCHAR(10)) + ' GB / ' + CAST(@MinMaterialShortfallPct AS VARCHAR(10))
                    + '% of recommended size) - likely baseline snapshot noise or heuristic imprecision, not a real capacity risk. Re-run at a busier period if unsure.'
            WHEN @IsManagedInstance = 1 AND @IsShortfallMaterial = 1 AND @MIServiceTier = 'BusinessCritical'
                THEN 'tempdb is below the estimated recommendation. Business Critical tempdb runs on dedicated local SSD sized by vCore count and is not manually resizable - increase vCores for more tempdb capacity, or reduce which databases run full logical checks concurrently.'
            WHEN @IsManagedInstance = 1 AND @IsShortfallMaterial = 1 AND @MIServiceTier = 'GeneralPurpose'
                THEN 'tempdb is below the estimated recommendation. General Purpose tempdb capacity is fixed by vCore count and is not manually resizable - increase vCores, or check whether Next-gen General Purpose is available/enabled for this instance (uses Elastic SAN storage with higher IOPS/throughput - verify actual tempdb limits for your hardware generation in the Azure portal, since this is not detectable from T-SQL), or reduce which databases run full logical checks concurrently.'
            WHEN @IsManagedInstance = 1 AND @IsShortfallMaterial = 1
                THEN 'tempdb is below the estimated recommendation, but MI tempdb size is fixed by service tier and not manually resizable (tier could not be determined - see UNKNOWN case in result set 1 for permission requirements) - consider a higher tier, or reducing which databases run full logical checks concurrently.'
            WHEN @IsShortfallMaterial = 1 AND LEN(@TempdbGrowthIssues) = 0
                THEN 'ADD ~' + CAST(@ShortfallGB AS VARCHAR(20)) + ' GB to tempdb - NO ISSUE: autogrowth is enabled, no restrictive max size cap, and '
                    + CAST(@TempdbVolumeFreeGB AS VARCHAR(20)) + ' GB free on ' + @TempdbVolumeMountPoint
                    + ' (>= the shortfall) - autogrowth CAN cover this automatically during the first live runs, though pre-growing tempdb manually still avoids growth-pause overhead mid-check.'
            WHEN @IsShortfallMaterial = 1
                THEN 'ADD ~' + CAST(@ShortfallGB AS VARCHAR(20)) + ' GB to tempdb - ISSUE FOUND: ' + @TempdbGrowthIssues
            ELSE 'OK - current tempdb size already meets the estimated recommendation.'
        END;

    DROP TABLE #Databases;
END
GO
