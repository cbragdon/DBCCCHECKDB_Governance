/*
================================================================================
 Check_JobScheduleOverlap.sql

 Purpose:
   Every sizing estimate in Precheck_RequiredSpaceForSetup.sql and every
   pre-flight check in Check_DiskAndTempdbHeadroom.sql assumes the three
   governance jobs (nightly tiered check, weekly VLDB rotation, weekly
   Large-tier full check) run SEQUENTIALLY - so headroom only needs to
   cover the single worst-case concurrent check, not the sum of all of
   them. Deploy_SQLAgentJobs.sql's DEFAULT schedule does NOT actually
   guarantee this: the nightly job runs at 01:00 every day (including
   Sundays and Wednesdays), while the two weekly jobs ALSO start at 01:00
   on their respective days - if the nightly job is still running a
   Large/VLDB-tier PHYSICAL_ONLY check when the weekly job kicks off, both
   now compete for disk/tempdb headroom at the same time, silently
   invalidating the sequential-execution assumption baked into the sizing
   report.

   This script identifies the governance jobs (by job-step command text,
   so it still works if you renamed them), pulls each one's schedule(s)
   and OBSERVED historical run duration (from msdb.dbo.sysjobhistory - the
   only reliable source, since planned duration depends entirely on your
   actual data/workload and can't be predicted from schedule metadata
   alone), and flags any pair whose scheduled start times could genuinely
   overlap in wall-clock time.

 IMPORTANT - requires job run history to be useful:
   A job that has never completed a run has no OBSERVED duration to
   compare against - those pairs are reported as `UNKNOWN (no run history
   yet)` rather than guessed at, since guessing wrong in either direction
   is worse than admitting we don't know yet. Re-run this after the jobs
   have executed at least once (ideally several times, across their
   heaviest workload) for a meaningful result. Requires membership in
   SQLAgentUser/SQLAgentReader/SQLAgentOperator msdb roles (or sysadmin)
   to read msdb.dbo.sysjobs / sysjobhistory / sysschedules.

 Platform handling:
   Works unchanged on both box product and Managed Instance - MI supports
   SQL Agent jobs natively and msdb is queried identically on both.

 Limitation - midnight-crossing runs:
   The overlap math treats each job's scheduled day as a single 24-hour
   window starting at its active_start_time; if a job's observed duration
   would carry it past midnight into the next calendar day, this is
   flagged separately (`CrossesMidnight = 1`) rather than silently
   mis-computed, since which day's schedule to compare against becomes
   ambiguous.

 Usage:
   EXEC dbo.Check_JobScheduleOverlap;                      -- last 20 runs per job (default)
   EXEC dbo.Check_JobScheduleOverlap @HistoryRunsToConsider = 50;

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.Check_JobScheduleOverlap
    @HistoryRunsToConsider INT = 20   -- how many recent completed runs to use for the "observed worst-case duration" per job
AS
BEGIN
    SET NOCOUNT ON;

    ------------------------------------------------------------------
    -- Identify the governance jobs by job-step command text (robust to
    -- renaming), and pull each job's OBSERVED worst-case duration from
    -- history (MAX run_duration across the last @HistoryRunsToConsider
    -- completed runs, step_id = 0 = whole-job outcome row).
    ------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#GovJobs') IS NOT NULL DROP TABLE #GovJobs;
    CREATE TABLE #GovJobs (
        job_id            UNIQUEIDENTIFIER,
        JobName           SYSNAME,
        RoleLabel         VARCHAR(40),
        ObservedMaxDurationSec INT NULL,
        RunsConsidered    INT
    );

    INSERT INTO #GovJobs (job_id, JobName, RoleLabel)
    SELECT DISTINCT
        j.job_id,
        j.name,
        CASE
            WHEN js.command LIKE '%Run_TieredIntegrityCheck%'        THEN 'Nightly Tiered Check'
            WHEN js.command LIKE '%Rotate_VLDB_ObjectLevelChecks%'   THEN 'Weekly VLDB Rotation'
            WHEN js.command LIKE '%Run_LargeTier_WeeklyFullCheck%'   THEN 'Weekly Large-Tier Full Check'
        END
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
    WHERE js.command LIKE '%Run_TieredIntegrityCheck%'
       OR js.command LIKE '%Rotate_VLDB_ObjectLevelChecks%'
       OR js.command LIKE '%Run_LargeTier_WeeklyFullCheck%';

    -- Observed duration: MAX(run_duration) across the most recent N
    -- completed runs (any outcome - a failed run still consumed real
    -- wall-clock time and disk/tempdb pressure while it ran).
    ;WITH RankedHistory AS (
        SELECT
            g.job_id,
            h.run_duration,
            ROW_NUMBER() OVER (PARTITION BY g.job_id ORDER BY h.run_date DESC, h.run_time DESC) AS rn
        FROM #GovJobs g
        JOIN msdb.dbo.sysjobhistory h ON h.job_id = g.job_id AND h.step_id = 0
    )
    UPDATE g
    SET
        ObservedMaxDurationSec = dur.MaxDurationSec,
        RunsConsidered = dur.RunsConsidered
    FROM #GovJobs g
    CROSS APPLY (
        SELECT
            MaxDurationSec = MAX((run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + (run_duration % 100)),
            RunsConsidered = COUNT(*)
        FROM RankedHistory rh
        WHERE rh.job_id = g.job_id AND rh.rn <= @HistoryRunsToConsider
    ) dur;

    ------------------------------------------------------------------
    -- Pull each job's schedule(s): active-days bitmask (Sun=1 ... Sat=64,
    -- matching msdb's own freq_interval convention for weekly schedules;
    -- daily schedules are treated as "every day" = 127) and start time
    -- converted to seconds-since-midnight.
    ------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#GovSchedules') IS NOT NULL DROP TABLE #GovSchedules;
    CREATE TABLE #GovSchedules (
        job_id           UNIQUEIDENTIFIER,
        JobName           SYSNAME,
        RoleLabel         VARCHAR(40),
        ScheduleName      SYSNAME,
        ActiveDaysMask    INT,
        StartTimeSec      INT,
        ObservedMaxDurationSec INT NULL,
        RunsConsidered    INT
    );

    INSERT INTO #GovSchedules (job_id, JobName, RoleLabel, ScheduleName, ActiveDaysMask, StartTimeSec, ObservedMaxDurationSec, RunsConsidered)
    SELECT
        g.job_id,
        g.JobName,
        g.RoleLabel,
        s.name,
        ActiveDaysMask = CASE
            WHEN s.freq_type = 8  THEN s.freq_interval          -- weekly: bitmask already Sun=1..Sat=64
            WHEN s.freq_type = 4  THEN 127                      -- daily: every day of the week
            ELSE 0                                               -- one-time/other: excluded from recurring-overlap logic below
        END,
        StartTimeSec = (s.active_start_time / 10000) * 3600 + (s.active_start_time / 100 % 100) * 60 + (s.active_start_time % 100),
        g.ObservedMaxDurationSec,
        g.RunsConsidered
    FROM #GovJobs g
    JOIN msdb.dbo.sysjobschedules js2 ON js2.job_id = g.job_id
    JOIN msdb.dbo.sysschedules s ON s.schedule_id = js2.schedule_id
    WHERE s.enabled = 1;

    ------------------------------------------------------------------
    -- Pairwise overlap check: for every distinct pair of governance-job
    -- schedules that share at least one active day, treat each as an
    -- interval [StartTimeSec, StartTimeSec + ObservedMaxDurationSec) and
    -- test for classic interval overlap.
    ------------------------------------------------------------------
    SELECT
        JobA                 = a.JobName,
        RoleA                = a.RoleLabel,
        ScheduleA             = a.ScheduleName,
        StartTimeA            = RIGHT('0' + CAST(a.StartTimeSec / 3600 AS VARCHAR(2)), 2) + ':' + RIGHT('0' + CAST(a.StartTimeSec / 60 % 60 AS VARCHAR(2)), 2),
        ObservedMaxDurationA_Hrs = CAST(a.ObservedMaxDurationSec / 3600.0 AS DECIMAL(6,2)),
        RunsConsideredA       = a.RunsConsidered,
        JobB                 = b.JobName,
        RoleB                = b.RoleLabel,
        ScheduleB             = b.ScheduleName,
        StartTimeB            = RIGHT('0' + CAST(b.StartTimeSec / 3600 AS VARCHAR(2)), 2) + ':' + RIGHT('0' + CAST(b.StartTimeSec / 60 % 60 AS VARCHAR(2)), 2),
        ObservedMaxDurationB_Hrs = CAST(b.ObservedMaxDurationSec / 3600.0 AS DECIMAL(6,2)),
        RunsConsideredB       = b.RunsConsidered,
        CrossesMidnight = CASE
            WHEN a.ObservedMaxDurationSec IS NOT NULL AND a.StartTimeSec + a.ObservedMaxDurationSec > 86400 THEN 1
            WHEN b.ObservedMaxDurationSec IS NOT NULL AND b.StartTimeSec + b.ObservedMaxDurationSec > 86400 THEN 1
            ELSE 0 END,
        OverlapAssessment = CASE
            WHEN a.ObservedMaxDurationSec IS NULL OR b.ObservedMaxDurationSec IS NULL
                THEN 'UNKNOWN (no run history yet) - re-run this check once both jobs have completed at least one run.'
            WHEN a.StartTimeSec < b.StartTimeSec + b.ObservedMaxDurationSec
                 AND b.StartTimeSec < a.StartTimeSec + a.ObservedMaxDurationSec
                THEN 'OVERLAP RISK - based on observed history, these jobs'' scheduled windows can overlap on shared active day(s). '
                     + 'Capacity sizing in Precheck_RequiredSpaceForSetup.sql assumes SEQUENTIAL execution - either reschedule one job with '
                     + 'enough buffer after the other''s observed worst-case duration, or re-size headroom for the SUM of both jobs'' concurrent needs.'
            ELSE 'OK - observed history shows enough gap between these jobs'' scheduled windows on shared active day(s).'
        END
    FROM #GovSchedules a
    JOIN #GovSchedules b
        ON a.job_id < b.job_id                       -- each pair once
        AND (a.ActiveDaysMask & b.ActiveDaysMask) <> 0   -- share at least one active day of the week
    ORDER BY JobA, JobB;

    IF NOT EXISTS (SELECT 1 FROM #GovJobs)
        RAISERROR('No governance jobs found. This check looks for job steps whose command references Run_TieredIntegrityCheck, Rotate_VLDB_ObjectLevelChecks, or Run_LargeTier_WeeklyFullCheck - deploy Deploy_SQLAgentJobs.sql first.', 10, 1) WITH NOWAIT;
    ELSE IF NOT EXISTS (SELECT 1 FROM #GovSchedules)
        RAISERROR('Governance job(s) found but none have an enabled recurring (daily/weekly) schedule attached - nothing to compare.', 10, 1) WITH NOWAIT;

    DROP TABLE #GovJobs;
    DROP TABLE #GovSchedules;
END
GO
