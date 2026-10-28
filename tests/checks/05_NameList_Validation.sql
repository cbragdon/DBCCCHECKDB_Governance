/*
 Regression test: malformed suffixes on bracket-quoted database names.
 Run in a disposable maintenance database with the toolkit installed.
 No databases are created or modified by this test.
*/
SET NOCOUNT ON;
DECLARE @Results TABLE (TestName nvarchar(120) NOT NULL, Passed bit NOT NULL);
DECLARE @Cases TABLE (Input nvarchar(300) NOT NULL, ExpectedName sysname NULL, ExpectedMalformed bit NOT NULL);
INSERT @Cases(Input,ExpectedName,ExpectedMalformed) VALUES
(N'[master]x', N'master', 1),
(N'[master] extra', N'master', 1),
(N'[master]   ', N'master', 0),
(N'[Odd]]Name]', N'Odd]Name', 0),
(N'[Finance, EU]', N'Finance, EU', 0),
(N'master', N'master', 0);
INSERT @Results(TestName,Passed)
SELECT c.Input,
  CONVERT(bit,CASE WHEN COUNT(f.DatabaseName)=1
     AND MAX(CONVERT(int,f.IsMalformed))=CONVERT(int,c.ExpectedMalformed)
     AND MAX(f.DatabaseName)=c.ExpectedName THEN 1 ELSE 0 END)
FROM @Cases AS c OUTER APPLY dbo.DBCCGov_SplitDatabaseList(c.Input) AS f
GROUP BY c.Input,c.ExpectedName,c.ExpectedMalformed;
DECLARE @Err int, @Pass bit;
BEGIN TRY
  EXEC dbo.Precheck_RequiredSpaceForSetup @Databases=N'[master]suffix';
  SET @Pass=0;
END TRY
BEGIN CATCH
  SET @Err=ERROR_NUMBER();
  SET @Pass=CASE WHEN @Err=50190 THEN 1 ELSE 0 END;
END CATCH;
INSERT @Results VALUES(N'Precheck rejects malformed quoted database',@Pass);
SET @Err=NULL;
BEGIN TRY
  EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases=N'[master]suffix';
  SET @Pass=0;
END TRY
BEGIN CATCH
  SET @Err=ERROR_NUMBER();
  SET @Pass=CASE WHEN @Err=50190 THEN 1 ELSE 0 END;
END CATCH;
INSERT @Results VALUES(N'Headroom rejects malformed quoted database',@Pass);
SET @Err=NULL;
BEGIN TRY
  EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases=N'[master]suffix';
  SET @Pass=0;
END TRY
BEGIN CATCH
  SET @Err=ERROR_NUMBER();
  SET @Pass=CASE WHEN @Err=50190 THEN 1 ELSE 0 END;
END CATCH;
INSERT @Results VALUES(N'Rotation rejects malformed quoted database',@Pass);
SELECT TestName, CASE WHEN Passed=1 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM @Results ORDER BY TestName;
IF EXISTS(SELECT 1 FROM @Results WHERE Passed=0)
  THROW 50191,'Quoted database-list regression assertions failed.',1;
PRINT '05_NameList_Validation: all checks PASS';
