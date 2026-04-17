---
phase: 21-blue-green-containers
reviewed: 2026-04-15T12:00:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - scripts/manage-containers.sh
  - docker/env-findclass-ssr.env
findings:
  critical: 0
  warning: 5
  info: 3
  total: 8
status: issues_found
---

# Phase 21: Code Review Report

**Reviewed:** 2026-04-15T12:00:00Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

Reviewed `scripts/manage-containers.sh` (541 lines, bash shell script for blue-green container lifecycle management) and `docker/env-findclass-ssr.env` (20 lines, environment variable template for findclass-ssr container).

Overall the script is well-structured with good practices: `set -euo pipefail`, proper quoting, `envsubst` with explicit variable allowlist, `nginx -t` validation before reload, and health check gates before traffic switch. The findings below are refinements around robustness and edge case handling rather than fundamental design flaws.

No critical (security/data-loss) issues found. The `envsubst` allowlist on line 90 correctly limits substitution to only the three intended variables, preventing accidental leakage of other shell environment variables into the container env file.

## Warnings

### WR-01: No trap to clean up temporary env file on script exit

**File:** `scripts/manage-containers.sh:82-91`
**Issue:** `prepare_env_file()` creates a temp file at `/tmp/findclass-ssr-${env}.env.$$` and returns its path. The cleanup (`rm -f "$env_file"` on line 157) happens at the end of `run_container()`. However, if the script exits unexpectedly between file creation (line 90) and cleanup (line 157) -- for example, `docker run` fails and `set -e` terminates the script -- the temp file containing database credentials remains in `/tmp/`. The script has no `trap` for EXIT to guarantee cleanup.

**Fix:**
```bash
# Add near the top of the script, after set -euo pipefail:
CLEANUP_FILES=()
cleanup_temp_files() {
  for f in "${CLEANUP_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f"
  done
}
trap cleanup_temp_files EXIT

# In prepare_env_file(), register the file:
prepare_env_file() {
  local env="$1"
  local tmp_file="/tmp/findclass-ssr-${env}.env.$$"
  # ... envsubst command ...
  CLEANUP_FILES+=("$tmp_file")
  echo "$tmp_file"
}
```

### WR-02: update_upstream writes temp file as current user, but ACTIVE_ENV_FILE uses sudo

**File:** `scripts/manage-containers.sh:169-175`
**Issue:** `update_upstream()` writes a temp file directly to `$UPSTREAM_CONF.tmp.$$` and `mv` replaces the original -- all without `sudo`. Meanwhile `set_active_env()` (lines 68-73) uses `sudo` for all file operations under `/opt/noda/`. This inconsistency suggests the upstream conf directory is writable by the current user, but if the script is ever run in a context where the nginx config directory requires elevated permissions, the `mv` on line 175 will silently fail. This is a consistency concern rather than an active bug since the current permissions apparently work.

**Fix:** If the upstream config is always user-writable, this is fine as-is. If it might need elevated permissions, mirror the `sudo tee + sudo mv` pattern from `set_active_env()`. Add a comment clarifying the permission expectation:
```bash
update_upstream() {
  local target_env="$1"
  # Note: config/nginx/snippets/ is expected to be user-writable (no sudo needed)
  local tmp_file="${UPSTREAM_CONF}.tmp.$$"
  ...
}
```

### WR-03: cmd_switch sets active env AFTER reload, creating window where state file disagrees with reality

**File:** `scripts/manage-containers.sh:489-492`
**Issue:** The switch sequence is: (1) update upstream file, (2) nginx -t, (3) nginx reload, (4) set_active_env. Between step 3 and step 4, the active env file still reflects the old environment while nginx is already routing to the new one. If the script crashes (OOM, SIGKILL) in this window, the state file is stale. On next `get_active_env()` call the system will think the old env is active.

**Fix:** Consider writing the state file before or atomically with the reload. Alternatively, document that this is an acceptable risk window:
```bash
# Option A: Write state file immediately before reload (slightly less accurate on reload failure)
set_active_env "$target_env"
reload_nginx

# Option B: Keep current order but add a recovery note in documentation
```
Given that `set -e` will cause exit on reload failure and the upstream file is already updated, Option A may be slightly safer because the state file will at least match the upstream config.

### WR-04: cmd_start does not update upstream or nginx when starting the active environment

**File:** `scripts/manage-containers.sh:273-306`
**Issue:** If the active container was stopped (e.g., after a host reboot or manual `cmd_stop`), and the user runs `cmd_start blue` to restart it, the upstream config and nginx routing are NOT updated. The upstream file may still reference the old container name, and if Docker assigned a different internal IP, nginx would route to a stale backend. This only matters if the container was removed and recreated (new internal IP), which is the case when using `docker run`.

**Fix:** After `run_container` and health check succeed in `cmd_start`, check if the started env is the active env and if so, update upstream and reload nginx:
```bash
# After health check passes, add:
local active_env
active_env=$(get_active_env)
if [ "$env" = "$active_env" ]; then
  update_upstream "$env"
  reload_nginx
  log_info "活跃环境 upstream 已刷新"
fi
```

### WR-05: Race condition on temp files using $$ (PID) in concurrent invocations

**File:** `scripts/manage-containers.sh:70,82,169`
**Issue:** Three temp file paths use `$$` as a uniqueness suffix. While `$$` protects against different processes, if the same script is somehow invoked twice in rapid succession from the same shell (e.g., two terminals), and both use the same env argument, they could collide on the same temp file path. Using `mktemp` would be more robust.

**Fix:**
```bash
# Replace /tmp/findclass-ssr-${env}.env.$$ with:
local tmp_file
tmp_file=$(mktemp "/tmp/findclass-ssr-${env}.env.XXXXXX")

# Similarly for the other two temp files:
tmp_file=$(mktemp "${UPSTREAM_CONF}.tmp.XXXXXX")
tmp_file=$(mktemp "$(dirname "$ACTIVE_ENV_FILE")/.active-env.tmp.XXXXXX")
```

## Info

### IN-01: cmd_logs passes "${@:3}" which fails with set -u on bash < 4.0

**File:** `scripts/manage-containers.sh:442`
**Issue:** `"${@:3}"` (array slice from position 3 onward) works in bash 4.0+, but on older bash versions this can be problematic. Since the project targets a Linux server (likely Debian/Ubuntu with bash 5.x), this is not a practical concern. However, if there are fewer than 3 arguments, the expansion produces nothing, which is the desired behavior.

**Fix:** No action needed for current deployment target. If portability to older bash is ever needed, replace with explicit argument forwarding logic.

### IN-02: RESEND_API_KEY defaults to empty string with ${RESEND_API_KEY:-}

**File:** `docker/env-findclass-ssr.env:19`
**Issue:** `RESEND_API_KEY=${RESEND_API_KEY:-}` means if the host environment variable is unset, the container receives an empty `RESEND_API_KEY=` line. This is safe behavior but means the application must handle an empty-string API key gracefully (as opposed to the variable being absent entirely). Since `env_file` in docker always sets the variable, the application cannot distinguish "unset" from "empty".

**Fix:** If the application treats empty and unset identically, this is fine. If there is a behavioral difference, consider either removing the line from the template when the key is not set, or adding a comment noting this behavior.

### IN-03: Step numbering in cmd_init jumps from conceptual to absolute

**File:** `scripts/manage-containers.sh:231-259`
**Issue:** `cmd_init()` has comments like "步骤 4/10" through "步骤 10/10", but there is no step 1/10 through 3/10. Steps 1-3 are the detection, validation, and confirmation logic above line 231 without step number labels. This is cosmetic and does not affect functionality.

**Fix:** Either renumber to "步骤 1/7" through "步骤 7/7", or add step labels to the earlier detection logic for consistency.

---

_Reviewed: 2026-04-15T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
