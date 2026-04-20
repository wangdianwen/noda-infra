---
phase: 47
slug: noda-site-image
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-20
---

# Phase 47 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Docker + curl/wget 手动验证 |
| **Config file** | 无独立测试框架 |
| **Quick run command** | `docker build -t noda-site:test -f deploy/Dockerfile.noda-site ../noda-apps && docker run --rm -p 3000:3000 noda-site:test` |
| **Full suite command** | 蓝绿部署全流程手动验证 |
| **Estimated runtime** | ~120 秒（构建）+ 10 秒（验证） |

---

## Sampling Rate

- **After every task commit:** Run `docker build + docker run --rm 健康检查`
- **After every plan wave:** Run 蓝绿部署手动验证
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 120 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 47-01-01 | 01 | 1 | SITE-01 | — | nginx 非 root 运行，端口 3000 | build | `docker build --target runner ... && docker run --rm -p 3000:3000 noda-site:test curl -sf http://127.0.0.1:3000/` | ❌ W0 | ⬜ pending |
| 47-01-02 | 01 | 1 | SITE-02 | — | prerender 产物完整复制 | build | `docker run --rm noda-site:test ls /usr/share/nginx/html/index.html` | ❌ W0 | ⬜ pending |
| 47-02-01 | 02 | 1 | SITE-03 | — | Pipeline 健康检查命令兼容 | smoke | `CONTAINER_HEALTH_CMD` 环境变量验证 | ❌ W0 | ⬜ pending |
| 47-02-02 | 02 | 1 | SITE-03 | — | 蓝绿部署全流程正常 | integration | Jenkins Build Now | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 构建验证脚本 — docker build + run + 健康检查 + 非 root 验证
- [ ] 蓝绿部署端到端验证 — 需要服务器环境

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 蓝绿部署全流程 | SITE-03 | 需要 Jenkins + 服务器环境 | Jenkins Build Now → Stage View 全绿 |
| 镜像体积 < 30MB | SITE-01 | 需要实际构建 | `docker images noda-site:test` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
