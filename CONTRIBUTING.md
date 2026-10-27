# Contributing to DBCC CHECKDB Governance

Issues and pull requests are welcome. For anything beyond a small fix, open an issue first so the approach can be agreed before you spend time on it.

## Reporting a problem

Include:

- SQL Server version and edition (`SELECT @@VERSION;`), and whether it is a SQL Server VM or Azure SQL Managed Instance.
- The version of Ola Hallengren's Maintenance Solution installed.
- The database's size and tier, and its availability group role if it has one.
- The exact procedure call or job step, and the full output or error text.

Remove anything private before posting: server, instance, database, login and object names, and data values.

## Pull requests

- Branch from `main` and keep one change per pull request.
- Say what changed and why, and list every test you ran with its result. A test that was not run is not reported as passed.
- Update the documentation in the same pull request when behaviour changes.
- Keep each file's existing encoding and line endings.

## Rules every change keeps

- The toolkit builds on Ola Hallengren's `DatabaseIntegrityCheck` and `CommandExecute`; integrity checks keep running through them.
- The files in `vendor/OlaHallengrenMaintenanceSolution/` are Ola Hallengren's code under his own MIT license. Replace them only with an unmodified official release, and keep his license text.
- Azure SQL Database stays out of scope: the procedures reject `EngineEdition = 5`.

## Tests

Both levels of tests are described under "Testing" in the [README](README.md). Run them on a test instance, never on production:

```powershell
.\tests\Run-Checks.ps1 -ServerName <test instance> -CompatibilityLevel 100,110,120,130,140,150,160,170
.\tests\Run-Checks.ps1 -ServerName <test instance> -CompatibilityLevel 100,110,120,130,140,150,160,170 -LegacyCardinalityEstimation
```

Each run creates disposable databases, installs the toolkit with the installer, runs every check and drops them again. `Tests_CoreLogic.sql` needs nothing installed.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.
