---
phase: 10-b2
reviewed: 2026-04-11T00:00:00Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - deploy/crontab
  - deploy/Dockerfile.noda-ops
  - scripts/backup/lib/health.sh
  - scripts/backup/lib/restore.sh
  - scripts/backup/lib/test-verify.sh
findings:
  critical: 2
  warning: 4
  info: 3
  total: 9
status: issues_found
---

# Phase 10-B2: Code Review Report

**Reviewed:** 2026-04-11T00:00:00Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed 5 files related to B2 backup bug fixes (BFIX-01/02/03). The crontab path fix (BFIX-01) and Dockerfile are clean. However, two critical SQL injection vulnerabilities were found in `health.sh` where user-controlled data (`$db_name`) is interpolated directly into SQL strings without quoting. Additionally, several logic issues were identified in `restore.sh` and `test-verify.sh` related to B2 subdirectory path handling, incomplete container/host environment detection, and a potential port leak in the host-mode restore path.

## Critical Issues

### CR-01: SQL Injection in health.sh get_database_size()

**File:** `scripts/backup/lib/health.sh:106`
**Issue:** The `$db_name` parameter is interpolated directly into a SQL query string without quoting. If a database name contains a single quote or other SQL metacharacters, this allows SQL injection. This function is also called from the container-internal path at line 181 with the same pattern.

```bash
docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
  "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' '
```

The `$db_name` value comes from querying `pg_database.datname` and iterating the results (lines 124-125, 173-176), which in normal operation only produces legitimate names. However, this pattern is unsafe in principle and should use parameterized queries.

**Fix:**
```bash
# Use psql variable binding instead of string interpolation
docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
  "SELECT pg_database_size(\$(psql_escape_identifier "$db_name"));" 2>/dev/null | tr -d ' '

# Or use psql -v for safe variable passing:
docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -v "dbname=$db_name" -c \
  "SELECT pg_database_size(current_setting('script_variables.dbname')::text);" 2>/dev/null | tr -d ' '
```

### CR-02: SQL Injection in test-verify.sh verify_data_exists()

**File:** `scripts/backup/lib/test-verify.sh:287`
**Issue:** The `$table` variable (obtained from `information_schema.tables`) is interpolated directly into a `SELECT COUNT(*) FROM $table` query without quoting. A table name containing special characters would break the query or allow injection.

```bash
count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
  -d "$test_db" -t -c "
    SELECT COUNT(*) FROM $table;
  " 2>/dev/null | xargs || echo "0")
```

**Fix:**
```bash
# Quote the table identifier properly
count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
  -d "$test_db" -t -c "
    SELECT COUNT(*) FROM \"${table}\";
  " 2>/dev/null | xargs || echo "0")
```

## Warnings

### WR-01: list_backups_b2() regex does not match B2 subdirectory paths

**File:** `scripts/backup/lib/restore.sh:61`
**Issue:** The regex `^([^_]+)_([0-9]{8})_([0-9]{6})\.(sql|dump)$` uses `^` anchor which expects the filename to start at the beginning of the string. However, `rclone ls` returns paths like `2026/04/07/keycloak_20260407_030000.dump` -- the filename has a `YYYY/MM/DD/` prefix from B2 subdirectory storage (BFIX-03). The `$filename` from `read -r size filename` will be the full relative path, not just the basename. This means `list_backups_b2()` silently skips all backups stored in date subdirectories and shows an empty list, breaking the restore workflow.

Note: The `download_backup()` function at line 127 correctly handles this with `--include "**/$backup_filename"`, but `list_backups_b2()` and `download_latest_backup()` (in test-verify.sh) both depend on parsing the list output.

**Fix:**
```bash
# Change the regex to allow path prefix before the filename
if [[ $filename =~ /?([^/_]+)_([0-9]{8})_([0-9]{6})\.(sql|dump)$ ]]; then
```

Or extract the basename first:
```bash
echo "$backups" | while read -r size filename; do
  local base_filename
  base_filename=$(basename "$filename")
  if [[ $base_filename =~ ^([^_]+)_([0-9]{8})_([0-9]{6})\.(sql|dump)$ ]]; then
```

### WR-02: Inconsistent container environment detection in health.sh

**File:** `scripts/backup/lib/health.sh:96-107` and `scripts/backup/lib/health.sh:349-358`
**Issue:** The functions `get_database_size()`, `get_total_database_size()`, and `list_databases()` unconditionally use `docker exec` to run psql commands, regardless of whether the script is running inside a container or on the host. In contrast, `check_disk_space()` (line 161) and `check_postgres_connection()` (line 50) correctly check `/.dockerenv` and branch accordingly.

When these functions are called from inside the noda-ops container (the primary runtime for backups per the crontab config), `docker exec` will fail because Docker CLI is not installed in the Alpine container. This means `get_database_size()` and `get_total_database_size()` silently return empty values when running inside the container, and the host-mode disk check path at line 227-307 will use incorrect data.

The container-internal disk check at lines 161-225 duplicates the database size query using direct `psql` instead of `docker exec`, which works correctly. But the standalone functions are still broken for container usage.

**Fix:** Add environment detection to `get_database_size()`, `get_total_database_size()`, and `list_databases()` similar to `check_postgres_connection()`:
```bash
get_database_size() {
  local db_name="$1"
  local postgres_host postgres_user
  postgres_host=$(get_postgres_host)
  postgres_user=$(get_postgres_user)

  if [[ -f /.dockerenv ]]; then
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$postgres_host" -U "$postgres_user" \
      -d postgres -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' '
  else
    docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
      "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' '
  fi
}
```

### WR-03: restore_database() extracts wrong target_db when backup_file has path prefix

**File:** `scripts/backup/lib/restore.sh:189`
**Issue:** When `backup_path` is something like `2026/04/07/keycloak_20260407_030000.dump`, the regex `^([^/]+)_[0-9]{8}_[0-9]{6}\.(sql|dump)$` will not match because the path contains slashes. The `target_db` extraction falls through to the error case at line 193. The `$backup_file` variable at this point holds the full local path (e.g., `/tmp/xxx/2026/04/07/keycloak_...dump`), not just the filename. The regex should operate on the basename.

```bash
if [[ $backup_file =~ ^([^/]+)_[0-9]{8}_[0-9]{6}\.(sql|dump)$ ]]; then
  target_db="${BASH_REMATCH[1]}"
```

**Fix:**
```bash
local base_name
base_name=$(basename "$backup_file")
if [[ $base_name =~ ^([^_]+)_[0-9]{8}_[0-9]{6}\.(sql|dump)$ ]]; then
  target_db="${BASH_REMATCH[1]}"
```

### WR-04: test-verify.sh source order may load constants.sh unconditionally

**File:** `scripts/backup/lib/test-verify.sh:17-25`
**Issue:** Line 17 conditionally loads `constants.sh` (guarding with `EXIT_SUCCESS` check), but line 22 unconditionally loads `log.sh`, line 23 loads `config.sh`, and line 24 loads `restore.sh`. If `restore.sh` also sources `config.sh` (it does, at line 17), the `config.sh` global variables (`POSTGRES_HOST`, `B2_ACCOUNT_ID`, etc.) will be overwritten with defaults, potentially losing values set by an earlier `load_config()` call. The dependency chain is: `test-verify.sh` -> `restore.sh` -> `config.sh` + `cloud.sh` -> `config.sh` again.

While `config.sh` uses `set -euo pipefail` and does not use `readonly` for its globals, re-sourcing `config.sh` will reset all variables to defaults, undoing any `load_config()` call that happened before `test-verify.sh` was sourced.

**Fix:** Add the same conditional guard pattern to all library sources in `test-verify.sh`:
```bash
# Already guarded:
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$_TEST_VERIFY_LIB_DIR/constants.sh"
fi

# Guard config.sh:
if ! type get_postgres_host &>/dev/null; then
  source "$_TEST_VERIFY_LIB_DIR/config.sh"
fi

# For libraries without side-effect guards, ensure load_config() is called
# after all sources complete, before any function that reads config values.
```

## Info

### IN-01: bc not guaranteed in Alpine container

**File:** `scripts/backup/lib/health.sh:136` and `scripts/backup/lib/health.sh:243`
**Issue:** The code uses `bc` for floating-point division (`echo "scale=2; $db_size / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"`). The Dockerfile at `deploy/Dockerfile.noda-ops` does not install `bc` in the Alpine image. The `|| echo "0"` fallback handles the missing binary gracefully, but the size display will always show "0" inside the container.

**Fix:** Add `bc` to the `apk add` line in `Dockerfile.noda-ops`, or use integer-only arithmetic for the display:
```dockerfile
RUN apk add --no-cache \
    bash curl wget jq coreutils rclone dcron supervisor \
    ca-certificates postgresql-client gnupg bc
```

### IN-02: verify_backup_integrity() stat command portability

**File:** `scripts/backup/lib/health.sh:342` (actually in restore.sh:342)
**Issue:** The code uses `stat -f%z` (macOS) and `stat -c%s` (Linux) as a fallback. Inside the Alpine container, only `stat -c%s` works. The `||` fallback handles this correctly, but the macOS form will always fail first. This is a minor efficiency concern, not a bug.

### IN-03: download_latest_backup() extracts wrong field for backup_path

**File:** `scripts/backup/lib/test-verify.sh:128`
**Issue:** `list_b2_backups` output format is `size path` (two fields). The code does `echo "$backups" | awk '{print $2}'` which works for flat paths. But with B2 subdirectory paths like `2026/04/07/db.dump`, the awk field split still produces the correct full path (it's the second field). This is correct as-is, but is fragile -- if the output format ever includes additional columns, it would break. Not a bug today.

---

_Reviewed: 2026-04-11T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
