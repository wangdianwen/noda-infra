# 全站批量发布编排（noda-release-all）设计

日期：2026-10-08 ｜ 状态：已获用户方向拍板（批量一门 / 参数化子集+层 / 管线内治 / 方案 C）

## 背景与目标

用户痛点：
1. 每次 snagme 发布 r4s 卡死或接近卡死（单盘 weed 被 ~5 万对象上传打满）。
2. 发布流程不透明：如 Pre-prod 桶阶段静默跑 27 分钟，无任何进度说明。
3. 审批按钮「点了没反应」（已定案：匿名会话 + /input/ 空壳页；横幅修复 b3f29d5 已上线）。
4. 8 产品逐班发布太慢，需要「发布全站」一键能力。

硬要求（用户原话口径）：**任何等待必须说明在等什么、为什么、多久**——静默 = 卡死。

## 决策记录

- 审批粒度：8 班全部 preprod 验证后，出**一个批量审批门**。
- 范围：`PRODUCTS` 参数化子集（空=全部 8 站）+ `LAYER`（static/all）。
- r4s 治理：本轮管线内治（串行 + 产品间冷却 + 资源探针门禁）；结构治（迁出 r4s/加盘）另立项。
- 编排器形态：**方案 C 专用 Jenkins 编排 job**（noda-release-all）；noda-apps 单产品管线零改动。

## 架构

```
noda-release-all（新编排 job，Jenkinsfile.batch）
  Phase 1  逐产品（串行）：触发 noda-apps normal 班 → 等子班到审批门（不批）
           → 探活 preprod → TG「N/8 preprod 完成」→ 产品间资源探针+冷却
  Phase 2  一个批量审批门（input）：列出全部 preprod 链接+探活结果+失败清单
           ACTION: deploy_prod（跳过失败者）/ abort
  Phase 3  逐产品依次批子班 gate（deploy_prod）→ 探活 prod → TG「N/8 完成」
           任一失败：立即停，汇报精确状态与 -old 回滚锚点
```

子班（noda-apps）保持独立可用；编排 job 只是指挥家：触发、轮询、代批、汇报。

## 组件与接口

| 组件 | 职责 | 依赖 |
|---|---|---|
| `jenkins/Jenkinsfile.batch` | 三阶段编排逻辑 | 复用下列脚本 |
| `scripts/jenkins/trigger-and-approve.sh` | 触发子班（form POST+crumb，已有） | — |
| `scripts/jenkins/gate-action.sh <N> <ACTION>` | 代批子班审批门（Script Console 路径，已实测） | jenkins-admin.env |
| r4s `pipeline-resource-probe.sh` | 资源探针（key=value，已部署） | SSH r4s |
| `scripts/jenkins/tg-notify.sh` | TG 进度通知 | — |
| pendingInputActions API | 轮询子班是否到达审批门（GET，免认证） | — |

job 创建：`scripts/jenkins/init-jobs.groovy` 登记 + Script Console 一次性创建（配置即代码）。

## 关键行为

- **参数**：`PRODUCTS`（String，逗号分隔；空=class,www,admin,liuyao,nearby,auth,comment,snagme 全集）、`LAYER`（static/all）、`COOLDOWN_SECONDS`（默认 60）、`HEARTBEAT_INTERVAL`（默认 60s）。
- **等待可见性**：所有等待循环（子班出队/到门/探针超阈值）每 HEARTBEAT_INTERVAL 向 console 输出一行「⏳ 等待 X ｜ 原因 Y ｜ 已等 Ns ｜ 下一步 Z」；阶段转换发 TG。
- **Phase 1 失败语义**：子班 FAILURE/ABORTED → 记入失败清单，继续下一产品；批量门信息里明示。
- **探活口径**：static 班 = preprod URL HTTP 200；all 班 = preprod URL 200 + `<产品域>-preprod.noda.co.nz/api/health` 200。探活重试 3 次×10s，仍失败记 ✗。
- **Phase 2 批量门**：message 含每产品一行「产品 → preprod URL → 探活 ✓/✗ → 备注」；deploy_prod = 仅部署探活通过者。
- **Phase 3 失败语义**：子班 prod 失败 → 立刻停止后续产品；TG + console 汇报已完成/未完成清单、失败班号、对应 `-old` 回滚锚点；不自动回滚（人工决策）。
- **r4s 管线内治**：产品间探针判定沿用资源门禁五项口径（weed 健康/MemPerc<85%/avail≥500MB/load<8/无残留中继）；超阈值则心跳等待至恢复（上限 900s，超时中止批量并汇报）。
- **并发防护**：`disableConcurrentBuilds()`；批量班与手工单班撞锁时由现有 static-publish 锁自然串行，心跳里说明「在等锁，持有者 #N」。
- **fast 模式不进批量**：DEPLOY_MODE 固定 normal（fast 跳过审批门，与批量门语义冲突）。

## 错误处理

- 子班 6h 审批超时：Phase 1 轮询发现子班消失/FAILURE → 记失败清单。
- 编排班自身被 abort：已发出的子班门保持 pending，TG 提示需手工 gate-action 清理。
- TG 发送失败：静默降级（console 为准），不阻塞发布。

## 测试与验收

1. 上线即以小子集 `PRODUCTS=auth,liuyao`（小站，分钟级）跑真实批量：验证三门时序（子班门→批量门→子班门代批）、探活、TG、心跳。
2. 注入失败：子集里混一个会失败的班（如错误参数），验证失败清单与跳过语义。
3. prod 阶段中途 abort 编排班：验证汇报与 `-old` 锚点提示。
4. 全量 8 站首跑放低峰窗口，比对单班串发基线时长。

## 明确不做（本轮）

- Pre-prod 桶上传提速、`__next.*` 瘦身（另立拍板项，但与痛点 1 强相关）。
- 静态资产迁出 r4s / 加盘。
- noda-apps 单产品管线的任何改动。
