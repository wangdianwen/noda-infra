# Phase 57: 环境准备 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-17
**Phase:** 57-环境准备
**Areas discussed:** 内存预算分配, Docker Compose 配置组织, Swap 与存储策略, SSH 部署通道, 网络端口与子网细节, 容器日志管理, iStoreOS Docker 开机行为, 初始化脚本幂等性

---

## 内存预算分配

| Option | Description | Selected |
|--------|-------------|----------|
| 同意默认方案 | PG 1G / KC 768M / Nginx 64M / ops 256M / ssr-prod 384M / ssr-pre 256M / admin 128M / auth 128M | |
| 优先压缩应用层 | 应用层内存再压，给 PG 和 KC 留更多 | |
| 优先压缩数据库 | PG 768M / KC 512M，应用层给更多空间 | ✓ |

**User's choice:** 优先压缩数据库
**Notes:** 用户明确要求 pre-prod 总共 256M 就够了

### Keycloak 内存

| Option | Description | Selected |
|--------|-------------|----------|
| KC 512M 足够 | Java 默认堆已控制，小用户量没问题 | |
| KC 640M 保守一点 | 给 Keycloak 多一点缓冲 | ✓ |
| PG 也压到 512M | 最大化应用层空间，但 PG 可能影响备份性能 | |

**User's choice:** KC 640M 保守一点

### Pre-prod 常驻策略

| Option | Description | Selected |
|--------|-------------|----------|
| 常驻运行 | 随时可以验证，但占用 512M | |
| 按需启动 | 只在部署时启动，节省内存 | |
| 混合模式 | ssr 常驻，admin/auth 按需 | |

**User's choice:** 用户自由输入 — "pre prod 总共 256M 就够了"

### 最终内存分配

| 服务 | 限制 |
|------|------|
| PostgreSQL | 768M |
| Keycloak | 640M |
| Nginx | 64M |
| noda-ops | 256M |
| findclass-ssr prod | 384M |
| findclass-ssr pre-prod | 128M |
| noda-admin | 64M |
| noda-auth | 64M |
| **总计** | **~2.31 GiB** |

---

## Docker Compose 配置组织

### Compose 文件组织

| Option | Description | Selected |
|--------|-------------|----------|
| R4s Overlay | 新增 docker-compose.r4s.yml，只覆盖差异 | ✓ |
| 独立 r4s 配置 | 完全独立的 r4s compose 文件 | |
| 环境变量区分 | 不新建文件，用环境变量区分 | |

**User's choice:** R4s Overlay (推荐)

### 容器命名

| Option | Description | Selected |
|--------|-------------|----------|
| 同名 | 与 Mac 容器名一致，脚本无需改动 | ✓ |
| 加 -r4s 后缀 | 区分但需改脚本引用 | |

**User's choice:** 同名 (推荐)

### 存储策略

| Option | Description | Selected |
|--------|-------------|----------|
| SD 卡存储 | 数据存 SD 卡，与 Docker 引擎同盘 | |
| SD卡优先 + 可迁移 | 先用 SD 卡，预留迁移能力 | ✓ |
| 等机械硬盘 | 等 1TB 机械硬盘挂载后再开始 | |

**User's choice:** SD卡优先 + 可迁移 (推荐)

### Compose 同步方式

| Option | Description | Selected |
|--------|-------------|----------|
| Git 同步 | r4s clone 仓库，Pipeline git pull 更新 | ✓ |
| SCP 传输 | Pipeline scp 文件到 r4s | |

**User's choice:** Git 同步 (推荐)

### 卷路径可配置性

| Option | Description | Selected |
|--------|-------------|----------|
| .env 环境变量 | DOCKER_DATA_DIR 变量管理路径 | ✓ |
| 硬编码路径 | compose 文件中直接写路径 | |

**User's choice:** .env 环境变量 (推荐)

### 密钥管理

| Option | Description | Selected |
|--------|-------------|----------|
| Doppler 动态注入 | Pipeline SSH 时临时生成 .env，用完删除 | ✓ |
| 静态 .env 文件 | r4s 上存放 .env 文件 | |

**User's choice:** Doppler 动态注入 (推荐)

### Doppler 执行方式

| Option | Description | Selected |
|--------|-------------|----------|
| r4s 安装 Doppler CLI | r4s 上安装 CLI，直接执行 secrets download | ✓ |
| Mac 传递密钥 | Jenkins 在 Mac 上获取密钥后传递 | |

**User's choice:** r4s 安装 Doppler CLI (推荐)

### 仓库目录

| Option | Description | Selected |
|--------|-------------|----------|
| /opt/noda-infra | 固定目录，与 Mac 路径一致 | ✓ |
| Home 目录 | clone 到用户 home 目录 | |

**User's choice:** /opt/noda-infra (推荐)

### 环境初始化方式

| Option | Description | Selected |
|--------|-------------|----------|
| Shell 脚本 | scripts/r4s/ 目录下幂等脚本 | ✓ |
| 手动配置 | 手动一次性操作 | |

**User's choice:** Shell 脚本 (推荐)

### 服务管理方式

| Option | Description | Selected |
|--------|-------------|----------|
| 保持一致 | r4s 与 Mac 相同的服务管理模式 | ✓ |
| 全部 compose 管理 | 所有服务统一用 docker compose | |

**User's choice:** 保持一致 (推荐)

---

## Swap 与存储策略

### Swap 大小和位置

| Option | Description | Selected |
|--------|-------------|----------|
| 2GB SD 卡 | /mnt/mmc1-4/docker/swapfile | ✓ |
| 1GB SD 卡 | 节省空间但缓冲小 | |
| 4GB SD 卡 | 更安全但占空间 | |

**User's choice:** 2GB SD 卡
**Notes:** 用户询问 SD 卡寿命 — 回答 Swap 写入频率很低（swappiness=10），对寿命影响极小

### Swappiness 值

| Option | Description | Selected |
|--------|-------------|----------|
| swappiness=10 | 内核尽量用 RAM，只在压力大时 swap | ✓ |
| swappiness=1 | 几乎不 swap，更保守 | |
| swappiness=60 | Linux 默认，更积极 | |

**User's choice:** swappiness=10 (推荐)

---

## SSH 部署通道

### SSH 用户

| Option | Description | Selected |
|--------|-------------|----------|
| jenkins 用户 + 受限 sudo | 专用用户，最小权限 | ✓ |
| root 用户 | 最简单但安全风险高 | |
| 管理员账户 | 复用 iStoreOS 管理员 | |

**User's choice:** jenkins 用户 + 受限 sudo (推荐)

### SSH 密钥类型

| Option | Description | Selected |
|--------|-------------|----------|
| ed25519 | 更快更安全，密钥更短 | ✓ |
| RSA 4096 | 兼容性最好，密钥较长 | |

**User's choice:** ed25519 (推荐)

### 密钥存储位置

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins credentials | 标准做法，Pipeline 通过 withCredentials 注入 | ✓ |
| ~/.ssh 目录 | 简单但不在 Jenkins 管理范围 | |

**User's choice:** Jenkins credentials (推荐)

### authorized_keys 配置

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins 专用 | 只添加 Jenkins 公钥 | ✓ |
| Jenkins + 你自己 | 同时添加手动 SSH 调试用公钥 | |

**User's choice:** Jenkins 专用 (推荐)

---

## 网络端口与子网细节

### 端口映射

| Option | Description | Selected |
|--------|-------------|----------|
| 高端口映射 (8080/8443) | 避免 iStoreOS 管理界面冲突 | ✓ |
| 直接 80/443 | 先检查是否可用 | |
| 不暴露端口 | Tunnel 直连 Nginx | |

**User's choice:** 高端口映射 (8080/8443)

### 子网配置

| Option | Description | Selected |
|--------|-------------|----------|
| 默认子网 | Docker 默认 172.17.x.x，不冲突 | ✓ |
| 固定子网 | 指定 172.28.0.0/16，便于管理 | |

**User's choice:** 默认子网 (推荐)

---

## 容器日志管理

### 日志配置

| Option | Description | Selected |
|--------|-------------|----------|
| 更紧凑 (5m×2) | 8 容器 ~80MB 总日志上限 | ✓ |
| 保持不变 (10m×3) | 8 容器 ~240MB 总日志上限 | |
| 禁用日志 | 最省空间但无法排查 | |

**User's choice:** 更紧凑 (5m×2) (推荐)

---

## iStoreOS Docker 开机行为

### 验证方式

| Option | Description | Selected |
|--------|-------------|----------|
| 验证 + 文档记录 | 脚本中验证开机自启状态并记录 | ✓ |
| 假设已配置 | 不额外验证 | |

**User's choice:** 验证 + 文档记录 (推荐)

---

## 初始化脚本幂等性

### 幂等要求

| Option | Description | Selected |
|--------|-------------|----------|
| 全幂等 | 每步检查状态再执行，可安全重复 | ✓ |
| 一次性执行 | 重复执行可能报错 | |

**User's choice:** 全幂等 (推荐)

---

## Claude's Discretion

无 — 所有决策均由用户明确选择。

## Deferred Ideas

None — discussion stayed within phase scope
