---
phase: 7
slug: execute-cloud-integration
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-06
---

# Phase 7 — 验证策略

> 每阶段验证合同，用于执行期间的反馈采样。

---

## 测试基础设施

| 属性 | 值 |
|------|-----|
| **框架** | Bash 脚本测试（自定义测试框架） |
| **配置文件** | `scripts/backup/tests/config.sh` |
| **快速运行命令** | `bash scripts/backup/tests/test_rclone.sh` |
| **完整套件命令** | `bash scripts/backup/tests/test_rclone.sh && bash scripts/backup/tests/test_upload.sh` |
| **预计运行时间** | ~30 秒（rclone 配置测试）+ ~120 秒（上传测试） |

---

## 采样率

- **每次任务提交后：** 运行 `bash scripts/backup/tests/test_rclone.sh`（快速验证）
- **每次计划 wave 后：** 运行完整套件（rclone + 上传测试）
- **`/gsd-verify-work` 之前：** 完整套件必须通过
- **最大反馈延迟：** 150 秒（2.5 分钟）

---

## 每任务验证映射

| 任务 ID | 计划 | Wave | 需求 | 威胁引用 | 安全行为 | 测试类型 | 自动化命令 | 文件存在 | 状态 |
|---------|------|------|------|----------|----------|----------|-----------|---------|--------|
| 07-00-01 | 00 | 0 | UPLOAD-01 | — | 无新安全行为 | 集成 | `bash scripts/backup/tests/test_rclone.sh` | ✅ W0 | ⬜ 待定 |
| 07-01-01 | 01 | 1 | UPLOAD-02 | — | 修复 test_rclone.sh 配置错误 | 单元 | `bash scripts/backup/tests/test_rclone.sh` | ✅ W0 | ⬜ 待定 |
| 07-01-02 | 01 | 1 | UPLOAD-03 | — | 修复 test_rclone.sh main() 函数 | 单元 | `bash scripts/backup/tests/test_rclone.sh` | ✅ W0 | ⬜ 待定 |
| 07-01-03 | 01 | 1 | SECURITY-01 | T-7-01 | 修复 cloud.sh 依赖缺失 | 单元 | `bash scripts/backup/tests/test_upload.sh` | ✅ W0 | ⬜ 待定 |
| 07-02-01 | 02 | 2 | UPLOAD-04 | — | 集成到主脚本 | 集成 | `bash scripts/backup/backup-postgres.sh --test` | ❌ W0 | ⬜ 待定 |
| 07-03-01 | 03 | 3 | UPLOAD-05, SECURITY-02 | T-7-02 | 验证清理和安全配置 | 集成 | `bash scripts/backup/tests/test_upload.sh --cleanup` | ❌ W0 | ⬜ 待定 |

*状态：⬜ 待定 · ✅ 通过 · ❌ 失败 · ⚠️ 不稳定*

---

## Wave 0 要求

- [x] `scripts/backup/tests/test_rclone.sh` — rclone 配置测试（已存在，需修复）
- [x] `scripts/backup/tests/test_upload.sh` — 上传功能测试（已存在，需修复）
- [x] `scripts/backup/lib/cloud.sh` — 云操作库（已存在，需验证）
- [x] `scripts/backup/lib/config.sh` — 配置管理（已存在，包含 B2 配置）
- [x] `rclone` (v1.73.3) — 已安装
- [x] `jq` (1.7.1) — 已安装

**现有基础设施覆盖所有阶段需求。**

---

## 仅手动验证

| 行为 | 需求 | 为什么手动 | 测试说明 |
|------|------|-----------|---------|
| B2 Application Key 权限验证 | SECURITY-02 | 无法通过 API 自动验证 B2 Key 权限范围 | 1. 登录 B2 控制台（https://secure.backblaze.com/app_keys.htm）<br>2. 检查 Application Key 权限：<br>   - 仅访问 `noda-backups` bucket<br>   - 权限：Read, Write, Delete（无 List、Share 等其他权限） |
| B2 Lifecycle Rules 验证 | UPLOAD-05 | 无法通过 CLI 自动验证 B2 Lifecycle Rules | 1. 登录 B2 控制台（https://secure.backblaze.com/bucket_lifecycle_rules.htm）<br>2. 检查 `noda-backups` bucket 的 Lifecycle Rules：<br>   - 文件年龄 > 7 天时自动删除<br>   - 应用于 `backups/postgres/` 前缀 |

---

## 验证签署

- [ ] 所有任务都有 `<automated>` 验证或 Wave 0 依赖
- [ ] 采样连续性：没有 3 个连续任务没有自动化验证
- [ ] Wave 0 覆盖所有缺失引用
- [ ] 无 watch-mode 标志
- [ ] 反馈延迟 < 150s
- [ ] 前言中设置 `nyquist_compliant: true`

**批准：** 待定
