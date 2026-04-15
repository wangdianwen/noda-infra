# Phase 20: Nginx 蓝绿路由基础 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-15
**Phase:** 20-nginx
**Areas discussed:** Upstream 抽离范围, Include 文件格式, 验证方式

---

## Upstream 抽离范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅 findclass | 只抽离 findclass_backend，严格遵循 Phase 范围 | |
| findclass + noda-site | 抽离两个蓝绿候选，为 noda-site 做准备 | |
| 全部三个 | 三个 upstream 全部抽离，保持配置风格一致 | ✓ |

**User's choice:** 全部三个
**Notes:** 保持配置风格一致，虽然 keycloak 短期无蓝绿需求，但统一抽离减少配置混乱

---

## Include 文件格式

| Option | Description | Selected |
|--------|-------------|----------|
| 纯 upstream 块 | 不加注释，Pipeline 直接重写整个文件 | ✓ |
| 带注释说明 | 添加文件头部注释说明用途和切换机制 | |

**User's choice:** 纯 upstream 块
**Notes:** 简洁，Phase 22 Pipeline 直接重写文件内容，无需解析/保留注释

---

## 验证方式

| Option | Description | Selected |
|--------|-------------|----------|
| 功能验证即可 | 验证 include 生效 + reload 切换生效，不测无中断 | ✓ |
| curl 循环测试 | reload 期间持续发请求，统计是否有失败 | |

**User's choice:** 功能验证即可
**Notes:** Phase 22 写部署脚本时再验证 reload 零中断性，Phase 20 专注配置变更正确性

---

## Claude's Discretion

- default.conf 中 upstream 块的具体替换写法
- snippets 目录文件加载顺序是否需调整
- 功能验证的具体步骤

## Deferred Ideas

None — discussion stayed within phase scope
