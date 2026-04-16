# Phase 27: 开发容器清理与 Docker Compose 简化 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-17
**Phase:** 27-docker-compose
**Mode:** Auto (--auto)
**Areas discussed:** dev.yml 保留内容, dev-standalone.yml 处理, simple.yml 清理, migrate-data 兼容

---

## dev.yml 保留内容

| Option | Description | Selected |
|--------|-------------|----------|
| 保留 nginx/keycloak 开发覆盖 | nginx 8081 端口 + keycloak start-dev 模式仍有本地开发价值 | ✓ |
| 完全删除 dev.yml | 所有开发覆盖都移除，简化为纯生产 overlay | |

**User's choice:** 保留 nginx/keycloak 开发覆盖 — auto-selected (recommended)
**Notes:** REQUIREMENTS.md CLEANUP-03 要求 "简化或移除"，保留有效覆盖属于简化

---

## dev-standalone.yml 处理

| Option | Description | Selected |
|--------|-------------|----------|
| 删除 | 本地 PG 已完全替代独立开发数据库 | ✓ |
| 保留为参考文档 | 重命名为 .example 后缀 | |

**User's choice:** 删除 — auto-selected (recommended)

---

## simple.yml 清理

| Option | Description | Selected |
|--------|-------------|----------|
| 同步清理 postgres-dev | 移除 simple.yml 中的 dev 服务，保持所有文件一致 | ✓ |
| 不动 simple.yml | simple.yml 是独立配置，不影响主 compose | |

**User's choice:** 同步清理 — auto-selected (recommended)

---

## migrate-data 兼容

| Option | Description | Selected |
|--------|-------------|----------|
| 添加友好提示 | 容器不存在时提示数据已迁移到本地 PG | ✓ |
| 直接删除 migrate-data | postgres-dev 容器已移除，函数无用 | |

**User's choice:** 添加友好提示 — auto-selected (recommended)
**Notes:** 保留接口兼容性，用户运行时获得清晰指引

---

## Claude's Discretion

- 具体的 YAML 编辑细节
- 文档更新的措辞和详细程度
- 是否需要在移除前添加确认提示

## Deferred Ideas

- docker-compose.simple.yml 合并到 base（超出清理范围）
- dev.yml nginx/keycloak 开发覆盖重新设计（Phase 30 可能重新定义）
- Docker volume postgres_dev_data 清理（留给用户手动执行）
