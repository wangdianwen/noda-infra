# Phase 23: Pipeline 集成与测试门禁 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-15
**Phase:** 23-pipeline-integration
**Areas discussed:** Jenkinsfile 位置, Pipeline 阶段粒度, noda-apps 代码获取与测试环境, 日志归档

---

## Jenkinsfile 位置与存储

| Option | Description | Selected |
|--------|-------------|----------|
| noda-infra 仓库独立文件 | Jenkinsfile 放在 noda-infra 仓库，通过 groovy 脚本引用。与现有脚本在同一仓库，维护方便 | ✓ |
| 写入 Jenkins Job 配置 | Jenkinsfile 写入 03-pipeline-job.groovy 的 configXml，修改需重启 Jenkins | |
| noda-apps 仓库 | 放在 noda-apps 根目录，需要两个仓库协同 | |

**User's choice:** noda-infra 仓库独立文件
**Notes:** 与现有所有部署脚本在同一个仓库，维护方便。noda-apps 是独立仓库，暂不将 Jenkinsfile 放入其中。

---

## Pipeline 阶段粒度

| Option | Description | Selected |
|--------|-------------|----------|
| 8 阶段细粒度 | Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → Cleanup，Jenkins Stage View 展示每阶段状态 | ✓ |
| 单脚本调用 | 调用 blue-green-deploy.sh 一个脚本，Jenkins UI 只显示一个大 Deploy stage | |
| 4 阶段粗粒度 | 折中方案，Pre-flight → Build+Test → Deploy+Health → Switch+Verify | |

**User's choice:** 8 阶段细粒度
**Notes:** 需要将 blue-green-deploy.sh 的逻辑拆分为可独立调用的阶段。

---

## noda-apps 代码获取

| Option | Description | Selected |
|--------|-------------|----------|
| Git SCM + SSH/PAT 认证 | Jenkins Git 插件配置仓库地址，凭据存 Jenkins Credentials | ✓ |
| 手动 git clone | 不用 Git 插件，更简单但缺少版本追踪 | |

**User's choice:** Git SCM + SSH/PAT 认证

---

## lint/test 执行环境

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins workspace 直接执行 | 在 workspace 中执行 pnpm lint && pnpm test，需宿主机安装 Node.js + pnpm | ✓ |
| Docker 容器中执行 | docker run 临时容器执行，更隔离但复杂度高 | |

**User's choice:** Jenkins workspace 直接执行

---

## 日志归档策略

| Option | Description | Selected |
|--------|-------------|----------|
| 仅失败时归档 | 失败时用 archiveArtifacts 保存构建日志和容器日志 | ✓ |
| 每次都归档 | 成功+失败都归档，占用更多存储 | |
| 不归档 | 只依赖 Jenkins 内置控制台输出 | |

**User's choice:** 仅失败时归档

---

## Claude's Discretion

- Jenkinsfile 各阶段具体调用哪些脚本/函数
- noda-apps Git URL 和分支配置
- Node.js/pnpm 在 Jenkins 宿主机的安装方式
- 日志归档的文件名格式和保留策略

## Deferred Ideas

None — discussion stayed within phase scope
