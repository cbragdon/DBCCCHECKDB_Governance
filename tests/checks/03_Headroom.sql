/*
================================================================================
 tests/checks/03_Headroom.sql

 Self-checking test of the INSTALLED dbo.Check_DiskAndTempdbHeadroom, run
 unmodified. Run it in the maintenance database that holds the toolkit
 (sqlcmd -b -I -i ..., or an SSMS query window). Prints PASS/FAIL per
 assertion, then "N test(s) run, N passed, 0 failed", and raises severity 16
 if anything failed.

 Covers:
   - the tempdb free-space percentage it reports equals
     100 * unallocated / total pages of tempdb's data files (measured
     independently at the same moment), at two different fill levels;
   - no tempdb warning when the threshold is 0;
   - a bracket-quoted target name containing & < > is resolved (its
     data-volume warning names the database).

 Side effects: a temporary table in tempdb for the second fill level (dropped
 at the end), one small DBCCGovTest_* database (dropped), and this test's
 dbo.CommandLog rows for that database (deleted). The HEADROOM_CHECK rows it
 writes for tempdb are left in dbo.CommandLog. Box product only.
================================================================================
*/
SET NOCOUNT ON;
GO
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNumber INT IDENTITY(1,1), TestName NVARCHAR(200) NOT NULL, Passed BIT NOT NULL, Detail NVARCHAR(MAX) NULL);
IF OBJECT_ID('tempdb..#Fill') IS NOT NULL DROP TABLE #Fill;

DECLARE @Start INT, @Err NVARCHAR(4000), @Msg NVARCHAR(MAX), @Reported DECIMAL(9,2), @Before DECIMAL(9,2), @After DECIMAL(9,2),
        @Level INT = 1, @Rows INT, @Sql NVARCHAR(MAX), @FirstOracle DECIMAL(9,2);

BEGIN TRY
    IF OBJECT_ID('dbo.Check_DiskAndTempdbHeadroom', 'P') IS NULL OR OBJECT_ID('dbo.CommandLog', 'U') IS NULL
        THROW 50120, 'Run this in the maintenance database that holds the toolkit (Check_DiskAndTempdbHeadroom, CommandLog).', 1;

    CREATE TABLE #Fill (pad CHAR(8000) NOT NULL);

    WHILE @Level <= 2
    BEGIN
        IF @Level = 2
        BEGIN
            -- Use about half of tempdb's currently free data pages (at most 100,000 pages = 781 MB).
            SELECT @Rows = SUM(unallocated_extent_page_count) / 2 FROM tempdb.sys.dm_db_file_space_usage;
            IF @Rows > 100000 SET @Rows = 100000;
            INSERT INTO #Fill (pad) SELECT TOP (@Rows) 'x' FROM sys.all_columns a CROSS JOIN sys.all_columns b;
        END

        SELECT @Before = 100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) FROM tempdb.sys.dm_db_file_space_usage;
        SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
        EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = N'', @MinTempdbFreePct = 100, @MinVolumeFreePct = 0;
        SELECT @After = 100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) FROM tempdb.sys.dm_db_file_space_usage;

        SELECT TOP (1) @Msg = ErrorMessage FROM dbo.CommandLog
        WHERE ID > @Start AND CommandType = 'HEADROOM_CHECK' AND DatabaseName = N'tempdb' AND ErrorMessage LIKE N'%logical free space%'
        ORDER BY ID;
        SET @Reported = TRY_CONVERT(DECIMAL(9,2), SUBSTRING(@Msg, CHARINDEX(N'logical free space ', @Msg) + 19,
                        CHARINDEX(N'%', @Msg, CHARINDEX(N'logical free space ', @Msg)) - CHARINDEX(N'logical free space ', @Msg) - 19));
        IF @Level = 1 SET @FirstOracle = @Before;

        INSERT INTO #Results (TestName, Passed, Detail)
        VALUES (N'Tempdb free % reported = unallocated / total data pages (fill level ' + CAST(@Level AS NVARCHAR(2)) + N', within 2 points)',
                CASE WHEN @Reported IS NOT NULL
                      AND @Reported BETWEEN (CASE WHEN @Before < @After THEN @Before ELSE @After END) - 2
                                        AND (CASE WHEN @Before > @After THEN @Before ELSE @After END) + 2 THEN 1 ELSE 0 END,
                N'reported=' + ISNULL(CAST(@Reported AS NVARCHAR(20)), N'(no warning row)') + N'% measured=' + CAST(@Before AS NVARCHAR(20))
                + N'..' + CAST(@After AS NVARCHAR(20)) + N'%');
        SET @Level += 1;
    END
    INSERT INTO #Results (TestName, Passed, Detail)
    -- Filling half the free pages should roughly halve the free percentage; require at least a quarter.
    VALUES (N'The two fill levels differ (so the comparison above is meaningful)', CASE WHEN @FirstOracle > 0 AND ABS(@FirstOracle - @Before) >= @FirstOracle / 4 THEN 1 ELSE 0 END,
            N'level 1=' + CAST(@FirstOracle AS NVARCHAR(20)) + N'% level 2=' + CAST(@Before AS NVARCHAR(20)) + N'%');
    DROP TABLE #Fill;

    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = N'', @MinTempdbFreePct = 0, @MinVolumeFreePct = 0;
    SELECT @Rows = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'HEADROOM_CHECK' AND ErrorMessage LIKE N'%logical free space%';
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'No tempdb warning when @MinTempdbFreePct = 0', CASE WHEN @Rows = 0 THEN 1 ELSE 0 END, N'warning rows=' + CAST(@Rows AS NVARCHAR(10)));

    -- Bracket-quoted target with a comma in its name, in a list: the data-volume check must find its files.
    IF DB_ID(N'DBCCGovTest_a,b') IS NOT NULL
        EXEC (N'ALTER DATABASE [DBCCGovTest_a,b] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [DBCCGovTest_a,b];');
    EXEC (N'CREATE DATABASE [DBCCGovTest_a,b];');
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = N'[DBCCGovTest_a,b], NoSuchDatabase', @MinTempdbFreePct = 0, @MinVolumeFreePct = 100;
    SELECT @Rows = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'HEADROOM_CHECK' AND DatabaseName = N'DBCCGovTest_a,b';
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Bracket-quoted target with a comma, [DBCCGovTest_a,b], resolved from a list', CASE WHEN @Rows = 1 THEN 1 ELSE 0 END,
            N'data-volume warning rows naming it=' + CAST(@Rows AS NVARCHAR(10)));
    EXEC (N'ALTER DATABASE [DBCCGovTest_a,b] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [DBCCGovTest_a,b];');

    -- Bracket-quoted target with & < > in its name: the data-volume check must find its files.
    IF DB_ID(N'DBCCGovTest_R&D<1>') IS NOT NULL
        EXEC (N'ALTER DATABASE [DBCCGovTest_R&D<1>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [DBCCGovTest_R&D<1>];');
    EXEC (N'CREATE DATABASE [DBCCGovTest_R&D<1>];');
    SELECT @Start = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;
    EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases = N' [DBCCGovTest_R&D<1>] ', @MinTempdbFreePct = 0, @MinVolumeFreePct = 100;
    SELECT @Rows = COUNT(*) FROM dbo.CommandLog WHERE ID > @Start AND CommandType = 'HEADROOM_CHECK' AND DatabaseName = N'DBCCGovTest_R&D<1>';
    INSERT INTO #Results (TestName, Passed, Detail)
    VALUES (N'Bracket-quoted target [DBCCGovTest_R&D<1>] resolved by the data-volume check', CASE WHEN @Rows = 1 THEN 1 ELSE 0 END,
            N'data-volume warning rows naming it=' + CAST(@Rows AS NVARCHAR(10)));
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
    INSERT INTO #Results (TestName, Passed, Detail) VALUES (N'Test setup or run completed without error', 0, @Err);
END CATCH;

-- Cleanup (always)
IF OBJECT_ID('tempdb..#Fill') IS NOT NULL DROP TABLE #Fill;
IF DB_ID(N'DBCCGovTest_R&D<1>') IS NOT NULL
    EXEC (N'ALTER DATABASE [DBCCGovTest_R&D<1>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [DBCCGovTest_R&D<1>];');
DELETE FROM dbo.CommandLog WHERE DatabaseName LIKE N'DBCCGovTest[_]%' AND DatabaseName <> DB_NAME();

SELECT TestNumber, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, TestName, Detail FROM #Results ORDER BY TestNumber;
DECLARE @Total INT = (SELECT COUNT(*) FROM #Results), @Failed INT = (SELECT COUNT(*) FROM #Results WHERE Passed = 0);
PRINT '03_Headroom: ' + CAST(@Total AS VARCHAR(10)) + ' test(s) run, ' + CAST(@Total - @Failed AS VARCHAR(10)) + ' passed, ' + CAST(@Failed AS VARCHAR(10)) + ' failed.';
IF @Failed > 0 OR @Total = 0
    RAISERROR('03_Headroom: %d of %d test(s) FAILED - see the result set.', 16, 1, @Failed, @Total);
GO
