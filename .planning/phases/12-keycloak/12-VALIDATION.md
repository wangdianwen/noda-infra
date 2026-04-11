---
phase: 12
slug: keycloak
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Docker smoke tests（基础设施项目，无代码测试框架） |
| **Config file** | none |
| **Quick run command** | `docker ps --filter "name=noda-infra-keycloak-dev"` |
| **Full suite command** | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev && sleep 30 && docker ps --filter "name=noda-infra-keycloak-dev"` |
| **Estimated runtime** | ~40 seconds |

---

## Sampling Rate

- **After every task commit:** Run `docker ps --filter "name=noda-infra-keycloak-dev"`
- **After every plan wave:** Run full suite: start keycloak-dev + verify ports + verify DB schema
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 40 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 12-01-01 | 01 | 1 | KCDEV-01 | T-12-01 | ports bind 127.0.0.1 only | smoke | `docker ps --filter "name=noda-infra-keycloak-dev" --format "{{.Ports}}"` | ⬜ W0 | ⬜ pending |
| 12-01-02 | 01 | 1 | KCDEV-01 | T-12-03 | KC_DB_URL=postgres-dev:5432/keycloak_dev | smoke | `docker exec noda-infra-postgres-dev psql -U postgres -d keycloak_dev -c "\dt" 2>&1 \| grep -c "table"` | ⬜ W0 | ⬜ pending |
| 12-02-01 | 02 | 1 | KCDEV-03 | — | themes dir rw mounted | smoke | `docker exec noda-infra-keycloak-dev ls /opt/keycloak/themes/noda/login/ 2>&1` | ⬜ W0 | ⬜ pending |
| 12-02-02 | 02 | 1 | KCDEV-02 | — | start-dev enables password auth | manual | 浏览器访问 http://localhost:18080/admin/ 并登录 | N/A | ⬜ pending |
| 12-02-03 | 02 | 1 | KCDEV-03 | — | theme cache disabled | manual | Admin Console 主题列表实时反映文件变更 | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `docker/services/keycloak/themes/noda/login/theme.properties` — 主题目录最小文件（KCDEV-03 验证需要）
- [ ] keycloak-dev 服务定义在 docker-compose.dev.yml 中 — KCDEV-01 验证需要
- [ ] 无需额外测试框架安装 — 基于容器运行状态的 smoke 测试

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Admin Console 密码登录 | KCDEV-02 | 需要浏览器交互和 UI 验证 | 1. 浏览器访问 http://localhost:18080/admin/ <br> 2. 使用 admin 凭证登录 <br> 3. 创建测试用户 <br> 4. 使用测试用户登录验证 |
| 主题热重载验证 | KCDEV-03 | 需要修改文件后刷新浏览器观察变化 | 1. 修改 themes/noda/login/resources/css/styles.css <br> 2. 刷新浏览器 <br> 3. 确认变更可见（无需重启容器） |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 40s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
