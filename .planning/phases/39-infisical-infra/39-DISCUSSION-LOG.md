# Phase 39: 密钥管理基础设施搭建 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 39-infisical-infra (密钥管理基础设施搭建)
**Areas discussed:** CLI 安装策略, Infisical 项目组织, 认证与安全, 离线备份策略

---

## 工具选择（重大变更）

| Option | Description | Selected |
|--------|-------------|----------|
| Doppler Developer Free | 单 Service Token 认证，CLI 安装简单，50 service tokens，10 projects，4 environments | ✓ |
| Infisical Cloud Free | Machine Identity（Client ID + Secret → JWT），密钥文件夹，密钥扫描，5 用户免费 | |
| SOPS + age 增强 | 零外部依赖，无单点故障，但无 Web UI | |

**User's choice:** Doppler Developer Free
**Reason:** 认证更简单（单 token），CLI 安装更简洁，免费额度充足

---

## CLI 安装策略

| Option | Description | Selected |
|--------|-------------|----------|
| brew install | `brew install dopplerhq/cli/doppler`，服务器已有 Homebrew | ✓ |
| apt 仓库（Infisical） | 添加第三方 apt 仓库 + apt-get install | |
| GitHub 二进制 | 手动下载到 /usr/local/bin/ | |
| 安装脚本封装 | 自定义 setup-infisical.sh 脚本 | |

**User's choice:** brew install
**Notes:** 用户最初回复"brew 安装到本地"

---

## Doppler 项目组织

| Option | Description | Selected |
|--------|-------------|----------|
| 单项目单环境 | 一个 "noda" 项目，"prod" 环境，所有密钥平铺 | ✓ |
| 单项目 + 文件夹 | 一个项目，用文件夹分组 | |
| 多项目分离 | noda-infra + noda-apps 分开 | |

**User's choice:** 单项目单环境

---

## 认证与安全

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins Credentials | Secret text 类型，withCredentials 读取，日志自动遮蔽 | ✓ |
| 文件存储 | /opt/noda/.doppler-token，文件权限 600 | |
| 双重存储 | Jenkins Credentials + 文件 | |

**User's choice:** Jenkins Credentials

---

## 离线备份策略

| Option | Description | Selected |
|--------|-------------|----------|
| 密码管理器 + B2 快照 | Service Token 存密码管理器，密钥导出加密上传 B2 | ✓ |
| 仅密码管理器 | Phase 42 再做 B2 自动化 | |

**User's choice:** 密码管理器 + B2 快照

---

## Claude's Discretion

- B2 加密快照的具体加密方式（age/gpg）
- Service Token 权限范围（read-only vs read-write）
- Doppler CLI 安装脚本实现细节

## Deferred Ideas

- 密钥版本管理 — Doppler Developer 免费版无此功能
- 密钥自动轮换 — Doppler Team 版才有
- 多环境（dev/staging）— 当前只有生产环境
- Infisical Cloud 作为升级路径

---

*Discussion log created: 2026-04-19*
