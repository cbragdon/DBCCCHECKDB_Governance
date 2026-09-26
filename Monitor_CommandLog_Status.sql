/*
================================================================================
 Monitor_CommandLog_Status.sql

 Purpose:
   Reports the most recent DBCC_CHECKDB executions from Ola Hallengren's
   CommandLog table, correctly distinguishing four states instead of the naive
   two (running vs. completed):

     - Succeeded              : EndTime populated, ErrorNumber = 0
     - Failed                 : EndTime populated, ErrorNumber <> 0
     - Running                : EndTime/ErrorNumber NULL, AND started after
                                 the instance's current start time (genuinely
                                 could still be executing)
     - Interrupted (orphaned) : EndTime/ErrorNumber NULL, but StartTime is
                                 BEFORE the instance's current start time -
                                 this row can NOT still be running; SQL Server
                                 (or the OS) restarted mid-check and the
                                 UPDATE that would have written EndTime/
                                 ErrorNumber never ran (see explanation below).

 Why this matters:
   CommandExecute.sql (which CommandLog logging is built on) INSERTs a row
   with StartTime BEFORE running the DBCC command, then UPDATEs that same row
   with EndTime/ErrorNumber AFTER the command returns, inside a TRY/CATCH.
   A clean SQL Server shutdown, crash, failover, or OS reboot (e.g. patching)
   severs the connection mid-execution - this is NOT a catchable T-SQL error,
   so the UPDATE never runs. The row is left permanently with EndTime AND
   ErrorNumber both NULL, which is indistinguishable from "still running"
   unless you check whether the instance has since restarted.

   Treating every EndTime IS NULL row as "currently running" will falsely
   report old, dead, pre-restart checks as active - potentially masking that
   a scheduled CHECKDB never actually completed.

 Usage:
   Run standalone, or wire into existing monitoring/alerting on a schedule.
   Alert on any row with Status = 'Interrupted (Server Restarted)' - it means
   a CHECKDB run was cut short and that database has NOT been fully checked
   since; re-run the appropriate tier proc for that database.

   A second result set reports recent Check_DiskAndTempdbHeadroom.sql
   warnings (CommandType = 'HEADROOM_CHECK'), which that proc persists to
   CommandLog in addition to its RAISERROR output - so a low-headroom
   condition preceding a CHECKDB run is visible here too, not just in
   SQL Agent job step history.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
*/

DECLARE @ServerStartTime DATETIME2 = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info);

;WITH CommandLogData AS (
    SELECT TOP (40)
        DatabaseName,
        CommandType,
        Command,
        StartTime,
        EndTime,
        ErrorNumber,
        Status = CASE
            WHEN EndTime IS NOT NULL AND ErrorNumber = 0 THEN 'Succeeded'
            WHEN EndTime IS NOT NULL AND ErrorNumber <> 0 THEN 'Failed'
            WHEN EndTime IS NULL AND ErrorNumber IS NULL AND StartTime >= @ServerStartTime THEN 'Running'
            WHEN EndTime IS NULL AND ErrorNumber IS NULL AND StartTime < @ServerStartTime THEN 'Interrupted (Server Restarted)'
            ELSE 'Unknown'
        END,
        DurationSeconds = CASE
            -- Completed (success or failure): actual measured duration
            WHEN EndTime IS NOT NULL THEN DATEDIFF(SECOND, StartTime, EndTime)
            -- Genuinely still running: elapsed time so far
            WHEN EndTime IS NULL AND ErrorNumber IS NULL AND StartTime >= @ServerStartTime THEN DATEDIFF(SECOND, StartTime, SYSDATETIME())
            -- Interrupted/orphaned: true stop time is unknown (somewhere between
            -- StartTime and the shutdown), so duration cannot be reliably computed -
            -- deliberately left NULL rather than showing a misleading number.
            ELSE NULL
        END
    FROM dbo.CommandLog
    WHERE CommandType = 'DBCC_CHECKDB'
    ORDER BY StartTime DESC
)
SELECT
    DatabaseName,
    CommandType,
    Command,
    StartTime,
    EndTime,
    ErrorNumber,
    Status,
    Duration =
        CASE
            WHEN DurationSeconds IS NULL THEN 'Unknown (interrupted before completion)'
            ELSE
                CAST(DurationSeconds / 86400 AS VARCHAR(10)) + 'd ' +
                RIGHT('0' + CAST((DurationSeconds % 86400) / 3600 AS VARCHAR(2)), 2) + 'h ' +
                RIGHT('0' + CAST((DurationSeconds % 3600) / 60 AS VARCHAR(2)), 2) + 'm ' +
                RIGHT('0' + CAST(DurationSeconds % 60 AS VARCHAR(2)), 2) + 's' +
                CASE WHEN Status = 'Running' THEN ' (running)' ELSE '' END
        END
FROM CommandLogData

UNION ALL

-- Grand total: only sums rows with a reliably measured duration
-- (Succeeded/Failed). Running and Interrupted rows are excluded since their
-- true duration is either incomplete (still going) or unknowable (orphaned).
SELECT
    'GRAND TOTAL (Succeeded/Failed only)',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    CAST(SUM(CASE WHEN Status IN ('Succeeded','Failed') THEN DurationSeconds END) / 86400 AS VARCHAR(10)) + 'd ' +
    RIGHT('0' + CAST((SUM(CASE WHEN Status IN ('Succeeded','Failed') THEN DurationSeconds END) % 86400) / 3600 AS VARCHAR(2)), 2) + 'h ' +
    RIGHT('0' + CAST((SUM(CASE WHEN Status IN ('Succeeded','Failed') THEN DurationSeconds END) % 3600) / 60 AS VARCHAR(2)), 2) + 'm ' +
    RIGHT('0' + CAST(SUM(CASE WHEN Status IN ('Succeeded','Failed') THEN DurationSeconds END) % 60 AS VARCHAR(2)), 2) + 's'
FROM CommandLogData;

------------------------------------------------------------------
-- Recent headroom-check warnings/info (from Check_DiskAndTempdbHeadroom.sql).
-- Each row is a point-in-time message logged immediately before a
-- Large/VLDB-tier run; DatabaseName is 'tempdb', the affected target
-- database, or NULL for instance-wide notes (MI-skip, IFI).
------------------------------------------------------------------
SELECT TOP (40)
    DatabaseName,
    LogDate = StartTime,
    Message = ErrorMessage
FROM dbo.CommandLog
WHERE CommandType = 'HEADROOM_CHECK'
ORDER BY StartTime DESC;
