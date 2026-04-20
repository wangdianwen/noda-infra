---
phase: 47
slug: noda-site-image
status: draft
nyquist_compliant: true
wave_0_complete: false
nyquist_note: "所有计划任务都有自动化验证命令（grep 组合检查），Wave 0 差距为服务器环境限制（docker build 需要 noda-apps 源码 + Jenkins 需要 Pipeline 服务器），非计划缺失"
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
| 47-01-01 | 01 | 1 | SITE-01 | -- | nginx 非 root 运行，端口 3000 | config-check | `test -f deploy/nginx/nginx.conf && test -f deploy/nginx/default.conf && grep -q 'pid /tmp/nginx.pid' deploy/nginx/nginx.conf && grep -q 'try_files .*/index.html' deploy/nginx/default.conf && echo "PASS"` | -- | ⬜ pending |
| 47-01-02 | 01 | 1 | SITE-01, SITE-02 | T-47-01..04 | nginx runner + pnpm 缓存挂载 | config-check | `grep -q 'FROM nginx:1.25-alpine AS runner' deploy/Dockerfile.noda-site && grep -q 'USER nginx' deploy/Dockerfile.noda-site && grep -q '\-\-mount=type=cache,target=/root/.local/share/pnpm/store' deploy/Dockerfile.noda-site && echo "PASS"` | -- | ⬜ pending |
| 47-02-01 | 02 | 2 | SITE-03 | -- | 健康检查参数优化 + 资源限制降低 | config-check | `grep -A 20 'noda-site:' docker/docker-compose.app.yml | grep -q 'interval: 10s' && grep -A 20 'noda-site:' docker/docker-compose.app.yml | grep -q "memory: 32M" && echo "PASS"` | -- | ⬜ pending |
| 47-02-02 | 02 | 2 | SITE-03 | -- | Pipeline 适配 nginx 容器 | config-check | `grep -q 'CONTAINER_HEALTH_CMD' jenkins/Jenkinsfile.noda-site && grep -q 'mkdir -p.*deploy/nginx' jenkins/Jenkinsfile.noda-site && echo "PASS"` | -- | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] 所有任务都有 `<automated>` 验证命令（grep 组合检查文件内容）
- [ ] 构建验证脚本 -- docker build + run + 健康检查 + 非 root 验证（需要 noda-apps 源码 + Docker 环境）
- [ ] 蓝绿部署端到端验证 -- 需要 Jenkins + 服务器环境

**注：** Wave 0 未完成项为环境限制，非计划缺失。部署到服务器后通过 Jenkins Pipeline 自动验证。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 蓝绿部署全流程 | SITE-03 | 需要 Jenkins + 服务器环境 | Jenkins Build Now → Stage View 全绿 |
| 镜像体积 < 30MB | SITE-01 | 需要实际构建 | `docker images noda-site:test` |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references（环境限制项已标注）
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
