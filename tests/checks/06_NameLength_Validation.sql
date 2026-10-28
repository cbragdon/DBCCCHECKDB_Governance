/* Run in a disposable maintenance database with the toolkit installed.
   Every lab object is removed. Proves 128-character names remain valid and
   overlength names cannot alias them, including with ANSI_WARNINGS OFF. */
SET NOCOUNT ON;
DECLARE @OriginalWarnings bit=CASE WHEN (16 & @@OPTIONS)=16 THEN 1 ELSE 0 END;
DECLARE @Results TABLE(TestName nvarchar(200) NOT NULL,Passed bit NOT NULL,Detail nvarchar(1000) NULL);
DECLARE @Prefix nvarchar(128)=N'DBCCGovNameLab_',@Name sysname,@Created bit=0,@Sql nvarchar(max),@Err int;
SET @Name=@Prefix+REPLICATE(N'x',128-LEN(@Prefix));
IF DB_ID(@Name) IS NOT NULL THROW 50194,'Name-length lab database already exists; inspect it before running this test.',1;
BEGIN TRY
    -- Default logical/physical file names append suffixes to the database name.
    -- Supply short file names so the 128-character identifier itself is tested.
    DECLARE @Tag varchar(32)=REPLACE(CONVERT(varchar(36),NEWID()),'-','');
    DECLARE @DataPath nvarchar(260)=CONVERT(nvarchar(260),SERVERPROPERTY('InstanceDefaultDataPath'));
    DECLARE @LogPath nvarchar(260)=CONVERT(nvarchar(260),SERVERPROPERTY('InstanceDefaultLogPath'));
    IF @DataPath IS NULL OR @LogPath IS NULL THROW 50196,'This fixture requires a box-product instance with default data and log paths.',1;
    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@Name)+N' ON PRIMARY (NAME=N''DBCCGovNameLab_Data'',FILENAME=N'
        +QUOTENAME(@DataPath+N'DBCCGovNameLab_'+@Tag+N'.mdf','''')+N') LOG ON (NAME=N''DBCCGovNameLab_Log'',FILENAME=N'
        +QUOTENAME(@LogPath+N'DBCCGovNameLab_'+@Tag+N'.ldf','''')+N');';
    EXEC(@Sql);SET @Created=1;
    SET @Sql=N'USE '+QUOTENAME(@Name)+N';CREATE TABLE dbo.Probe(Id int NOT NULL PRIMARY KEY);INSERT dbo.Probe VALUES(1);';EXEC(@Sql);
    DECLARE @Long nvarchar(max)=CONVERT(nvarchar(max),@Name)+N'y';
    DECLARE @Cases TABLE(Id int NOT NULL,Input nvarchar(max) NULL,Expected nvarchar(128) NULL,Malformed bit NOT NULL,ExpectedRows int NOT NULL);
    INSERT @Cases VALUES
    (1,NULL,NULL,0,0),(2,N'',NULL,0,0),(3,N', ,',NULL,0,0),
    (4,N'[a]]]',N'a]',0,1),(5,N'[a]]',N'[a]]',1,1),
    (6,N'[master]suffix',N'master',1,1),(7,N'[master]'+NCHAR(9)+NCHAR(13)+NCHAR(10),N'master',0,1),
    (8,@Name,@Name,0,1),(9,QUOTENAME(@Name),@Name,0,1),
    (10,N'[数据,庫]',N'数据,庫',0,1),(11,N' [Finance, EU] ',N'Finance, EU',0,1),
    (12,N'[master] [model]',N'master',1,1),(13,N'[]suffix',N'',1,1),
    (14,@Long,@Name,1,1),(15,N'['+@Long+N']',@Name,1,1);
    DECLARE @Mode int=0,@Setting varchar(3),@BeforeLog int,@BeforeRotation int;
    WHILE @Mode<2
    BEGIN
        IF @Mode=0 BEGIN SET ANSI_WARNINGS OFF;SET @Setting='OFF';END
        ELSE BEGIN SET ANSI_WARNINGS ON;SET @Setting='ON';END;
        INSERT @Results(TestName,Passed,Detail)
        SELECT N'ANSI_WARNINGS '+@Setting+N' parser case '+CONVERT(nvarchar(3),c.Id),
            CONVERT(bit,CASE WHEN COUNT(f.Position)=c.ExpectedRows
                AND (c.ExpectedRows=0 OR (MAX(CONVERT(int,f.IsMalformed))=CONVERT(int,c.Malformed)
                AND MAX(DATALENGTH(f.DatabaseName))=DATALENGTH(c.Expected)
                AND MAX(f.DatabaseName) COLLATE Latin1_General_100_BIN2=c.Expected COLLATE Latin1_General_100_BIN2))
                THEN 1 ELSE 0 END),NULL
        FROM @Cases c OUTER APPLY dbo.DBCCGov_SplitDatabaseList(c.Input) f
        GROUP BY c.Id,c.Input,c.Expected,c.Malformed,c.ExpectedRows;
        SELECT @BeforeLog=ISNULL(MAX(ID),0) FROM dbo.CommandLog;
        SELECT @BeforeRotation=COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName=@Name;
        SET @Err=0;
        BEGIN TRY EXEC dbo.Precheck_RequiredSpaceForSetup @Databases=@Long; END TRY
        BEGIN CATCH SET @Err=ERROR_NUMBER(); END CATCH;
        INSERT @Results VALUES(N'ANSI_WARNINGS '+@Setting+N' precheck rejects overlength input',CONVERT(bit,CASE WHEN @Err=50190 THEN 1 ELSE 0 END),CONVERT(nvarchar(20),@Err));
        SET @Err=0;
        BEGIN TRY EXEC dbo.Check_DiskAndTempdbHeadroom @TargetDatabases=@Long,@MinTempdbFreePct=100; END TRY
        BEGIN CATCH SET @Err=ERROR_NUMBER(); END CATCH;
        INSERT @Results VALUES(N'ANSI_WARNINGS '+@Setting+N' headroom rejects overlength input',CONVERT(bit,CASE WHEN @Err=50190 THEN 1 ELSE 0 END),CONVERT(nvarchar(20),@Err));
        SET @Err=0;
        BEGIN TRY EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases=@Long,@DaysInCycle=1,@TimeLimitSeconds=0; END TRY
        BEGIN CATCH SET @Err=ERROR_NUMBER(); END CATCH;
        INSERT @Results VALUES(N'ANSI_WARNINGS '+@Setting+N' rotation rejects overlength input',CONVERT(bit,CASE WHEN @Err=50190 THEN 1 ELSE 0 END),CONVERT(nvarchar(20),@Err));
        INSERT @Results SELECT N'ANSI_WARNINGS '+@Setting+N' rejected inputs leave CommandLog unchanged',CONVERT(bit,CASE WHEN NOT EXISTS(SELECT 1 FROM dbo.CommandLog WHERE ID>@BeforeLog) THEN 1 ELSE 0 END),NULL;
        INSERT @Results SELECT N'ANSI_WARNINGS '+@Setting+N' rejected inputs leave rotation registration unchanged',CONVERT(bit,CASE WHEN (SELECT COUNT(*) FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName=@Name)=@BeforeRotation THEN 1 ELSE 0 END),NULL;
        SET @Mode+=1;
    END;
    SET ANSI_WARNINGS ON;
    DECLARE @ValidList nvarchar(260)=QUOTENAME(@Name);
    EXEC dbo.Rotate_VLDB_ObjectLevelChecks @VLDBDatabases=@ValidList,@DaysInCycle=1,@TimeLimitSeconds=0;
    INSERT @Results SELECT N'A valid 128-character name reaches rotation without truncation',CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM dbo.VLDB_CheckRotationLog WHERE DatabaseName=@Name AND TableName=N'Probe') THEN 1 ELSE 0 END),NULL;
END TRY
BEGIN CATCH
    INSERT @Results VALUES(N'Name-length fixture and assertions complete',0,CONVERT(nvarchar(1000),ERROR_MESSAGE()));
END CATCH;
SET ANSI_WARNINGS ON;
IF @Created=1
BEGIN
    DELETE dbo.VLDB_CheckRotationLog WHERE DatabaseName=@Name;
    IF DB_ID(@Name) IS NOT NULL BEGIN SET @Sql=N'ALTER DATABASE '+QUOTENAME(@Name)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;DROP DATABASE '+QUOTENAME(@Name)+N';';EXEC(@Sql);END;
END;
SELECT TestName,CASE WHEN Passed=1 THEN 'PASS' ELSE 'FAIL' END AS Result,Detail FROM @Results ORDER BY TestName;
DECLARE @Total int=(SELECT COUNT(*) FROM @Results),@Failed int=(SELECT COUNT(*) FROM @Results WHERE Passed=0);
PRINT '06_NameLength_Validation: '+CONVERT(varchar(10),@Total)+' test(s) run, '+CONVERT(varchar(10),@Total-@Failed)+' passed, '+CONVERT(varchar(10),@Failed)+' failed';
IF @OriginalWarnings=0 SET ANSI_WARNINGS OFF;
IF @Failed>0 OR @Total<>41 THROW 50195,'Database-list name-length regression assertions failed.',1;
