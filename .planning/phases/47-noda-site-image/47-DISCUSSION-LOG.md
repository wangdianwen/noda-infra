# Phase 47: noda-site 镜像优化 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-20
**Phase:** 47-noda-site-image
**Areas discussed:** 容器内 nginx 配置, 健康检查与安全, Jenkins Pipeline 适配

---

## 容器内 nginx 配置

### SPA fallback

| Option | Description | Selected |
|--------|-------------|----------|
| SPA fallback | 所有未匹配路径返回 index.html，与当前 serve 行为完全一致 | ✓ |
| 严格静态文件 | 仅服务预渲染的 HTML，未找到路径返回 404 | |
| Claude 决定 | 你来决定最合适的方案 | |

**User's choice:** SPA fallback（推荐）
**Notes:** noda-site 使用 vite-plugin-prerender，大部分页面已预渲染，但 SPA fallback 保证所有路径都能正确响应

### 缓存策略

| Option | Description | Selected |
|--------|-------------|----------|
| 不设缓存头 | 容器内 nginx 不设缓存头，让前面一层 nginx 处理 | ✓ |
| 分层缓存 | 静态资源长缓存，HTML 不缓存，与外层 nginx 相同 | |
| Claude 决定 | 你来决定 | |

**User's choice:** 不设缓存头（推荐）
**Notes:** 外层 nginx（default.conf）已处理缓存策略（静态资源 1 年 + immutable，HTML no-cache），避免两层缓存冲突

### gzip 压缩

| Option | Description | Selected |
|--------|-------------|----------|
| 启用 gzip | 容器内 nginx 启用 gzip，减少内部网络传输量 | |
| 不启用 | 外层 nginx/Cloudflare 已处理压缩 | ✓ |
| Claude 决定 | 你来决定 | |

**User's choice:** 不启用（推荐）
**Notes:** Cloudflare + 外层 nginx 已处理压缩，容器内无需重复

---

## 健康检查与安全

### 健康检查方式

| Option | Description | Selected |
|--------|-------------|----------|
| curl localhost | 用 curl 检查 http://localhost:3000/ | ✓ |
| 进程检查 | 检查 nginx 进程是否存在 | |
| Claude 决定 | 你来决定 | |

**User's choice:** curl localhost（推荐）
**Notes:** nginx:alpine 可能只有 BusyBox wget，具体命令由实现阶段决定

### 非 root 运行

| Option | Description | Selected |
|--------|-------------|----------|
| 非 root 运行 | 以 nginx 用户运行，更安全 | ✓ |
| root 运行 | 用 root 更简单，配合 read_only + cap_drop | |
| Claude 决定 | 你来决定 | |

**User's choice:** 非 root 运行（推荐）
**Notes:** 需要配置可写目录（/var/cache/nginx、/var/run 等）

---

## Jenkins Pipeline 适配

### Pipeline 修改范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅修改 Dockerfile | Pipeline 逻辑不变，仅调整 Dockerfile | |
| Dockerfile + Pipeline 优化 | 包括 pnpm 缓存、健康检查优化、资源限制调整 | ✓ |
| Claude 决定 | 你来决定 | |

**User's choice:** Dockerfile + Pipeline 优化

### Pipeline 优化项（多选）

| Option | Description | Selected |
|--------|-------------|----------|
| pnpm 构建缓存 | 挂载主机 pnpm store 作为构建缓存 | ✓ |
| 缩短健康检查等待 | nginx 启动更快，缩短超时/等待 | ✓ |
| 降低资源限制 | nginx 资源占用更小，降低内存限制 | ✓ |
| Claude 决定 | 你来决定合适的优化组合 | ✓ |

**User's choice:** 全选
**Notes:** 所有 Pipeline 优化项都纳入本 Phase 范围

---

## Claude's Discretion

- HEALTHCHECK 具体命令（curl vs wget）
- 非 root 运行的具体配置细节
- 资源限制的具体数值
- 健康检查超时参数的具体调整值
- pnpm 缓存挂载的具体实现方式

## Deferred Ideas

- HYGIENE-02（COPY --chown）属于 Phase 48
- findclass-ssr Alpine 切换属于 Phase 49-51
