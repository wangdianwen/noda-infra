---
phase: 29
slug: jenkins-pipeline
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 29 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell（bash 脚本 + docker/jenkins 命令） |
| **Config file** | none |
| **Quick run command** | `bash -n jenkins/Jenkinsfile.infra && bash -n scripts/pipeline-stages.sh` |
| **Full suite command** | `source scripts/pipeline-stages.sh && type pipeline_backup_database && type pipeline_deploy_postgres && type pipeline_deploy_keycloak && type pipeline_deploy_nginx && type pipeline_deploy_noda_ops` |
| **Estimated runtime** | ~2 秒 |

---

## Sampling Rate

- **After every task commit:** Run `bash -n` 验证脚本语法
- **After every plan wave:** Run full suite（函数存在性检查）
- **Before `/gsd-verify-work`:** 完整 Pipeline 流程验证（需要 Jenkins 服务器）
- **Max feedback latency:** 2 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 29-01-01 | 01 | 1 | PIPELINE-02 | — | N/A | smoke | `test -f scripts/pipeline-stages.sh && grep -c "pipeline_backup_database" scripts/pipeline-stages.sh` ≥ 1 | ✅ | ⬜ pending |
| 29-01-02 | 01 | 1 | PIPELINE-05 | — | N/A | unit | `grep -c "pipeline_health_postgres\|pipeline_health_nginx\|pipeline_health_noda_ops" scripts/pipeline-stages.sh` ≥ 3 | ✅ | ⬜ pending |
| 29-01-03 | 01 | 1 | PIPELINE-06 | — | N/A | unit | `grep -c "pipeline_rollback" scripts/pipeline-stages.sh` ≥ 1 | ✅ | ⬜ pending |
| 29-02-01 | 02 | 1 | PIPELINE-01 | — | N/A | smoke | `test -f jenkins/Jenkinsfile.infra` | ❌ W0 | ⬜ pending |
| 29-02-02 | 02 | 1 | PIPELINE-03 | — | N/A | unit | `grep -c "pipeline_deploy_postgres\|pipeline_deploy_keycloak\|pipeline_deploy_nginx\|pipeline_deploy_noda_ops" jenkins/Jenkinsfile.infra` ≥ 4 | ❌ W0 | ⬜ pending |
| 29-02-03 | 02 | 1 | PIPELINE-07 | — | N/A | unit | `grep -c "input.*message\|input.*ok" jenkins/Jenkinsfile.infra` ≥ 1 | ❌ W0 | ⬜ pending |
| 29-03-01 | 03 | 2 | PIPELINE-04 | — | N/A | smoke | `grep -c "pg_dump\|pg_dumpall" scripts/pipeline-stages.sh` ≥ 1 | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- `jenkins/Jenkinsfile.infra` — 统一基础设施 Pipeline 文件
- 现有基础设施覆盖所有 phase requirements（pipeline-stages.sh, manage-containers.sh 已存在）

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Jenkins choice 参数下拉菜单 | PIPELINE-01 | 需要 Jenkins UI 验证 | 在 Jenkins 中运行 infra-deploy 任务，检查服务选择下拉菜单 |
| Keycloak 蓝绿零停机部署 | PIPELINE-03 | 需要实际部署和切换 | 选择 keycloak 服务，执行 Pipeline，验证零停机 |
| Postgres 人工确认门禁 | PIPELINE-07 | 需要 Jenkins input 交互 | 选择 postgres 服务，验证 Pipeline 暂停等待确认 |
| 备份失败中止部署 | PIPELINE-04 | 需要模拟备份失败 | 模拟 pg_dump 失败，验证 Pipeline 中止 |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 2s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
