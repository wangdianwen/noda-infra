---
phase: 20
slug: nginx
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-15
---

# Phase 20 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 手动验证（nginx -t + curl + docker exec） |
| **Config file** | 无 — 本 Phase 为 nginx 配置重构，无自动化测试框架 |
| **Quick run command** | `docker exec noda-infra-nginx nginx -t` |
| **Full suite command** | `docker exec noda-infra-nginx nginx -t && curl -sf http://localhost/health -H "Host: class.noda.co.nz" -o /dev/null` |
| **Estimated runtime** | ~2 seconds |

---

## Sampling Rate

- **After every task commit:** Run `docker exec noda-infra-nginx nginx -t`
- **After every plan wave:** Run full suite command
- **Before `/gsd-verify-work`:** Full suite must pass
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 20-01-01 | 01 | 1 | BLUE-02 | — | N/A | manual | `docker exec noda-infra-nginx nginx -t` | ✅ | ⬜ pending |
| 20-01-02 | 01 | 1 | BLUE-02 | T-20-01 | 原子写入（先写临时文件再 mv） | manual | `grep upstream config/nginx/snippets/upstream-findclass.conf` | ⬜ W0 | ⬜ pending |
| 20-01-03 | 01 | 1 | BLUE-02 | — | N/A | manual | `docker exec noda-infra-nginx nginx -s reload` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

无需安装测试框架 — 本 Phase 使用 `nginx -t` + `curl` 手动验证，已有基础设施覆盖所有验证需求。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| nginx reload 后流量仍正常 | BLUE-02 | 需要运行中的 Docker 容器 | 1. `docker exec noda-infra-nginx nginx -t` 确认语法正确 2. `docker exec noda-infra-nginx nginx -s reload` 3. `curl -sf http://localhost/health -H "Host: class.noda.co.nz"` 确认 HTTP 200 |
| 修改 upstream 文件后 reload 切换生效 | BLUE-02 | 需要 Docker 网络中实际运行的容器 | 1. 修改 upstream-findclass.conf 中 server 地址 2. `docker exec noda-infra-nginx nginx -s reload` 3. 确认流量指向新地址 |

---

## Validation Sign-Off

- [x] All tasks have automated verify or manual verification instructions
- [x] Sampling continuity: nginx -t after every task commit
- [x] Wave 0 covers all MISSING references (N/A — no test framework needed)
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
