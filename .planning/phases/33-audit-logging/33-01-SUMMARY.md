---
phase: 33-audit-logging
plan: 01
status: complete
started: "2026-04-18"
completed: "2026-04-18"
---

## Plan 33-01: auditd 内核审计规则脚本

### Objective
创建 auditd 内核审计规则安装/验证/卸载脚本，监控所有 docker 命令执行并保护审计日志不被篡改。

### What was built
- `scripts/install-auditd-rules.sh` — 三件套脚本（install/verify/uninstall/help）
  - install: 安装 auditd 包、移除 no-audit 默认规则、写入 noda-docker.rules、配置 auditd.conf、加载规则、启动服务
  - verify: 检查规则文件、服务状态、规则加载、auditd.conf 参数、日志目录权限
  - uninstall: 删除规则文件、重新加载规则
  - macOS 平台所有操作跳过

### Key Decisions
- 使用 syscall 方式（-a always,exit -S execve）监控 /usr/bin/docker，非 deprecated watch 模式
- 包含普通用户（auid>=1000）和 jenkins 系统用户（uid=jenkins）两条规则，覆盖 auid unset 场景
- auditd.conf 配置：log_group=root, max_log_file=50, num_logs=30, log_format=ENRICHED
- 移除 Debian 默认 10-no-audit.rules 避免规则冲突

### Requirements Traceability
- AUDIT-01: docker 命令审计 — 通过 auditd syscall 规则实现
- AUDIT-02: 日志不可篡改 — log_group=root + 文件权限 0600 root:root

### Self-Check
- [x] bash -n 语法检查通过
- [x] 三个子命令函数存在（cmd_install, cmd_verify, cmd_uninstall）
- [x] 包含 -k docker-cmd 标记
- [x] 包含 uid=jenkins 专用规则
- [x] 包含 augenrules --load 规则加载
