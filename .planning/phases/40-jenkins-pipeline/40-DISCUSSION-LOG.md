# Phase 40: Jenkins Pipeline 集成 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 40-jenkins-pipeline
**Areas discussed:** Jenkinsfile 范围, 密钥获取方式, 手动部署脚本, Doppler 宕机回退

---

## Jenkinsfile 范围

| Option | Description | Selected |
|--------|-------------|----------|
| 改 3 个，跳过 noda-site | findclass-ssr、infra、keycloak 都加 Fetch Secrets。noda-site 无敏感密钥跳过。减少改动量 | ✓ |
| 4 个都改 | 所有 Jenkinsfile 统一模式，未来 noda-site 需要密钥时不用再改 | |
| 只在 pipeline-stages.sh 改 | 统一处理，不单独加 Fetch Secrets stage | |

**User's choice:** 改 3 个，跳过 noda-site
**Notes:** noda-site 是静态站点，无敏感密钥，不需要 Doppler 集成

---

## 密钥获取方式

| Option | Description | Selected |
|--------|-------------|----------|
| pipeline-stages.sh 统一处理 | 在 pipeline-stages.sh 中统一改为 doppler secrets download，所有 Jenkinsfile 自动获得密钥 | ✓ |
| 每个 Jenkinsfile 独立 stage | 每个 Jenkinsfile 添加独立 Fetch Secrets stage，更符合 Jenkins 最佳实践但改动量大 | |

**User's choice:** pipeline-stages.sh 统一处理

---

## Token 注入方式

| Option | Description | Selected |
|--------|-------------|----------|
| withCredentials 包装整个 pipeline | 在 options 或 environment 块中注入 DOPPLER_TOKEN，pipeline-stages.sh 检测到就用 Doppler | ✓ |
| 独立 Fetch Secrets stage | 添加一个 Jenkinsfile 顶部 stage 专门拉取密钥到 workspace | |

**User's choice:** withCredentials 包装整个 pipeline

---

## 手动部署脚本

| Option | Description | Selected |
|--------|-------------|----------|
| 本 phase 一起改 | 手动脚本也改为 doppler secrets download 获取密钥，需要用户手动设置 DOPPLER_TOKEN | ✓ |
| Phase 41 再改 | 手动脚本 Phase 41 迁移时再改，本 phase 只改 Jenkinsfile + pipeline-stages.sh | |

**User's choice:** 本 phase 一起改

---

## Doppler 宕机回退

| Option | Description | Selected |
|--------|-------------|----------|
| 双模式回退 | DOPPLER_TOKEN 存在用 Doppler，不存在回退 source docker/.env | ✓ |
| 纯 Doppler 无回退 | 只支持 Doppler，没有 DOPPLER_TOKEN 就报错停止 | |

**User's choice:** 双模式回退

---

## Claude's Discretion

- pipeline-stages.sh 中 Doppler 回退逻辑的具体实现细节
- withCredentials 在 Jenkinsfile 中的包装位置和范围
- 手动脚本的 Doppler 检测和错误处理细节
- Doppler secrets download 后的变量注入方式

## Deferred Ideas

- noda-site Pipeline 的 Doppler 集成 — 未来需要时复用相同模式
- Phase 41 删除 docker/.env — 本 phase 保留作为回退
