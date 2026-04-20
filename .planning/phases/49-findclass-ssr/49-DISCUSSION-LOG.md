# Phase 49: findclass-ssr 爬虫审计与决策 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-20
**Phase:** 49-findclass-ssr
**Areas discussed:** 审计方式, 移除 vs 分离决策, 独立容器架构

---

## 审计方式

| Option | Description | Selected |
|--------|-------------|----------|
| 克隆 noda-apps 审计 | 将 noda-apps 克隆到本地，完整审计 Python 脚本源码、调用链路、API 端点调用 | ✓ |
| 基于现有研究文档 | 基于 ARCHITECTURE.md 和 FEATURES.md 做决策，不查看源码 | |
| 服务器上容器检查 | 在生产服务器上检查运行中的 findclass-ssr 容器 | |

**User's choice:** 克隆 noda-apps 审计
**Notes:** 聚焦审计（只看 Python 脚本和 crawl-scheduler.ts），产出为 RESEARCH.md，需包含完整调用链路 + 运行频率

---

## 移除 vs 分离决策

| Option | Description | Selected |
|--------|-------------|----------|
| 完全移除（如果 HTTP 够用） | 移除所有 Python/Chromium，如果 Fetcher.get() 已覆盖所有场景 | |
| 分离为独立容器 | 创建独立 findclass-crawler 容器，保留完整能力 | |
| 审计后决策 | 审计完成后再决定 | ✓ |
| 你决定 | Claude 根据审计结果自动决策 | |

**User's choice:** 审计后决策
**Notes:** 决策条件以 StealthySession 是否实际使用为准，通过代码证据直接判断（不需要生产环境观察）

---

## 独立容器架构

### 容器位置

| Option | Description | Selected |
|--------|-------------|----------|
| 同一 docker-compose | 新容器加入 docker-compose.app.yml | ✓ |
| 独立 docker-compose 文件 | 独立 docker-compose.crawler.yml | |

**User's choice:** 同一 docker-compose

### 触发方式

| Option | Description | Selected |
|--------|-------------|----------|
| API 调用触发 | crawl-scheduler.ts 通过 HTTP POST 触发爬虫容器 | ✓ |
| 爬虫容器内部 cron | 爬虫容器自带定时器 | |
| 两种都支持 | API + 内部 cron | |

**User's choice:** API 调用触发

### 调度器改造范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅改调用方式 | spawn → HTTP fetch，不重写调度逻辑 | ✓ |
| 重写调度器 | 重写为独立微服务 | |

**User's choice:** 仅改调用方式

### 部署策略

| Option | Description | Selected |
|--------|-------------|----------|
| 单实例，无蓝绿 | 爬虫容器单实例运行 | ✓ |
| 蓝绿部署 | 与 findclass-ssr 一致 | |

**User's choice:** 单实例，无蓝绿

---

## Claude's Discretion

- noda-apps 仓库克隆位置和清理
- 审计文档格式和结构
- 调用链路图展示方式
- 决策分析深度

## Deferred Ideas

- findclass-ssr Alpine 切换 — Phase 51
- 爬虫容器具体实现 — Phase 50
- Jenkins Pipeline 适配 — Phase 50
