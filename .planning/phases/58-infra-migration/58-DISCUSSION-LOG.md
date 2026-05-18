# Phase 58: 基础设施迁移 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-17
**Phase:** 58-基础设施迁移
**Areas discussed:** PostgreSQL 迁移方式, noda-ops 镜像处理, 迁移执行节奏, 数据安全策略

---

## PostgreSQL 迁移方式

| Option | Description | Selected |
|--------|-------------|----------|
| SSH 管道流式传输 | pg_dump \| ssh root@r4s 'docker exec -i postgres pg_restore'。快，不占磁盘 | ✓ |
| 文件传输 | pg_dump 到文件，scp 传到 r4s，pg_restore | |
| rsync Docker volume | rsync 整个 volume 目录。风险高，PG 版本必须一致 | |

**User's choice:** SSH 管道流式传输

| Option | Description | Selected |
|--------|-------------|----------|
| 全部数据库一起迁移 | noda_prod + keycloak + noda_preprod 等所有数据库一步到位 | ✓ |
| 仅业务数据库 | 只迁 noda_prod，Keycloak 单独 export/import | |

**User's choice:** 全部数据库一起迁移

| Option | Description | Selected |
|--------|-------------|----------|
| 停服迁移 | Mac PG 停止，确保数据一致性 | ✓ |
| 不停服迁移 | Mac PG 继续运行，有少量数据丢失风险 | |

**User's choice:** 停服迁移

| Option | Description | Selected |
|--------|-------------|----------|
| 是，先备份再迁移 | 迁移前跑一遍备份脚本作为回滚点 | ✓ |
| 不需要 | 直接开始迁移 | |

**User's choice:** 是，先备份再迁移

| Option | Description | Selected |
|--------|-------------|----------|
| 先启动空容器再 pipe 导入 | r4s 上先启动空 PG 容器，然后 pipe 导入数据 | ✓ |
| 先 dump 到文件再 restore | dump 自定义格式 (-Fc)，scp 到 r4s，pg_restore | |
| 共享 volume | Mac 和 r4s 文件共享 | |

**User's choice:** 先启动空容器再 pipe 导入

| Option | Description | Selected |
|--------|-------------|----------|
| 表数量 + 行数对比 | 对比 Mac 和 r4s 的表数量和每表行数 | ✓ |
| 数据 checksum 验证 | 逐表 CHECKSUM 对比，更严格但耗时 | |
| 只验证容器健康 | PG 容器健康 + 服务能连上 | |

**User's choice:** 表数量 + 行数对比

**Notes:** 用户希望确保数据零丢失，选择了最保守的方案组合。

---

## noda-ops 镜像处理

| Option | Description | Selected |
|--------|-------------|----------|
| Mac 构建 + SSH 管道传输 | docker build + docker save \| ssh 'docker load' | ✓ |
| Mac 构建 + 文件传输 | docker save 保存文件，scp 传输 | |
| r4s 本地构建 | 在 r4s 上直接构建。最慢，需要构建依赖 | |

**User's choice:** Mac 构建 + SSH 管道传输

| Option | Description | Selected |
|--------|-------------|----------|
| .env 文件（同 Mac） | 复制 Mac 的 .env 文件到 r4s | ✓ |
| 单独 .env.r4s | r4s 专用环境变量文件 | |
| 写在 compose 文件中 | 不推荐，密钥会入 git | |

**User's choice:** .env 文件（同 Mac）

**Notes:** 统一使用 SSH 管道模式与 PG 迁移保持一致。

---

## 迁移执行节奏

| Option | Description | Selected |
|--------|-------------|----------|
| 逐服务串行 | PG → Keycloak → Nginx → noda-ops，每步验证 | ✓ |
| 一次性全部 | 所有服务一起迁移，统一验证 | |
| 分两层 | 数据层(PG+KC) + 网络层(Nginx+noda-ops) | |

**User's choice:** 逐服务串行

| Option | Description | Selected |
|--------|-------------|----------|
| PG → KC → Nginx → noda-ops | 遵循依赖关系 | ✓ |
| Nginx → PG → KC → noda-ops | 先确保网络通道 | |

**User's choice:** PG → KC → Nginx → noda-ops

**Notes:** 遵循服务依赖关系，逐步验证。

---

## 数据安全策略

| Option | Description | Selected |
|--------|-------------|----------|
| 停服迁移，全程中断 | Mac 全部停止 → r4s 迁移 → 验证。全链路不可用 | ✓ |
| 并行运行，短暂切换 | Mac 继续运行，切换时短暂中断。有双写风险 | |

**User's choice:** 停服迁移，全程中断

| Option | Description | Selected |
|--------|-------------|----------|
| 保留一周后清理 | Mac 旧容器 stop 不 rm，保留一周 | ✓ |
| 立即清理 | 验证通过后立即清理 Mac | |
| Phase 62 后清理 | 等最终验证完成后清理 | |

**User's choice:** 保留一周后清理

**Notes:** 保守策略确保数据安全，Mac 作为回滚点保留。

---

## Claude's Discretion

- pg_dump/pg_restore 具体命令参数
- 各服务健康检查的具体验证步骤
- r4s 上 Docker Compose 部署命令
- 迁移过程中错误处理和重试逻辑

## Deferred Ideas

无 — 讨论均在 phase 范围内
