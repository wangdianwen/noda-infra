# Jenkins 发版链路完全治理（SP1+SP3+SP4）— 设计文档

- 日期：2026-10-07
- 状态：已批准（用户确认范围 SP1+SP3+SP4；SP2 构建侧手术明确不做）
- 关联：dda2be9（轮转/上传提速，已推 main）；#660 复盘结论

## 背景与实证（2026-10-07 查明）

**问题1「审批后不立即部署」**：审批通道无 bug（浏览器 Proceed 7-31s 生效、无 400、无自动批准进程）。延迟全在 Deploy Prod 内部：

| 环节 | 实测（#660 snagme static） | 根因 |
|---|---|---|
| prod 快照轮转 | 929s，主层 900s 预算到点被杀（WARN_main 只告警） | snagme 50,778 对象 @ r4s transfers=32 ≈ 54 obj/s 需 926s > 900s 预算，**必然超时**；回滚锚点 snagme-prev 因此处于「旧文件+部分新文件」混装态 |
| 差量上传 | 685s（42,219 对象 ≈ 61 obj/s @ 16 并发） | 单连接 ~262ms 延迟主导，并发不足 |
| stg 轮转 | 204s ≈ 245 obj/s @ 32 并发（Mac 本机 weed） | 无问题（对照组） |

API 产品（#661 nearby）：批准后 4s 即 docker push（40s 完成）；大头是容器 boot→healthy **210s**（r4s 可用内存仅 947MB 告警；**容器内存限制 256MB**；-next 与 prod 两容器均 ~200s，稳定复现，非偶发）+ 蓝绿切流 84s + jobs/E2E。

**问题2「snagme 无增量」**：构建确定性已铁证（同源码连建两次 0 diff；补 `NEXT_PUBLIC_GA4_SNAGME_ID` 后重建与 #660 产物逐字节一致）。真正根因是 **Turbopack chunk 重排放大器**：f3339274 改 1 文件 11 行 → 1 个 antd locale chunk 改名（3tt0t6v60mnzj→134rpq4hi2vyp）→ 42,219 个引用它的 html+txt（8445+33774）内容全变 → 全量重传。页面 diff 仅 chunk 文件名不同。

**dda2be9 已落地**（本设计的前提）：prod 轮转 32→64 并发/校验 64→128/单层 900→1500s/外层 1800→2400s；差量上传 16→32 并发；stg 轮转 64/128。同内容 0.3s 跳过不受影响。

## SP2 劝退记录（决策留档）

构建侧 chunk 治理不做：即使 antd 等三方库分到独立稳定 chunk，app 自有组件（如 AnalyticsConsent，挂根 layout）仍会随代码改动重命名，而它被 42k 页每页引用；抽静态脚本需重写 consent/i18n/共享存储且三站同改，只救低频场景。正解=传输地板（SP1）+预期管理（SP4）。

## SP1 静态发版地板

### 1. r4s weed 并发压测（受控，临时前缀）
- 前置检查：r4s weed 数据盘剩余空间、`weed shell volume.list` 空闲槽位、free 内存基线。任一不足则降级为只测 64。
- 步骤：
  1. 经与管线相同的 r4s 本机 rclone，从 `sites/snagme/` 服务端复制 ~5,000 对象到临时前缀 `sites/zzz-bench-src/`；
  2. `zzz-bench-src → zzz-bench-dst` 服务端 sync：先 64 并发计时，清 dst 后再 128 并发计时；
  3. 全程采样 `docker stats weed`（MEM%）、r4s free 内存；中止判据（可执行）：r4s free < 300MB，或 weed 容器内存较压测前基线翻倍，或出现 D 状态进程——任一命中立即中止当前轮次，并发定格 64。
- 判定：128 相比 64 提速 >1.3× 且内存平稳 → 管线改 128（一行改动）；否则维持 64。
- 清理：删除 `sites/zzz-bench-src|dst/` 全部对象并复核为 0。
- 产出：压测报告（速率、内存曲线、结论）。

### 2. 真实轮转 + 锚点修复
- 用胜出并发值，在 r4s 上执行与管线 `_static_snapshot_rotate_prod` 逐字节等价的单次轮转（`sites/snagme/ → sites/snagme-prev/`，--max-duration 1500s）。
- 验收：①完成（ROTATE_DONE，无 WARN_main）；②`snagme-prev` 对象数 = `snagme` 对象数；③两前缀 `.noda-manifest` 内容哈希一致 → 回滚锚点从混装损坏态修复为干净快照。
- 注意：轮转期间 prod 前缀只读不受影响；轮转失败不回滚（快照层失败本就不阻塞发布），如实记录。

### 3. 观测闭环
- 下次真实 snagme 发版（含内容变更）后，抓取 wfapi 时间线对比：预期 Deploy Prod ≤ 10min（轮转 ~460s + 上传 ~350s + 探活对账）；不达标回到 SP1.1 重新调参。

## SP3 API 启动诊断（只诊断，零改动）

- 证据链：
  1. `docker logs noda-api-prod --since <13:08:00Z> --until <13:10:30Z>`：当前 prod 容器与 -next 同镜像同启动路径，其首 200s 日志即启动解剖（迁移/监听就绪时点）；
  2. compose/Dockerfile/entrypoint：迁移在哪一步跑、healthcheck 命令与 5s 间隔判定链；
  3. `docker stats noda-api-prod` 当前用量 vs 256MB 限制、RestartCount/OOMKilled；
  4. r4s 磁盘/内存基线（idle 采样）。
- 产出：诊断报告——把 210s 拆解为「迁移 / 应用就绪 / 健康判定」三段，各归因（CPU/IO/内存限 256MB/迁移 SQL），给出两条路的成本估算供立项决策：A) r4s 内存治理（含容器限额调整）；B) 应用侧启动优化（迁移拆分/延迟建连等，属 noda-apps）。**不改任何配置、不重启任何容器。**

## SP4 发版预期 SOP

- 新建 `docs/deploy-expectations.md`（noda-infra）：
  - 改动类型 → 预期时长表：无内容变更=Build+0.3s 跳过（全程 ~5-6min）；仅 chunk 图重排（含 11 行级小改）=全站重传，Deploy Prod 预期 12-15min（治理后）；全站文案批=同上；API normal=5-8min（健康门 200s 是当前物理地板，见 SP3 报告）；fast 模式语义。
  - Deploy Prod 日志时间线怎么读（轮转→清单差量→对账→指纹→探活的正常顺序与各段预算）。
  - 异常判据：什么情况算真卡（清单 GET ≥5s 哨兵、WARN_main、对账不平）与对应第一动作。
- 完成后把关键结论同步进 auto-memory 与 hindsight。

## 验收标准

1. 压测报告：64 vs 128 速率 + 内存曲线 + 最终并发决策；
2. snagme-prev 锚点修复：对象数一致 + 清单哈希一致，且管线口径（1500s 预算）下实测完成；
3. `docs/deploy-expectations.md` 入库（含压测/轮转实测数据）；
4. SP3 诊断报告（210s 三段拆解 + 立项建议），零改动；
5. （条件）若 128 胜出：pipeline-stages.sh 一行改动 + bash -n + 推送。

## 回滚与安全边界

- 压测与轮转只新建/覆盖快照前缀与临时前缀，不触碰 `sites/snagme/`（线上内容）本体；临时前缀测毕即删。
- 全程不重启 weed、不动容器、不改 Jenkinsfile；唯一的代码改动路径是「128 胜出」的一行并发值。
- 若压测显示 64 并发下 weed 内存已不稳，回退方案=把 dda2be9 的传输值下调（32）并依赖 1500s 预算兜底（旧速率 926s < 1500s 仍能完成）。
