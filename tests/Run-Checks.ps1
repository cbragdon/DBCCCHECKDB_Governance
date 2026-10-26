<#
================================================================================
 tests/Run-Checks.ps1

 Purpose:
   Runs the self-checking tests against a DISPOSABLE maintenance database, at
   one or more database compatibility levels (optionally with the legacy
   cardinality estimator), on a box-product test instance:
     1. creates the maintenance database (default name DBCCGovRun_Admin);
     2. installs the toolkit into it with Install-DBCCGovernanceToolkit.ps1
        (no -ScriptFolder, exactly as a user runs it), including the
        Ola Hallengren prerequisite from vendor\;
     3. checks every procedure was created with QUOTED_IDENTIFIER ON;
     4. runs Tests_CoreLogic.sql and tests\checks\*.sql with sqlcmd -b and
        requires "0 failed" from each;
     5. drops the maintenance database (unless -KeepDatabase).
   Below compatibility level 110 the installer must refuse the database; the
   runner checks that it does and moves on.

   The checks create and drop their own DBCCGovTest_* databases (about
   3.5 GB at peak, in the instance default paths). Nothing is written to
   msdb, and no real database is checked.

 Usage:
   .\tests\Run-Checks.ps1 -ServerName localhost
   .\tests\Run-Checks.ps1 -ServerName localhost -CompatibilityLevel 100,110,120,130,140,150,160,170
   .\tests\Run-Checks.ps1 -ServerName localhost -CompatibilityLevel 130 -LegacyCardinalityEstimation
   .\tests\Run-Checks.ps1 -ServerName localhost -ResultPath .\check-results.csv   # also append the rows to a CSV

 Exit code: 0 when every check passed, 1 otherwise.
 Requires: sqlcmd on PATH, sysadmin on the test instance (Windows auth).
================================================================================
#>
[CmdletBinding()]
param(
    [string] $ServerName = 'localhost',
    [int[]] $CompatibilityLevel = @(150),
    [switch] $LegacyCardinalityEstimation,
    [ValidatePattern('^DBCCGovRun_\w+$')]
    [string] $MaintenanceDB = 'DBCCGovRun_Admin',
    [switch] $KeepDatabase,
    [string] $ResultPath
)

# Continue, not Stop: in Windows PowerShell 5.1 a native command's stderr line under 2>&1 would
# otherwise end the run. Every sqlcmd exit code is checked explicitly instead.
$ErrorActionPreference = 'Continue'
$TestsFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoFolder  = Split-Path -Parent $TestsFolder
$Installer   = Join-Path $RepoFolder 'Install-DBCCGovernanceToolkit.ps1'
$Checks      = @(Join-Path $RepoFolder 'Tests_CoreLogic.sql') + @(Get-ChildItem (Join-Path $TestsFolder 'checks') -Filter '*.sql' | Sort-Object Name | ForEach-Object FullName)
$Procedures  = @('DBCCGov_SplitDatabaseList', 'Check_DiskAndTempdbHeadroom', 'Run_TieredIntegrityCheck', 'Rotate_VLDB_ObjectLevelChecks',
                 'Run_LargeTier_WeeklyFullCheck', 'Precheck_RequiredSpaceForSetup', 'Check_JobScheduleOverlap')

function Invoke-Query([string]$Database, [string]$Query) {
    $out = & sqlcmd -S $ServerName -E -C -b -I -d $Database -h -1 -W -Q "SET NOCOUNT ON; $Query" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed in [$Database]: $Query`n$($out -join "`n")" }
    $out
}
function Remove-MaintenanceDb {
    Invoke-Query 'master' "IF DB_ID(N'$MaintenanceDB') IS NOT NULL BEGIN ALTER DATABASE [$MaintenanceDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$MaintenanceDB]; END" | Out-Null
}

$rows = @()
foreach ($level in $CompatibilityLevel) {
    $ce = if ($LegacyCardinalityEstimation) { 'ON' } else { 'OFF' }
    $label = "compat $level, legacy CE $ce"
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    Remove-MaintenanceDb
    Invoke-Query 'master' "CREATE DATABASE [$MaintenanceDB]; ALTER DATABASE [$MaintenanceDB] SET COMPATIBILITY_LEVEL = $level;" | Out-Null
    Invoke-Query $MaintenanceDB "ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = $ce;" | Out-Null

    $install = & $Installer -ServerName $ServerName -MaintenanceDB $MaintenanceDB 6>$null | Select-Object -Last 1
    if ($level -lt 110) {
        $ok = $install.Status -like 'FAILED - maintenance database compatibility level*'
        $rows += [pscustomobject]@{ Level = $label; Check = 'Installer refuses compatibility below 110'; Result = $(if ($ok) {'PASS'} else {'FAIL'}); Detail = $install.Status }
        if (-not $KeepDatabase) { Remove-MaintenanceDb }
        continue
    }
    $rows += [pscustomobject]@{ Level = $label; Check = 'Installer (no -ScriptFolder)'; Result = $(if ($install.Status -eq 'SUCCESS') {'PASS'} else {'FAIL'}); Detail = $install.Status }
    if ($install.Status -ne 'SUCCESS') { if (-not $KeepDatabase) { Remove-MaintenanceDb }; continue }

    $list = ($Procedures | ForEach-Object { "N'$_'" }) -join ','
    $qi = Invoke-Query $MaintenanceDB "SELECT CAST(COUNT(*) AS varchar(10)) + '/' + CAST(SUM(CAST(m.uses_quoted_identifier AS int)) AS varchar(10)) FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id WHERE o.name IN ($list);"
    $qiText = ($qi | Select-Object -Last 1).Trim()
    $rows += [pscustomobject]@{ Level = $label; Check = 'All 7 objects created with QUOTED_IDENTIFIER ON'; Result = $(if ($qiText -eq '7/7') {'PASS'} else {'FAIL'}); Detail = "objects/QI on = $qiText" }

    foreach ($file in $Checks) {
        $name = [IO.Path]::GetFileName($file)
        $out = & sqlcmd -S $ServerName -E -C -b -I -f 65001 -d $MaintenanceDB -W -i $file 2>&1
        $exit = $LASTEXITCODE
        $text = $out -join "`n"
        $summary = ([regex]::Match($text, '(\d+) test\(s\) run, (\d+) passed, (\d+) failed')).Value
        $ok = ($exit -eq 0) -and ($summary -match ', 0 failed$')
        if (-not $ok) { $out | Where-Object { $_ -match 'FAIL|Msg \d+' } | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        $rows += [pscustomobject]@{ Level = $label; Check = $name; Result = $(if ($ok) {'PASS'} else {'FAIL'}); Detail = $(if ($summary) { $summary } else { "exit $exit" }) }
    }
    if (-not $KeepDatabase) { Remove-MaintenanceDb }
}

$rows | Format-Table -AutoSize | Out-Host
if ($ResultPath) { $rows | Select-Object @{ n = 'Time'; e = { (Get-Date).ToString('s') } }, * | Export-Csv -Path $ResultPath -NoTypeInformation -Append }
$failed = @($rows | Where-Object Result -ne 'PASS').Count
Write-Host "$($rows.Count - $failed) of $($rows.Count) check(s) passed." -ForegroundColor $(if ($failed) {'Red'} else {'Green'})
exit $(if ($failed) { 1 } else { 0 })
