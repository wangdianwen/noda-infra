# Mac Docker 清理记录

**日期:** 2026-05-19
**清理对象:** Mac 本地 Docker 资源
**触发原因:** Phase 62 Wave 3 - Mac 旧容器清理

---

## 清理前状态

**磁盘占用:** 54.14GB
- 镜像: 27.92GB
- 卷: 489.4MB
- 构建缓存: 25.69GB

**资源清单:**
- 容器: 1 个运行中（noda-infra-postgres-prod）
- 镜像: 8 个（包括回滚依赖和关键基础镜像）
- 卷: 8 个（6 个可清理的旧卷）
- 网络: 4 个（noda-network 保留）

---

## 执行的清理操作

### 1. 卷清理（释放 240.7MB）

```bash
docker volume rm noda-platform_pgdata pre-prod_pgdata prod_pgbackups prod_pgdata prod_xyops_data user-avatars
```

**已删除的旧卷:**
- `noda-platform_pgdata`
- `pre-prod_pgdata`
- `prod_pgbackups`
- `prod_pgdata`
- `prod_xyops_data`
- `user-avatars`

### 2. 构建缓存清理（释放 25.69GB）

```bash
docker builder prune -a --force
```

**清理结果:**
- 删除 350 个构建缓存条目
- 释放 25.69GB 磁盘空间

---

## 清理后状态

**磁盘占用:** 6.24GB（减少 88%）
- 镜像: 5.996GB
- 卷: 248.7MB
- 构建缓存: 0B

**保留的资源:**
- ✅ `noda-infra-postgres-prod` 容器（运行中）
- ✅ `noda-infra_postgres_data` 卷（本地开发数据）
- ✅ `noda-infra-nginx-config` 卷（nginx 配置）
- ✅ `noda-network` 外部网络
- ✅ 所有回滚依赖镜像（`keycloak:rollback`, `noda-apps:6ca28bf8`）
- ✅ 所有关键基础镜像（postgres, keycloak, nginx, alpine）

---

## 验证结果

### 本地环境 ✅
- PostgreSQL 容器运行正常
- 关键镜像和卷全部保留
- 磁盘空间释放成功

### 生产服务 ⚠️
- SSH 连接失败（Permission denied）
- 通过 Cloudflare Tunnel 验证：
  - `class.noda.co.nz`: 307（在线）
  - `auth.noda.co.nz`: 307（在线）

---

## 磁盘空间节省

| 项目 | 清理前 | 清理后 | 释放 |
|------|--------|--------|------|
| 总计 | 54.14GB | 6.24GB | **47.9GB (88%)** |
| 镜像 | 27.92GB | 5.996GB | 21.92GB (78%) |
| 卷 | 489.4MB | 248.7MB | 240.7MB (49%) |
| 构建缓存 | 25.69GB | 0B | 25.69GB (100%) |

---

## 后续建议

1. **定期清理:** 每月清理构建缓存和旧卷
2. **监控磁盘:** 每周检查 `docker system df`
3. **SSH 连接:** 手动验证 r4s SSH 连接问题

---

## 相关文档

- Phase 62 Plan 62-03: Mac 旧容器清理
- Phase 62 计划: 切换与验证
