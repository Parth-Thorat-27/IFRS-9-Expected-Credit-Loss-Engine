#!/usr/bin/env bash
# Phase 1 smoke test: prove both ways into the database work before any
# schema exists.
#   1. SQL*Plus inside the container: the path every bash batch step uses
#   2. python-oracledb thin mode from the host: the path the Python steps use
#
# Usage: scripts/smoke_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_env APP_USER APP_USER_PASSWORD

log "waiting for the $APP_USER account to accept logins"
wait_for_db 600

log "1/2 SQL*Plus through docker exec $ORACLE_CONTAINER"
run_sql ECL - <<'SQL'
-- TAB OFF: by default SQL*Plus squeezes runs of spaces in its output into tab characters.
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 TAB OFF
SELECT 'database version : ' || REPLACE(banner_full, CHR(10), ' | ') FROM v$version;
SELECT 'connected user   : ' || USER FROM dual;
SELECT 'container (PDB)  : ' || SYS_CONTEXT('USERENV', 'CON_NAME') FROM dual;
SQL

log "2/2 python-oracledb from the host"
"$PYTHON" "$ROOT_DIR/python/smoke_db.py"

log "smoke test passed"
