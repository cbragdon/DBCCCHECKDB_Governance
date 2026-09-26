/*
================================================================================
 Tests_CoreLogic.sql

 Purpose:
   Lightweight, framework-free regression tests for the pure decision logic
   embedded in this project's procedures - the boundary/threshold math that
   determines tiering, materiality, and schedule-overlap outcomes. These are
   the pieces most likely to silently break during a future edit (e.g.
   someone "simplifies" a CASE expression and flips a > to a >=).

   This deliberately does NOT attempt to test the procedures end-to-end
   against live system DMVs (sys.master_files, sys.dm_os_volume_stats,
   msdb.dbo.sysjobhistory, etc.) - faking those realistically requires a
   framework like tSQLt with FakeTable, which is a heavier dependency than
   this project currently needs. Instead, each test below reproduces the
   EXACT expression copied from the real script (cited in a comment) and
   asserts it against known inputs / documented boundaries. If a future edit
   changes one of those expressions without updating the matching test here,
   that's a signal the change needs a second look.

   Covers:
     1. Run_TieredIntegrityCheck.sql   - Small/Medium/Large/VLDB size tiering boundaries
     2. Precheck_RequiredSpaceForSetup.sql - IsShortfallMaterial threshold logic
     3. Check_JobScheduleOverlap.sql   - active-day-mask sharing + interval overlap math

 Usage:
   Run against ANY database (does not require the other procedures to be
   deployed, and touches no system tables) - box product or Managed Instance:

     sqlcmd -S <server> -d <database> -E -C -i Tests_CoreLogic.sql -f 65001
     sqlcmd -S <server> -d <database> -G -C -i Tests_CoreLogic.sql -f 65001

   Prints one row per test (PASS/FAIL) plus a summary. Raises an error
   (severity 16) if any test failed, so this can be wired into a CI/build
   step that checks the script's exit behavior.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestNumber   INT IDENTITY(1,1),
    TestName     VARCHAR(200),
    Expected     VARCHAR(100),
    Actual       VARCHAR(100),
    Passed       AS (CASE WHEN Expected = Actual THEN 1 ELSE 0 END)
);

------------------------------------------------------------------------------
-- 1. Tier boundary logic (Run_TieredIntegrityCheck.sql SizeCTE WHERE clauses)
--    Small:  SizeGB < 50
--    Medium: SizeGB >= 50  AND SizeGB < 500
--    Large:  SizeGB >= 500 AND SizeGB < 2048
--    VLDB:   SizeGB >= 2048
------------------------------------------------------------------------------
DECLARE @SmallMaxGB  DECIMAL(18,2) = 50;
DECLARE @MediumMaxGB DECIMAL(18,2) = 500;
DECLARE @LargeMaxGB  DECIMAL(18,2) = 2048;

;WITH TierCases AS (
    SELECT * FROM (VALUES
        (0.01,    'Small'),   -- effectively-empty database
        (49.99,   'Small'),   -- just under Small boundary
        (50.00,   'Medium'),  -- exactly on Small/Medium boundary -> Medium (>=)
        (499.99,  'Medium'),  -- just under Medium boundary
        (500.00,  'Large'),   -- exactly on Medium/Large boundary -> Large (>=)
        (2047.99, 'Large'),   -- just under Large boundary
        (2048.00, 'VLDB'),    -- exactly on Large/VLDB boundary -> VLDB (>=)
        (5000.00, 'VLDB')     -- deep into VLDB range
    ) AS v(SizeGB, ExpectedTier)
)
INSERT INTO #TestResults (TestName, Expected, Actual)
SELECT
    'Tier boundary: ' + CAST(SizeGB AS VARCHAR(20)) + ' GB',
    ExpectedTier,
    CASE
        WHEN SizeGB < @SmallMaxGB THEN 'Small'
        WHEN SizeGB >= @SmallMaxGB  AND SizeGB < @MediumMaxGB THEN 'Medium'
        WHEN SizeGB >= @MediumMaxGB AND SizeGB < @LargeMaxGB  THEN 'Large'
        WHEN SizeGB >= @LargeMaxGB THEN 'VLDB'
    END
FROM TierCases;

------------------------------------------------------------------------------
-- 2. Materiality threshold logic (Precheck_RequiredSpaceForSetup.sql):
--      IsShortfallMaterial = 1 WHEN ShortfallGB > @MinMaterialShortfallGB
--                             AND ShortfallGB > (RequiredGB * @MinMaterialShortfallPct / 100.0)
--    Defaults: @MinMaterialShortfallGB = 2.0, @MinMaterialShortfallPct = 10.0
------------------------------------------------------------------------------
DECLARE @MinMaterialShortfallGB  DECIMAL(18,2) = 2.0;
DECLARE @MinMaterialShortfallPct DECIMAL(5,2)  = 10.0;

;WITH MaterialityCases AS (
    -- ShortfallGB, RequiredGB, ExpectedMaterial (1/0), Label
    SELECT * FROM (VALUES
        (1.00,   100.00, 0, 'below absolute floor (2 GB)'),
        (2.00,   100.00, 0, 'exactly at absolute floor -> not material (needs strictly >)'),
        (2.01,   100.00, 0, 'above floor but below 10% of required (100GB*10%=10GB)'),
        (9.99,   100.00, 0, 'just under both thresholds combined'),
        (10.00,  100.00, 0, 'exactly at 10% -> not material (needs strictly >)'),
        (10.01,  100.00, 1, 'above both floor and 10% -> material'),
        (3.00,   10.00,  1, 'small required size: floor (2GB) and 10% (1GB) both cleared'),
        (2.50,   100.00, 0, 'clears floor (2GB) but not 10% of required (10GB)'),
        (50.00,  10000.00, 0, 'large required size: 10% (1000GB) not cleared despite large absolute shortfall')
    ) AS v(ShortfallGB, RequiredGB, ExpectedMaterial, Label)
)
INSERT INTO #TestResults (TestName, Expected, Actual)
SELECT
    'Materiality: ' + Label + ' (Shortfall=' + CAST(ShortfallGB AS VARCHAR(20)) + ', Required=' + CAST(RequiredGB AS VARCHAR(20)) + ')',
    CAST(ExpectedMaterial AS VARCHAR(10)),
    CAST(CASE
        WHEN ShortfallGB > @MinMaterialShortfallGB
             AND ShortfallGB > (RequiredGB * @MinMaterialShortfallPct / 100.0)
            THEN 1 ELSE 0 END AS VARCHAR(10))
FROM MaterialityCases;

------------------------------------------------------------------------------
-- 3. Job schedule overlap math (Check_JobScheduleOverlap.sql):
--    a) Day-mask sharing:  (MaskA & MaskB) <> 0
--    b) Interval overlap:  StartA < StartB + DurB  AND  StartB < StartA + DurA
--    Times below are seconds-since-midnight (01:00 = 3600, 08:00 = 28800).
------------------------------------------------------------------------------
;WITH OverlapCases AS (
    -- MaskA, MaskB, StartA, DurA, StartB, DurB, ExpectedSharesDay, ExpectedOverlap, Label
    SELECT * FROM (VALUES
        -- Nightly (daily, mask=127) vs Weekly Large-Tier (Wed, mask=8): both 01:00,
        -- nightly observed 5.5h -> overlaps into Large-Tier's 01:00 start.
        (127, 8,   3600, 19800, 3600, 1800, 1, 1, 'Nightly(5.5h@01:00) vs Wed-Large(0.5h@01:00) - real validated scenario'),
        -- Same pair, but VLDB rescheduled to 08:00 (28800s) - nightly's 5.5h window
        -- ends at 07:30, well before 08:00 -> no overlap.
        (127, 1,   3600, 19800, 28800, 10800, 1, 0, 'Nightly(5.5h@01:00) vs Sun-VLDB(3h@08:00) - real validated scenario'),
        -- Weekly Large-Tier (Wed, mask=8) vs Weekly VLDB (Sun, mask=1): no shared
        -- active day at all -> pair excluded from overlap math entirely.
        (8, 1,     3600, 1800, 3600, 10800, 0, NULL, 'Wed-Large vs Sun-VLDB - no shared active day'),
        -- Two jobs sharing a day, back-to-back with zero gap (B starts exactly
        -- when A's observed window ends) - boundary case, intervals just touch,
        -- not overlap (classic half-open interval convention).
        (127, 127, 3600, 3600, 7200, 3600, 1, 0, 'Back-to-back, zero gap (touching, not overlapping)'),
        -- Two jobs sharing a day, B starts 1 second before A's window ends.
        (127, 127, 3600, 3600, 7199, 3600, 1, 1, 'Back-to-back minus 1 second (true overlap)')
    ) AS v(MaskA, MaskB, StartA, DurA, StartB, DurB, ExpectedSharesDay, ExpectedOverlap, Label)
),
Computed AS (
    SELECT *,
        SharesDay = CASE WHEN (MaskA & MaskB) <> 0 THEN 1 ELSE 0 END,
        Overlaps  = CASE WHEN StartA < StartB + DurB AND StartB < StartA + DurA THEN 1 ELSE 0 END
    FROM OverlapCases
)
INSERT INTO #TestResults (TestName, Expected, Actual)
SELECT 'Overlap - shares active day: ' + Label,
       CAST(ExpectedSharesDay AS VARCHAR(10)),
       CAST(SharesDay AS VARCHAR(10))
FROM Computed
UNION ALL
SELECT 'Overlap - interval overlap: ' + Label,
       ISNULL(CAST(ExpectedOverlap AS VARCHAR(30)), 'N/A (no shared day)'),
       CASE WHEN SharesDay = 0 THEN 'N/A (no shared day)' ELSE CAST(Overlaps AS VARCHAR(30)) END
FROM Computed;

------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------
SELECT TestNumber, TestName, Expected, Actual,
       CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM #TestResults
ORDER BY TestNumber;

DECLARE @Total INT = (SELECT COUNT(*) FROM #TestResults);
DECLARE @Failed INT = (SELECT COUNT(*) FROM #TestResults WHERE Passed = 0);

PRINT '';
PRINT CAST(@Total AS VARCHAR(10)) + ' test(s) run, ' + CAST(@Total - @Failed AS VARCHAR(10)) + ' passed, ' + CAST(@Failed AS VARCHAR(10)) + ' failed.';

IF @Failed > 0
    RAISERROR('Tests_CoreLogic.sql: %d of %d test(s) FAILED - see result set above.', 16, 1, @Failed, @Total);
ELSE
    PRINT 'All tests passed.';

DROP TABLE #TestResults;
GO
