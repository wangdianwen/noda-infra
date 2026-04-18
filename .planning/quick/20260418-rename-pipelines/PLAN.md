---
name: rename-pipelines
status: in-progress
---

# 重命名 Jenkins Pipeline 与容器名对齐

## 目标
将 `noda-apps-deploy` Pipeline 重命名为 `findclass-ssr-deploy`，与容器名 `findclass-ssr-{blue|green}` 一致。

## 命名规范
蓝绿部署 Pipeline 统一使用 `{service-name}-deploy` 格式：
- `findclass-ssr-deploy` → `findclass-ssr-{blue|green}`
- `keycloak-deploy` → `keycloak-{blue|green}`
- `noda-site-deploy` → `noda-site-{blue|green}`
- `infra-deploy` → compose 基础设施服务

## 变更清单
1. `git mv jenkins/Jenkinsfile jenkins/Jenkinsfile.findclass-ssr`
2. `03-pipeline-job.groovy`: job name + scriptPath + description
3. `setup-jenkins-pipeline.sh`: 所有 noda-apps-deploy 引用
4. `CLAUDE.md`: findclass-deploy 引用
