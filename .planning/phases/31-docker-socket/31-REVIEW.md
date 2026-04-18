---
phase: 31-docker-socket
reviewed: 2026-04-18T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - scripts/undo-permissions.sh
  - scripts/setup-jenkins.sh
  - scripts/apply-file-permissions.sh
findings:
  critical: 1
  warning: 3
  info: 3
  total: 7
status: issues_found
---

# Phase 31: Code Review Report

**Reviewed:** 2026-04-18
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

Reviewed three bash scripts for Docker socket permission convergence: an undo/rollback safety net, a Jenkins lifecycle management script, and a one-stop permission application script.

One critical security issue found: command injection via Groovy code interpolation in the password reset function. Three warnings: a `local` variable scoping bug in a pipe subshell, no confirmation prompt before the destructive `undo` operation, and the undo logic does not actually read the backup file it validates. Three info-level items noted.

## Critical Issues

### CR-01: Groovy Code Injection via Unsanitized Password Interpolation

**File:** `scripts/setup-jenkins.sh:491-499`
**Issue:** The `cmd_reset_password` function writes the user-supplied password directly into a Groovy script using an unquoted heredoc (`<<GROOVY` instead of `<<'GROOVY'`). The variable `${new_password}` is expanded by bash before being written into the Groovy source file. This creates a code injection vulnerability: a password containing single quotes or Groovy syntax can break out of the string literal and execute arbitrary Groovy code inside the Jenkins JVM (which runs as the jenkins system user with Docker socket access).

For example, a password like `'); Runtime.getRuntime().exec('touch /tmp/pwned'); println ('x` would execute an arbitrary OS command.

**Fix:**
Replace the heredoc-based Groovy script generation with proper escaping, or pass the password via an environment variable and read it in Groovy:

```bash
# Option A: Pass password via environment variable (preferred)
local groovy_script
groovy_script=$(mktemp /tmp/reset-jenkins-password.groovy.XXXXXX)
cat > "$groovy_script" <<'GROOVY'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def realm = instance.getSecurityRealm()
def user = realm.getUser('admin')
if (user != null) {
    user.setPassword(System.getenv('JENKINS_NEW_PASSWORD'))
    instance.save()
    println 'Password reset successful'
} else {
    println 'ERROR: admin user not found'
    System.exit(1)
}
GROOVY

reset_output=$(JENKINS_NEW_PASSWORD="$new_password" sudo -u jenkins java -jar "$cli_jar" -s "http://localhost:${JENKINS_PORT}/" groovy < "$groovy_script" 2>&1)
```

## Warnings

### WR-01: `local` Variable Declared Inside Pipe Subshell Is Lost

**File:** `scripts/undo-permissions.sh:100`
**Issue:** Inside `backup_current_state()`, the line `local override_dir="/etc/systemd/system/docker.service.d"` appears inside a `{ ... } | sudo tee` block. In bash, each side of a pipe runs in a subshell. The `local` keyword works in the subshell but the variable is scoped to that subshell, not the parent function. In this specific case the variable is only used within the same subshell block so the bug is latent -- it will not cause a runtime failure. However, if anyone moves the `$override_dir` reference outside the pipe block, it would silently resolve to empty. This is a code smell that signals a fragile pattern.

**Fix:**
Declare the variable before the pipe block and reference it inside:

```bash
backup_current_state() {
  local override_dir="/etc/systemd/system/docker.service.d"
  # ...
  {
    # ... other lines ...
    if [[ "$(uname)" != "Darwin" ]]; then
      if [ -d "$override_dir" ]; then
        sudo cat "$override_dir"/*.conf 2>/dev/null || echo "无 override 文件"
      else
        echo "无 override 目录"
      fi
    else
      echo "N/A (非 Linux)"
    fi
    # ...
  } | sudo tee "$BACKUP_FILE" > /dev/null
}
```

### WR-02: Destructive `undo` Command Has No Confirmation Prompt

**File:** `scripts/undo-permissions.sh:129-190`
**Issue:** The `undo_permissions` function performs six destructive operations (restoring socket ownership, removing systemd overrides, restarting Docker, modifying file permissions, changing group membership, restarting Jenkins) without any confirmation prompt. A simple typo running `undo-permissions.sh undo` instead of `undo-permissions.sh backup` would immediately restart Docker and Jenkins in production, causing service disruption.

**Fix:**
Add an interactive confirmation before proceeding:

```bash
undo_permissions() {
  # ... existing backup file check ...
  log_warn "即将执行以下破坏性操作:"
  log_warn "  1. 恢复 Docker socket 属组为 root:docker"
  log_warn "  2. 移除 systemd override 并重启 Docker"
  log_warn "  3. 恢复脚本权限"
  log_warn "  4. 将 jenkins 加入 docker 组并重启 Jenkins"
  echo ""
  read -rp "确认执行回滚？(yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    log_info "回滚已取消"
    exit 0
  fi
  # ... rest of function ...
}
```

### WR-03: `undo_permissions` Validates Backup File But Never Reads It

**File:** `scripts/undo-permissions.sh:134-139` and `145-190`
**Issue:** The `undo_permissions` function checks that `$BACKUP_FILE` exists (lines 135-139) and prints its contents (lines 141-143), but the actual restore operations on lines 145-190 use hardcoded values (`root:docker`, `755`, etc.) without parsing any data from the backup file. If the backup file records different permissions (e.g., `0750` instead of `0755`), those values would be ignored during restore. The backup file becomes cosmetic rather than functional.

**Fix:** Either (a) parse the backup file to restore the exact recorded values, or (b) remove the backup file check from `undo_permissions` since the hardcoded restore is intentional, and update the documentation to clarify that undo restores to known-good defaults (not the exact pre-change state).

## Info

### IN-01: `setup-jenkins.sh` Uses `$0` Which May Show Full Path in Help Messages

**File:** `scripts/setup-jenkins.sh:199,373,452`
**Issue:** The script references `$0` in user-facing help messages. Depending on how the script is invoked, `$0` may show an absolute path (e.g., `/Users/user/noda-infra/scripts/setup-jenkins.sh`) rather than a relative invocation (e.g., `bash scripts/setup-jenkins.sh`). This is cosmetic only.

**Fix:** Consider using `basename "$0"` or a relative path for cleaner help output.

### IN-02: Temporary Groovy Script Not Cleaned Up on `set -e` Failure Path

**File:** `scripts/setup-jenkins.sh:490,520`
**Issue:** The temporary file created by `mktemp` on line 490 is cleaned up on the explicit error path (line 515: `rm -f "$groovy_script"`) and the success path (line 520). However, if `set -e` triggers an exit from between these two points (e.g., a future code addition that fails), the temp file containing the password hash operation would remain in `/tmp`. The risk is low because the script does not contain the plaintext password in the Groovy file after the CR-01 fix, but it is still good practice to use a `trap` for cleanup.

**Fix:** Add a trap at the start of `cmd_reset_password`:
```bash
groovy_script=$(mktemp /tmp/reset-jenkins-password.groovy.XXXXXX)
trap 'rm -f "$groovy_script"' EXIT
```

### IN-03: Duplicated LOCKED_SCRIPTS List Across Two Files

**File:** `scripts/undo-permissions.sh:21-26` and `scripts/apply-file-permissions.sh:20-25`
**Issue:** The `LOCKED_SCRIPTS` array is defined identically in both files. If a script is added to one but not the other, the undo operation would not restore the correct permissions for that file.

**Fix:** Consider extracting the list into a shared file (e.g., `scripts/lib/locked-scripts.sh`) that both scripts source:
```bash
# scripts/lib/locked-scripts.sh
LOCKED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
    "$PROJECT_ROOT/scripts/pipeline-stages.sh"
    "$PROJECT_ROOT/scripts/manage-containers.sh"
)
```

---

_Reviewed: 2026-04-18_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
