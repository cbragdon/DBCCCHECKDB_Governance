/*
================================================================================
 tests/checks/01_Tiering_Routing.sql

 Self-checking test of the INSTALLED dbo.Run_TieredIntegrityCheck and
 dbo.Run_LargeTier_WeeklyFullCheck. Run it in the maintenance database that
 holds the toolkit (sqlcmd -b -I -i ..., or an SSMS query window). Prints
 PASS/FAIL per assertion, then "N test(s) run, N passed, 0 failed", and
 raises severity 16 if anything failed.

 How it tests the real code without 500 GB databases:
   It reads each procedure's definition from the database (OBJECT_DEFINITION)
   and creates a test copy with exactly these edits, each of which must match
   the expected number of times or the test fails:
     - tier boundaries scaled from GB to 0.25 / 0.5 / 0.75 GB;
     - the database scan narrowed to databases named DBCCGovTest_*, so no
       real database is checked;
     - sys.dm_hadr_database_replica_states replaced by a test table, so
       availability-group roles can be simulated on any instance.
   Everything else - list building, role filtering, PHYSICAL_ONLY, MAXDOP,
   and the calls to DatabaseIntegrityCheck - is the installed code.

 Side effects (all removed at the end): about 3.5 GB of DBCCGovTest_*
 databases in the instance default paths, two dbo.*_TestScaled procedures,
 the table dbo.DBCCGovTest_ReplicaStates, and this test's own dbo.CommandLog
 rows (DatabaseName LIKE 'DBCCGovTest[_]%'). Use a test instance or a
 disposable maintenance database (tests/Run-Checks.ps1 does both).
 Box product only.
================================================================================
*/
SET NOCOUNT ON;
GO
------------------------------------------------------------------------------
-- Helpers (temporary procedures, gone when the session ends)
------------------------------------------------------------------------------
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
-- A database whose data + log files total exactly @TotalMB (the size the procedures tier on).
CREATE OR ALTER PROCEDURE #NewLabDb @Name SYSNAME, @TotalMB INT
AS
BEGIN
    DECLARE @Sql NVARCHAR(MAX), @DataFile SYSNAME, @DataMB INT, @LogMB INT, @Msg NVARCHAR(400);
    EXEC #DropLabDb @Name;
    SET @Sql = N'CREATE DATABASE ' + QUOTENAME(@Name) + N'; ALTER DATABASE ' + QUOTENAME(@Name) + N' SET RECOVERY SIMPLE;';
    EXEC (@Sql);
    SELECT @DataFile = name, @DataMB = size / 128 FROM sys.master_files WHERE database_id = DB_ID(@Name) AND type = 0;
    SELECT @LogMB = SUM(size) / 128 FROM sys.master_files WHERE database_id = DB_ID(@Name) AND type = 1;
    IF (SELECT COUNT(*) FROM sys.master_files WHERE database_id = DB_ID(@Name)) <> 2
       OR (SELECT SUM(size) % 128 FROM sys.master_files WHERE database_id = DB_ID(@Name)) <> 0
       OR @TotalMB - @LogMB < @DataMB
    BEGIN
        SET @Msg = N'Cannot size test database ' + @Name + N' to ' + CAST(@TotalMB AS NVARCHAR(10)) + N' MB from the model database''s files.';
        THROW 50100, @Msg, 1;
    END
    IF @TotalMB - @LogMB > @DataMB
    BEGIN
        SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@Name) + N' MODIFY FILE (NAME = ' + QUOTENAME(@DataFile) + N', SIZE = ' + CAST(@TotalMB - @LogMB AS NVARCHAR(10)) + N'MB);';
        EXEC (@Sql);
    END
END
GO
-- A test copy of an installed procedure. #Edits (Ordinal, OldText, NewText, ExpectedCount) is created
-- by the caller; every edit must match exactly ExpectedCount times.
CREATE OR ALTER PROCEDURE #MakeTestCopy @Source SYSNAME, @Copy SYSNAME
AS
BEGIN
    DECLARE @Def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@Source));
    DECLARE @Ordinal INT = 0, @Old NVARCHAR(4000), @New NVARCHAR(4000), @Want INT, @Got INT, @Sql NVARCHAR(MAX), @Msg NVARCHAR(4000);
    IF @Def IS NULL BEGIN SET @Msg = N'Cannot read the definition of ' + @Source + N'.'; THROW 50101, @Msg, 1; END
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @Ordinal = Ordinal, @Old = OldText, @New = NewText, @Want = ExpectedCount
        FROM #Edits WHERE Ordinal > @Ordinal ORDER BY Ordinal;
        IF @@ROWCOUNT = 0 BREAK;
        SET @Got = (DATALENGTH(@Def) - DATALENGTH(REPLACE(@Def, @Old, N''))) / DATALENGTH(@Old);
        IF @Got <> @Want
        BEGIN
            SET @Msg = N'Test copy of ' + @Source + N': expected ' + CAST(@Want AS NVARCHAR(10)) + N' occurrence(s) of [' + @Old
                     + N'], found ' + CAST(@Got AS NVARCHAR(10)) + N'. The procedure text changed; review it and update this test.';
            THROW 50102, @Msg, 1;
        END
        SET @Def = REPLACE(@Def, @Old, @New);
    END
    SET @Sql = N'IF OBJECT_ID(N''' + @Copy + N''', ''P'') IS NOT NULL DROP PROCEDURE ' + @Copy + N';';
    EXEC (@Sql);
    EXEC (@Def);
END
GO

------------------------------------------------------------------------------
-- Test
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNumber INT IDENTITY(1,1), TestName NVARCHAR(200) NOT NULL, Passed BIT NOT NULL, Detail NVARCHAR(MAX) NULL);

DECLARE @Start INT, @Err NVARCHAR(4000);
DECLARE @Lab TABLE (Name SYSNAME PRIMARY KEY, TotalMB INT NOT NULL);
INSERT INTO @Lab (Name, TotalMB) VALUES
    (N'DBCCGovTest_Small', 64),
    (N'DBCCGovTest_R&D<1>', 64),         -- & < > in the name (were escaped by FOR XML PATH)
    (N'DBCCGovTest_O''Brien', 64),       -- apostrophe
    (N'DBCCGovTest_a,b', 64),            -- comma: cannot be passed to DatabaseIntegrityCheck, must be skipped cleanly
    (N'DBCCGovTest_Primary', 64),        -- simulated AG primary
    (N'DBCCGovTest_Secondary', 64),      -- simulated AG secondary: no full CHECKDB here
    (N'DBCCGovTest_Edge', 256),          -- exactly on the Small/Medium boundary (0.25 GB) -> Medium
    (N'DBCCGovTest_Medium', 400),
    (N'DBCCGovTest_Large', 600),
    (N'DBCCGovTest_SecondaryLarge', 600),-- simulated AG secondary: PHYSICAL_ONLY nightly still runs, weekly full check does not
    (N'DBCCGovTest_VLDB', 800);

BEGIN TRY
    DECLARE @n SYSNAME, @mb INT;
    DECLARE lab CURSOR LOCAL FAST_FORWARD FOR SELECT Name, TotalMB FROM @Lab;
    OPEN lab; FETCH NEXT FROM lab INTO @n, @mb;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC #NewLabDb @n, @mb; FETCH NEXT FROM lab INTO @n, @mb; END
    CLOSE lab; DEALLOCATE lab;

    IF OBJECT_ID('dbo.DBCCGovTest_ReplicaStates', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_ReplicaStates;
    CREATE TABLE dbo.DBCCGovTest_ReplicaStates (database_id INT NOT NULL, is_local BIT NOT NULL, is_primary_replica BIT NOT NULL);
    -- Two simulated AGs. Rows for the remote replicas too, as the real DMV shows them on a primary.
    INSERT INTO dbo.DBCCGovTest_ReplicaStates (database_id, is_local, is_primary_replica) VALUES
        (DB_ID(N'DBCCGovTest_Primary'), 1, 1), (DB_ID(N'DBCCGovTest_Primary'), 0, 0),
        (DB_ID(N'DBCCGovTest_Secondary'), 1, 0),
        (DB_ID(N'DBCCGovTest_SecondaryLarge'), 1, 0);

    CREATE TABLE #Edits (Ordinal INT PRIMARY KEY, OldText NVARCHAR(4000) NOT NULL, NewText NVARCHAR(4000) NOT NULL, ExpectedCount INT NOT NULL);
    INSERT INTO #Edits VALUES
        (1, N'PROCEDURE dbo.Run_TieredIntegrityCheck', N'PROCEDURE dbo.Run_TieredIntegrityCheck_TestScaled', 1),
        (2, N'DECLARE @SmallMaxGB  DECIMAL(18,2) = 50;', N'DECLARE @SmallMaxGB  DECIMAL(18,2) = 0.25;', 1),
        (3, N'DECLARE @MediumMaxGB DECIMAL(18,2) = 500;', N'DECLARE @MediumMaxGB DECIMAL(18,2) = 0.5;', 1),
        (4, N'DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;', N'DECLARE @LargeMaxGB  DECIMAL(18,2) = 0.75;', 1),
        (5, N'AND d.state = 0', N'AND d.state = 0 AND d.name LIKE N''DBCCGovTest[_]%''', 1),
        (6, N'sys.dm_hadr_database_replica_states', N'dbo.DBCCGovTest_ReplicaStates', 2);   -- the query and its comment
    EXEC #MakeTestCopy N'dbo.Run_TieredIntegrityCheck', N'dbo.Run_TieredIntegrityCheck_TestScaled';

    DELETE #Edits;
    INSERT INTO #Edits VALUES
        (1, N'PROCEDURE dbo.Run_LargeTier_WeeklyFullCheck', N'PROCEDURE dbo.Run_LargeTier_WeeklyFullCheck_TestScaled', 1),
        (2, N'DECLARE @MediumMaxGB DECIMAL(18,2) = 500;', N'DECLARE @MediumMaxGB DECIMAL(18,2) = 0.5;', 1),
        (3, N'DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;', N'DECLARE @LargeMaxGB  DECIMAL(18,2) = 0.75;', 1),
        (4, N'AND d.state = 0', N'AND d.state = 0 AND d.name LIKE N''DBCCGovTest[_]%''', 1),
        (5, N'sys.dm_hadr_database_replica_states', N'dbo.DBCCGovTest_ReplicaStates', 1);
    EXEC #MakeTestCopy N'dbo.Run_LargeTier_WeeklyFullCheck', N'dbo.Run_LargeTier_WeeklyFullCheck_TestScaled';

    --------------------------------------------------------------------------
    -- Nightly run
    --------------------------------------------------------------------------
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Run_TieredIntegrityCheck_TestScaled;

    -- Expected strategy per database. MAXDOP mirrors the documented values: box product 4 (Large) / 2 (VLDB),
    -- Managed Instance 2 / 1, omitted on builds that predate @MaxDop support.
    DECLARE @IsMI BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 8 THEN 1 ELSE 0 END;
    DECLARE @Major INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
    DECLARE @Build INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 2) AS INT);
    DECLARE @MaxDopOk BIT = CASE WHEN @IsMI = 1 OR @Major >= 14 OR (@Major = 13 AND @Build >= 5026) THEN 1 ELSE 0 END;

    DECLARE @Expect TABLE (Name SYSNAME PRIMARY KEY, Runs INT NOT NULL, PhysicalOnly BIT NULL, MaxDop INT NULL);
    INSERT INTO @Expect VALUES
        (N'DBCCGovTest_Small', 1, 0, NULL),
        (N'DBCCGovTest_R&D<1>', 1, 0, NULL),
        (N'DBCCGovTest_O''Brien', 1, 0, NULL),
        (N'DBCCGovTest_a,b', 0, NULL, NULL),
        (N'DBCCGovTest_Primary', 1, 0, NULL),
        (N'DBCCGovTest_Secondary', 0, NULL, NULL),
        (N'DBCCGovTest_Edge', 1, 0, NULL),
        (N'DBCCGovTest_Medium', 1, 0, NULL),
        (N'DBCCGovTest_Large', 1, 1, CASE WHEN @MaxDopOk = 0 THEN NULL WHEN @IsMI = 1 THEN 2 ELSE 4 END),
        (N'DBCCGovTest_SecondaryLarge', 1, 1, CASE WHEN @MaxDopOk = 0 THEN NULL WHEN @IsMI = 1 THEN 2 ELSE 4 END),
        (N'DBCCGovTest_VLDB', 1, 1, CASE WHEN @MaxDopOk = 0 THEN NULL WHEN @IsMI = 1 THEN 1 ELSE 2 END);

    INSERT INTO #Results (TestName, Passed, Detail)
    SELECT N'Nightly: ' + e.Name + CASE e.Runs WHEN 0 THEN N' is not checked' ELSE N' checked once, '
               + CASE WHEN e.PhysicalOnly = 1 THEN N'PHYSICAL_ONLY' ELSE N'full CHECKDB' END
               + ISNULL(N', MAXDOP ' + CAST(e.MaxDop AS NVARCHAR(5)), N'') END,
           CASE WHEN c.Runs = e.Runs
                 AND (e.Runs = 0 OR (c.Errors = 0
                      AND c.PhysicalOnly = e.PhysicalOnly
                      AND ISNULL(c.MaxDop, -1) = ISNULL(e.MaxDop, -1))) THEN 1 ELSE 0 END,
           N'runs=' + CAST(c.Runs AS NVARCHAR(10)) + N'; command=' + ISNULL(c.Command, N'(none)')
    FROM @Expect e
    CROSS APPLY (
        SELECT Runs = COUNT(*),
               Errors = SUM(CASE WHEN l.ErrorNumber = 0 AND l.EndTime IS NOT NULL THEN 0 ELSE 1 END),
               PhysicalOnly = MAX(CASE WHEN l.Command LIKE N'%PHYSICAL[_]ONLY%' THEN 1 ELSE 0 END),
               MaxDop = MAX(CASE WHEN l.Command LIKE N'%MAXDOP = 1%' THEN 1 WHEN l.Command LIKE N'%MAXDOP = 2%' THEN 2
                                 WHEN l.Command LIKE N'%MAXDOP = 4%' THEN 4 WHEN l.Command LIKE N'%MAXDOP%' THEN -2 END),
               Command = MAX(l.Command)
        FROM dbo.CommandLog l
        WHERE l.ID > @Start AND l.CommandType = 'DBCC_CHECKDB' AND l.DatabaseName = e.Name
    ) c
    ORDER BY e.Name;

    --------------------------------------------------------------------------
    -- Weekly Large-tier run: only DBCCGovTest_Large (primary), full logical check
    --------------------------------------------------------------------------
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Run_LargeTier_WeeklyFullCheck_TestScaled @TimeLimitSeconds = 3600;

    INSERT INTO #Results (TestName, Passed, Detail)
    SELECT N'Weekly: only DBCCGovTest_Large, full logical CHECKDB' + CASE WHEN @MaxDopOk = 1 THEN N', MAXDOP ' + CASE WHEN @IsMI = 1 THEN N'2' ELSE N'4' END ELSE N'' END,
           CASE WHEN COUNT(*) = 1
                 AND MAX(DatabaseName) = N'DBCCGovTest_Large'
                 AND MAX(CASE WHEN Command LIKE N'%PHYSICAL[_]ONLY%' THEN 1 ELSE 0 END) = 0
                 AND MAX(CASE WHEN ErrorNumber = 0 AND EndTime IS NOT NULL THEN 0 ELSE 1 END) = 0
                 AND (@MaxDopOk = 0 OR MAX(Command) LIKE N'%MAXDOP = ' + CASE WHEN @IsMI = 1 THEN N'2' ELSE N'4' END + N'%')
                THEN 1 ELSE 0 END,
           N'rows=' + CAST(COUNT(*) AS NVARCHAR(10)) + N'; ' + ISNULL(STUFF((SELECT N' | ' + DatabaseName + N': ' + Command FROM dbo.CommandLog
                WHERE ID > @Start AND CommandType = 'DBCC_CHECKDB' ORDER BY ID FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N''), N'')
    FROM dbo.CommandLog
    WHERE ID > @Start AND CommandType = 'DBCC_CHECKDB';
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
    INSERT INTO #Results (TestName, Passed, Detail) VALUES (N'Test setup or run completed without error', 0, @Err);
END CATCH;

------------------------------------------------------------------------------
-- Cleanup (always)
------------------------------------------------------------------------------
IF OBJECT_ID('dbo.Run_TieredIntegrityCheck_TestScaled', 'P') IS NOT NULL DROP PROCEDURE dbo.Run_TieredIntegrityCheck_TestScaled;
IF OBJECT_ID('dbo.Run_LargeTier_WeeklyFullCheck_TestScaled', 'P') IS NOT NULL DROP PROCEDURE dbo.Run_LargeTier_WeeklyFullCheck_TestScaled;
IF OBJECT_ID('dbo.DBCCGovTest_ReplicaStates', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_ReplicaStates;
DECLARE @d SYSNAME;
DECLARE dropper CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE name LIKE N'DBCCGovTest[_]%' AND name <> DB_NAME();
OPEN dropper; FETCH NEXT FROM dropper INTO @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC #DropLabDb @d; FETCH NEXT FROM dropper INTO @d; END
CLOSE dropper; DEALLOCATE dropper;
DELETE FROM dbo.CommandLog WHERE DatabaseName LIKE N'DBCCGovTest[_]%' AND DatabaseName <> DB_NAME();

------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------
SELECT TestNumber, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, TestName, Detail FROM #Results ORDER BY TestNumber;
DECLARE @Total INT = (SELECT COUNT(*) FROM #Results), @Failed INT = (SELECT COUNT(*) FROM #Results WHERE Passed = 0);
PRINT '01_Tiering_Routing: ' + CAST(@Total AS VARCHAR(10)) + ' test(s) run, ' + CAST(@Total - @Failed AS VARCHAR(10)) + ' passed, ' + CAST(@Failed AS VARCHAR(10)) + ' failed.';
IF @Failed > 0 OR @Total = 0
    RAISERROR('01_Tiering_Routing: %d of %d test(s) FAILED - see the result set.', 16, 1, @Failed, @Total);
GO
