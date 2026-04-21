# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (shipped 2026-04-17) -- [详情](milestones/v1.5-ROADMAP.md)
- **v1.6 Jenkins Pipeline 强制执行** -- Phases 31-34 (shipped 2026-04-18)
- **v1.7 代码精简与规整** -- Phases 35-38 (shipped 2026-04-19) -- [详情](milestones/v1.7-ROADMAP.md)
- **v1.8 密钥管理集中化** -- Phases 39-42 (shipped 2026-04-19)
- **v1.9 部署后磁盘清理自动化** -- Phases 43-46 (shipped 2026-04-20) -- [详情](milestones/v1.9-MILESTONE.md)
- **v1.10 Docker 镜像瘦身优化** -- Phases 47-52 (shipped 2026-04-21) -- [详情](milestones/v1.10-ROADMAP.md)

## Phases

<details>
<summary>v1.10 Docker 镜像瘦身优化 (Phases 47-52) -- SHIPPED 2026-04-21</summary>

**Milestone Goal:** 全面优化所有自建 Docker 镜像体积，减少构建时间、磁盘占用和部署带宽

- [x] **Phase 47: noda-site 镜像优化** - nginx:1.25-alpine 替代 Node.js，~218MB → ~25MB (completed 2026-04-20)
- [x] **Phase 48: 全局 Docker 卫生实践** - .dockerignore + COPY --chown + 基础镜像统一 (completed 2026-04-20)
- [x] **Phase 49: findclass-ssr 爬虫审计与决策** - Python 调用链路审计完成 (completed 2026-04-20)
- [x] **Phase 50: findclass-ssr 瘦身执行** - 跳过：爬虫是核心功能 (skipped 2026-04-21)
- [x] **Phase 51: findclass-ssr 深度优化** - 跳过：依赖 Phase 50 (skipped 2026-04-21)
- [x] **Phase 52: 基础设施镜像清理** - noda-ops 多阶段构建 + backup 层合并 (completed 2026-04-21)

</details>
