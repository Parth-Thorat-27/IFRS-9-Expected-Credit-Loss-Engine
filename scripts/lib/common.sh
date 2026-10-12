#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it, never run it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# What a script gets from it:
#   log, die       timestamped messages on stderr (and in $LOG_FILE once set)
#   require_env    stop early, with a clear message, when a setting is missing
#   run_sql        SQL*Plus inside the Oracle container through `docker exec`
#   wait_for_db    block until the ECL account can really log in
#   ROOT_DIR, PYTHON and every value from .env
#
# Strict mode is switched on here so every script fails the same way:
#   -e           stop at the first failing command; a batch must never carry on after an error
#   -E           let the ERR trap fire inside functions and subshells too
#   -u           an unset variable is a bug, not an empty string
#   -o pipefail  a pipeline fails when any command in it fails, not only the last one
set -Eeuo pipefail

# Sourcing twice would stack traps and re-read .env.
if [[ -n "${_ECL_COMMON_LOADED:-}" ]]; then return 0; fi
_ECL_COMMON_LOADED=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Git Bash on Windows rewrites any argument that looks like a Unix path
# (/nolog, /opt/ecl/...) into a Windows path before docker sees it. Turn that
# off. On Linux and WSL the variable does nothing.
export MSYS_NO_PATHCONV=1
# With the rewriting off, a native Windows program (python.exe, docker.exe)
# would read /c/Users/... as C:\c\Users\... So on Git Bash, keep ROOT_DIR in
# the C:/Users/... form that bash and Windows programs both understand, and
# build every path from it. cygpath exists only on Git Bash/Cygwin.
if command -v cygpath >/dev/null 2>&1; then ROOT_DIR="$(cygpath -m "$ROOT_DIR")"; fi
export ROOT_DIR

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# A script sets LOG_FILE to keep a log per run; until then lines go to stderr only.
LOG_FILE="${LOG_FILE:-}"

# log [INFO|WARN|ERROR] message...
log() {
  local level=INFO
  case "${1:-}" in INFO | WARN | ERROR) level="$1" && shift ;; esac
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  # stderr, so a caller can capture a function's real output with $(...)
  # without log lines mixed into it.
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE"; fi
}

# die [exit_code] message...    (exit code defaults to 1)
die() {
  local code=1
  if [[ $# -gt 1 && "$1" =~ ^[0-9]+$ ]]; then code="$1" && shift; fi
  log ERROR "$*"
  exit "$code"
}

# With set -e a failing command ends the script without saying why. The trap
# records the file, line and command first, which is what you need when you
# read a batch log the morning after.
_on_error() {
  log ERROR "exit $1 at ${BASH_SOURCE[1]:-?}:$2: $3"
}
trap '_on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
if [[ -f "$ROOT_DIR/.env" ]]; then
  # set -a exports everything the file defines, so docker, Python and child
  # scripts all see the same values. tr drops Windows line endings in case the
  # file was saved by a Windows editor ("ECL\r" is not a valid user name).
  set -a
  # shellcheck disable=SC1090,SC1091
  source <(tr -d '\r' <"$ROOT_DIR/.env")
  set +a
fi
ORACLE_CONTAINER="${ORACLE_CONTAINER:-ecl-oracle}"
ORACLE_SERVICE="${ORACLE_SERVICE:-FREEPDB1}"

# require_env NAME...   fail before doing any work if a setting is missing.
require_env() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  if ((${#missing[@]} > 0)); then
    die "missing setting(s): ${missing[*]} (copy .env.example to .env and fill them in)"
  fi
}

# The venv layout differs by platform: .venv/bin on Linux and WSL,
# .venv/Scripts on Windows (Git Bash). Otherwise use whatever python is on PATH.
if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  PYTHON="$ROOT_DIR/.venv/bin/python"
elif [[ -x "$ROOT_DIR/.venv/Scripts/python.exe" ]]; then
  PYTHON="$ROOT_DIR/.venv/Scripts/python.exe"
else
  PYTHON="$(command -v python3 || command -v python || echo python3)"
fi
export PYTHON

# ---------------------------------------------------------------------------
# SQL*Plus
# ---------------------------------------------------------------------------
# run_sql <ECL|SYSTEM> <db/file.sql | -> [script arguments...]
#
#   db/file.sql   run the file through the container's bind mount (/opt/ecl/db);
#                 extra arguments arrive in the script as &1, &2, ...
#   -             run SQL read from stdin, for short inline statements
#
# Prints the SQL*Plus output on stdout. Returns non-zero if anything failed.
run_sql() {
  (($# >= 2)) || die 2 "usage: run_sql <ECL|SYSTEM> <db/file.sql|-> [args...]"
  local account="$1" src="$2"
  shift 2

  local user pass
  case "$account" in
    ECL)
      require_env APP_USER APP_USER_PASSWORD
      user="$APP_USER" pass="$APP_USER_PASSWORD"
      ;;
    SYSTEM)
      require_env ORACLE_PASSWORD
      user=SYSTEM pass="$ORACLE_PASSWORD"
      ;;
    *) die 2 "run_sql: unknown account '$account' (use ECL or SYSTEM)" ;;
  esac

  local what="inline SQL" run_line=""
  if [[ "$src" != "-" ]]; then
    # Only db/ is mounted into the container, so SQL files must live there.
    [[ "$src" == db/* ]] || die 2 "run_sql: $src is not under db/"
    [[ -f "$ROOT_DIR/$src" ]] || die "run_sql: $src not found"
    what="$src"
    run_line="@/opt/ecl/$src${*:+ $*}"
  fi

  local rc=0
  # The password travels on stdin (sqlplus /nolog, then CONNECT), never on the
  # command line, so it can't be read from `ps` inside the container.
  # WHENEVER SQLERROR comes first so that even a failed CONNECT makes SQL*Plus
  # exit with an error code instead of carrying on unconnected.
  {
    printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\n'
    printf 'WHENEVER OSERROR EXIT FAILURE\n'
    printf 'CONNECT %s/"%s"@//localhost:1521/%s\n' "$user" "$pass" "$ORACLE_SERVICE"
    if [[ -n "$run_line" ]]; then printf '%s\n' "$run_line"; else cat; fi
    printf '\nEXIT SUCCESS\n'
  } | docker exec -i "$ORACLE_CONTAINER" sqlplus -S -L /nolog 2>&1 | _sqlplus_filter || rc=$?

  if ((rc != 0)); then log ERROR "SQL*Plus failed running $what as $user (error lines above)"; fi
  return "$rc"
}

# Passes SQL*Plus output through line by line (and into $LOG_FILE), and exits
# non-zero if it saw an error that WHENEVER SQLERROR does not catch:
#  - SQL*Plus's own errors (SP2-nnnn, such as a missing @file) are not SQL errors;
#  - "created with compilation errors" is only a warning to SQL*Plus;
#  - the exit code is SQLCODE mod 256, so ORA-01536 (1536 = 6 x 256) would exit 0.
# Filtering the stream keeps output live and needs no temp file, so nothing is
# left behind when a run is killed half way.
_sqlplus_filter() {
  awk -v logfile="$LOG_FILE" '
    { print; fflush(); if (logfile != "") print >> logfile }
    /^(SP2-[0-9]+|ORA-[0-9]+|PLS-[0-9]+)/ || /with compilation errors/ { failed = 1 }
    END { exit failed ? 3 : 0 }'
}

# wait_for_db [timeout_seconds]
# The container health check turns green as soon as the database is open,
# which can be a few seconds before the gvenzl entrypoint has finished creating
# the ECL account. A real login is the test that matters, so poll that.
wait_for_db() {
  local timeout="${1:-300}" waited=0
  # LOG_FILE is blanked for the probe so a slow start doesn't fill the run log
  # with expected login failures.
  until LOG_FILE='' run_sql ECL - <<<"SELECT 1 FROM dual;" >/dev/null 2>&1; do
    if ((waited >= timeout)); then
      die "database not ready after ${timeout}s (check: docker logs $ORACLE_CONTAINER)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
