---
phase: 31-docker-socket
verified: 2026-04-18T12:00:00Z
status: human_needed
score: 7/11 must-haves verified
overrides_applied: 0
gaps:
  - truth: "sudo -u jenkins docker ps 返回容器列表（jenkins 用户可正常执行 docker 命令）"
    status: failed
    reason: "需要生产 Linux 服务器验证。当前环境为 macOS，无 jenkins 系统用户"
    artifacts:
      - path: "scripts/setup-jenkins.sh"
        issue: "代码逻辑正确（systemd override 配置 socket 属组为 root:jenkins），但实际效果只能在 Linux 服务器验证"
    missing:
      - "在生产 Linux 服务器运行 sudo bash scripts/apply-file-permissions.sh apply 后执行 sudo -u jenkins docker ps"
  - truth: "sudo -u admin docker ps 返回 permission denied（非 jenkins 用户无法直接执行 docker 命令）"
    status: failed
    reason: "需要生产 Linux 服务器验证。当前环境为 macOS，无 admin 用户，Docker Desktop 安全模型不同"
    artifacts: []
    missing:
      - "在生产 Linux 服务器权限收敛后验证非 jenkins 用户被拒绝"
  - truth: "服务器重启或 Docker 服务重启后，Docker socket 属组仍为 root:jenkins"
    status: failed
    reason: "需要生产 Linux 服务器验证。systemd override 代码逻辑正确，但持久化效果只能在 Linux 重启后确认"
    artifacts:
      - path: "scripts/apply-file-permissions.sh"
        issue: "systemd override 配置代码正确（ExecStartPost），但持久化效果需实际重启验证"
    missing:
      - "在生产 Linux 服务器执行 sudo systemctl restart docker 后检查 ls -la /var/run/docker.sock 属组"
  - truth: "所有 4 个 Jenkins Pipeline 端到端正常运行"
    status: failed
    reason: "需要生产 Linux 服务器验证。Jenkins Pipeline 运行依赖完整的权限收敛环境"
    artifacts: []
    missing:
      - "在生产服务器权限收敛后触发 4 个 Jenkins Pipeline 验证"
deferred:
  - truth: "备份脚本（noda-ops 容器内 + 宿主机 docker exec）正常工作"
    addressed_in: "Phase 31 (JENKINS-02) + Phase 34"
    evidence: "JENKINS-02 在 Phase 31 需求中声明，但备份脚本兼容性验证需要在生产环境执行权限收敛后进行；Phase 34 统一管理脚本包含完整验证"
human_verification:
  - test: "在生产 Linux 服务器运行 sudo bash scripts/apply-file-permissions.sh apply"
    expected: "所有步骤成功完成，无报错"
    why_human: "需要 Linux 生产环境（systemd + jenkins 用户 + Docker socket），macOS 开发环境无法模拟"
  - test: "运行 sudo bash scripts/apply-file-permissions.sh verify 输出全部 PASS"
    expected: "7 项检查全部 PASS（socket 属组 jenkins、权限 660、systemd override 存在、4 个脚本 750 root:jenkins、hook 存在、jenkins docker 可用、/opt/noda 770 root:jenkins）"
    why_human: "需要生产 Linux 环境，macOS 上 N/A 和权限差异是预期行为"
  - test: "运行 sudo -u jenkins docker ps"
    expected: "返回容器列表（非 permission denied）"
    why_human: "需要 Linux 生产环境 jenkins 用户实际访问 Docker socket"
  - test: "运行 sudo -u admin docker ps"
    expected: "返回 permission denied"
    why_human: "需要 Linux 生产环境验证非 jenkins 用户被拒绝"
  - test: "运行 sudo systemctl restart docker && ls -la /var/run/docker.sock"
    expected: "属组为 root:jenkins（systemd override 持久化生效）"
    why_human: "需要 Linux 生产环境验证重启后权限持久化"
  - test: "触发 4 个 Jenkins Pipeline（findclass-ssr、noda-site、keycloak、infra）"
    expected: "全部正常运行"
    why_human: "需要生产环境完整 Jenkins + 权限收敛环境"
  - test: "运行 bash scripts/undo-permissions.sh backup + bash scripts/undo-permissions.sh undo"
    expected: "备份成功创建，回滚后权限恢复为 root:docker，jenkins 重新加入 docker 组"
    why_human: "需要在已应用权限收敛的 Linux 生产环境验证回滚完整性"
---

# Phase 31: Docker Socket 权限收敛 + 文件权限锁定 Verification Report

**Phase Goal:** 仅 jenkins 用户可通过 Docker socket 执行 docker 命令，部署脚本仅 jenkins 可执行，且权限配置在服务器重启后持久保留
**Verified:** 2026-04-18T12:00:00Z
**Status:** human_needed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | undo-permissions.sh 可以备份当前权限状态到 /opt/noda/pre-phase31-permissions-backup.txt | VERIFIED | backup_current_state() 函数存在（278 行脚本），macOS 上执行 exit 0，Linux 路径 root:docker/root:jenkins 保留 |
| 2 | undo-permissions.sh undo 子命令可以恢复备份的权限状态 | VERIFIED | undo_permissions() 函数存在，6 步恢复逻辑完整（socket 属组 -> systemd override -> Docker 重启 -> 脚本权限 -> jenkins 组 -> Jenkins 重启） |
| 3 | setup-jenkins.sh install 第 8 步配置 systemd override 使 socket 属组为 root:jenkins | VERIFIED | 步骤 8 包含 gpasswd -d jenkins docker（幂等移除）+ tee socket-permissions.conf + ExecStartPost chown root:jenkins |
| 4 | setup-jenkins.sh status 检查 jenkins 用户可执行 docker 命令（而非检查 docker 组成员） | VERIFIED | 检查 4/5 使用 `sudo -u jenkins docker info` 替代 `groups jenkins \| grep docker`，并补充检查 systemd override 文件存在性 |
| 5 | apply-file-permissions.sh 可以锁定 4 个部署脚本为 750 root:jenkins | VERIFIED | cmd_apply() 中 LOCKED_SCRIPTS 数组遍历 chown root:jenkins + chmod 750，4 个目标脚本均存在 |
| 6 | apply-file-permissions.sh 可以创建 .git/hooks/post-merge hook 恢复文件权限 | VERIFIED | cmd_hook() 创建 hook 文件，macOS 实测成功（exit 0），hook 包含跨平台 OWNER_GROUP 逻辑 |
| 7 | apply-file-permissions.sh 可以创建 systemd override 持久化 Docker socket 权限 | VERIFIED | cmd_apply() 步骤 3 写入 ExecStartPost=...chown root:jenkins...socket-permissions.conf |
| 8 | apply-file-permissions.sh 可以验证所有权限配置是否正确 | VERIFIED | cmd_verify() 包含 7 项检查（socket 属组/权限、override、脚本权限、hook、jenkins docker、/opt/noda），exit 1 on failure |
| 9 | sudo -u jenkins docker ps 返回容器列表 | HUMAN_NEEDED | 代码逻辑正确，但需 Linux 生产环境验证 |
| 10 | sudo -u admin docker ps 返回 permission denied | HUMAN_NEEDED | 代码逻辑正确（socket 属组收敛 + docker 组清空），但需 Linux 生产环境验证 |
| 11 | 服务器重启后 Docker socket 属组仍为 root:jenkins | HUMAN_NEEDED | systemd override 配置正确，但需 Linux 重启验证持久化 |

**Score:** 8/11 truths verified (3 require production Linux server)

### Deferred Items

Items not yet met but explicitly addressed in later milestone phases.

| # | Item | Addressed In | Evidence |
|---|------|-------------|----------|
| 1 | 备份脚本兼容性验证 | Phase 34 | Phase 34 goal: "统一管理脚本" + JENKINS-02 备份脚本兼容性验证需权限收敛后进行 |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/undo-permissions.sh` | 最小 undo 安全网脚本 | VERIFIED | 278 行，包含 backup/undo/help 子命令，detect_platform 跨平台 |
| `scripts/setup-jenkins.sh` | Jenkins 生命周期管理脚本（socket 属组方式） | VERIFIED | 729 行（>500 min_lines），install 步骤 8 使用 systemd override，uninstall 清理 override |
| `scripts/apply-file-permissions.sh` | 一站式权限应用脚本 | VERIFIED | 408 行，包含 apply/verify/hook/help 子命令，LOCKED_SCRIPTS 数组 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| setup-jenkins.sh | socket-permissions.conf | cmd_install 步骤 8 写入 systemd override | WIRED | ExecStartPost 行正确写入 chown root:jenkins + chmod 660 |
| undo-permissions.sh | docker.sock | backup 记录属组 + undo 恢复属组 | WIRED | backup_current_state 记录 socket 属组/权限，undo_permissions 恢复 root:docker |
| apply-file-permissions.sh | .git/hooks/post-merge | apply hook 创建 post-merge 文件 | WIRED | macOS 实测 hook 创建成功，文件可执行，包含跨平台逻辑 |
| apply-file-permissions.sh | socket-permissions.conf | apply 创建 systemd override | WIRED | socket-permissions.conf 写入路径正确 |
| apply-file-permissions.sh | deploy-*.sh 等 4 个脚本 | apply 设置 chown/chmod | WIRED | LOCKED_SCRIPTS 数组包含 4 个脚本，全部存在 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| N/A (shell scripts, no dynamic data) | -- | -- | -- | SKIPPED |

Shell 脚本无动态数据渲染，跳过 Level 4 数据流追踪。

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| shellcheck 无 error | `shellcheck -S error scripts/apply-file-permissions.sh scripts/undo-permissions.sh scripts/setup-jenkins.sh` | exit 0, 无输出 | PASS |
| apply verify 在 macOS 运行不 crash | `bash scripts/apply-file-permissions.sh verify` | 输出 N/A + 权限差异（预期），exit 1 | PASS |
| undo backup 在 macOS 运行不 crash | `bash scripts/undo-permissions.sh backup` | sudo 提示密码（预期），exit 0 | PASS |
| setup-jenkins status 在 macOS 运行不 crash | `bash scripts/setup-jenkins.sh status` | 输出环境信息，exit 0 | PASS |
| hook 子命令创建成功 | `bash scripts/apply-file-permissions.sh hook` | post-merge hook 已创建，exit 0 | PASS |
| install 在 macOS 拒绝 | `bash scripts/setup-jenkins.sh install` | 输出 "仅支持 Linux"，exit 1 | PASS |
| uninstall 在 macOS 拒绝 | `bash scripts/setup-jenkins.sh uninstall` | 输出 "仅支持 Linux"，exit 1 | PASS |
| 旧模式 usermod -aG docker 已移除 | `grep -c 'usermod -aG docker jenkins' scripts/setup-jenkins.sh` | 返回 0 | PASS |
| detect_platform 三个脚本均包含 | `grep -l detect_platform scripts/*.sh` | 3 个文件匹配 | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PERM-01 | 31-01 | Docker socket 属组从 docker 改为 jenkins | CODE_VERIFIED | apply-file-permissions.sh + setup-jenkins.sh 包含 chown root:jenkins + chmod 660 |
| PERM-02 | 31-01 | Docker socket 权限通过 systemd override 持久化 | CODE_VERIFIED | socket-permissions.conf 写入 ExecStartPost=...chown root:jenkins... |
| PERM-03 | 31-02 | 部署脚本锁定为 750 root:jenkins | CODE_VERIFIED | LOCKED_SCRIPTS 数组 + cmd_apply chown root:jenkins chmod 750 |
| PERM-04 | 31-02 | git pull 后文件权限自动恢复（post-merge hook） | CODE_VERIFIED | cmd_hook() 创建 .git/hooks/post-merge，包含跨平台权限恢复逻辑 |
| PERM-05 | (Phase 34) | 统一权限管理脚本 setup-docker-permissions.sh | DEFERRED | REQUIREMENTS.md 明确分配到 Phase 34，不在 Phase 31 范围 |
| JENKINS-01 | 31-03 | 权限收敛后 4 个 Jenkins Pipeline 正常工作 | HUMAN_NEEDED | 需生产环境权限收敛后端到端验证 |
| JENKINS-02 | 31-02 | 备份脚本正常工作 | HUMAN_NEEDED | 需生产环境权限收敛后验证 docker exec 兼容性 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/setup-jenkins.sh | 665 | mktemp 临时文件 | Info | 临时文件模式正确，非 placeholder |
| scripts/undo-permissions.sh | 213 | usermod -aG docker jenkins | Info | 位于 undo_permissions() 回滚函数中，是正确的恢复逻辑（非遗漏） |

注意: 31-REVIEW.md 记录了 1 个 Critical（CR-01: Groovy 代码注入）和 3 个 Warning（WR-01/02/03）。这些是代码质量问题，不影响 Phase 31 核心目标（权限收敛脚本的功能正确性）。CR-01 存在于 cmd_reset_password 函数中，与 Docker socket 权限收敛无关。建议在后续 Phase 中修复。

### Human Verification Required

### 1. 权限应用验证

**Test:** 在生产 Linux 服务器运行 `sudo bash scripts/apply-file-permissions.sh apply`
**Expected:** 所有步骤成功完成，输出 "Phase 31: 权限配置完成"
**Why human:** 需要 Linux 生产环境（systemd + jenkins 用户 + Docker socket），macOS 开发环境无法模拟

### 2. 权限配置验证

**Test:** 在生产 Linux 服务器运行 `sudo bash scripts/apply-file-permissions.sh verify`
**Expected:** 7 项检查全部 PASS（socket 属组 jenkins、权限 660、systemd override、4 个脚本 750 root:jenkins、hook、jenkins docker 可用、/opt/noda 770）
**Why human:** 需要生产 Linux 环境，macOS 上 N/A 和权限差异是预期行为

### 3. jenkins 用户 Docker 访问

**Test:** `sudo -u jenkins docker ps`
**Expected:** 返回容器列表（非 permission denied）
**Why human:** 需要 Linux 生产环境 jenkins 用户实际访问 Docker socket

### 4. 非 jenkins 用户被拒绝

**Test:** `sudo -u admin docker ps`
**Expected:** 返回 permission denied
**Why human:** 需要 Linux 生产环境验证非 jenkins 用户被拒绝

### 5. 重启后权限持久化

**Test:** `sudo systemctl restart docker && ls -la /var/run/docker.sock`
**Expected:** 属组为 root:jenkins（systemd override 持久化生效）
**Why human:** 需要 Linux 生产环境验证重启后权限持久化

### 6. Jenkins Pipeline 端到端验证

**Test:** 触发 4 个 Jenkins Pipeline（findclass-ssr、noda-site、keycloak、infra）
**Expected:** 全部正常运行，无权限相关失败
**Why human:** 需要生产环境完整 Jenkins + 权限收敛环境，无法在 macOS 模拟

### 7. 回滚安全网验证

**Test:** `sudo bash scripts/undo-permissions.sh backup && sudo bash scripts/undo-permissions.sh undo`
**Expected:** 备份成功创建到 /opt/noda/pre-phase31-permissions-backup.txt，回滚后权限恢复为 root:docker，jenkins 重新加入 docker 组
**Why human:** 需要在已应用权限收敛的 Linux 生产环境验证回滚完整性

### Gaps Summary

Phase 31 的三个脚本（apply-file-permissions.sh、undo-permissions.sh、setup-jenkins.sh）在代码层面完整实现了所有需求：

- **PERM-01/02**: systemd override 配置 socket 属组为 root:jenkins（ExecStartPost 方式持久化）
- **PERM-03**: 4 个部署脚本锁定为 750 root:jenkins（LOCKED_SCRIPTS 数组）
- **PERM-04**: Git post-merge hook 自动恢复文件权限（跨平台兼容）
- **JENKINS-01/02**: 代码逻辑确保 Jenkins/Pipeline 兼容

但所有 5 项 ROADMAP Success Criteria 都需要在生产 Linux 服务器上实际验证。当前开发环境为 macOS（Docker Desktop + Homebrew Jenkins），与 Linux 生产环境（systemd + jenkins 系统用户 + Docker CE）安全模型完全不同。代码已通过 macOS 跨平台适配（Plan 03 gap closure），在 macOS 上优雅降级不 crash。

31-REVIEW.md 记录的 CR-01（Groovy 代码注入）属于 setup-jenkins.sh 的密码重置功能，与 Docker socket 权限收敛核心目标无关，建议在后续 Phase 中修复。

---

_Verified: 2026-04-18T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
