#!/usr/bin/env bash
# Build the database schema.
#
#   1. As SYSTEM: directory objects and grants (db/00_directories.sql). Only a
#      privileged account may create directories.
#   2. As ECL: everything else (db/install.sql).
#
# Usage: scripts/setup_db.sh [--reset]
#   --reset   drop every object in the ECL schema first. All data is lost;
#             rerun load_history.sh and the monthly batch afterwards.
# Exit codes: 0 success, 1 a step failed, 2 bad arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

reset=false
case "${1:-}" in
  "") ;;
  --reset) reset=true ;;
  -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
  *) die 2 "unknown option '$1' (usage: scripts/setup_db.sh [--reset])" ;;
esac

require_env ORACLE_PASSWORD APP_USER APP_USER_PASSWORD
log "waiting for the database"
wait_for_db 600

log "directory objects and grants (as SYSTEM)"
run_sql SYSTEM db/00_directories.sql "$APP_USER"

if $reset; then
  log "dropping every object in the $APP_USER schema"
  run_sql ECL db/reset.sql
else
  # Without --reset, refuse to install over an existing schema: CREATE TABLE
  # would fail half way and leave a mix of old and new objects.
  tables=$(sql_value ECL "SELECT COUNT(*) FROM user_tables")
  if ((tables > 0)); then
    die "the $APP_USER schema already has $tables tables; use --reset to rebuild it (drops all data)"
  fi
fi

log "installing schema objects (as $APP_USER)"
run_sql ECL db/install.sql

# Assign first, then log: a failing $(...) inside another command's arguments
# does not stop a set -e script, but a failing assignment does.
summary=$(sql_value ECL "SELECT (SELECT COUNT(*) FROM user_tables) || ' tables, '
  || (SELECT COUNT(*) FROM user_views) || ' views, '
  || (SELECT COUNT(*) FROM user_objects WHERE object_type = 'PACKAGE') || ' packages' FROM dual")
log "schema ready: $summary"
