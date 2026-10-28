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
 Updated: 2026-10-26
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
    @VLDBDatabases NVARCHAR(MAX),   -- comma-separated list (names may be bracket-quoted), e.g. same @VLDBs list produced by Run_TieredIntegrityCheck
    @DaysInCycle INT = 7,           -- number of scheduled runs to complete one full rotation
    @TimeLimitSeconds INT = 21600   -- 6 hours per run; tune to your maintenance window
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DbName SYSNAME;
    DECLARE @QuotedDb NVARCHAR(300);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @BatchTables NVARCHAR(MAX);
    DECLARE @BatchSize INT, @BatchCount INT, @CheckedCount INT, @LogIdBefore INT;
    DECLARE @TrackingDB SYSNAME = DB_NAME();   -- database this proc lives in (e.g. DBAdmin) - captured
                                                -- BEFORE any dynamic SQL switches context via USE,
                                                -- so the tracking table reference stays correct.

    IF @DaysInCycle IS NULL OR @DaysInCycle < 1
    BEGIN
        RAISERROR('@DaysInCycle must be 1 or greater.', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------------
    -- Split the database list with dbo.DBCCGov_SplitDatabaseList
    -- (Split_DatabaseList.sql): items may be bracket-quoted ([name], ]]
    -- for ]), so any database name - including one with a comma - works.
    ------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM dbo.DBCCGov_SplitDatabaseList(@VLDBDatabases) WHERE IsMalformed = 1)
        THROW 50190, 'Database list contains an overlength or malformed bracket-quoted name.', 1;
    DECLARE @Dbs TABLE (Position INT PRIMARY KEY, DbName SYSNAME NOT NULL);
    INSERT INTO @Dbs (Position, DbName)
    SELECT Position, DatabaseName FROM dbo.DBCCGov_SplitDatabaseList(@VLDBDatabases);
    DECLARE @DirectDb BIT, @DbStart DATETIME2, @DirectCmd NVARCHAR(MAX), @DirectRc INT, @DirectFailed INT = 0, @DSchema SYSNAME, @DTable SYSNAME;

    -- Work table for one database's batch: the exact same set is used both to
    -- build the @Objects list and to decide which rows to stamp afterward.
    CREATE TABLE #Batch (SchemaName SYSNAME NOT NULL, TableName SYSNAME NOT NULL);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DbName FROM @Dbs ORDER BY Position;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @QuotedDb = QUOTENAME(@DbName);

        -- Pre-flight headroom check for this specific database (tempdb
        -- logical/volume + this DB's own data-volume + IFI on box product;
        -- tempdb-logical-only on MI). Non-blocking - see
        -- Check_DiskAndTempdbHeadroom.sql for rationale. Checked per-database
        -- since each VLDB in the rotation list may live on a different volume.
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = @QuotedDb;

        -- Synchronise the tracking table with the database's current tables:
        -- register new tables, and remove rows for tables that no longer exist
        -- (otherwise a dropped table is selected into every future batch).
        -- The dynamic SQL switches context into @DbName to read its sys.tables,
        -- so the tracking table is fully qualified with @TrackingDB, and the
        -- database name is passed as a parameter, never concatenated as text.
        SET @Sql = N'
            USE ' + QUOTENAME(@DbName) + N';
            INSERT INTO ' + QUOTENAME(@TrackingDB) + N'.dbo.VLDB_CheckRotationLog (DatabaseName, SchemaName, TableName, LastCheckedDate)
            SELECT @p_DbName, s.name, t.name, NULL
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE NOT EXISTS (
                SELECT 1 FROM ' + QUOTENAME(@TrackingDB) + N'.dbo.VLDB_CheckRotationLog r
                WHERE r.DatabaseName = @p_DbName
                  AND r.SchemaName COLLATE DATABASE_DEFAULT = s.name COLLATE DATABASE_DEFAULT
                  AND r.TableName COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT
            );

            DELETE r
            FROM ' + QUOTENAME(@TrackingDB) + N'.dbo.VLDB_CheckRotationLog r
            WHERE r.DatabaseName = @p_DbName
              AND NOT EXISTS (
                SELECT 1
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE s.name COLLATE DATABASE_DEFAULT = r.SchemaName COLLATE DATABASE_DEFAULT
                  AND t.name COLLATE DATABASE_DEFAULT = r.TableName COLLATE DATABASE_DEFAULT
            );';
        EXEC sp_executesql @Sql, N'@p_DbName SYSNAME', @p_DbName = @DbName;

        -- Select the oldest-checked (or never-checked) 1/@DaysInCycle share of tables.
        SELECT @BatchSize = CAST(CEILING(CAST(COUNT(*) AS FLOAT) / @DaysInCycle) AS INT)
        FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = @DbName;

        IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 1;

        TRUNCATE TABLE #Batch;
        INSERT INTO #Batch (SchemaName, TableName)
        SELECT TOP (@BatchSize)
              SchemaName, TableName
        FROM dbo.VLDB_CheckRotationLog
        WHERE DatabaseName = @DbName
        ORDER BY ISNULL(LastCheckedDate, '1900-01-01') ASC, SchemaName, TableName;
        SET @BatchCount = @@ROWCOUNT;

        -- DatabaseIntegrityCheck splits @Databases and @Objects on commas and matches names with LIKE, so a
        -- name containing a comma or a % cannot be passed to it exactly. Such a database is checked entirely
        -- through Hallengren's dbo.CommandExecute with the command text DatabaseIntegrityCheck builds (same
        -- dbo.CommandLog rows); in other databases only such tables are, after DatabaseIntegrityCheck has run.
        SET @DirectDb = CASE WHEN @DbName LIKE N'%,%' OR @DbName LIKE N'%[%]%' THEN 1 ELSE 0 END;
        SET @BatchTables = NULL;
        -- Hallengren's @Objects format is three-part "Database.Schema.Table". It reads
        -- each item with PARSENAME, so every part is bracket-quoted to keep names that
        -- contain dots, brackets or quotes intact. TYPE + .value() keeps & < > unescaped.
        SELECT @BatchTables = STUFF((
            SELECT ',' + QUOTENAME(@DbName) + '.' + QUOTENAME(SchemaName) + '.' + QUOTENAME(TableName)
            FROM #Batch
            WHERE @DirectDb = 0 AND SchemaName NOT LIKE N'%,%' AND SchemaName NOT LIKE N'%[%]%' AND TableName NOT LIKE N'%,%' AND TableName NOT LIKE N'%[%]%'
            ORDER BY SchemaName, TableName
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 1, '');

        IF @BatchCount > 0
        BEGIN
            SELECT @LogIdBefore = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
            SET @DbStart = SYSDATETIME();

            -- Run CHECKTABLE + CHECKALLOC + CHECKCATALOG on this batch of tables (full logical check)
            IF @BatchTables IS NOT NULL
                EXEC dbo.DatabaseIntegrityCheck
                    @Databases = @QuotedDb,
                    @CheckCommands = 'CHECKALLOC,CHECKCATALOG,CHECKTABLE',
                    @Objects = @BatchTables,
                    @TimeLimit = @TimeLimitSeconds,
                    @LogToTable = 'Y';

            -- Direct path. Like @TimeLimit in DatabaseIntegrityCheck, no command starts once
            -- @TimeLimitSeconds has passed since this database's checks began.
            IF @DirectDb = 1 AND (@TimeLimitSeconds IS NULL OR SYSDATETIME() < DATEADD(SECOND, @TimeLimitSeconds, @DbStart))
            BEGIN
                SET @DirectCmd = N'DBCC CHECKALLOC (' + QUOTENAME(@DbName) + N') WITH ALL_ERRORMSGS';
                EXEC @DirectRc = dbo.CommandExecute @DatabaseContext = N'master', @Command = @DirectCmd, @CommandType = N'DBCC_CHECKALLOC', @Mode = 1,
                     @DatabaseName = @DbName, @LogToTable = N'Y', @Execute = N'Y';
                IF @DirectRc <> 0 SET @DirectFailed += 1;
            END
            IF @DirectDb = 1 AND (@TimeLimitSeconds IS NULL OR SYSDATETIME() < DATEADD(SECOND, @TimeLimitSeconds, @DbStart))
            BEGIN
                SET @DirectCmd = N'DBCC CHECKCATALOG (' + QUOTENAME(@DbName) + N')';
                EXEC @DirectRc = dbo.CommandExecute @DatabaseContext = N'master', @Command = @DirectCmd, @CommandType = N'DBCC_CHECKCATALOG', @Mode = 1,
                     @DatabaseName = @DbName, @LogToTable = N'Y', @Execute = N'Y';
                IF @DirectRc <> 0 SET @DirectFailed += 1;
            END
            DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT SchemaName, TableName FROM #Batch
                WHERE @DirectDb = 1 OR SchemaName LIKE N'%,%' OR SchemaName LIKE N'%[%]%' OR TableName LIKE N'%,%' OR TableName LIKE N'%[%]%'
                ORDER BY SchemaName, TableName;
            OPEN table_cursor;
            FETCH NEXT FROM table_cursor INTO @DSchema, @DTable;
            WHILE @@FETCH_STATUS = 0 AND (@TimeLimitSeconds IS NULL OR SYSDATETIME() < DATEADD(SECOND, @TimeLimitSeconds, @DbStart))
            BEGIN
                SET @DirectCmd = N'DBCC CHECKTABLE (N''' + REPLACE(QUOTENAME(@DSchema) + N'.' + QUOTENAME(@DTable), N'''', N'''''') + N''') WITH ALL_ERRORMSGS';
                EXEC @DirectRc = dbo.CommandExecute @DatabaseContext = @DbName, @Command = @DirectCmd, @CommandType = N'DBCC_CHECKTABLE', @Mode = 1,
                     @DatabaseName = @DbName, @SchemaName = @DSchema, @ObjectName = @DTable, @ObjectType = N'U', @LogToTable = N'Y', @Execute = N'Y';
                IF @DirectRc <> 0 SET @DirectFailed += 1;
                FETCH NEXT FROM table_cursor INTO @DSchema, @DTable;
            END
            CLOSE table_cursor;
            DEALLOCATE table_cursor;

            -- Stamp only the tables of this batch that DatabaseIntegrityCheck actually
            -- checked without error in this run (its CommandLog rows). A table skipped
            -- because @TimeLimit was reached, or one that reported an error, keeps its
            -- old date, so it is first in line again next run.
            UPDATE r
            SET LastCheckedDate = SYSDATETIME()
            FROM dbo.VLDB_CheckRotationLog r
            JOIN #Batch b ON r.SchemaName = b.SchemaName AND r.TableName = b.TableName
            WHERE r.DatabaseName = @DbName
              AND EXISTS (
                SELECT 1 FROM dbo.CommandLog c
                WHERE c.ID > @LogIdBefore
                  AND c.CommandType = 'DBCC_CHECKTABLE'
                  AND c.DatabaseName = @DbName
                  AND c.SchemaName = b.SchemaName
                  AND c.ObjectName = b.TableName
                  AND c.EndTime IS NOT NULL
                  AND c.ErrorNumber = 0
            );
            SET @CheckedCount = @@ROWCOUNT;

            IF @CheckedCount < @BatchCount
                RAISERROR('INFO: [%s] %d of %d table(s) in this rotation batch were checked; the other(s) were not reached before @TimeLimitSeconds or reported an error (see dbo.CommandLog). They keep their previous LastCheckedDate and are first in line next run.', 10, 1, @DbName, @CheckedCount, @BatchCount) WITH NOWAIT;
        END

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Fail the job step as DatabaseIntegrityCheck does when a check reported errors.
    IF @DirectFailed > 0
        RAISERROR('%d check(s) run directly reported errors; see dbo.CommandLog.', 16, 1, @DirectFailed);
END
GO
