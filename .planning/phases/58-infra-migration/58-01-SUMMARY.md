---
phase: 58-infra-migration
plan: 01
status: complete
started: "2026-05-18T10:00:00.000Z"
completed: "2026-05-18T10:30:00.000Z"
---

## Plan 58-01: PostgreSQL 数据迁移

**Result:** ✅ 成功

### 执行摘要

将 Mac M4 上的 4 个 PostgreSQL 数据库（noda_prod/keycloak/noda_preprod/noda_agent，约 50MB）通过 SSH 管道完整迁移到 r4s (iStoreOS)。

### 环境预置（修复 Phase 57 遗漏）

在迁移前修复了 3 项缺失：
1. 创建 `noda-network` 外部网桥网络
2. 创建 2GB swap 文件（持久化到 fstab）
3. 通过 tar+scp 部署仓库文件到 r4s（`/opt/noda/noda-infra/`）

### 连接参数

- R4S_HOST: `192.168.100.1`
- SSH_KEY: `~/.ssh/id_noda_r4s`
- R4S_REPO_PATH: `/opt/noda/noda-infra`

### 迁移执行

| 阶段 | 操作 | 结果 |
|------|------|------|
| 基准线获取 | Mac PG 表行数+序列值 | ✅ 已保存 |
| Mac 停服 | 5 个容器 (apps/keycloak/nginx/noda-ops) | ✅ Exited 状态 |
| Mac 备份 | pg_dumpall → 1.4MB SQL | ✅ 完成 |
| .env 传输 | SCP 管道到 r4s | ✅ 31 行 |
| r4s PG 启动 | docker compose up -d postgres | ✅ healthy |
| 数据库创建 | keycloak/noda_preprod/noda_agent + preprod_app 角色 | ✅ 完成 |
| 数据迁移 | SSH 管道 pg_dump -Fc → pg_restore | ✅ 4/4 无错误 |
| 数据验证 | 表数量+行数+序列值对比 | ✅ 完全一致 |

### 数据验证结果

| 数据库 | Mac 表数 | r4s 表数 | 数据一致 |
|--------|---------|---------|---------|
| keycloak | 88 | 88 | ✅ |
| noda_prod | 12 | 12 | ✅ (courses=464, web_vitals=314) |
| noda_preprod | 12 | 12 | ✅ |
| noda_agent | 5 | 5 | ✅ |

关键序列值：web_vitals_id_seq=891 ✅, course_view_dedup_id_seq=146 ✅

### Mac 旧容器状态

5 个容器保留在 Exited 状态（per D-12），未删除。

### Self-Check: PASSED
