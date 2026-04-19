---
phase: 46-nginx-blue-green
plan: 01
status: complete
started: 2026-04-20
completed: 2026-04-20
---

# Phase 46 Plan 01: nginx DNS 解析修复

## Summary

修复 nginx infra Pipeline `--force-recreate` 后 DNS 解析失败导致的容器重启循环。添加 Docker DNS resolver 配置 + 部署后 reload 步骤。

## Changes

### Task 1: nginx.conf 添加 Docker DNS resolver 指令
- `config/nginx/nginx.conf` http 块添加 `resolver 127.0.0.11 valid=30s;` 和 `resolver_timeout 5s;`
- nginx 使用 Docker 内置 DNS 解析容器名称（如 findclass-ssr-blue:3001）

### Task 2: pipeline_deploy_nginx() 添加部署后 DNS 刷新步骤
- `scripts/pipeline-stages.sh` 中 `pipeline_deploy_nginx()` 在 `docker compose up --force-recreate` 后添加 sleep 5 + nginx -s reload
- reload 失败时 `return 1`，Pipeline 失败处理机制接管

## Key Files

### Modified
- `config/nginx/nginx.conf` — Docker DNS resolver 配置
- `scripts/pipeline-stages.sh` — 部署后 DNS 刷新步骤

## Requirements Met

| Requirement | How |
|-------------|-----|
| DNS-01 | nginx.conf 添加 resolver 127.0.0.11，nginx 使用 Docker DNS |
| DNS-02 | pipeline_deploy_nginx() 添加 sleep 5 + reload 刷新 DNS |

## Deviations

无。所有修改严格按 PLAN.md 执行。

## Self-Check: PASSED

- [x] nginx.conf 包含 `resolver 127.0.0.11 valid=30s;`
- [x] nginx.conf 包含 `resolver_timeout 5s;`
- [x] pipeline_deploy_nginx() 包含 `sleep 5`
- [x] pipeline_deploy_nginx() 包含 `docker exec noda-infra-nginx nginx -s reload`
- [x] reload 失败时 `return 1`
- [x] pipeline_deploy_noda_ops() 未被修改
