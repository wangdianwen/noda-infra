---
phase: 33-audit-logging
plan: 03
status: complete
started: "2026-04-18"
completed: "2026-04-18"
---

## Plan 33-03: sudo 操作日志配置脚本

### Objective
创建 sudo 操作日志配置安装脚本和 logrotate 轮转配置，将所有 sudo 操作记录到独立日志文件。

### What was built
- `scripts/install-sudo-log.sh` — 三件套脚本（install/verify/uninstall/help）
  - install: 创建日志目录、写入 /etc/sudoers.d/noda-audit、visudo 验证、设置权限、复制 logrotate 配置
  - verify: 检查 sudoers 文件、权限、语法、logfile 配置、日志目录、logrotate
  - uninstall: 删除 sudoers 文件和 logrotate 配置（保留日志目录和日志文件）
  - macOS 平台所有操作跳过
- `config/logrotate/sudo-logs` — 日志轮转配置
  - daily + rotate 14 + maxsize 50M
  - create 0600 root root

### Key Decisions
- 使用独立文件 /etc/sudoers.d/noda-audit 避免与现有 sudoers 冲突
- Defaults logfile 配置，零代码侵入
- 卸载时保留日志目录和日志文件（历史审计数据）
- 日志目录权限 700 root:root，日志文件权限 0600 root:root

### Requirements Traceability
- AUDIT-04: sudo 操作日志记录

### Self-Check
- [x] bash -n 语法检查通过
- [x] 包含 noda-audit sudoers 文件名
- [x] 包含 logfile=/var/log/sudo-logs/sudo.log
- [x] 包含 visudo -cf 语法验证
- [x] 包含 mkdir -p 日志目录创建
- [x] logrotate rotate 14 + maxsize 50M
