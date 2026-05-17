---
phase: 57-env-prep
plan: 01
status: complete
completed: "2026-05-17"
---

# Phase 57 Plan 01: r4s 环境初始化脚本集

## 一行总结

创建 5 个幂等 Shell 脚本，覆盖 r4s Docker 网络创建、Swap 配置、SSH 用户搭建、Docker 自启验证。

## 完成的任务

| 任务 | 提交 | 文件 |
|------|------|------|
| Task 1: 网络与 Swap 初始化脚本 | a54eccd | setup-network.sh, setup-swap.sh |
| Task 2: SSH/Docker 验证/编排入口 | a741659 | setup-ssh.sh, verify-docker.sh, setup-r4s.sh |

## 关键成果

### 创建的文件

- `scripts/r4s/setup-network.sh` — 幂等创建 noda-network Docker 独立网桥
- `scripts/r4s/setup-swap.sh` — 2GB Swap + UCI fstab 持久化 + swappiness=10
- `scripts/r4s/setup-ssh.sh` — jenkins 用户 + docker 组 + SSH 目录 + 公钥辅助函数
- `scripts/r4s/verify-docker.sh` — Docker 开机自启 + restart 策略 + 资源概况
- `scripts/r4s/setup-r4s.sh` — 编排入口，统一调用所有函数

### 设计要点

- 所有脚本幂等（先检查状态再执行）
- 复用 `scripts/lib/log.sh` 日志函数
- 支持 `BASH_SOURCE[0] == "${0}"` 条件调用（可独立运行也可 source）
- Swap 使用 dd（非 fallocate）+ UCI fstab 持久化（iStoreOS 特有）
- SSH 用户使用 /bin/ash（iStoreOS 无 bash）+ opkg 安装 shadow-useradd

### 决策覆盖

- D-21: Swap 文件路径 /mnt/mmc1-4/docker/swapfile
- D-22: vm.swappiness=10
- D-24: jenkins 用户 + docker 组（无 sudo）
- D-25: ed25519 密钥类型（注释说明）
- D-27: authorized_keys 仅添加 Jenkins 公钥
- D-29: noda-network 使用默认子网
- D-31: /etc/init.d/dockerd 开机自启验证
- D-32: 所有脚本幂等设计

## Self-Check: PASSED

- [x] 5 个脚本全部通过 `bash -n` 语法检查
- [x] 每个脚本包含 `set -euo pipefail`
- [x] 每个脚本 source log.sh
- [x] 每个脚本包含幂等检查逻辑
- [x] setup-r4s.sh 引用所有 4 个子脚本函数
- [x] 需求 ENV-01/02/04/05 有对应脚本覆盖
