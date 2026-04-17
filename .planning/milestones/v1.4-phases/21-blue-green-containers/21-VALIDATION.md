---
phase: 21
slug: blue-green-containers
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-15
---

# Phase 21 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash 语法检查（`bash -n`）+ Docker 集成测试 |
| **Config file** | none — 脚本类测试不需要框架 |
| **Quick run command** | `bash -n scripts/manage-containers.sh` |
| **Full suite command** | `bash scripts/manage-containers.sh status` |
| **Estimated runtime** | ~2 seconds（语法检查） |

---

## Sampling Rate

- **After every task commit:** Run `bash -n scripts/manage-containers.sh`
- **After every plan wave:** Run `bash -n scripts/manage-containers.sh` + 检查 env 文件存在
- **Before `/gsd-verify-work`:** 生产环境执行完整 init → start → status 流程
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 21-01-01 | 01 | 1 | BLUE-04 | T-21-04 | docker run 包含完整安全参数 | syntax | `bash -n scripts/manage-containers.sh` | ❌ W0 | ⬜ pending |
| 21-01-02 | 01 | 1 | BLUE-03 | — | 状态文件原子写入 | syntax | `bash -n scripts/manage-containers.sh` | ❌ W0 | ⬜ pending |
| 21-01-03 | 01 | 1 | BLUE-01 | — | blue/green 容器独立启停 | syntax | `bash -n scripts/manage-containers.sh` | ❌ W0 | ⬜ pending |
| 21-01-04 | 01 | 1 | BLUE-05 | — | noda-network 网络配置 | syntax | `bash -n scripts/manage-containers.sh` | ❌ W0 | ⬜ pending |
| 21-01-05 | 01 | 1 | BLUE-03 | T-21-03 | env 文件权限 600 | unit | `stat -f '%Lp' docker/env-findclass-ssr.env` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/manage-containers.sh` — 所有子命令实现
- [ ] `docker/env-findclass-ssr.env` — 环境变量文件

*Existing infrastructure (bash -n, docker CLI) covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| init 迁移：compose → blue 容器 | BLUE-01, BLUE-04 | 需要运行中的 findclass-ssr 容器 | 1. 确认 findclass-ssr 运行 2. 执行 init 3. 确认 blue 容器健康 4. 确认 nginx 指向 blue |
| nginx DNS 解析容器名 | BLUE-05 | 需要 Docker 网络中的活跃容器 | `docker exec noda-infra-nginx wget -qO- http://findclass-ssr-blue:3001/api/health` |
| switch 切换流量 | BLUE-01 | 需要 blue + green 容器同时运行 | 1. start green 2. switch green 3. 确认 upstream 指向 green |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
