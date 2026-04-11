---
phase: 13
slug: keycloak
status: draft
nyquist_compliant: false
wave_0_complete: true
created: 2026-04-11
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 手动视觉验证（无自动化测试框架） |
| **Config file** | none |
| **Quick run command** | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev && open http://localhost:18080` |
| **Full suite command** | 遍历登录页所有状态进行视觉检查 |
| **Estimated runtime** | ~60 seconds |

---

## Sampling Rate

- **After every task commit:** Dev 环境 `localhost:18080` 目视验证
- **After every plan wave:** Dev + Prod 环境对比验证
- **Before `/gsd-verify-work`:** 生产环境 `auth.noda.co.nz` 完整登录流程验证
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 13-01-01 | 01 | 1 | THEME-01 | N/A | N/A | manual | `cat docker/services/keycloak/themes/noda/login/theme.properties` | ✅ | ⬜ pending |
| 13-01-02 | 01 | 1 | THEME-01 | N/A | N/A | manual | `cat docker/services/keycloak/themes/noda/login/resources/css/styles.css` | ✅ | ⬜ pending |
| 13-01-03 | 01 | 1 | THEME-02 | N/A | N/A | manual | 目视确认默认 Logo 保留 | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. 纯 CSS 修改不需要测试框架基础设施。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 登录页品牌色显示 | THEME-01 | CSS 视觉效果需人眼确认 | 打开 dev 环境登录页，检查按钮颜色、链接色、焦点环色是否为 Pounamu Green #0D9B6A |
| 默认 Logo 保留 | THEME-02 | 视觉确认 Logo 未被替换 | 打开登录页，确认 Keycloak 默认 Logo 仍在 |
| 生产环境主题生效 | THEME-01 | 需在真实域名验证 | 访问 auth.noda.co.nz，确认品牌样式已应用 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
