-- install.sql: build the whole ECL schema in dependency order.
--
-- Run as ECL on an empty schema. scripts/setup_db.sh does that, after it has
-- created the directory objects as SYSTEM (00_directories.sql).
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET ECHO OFF FEEDBACK OFF VERIFY OFF SERVEROUTPUT ON SIZE UNLIMITED

PROMPT [1/8] tables
@@01_tables.sql
PROMPT [2/8] constraints and indexes
@@02_constraints_indexes.sql
PROMPT [3/8] comments
@@03_comments.sql
PROMPT [4/8] external tables
@@04_external_tables.sql
PROMPT [5/8] views
@@05_views.sql
PROMPT [6/8] packages
@@packages/pkg_batch_log.pks
@@packages/pkg_batch_log.pkb
PROMPT [7/8] seed data
@@seed/month_idx.sql
PROMPT [8/8] compile check
@@check_install.sql
