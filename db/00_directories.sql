-- 00_directories.sql: directory objects and their grants. Run as SYSTEM.
--
-- A directory object maps a database name to a folder inside the container;
-- external tables and BFILE reads can only see files through one. Creating
-- them needs the CREATE ANY DIRECTORY privilege, which the ECL account
-- deliberately does not have, so setup_db.sh runs this one file as SYSTEM and
-- then grants ECL exactly the access it needs.
--
-- &1 = the application schema (APP_USER from .env, normally ECL)
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET VERIFY OFF FEEDBACK OFF

-- The folders are bind mounts from the project (see docker-compose.yml).
CREATE OR REPLACE DIRECTORY ecl_config_dir    AS '/opt/ecl/config';
CREATE OR REPLACE DIRECTORY ecl_incoming_dir  AS '/opt/ecl/data/incoming';
CREATE OR REPLACE DIRECTORY ecl_processed_dir AS '/opt/ecl/data/processed';
CREATE OR REPLACE DIRECTORY ecl_log_dir       AS '/opt/ecl/logs';

-- Read-only where the database only reads; write only where the external
-- table access driver writes its .log and .bad files.
GRANT READ        ON DIRECTORY ecl_config_dir    TO &1;
GRANT READ        ON DIRECTORY ecl_incoming_dir  TO &1;
GRANT READ        ON DIRECTORY ecl_processed_dir TO &1;
GRANT READ, WRITE ON DIRECTORY ecl_log_dir       TO &1;

PROMPT directories ECL_CONFIG_DIR, ECL_INCOMING_DIR, ECL_PROCESSED_DIR, ECL_LOG_DIR ready for &1
