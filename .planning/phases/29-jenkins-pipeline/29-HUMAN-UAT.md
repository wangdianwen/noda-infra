---
status: partial
phase: 29-jenkins-pipeline
source: [29-VERIFICATION.md]
started: 2026-04-17
updated: 2026-04-17
---

## Current Test

[awaiting human testing]

## Tests

### 1. Jenkins 任务注册 + 参数化下拉菜单
expected: Jenkins UI 中存在 infra-deploy 任务，Build with Parameters 显示 SERVICE 下拉菜单（keycloak/nginx/noda-ops/postgres）
result: [pending]
instructions: 在 Jenkins 服务器上创建 Pipeline 任务，指定 jenkins/Jenkinsfile.infra，点击 Build with Parameters 验证下拉菜单

### 2. Keycloak 蓝绿部署 Pipeline 端到端
expected: 选择 keycloak 服务执行 Pipeline，自动完成备份→部署→健康检查→切换→验证全流程
result: [pending]
instructions: 在 Jenkins 中选择 keycloak 服务触发 Pipeline，观察各阶段状态

### 3. PostgreSQL 人工确认门禁
expected: 选择 postgres 服务时，Pipeline 在 Human Approval 阶段暂停，30 分钟超时后自动中止
result: [pending]
instructions: 选择 postgres 服务触发 Pipeline，验证暂停等待人工确认

### 4. 部署失败自动回滚
expected: 健康检查失败时自动执行回滚（keycloak 切回旧容器、nginx/noda-ops 恢复旧镜像）
result: [pending]
instructions: 模拟部署失败场景，验证回滚行为

## Summary

total: 4
passed: 0
issues: 0
pending: 4
skipped: 0
blocked: 0

## Gaps
