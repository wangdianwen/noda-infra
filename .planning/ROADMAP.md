# Roadmap: Noda 基础设施

## Overview

Noda 项目基础设施的演进路线图。从数据库备份系统开始，逐步完善基础设施的现代化、安全性和可维护性。

## Milestones

- ✅ **v1.0 完整备份系统** — Phases 1-9 (shipped 2026-04-06) — [详情](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 基础设施现代化** — 29 commits (shipped 2026-04-11) — [详情](milestones/v1.1-MILESTONE.md)

## Current State

**最新版本:** v1.1 (2026-04-11)

**基础设施状态:**
- PostgreSQL prod/dev 双实例运行中
- Keycloak Google 登录已修复
- findclass-ssr 三合一服务已部署
- noda-ops 容器（备份 + 隧道）已合并
- 全量文档已更新并验证

**已知遗留:**
- 备份系统磁盘空间检查 bug
- 备份系统验证测试下载功能 bug
- Keycloak 自定义主题未实现

## Next Steps

v1.2 规划中：
- 修复备份系统已知 bug
- 监控生产环境运行情况
- 根据实际使用情况优化
