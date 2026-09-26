/*
================================================================================
 Rotate_VLDB_ObjectLevelChecks.sql

 Purpose:
   Provides full LOGICAL integrity coverage for VLDB-tier databases (>= 2 TB)
   where a nightly full DBCC CHECKDB is impractical. Run_TieredIntegrityCheck
   only runs PHYSICAL_ONLY checks against VLDBs nightly - this script rotates
   CHECKTABLE across a subset of tables each run (e.g. weekly schedule) so
   that, over a full cycle (7 runs), every table has had a full logical check.

   Requires a tracking table (created below) to remember which tables were
   last checked, so rotation resumes correctly across runs.

 Recommended schedule:
   Weekly SQL Agent job, e.g. every Sunday 01:00, with @DaysInCycle = 7 so it
   effectively checks ~1/7th of tables per week -> full coverage per ~7 weeks.
   Tune @DaysInCycle down (e.g. 4) for faster full coverage if the maintenance
   window allows more per-run work.

 Prerequisite: Ola Hallengren's DatabaseIntegrityCheck must be installed.
 Check_DiskAndTempdbHeadroom.sql must also be deployed to the same database first.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-25
================================================================================
*/

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VLDB_CheckRotationLog' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.VLDB_CheckRotationLog
    (
        DatabaseName    SYSNAME       NOT NULL,
        SchemaName      SYSNAME       NOT NULL,
        TableName       SYSNAME       NOT NULL,
        LastCheckedDate DATETIME2     NULL,
        CONSTRAINT PK_VLDB_CheckRotationLog PRIMARY KEY (DatabaseName, SchemaName, TableName)
    );
END
GO

CREATE OR ALTER PROCEDURE dbo.Rotate_VLDB_ObjectLevelChecks
    @VLDBDatabases NVARCHAR(MAX),   -- comma-separated list, e.g. same @VLDBs list produced by Run_TieredIntegrityCheck
    @DaysInCycle INT = 7,           -- number of scheduled runs to complete one full rotation
    @TimeLimitSeconds INT = 21600   -- 6 hours per run; tune to your maintenance window
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @BatchTables NVARCHAR(MAX);
    DECLARE @TrackingDB SYSNAME = DB_NAME();   -- database this proc lives in (e.g. DBAdmin) - captured
                                                -- BEFORE any dynamic SQL switches context via USE,
                                                -- so the tracking table reference stays correct.

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT value FROM STRING_SPLIT(@VLDBDatabases, ',') WHERE LTRIM(RTRIM(value)) <> '';

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Pre-flight headroom check for this specific database (tempdb
        -- logical/volume + this DB's own data-volume + IFI on box product;
        -- tempdb-logical-only on MI). Non-blocking - see
        -- Check_DiskAndTempdbHeadroom.sql for rationale. Checked per-database
        -- since each VLDB in the rotation list may live on a different volume.
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @DbName;

        -- Register any new tables not yet tracked for this database.
        -- Note: dynamic SQL switches context into @DbName to enumerate its sys.tables,
        -- so the tracking table must be fully qualified with @TrackingDB - it does NOT
        -- live in @DbName, it lives in the database this proc was deployed to.
        SET @Sql = N'
            USE ' + QUOTENAME(@DbName) + N';
            INSERT INTO ' + QUOTENAME(@TrackingDB) + N'.dbo.VLDB_CheckRotationLog (DatabaseName, SchemaName, TableName, LastCheckedDate)
            SELECT ''' + @DbName + N''', s.name, t.name, NULL
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE NOT EXISTS (
                SELECT 1 FROM ' + QUOTENAME(@TrackingDB) + N'.dbo.VLDB_CheckRotationLog r
                WHERE r.DatabaseName = ''' + @DbName + N'''
                  AND r.SchemaName COLLATE DATABASE_DEFAULT = s.name COLLATE DATABASE_DEFAULT
                  AND r.TableName COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT
            );';
        EXEC sp_executesql @Sql;

        -- Select the oldest-checked (or never-checked) 1/@DaysInCycle share of tables into a
        -- work table, so the exact same set is used both to build the @Objects list and to
        -- stamp LastCheckedDate afterward (avoids re-deriving/mismatching the batch).
        IF OBJECT_ID('tempdb..#Batch') IS NOT NULL DROP TABLE #Batch;

        DECLARE @BatchSize INT;
        SELECT @BatchSize = CAST(CEILING(CAST(COUNT(*) AS FLOAT) / @DaysInCycle) AS INT)
        FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = @DbName;

        IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 1;

        SELECT TOP (@BatchSize)
              SchemaName, TableName
        INTO #Batch
        FROM dbo.VLDB_CheckRotationLog
        WHERE DatabaseName = @DbName
        ORDER BY ISNULL(LastCheckedDate, '1900-01-01') ASC;

        SET @BatchTables = NULL;
        -- Hallengren's @Objects format is unbracketed three-part "Database.Schema.Table"
        -- (confirmed via https://ola.hallengren.com/sql-server-integrity-check.html) -
        -- it must include the database name, and does not accept bracket-quoted [Schema].[Table].
        SELECT @BatchTables = STUFF((
            SELECT ',' + @DbName + '.' + SchemaName + '.' + TableName
            FROM #Batch
            FOR XML PATH('')
        ), 1, 1, '');

        IF @BatchTables IS NOT NULL
        BEGIN
            -- Run CHECKTABLE + CHECKALLOC + CHECKCATALOG on this batch of tables (full logical check)
            EXEC dbo.DatabaseIntegrityCheck
                @Databases = @DbName,
                @CheckCommands = 'CHECKALLOC,CHECKCATALOG,CHECKTABLE',
                @Objects = @BatchTables,
                @TimeLimit = @TimeLimitSeconds,
                @LogToTable = 'Y';

            -- Mark exactly this batch as checked (join on the work table, not re-derived criteria)
            UPDATE r
            SET LastCheckedDate = SYSDATETIME()
            FROM dbo.VLDB_CheckRotationLog r
            JOIN #Batch b ON r.SchemaName = b.SchemaName AND r.TableName = b.TableName
            WHERE r.DatabaseName = @DbName;
        END

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
GO
