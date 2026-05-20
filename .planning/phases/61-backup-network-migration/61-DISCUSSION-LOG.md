# Phase 61: 备份与网络迁移 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-19
**Phase:** 61-备份与网络迁移
**Areas discussed:** Cloudflare Tunnel 切换, 备份 Cronjob 验证, 端口映射与 pre-prod 路由, Mac 旧服务清理

---

## Cloudflare Tunnel 切换

### 切换方式

| Option | Description | Selected |
|--------|-------------|----------|
| DNS 切换 | Tunnel 已在 r4s 运行，只需切换 DNS 指向 r4s | |
| 先停旧后起新 | 停 Mac Tunnel，启 r4s Tunnel，有短暂中断 | |
| 双活并行验证 | 两个 Tunnel 同时运行，自动负载均衡 | |

**User's choice:** Tunnel 已可访问，无需切换
**Notes:** 用户确认 r4s 上的 Cloudflare Tunnel 已经在正常工作

### DNS 解析验证

| Option | Description | Selected |
|--------|-------------|----------|
| 需要验证 DNS 解析 | config.yml 中 noda-nginx 需确认在 r4s Docker 网络内能解析 | ✓ |
| 已验证，没问题 | Tunnel 已工作，DNS 没问题 | |
| Claude 决定 | 让 Claude 执行时验证 | |

**User's choice:** 需要验证 DNS 解析
**Notes:** config.yml 中 `noda-nginx` 与实际容器名 `noda-infra-nginx` 可能不同，需验证

### 域名路由配置

| Option | Description | Selected |
|--------|-------------|----------|
| 保持现有配置 | 6 个域名全部保持不变 | ✓ |
| 需要调整域名 | 添加或移除域名路由规则 | |

**User's choice:** 保持现有配置
**Notes:** 6 个域名（noda.co.nz、auth、class、admin、health、localhost）全部保留

---

## 备份 Cronjob 验证

### Cronjob 当前状态

| Option | Description | Selected |
|--------|-------------|----------|
| Cronjob 已运行，只需验证 | 容器内 cronjob 已正常触发 | |
| 需手动触发验证 | cronjob 可能未触发，需手动执行验证 | ✓ |
| Claude 决定 | 让 Claude 检查实际状态 | |

**User's choice:** 需手动触发验证
**Notes:** r4s noda-ops 容器已启动但 cronjob 可能未正常触发过

### 验证执行顺序

| Option | Description | Selected |
|--------|-------------|----------|
| 按依赖关系串行 | pg_dump → B2 → Doppler → 周验证 | ✓ |
| 按风险从低到高 | B2 → pg_dump → Doppler → 周验证 | |

**User's choice:** 按依赖关系串行
**Notes:** 先验证数据库备份（核心功能），再验证上传和辅助功能

### 验证执行方式

| Option | Description | Selected |
|--------|-------------|----------|
| SSH docker exec | 远程执行备份脚本，查看输出 | ✓ |
| r4s 本地交互执行 | 直接在 r4s 上交互式执行 | |
| 编写验证脚本 | 一次性验证所有 cronjob | |

**User's choice:** SSH docker exec
**Notes:** 沿用 Phase 60 SSH docker exec 模式

### 备份保留策略

| Option | Description | Selected |
|--------|-------------|----------|
| 保持现有策略 | 7 天保留，find -mtime +7 -delete | ✓ |
| 缩短保留时间 | 3 天保留，节省 SD 卡空间 | |

**User's choice:** 保持现有策略
**Notes:** 64GB SD 卡空间足够保留 7 天备份

---

## 端口映射与 Pre-prod 路由

### Nginx 高端口验证

| Option | Description | Selected |
|--------|-------------|----------|
| 不需要，Tunnel 走内部网络 | 外部访问通过 Cloudflare Tunnel | |
| 需要验证高端口 | 从宿主机外部验证 8080/8081/8443 | |

**User's choice:** 只需暴露一个 pre-prod 端口（80），通过 /etc/hosts 指向 class.noda.dev
**Notes:** 用户希望 pre-prod 通过 class.noda.dev 域名直接访问 r4s，最好用 80 端口

### 80 端口可用性

| Option | Description | Selected |
|--------|-------------|----------|
| 用高端口（如 8080） | iStoreOS 占用 80 端口 | ✓ |
| 80 端口可用 | r4s 上 80 端口未占用 | |

**User's choice:** 用高端口
**Notes:** iStoreOS 管理界面占用 80 端口，使用 8080 替代

### Pre-prod 端口选择

| Option | Description | Selected |
|--------|-------------|----------|
| 复用 8080 | r4s overlay 已配置 8080:80 | ✓ |
| 分配独立端口 | 为 pre-prod 单独分配端口 | |

**User's choice:** 复用 8080
**Notes:** 现有配置已有 8080:80 映射，无需新增端口

---

## Mac 旧服务清理

### 清理时机

| Option | Description | Selected |
|--------|-------------|----------|
| r4s 验证通过后清理 | 确认 r4s 正常后再清理 | ✓ |
| Phase 62 统一清理 | 全链路验证后统一清理 | |
| 延迟清理（一周后） | 等 r4s 稳定运行一周 | |

**User's choice:** r4s 验证通过后清理
**Notes:** 不等到 Phase 62，Phase 61 验证通过即清理

### 清理程度

| Option | Description | Selected |
|--------|-------------|----------|
| 停止但不删除 | 保留回滚能力 | ✓ |
| 完全删除 | 停止并删除容器和卷 | |

**User's choice:** 停止但不删除
**Notes:** 与 Phase 58 D-12 策略一致，Mac 旧容器保留作回滚点

---

## Claude's Discretion

- 手动触发验证的具体命令和参数
- Docker 内部 DNS 解析验证的具体方法
- B2 上传验证的检查方式
- pre-prod 访问验证的 curl 命令和预期响应
- 验证失败时的回退步骤

## Deferred Ideas

None — discussion stayed within phase scope
