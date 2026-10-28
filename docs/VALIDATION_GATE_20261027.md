# PR #7 validation gate — 2026-10-27

**Historical pre-execution gate.** Successful local execution and the subsequent overlength-name correction are recorded in [VALIDATION_RESULTS_20261028.md](VALIDATION_RESULTS_20261028.md). The original planning state follows.


**Status: NOT READY TO MERGE.** This document distinguishes live CI evidence, source-level checks and SQL Server execution. No test is recorded as successful unless it was actually executed.

## Scope

Repository: `cbragdon/DBCCCHECKDB_Governance`  
Branch: `audit/20261027-validate-quoted-name-suffix`  
Requested SQL Server: `DESKTOP-6BVBI90`, SQL Server 2025 CU9 (17.0.5015.4), Windows authentication.  
Local test evidence directory: `D:\Projects\_sessions`.

The excluded `FindTimeoutStatementsNQueryStore` object belongs to a different repository and is not modified or tested here.

## Finding and proposed fix

The original `DBCCGov_SplitDatabaseList` silently accepted an input such as `[master]suffix` as the existing database `master`. The fix returns `IsMalformed` per token and checks the flag in `Precheck_RequiredSpaceForSetup`, `Check_DiskAndTempdbHeadroom` and `Rotate_VLDB_ObjectLevelChecks` before processing. Malformed input throws error **50190**. The headroom check now validates before it can emit `CommandLog` rows. The regression test additionally covers unclosed brackets and escaped `]` characters.

**Compatibility note:** `DBCCGov_SplitDatabaseList` now exposes an extra output column (`IsMalformed`). Internal callers use explicit column selection; external callers using `SELECT *` should review the changed return contract before merging.

## Evidence recorded in this session

| Gate | Result | Evidence |
|---|---|---|
| GitHub repository and branch available | PASS | Connected GitHub API, draft PR #7 |
| Static source assertions (14 checked) | PASS | Inspected source at current PR branch; confirms guards, ordering, test runner discovery and failure reporting |
| New SQL regression test present | PASS (source presence only) | `tests/checks/05_NameList_Validation.sql` |
| Full SQL Server 2025 integration suite | **NOT RUN** | This execution environment cannot reach the Windows SQL Server or local project drives |
| Compatibility level 100, CE OFF/ON | **NOT RUN** | Expected installer refusal below supported minimum 110; must be verified |
| Levels 110–170, legacy CE OFF/ON | **NOT RUN** | Must execute on disposable maintenance databases |
| Shared instance state unchanged | **NOT VERIFIED** | Must be checked after integration runs |
| Merge approval | **BLOCKED** | All required integration tests must pass first |

Static assertions are not SQL compilation tests. They cannot prove that the T-SQL executes correctly.

## Required local execution

From a clean checkout of this PR branch, on a Windows machine with `sqlcmd`, Windows PowerShell and the required SQL Server sysadmin privileges:

```powershell
Set-Location D:\Projects\_sessions
git clone https://github.com/cbragdon/DBCCCHECKDB_Governance.git DBCCCHECKDB_Governance_PR7
Set-Location .\DBCCCHECKDB_Governance_PR7
git checkout audit/20261027-validate-quoted-name-suffix
$levels = @(100,110,120,130,140,150,160,170)
.\tests\Run-Checks.ps1 -ServerName DESKTOP-6BVBI90 -CompatibilityLevel $levels -ResultPath 'D:\Projects\_sessions\DBCC_PR7_CE_OFF.csv'
.\tests\Run-Checks.ps1 -ServerName DESKTOP-6BVBI90 -CompatibilityLevel $levels -LegacyCardinalityEstimation -ResultPath 'D:\Projects\_sessions\DBCC_PR7_CE_ON.csv'
```

Each invocation must exit 0 and every CSV `Result` must be `PASS`, including `05_NameList_Validation.sql`. The compatibility-100 installer refusal must be a PASS of the expected unsupported-version behavior. Record any log, exception and resource adjustment. Verify disposable databases are removed.

## Merge rule

Only after these runs succeed, attach both CSVs (or a summary with exact counts and commit SHA), record the SQL Server build and shared-instance cleanup checks, review the changed table-valued function return schema, and change this gate from NOT READY to READY. **Do not merge on static source review alone.**
