# Phase 29: 统一基础设施 Jenkins Pipeline - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-17
**Phase:** 29-jenkins-pipeline
**Mode:** Auto (--auto)
**Areas discussed:** Pipeline 结构, 部署策略, 备份集成, 回滚机制, 人工确认, deploy 脚本同步

---

## Pipeline 结构

| Option | Description | Selected |
|--------|-------------|----------|
| 单一 Jenkinsfile.infra（choice 参数） | 统一 Pipeline，通过下拉菜单选择服务，条件化执行 | ✓ |
| 独立 Jenkinsfile per 服务 | 每个基础设施服务一个 Jenkinsfile（类似 Jenkinsfile.keycloak） | |
| 共享库 + 模板 | Jenkins Shared Library 模式，动态加载服务配置 | |

**User's choice:** 单一 Jenkinsfile.infra — auto-selected (matches PIPELINE-01 requirement)
**Notes:** PIPELINE-01 明确要求 choice 参数选择目标服务

---

## Keycloak 集成方式

| Option | Description | Selected |
|--------|-------------|----------|
| 复用 keycloak-blue-green-deploy.sh | Pipeline 调用现有脚本，不重写逻辑 | ✓ |
| 内联蓝绿逻辑 | 在 pipeline-stages.sh 中重新实现 Keycloak 蓝绿 | |
| 委托 Jenkinsfile.keycloak | Pipeline 触发另一个 Jenkins job | |

**User's choice:** 复用 keycloak-blue-green-deploy.sh — auto-selected (避免代码重复)

---

## Nginx 部署策略

| Option | Description | Selected |
|--------|-------------|----------|
| Docker compose recreate（秒级中断） | --force-recreate 重建容器，2-5 秒不可用 | ✓ |
| 双容器热切 | 部署第二个 nginx 容器，通过端口映射切换 | |
| 配置热重载（nginx -s reload） | 仅适用于配置变更，不适用于镜像更新 | |

**User's choice:** compose recreate — auto-selected (nginx 无法蓝绿代理自身，秒级中断可接受)

---

## Postgres 部署策略

| Option | Description | Selected |
|--------|-------------|----------|
| Compose restart + 人工确认 | pg_dump 备份 → 人工确认 → compose restart → pg_isready 验证 | ✓ |
| 蓝绿双容器 | 双 PG 实例 + 数据同步 | |
| compose stop + start | 完全停止再启动（连接全部断开） | |

**User's choice:** compose restart + 人工确认 — auto-selected (PIPELINE-05/PIPELINE-07 要求)

---

## 备份范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅 postgres/keycloak | 有持久化数据的服务需要备份 | ✓ |
| 全部 4 个服务 | 统一备份所有服务 | |
| 按需选择 | Pipeline 参数选择是否备份 | |

**User's choice:** 仅 postgres/keycloak — auto-selected (nginx/noda-ops 无持久化数据)

---

## deploy-infrastructure-prod.sh 处理

| Option | Description | Selected |
|--------|-------------|----------|
| 精简为 postgres-only 回退 | 移除 nginx/noda-ops 逻辑，仅保留 postgres 作为灾难恢复手动入口 | ✓ |
| 完全删除 | 所有部署通过 Pipeline | |
| 保持不变 | 脚本和 Pipeline 并存 | |

**User's choice:** 精简为 postgres-only 回退 — auto-selected (避免脚本和 Pipeline 逻辑分叉)

---

## Claude's Discretion

- Jenkinsfile.infra 阶段名称和参数定义细节
- 备份文件命名规则和清理策略
- 健康检查重试参数和超时
- compose recreate 的具体参数（--no-deps, --force-recreate 等）
- Pipeline 失败日志保存路径

## Deferred Ideas

- Postgres 蓝绿部署（需要双实例 + 数据复制，复杂度高）
- Pipeline 并发互斥控制（infra-deploy vs findclass-deploy）
- 部署结果邮件通知
- 部署历史审计日志
- 自动触发 Pipeline（保持手动）
- Keycloak 版本升级 Pipeline（schema 迁移不兼容）
