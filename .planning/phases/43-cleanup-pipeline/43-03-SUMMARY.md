---
phase: 43-cleanup-pipeline
plan: 03
type: execute
status: complete
completed: "2026-04-19"
---

# Plan 43-03: 手动触发 Pipeline 端到端验证

## 结果

通过 3 次 Jenkins Pipeline 构建（#54、#55、#56）完成端到端验证，发现并修复了镜像清理逻辑缺陷。

## 验证过程

### Build #54 — 基线验证（旧代码）
- 触发 findclass-ssr Pipeline → SUCCESS
- 清理函数全部执行：build cache、container、network、volume、node_modules(781M)、临时文件
- 磁盘快照：部署前 + 清理后均有输出
- **问题发现：** `cleanup_by_date_threshold` 的日期解析在 macOS 全部失败（`image_epoch=0` → `continue`），8 个旧 SHA 镜像（~40GB）未被清理
- postgres_data 卷安全 ✓

### Build #55 — 代码已推送但 Jenkins 拉取旧代码
- 修复已提交到本地 main，但未推送到远程
- Jenkins 使用旧代码构建，镜像清理仍然无效

### Build #56 — 新代码生效 ✓
- 修复推送到 origin/main 后触发
- **新逻辑正确执行：**
  - `保留 findclass-ssr:fafe1e89（正在使用）`
  - 删除 7 个旧 SHA 标签镜像
  - 只保留 2 个镜像（在用 + latest）
  - 释放约 35GB 磁盘空间
- postgres_data 卷安全 ✓

## 修复内容

**问题：** `cleanup_by_date_threshold` 使用 macOS 不兼容的 ISO 8601 日期解析，所有 `image_epoch=0`，镜像从未被清理。

**修复：** 改为按容器使用状态清理策略：
1. 收集所有容器实际引用的镜像 ID
2. 始终保留 `latest` 标签镜像
3. 删除所有不在用列表中的旧标签镜像
4. 清理 dangling images

## 验证清单

| 检查项 | 结果 |
|--------|------|
| findclass-ssr Pipeline 构建成功 | ✓ SUCCESS |
| Cleanup 阶段无错误 | ✓ |
| 2 次磁盘快照（部署前 + 清理后） | ✓ |
| build cache、container、network、volume 清理 | ✓ |
| node_modules 清理（781M） | ✓ |
| 旧镜像清理（7 个，~35GB） | ✓ |
| postgres_data 卷未被删除 | ✓ |
| 服务正常运行 | ✓ |

## 关键文件

- `scripts/lib/image-cleanup.sh` — 修复 `cleanup_by_date_threshold` 按使用状态清理

## Self-Check: PASSED
