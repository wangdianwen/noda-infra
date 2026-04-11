---
status: partial
phase: 18-container-labels
source: 18-VERIFICATION.md
started: 2026-04-12
updated: 2026-04-12
---

## Current Test

[awaiting human testing]

## Tests

### 1. docker ps 按环境筛选验证
expected: 部署后 `docker ps --filter label=noda.environment=prod` 返回 5 个生产容器，`--filter label=noda.environment=dev` 返回 2 个开发容器
result: [pending]

### 2. docker ps 按服务组筛选验证
expected: `docker ps --filter label=noda.service-group=apps` 返回 findclass-ssr，`--filter label=noda.service-group=infra` 返回基础设施容器
result: [pending]

### 3. 所有容器双标签确认
expected: `docker inspect` 每个容器同时拥有 noda.service-group 和 noda.environment 标签
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
