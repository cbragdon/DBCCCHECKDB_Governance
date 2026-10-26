/*
================================================================================
 tests/checks/02_Rotation.sql

 Self-checking test of the INSTALLED dbo.Rotate_VLDB_ObjectLevelChecks,
 run unmodified. Run it in the maintenance database that holds the toolkit
 (sqlcmd -b -I -i ..., or an SSMS query window). Prints PASS/FAIL per
 assertion, then "N test(s) run, N passed, 0 failed", and raises severity 16
 if anything failed.

 Covers:
   - every table is checked within one cycle (@DaysInCycle runs);
   - a table is stamped as checked only when DatabaseIntegrityCheck really
     checked it (@TimeLimitSeconds = 0 makes it check nothing);
   - a dropped table leaves the rotation log;
   - database names with an apostrophe or & < >, schema/table names with a
     dot, an apostrophe or a bracket;
   - several databases in one list, bracket-quoted or not.

 Side effects (all removed at the end): small DBCCGovTest_* databases, their
 rows in dbo.VLDB_CheckRotationLog, and this test's own dbo.CommandLog rows
 (DatabaseName LIKE 'DBCCGovTest[_]%'). Use a test instance or a disposable
 maintenance database (tests/Run-Checks.ps1 does both). Box product only.
================================================================================
*/
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE #DropLabDb @Name SYSNAME
AS
BEGIN
    DECLARE @Sql NVARCHAR(MAX);
    IF DB_ID(@Name) IS NOT NULL
    BEGIN
        SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@Name) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@Name) + N';';
        EXEC (@Sql);
    END
END
GO
-- A database with @Tables one-row tables named t001..tNNN in schema dbo.
CREATE OR ALTER PROCEDURE #NewRotationDb @Name SYSNAME, @Tables INT
AS
BEGIN
    DECLARE @Sql NVARCHAR(MAX), @i INT = 1, @t NVARCHAR(10);
    EXEC #DropLabDb @Name;
    SET @Sql = N'CREATE DATABASE ' + QUOTENAME(@Name) + N'; ALTER DATABASE ' + QUOTENAME(@Name) + N' SET RECOVERY SIMPLE;';
    EXEC (@Sql);
    SET @Sql = N'';
    WHILE @i <= @Tables
    BEGIN
        SET @t = N't' + RIGHT(N'000' + CAST(@i AS NVARCHAR(4)), 3);
        SET @Sql += N'CREATE TABLE dbo.' + @t + N' (id INT PRIMARY KEY, pad CHAR(100) NOT NULL DEFAULT ''x''); INSERT dbo.' + @t + N' (id) VALUES (1);';
        SET @i += 1;
    END
    SET @Sql = N'USE ' + QUOTENAME(@Name) + N'; ' + @Sql;
    EXEC (@Sql);
END
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNumber INT IDENTITY(1,1), TestName NVARCHAR(200) NOT NULL, Passed BIT NOT NULL, Detail NVARCHAR(MAX) NULL);

DECLARE @Start INT, @Err NVARCHAR(4000), @Run INT, @Checked INT, @Stamped INT, @Rows INT, @Distinct INT, @Sql NVARCHAR(MAX);

BEGIN TRY
    IF OBJECT_ID('dbo.Rotate_VLDB_ObjectLevelChecks', 'P') IS NULL OR OBJECT_ID('dbo.VLDB_CheckRotationLog', 'U') IS NULL
       OR OBJECT_ID('dbo.CommandLog', 'U') IS NULL
        THROW 50110, 'Run this in the maintenance database that holds the toolkit (Rotate_VLDB_ObjectLevelChecks, VLDB_CheckRotationLog, CommandLog).', 1;

    DELETE FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName LIKE N'DBCCGovTest[_]%';

    --------------------------------------------------------------------------
    -- 1. Coverage: 10 tables, @DaysInCycle = 3 -> batches of CEILING(10/3) = 4 (the 3rd run takes the
    --    last 2 unchecked tables plus the 2 oldest); all 10 checked in 3 runs, and after every run the
    --    stamped tables are exactly the ones checked in that run.
    --------------------------------------------------------------------------
    EXEC #NewRotationDb N'DBCCGovTest_Rot', 10;
    DECLARE @CycleStart INT = (SELECT ISNULL(MAX(ID), 0) FROM dbo.CommandLog);
    SET @Run = 1;
    WHILE @Run <= 3
    BEGIN
        SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
        DECLARE @Before DATETIME2 = SYSDATETIME();
        EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'DBCCGovTest_Rot', @DaysInCycle = 3;
        SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog
        WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Rot' AND ErrorNumber = 0 AND EndTime IS NOT NULL;
        SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Rot' AND LastCheckedDate >= @Before;
        INSERT INTO #Results (TestName, Passed, Detail)
        VALUES (N'Coverage run ' + CAST(@Run AS NVARCHAR(2)) + N': stamped tables = tables checked in this run (4)',
                CASE WHEN @Checked = @Stamped AND @Checked = 4 THEN 1 ELSE 0 END,
                N'checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)));
        SET @Run += 1;
    END
    SELECT @Distinct = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog
    WHERE ID > @CycleStart AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Rot' AND ErrorNumber = 0;
    SELECT @Rows = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Rot' AND LastCheckedDate IS NOT NULL;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Coverage: all 10 tables checked and stamped within one 3-run cycle', CASE WHEN @Distinct = 10 AND @Rows = 10 THEN 1 ELSE 0 END,
            N'distinct tables checked=' + CAST(@Distinct AS NVARCHAR(10)) + N' stamped=' + CAST(@Rows AS NVARCHAR(10)));

    --------------------------------------------------------------------------
    -- 2. Time limit: @TimeLimitSeconds = 0 -> DatabaseIntegrityCheck starts no command, so nothing may be
    --    stamped. The next run without a limit checks and stamps the whole batch.
    --------------------------------------------------------------------------
    EXEC #NewRotationDb N'DBCCGovTest_Many', 50;
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'DBCCGovTest_Many', @DaysInCycle = 1, @TimeLimitSeconds = 0;
    SELECT @Checked = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Many';
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Many' AND LastCheckedDate IS NOT NULL;
    SELECT @Rows = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Many';
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Time limit reached before any check: 0 of 50 tables stamped', CASE WHEN @Rows = 50 AND @Checked = 0 AND @Stamped = 0 THEN 1 ELSE 0 END,
            N'registered=' + CAST(@Rows AS NVARCHAR(10)) + N' checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)));

    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'DBCCGovTest_Many', @DaysInCycle = 1;
    SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Many' AND ErrorNumber = 0;
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Many' AND LastCheckedDate IS NOT NULL;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Next run without a limit: all 50 checked and stamped', CASE WHEN @Checked = 50 AND @Stamped = 50 THEN 1 ELSE 0 END,
            N'checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)));

    --------------------------------------------------------------------------
    -- 3. A dropped table leaves the rotation log, and the run still checks the others.
    --------------------------------------------------------------------------
    EXEC (N'USE [DBCCGovTest_Rot]; DROP TABLE dbo.t005;');
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    BEGIN TRY
        EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'DBCCGovTest_Rot', @DaysInCycle = 1;
        SET @Err = NULL;
    END TRY
    BEGIN CATCH
        SET @Err = ERROR_MESSAGE();
    END CATCH
    SELECT @Rows = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Rot' AND TableName = N't005';
    SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Rot' AND ErrorNumber = 0;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Dropped table removed from the rotation log; the other 9 checked', CASE WHEN @Err IS NULL AND @Rows = 0 AND @Checked = 9 THEN 1 ELSE 0 END,
            N'rows for t005=' + CAST(@Rows AS NVARCHAR(10)) + N' checked=' + CAST(@Checked AS NVARCHAR(10)) + ISNULL(N' error=' + @Err, N''));

    --------------------------------------------------------------------------
    -- 4. Awkward names: database with an apostrophe and & < >, schema and table names with a dot,
    --    an apostrophe and a closing bracket; two databases in one list, one bracket-quoted.
    --------------------------------------------------------------------------
    EXEC #NewRotationDb N'DBCCGovTest_O''Brien & <Co>', 2;
    SET @Sql = N'USE ' + QUOTENAME(N'DBCCGovTest_O''Brien & <Co>') + N';
        EXEC (N''CREATE SCHEMA [s.x''''y]'');
        CREATE TABLE [s.x''y].[t.o''q]]] (id INT PRIMARY KEY);
        INSERT [s.x''y].[t.o''q]]] (id) VALUES (1);';
    EXEC (@Sql);
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    BEGIN TRY
        EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'[DBCCGovTest_O''Brien & <Co>], DBCCGovTest_Many', @DaysInCycle = 1;
        SET @Err = NULL;
    END TRY
    BEGIN CATCH
        SET @Err = ERROR_MESSAGE();
    END CATCH
    SELECT @Checked = COUNT(DISTINCT SchemaName + N'.' + ObjectName) FROM dbo.CommandLog
    WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_O''Brien & <Co>' AND ErrorNumber = 0;
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_O''Brien & <Co>' AND LastCheckedDate IS NOT NULL;
    SELECT @Rows = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_O''Brien & <Co>' AND SchemaName = N's.x''y' AND TableName = N't.o''q]' AND LastCheckedDate IS NOT NULL;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Awkward database, schema and table names: all 3 tables checked and stamped', CASE WHEN @Err IS NULL AND @Checked = 3 AND @Stamped = 3 AND @Rows = 1 THEN 1 ELSE 0 END,
            N'checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)) + N' [s.x''y].[t.o''q]]] stamped=' + CAST(@Rows AS NVARCHAR(10)) + ISNULL(N' error=' + @Err, N''));
    SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Many' AND ErrorNumber = 0;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Second database in the same list processed too', CASE WHEN @Checked = 50 THEN 1 ELSE 0 END, N'DBCCGovTest_Many checked=' + CAST(@Checked AS NVARCHAR(10)));

    --------------------------------------------------------------------------
    -- 5. Names DatabaseIntegrityCheck cannot carry (comma, %): checked directly through CommandExecute.
    --    a) a database with a comma in its name: time limit 0 stamps nothing; a full run checks and stamps
    --       every table and logs CHECKALLOC and CHECKCATALOG for it.
    --    b) an ordinary database with tables named x,y and p%q: all four tables checked and stamped.
    --------------------------------------------------------------------------
    EXEC #NewRotationDb N'DBCCGovTest_R,ot', 2;
    EXEC (N'USE [DBCCGovTest_R,ot]; CREATE TABLE dbo.[x,y] (id INT PRIMARY KEY); CREATE TABLE dbo.[p%q] (id INT PRIMARY KEY);');
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    BEGIN TRY EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'[DBCCGovTest_R,ot]', @DaysInCycle = 1, @TimeLimitSeconds = 0; SET @Err = NULL; END TRY
    BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
    SELECT @Checked = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND DatabaseName = N'DBCCGovTest_R,ot' AND CommandType LIKE 'DBCC[_]%';
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_R,ot' AND LastCheckedDate IS NOT NULL;
    SELECT @Rows = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_R,ot';
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Comma database [DBCCGovTest_R,ot], time limit 0: registered 4, ran nothing, stamped nothing', CASE WHEN @Err IS NULL AND @Rows = 4 AND @Checked = 0 AND @Stamped = 0 THEN 1 ELSE 0 END,
            N'registered=' + CAST(@Rows AS NVARCHAR(10)) + N' DBCC rows=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)) + ISNULL(N' error=' + @Err, N''));

    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    BEGIN TRY EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'[DBCCGovTest_R,ot]', @DaysInCycle = 1; SET @Err = NULL; END TRY
    BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
    SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_R,ot' AND ErrorNumber = 0;
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_R,ot' AND LastCheckedDate IS NOT NULL;
    SELECT @Rows = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND DatabaseName = N'DBCCGovTest_R,ot' AND CommandType IN ('DBCC_CHECKALLOC', 'DBCC_CHECKCATALOG') AND ErrorNumber = 0;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Comma database [DBCCGovTest_R,ot]: 4 tables checked and stamped, CHECKALLOC + CHECKCATALOG logged', CASE WHEN @Err IS NULL AND @Checked = 4 AND @Stamped = 4 AND @Rows = 2 THEN 1 ELSE 0 END,
            N'checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)) + N' alloc+catalog=' + CAST(@Rows AS NVARCHAR(10)) + ISNULL(N' error=' + @Err, N''));

    EXEC #NewRotationDb N'DBCCGovTest_Mixed', 2;
    EXEC (N'USE [DBCCGovTest_Mixed]; CREATE TABLE dbo.[x,y] (id INT PRIMARY KEY); CREATE TABLE dbo.[p%q] (id INT PRIMARY KEY);');
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    BEGIN TRY EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases = N'DBCCGovTest_Mixed', @DaysInCycle = 1; SET @Err = NULL; END TRY
    BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
    SELECT @Checked = COUNT(DISTINCT ObjectName) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Mixed' AND ErrorNumber = 0;
    SELECT @Stamped = COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName = N'DBCCGovTest_Mixed' AND LastCheckedDate IS NOT NULL;
    SELECT @Rows = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'DBCC_CHECKTABLE' AND DatabaseName = N'DBCCGovTest_Mixed' AND ObjectName IN (N'x,y', N'p%q') AND ErrorNumber = 0;
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Tables x,y and p%q in an ordinary database: all 4 tables checked and stamped', CASE WHEN @Err IS NULL AND @Checked = 4 AND @Stamped = 4 AND @Rows = 2 THEN 1 ELSE 0 END,
            N'checked=' + CAST(@Checked AS NVARCHAR(10)) + N' stamped=' + CAST(@Stamped AS NVARCHAR(10)) + N' x,y + p%q=' + CAST(@Rows AS NVARCHAR(10)) + ISNULL(N' error=' + @Err, N''));
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
    INSERT INTO #Results (TestName, Passed, Detail) VALUES (N'Test setup or run completed without error', 0, @Err);
END CATCH;

-- Cleanup (always)
DELETE FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName LIKE N'DBCCGovTest[_]%';
DECLARE @d SYSNAME;
DECLARE dropper CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE name LIKE N'DBCCGovTest[_]%' AND name <> DB_NAME();
OPEN dropper; FETCH NEXT FROM dropper INTO @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC #DropLabDb @d; FETCH NEXT FROM dropper INTO @d; END
CLOSE dropper; DEALLOCATE dropper;
DELETE FROM dbo.CommandLog WHERE DatabaseName LIKE N'DBCCGovTest[_]%' AND DatabaseName <> DB_NAME();

SELECT TestNumber, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, TestName, Detail FROM #Results ORDER BY TestNumber;
DECLARE @Total INT = (SELECT COUNT(*) FROM #Results), @Failed INT = (SELECT COUNT(*) FROM #Results WHERE Passed = 0);
PRINT '02_Rotation: ' + CAST(@Total AS VARCHAR(10)) + ' test(s) run, ' + CAST(@Total - @Failed AS VARCHAR(10)) + ' passed, ' + CAST(@Failed AS VARCHAR(10)) + ' failed.';
IF @Failed > 0 OR @Total = 0
    RAISERROR('02_Rotation: %d of %d test(s) FAILED - see the result set.', 16, 1, @Failed, @Total);
GO
