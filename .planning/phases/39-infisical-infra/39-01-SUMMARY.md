---
phase: 39-infisical-infra
plan: 01
status: complete
completed: 2026-04-19
---

# Plan 39-01: Doppler CLI 安装脚本 — 完成摘要

## Objective
在宿主机上安装 Doppler CLI，创建可复现的安装脚本。

## What Was Built

### scripts/install-doppler.sh
自动化安装脚本，包含：
- Homebrew 路径（brew tap + brew install），包含 gnupg 依赖处理
- curl/wget 备选路径（适合无 Homebrew 环境）
- 安装后版本验证
- 已安装检测（幂等性）

## Verification
- `doppler --version` → v3.75.3 ✅
- `bash -n scripts/install-doppler.sh` → 语法正确 ✅
- brew tap + gnupg 依赖 ✅

## Self-Check: PASSED

## Key Decisions
- 本机直接通过 brew 安装（无远程服务器）
- 脚本保留两种安装路径，供未来重建使用

## Key Files
- `scripts/install-doppler.sh` — Doppler CLI 安装脚本
