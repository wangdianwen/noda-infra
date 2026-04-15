# Phase 22: 蓝绿部署核心流程 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-15
**Phase:** 22-蓝绿部署核心流程
**Areas discussed:** 健康检查策略, 脚本接口与参数设计, 回滚脚本设计, 构建与镜像管理

---

## 健康检查策略

| Option | Description | Selected |
|--------|-------------|----------|
| HTTP curl 直检 | docker exec 到容器内执行 wget/curl，超时放宽到 120s（30x4s） | ✓ |
| 复用 Docker healthcheck | wait_container_healthy() Docker inspect，超时 120s | |
| 双重检查 | 先等 Docker healthcheck，再做 HTTP curl 确认 | |

**User's choice:** HTTP curl 直检
**Notes:** 更直接，不依赖 Docker healthcheck 的 start-period/retries 配置

### curl 执行方式

| Option | Description | Selected |
|--------|-------------|----------|
| 宿主机 curl 容器名 | 需要宿主机能解析 Docker DNS | |
| docker exec curl | 在容器内部执行，不依赖宿主机 DNS 解析 | ✓ |
| nginx 容器内 curl | 从 nginx 容器 curl 目标容器，验证 nginx DNS 解析 | |

**User's choice:** docker exec curl
**Notes:** 更可靠，不依赖宿主机 DNS 解析能力

---

## 脚本接口与参数设计

### 目标环境检测

| Option | Description | Selected |
|--------|-------------|----------|
| 自动检测 | 读取 /opt/noda/active-env，自动部署到非活跃环境 | ✓ |
| 手动指定 | 用户传入 blue/green 参数 | |

**User's choice:** 自动检测
**Notes:** 用户无需记住当前活跃环境

### 构建代码来源

| Option | Description | Selected |
|--------|-------------|----------|
| 当前目录构建 | 从当前目录 .git 获取 SHA，参数只需项目路径 | ✓ |
| 指定仓库+分支 | 脚本接受仓库 URL 和分支名，自动 clone | |

**User's choice:** 当前目录构建
**Notes:** Phase 23 Pipeline 从 Jenkins workspace 执行，当前目录即代码目录

### 与 manage-containers.sh 复用关系

| Option | Description | Selected |
|--------|-------------|----------|
| source 复用 | 部署脚本 source manage-containers.sh 复用函数 | ✓ |
| 子命令调用 | 通过 bash manage-containers.sh start ... 调用 | |
| 完全独立 | 不依赖 manage-containers.sh，复制函数逻辑 | |

**User's choice:** source 复用
**Notes:** 最直接，复用 run_container/update_upstream/reload_nginx 等函数

---

## 回滚脚本设计

### 回滚粒度

| Option | Description | Selected |
|--------|-------------|----------|
| 切回上一容器 | 切换到上一个活跃环境的容器，立即恢复服务 | ✓ |
| 重新构建上一版本 | 用上一个 Git SHA 重新构建镜像（2-5 分钟） | |
| 指定镜像版本回滚 | 从镜像历史中选择指定版本回滚 | |

**User's choice:** 切回上一容器
**Notes:** 最快，前提是旧容器仍在运行

### 镜像保留策略

| Option | Description | Selected |
|--------|-------------|----------|
| 保留最近 N 个 | 简单防止磁盘占满，Phase 24 提供完善清理 | ✓ |
| 保留最近 N 天 | 基于时间更直觉但可能意外删太多 | |
| 只清理无标签 | 只清理 dangling images，最安全但可能不够 | |

**User's choice:** 保留最近 N 个
**Notes:** 周级别构建频率，每镜像约 500MB，N 建议为 5

---

## 构建与镜像管理

### 镜像标签格式

| Option | Description | Selected |
|--------|-------------|----------|
| 短 SHA 7 字符 | git rev-parse --short HEAD（如 abc1234） | ✓ |
| SHA + 日期 | 如 abc1234-20260415，人类更友好 | |
| SHA + 备注 | 如 abc1234-hotfix，需要手动输入 | |

**User's choice:** 短 SHA 7 字符
**Notes:** 简洁、可追溯到 Git commit

### 构建命令

| Option | Description | Selected |
|--------|-------------|----------|
| docker compose build | 复用现有流程，与 deploy-apps-prod.sh 一致 | ✓ |
| docker build | 直接构建，更直接但需要维护构建参数 | |

**User's choice:** docker compose build
**Notes:** 构建后用 docker tag 添加 SHA 标签

---

## Claude's Discretion

- HTTP 健康检查的具体实现细节（重试间隔、超时参数）
- E2E 验证的 curl 端点和判断逻辑
- 保留镜像数量 N 的默认值
- 脚本步骤日志格式和进度输出
- rollback-findclass.sh 的参数设计

## Deferred Ideas

None
