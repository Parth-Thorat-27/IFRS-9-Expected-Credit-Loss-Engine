-- install.sql: build the whole ECL schema in dependency order.
--
-- Run as ECL on an empty schema. scripts/setup_db.sh does that, after it has
-- created the directory objects as SYSTEM (00_directories.sql).
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET ECHO OFF FEEDBACK OFF VERIFY OFF SERVEROUTPUT ON SIZE UNLIMITED

PROMPT [1/9] tables
@@01_tables.sql
PROMPT [2/9] constraints and indexes
@@02_constraints_indexes.sql
PROMPT [3/9] comments
@@03_comments.sql
PROMPT [4/9] external tables
@@04_external_tables.sql
PROMPT [5/9] views
@@05_views.sql
PROMPT [6/9] packages
@@packages/pkg_batch_log.pks
@@packages/pkg_batch_log.pkb
@@packages/pkg_params.pks
@@packages/pkg_params.pkb
@@packages/pkg_load.pks
@@packages/pkg_load.pkb
@@packages/pkg_lgd.pks
@@packages/pkg_lgd.pkb
@@packages/pkg_dq.pks
@@packages/pkg_dq.pkb
@@packages/pkg_staging.pks
@@packages/pkg_staging.pkb
@@packages/pkg_ecl.pks
@@packages/pkg_ecl.pkb
PROMPT [7/9] triggers
@@triggers/trg_param_audit.sql
@@triggers/trg_stage_change_audit.sql
PROMPT [8/9] seed data
@@seed/month_idx.sql
@@seed/dq_rules.sql
PROMPT [9/9] compile check
@@check_install.sql
