---
phase: 28
slug: keycloak
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 28 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell（bash 脚本 + docker/nginx 命令） |
| **Config file** | none |
| **Quick run command** | `docker exec noda-infra-nginx nginx -t` |
| **Full suite command** | `SERVICE_NAME=keycloak bash scripts/manage-containers.sh status && docker exec noda-infra-nginx nginx -t` |
| **Estimated runtime** | ~5 秒 |

---

## Sampling Rate

- **After every task commit:** Run `nginx -t` 验证配置语法
- **After every plan wave:** Run manage-containers.sh status + nginx -t
- **Before `/gsd-verify-work`:** 完整蓝绿切换流程验证（init → start → switch → verify）
- **Max feedback latency:** 5 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 28-01-01 | 01 | 1 | KCBLUE-01 | — | N/A | smoke | `test -f docker/env-keycloak.env` | ❌ W0 | ⬜ pending |
| 28-01-02 | 01 | 1 | KCBLUE-03 | — | N/A | unit | `grep -c "keycloak" scripts/manage-containers.sh` ≥ 1 | ✅ | ⬜ pending |
| 28-01-03 | 01 | 1 | KCBLUE-02 | — | N/A | smoke | `grep -c "keycloak-" config/nginx/snippets/upstream-keycloak.conf` ≥ 1 | ✅ | ⬜ pending |
| 28-02-01 | 02 | 2 | KCBLUE-04 | — | N/A | integration | `test -f scripts/keycloak-blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 28-03-01 | 03 | 2 | KCBLUE-04 | — | N/A | unit | `test -f jenkins/Jenkinsfile.keycloak` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `docker/env-keycloak.env` — Keycloak 环境变量模板（KCBLUE-01）
- [ ] `scripts/keycloak-blue-green-deploy.sh` — Keycloak 蓝绿部署脚本
- [ ] `jenkins/Jenkinsfile.keycloak` — Keycloak 蓝绿 Pipeline
- [ ] Keycloak 健康检查端点验证 — 在现有容器上测试 `/health/ready` 可用性

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 蓝绿切换零停机 | KCBLUE-04 | 需要实际部署和切换测试 | init → start blue → switch → verify auth.noda.co.nz 可访问 |
| Keycloak 健康检查端点 | KCBLUE-01 | 需要运行中的 Keycloak 容器 | `docker exec noda-infra-keycloak-prod wget -qO- http://localhost:8080/health/ready` |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
