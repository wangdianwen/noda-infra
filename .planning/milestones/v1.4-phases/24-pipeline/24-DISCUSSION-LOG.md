# Phase 24: Pipeline 增强特性 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-16
**Phase:** 24-Pipeline 增强特性
**Mode:** Auto (--auto)
**Areas discussed:** 备份检查方式, CDN 缓存清除, 镜像清理策略, Cloudflare 凭据管理

---

## 备份检查方式

| Option | Description | Selected |
|--------|-------------|----------|
| 检查宿主机挂载目录中最新备份文件 mtime | 递归查找 `docker/volumes/backup` 下最新的 .dump/.sql 文件 | ✓ |
| 调用备份脚本验证 | source backup-postgres.sh 并检查其状态 | |
| 查询 B2 云存储最新备份 | 通过 rclone 检查 B2 上最新备份时间 | |

**User's choice:** 检查宿主机挂载目录中最新备份文件 mtime (auto-selected)
**Notes:** 宿主机目录直接可访问，无需 Docker exec 或云存储 API，最简单可靠

---

## CDN 缓存清除

| Option | Description | Selected |
|--------|-------------|----------|
| Cloudflare API purge_cache (purge_everything) | 清除 zone 全部缓存，API 调用最少 | ✓ |
| Cloudflare API purge_cache (按文件 URL) | 逐个清除特定文件 URL，精确但需枚举 | |
| Cloudflare API purge_cache (按 tag/host) | 按 cache tag 或 host 清除，需额外配置 | |

**User's choice:** Cloudflare API purge_everything (auto-selected)
**Notes:** 单域名单应用，purge_everything 最简单，免费计划支持

---

## 镜像清理策略

| Option | Description | Selected |
|--------|-------------|----------|
| 改为按 7 天时间阈值清理 | 删除超过 7 天的带 SHA 标签镜像 + dangling images | ✓ |
| 保持按保留数量（改为更大数字） | 保留最近 10 或 15 个镜像 | |
| 混合策略（7 天 + 至少保留 3 个） | 时间为主，保底最少保留数 | |

**User's choice:** 按 7 天时间阈值清理 (auto-selected)
**Notes:** ENH-03 明确要求"超过 7 天的旧 Docker 镜像"，时间阈值是需求原文

---

## Cloudflare 凭据管理

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins Credentials + withCredentials | 存储在 Jenkins 中，Pipeline 通过 withCredentials 注入 | ✓ |
| .env.production 环境变量 | 放在 .env 文件中，Pipeline 读取 | |
| Jenkins 宿主机环境变量 | 设置在系统 /etc/environment 中 | |

**User's choice:** Jenkins Credentials + withCredentials (auto-selected)
**Notes:** 与 Phase 19 中 Git 凭据管理方式一致，安全性最高

---

## Claude's Discretion

- CDN 缓存清除 API 调用的具体 curl 命令实现
- 备份文件查找的精确 bash 实现（find 命令参数等）
- 镜像时间解析方式（docker inspect --format vs docker images --format）

## Deferred Ideas

None — discussion stayed within phase scope
