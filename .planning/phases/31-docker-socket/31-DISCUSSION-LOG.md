# Phase 31: Docker Socket 权限收敛 + 文件权限锁定 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 31-docker-socket
**Areas discussed:** 备份脚本兼容性, git pull 权限恢复, 脚本锁定范围, 执行安全网+回滚

---

## 备份脚本兼容性

| Option | Description | Selected |
|--------|-------------|----------|
| 恢复脚本由 jenkins 用户运行 | sudo -u jenkins 执行恢复，管理员通过 Break-Glass 访问 | ✓ |
| 恢复操作做成 Pipeline Job | Jenkins UI 触发恢复，但 Jenkins 宕机时不可用 | |
| 保持 docker exec 对所有用户开放 | 与 PERM-01 矛盾 | |

**User's choice:** 恢复脚本由 jenkins 用户运行
**Notes:** noda-ops 容器不挂载 Docker socket，备份通过内部网络不受影响。宿主机恢复脚本需要 jenkins 用户权限。

---

## git pull 权限恢复

| Option | Description | Selected |
|--------|-------------|----------|
| Git post-merge hook | .git/hooks/post-merge 自动恢复，需安装脚本创建 | ✓ |
| Pipeline pre-flight 阶段 | 只覆盖 Pipeline 触发场景，手动 git pull 不受保护 | |
| 两者都用 | 双重保障但维护两处 | |

**User's choice:** Git post-merge hook
**Notes:** hook 不在版本控制中，由安装脚本创建。

---

## 脚本锁定范围

| Option | Description | Selected |
|--------|-------------|----------|
| 最小范围（需求列出的） | deploy/*.sh + pipeline-stages.sh + manage-containers.sh | ✓ |
| 扩展范围（核心部署流程） | 加上 blue-green-deploy.sh、rollback-findclass.sh 等 | |
| 全量锁定（所有 Docker 脚本） | 所有使用 docker 命令的脚本 | |

**User's choice:** 最小范围
**Notes:** 其他脚本通过已锁定的脚本间接调用。

---

## 执行安全网+回滚

| Option | Description | Selected |
|--------|-------------|----------|
| 最小 undo 脚本 | 备份当前权限状态，可快速恢复 | ✓ |
| 无回滚，纯手动修复 | 简单但风险高 | |
| 完整快照回滚 | 过度工程化 | |

**User's choice:** 最小 undo 脚本
**Notes:** 执行前备份 socket 属组和文件权限列表。

---

## Claude's Discretion

- Socket 属组具体名称
- systemd override 配置参数
- post-merge hook 实现方式
- undo 脚本备份格式和存储位置

## Deferred Ideas

None
