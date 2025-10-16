
/*********************************************************************************************
  File: TERA_Audit_Implementation_DemoSchema.sql
  Purpose: End-to-end implementation of SQL Server Auditing & Logging for TERA (POC/Prod-ready)
  Author: Serge Florentin Tchuenteu (Ardent Health Systems) – prepared by ChatGPT
  Schema: Demo  (use this schema name across objects and audit scope)
  Notes:
    - Run from an account with sysadmin rights.
    - Adjust paths and database names as needed.
*********************************************************************************************/

/*==========================================================================================*/
/* 0) PARAMETERS & FOLDERS                                                                   */
/*==========================================================================================*/
USE master;
GO
DECLARE @AuditFolder NVARCHAR(4000) = N'C:\SQLAudit\TERA\';

BEGIN TRY
    EXEC xp_create_subdir @AuditFolder;
END TRY BEGIN CATCH
    PRINT 'xp_create_subdir may have failed or folder already exists: ' + ERROR_MESSAGE();
END CATCH;
GO

/*==========================================================================================*/
/* 1) OPTIONAL: DEMO PRINCIPALS (Skip in prod; use existing service/users)                   */
/*==========================================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='tera_etl')
    CREATE LOGIN tera_etl WITH PASSWORD = 'P@ssw0rd_etl!';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='tera_analyst')
    CREATE LOGIN tera_analyst WITH PASSWORD = 'P@ssw0rd_analyst!';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='audit_viewer')
    CREATE LOGIN audit_viewer WITH PASSWORD = 'P@ssw0rd_view!';
GO

/*==========================================================================================*/
/* 2) OPTIONAL: DEMO OBJECTS IN TERA.DB                                                      */
/*==========================================================================================*/
IF DB_ID('TERA') IS NULL
BEGIN
    RAISERROR('Database TERA not found. Create or change DB name, then re-run.', 16, 1);
    RETURN;
END
GO

USE TERA;
GO
-- Demo schema to simulate PHI/PII domain
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='Demo') EXEC('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO

-- Demo table (remove in prod)
IF OBJECT_ID('Demo.PatientPII','U') IS NOT NULL DROP TABLE Demo.PatientPII;
CREATE TABLE Demo.PatientPII
(
    PatientID   INT IDENTITY(1,1) PRIMARY KEY,
    FullName    NVARCHAR(100),
    SSN         NVARCHAR(15),
    DOB         DATE,
    LastUpdated DATETIME2(3) DEFAULT SYSUTCDATETIME()
);
GO

-- Map users (optional)
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='tera_etl')     CREATE USER tera_etl FOR LOGIN tera_etl;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='tera_analyst') CREATE USER tera_analyst FOR LOGIN tera_analyst;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='audit_viewer') CREATE USER audit_viewer FOR LOGIN audit_viewer;
GO

-- Minimal perms for demo
GRANT SELECT, INSERT, UPDATE, DELETE ON Demo.PatientPII TO tera_etl;
GRANT SELECT ON Demo.PatientPII TO tera_analyst;
DENY  UPDATE ON Demo.PatientPII TO tera_analyst;  -- predictable failure (succeeded=0)
GO

/*==========================================================================================*/
/* 3) SERVER AUDIT (file target) + SERVER SPECIFICATIONS                                     */
/*==========================================================================================*/
USE master;
GO

IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'TERA_Server_Audit')
    ALTER SERVER AUDIT TERA_Server_Audit WITH (STATE = OFF);
DROP SERVER AUDIT IF EXISTS TERA_Server_Audit;
GO

DECLARE @AuditSql NVARCHAR(MAX) =
N'CREATE SERVER AUDIT TERA_Server_Audit
  TO FILE (FILEPATH = N''' + REPLACE(@AuditFolder,'''','''''') + N''', MAXSIZE = 512 MB, MAX_ROLLOVER_FILES = 20)
  WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);';
EXEC (@AuditSql);
GO

ALTER SERVER AUDIT TERA_Server_Audit WITH (STATE = ON);
GO

DROP SERVER AUDIT SPECIFICATION IF EXISTS TERA_Server_Spec;
GO
CREATE SERVER AUDIT SPECIFICATION TERA_Server_Spec
FOR SERVER AUDIT TERA_Server_Audit
    ADD (FAILED_LOGIN_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SERVER_PERMISSION_CHANGE_GROUP),
    ADD (SERVER_OBJECT_CHANGE_GROUP);
GO
ALTER SERVER AUDIT SPECIFICATION TERA_Server_Spec WITH (STATE = ON);
GO

/*==========================================================================================*/
/* 4) DATABASE AUDIT SPECIFICATION (scoped to Demo schema)                                   */
/*==========================================================================================*/
USE TERA;
GO
IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name='TERA_DB_Spec')
    ALTER DATABASE AUDIT SPECIFICATION TERA_DB_Spec WITH (STATE = OFF);
DROP DATABASE AUDIT SPECIFICATION IF EXISTS TERA_DB_Spec;
GO

CREATE DATABASE AUDIT SPECIFICATION TERA_DB_Spec
FOR SERVER AUDIT TERA_Server_Audit
    ADD (SELECT ON SCHEMA::Demo BY PUBLIC),
    ADD (INSERT  ON SCHEMA::Demo BY PUBLIC),
    ADD (UPDATE  ON SCHEMA::Demo BY PUBLIC),
    ADD (DELETE  ON SCHEMA::Demo BY PUBLIC),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP),
    ADD (DATABASE_OBJECT_CHANGE_GROUP);
GO
ALTER DATABASE AUDIT SPECIFICATION TERA_DB_Spec WITH (STATE = ON);
GO

/*==========================================================================================*/
/* 5) EXTENDED EVENTS – runtime errors & deadlocks                                           */
/*==========================================================================================*/
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='TERA_XE_Logger')
    DROP EVENT SESSION TERA_XE_Logger ON SERVER;
GO

CREATE EVENT SESSION TERA_XE_Logger ON SERVER
ADD EVENT sqlserver.error_reported(WHERE (severity >= 16)),
ADD EVENT sqlserver.lock_deadlock
ADD TARGET package0.ring_buffer;
GO

ALTER EVENT SESSION TERA_XE_Logger ON SERVER STATE = START;
GO

/*==========================================================================================*/
/* 6) VALIDATION – simulate activity                                                         */
/*==========================================================================================*/
USE TERA;
GO
-- success path (etl)
EXECUTE AS LOGIN = 'tera_etl';
INSERT INTO Demo.PatientPII (FullName, SSN, DOB) VALUES (N'Jane Doe', N'111-22-3333', '1990-06-01');
UPDATE Demo.PatientPII SET LastUpdated = SYSUTCDATETIME() WHERE PatientID = 1;
REVERT;

-- denied path (analyst)
EXECUTE AS LOGIN = 'tera_analyst';
BEGIN TRY
    UPDATE Demo.PatientPII SET FullName = N'Blocked Update' WHERE PatientID = 1;
END TRY BEGIN CATCH
    PRINT CONCAT('Expected failure -> ', ERROR_MESSAGE());
END CATCH;
REVERT;
GO

/*==========================================================================================*/
/* 7) REVIEW AUDIT OUTPUT                                                                    */
/*==========================================================================================*/
DECLARE @AuditFilePattern NVARCHAR(4000) = @AuditFolder + N'*.sqlaudit';

SELECT TOP (200)
    event_time,
    succeeded,
    server_principal_name,
    action_id,          -- SL/IN/UP/DL
    database_name,
    schema_name,
    object_name,
    statement
FROM sys.fn_get_audit_file(@AuditFilePattern, DEFAULT, DEFAULT)
WHERE database_name = 'TERA'
  AND action_id IN ('SL','IN','UP','DL')
  AND ISNULL(schema_name,'') NOT IN ('sys','INFORMATION_SCHEMA')
ORDER BY event_time DESC;

-- Failures only (permission denials, failed logins, etc.)
SELECT TOP (200)
    event_time, succeeded, action_id, server_principal_name,
    database_name, schema_name, object_name, statement
FROM sys.fn_get_audit_file(@AuditFilePattern, DEFAULT, DEFAULT)
WHERE succeeded = 0
ORDER BY event_time DESC;
GO

/*==========================================================================================*/
/* 8) REVIEW EXTENDED EVENTS OUTPUT                                                          */
/*==========================================================================================*/
;WITH x AS(
  SELECT CAST(t.target_data AS XML) AS xdata
  FROM sys.dm_xe_sessions s
  JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
  WHERE s.name='TERA_XE_Logger' AND t.target_name='ring_buffer'
)
SELECT
    n.value('@name','sysname')                        AS event_name,
    n.value('@timestamp','datetime2')                 AS utc_time,
    n.value('(data[@name="severity"]/value)[1]','int')           AS severity,
    n.value('(data[@name="message"]/value)[1]','nvarchar(2048)') AS message
FROM x
CROSS APPLY x.xdata.nodes('//RingBufferTarget/event') AS T(n)
ORDER BY utc_time DESC;
GO

/*==========================================================================================*/
/* 9) ACCESS & RETENTION                                                                     */
/*==========================================================================================*/
USE TERA;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='audit_viewer')
    CREATE USER audit_viewer FOR LOGIN audit_viewer;
EXEC sp_addrolemember 'db_datareader', 'audit_viewer';
GO
-- Filesystem: ensure only SQL service (write) and approved auditors (read) have access.
-- Retention: archive *.sqlaudit monthly to encrypted storage (HIPAA ~6 years).

/*==========================================================================================*/
/* 10) CLEANUP (OPTIONAL – for repeatable demos)                                             */
/*==========================================================================================*/
-- To clean up, uncomment and run this section:
/*
ALTER EVENT SESSION TERA_XE_Logger ON SERVER STATE = STOP;
DROP EVENT SESSION TERA_XE_Logger ON SERVER;

USE TERA;
ALTER DATABASE AUDIT SPECIFICATION TERA_DB_Spec WITH (STATE = OFF);
DROP DATABASE AUDIT SPECIFICATION TERA_DB_Spec;

USE master;
ALTER SERVER AUDIT SPECIFICATION TERA_Server_Spec WITH (STATE = OFF);
DROP SERVER AUDIT SPECIFICATION TERA_Server_Spec;
ALTER SERVER AUDIT TERA_Server_Audit WITH (STATE = OFF);
DROP SERVER AUDIT TERA_Server_Audit;

USE TERA;
DROP TABLE IF EXISTS Demo.PatientPII;
DROP USER IF EXISTS tera_etl, tera_analyst, audit_viewer;
USE master;
DROP LOGIN IF EXISTS tera_etl, tera_analyst, audit_viewer;
*/
