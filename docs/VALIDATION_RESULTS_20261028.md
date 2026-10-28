# Executed validation — 2026-10-28

**Execution gate: PASS for the available SQL Server 2025 local scope.**

## Product revision

`8c5cd1bfe90769fd7e7fadbd0e9b7fcfbd24288c` was executed on SQL Server 2025 CU9-GDR Developer, build `17.0.5015.4`, using Windows authentication. This record is a documentation-only follow-up; the tested SQL is unchanged.

The original PR revision `55e7bfe` passed the complete existing suite with legacy CE OFF and ON. The unchanged CE-OFF repository runner reported 57/57 checks, including expected installation refusal at compatibility 100. The additional correction below received independent red/green validation and all direct/transitive affected regressions.

## Reproduced correction

With `ANSI_WARNINGS OFF`, the original parser returned a 128-character prefix and `IsMalformed = 0` for a 129-character database-name token. That could select an existing database with the truncated name. The correction checks decoded `DATALENGTH` before converting to `SYSNAME`, marks overlength items invalid, and has all three consumers reject the entire invalid list with 50190. No post-2016 T-SQL construct was introduced.

The 41-assertion name-length test fails against the old PR parser and passes after an in-place upgrade. It checks both warning settings, quoted/unquoted overlength input, valid 128-character names, Unicode, escaped brackets, and absence of CommandLog/rotation side effects. Its boundary database has short explicit logical/physical file names.

## Final execution matrix

Utility compatibility 110, 120, 130, 140, 150, 160 and 170 were each exercised with `LEGACY_CARDINALITY_ESTIMATION` OFF and ON. Compatibility 100 was tested for expected installer refusal in both settings. Native CHECKDB also ran on disposable targets at every level 100–170.

**144 recorded executions: 142 PASS and 2 EXPECTED_UNSUPPORTED. No FAIL.**

| Check | Executions | Outcome |
|---|---:|---|
| `NativeCHECKDB` | 16 | 16 PASS |
| `Install` | 16 | 14 PASS; 2 expected refusals |
| `QuotedIdentifier` | 14 | 14 PASS |
| `IndependentParserBoundaries` | 14 | 14 PASS |
| `02_Rotation` | 14 | 14 PASS |
| `03_Headroom` | 14 | 14 PASS |
| `05_NameList_Validation` | 14 | 14 PASS |
| `06_NameLength_Validation` | 14 | 14 PASS |
| `ActualTargetCheck` | 14 | 14 PASS |
| `01_Tiering_Routing` | 14 | 14 PASS |

`01_Tiering_Routing.sql` was rerun because its tiered and weekly callers invoke the changed headroom procedure. The standalone core-expression and job-overlap files are unchanged and retain their complete baseline matrix evidence. The new name-length file contributed 574 successful SQL assertions (41 × 14 contexts).

Detailed per-execution CSVs include build, compatibility, CE, test name, actual result/error, duration and product commit. Raw output and earlier failed harness attempts are retained in the timestamped local validation artifacts. Static inspection is not counted as SQL execution.

## Cleanup

Final readback matched the original nine databases and their compatibility levels. Instance memory settings, job/schedule identities, existing SSIS catalog project/environment metadata and package hashes were preserved. No temporary database, job, catalog fixture or orphan test data/log file remained; the instance index lock was free. No production deployment or enforcement was performed.

## Scope limits and return contract

Compatibility levels on SQL Server 2025 do not qualify actual SQL Server 2016–2022 or Azure Managed Instance engines. Tier routing uses the suite's scaled fixtures and simulated AG DMV rows; real AG failover and 500 GB/2 TB maintenance are not certified. The name-length fixture requires a box-product instance with default data/log paths.

The added `IsMalformed` output column originates in this PR. External `SELECT *` consumers must account for that return-shape change and reject rows flagged invalid. The excluded timeout procedure was not deployed, modified or executed.
