# Phase 46: nginx 蓝绿部署支持 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 46-nginx-blue-green
**Areas discussed:** DNS 解析方案, Pipeline 部署顺序, nginx 蓝绿支持范围

---

## DNS 解析方案

| Option | Description | Selected |
|--------|-------------|----------|
| 方案 A: resolver 指令 | nginx.conf http 块添加 `resolver 127.0.0.11 valid=30s;`，最小改动（1 行） | ✓ |
| 方案 B: 变量动态解析 | `set $backend` + `proxy_pass http://$backend`，每请求重新解析，改动大且 proxy_next_upstream 不兼容 | |
| 方案 A + B 混合 | 两者叠加，增加维护复杂度 | |

**User's choice:** 方案 A: resolver 指令（推荐）
**Notes:** 最小改动即可解决问题，nginx reload 时会重新解析 upstream DNS

---

## Pipeline 部署顺序

| Option | Description | Selected |
|--------|-------------|----------|
| 添加 sleep + reload | recreate 后等待 3-5 秒 + nginx -s reload | ✓ |
| 只添加 reload | 不等待，依赖 resolver TTL 刷新 | |
| 添加 sleep + reload + 健康检查 | 最彻底但增加 Pipeline 复杂度 | |

**User's choice:** 添加 sleep + reload（推荐）
**Notes:** sleep 确保 Docker DNS 就绪后 reload 触发重新解析

---

## nginx 蓝绿支持范围

| Option | Description | Selected |
|--------|-------------|----------|
| 最小范围：仅修复 DNS | resolver + Pipeline reload，~6 行改动 | ✓ |
| 扩大范围：DNS + nginx 蓝绿 | 双 nginx 容器 + upstream 切换，范围显著扩大 | |

**User's choice:** 最小范围：仅修复 DNS（推荐）
**Notes:** nginx 部署频率极低，graceful reload 已足够。nginx 蓝绿模式记为 deferred

---

## Claude's Discretion

- sleep 的具体秒数（3-5 秒范围）
- resolver_timeout 的具体值
- pipeline_deploy_nginx() 中 reload 步骤的日志格式
- 是否需要为 noda-ops 也添加 reload 步骤

## Deferred Ideas

- nginx 蓝绿部署模式 — 未来如果需要 nginx 自身零停机部署可考虑
