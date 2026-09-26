# Bundled third-party component: Ola Hallengren's SQL Server Maintenance Solution

This folder contains unmodified copies of three scripts from Ola Hallengren's
SQL Server Maintenance Solution, vendored here **only** so that
`Install-DBCCGovernanceToolkit.ps1` can automatically install this project's
one hard prerequisite when it's missing from a target's utility database,
without requiring internet access from the SQL Server itself at deploy time
(the DBCCCHECKDB_Governance toolkit is built entirely on top of these
scripts and cannot function without them).

- `CommandLog.sql` — creates the `dbo.CommandLog` logging table.
- `CommandExecute.sql` — creates `dbo.CommandExecute`, the wrapper procedure
  used for logging and error handling.
- `DatabaseIntegrityCheck.sql` — creates `dbo.DatabaseIntegrityCheck`, the
  actual `DBCC CHECKDB` wrapper every procedure in this project calls into.

Vendored version: **2026-09-12** (per each script's own `--// Version:`
header comment). Source: https://ola.hallengren.com/scripts/ — downloaded
directly from the author's site, unmodified.

## License

The SQL Server Maintenance Solution is MIT-licensed:
https://ola.hallengren.com/license.html

```
Copyright (c) 2026 Ola Hallengren

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Staying current

This is a convenience fallback, not a replacement for keeping Hallengren's
toolkit current yourself. Periodically re-download these three files from
https://ola.hallengren.com/scripts/ and replace them here to pick up fixes
and new SQL Server version support. `MaintenanceSolution.sql` (the full
install, including backup/index maintenance jobs) is intentionally **not**
vendored here — only the three files this project's auto-install needs are.
