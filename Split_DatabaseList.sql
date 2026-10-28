/*
================================================================================
 Split_DatabaseList.sql

 Purpose:
   dbo.DBCCGov_SplitDatabaseList splits a comma-separated list of database
   names into one row per name, for Rotate_VLDB_ObjectLevelChecks,
   Check_DiskAndTempdbHeadroom and Precheck_RequiredSpaceForSetup.

   An item may be bracket-quoted, with ]] for a closing bracket, so ANY
   database name can be passed - including one that contains a comma:
     N'Sales, [R&D], [Finance, EU], [Odd]]Name]'
       -> Sales | R&D | Finance, EU | Odd]Name
   Unquoted items are trimmed; quoted items are taken exactly. Empty items
   are skipped. Position keeps the order of the list. IsMalformed marks any
   quoted item with non-whitespace characters after its closing bracket;
   callers must reject the full list before acting on database names.

   A multi-statement function with a character loop (no STRING_SPLIT,
   OPENJSON or XML), so it works in a maintenance database at any
   compatibility level the toolkit supports (110+).

 Deploy this file first: the procedures above call it.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-10-26
================================================================================
*/

CREATE OR ALTER FUNCTION dbo.DBCCGov_SplitDatabaseList (@List NVARCHAR(MAX))
RETURNS @Items TABLE (Position INT IDENTITY(1,1) PRIMARY KEY, DatabaseName SYSNAME NOT NULL, IsMalformed BIT NOT NULL)
AS
BEGIN
    DECLARE @i BIGINT = 1, @len BIGINT = LEN(ISNULL(@List, N'') + N'x') - 1;   -- + 'x' keeps trailing spaces in the count
    DECLARE @ch NCHAR(1), @item NVARCHAR(MAX) = N'', @inBracket BIT = 0, @quoted BIT = 0, @openAt BIGINT = 0, @literalAt BIGINT = 0, @malformed BIT = 0;

    WHILE @i <= @len + 1
    BEGIN
        SET @ch = CASE WHEN @i <= @len THEN SUBSTRING(@List, @i, 1) ELSE N',' END;   -- a final comma ends the last item
        IF @inBracket = 1
        BEGIN
            IF @ch = N']' AND @i < @len AND SUBSTRING(@List, @i + 1, 1) = N']'
                SELECT @item += N']', @i += 1;                 -- ]] is a literal ]
            ELSE IF @ch = N']' AND @i <= @len
                SET @inBracket = 0;                            -- end of the quoted name
            ELSE IF @i > @len
                -- Unclosed [: it was not a quote after all. Read again from just after it, with the [ as an
                -- ordinary character, so the commas inside still separate names.
                SELECT @item = N'[', @inBracket = 0, @quoted = 0, @literalAt = @openAt, @i = @openAt;
            ELSE
                SET @item += @ch;
        END
        ELSE IF @ch = N'[' AND @quoted = 0 AND LTRIM(RTRIM(@item)) = N'' AND @i <> @literalAt
            SELECT @inBracket = 1, @quoted = 1, @item = N'', @openAt = @i;
        ELSE IF @ch = N','
        BEGIN
            IF @quoted = 0 SET @item = LTRIM(RTRIM(@item));
            IF @item <> N'' INSERT INTO @Items (DatabaseName, IsMalformed) VALUES (@item, @malformed);
            SELECT @item = N'', @quoted = 0, @malformed = 0;
        END
        ELSE IF @quoted = 0
            SET @item += @ch;
        ELSE IF @ch NOT IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13))
            SET @malformed = 1;   -- non-whitespace after ] must not silently resolve to another database
        SET @i += 1;
    END
    RETURN;
END
GO
