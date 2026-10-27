# Security policy for DBCC CHECKDB Governance

## Supported versions

Only the latest commit on `main` is supported. Fixes are made there; older copies are not patched separately.

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to <https://github.com/cbragdon/DBCCCHECKDB_Governance/security/advisories/new>.
2. Describe the problem, the affected file, procedure or script, how to reproduce it on a test instance, and what an attacker could gain.

Remove anything private before sending: server, instance, database, login and object names, and data values.

The report stays private between you and the maintainer until a fix is published.

## What to expect

This is a one-person project, so there is no guaranteed response time. Reports are read and answered as soon as possible. You will be told whether the report is accepted, and when a fix is published. If you would like to be credited in the advisory, say so.

## What counts as a security problem

Anything that lets the code expose data, run something it was not asked to run, gain permissions it should not have, or leak a credential. For example, a crafted database or object name that changes the dynamic SQL a procedure builds.

The project's design already commits to the following, and a way around any of them is a security problem:

- Every database, schema and table name in a `DBCC` command the toolkit builds is quoted with `QUOTENAME`.
- Azure SQL Database is rejected (`EngineEdition = 5`).

## Out of scope

- The files in `vendor/OlaHallengrenMaintenanceSolution/` are Ola Hallengren's code. Report a problem in them to him through <https://ola.hallengren.com>; it is fixed here by taking his official release.
- Vulnerabilities in SQL Server or Windows themselves: report them to Microsoft through the [Microsoft Security Response Center](https://msrc.microsoft.com/report).
