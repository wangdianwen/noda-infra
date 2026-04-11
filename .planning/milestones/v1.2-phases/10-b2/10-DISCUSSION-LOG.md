# Phase 10: B2 备份修复 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 10-B2 备份修复
**Areas discussed:** B2 中断调查策略, 磁盘检查修复方案, 验证下载修复方案, 测试策略

---

## B2 中断调查策略

| Option | Description | Selected |
|--------|-------------|----------|
| v1.1 迁移导致 | 容器重启/重命名，rclone 配置或环境变量丢失 | |
| B2/rclone 配置问题 | 凭证过期、bucket 配置变更、版本兼容 | |
| 不确定，需查日志 | 需要查看生产环境日志才能确定 | ✓ |
| 已知原因 | 已经知道具体原因 | |

**User's choice:** 不确定，需查日志
**Notes:** 计划内包含调查步骤，先登录服务器检查日志和状态，定位根因后再针对性修复

---

## 磁盘检查修复方案

| Option | Description | Selected |
|--------|-------------|----------|
| 简单修复：加 df 检查 | 容器内直接用 df 检查挂载点空间，简单可靠 | ✓ |
| 完整方案：Docker volume 感知 | 检查 Docker volume 实际空间、overlay2 占用等 | |
| 简化方案：移除脚本内检查 | 把磁盘检查交给外部监控 | |

**User's choice:** 简单修复：加 df 检查
**Notes:** 修复位置 health.sh:163-166，替换 return 0 为实际的 df 空间检查

---

## 验证下载修复方案

| Option | Description | Selected |
|--------|-------------|----------|
| 修复下载路径解析 | 修复下载函数正确处理日期子目录路径 | ✓ |
| 扁平化存储结构 | 改备份上传逻辑取消日期子目录 | |
| 你决定 | 两种方案都可以 | |

**User's choice:** 修复下载路径解析
**Notes:** 保持 B2 存储结构不变，修复 download_backup 和 download_latest_backup 中的路径解析逻辑

---

## 测试与验证策略

| Option | Description | Selected |
|--------|-------------|----------|
| 本地模拟验证 | 用 B2 测试文件 + 模拟环境在本地验证 | ✓ |
| 生产环境直接验证 | 直接在服务器上执行修复后脚本 | |
| 分步验证 | 先本地再生产 | |

**User's choice:** 本地模拟验证
**Notes:** 验证优先级按独立性排列：磁盘检查 > B2 中断 > 验证下载

---

## Claude's Discretion

- 具体 df 检查命令和阈值计算方式
- rclone 参数调优
- 测试脚本详细构造

## Deferred Ideas

None — discussion stayed within phase scope
