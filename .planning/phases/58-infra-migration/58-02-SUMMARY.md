---
phase: 58-infra-migration
plan: 02
status: complete
started: "2026-05-18T08:07:00.000Z"
completed: "2026-05-18T08:22:00.000Z"
---

## Plan 58-02: Keycloak + Nginx 启动验证

**Result:** ✅ 成功

### 执行摘要

在 r4s 上启动 Keycloak（认证服务）和 Nginx（反向代理），验证 Keycloak 连接 PG 数据库、Nginx 反向代理链路正常。

### 偏差记录

**Keycloak 版本升级 26.2.3 → 26.3**: r4s 上 Keycloak 26.2.3 无法启动（Quarkus `ClassNotFoundException: InitialConfigurator`），镜像在 Mac 正常运行但在 iStoreOS 上 class loading 失败。升级到 26.3 后正常启动。Keycloak 自动完成了数据库 schema 迁移（26.2.3 → 26.3.0）。

### 验证结果

| 组件 | 验证项 | 结果 |
|------|--------|------|
| Keycloak | 容器运行 | ✅ Up 4 minutes |
| Keycloak | PG 连接 | ✅ 无连接错误日志 |
| Keycloak | noda realm | ✅ OIDC discovery 正常返回 |
| Keycloak | realm 迁移 | ✅ master/noda/noda-dev 全部迁移到 26.3.0 |
| Nginx | 容器运行 | ✅ Up 14 seconds |
| Nginx | 配置语法 | ✅ syntax is ok |
| Nginx | /auth/ 代理 | ✅ HTTP 301（Keycloak 重定向） |
| Nginx | 端口映射 | ✅ 8080:80, 8081:81, 8443:443 |

### 自检：已通过
