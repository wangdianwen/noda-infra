---
phase: 14-container-protection-and-deployment-safety
plan: 14-02
subsystem: nginx
tags: [nginx, upstream, failover, error-page, resilience]
key-files:
  created:
    - config/nginx/errors/50x.html
  modified:
    - config/nginx/conf.d/default.conf
    - docker/docker-compose.prod.yml
metrics:
  tasks: 1
  commits: 1
  duration: ~4m
---

# Plan 14-02: Nginx upstream 故障转移 + 自定义错误页面

## Changes

### Task 1: upstream 故障转移 + 自定义错误页面

**修改文件：**

1. **config/nginx/conf.d/default.conf**
   - 添加 `upstream keycloak_backend` 块（server keycloak:8080, max_fails=3, fail_timeout=30s）
   - 添加 `upstream findclass_backend` 块（server findclass-ssr:3001, max_fails=3, fail_timeout=30s）
   - 将 proxy_pass 从直接 host:port 改为 upstream 名称引用
   - 添加 `proxy_next_upstream error timeout http_502 http_503` 故障转移
   - 两个 server 块添加 `error_page 502 503 /50x.html`
   - 添加 `root /etc/nginx/errors` 和 location 块用于错误页

2. **config/nginx/errors/50x.html**（新建）
   - 自定义中文维护页面，包含友好提示信息

3. **docker/docker-compose.prod.yml**
   - nginx 服务添加 errors 目录卷挂载：`./config/nginx/errors:/etc/nginx/errors:ro`

## Commits

| Commit | Description |
|--------|-------------|
| 2f9c64a | feat(14-02): nginx upstream 故障转移 + 自定义错误页面 (D-07, D-08) |

## Deviations

None — all changes implemented as planned.

## Self-Check: PASSED

- [x] upstream keycloak_backend 定义存在
- [x] upstream findclass_backend 定义存在
- [x] proxy_next_upstream error timeout http_502 http_503 配置
- [x] error_page 502 503 /50x.html 配置
- [x] config/nginx/errors/50x.html 文件存在
- [x] docker-compose.prod.yml nginx 卷挂载 errors 目录
