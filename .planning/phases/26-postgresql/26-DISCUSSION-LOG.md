# Phase 26: 宿主机 PostgreSQL 安装与配置 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-17
**Phase:** 26-postgresql
**Mode:** Auto (--auto)
**Areas discussed:** 认证策略, 端口配置, 数据迁移策略, 脚本组织

---

## 认证策略

| Option | Description | Selected |
|--------|-------------|----------|
| trust (无密码) | 本地连接无需密码，开发体验最简 | ✓ |
| md5 (密码认证) | 需要密码，更接近生产环境 | |

**User's choice:** trust (无密码) — auto-selected (recommended)
**Notes:** 本地开发环境便利性优先；生产 PG 在 Docker 容器中不受影响

---

## 端口配置

| Option | Description | Selected |
|--------|-------------|----------|
| 5432 (默认) | 标准 PG 端口，开发者 macOS 与服务器完全隔离无冲突 | ✓ |
| 5433 (与旧 dev 容器一致) | 匹配旧 docker-compose.dev.yml 中的 postgres-dev 端口 | |

**User's choice:** 5432 (默认) — auto-selected (recommended)
**Notes:** 开发者本地 macOS 与生产服务器完全隔离；使用默认端口减少连接字符串修改

---

## 数据迁移策略

| Option | Description | Selected |
|--------|-------------|----------|
| pg_dump/pg_restore via docker exec | 使用 Docker 容器内的 pg_dump 确保版本匹配 | ✓ |
| 跳过迁移，用种子脚本初始化 | 如果 Docker volume 中无重要数据 | |

**User's choice:** pg_dump/pg_restore via docker exec — auto-selected (recommended)
**Notes:** LOCALPG-04 要求迁移现有数据；docker exec 确保版本一致性；允许跳过（无重要数据时）

---

## 脚本组织

| Option | Description | Selected |
|--------|-------------|----------|
| 独立脚本 setup-postgres-local.sh 子命令模式 | install/init-db/migrate-data/status/uninstall 子命令 | ✓ |
| 简单命令序列（无脚本） | 直接在文档中列出安装步骤 | |

**User's choice:** 独立脚本子命令模式 — auto-selected (recommended)
**Notes:** 与 setup-jenkins.sh 模式一致；Phase 30 的 setup-dev.sh 会调用此脚本

---

## Claude's Discretion

- 脚本的具体实现细节（错误处理、颜色输出、交互确认）
- brew services 的具体配置方式
- 幂等性检查的具体实现
- 迁移脚本的进度反馈方式
- 是否需要单独的 pg_hba.conf 配置模板

## Deferred Ideas

- Jenkins H2 → PG 迁移（超出 Phase 26 范围，待评估）
- Jenkins PG 数据纳入 B2 备份体系
- 开发数据库种子数据自动化（Phase 30）
- PostgreSQL 配置优化（开发环境用默认配置）
