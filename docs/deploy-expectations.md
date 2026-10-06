# 发版预期 SOP（noda-apps Jenkins 管线）

> 2026-10-07 治理基线。数据来源：#660/#661 复盘 + 当日 weed 压测与 snagme 真实轮转实测。
> 配套：`docs/api-startup-diagnosis-2026-10-07.md`（API 部署慢诊断）、`docs/superpowers/specs/2026-10-07-deploy-throughput-governance-design.md`。

## 一、改动类型 → 预期时长

| 改动类型 | Deploy Prod 预期 | 全程预期 | 说明 |
|---|---|---|---|
| **无内容变更**（同 sha 重发 / docs-only） | 秒级（0.3s 指纹跳过） | ~5-6min | Build 是物理下限；跳过时「内容未变更，跳过镜像与快照」 |
| **有内容变更·大站**（snagme 50,780 对象） | **24-30min**（现状 swap 债拖累；swap 清偿后预期 16-20min） | 现状 45-60min | 构成见下方时间线；stg 桶发布（审批前）还要再付一轮轮转+上传 |
| **有内容变更·小站**（liuyao/class/admin/nearby/www/auth/comment，<5k 对象） | 1-3min | 6-10min | 轮转/上传对象少，分钟级 |
| **API（LAYER=api）** | ~8min（现状）；与静态发版错峰后 ~3.5-4min | — | 大头= docker 容器创建停滞（争抢期 191s，错峰后秒级）+ 切流 84s + E2E ~2.5min；应用启动仅 15s（见诊断报告） |
| fast 模式 | 跳过审批直发 | — | 仅紧急用；跳过的是 Human Approval 门 |

> ⚠️ **为什么「改 11 行代码」也要全量重传**：Turbopack chunk 图重排会让共享 chunk 改名，全站每个页面的 HTML/RSC 都内嵌 chunk 文件名清单（#660 实证：1 文件 11 行 → 42,219 页变化）。这是内容真实变化（引用变了），不是管线故障；已论证构建侧改造 ROI 差，接受它、把传输打快是正解。

## 二、Deploy Prod 日志时间线怎么读（静态站）

正常顺序与各段现状预算（snagme 50,780 对象 @ 64 并发实测）：

1. `队列门禁/部署锁` — 秒级；若他人在发同产品/静态发布中，最多等 900-3600s（**stage 会提示「非卡死」**）。
2. `快照轮转 snagme -> snagme-prev` — **实测 1418s**（2026-10-07，swap 满载态）；此步**静默无输出属正常**，预算 1500s/层（外层 2400s）。swap 清偿后预期 ~950s。
3. `清单差量：上传 N、删除 M` — 按变更对象数；历史 42k 对象 685s（16 并发），现 32 并发更快；**「上传 0 删除 0（零传输）」也是正常输出**。
4. `对账`（桶列举 vs 源计数，重试 3 次）+ `指纹上送` — 秒级~2min（撞 weed vacuum 窗口时有 45s 退避重试）。
5. 探活/E2E — 秒级。

weed 性能参考（2026-10-07 实测，r4s 本机服务端 copy/sync）：**~44 obj/s 饱和**（64 与 128 并发无差异，瓶颈不在并发）；swap 满载态全量轮转 ~36 obj/s；健康态历史值 ~54-61 obj/s。**weed 内存**：sync 负载下 621MiB→1.39GiB（空闲值 2.2 倍，容器限额 1.5GiB），轮转期间不要叠加百度备份等重 IO。

## 三、异常判据（什么才算真卡）

| 信号 | 含义 | 第一动作 |
|---|---|---|
| `桶内清单 GET 耗时 ≥5s` | weed 响应劣化（swap 债/cgroup/compaction） | 查 r4s：`cat /proc/meminfo`（看 MemAvailable/SwapFree）+ `docker stats seaweedfs`；非管线问题 |
| `快照轮转 _main 失败` | 轮转超 1500s 预算被杀，**回滚锚点部分混装** | 发布本身不受影响；尽快重跑一次轮转修复锚点（rclone sync 幂等） |
| `对账不平`（桶 N ≠ 源 M） | 镜像漏传/截断 | 管线自动全量 sync 收敛 3 次；3 次后仍不平才人工介入 |
| `指纹上送失败` | 撞 vacuum 只读窗口 | 仅告警：下次同内容重发走全量（自愈），不影响本次发布完整性 |
| 审批 6h 超时记 FAILURE | 无人批准 | gate-action.sh 或浏览器补批；非部署故障 |
| Deploy Prod 整段 0 输出 >25min | 轮转静默（正常上限 ~24min）或真挂 | 看 `~/.jenkins/noda-apps/ws-*@tmp/durable-*/jenkins-log.txt`（实时日志）与 r4s `docker ps`（有无 tmp-s3-relay / rotate 容器） |

## 四、发版纪律（2026-10-07 起建议）

1. **静态与 API 发版不要同时跑**：跨层锁不互斥，r4s 单机资源会互抢（#661 的 191s 容器创建停滞即实证）。串行发。
2. snagme 这类大站的有变更发版前，确认 swap 水位（`SwapFree`）；满载时轮转要 ~24min 且 weed 内存逼近限额。
3. r4s 资源治理（swap 清偿、跨层串行化、weed 限额评估）为独立立项，见诊断报告路径 A。
