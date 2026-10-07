# 发版预期 SOP（noda-apps Jenkins 管线）

> 2026-10-07 治理基线，**#663/#664 端到端实测校准**（未变更路径 #663=458s；全量路径 #664=3783s）。
> 配套：`docs/api-startup-diagnosis-2026-10-07.md`（API 部署慢诊断）、`docs/superpowers/specs/2026-10-07-deploy-throughput-governance-design.md`。

## 一、改动类型 → 预期时长（snagme 50,780 对象实测校准）

| 改动类型 | Deploy Prod 预期 | 全程预期 | 实测依据 |
|---|---|---|---|
| **无内容变更**（同 tree 重发 / 注释类被 minifier 剥掉的改动） | 秒级（0.3s 指纹跳过） | **458s**（#663 实测，含 Build 213s+审批等待） | stg/prod 双跳过各 3s |
| **有内容变更·大站**（snagme；任何真实代码/样式改动都会全量重传） | **~8min**（#684 蓝绿首秀实测 489s：green 全量上传+对账+fs.mv 原子切换×2 各 ~40-60s；旧轮转路径 31min 已被取代，STATIC_BLUEGREEN=0 可回退） | **~15-18min**（不含人工审批等待） | #684 实测全程 17.8min 含 stg 71s + 审批延迟 5.5min |
| **蓝绿发布语义**（2026-10-07 e98bf11 起） | 切换=fs.mv 原子 rename，旧版保留 `sites/<product>-old`（免费回滚锚点）；发布期垃圾 92k→0（#680 的单盘 iowait 89% 根治） | — | 夜间 02:00 删 -old + volume.vacuum 0.3 清账（实测 vacuum 全量 1698s） |
| **有内容变更·小站**（<5k 对象） | 1-3min | 6-10min | 轮转/上传对象少 |
| **API（LAYER=api）** | ~8min（与静态并行时）；错峰 ~3.5-4min | — | 见诊断报告（docker 建容器停滞是主因） |
| fast 模式 | 跳过审批直发 | — | 仅紧急用 |

> ⚠️ **为什么「改一行 CSS」也要全量重传**：Turbopack chunk 图重排让共享 chunk 改名，全站每页 HTML/RSC 内嵌 chunk 文件名清单。#664 实证复现：1 条惰性 CSS 规则（页面无该元素、零视觉影响）→ 42,232 页变化（新增/删除恰好是新旧 css chunk 一对）。注意：**注释类改动会被 minifier 剥掉→产物零变化→走跳过路径**（#663 实证 tree 不变）。
>
> ⚠️ **上传/轮转吞吐受 weed 实时状态支配，波动 4-6 倍**：同一台 r4s、同并发，轮转 270s（暖缓存/低负载）↔ 1418s（高负载）；上传 42k 对象 21min（33 obj/s，经中继）。提高并发无增益（weed 饱和），1500s 轮转预算已盖住最坏观测值。

## 二、Deploy Prod 日志时间线怎么读（静态站，#664 实测锚点）

正常顺序与各段实测（snagme 50,780 对象）：

1. `队列门禁/部署锁` — 秒级；同产品发布中最多等 900-3600s（**stage 会提示「非卡死」**）。
2. `快照轮转 snagme -> snagme-prev` — **270s（状态好）～1418s（状态差）**，静默无输出属正常；预算 1500s/层（外层 2400s）。
3. `清单差量：上传 N、删除 M` — 大站真实变更典型 42k 对象 ~21min（经中继 33 obj/s）；**「上传 0 删除 0（零传输）」也是正常输出**。`清单 GET 耗时 ≥5s` 告警=weed 响应劣化提示，非阻断。
4. `对账`（桶列举 vs 源计数，重试 3 次）+ `指纹上送` — 数分钟（对账列举 50k 对象本身要几分钟，静默属正常）。
5. 探活/E2E — 秒级。

weed 性能参考（2026-10-07 双机实测）：r4s ~33-44 obj/s 饱和（并发无增益）；Mac stg 修复限额前 ~37 obj/s（GC 抖动）、限额后预期回升；**weed 内存**：sync 负载=空闲值 2.2 倍（r4s 1.39GiB/1.5GiB、stg 已放宽 768M→1536M），轮转/上传期间勿叠加百度备份等重 IO。

## 三、异常判据（什么才算真卡）

| 信号 | 含义 | 第一动作 |
|---|---|---|
| `桶内清单 GET 耗时 ≥5s` | weed 响应劣化（swap 债/GC 贴线/compaction） | r4s：看 MemAvailable/SwapFree + `docker stats seaweedfs`；Mac stg：`docker stats seaweedfs-stg`（MemPerc>85% 即 GC 抖动） |
| `快照轮转 _main 失败` | 轮转超 1500s 预算被杀，**回滚锚点部分混装** | 发布不受影响；尽快重跑一次轮转修复锚点（rclone sync 幂等） |
| `对账不平`（桶 N ≠ 源 M） | 镜像漏传/截断 | 管线自动全量 sync 收敛 3 次；3 次后仍不平才人工介入 |
| `指纹上送失败` | 撞 vacuum 只读窗口 | 仅告警：下次同内容重发走全量（自愈） |
| 审批 6h 超时记 FAILURE | 无人批准 | gate-action.sh 或浏览器补批；非部署故障 |
| Deploy Prod 整段 0 输出 >25min | 轮转静默（正常上限 ~24min）或真挂 | 看 `~/.jenkins/noda-apps/ws-*@tmp/durable-*/jenkins-log.txt` 与 r4s `docker ps` |

## 四、发版纪律（2026-10-07 起）

1. ~~静态与 API 发版不要同时跑~~ **已结构化（3141ed0）**：纯 API 班次的 Deploy Prod 会自动等待 `static-publish` 锁（最长 60min），静态与 API 并行互抢资源从锁层面排除；stage 日志可见「尝试获取部署锁 [static-publish]」的等待即此机制。
2. **资源门禁（fc56aec）**：Build 入口与 Deploy Prod 重取锁后各跑一次 `pipeline_resource_gate`——r4s 五项检查（weed 健康 / weed 内存 <85% / 可用内存 ≥500MB / 负载 <8 / 无残留中继），30s 轮询最长等 15min 自愈，超时本班不跑（FAIL 信息含排查指引）。swap 慢性债只告警不阻断。行为可调：`RESOURCE_GATE_WAIT_SECONDS`（等待上限）、`RESOURCE_GATE_MIN_FREE_MB`（内存地板）。探针缺失时 fail-open 放行（不会因探针故障瘫痪发版）。
3. snagme 大站有变更发版前确认 r4s `SwapFree` 与 `docker stats seaweedfs`（MemPerc）；高水位时轮转可能要 ~24min。
4. r4s 资源治理状态（2026-10-07）：weed 限额 2G（在线+落盘）；stg 限额 1536M（180e84e）；swap 债周清守卫已上线（周日 05:30，安全阈值+TG，2572036）——swap 满载的残余风险在首个安全窗口自动清偿，或人工 `docker restart immich_server`（释放 ~470MB 冷页，最快）。
4. 想测「跳过路径」别用注释——会被 minifier 剥掉（#663）；产物不变就走跳过，这是设计行为。
