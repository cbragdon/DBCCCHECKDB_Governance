<#
================================================================================
 Install-DBCCGovernanceToolkit.ps1

 Purpose:
   Multi-target installer for this project. Deploys the six governance
   stored procedures to one or more SQL Server VMs and/or Azure SQL Managed
   Instances in a single run, against a shared or per-server utility
   ("maintenance") database.

   What this script deploys, in dependency order (all six are
   CREATE OR ALTER PROCEDURE scripts - safe to re-run):
     1. Check_DiskAndTempdbHeadroom.sql
     2. Run_TieredIntegrityCheck.sql
     3. Rotate_VLDB_ObjectLevelChecks.sql
     4. Run_LargeTier_WeeklyFullCheck.sql
     5. Precheck_RequiredSpaceForSetup.sql
     6. Check_JobScheduleOverlap.sql

   What this script deliberately does NOT do:
     - Deploy Deploy_SQLAgentJobs.sql (the SQL Agent jobs/schedules). That
       script requires a per-instance @VLDBDatabaseList edit (which VLDB-tier
       databases exist on THIS instance) and is intentionally left as a
       manual, reviewed step per target - see Deployment-Guide.md Step 5.
     - Run Tests_CoreLogic.sql or Monitor_CommandLog_Status.sql. Both are
       on-demand scripts (a regression test suite and a reporting query),
       not something to "install" once and leave behind.
     - Use SQL authentication, ever. Auth is auto-detected per target and is
       always either Windows Integrated Auth (box product) or Azure AD
       (Managed Instance) - see "Authentication" below.

 Prerequisite auto-install (Ola Hallengren's Maintenance Solution):
   This project's procedures are built entirely on top of Ola Hallengren's
   dbo.DatabaseIntegrityCheck, so it must exist in the target maintenance
   database first. This script checks for it on every target and, if
   missing, AUTOMATICALLY installs the three files it depends on
   (CommandLog.sql, CommandExecute.sql, DatabaseIntegrityCheck.sql) from the
   vetted, unmodified, MIT-licensed copies bundled in
   vendor\OlaHallengrenMaintenanceSolution\ in this same repo (see that
   folder's README.md for license/attribution/version details) - no
   internet access from the target SQL Server is required. This is logged
   clearly per target (`[AUTO-INSTALLED]`) and recorded in the returned
   result objects via the `HallengrenAutoInstalled` column, so it's always
   visible which targets got this vs. already had it. Pass
   -SkipHallengrenAutoInstall to disable this and go back to
   fail-with-a-clear-error-if-missing behavior instead.

 Authentication (auto-detected per target, never SQL auth):
   - Server names ending in '.database.windows.net' are treated as Azure SQL
     Managed Instance -> deployed with `sqlcmd -G -C` (Azure AD).
   - Everything else is treated as a box-product SQL Server VM -> deployed
     with `sqlcmd -E -C` (Windows Integrated Auth, using the credentials of
     whoever runs this script).
   Prerequisite: sqlcmd must be installed and on PATH, and the identity
   running this script must already have the necessary Windows/Azure AD
   permissions on every target (this script does not prompt for or accept
   credentials of any kind).

 Target list (choose ONE):
   - -ServerName: one or more server/instance names passed directly.
   - -CsvPath: a CSV file for larger deployments. Required column:
       ServerName
     Optional column (falls back to -MaintenanceDB if omitted/blank):
       MaintenanceDB
     Example CSV (see Targets.example.csv in this folder):
       ServerName,MaintenanceDB
       sql-vm01.contoso.com,DBAdmin
       my-instance.<region>.database.windows.net,DBAdmin

 Usage:
   # A couple of servers directly, default utility database (DBAdmin):
   .\Install-DBCCGovernanceToolkit.ps1 -ServerName 'sql-vm01.contoso.com','my-mi.abc123.database.windows.net'

   # Large deployment via CSV, explicit default database override:
   .\Install-DBCCGovernanceToolkit.ps1 -CsvPath .\Targets.csv -MaintenanceDB 'DBAdmin'

   # Require Hallengren's toolkit to already be installed - fail instead of auto-installing it:
   .\Install-DBCCGovernanceToolkit.ps1 -CsvPath .\Targets.csv -SkipHallengrenAutoInstall

   # Preview what would run without making any changes:
   .\Install-DBCCGovernanceToolkit.ps1 -CsvPath .\Targets.csv -WhatIf

   # Save the per-target results for a deployment record:
   .\Install-DBCCGovernanceToolkit.ps1 -CsvPath .\Targets.csv | Export-Csv .\install-results.csv -NoTypeInformation

 Requires:
   sqlcmd on PATH. Deploys with `-f 65001` (UTF-8 input codepage) on every
   call - several scripts in this project contain non-ASCII characters
   (em-dashes) and plain sqlcmd defaults to the system ANSI codepage on
   Windows, which silently corrupts them (see Deployment-Guide.md Step 2).

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
#>

[CmdletBinding(DefaultParameterSetName = 'Inline', SupportsShouldProcess = $true)]
param(
    [Parameter(ParameterSetName = 'Inline', Mandatory = $true, Position = 0)]
    [string[]] $ServerName,

    [Parameter(ParameterSetName = 'Csv', Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $CsvPath,

    # Default utility/maintenance database - used for every target unless a
    # CSV row supplies its own MaintenanceDB value.
    [string] $MaintenanceDB = 'DBAdmin',

    # Folder containing the .sql files. Defaults to this script's own folder.
    [string] $ScriptFolder = $PSScriptRoot,

    # Disable auto-installing Ola Hallengren's prerequisite scripts when
    # missing - revert to failing the target with a clear error instead.
    [switch] $SkipHallengrenAutoInstall
)

$ErrorActionPreference = 'Continue'

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd was not found on PATH. Install the SQL Server command-line tools first."
}

# Deployment order matters for readability/consistency with Deployment-Guide.md
# even though CREATE OR ALTER PROCEDURE tolerates forward references.
$ProcedureFiles = @(
    'Check_DiskAndTempdbHeadroom.sql',
    'Run_TieredIntegrityCheck.sql',
    'Rotate_VLDB_ObjectLevelChecks.sql',
    'Run_LargeTier_WeeklyFullCheck.sql',
    'Precheck_RequiredSpaceForSetup.sql',
    'Check_JobScheduleOverlap.sql'
)

foreach ($file in $ProcedureFiles) {
    $fullPath = Join-Path $ScriptFolder $file
    if (-not (Test-Path $fullPath -PathType Leaf)) {
        throw "Required file not found: $fullPath (run this script from the project folder, or pass -ScriptFolder)."
    }
}

# Bundled, MIT-licensed, unmodified copies of the three Ola Hallengren files
# this project's auto-install feature uses when a target is missing the
# prerequisite - see vendor\OlaHallengrenMaintenanceSolution\README.md.
$HallengrenVendorFolder = Join-Path $ScriptFolder 'vendor\OlaHallengrenMaintenanceSolution'
$HallengrenFiles = @('CommandLog.sql', 'CommandExecute.sql', 'DatabaseIntegrityCheck.sql')

if (-not $SkipHallengrenAutoInstall) {
    foreach ($file in $HallengrenFiles) {
        $fullPath = Join-Path $HallengrenVendorFolder $file
        if (-not (Test-Path $fullPath -PathType Leaf)) {
            throw "Prerequisite auto-install is enabled but a required vendor file is missing: $fullPath. Either restore vendor\OlaHallengrenMaintenanceSolution\, or pass -SkipHallengrenAutoInstall."
        }
    }
}

#---------------------------------------------------------------------------
# Build the target list.
#---------------------------------------------------------------------------
$targets = @()

if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    $rows = Import-Csv -Path $CsvPath
    foreach ($row in $rows) {
        if (-not $row.ServerName -or $row.ServerName.Trim() -eq '') { continue }
        $db = if ($row.PSObject.Properties.Match('MaintenanceDB').Count -gt 0 -and $row.MaintenanceDB -and $row.MaintenanceDB.Trim() -ne '') {
            $row.MaintenanceDB.Trim()
        } else {
            $MaintenanceDB
        }
        $targets += [PSCustomObject]@{ ServerName = $row.ServerName.Trim(); MaintenanceDB = $db }
    }
} else {
    foreach ($name in $ServerName) {
        $targets += [PSCustomObject]@{ ServerName = $name.Trim(); MaintenanceDB = $MaintenanceDB }
    }
}

if ($targets.Count -eq 0) {
    throw "No targets resolved - check -ServerName / -CsvPath input."
}

Write-Host "Resolved $($targets.Count) target(s)."

#---------------------------------------------------------------------------
# Per-target deployment.
#---------------------------------------------------------------------------
$results = @(foreach ($target in $targets) {

    $server = $target.ServerName
    $db     = $target.MaintenanceDB
    $isMI   = $server -match '\.database\.windows\.net$'
    $authArgs = if ($isMI) { @('-G', '-C') } else { @('-E', '-C') }
    $authLabel = if ($isMI) { 'Azure AD (Managed Instance)' } else { 'Windows Integrated Auth (box product)' }

    Write-Host ""
    Write-Host "=== $server  (db: $db, auth: $authLabel) ===" -ForegroundColor Cyan

    $filesDeployed = @()
    $filesFailed   = @()
    $prereqOk      = $false
    $hallengrenAutoInstalled = $false
    $status        = 'Not attempted'

    try {
        if (-not $PSCmdlet.ShouldProcess("$server / $db", "Deploy governance toolkit ($($ProcedureFiles.Count) procedures)")) {
            $status = 'Skipped (WhatIf)'
        } else {
            # Prerequisite check: Ola Hallengren's DatabaseIntegrityCheck must
            # already exist in the target maintenance database.
            $prereqArgs = $authArgs + @('-S', $server, '-d', $db, '-f', '65001', '-b', '-h', '-1', '-W',
                '-Q', "SET NOCOUNT ON; IF OBJECT_ID('dbo.DatabaseIntegrityCheck','P') IS NULL BEGIN RAISERROR('MISSING_PREREQ',16,1); END ELSE PRINT 'PREREQ_OK';")

            $prereqOutput = & sqlcmd @prereqArgs 2>&1
            $prereqExit = $LASTEXITCODE
            $prereqMissing = ($prereqExit -ne 0 -or ($prereqOutput -join "`n") -notmatch 'PREREQ_OK')

            if ($prereqMissing -and -not $SkipHallengrenAutoInstall) {
                Write-Host "  [INFO] Prerequisite not found in [$db] - auto-installing Ola Hallengren's Maintenance Solution (CommandLog, CommandExecute, DatabaseIntegrityCheck) from the bundled vendor copy..." -ForegroundColor Yellow

                $hallengrenInstallFailed = $false
                foreach ($hfile in $HallengrenFiles) {
                    $hFullPath = Join-Path $HallengrenVendorFolder $hfile
                    $hArgs = $authArgs + @('-S', $server, '-d', $db, '-f', '65001', '-b', '-i', $hFullPath)
                    $hOutput = & sqlcmd @hArgs 2>&1
                    $hExit = $LASTEXITCODE

                    if ($hExit -eq 0) {
                        Write-Host "  [AUTO-INSTALLED] $hfile" -ForegroundColor Yellow
                    } else {
                        $hallengrenInstallFailed = $true
                        Write-Host "  [FAIL] Auto-install of $hfile failed (exit $hExit)." -ForegroundColor Red
                        $hOutput | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
                    }
                }

                if (-not $hallengrenInstallFailed) {
                    # Re-check the prerequisite now that the vendor files have
                    # been deployed, rather than assuming success.
                    $recheckOutput = & sqlcmd @prereqArgs 2>&1
                    $recheckExit = $LASTEXITCODE
                    if ($recheckExit -eq 0 -and ($recheckOutput -join "`n") -match 'PREREQ_OK') {
                        $prereqMissing = $false
                        $hallengrenAutoInstalled = $true
                        Write-Host "  [OK] Prerequisite auto-install succeeded - DatabaseIntegrityCheck now present in [$db]." -ForegroundColor Green
                    }
                }
            }

            if ($prereqMissing) {
                $status = 'FAILED - prerequisite missing or connection failed'
                Write-Host "  [FAIL] Prerequisite check: Ola Hallengren's DatabaseIntegrityCheck not found in [$db] (or could not connect)." -ForegroundColor Red
                if ($SkipHallengrenAutoInstall) {
                    Write-Host "         Auto-install is disabled (-SkipHallengrenAutoInstall) - install https://ola.hallengren.com/ to [$db] first, then re-run this target." -ForegroundColor Red
                } else {
                    Write-Host "         Auto-install was attempted and failed - see errors above. Install https://ola.hallengren.com/ to [$db] manually, then re-run this target." -ForegroundColor Red
                }
                $prereqOutput | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
            } else {
                $prereqOk = $true
                if (-not $hallengrenAutoInstalled) {
                    Write-Host "  [OK] Prerequisite check passed (DatabaseIntegrityCheck found in [$db])." -ForegroundColor Green
                }

                foreach ($file in $ProcedureFiles) {
                    $fullPath = Join-Path $ScriptFolder $file
                    $deployArgs = $authArgs + @('-S', $server, '-d', $db, '-f', '65001', '-b', '-i', $fullPath)

                    $deployOutput = & sqlcmd @deployArgs 2>&1
                    $deployExit = $LASTEXITCODE

                    if ($deployExit -eq 0) {
                        $filesDeployed += $file
                        Write-Host "  [OK] $file" -ForegroundColor Green
                    } else {
                        $filesFailed += $file
                        Write-Host "  [FAIL] $file (exit $deployExit)" -ForegroundColor Red
                        $deployOutput | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
                    }
                }

                $status = if ($filesFailed.Count -eq 0) { 'SUCCESS' }
                          elseif ($filesDeployed.Count -gt 0) { 'PARTIAL - some procedures failed' }
                          else { 'FAILED - all procedures failed' }
            }
        }
    } catch {
        # Guarantee one target's unexpected failure (e.g. a native command
        # writing to stderr, a network drop mid-deployment) never aborts the
        # whole run - log it against this target and move on to the next.
        $status = "FAILED - unexpected error: $($_.Exception.Message)"
        Write-Host "  [FAIL] Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    }

    [PSCustomObject]@{
        ServerName      = $server
        MaintenanceDB   = $db
        AuthType        = $authLabel
        PrereqOk        = $prereqOk
        HallengrenAutoInstalled = $hallengrenAutoInstalled
        ProceduresOk    = $filesDeployed.Count
        ProceduresFailed = $filesFailed.Count
        FailedFiles     = ($filesFailed -join '; ')
        Status          = $status
    }
})

Write-Host ""
Write-Host "==================== Summary ====================" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-Host

$failCount = @($results | Where-Object { $_.Status -notin @('SUCCESS', 'Skipped (WhatIf)') }).Count
if ($failCount -gt 0) {
    Write-Host "$failCount of $($results.Count) target(s) had failures - see Status/FailedFiles columns above." -ForegroundColor Yellow
} else {
    Write-Host "All targets completed successfully." -ForegroundColor Green
}

$autoInstalledCount = @($results | Where-Object { $_.HallengrenAutoInstalled }).Count
if ($autoInstalledCount -gt 0) {
    Write-Host "NOTE: Ola Hallengren's Maintenance Solution prerequisite was auto-installed on $autoInstalledCount target(s) that didn't already have it - see HallengrenAutoInstalled column above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "REMINDER: SQL Agent jobs were NOT deployed by this script." -ForegroundColor Yellow
Write-Host "Deploy_SQLAgentJobs.sql must still be run manually, per instance - edit" -ForegroundColor Yellow
Write-Host "@MaintenanceDB and @VLDBDatabaseList (if that instance has VLDB-tier" -ForegroundColor Yellow
Write-Host "databases) before running it. See Deployment-Guide.md Step 5." -ForegroundColor Yellow

$results
