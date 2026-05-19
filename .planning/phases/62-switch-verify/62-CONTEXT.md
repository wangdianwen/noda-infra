---
phase: 62-switch-verify
created: 2026-05-19
---

# Phase 62: 切换与验证 — 上下文

## 目标

迁移完成后的全链路验证、Mac 清理和回滚方案确认。这是 v1.12 里程碑的最后阶段。

## 依赖

Phase 61 已完成（8/8 验证通过）：
- 备份 cronjob 全部正常运行
- Cloudflare Tunnel 在 r4s 上运行
- Mac 旧 noda-ops 已清理

## 需求覆盖

| 需求 | 描述 |
|------|------|
| SWITCH-01 | 全链路验证通过：浏览器 → Cloudflare → r4s Nginx → 各服务（prod + pre-prod） |
| SWITCH-02 | Mac 上旧容器已停止并清理，不再占用端口和资源 |
| SWITCH-03 | 回滚方案已验证：如果 r4s 出问题，可以快速切回 Mac 运行 |

## 当前架构

### r4s 运行服务

| 服务 | 容器 | 内存 | 端口 |
|------|------|------|------|
| postgres | noda-infra-postgres-prod | 768M | 5432 (内部) |
| nginx | noda-infra-nginx | 64M | 8080:80, 8081:81, 8443:443 |
| noda-ops | noda-ops | 256M | - |
| keycloak | noda-infra-keycloak | 640M | 8080 (内部) |
| noda-apps-prod | noda-apps-prod | 768M | 3000 (内部) |

### Mac 保留服务

- Jenkins（宿主机，端口 8888）
- 手动部署脚本（紧急回退）

### 外部访问路径

```
浏览器 → Cloudflare CDN → r4s noda-ops:cloudflared → nginx:80 → 各服务
  class.noda.co.nz → nginx → noda-apps-prod:3000
  auth.noda.co.nz  → nginx → keycloak:8080
  www.noda.co.nz   → nginx → noda-apps-prod:3002
  admin.noda.co.nz → nginx → noda-apps-prod:3006
```

### Pre-prod 访问路径

```
/etc/hosts (192.168.100.1) → r4s:8443 → nginx:443 SSL → pre-prod 容器
  class.noda.test:8443  → noda-apps-preprod:3000
  auth.noda.test:8443   → keycloak:8080
```

## 关键约束

1. **不能断开生产服务** — 验证过程中 class.noda.co.nz 必须保持可用
2. **回滚必须可行** — 在清理 Mac 之前必须确认回滚方案
3. **Jenkins 保留在 Mac** — 不清理 Jenkins 相关资源

## 已知问题

- r4s 上 Docker 镜像过旧，通过 volume mount 覆盖脚本（config.sh, test-verify.sh）
  - 不影响 Phase 62，但记录为技术债
