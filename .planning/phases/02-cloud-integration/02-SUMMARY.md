# Phase 2: 云存储集成 - 规划摘要

**创建日期:** 2026-04-06
**状态:** ✅ 规划完成，准备执行
**预估时间:** 5-8 hours

---

## 📋 规划文档

### 已创建的文档
1. ✅ **02-RESEARCH.md** - 技术研究
   - Backblaze B2 技术调研
   - rclone 使用方法
   - 安全凭证管理方案
   - 重试和校验机制实现

2. ✅ **02-CONTEXT.md** - 上下文
   - Phase 概述和目标
   - 依赖关系（Phase 1 已完成）
   - 需求覆盖分析（7 个需求）
   - 风险评估和缓解措施
   - 成功标准定义

3. ✅ **02-DISCUSSION-LOG.md** - 决策日志
   - 12 个关键技术决策
   - 每个决策包含：决策内容、理由、影响、替代方案
   - 涵盖：云存储选择、工具选择、凭证管理、重试策略等

4. ✅ **02-PLAN.md** - 执行计划
   - 4 个 Waves，15 个任务
   - 详细的任务分解和验收标准
   - 风险和缓解措施
   - 时间估算（5-8 hours）

---

## 🎯 Phase 2 目标

**核心目标：** 将本地备份自动上传到 Backblaze B2 云存储

**具体目标：**
1. ✅ 备份完成后自动上传到 B2（使用 rclone）
2. ✅ 上传失败时自动重试（指数退避，最多 3 次）
3. ✅ 上传后验证校验和（rclone --checksum）
4. ✅ 自动清理 7 天前的旧备份（本地和云端）
5. ✅ 凭证通过环境变量安全管理
6. ✅ B2 Application Key 使用最小权限

---

## 📦 需求覆盖

| 需求 | 描述 | 优先级 |
|------|------|--------|
| UPLOAD-01 | 自动上传到 B2（使用 rclone） | P0 |
| UPLOAD-02 | 上传失败重试（指数退避，3次） | P0 |
| UPLOAD-03 | 上传后验证校验和（--checksum） | P0 |
| UPLOAD-04 | 清理 7 天前的旧备份 | P0 |
| UPLOAD-05 | 清理未完成的上传文件 | P1 |
| SECURITY-01 | 凭证通过环境变量管理 | P0 |
| SECURITY-02 | 最小权限 B2 Application Key | P0 |

**总计：** 7 个需求（6 个 P0，1 个 P1）

---

## 🌊 Wave 分解

### Wave 0: 基础设施准备（独立，30 min）
**目标：** 安装和配置 rclone，创建 B2 测试环境

**任务：**
1. 安装 rclone（`brew install rclone`）
2. 创建 B2 Bucket（名称：noda-backups）
3. 生成 B2 Application Key（最小权限）
4. 配置 .env.backup（添加 B2 配置）
5. 创建测试脚本（test_rclone.sh）

**验收标准：**
- rclone 命令可用（版本 >= 1.60）
- B2 bucket 已创建
- Application Key 已生成（仅限备份目录）
- .env.backup 已更新

---

### Wave 1: 核心功能实现（依赖 Wave 0，2-3 hours）
**目标：** 实现 lib/cloud.sh 云操作库

**任务：**
1. 扩展 lib/config.sh（添加 B2 配置函数）
2. 创建 lib/cloud.sh（实现云操作库）
3. 实现上传重试逻辑（指数退避，3 次）
4. 实现校验和验证（rclone check --checksum）

**核心函数：**
- `setup_rclone_config()` - 创建临时 rclone 配置
- `upload_to_b2()` - 上传备份文件（含重试）
- `verify_upload_checksum()` - 验证校验和
- `cleanup_old_backups_b2()` - 清理云端旧备份
- `list_b2_backups()` - 列出云端备份

**验收标准：**
- lib/cloud.sh 文件已创建
- 所有核心函数已实现
- 重试逻辑正常工作
- 校验和验证通过

---

### Wave 2: 主脚本集成（依赖 Wave 1，1-2 hours）
**目标：** 将云上传集成到主脚本

**任务：**
1. 修改 backup-postgres.sh（加载 lib/cloud.sh）
2. 集成云上传流程（备份 → 验证 → 上传 → 清理）
3. 实现清理功能集成（本地和云端）
4. 完善错误处理和日志

**新流程：**
```
1. 健康检查
2. 本地备份
3. 本地验证
4. 云上传（新增）
5. 清理旧备份
6. 完成
```

**验收标准：**
- 主脚本集成云上传
- 清理功能正常工作
- 错误处理完善

---

### Wave 3: 测试和优化（依赖 Wave 2，1-2 hours）
**目标：** 端到端测试和性能优化

**任务：**
1. 创建端到端测试（test_upload.sh）
2. 性能优化（调整 rclone 参数）
3. 文档更新（README.md）

**测试场景：**
- 完整上传流程测试
- 上传失败重试测试
- 校验和验证测试
- 清理功能测试
- 性能测试（上传速度）

**验收标准：**
- 所有测试通过
- 上传速度合理（> 10 MB/s）
- 文档已更新

---

## 🔑 关键决策

### 决策 01: 云存储提供商
**选择：** Backblaze B2
**理由：** 成本低（$0.005/GB/月），11个9持久性，rclone 原生支持

### 决策 02: 同步工具
**选择：** rclone
**理由：** 原生支持 B2，成熟稳定，内置重试和校验

### 决策 03: 凭证管理
**选择：** 环境变量 + 临时配置文件
**理由：** 安全、灵活、不泄露凭证

### 决策 04: 重试策略
**选择：** 指数退避，最多 3 次
**理由：** 容错、避免限流、平衡成功率

### 决策 05: 校验和验证
**选择：** rclone check --checksum
**理由：** 可靠、自动化、快速

---

## ⚠️ 风险和缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| rclone 未安装 | 中 | 高 | Wave 0 安装和验证 |
| B2 API 限流 | 低 | 中 | 指数退避重试 |
| 网络不稳定 | 中 | 中 | 增加超时时间 |
| 大文件上传超时 | 低 | 中 | rclone 自动重试 |
| 校验和不匹配 | 低 | 高 | 立即重试 |
| 清理误删 | 低 | 高 | 先测试，后上线 |

---

## 📊 时间估算

| Wave | 预估时间 | 缓冲时间 | 总计 |
|------|----------|----------|------|
| Wave 0 | 30 min | 15 min | 45 min |
| Wave 1 | 2-3 hours | 1 hour | 3-4 hours |
| Wave 2 | 1-2 hours | 30 min | 1.5-2.5 hours |
| Wave 3 | 1-2 hours | 30 min | 1.5-2.5 hours |
| **总计** | **5-8 hours** | **2-3 hours** | **7-11 hours** |

---

## 📂 文件结构

### 新增文件
```
scripts/backup/
├── lib/
│   └── cloud.sh              # 云操作库（新增）
├── tests/
│   ├── test_upload.sh        # 上传测试（新增）
│   └── test_rclone.sh        # rclone 配置测试（新增）
└── README.md                 # 使用文档（新增）
```

### 修改文件
```
scripts/backup/
├── lib/
│   └── config.sh             # 扩展 B2 配置（修改）
└── backup-postgres.sh        # 集成云上传（修改）

.env.backup                   # 扩展 B2 配置（修改）
```

---

## ✅ 成功标准

### 必须达成（BLOCKER）
1. ✅ 上传功能：备份完成后自动上传到 B2
2. ✅ 重试机制：上传失败时自动重试 3 次
3. ✅ 校验和验证：上传后验证文件完整性
4. ✅ 凭证安全：所有凭证通过环境变量管理
5. ✅ 自动清理：7 天前的备份被自动删除

### 应该达成（IMPORTANT）
6. ✅ 最小权限：B2 Key 仅授予必要的权限
7. ✅ 错误处理：上传失败时返回明确的错误信息

### 可以达成（NICE-TO-HAVE）
8. ⭐ 进度显示：上传时显示进度条
9. ⭐ 性能监控：追踪上传时间

---

## 🚀 下一步

### 立即行动
1. ✅ Phase 2 规划已完成
2. ⏳ 开始 Wave 0 执行（安装 rclone，配置 B2）
3. ⏳ 创建 B2 bucket 和 Application Key
4. ⏳ 实现 lib/cloud.sh 核心功能
5. ⏳ 集成到主脚本并测试

### 外部依赖
- [ ] Backblaze B2 账户注册
- [ ] 创建 B2 bucket（noda-backups）
- [ ] 生成 B2 Application Key

### 执行命令
```bash
# 开始执行 Wave 0
cd /Users/dianwenwang/Project/noda-infra
bash scripts/backup/tests/test_rclone.sh
```

---

## 📝 相关文档

- **技术研究：** .planning/phases/02-cloud-integration/02-RESEARCH.md
- **上下文：** .planning/phases/02-cloud-integration/02-CONTEXT.md
- **决策日志：** .planning/phases/02-cloud-integration/02-DISCUSSION-LOG.md
- **执行计划：** .planning/phases/02-cloud-integration/02-PLAN.md
- **项目状态：** .planning/STATE.md
- **路线图：** .planning/ROADMAP.md

---

**规划摘要版本:** 1.0
**最后更新:** 2026-04-06
**状态:** ✅ 规划完成，准备执行
**预估完成时间:** 5-8 hours
