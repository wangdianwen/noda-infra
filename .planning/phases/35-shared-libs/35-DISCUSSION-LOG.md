# Phase 35: 共享库建设 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 35-shared-libs
**Areas discussed:** image-cleanup.sh 提取策略, deploy-check.sh 参数化设计

---

## image-cleanup.sh 提取策略

| Option | Description | Selected |
|--------|-------------|----------|
| 3 个独立函数 | 文件包含 cleanup_by_tag_count()、cleanup_by_date_threshold()、cleanup_dangling()，每个调用方选择自己需要的函数 | ✓ |
| 1 个统一入口 + strategy 参数 | cleanup_old_images --strategy=tag\|date\|dangling，内部根据 strategy 分发 | |
| 部分提取 + 保留内联 | 只提取策略相同的部分，差异太大的单独保留内联 | |

**User's choice:** 3 个独立函数
**Notes:** 3 个实现策略根本不同（标签保留/日期阈值/dangling 清理），统一接口会增加不必要的复杂度

### 函数命名风格

| Option | Description | Selected |
|--------|-------------|----------|
| 策略描述命名 | cleanup_by_tag_count()、cleanup_by_date_threshold()、cleanup_dangling() | ✓ |
| 统一前缀命名 | cleanup_images_tag_retention()、cleanup_images_date_retention()、cleanup_images_dangling() | |

**User's choice:** 策略描述命名
**Notes:** 名称自描述，清晰表明策略差异

---

## deploy-check.sh 参数化设计

| Option | Description | Selected |
|--------|-------------|----------|
| 函数参数传递 | 函数签名使用位置参数，所有调用方明确传递值。最简洁，无隐式依赖 | ✓ |
| 环境变量读取 | 函数内部读取环境变量，保持与现有调用方一致 | |
| 混合：函数参数 + 环境变量回退 | 函数参数优先，未传时回退到环境变量。灵活但增加复杂度 | |

**User's choice:** 函数参数传递
**Notes:** 位置参数最简洁、无隐式依赖，新调用方不会因为忘记设置环境变量而出错

---

## Claude's Discretion

- detect_platform 提取方式（8 个相同实现，无决策争议）
- Source Guard 变量命名（遵循已有模式）
- 具体函数签名设计
- 调用方迁移的执行顺序

## Deferred Ideas

None — discussion stayed within phase scope
