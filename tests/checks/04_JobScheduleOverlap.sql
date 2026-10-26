/*
================================================================================
 tests/checks/04_JobScheduleOverlap.sql

 Self-checking test of the INSTALLED dbo.Check_JobScheduleOverlap. Run it in
 the maintenance database that holds the toolkit (sqlcmd -b -I -i ..., or an
 SSMS query window). Prints PASS/FAIL per scenario, then "N test(s) run,
 N passed, 0 failed", and raises severity 16 if anything failed.

 How it tests the real code without touching msdb:
   It reads the procedure's definition (OBJECT_DEFINITION) and creates a test
   copy in which every "msdb.dbo." reference (the expected number of them,
   or the test fails) points at test tables dbo.DBCCGovTest_sysjobs,
   _sysjobsteps, _sysjobhistory, _sysjobschedules and _sysschedules. Each
   scenario fills those tables with jobs, schedules and one history row, runs
   the copy, and compares its verdict with the correct answer.

 Side effects (all removed at the end): the test copy and the five test
 tables. Nothing is written to msdb.
================================================================================
*/
SET NOCOUNT ON;
GO
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
-- Replaces the test job tables' contents with the jobs in #Jobs (one schedule and at most one history row each).
CREATE OR ALTER PROCEDURE #SetJobs
AS
BEGIN
    DELETE dbo.DBCCGovTest_sysjobs; DELETE dbo.DBCCGovTest_sysjobsteps; DELETE dbo.DBCCGovTest_sysjobhistory;
    DELETE dbo.DBCCGovTest_sysjobschedules; DELETE dbo.DBCCGovTest_sysschedules;
    INSERT dbo.DBCCGovTest_sysjobs (job_id, name) SELECT JobId, Name FROM #Jobs;
    INSERT dbo.DBCCGovTest_sysjobsteps (job_id, step_id, command) SELECT JobId, 1, N'EXEC dbo.' + ProcName + N';' FROM #Jobs;
    INSERT dbo.DBCCGovTest_sysschedules (schedule_id, name, enabled, freq_type, freq_interval, active_start_time)
        SELECT Id, N'schedule ' + Name, 1, FreqType, Mask, StartHHMMSS FROM #Jobs;
    INSERT dbo.DBCCGovTest_sysjobschedules (job_id, schedule_id) SELECT JobId, Id FROM #Jobs;
    INSERT dbo.DBCCGovTest_sysjobhistory (job_id, step_id, run_date, run_time, run_duration)
        SELECT JobId, 0, 20261020, StartHHMMSS, DurHHMMSS FROM #Jobs WHERE DurHHMMSS IS NOT NULL;
END
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNumber INT IDENTITY(1,1), TestName NVARCHAR(200) NOT NULL, Passed BIT NOT NULL, Detail NVARCHAR(MAX) NULL);
DECLARE @Err NVARCHAR(4000);

BEGIN TRY
    IF OBJECT_ID('dbo.Check_JobScheduleOverlap', 'P') IS NULL
        THROW 50130, 'Run this in the maintenance database that holds the toolkit (Check_JobScheduleOverlap).', 1;

    IF OBJECT_ID('dbo.DBCCGovTest_sysjobs', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobs;
    IF OBJECT_ID('dbo.DBCCGovTest_sysjobsteps', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobsteps;
    IF OBJECT_ID('dbo.DBCCGovTest_sysjobhistory', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobhistory;
    IF OBJECT_ID('dbo.DBCCGovTest_sysjobschedules', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobschedules;
    IF OBJECT_ID('dbo.DBCCGovTest_sysschedules', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysschedules;
    CREATE TABLE dbo.DBCCGovTest_sysjobs (job_id UNIQUEIDENTIFIER PRIMARY KEY, name SYSNAME NOT NULL);
    CREATE TABLE dbo.DBCCGovTest_sysjobsteps (job_id UNIQUEIDENTIFIER NOT NULL, step_id INT NOT NULL, command NVARCHAR(MAX) NOT NULL);
    CREATE TABLE dbo.DBCCGovTest_sysjobhistory (job_id UNIQUEIDENTIFIER NOT NULL, step_id INT NOT NULL, run_date INT NOT NULL, run_time INT NOT NULL, run_duration INT NOT NULL);
    CREATE TABLE dbo.DBCCGovTest_sysjobschedules (job_id UNIQUEIDENTIFIER NOT NULL, schedule_id INT NOT NULL);
    CREATE TABLE dbo.DBCCGovTest_sysschedules (schedule_id INT PRIMARY KEY, name SYSNAME NOT NULL, enabled INT NOT NULL, freq_type INT NOT NULL, freq_interval INT NOT NULL, active_start_time INT NOT NULL);

    CREATE TABLE #Edits (Ordinal INT PRIMARY KEY, OldText NVARCHAR(4000) NOT NULL, NewText NVARCHAR(4000) NOT NULL, ExpectedCount INT NOT NULL);
    INSERT INTO #Edits VALUES
        (1, N'PROCEDURE dbo.Check_JobScheduleOverlap', N'PROCEDURE dbo.Check_JobScheduleOverlap_Test', 1),
        (2, N'msdb.dbo.', N'dbo.DBCCGovTest_', 7);   -- 5 table references + 2 in the header comment
    EXEC #MakeTestCopy N'dbo.Check_JobScheduleOverlap', N'dbo.Check_JobScheduleOverlap_Test';

    -- Scenarios: jobs (freq_type 4 = daily, 8 = weekly with day mask Sun=1 ... Sat=64; times HHMMSS) and the
    -- correct verdict for the pair: OVERLAP, OK, UNKNOWN, or NOPAIR (no row: no shared day and no overlap).
    CREATE TABLE #Scenarios (Id INT PRIMARY KEY, Label NVARCHAR(200) NOT NULL, Expected VARCHAR(10) NOT NULL,
        TypeA INT, MaskA INT, StartA INT, DurA INT NULL, TypeB INT, MaskB INT, StartB INT, DurB INT NULL);
    INSERT INTO #Scenarios VALUES
        (1, N'Nightly 01:00 for 5.5h vs Wednesday 01:00 for 0.5h',                    'OVERLAP', 4, 1, 10000, 53000, 8, 8, 10000, 3000),
        (2, N'Nightly 01:00 for 5.5h vs Sunday 08:00 for 3h',                         'OK',      4, 1, 10000, 53000, 8, 1, 80000, 30000),
        (3, N'Wednesday 01:00 vs Sunday 01:00 (no shared day)',                        'NOPAIR',  8, 8, 10000, 3000,  8, 1, 10000, 30000),
        (4, N'Back-to-back, touching (01:00 for 1h, then 02:00)',                      'OK',      4, 1, 10000, 10000, 4, 1, 20000, 10000),
        (5, N'Back-to-back minus one second (second job at 01:59:59)',                'OVERLAP', 4, 1, 10000, 10000, 4, 1, 15959, 10000),
        (6, N'One job has no run history yet',                                         'UNKNOWN', 4, 1, 10000, NULL,  8, 8, 10000, 3000),
        (7, N'Cross-midnight: nightly 23:00 for 4h vs Wednesday 01:00 for 0.5h',       'OVERLAP', 4, 1, 230000, 40000, 8, 8, 10000, 3000),
        (8, N'Week wrap: Saturday 23:00 for 4h vs Sunday 01:00 for 0.5h',              'OVERLAP', 8, 64, 230000, 40000, 8, 1, 10000, 3000),
        (9, N'Tuesday 23:00 for 1h vs Wednesday 00:00 (touching at midnight)',         'NOPAIR',  8, 4, 230000, 10000, 8, 8, 0, 3000);

    CREATE TABLE #Jobs (Id INT PRIMARY KEY, JobId UNIQUEIDENTIFIER NOT NULL, Name SYSNAME NOT NULL, ProcName SYSNAME NOT NULL,
        FreqType INT NOT NULL, Mask INT NOT NULL, StartHHMMSS INT NOT NULL, DurHHMMSS INT NULL);
    CREATE TABLE #Out (JobA SYSNAME NULL, RoleA VARCHAR(40) NULL, ScheduleA SYSNAME NULL, StartTimeA VARCHAR(10) NULL, ObservedMaxDurationA_Hrs DECIMAL(6,2) NULL,
        RunsConsideredA INT NULL, JobB SYSNAME NULL, RoleB VARCHAR(40) NULL, ScheduleB SYSNAME NULL, StartTimeB VARCHAR(10) NULL,
        ObservedMaxDurationB_Hrs DECIMAL(6,2) NULL, RunsConsideredB INT NULL, CrossesMidnight INT NULL, OverlapAssessment NVARCHAR(MAX) NULL);

    DECLARE @Id INT = 0, @Label NVARCHAR(200), @Expected VARCHAR(10), @Got VARCHAR(10), @Rows INT, @Text NVARCHAR(MAX);
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @Id = Id, @Label = Label, @Expected = Expected FROM #Scenarios WHERE Id > @Id ORDER BY Id;
        IF @@ROWCOUNT = 0 BREAK;
        DELETE #Jobs; DELETE #Out;
        INSERT INTO #Jobs
            SELECT 1, NEWID(), N'Job A', N'Run_TieredIntegrityCheck', TypeA, MaskA, StartA, DurA FROM #Scenarios WHERE Id = @Id
            UNION ALL
            SELECT 2, NEWID(), N'Job B', N'Run_LargeTier_WeeklyFullCheck', TypeB, MaskB, StartB, DurB FROM #Scenarios WHERE Id = @Id;
        EXEC #SetJobs;
        INSERT INTO #Out EXEC dbo.Check_JobScheduleOverlap_Test;
        SELECT @Rows = COUNT(*), @Text = MAX(OverlapAssessment) FROM #Out;
        SET @Got = CASE WHEN @Rows = 0 THEN 'NOPAIR' WHEN @Rows > 1 THEN 'MANY'
                        WHEN @Text LIKE 'OVERLAP%' THEN 'OVERLAP' WHEN @Text LIKE 'OK%' THEN 'OK' WHEN @Text LIKE 'UNKNOWN%' THEN 'UNKNOWN' ELSE '?' END;
        INSERT INTO #Results (TestName, Passed, Detail)
        VALUES (@Label + N' -> ' + @Expected, CASE WHEN @Got = @Expected THEN 1 ELSE 0 END, N'procedure says ' + @Got);
    END
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
    INSERT INTO #Results (TestName, Passed, Detail) VALUES (N'Test setup or run completed without error', 0, @Err);
END CATCH;

-- Cleanup (always)
IF OBJECT_ID('dbo.Check_JobScheduleOverlap_Test', 'P') IS NOT NULL DROP PROCEDURE dbo.Check_JobScheduleOverlap_Test;
IF OBJECT_ID('dbo.DBCCGovTest_sysjobs', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobs;
IF OBJECT_ID('dbo.DBCCGovTest_sysjobsteps', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobsteps;
IF OBJECT_ID('dbo.DBCCGovTest_sysjobhistory', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobhistory;
IF OBJECT_ID('dbo.DBCCGovTest_sysjobschedules', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysjobschedules;
IF OBJECT_ID('dbo.DBCCGovTest_sysschedules', 'U') IS NOT NULL DROP TABLE dbo.DBCCGovTest_sysschedules;

SELECT TestNumber, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, TestName, Detail FROM #Results ORDER BY TestNumber;
DECLARE @Total INT = (SELECT COUNT(*) FROM #Results), @Failed INT = (SELECT COUNT(*) FROM #Results WHERE Passed = 0);
PRINT '04_JobScheduleOverlap: ' + CAST(@Total AS VARCHAR(10)) + ' test(s) run, ' + CAST(@Total - @Failed AS VARCHAR(10)) + ' passed, ' + CAST(@Failed AS VARCHAR(10)) + ' failed.';
IF @Failed > 0 OR @Total = 0
    RAISERROR('04_JobScheduleOverlap: %d of %d test(s) FAILED - see the result set.', 16, 1, @Failed, @Total);
GO
