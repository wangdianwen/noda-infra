# 发版链路完全治理（SP1+SP3+SP4）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把静态站发版传输地板实测出来并调到位、修复 snagme-prev 回滚锚点、诊断 API 启动 210s（零改动）、把发版预期固化成 SOP 文档。

**Architecture:** 全部操作经 `ssh root@192.168.100.1` 到 r4s，rclone 以 `docker run --rm alpine/socat` 一次性容器跑（与管线 `_static_snapshot_rotate_prod` 逐字节同款 wrapper）；压测用临时前缀 `sites/zzz-bench-*`，真实轮转覆盖 `sites/snagme-prev/`（快照前缀，非线上内容）；SP3 只读日志与 inspect；产出两份文档入库。

**Tech Stack:** r4s OpenWrt（BusyBox ash、docker）、SeaweedFS S3、rclone（/opt/noda/bin/rclone 容器内挂载）、macOS 本地 Jenkins/管线仓库。

**Spec:** `docs/superpowers/specs/2026-10-07-deploy-throughput-governance-design.md`

## Global Constraints

- 不触碰 `SW:noda-static/sites/snagme/`（线上内容只读）；只允许写 `sites/zzz-bench-src|dst/`（测毕删）与 `sites/snagme-prev/`（快照锚点）。
- 全程不重启 weed、不重启任何容器、不动 Jenkinsfile。唯一代码改动路径：128 并发胜出时 `scripts/pipeline-stages.sh` 的一行传输值。
- 中止判据（压测/轮转全程监测，任一命中立即中止当前轮次）：r4s free < 300MB；weed 容器内存较基线翻倍；出现 D 状态进程。
- r4s 是 BusyBox：`ps -eo`/`stat` 等 GNU 选项不可用；D 状态用 `grep -c '(D' /proc/[0-9]*/stat`。
- S3 凭据运行时从 r4s `/etc/noda/jobs.env` 提取（`S3_ACCESS_KEY`/`S3_SECRET_KEY`），不落任何文档/日志。
- rclone 服务端 copy/sync 为准；禁用 `--fast-list`（weed listing 截断雷，见仓库记忆）。
- 提交信息沿用仓库风格：中文单行、含实证数据与决策依据；每次 push 前 `bash -n scripts/pipeline-stages.sh`（若改动）。
- 参照基线：#660 实测 50,778 对象、轮转 929s 被杀（transfers=32）、差量上传 685s（16 并发）、stg 轮转 204s（Mac weed @32）；dda2be9 后管线配置 64/1500s/2400s。

---

### Task 0: 前置检查与基线采样（go/no-go）

**Files:**
- Create: 无（数据进 Task 8 文档）

**Interfaces:**
- Produces: `WEED_CONTAINER`（weed 容器名）、`AK`/`SK`（凭据，仅 shell 变量）、基线内存/磁盘/槽位数值；go/no-go 结论供后续任务消费。

- [ ] **Step 1: 找 weed 容器名与数据盘**

```bash
ssh root@192.168.100.1 "docker ps --format '{{.Names}}\t{{.Status}}'"
ssh root@192.168.100.1 "docker inspect <weed容器名> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'"
```
Expected: 列出 weed（或 seaweedfs）容器名；数据卷 Source 路径（记为 `WEED_DATA_DIR`）。

- [ ] **Step 2: 磁盘/内存/槽位基线**

```bash
ssh root@192.168.100.1 "df -m <WEED_DATA_DIR> | tail -1"
ssh root@192.168.100.1 "free -m | awk 'NR==2{print \"free=\"\$7\"MB\"}'"
ssh root@192.168.100.1 "docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep -i weed"
ssh root@192.168.100.1 "docker exec <weed容器名> sh -c 'echo volume.list | weed shell' 2>/dev/null | grep -E 'free|Free' | head -3"
```
Expected: 数据盘余量 >5G；free >600MB；记录 weed 当前 MemUsage 作为基线 `WEED_MEM_BASELINE`；volume.list 有 free 槽位（>20）。
**No-go 处置**：任一不满足 → 按 spec 降级为「只测 64 并发」，跳过 Task 2 的 128 轮次（其余任务不变）。

- [ ] **Step 3: 提取凭据并验证 S3 可用**

```bash
AK=$(ssh root@192.168.100.1 "grep -E '^S3_ACCESS_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" | tr -d '\r')
SK=$(ssh root@192.168.100.1 "grep -E '^S3_SECRET_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" | tr -d '\r')
ssh root@192.168.100.1 "docker run --rm --network noda-network -v /opt/noda/bin/rclone:/usr/local/bin/rclone -e RCLONE_CONFIG_SW_TYPE=s3 -e RCLONE_CONFIG_SW_PROVIDER=Other -e RCLONE_CONFIG_SW_ENDPOINT=http://seaweedfs:8333 -e RCLONE_CONFIG_SW_ACCESS_KEY_ID=$AK -e RCLONE_CONFIG_SW_SECRET_ACCESS_KEY=$SK --entrypoint /usr/local/bin/rclone alpine/socat lsf SW:noda-static/sites/ --max-depth 1"
```
Expected: 列出 snagme、snagme-prev、liuyao 等前缀（凭据有效）。定义 shell 函数 `swr()`（包装上述 docker run，参数为 transfers/checkers + rclone 子命令）供后续任务复用：

```bash
swr() { local t=$1 ck=$2; shift 2; ssh root@192.168.100.1 "docker run --rm --network noda-network -v /opt/noda/bin/rclone:/usr/local/bin/rclone -e RCLONE_CONFIG_SW_TYPE=s3 -e RCLONE_CONFIG_SW_PROVIDER=Other -e RCLONE_CONFIG_SW_ENDPOINT=http://seaweedfs:8333 -e RCLONE_CONFIG_SW_ACCESS_KEY_ID=$AK -e RCLONE_CONFIG_SW_SECRET_ACCESS_KEY=$SK -e RCLONE_TRANSFERS=$t -e RCLONE_CHECKERS=$ck --entrypoint /usr/local/bin/rclone alpine/socat $*"; }
```

### Task 1: 创建压测源前缀（5000 对象）

**Files:** 无仓库文件改动。

**Interfaces:**
- Consumes: Task 0 的 `swr()`。
- Produces: `SW:noda-static/sites/zzz-bench-src/`（约 5000 对象）；创建耗时（记录）。

- [ ] **Step 1: 服务端复制并计时**

```bash
start=$(date +%s)
swr 64 128 copy "SW:noda-static/sites/snagme/_next/static/chunks/" "SW:noda-static/sites/zzz-bench-src/chunks/" --no-traverse
echo "elapsed=$(( $(date +%s) - start ))s"
swr 64 128 lsf -R --files-only "SW:noda-static/sites/zzz-bench-src/" | wc -l
```
Expected: 对象数 ≈5000（chunks 子树约 5 万对象的前 5000 个左右；若 chunks 子树不足 5000，补拷 `media/` 子树）；`copy` 无报错退出。若对象数超 8000 或不足 3000，记录实际值即可（影响的是压测时长，不影响速率结论）。

### Task 2: 64 vs 128 并发压测（含内存监测）

**Files:** 无仓库文件改动。

**Interfaces:**
- Consumes: Task 1 的 bench 前缀、Task 0 的 `WEED_MEM_BASELINE`。
- Produces: `RATE_64`、`RATE_128`（obj/s）、全程内存曲线（r4s /tmp/bench-mem.log）、决策 `FINAL_TRANSFERS`（64 或 128）。

- [ ] **Step 1: 启动内存采样器（r4s 后台）**

```bash
ssh root@192.168.100.1 "nohup sh -c 'while true; do echo \"\$(date +%T) free=\$(free -m | awk \"NR==2{print \\\$7}\")MB weed=\$(docker stats --no-stream --format \"{{.MemUsage}}\" | grep -i weed)\"; sleep 5; done' > /tmp/bench-mem.log 2>&1 & echo started"
```
Expected: 输出 `started`；`ssh root@192.168.100.1 "tail -2 /tmp/bench-mem.log"` 可见采样行。

- [ ] **Step 2: 64 并发轮次**

```bash
start=$(date +%s)
swr 64 128 sync "SW:noda-static/sites/zzz-bench-src/" "SW:noda-static/sites/zzz-bench-dst/" --max-duration 1500s
echo "elapsed=$(( $(date +%s) - start ))s"
```
Expected: 无报错；记 `RATE_64 = 对象数 / elapsed`（对象数来自 Task 1）。对照：5000 对象若 20-80s → 62-250 obj/s 即正常带。

- [ ] **Step 3: 清空 dst，128 并发轮次**

```bash
swr 64 128 delete "SW:noda-static/sites/zzz-bench-dst/" --rmdirs || true
start=$(date +%s)
swr 128 256 sync "SW:noda-static/sites/zzz-bench-src/" "SW:noda-static/sites/zzz-bench-dst/" --max-duration 1500s
echo "elapsed=$(( $(date +%s) - start ))s"
```
Expected: 无报错；记 `RATE_128`。

- [ ] **Step 4: 检查中止判据**

```bash
ssh root@192.168.100.1 "tail -40 /tmp/bench-mem.log"
ssh root@192.168.100.1 "free -m | awk 'NR==2{print \$7}'"
ssh root@192.168.100.1 "grep -c '(D' /proc/[0-9]*/stat 2>/dev/null | grep -v ':0' | head -5"
```
Expected: free 全程 >300MB；weed 内存未超 `WEED_MEM_BASELINE` 的 2 倍；无 D 状态。**若违反**：`FINAL_TRANSFERS=64` 直接定案，128 轮次数据标注「触发中止判据，不可用」。

- [ ] **Step 5: 决策**

```bash
# 停采样器
ssh root@192.168.100.1 "pkill -f bench-mem || true"
```
决策规则（照 spec）：`RATE_128 > RATE_64 × 1.3` 且 Step 4 全绿 → `FINAL_TRANSFERS=128`；否则 `FINAL_TRANSFERS=64`。把两个速率与决策写入执行记录。

### Task 3: 清理压测前缀

**Files:** 无。

**Interfaces:**
- Consumes: Task 1/2 的 bench 前缀。
- Produces: 桶内无 zzz-bench-*（验收给 Task 8 文档引用）。

- [ ] **Step 1: purge 两个前缀**

```bash
swr 64 128 purge "SW:noda-static/sites/zzz-bench-src/"
swr 64 128 purge "SW:noda-static/sites/zzz-bench-dst/"
swr 64 128 lsf "SW:noda-static/sites/" --max-depth 1 | grep zzz-bench
```
Expected: 最后一条命令无输出（前缀已不存在）。若 purge 不被 weed 支持，退化为 `delete --rmdirs` 后复查。

### Task 4: 真实轮转 + 锚点修复（snagme → snagme-prev）

**Files:** 无仓库文件改动。

**Interfaces:**
- Consumes: Task 2 的 `FINAL_TRANSFERS`。
- Produces: 干净的 `sites/snagme-prev/`；实测轮转时长 `ROTATE_SECONDS`（50,778 对象 @ FINAL_TRANSFERS）。

- [ ] **Step 1: 重启采样器，执行轮转**

```bash
# 采样器启动同 Task 2 Step 1
start=$(date +%s)
swr $FINAL_TRANSFERS $((FINAL_TRANSFERS*2)) sync "SW:noda-static/sites/snagme/" "SW:noda-static/sites/snagme-prev/" --max-duration 1500s
ROTATE_SECONDS=$(( $(date +%s) - start ))
echo "ROTATE_SECONDS=$ROTATE_SECONDS"
```
Expected: 退出码 0，无超时截断；`ROTATE_SECONDS` 显著小于 926s（#660 在 32 并发下的需求）。**若 1500s 内未完成**：记录实际时长，并发决策降级讨论（回 32+1500s 预算也能完成，属 spec 回退路径），并在执行记录中标注。
注：此命令与管线 `_static_snapshot_rotate_prod` 的主层 sync 语义逐字节等价（同 wrapper、同 --max-duration、同 SW 路径），只是外层单次调用。

- [ ] **Step 2: 停采样器并检查判据**（同 Task 2 Step 4 命令）
Expected: 三项全绿；把轮转期间内存曲线归档到 /tmp/bench-mem.log（后续粘进文档）。

### Task 5: 锚点完整性验收

**Files:** 无。

**Interfaces:**
- Consumes: Task 4 的轮转结果。
- Produces: 验收结论（对象数一致 + 清单哈希一致），写进 Task 8 文档。

- [ ] **Step 1: 对象数对账**

```bash
swr 64 128 lsf -R --files-only "SW:noda-static/sites/snagme/" | wc -l
swr 64 128 lsf -R --files-only "SW:noda-static/sites/snagme-prev/" | wc -l
```
Expected: 两数相等（约 50,780）。

- [ ] **Step 2: 清单哈希对账**

```bash
swr 64 128 cat "SW:noda-static/sites/snagme/.noda-manifest" | shasum -a 256
swr 64 128 cat "SW:noda-static/sites/snagme-prev/.noda-manifest" | shasum -a 256
```
Expected: 两哈希相等 → 回滚锚点从混装损坏态修复为与线上一致的干净快照。**若不等**：说明轮转有遗漏对象，重跑 Task 4 Step 1 一次（sync 幂等）后再验；连续两次不等则升级为问题记录（不阻塞其余任务）。

### Task 6:（条件）128 胜出时更新管线并发值

**Files:**
- Modify: `scripts/pipeline-stages.sh`（仅当 `FINAL_TRANSFERS=128`；否则本任务整段跳过）

**Interfaces:**
- Consumes: Task 2 决策。
- Produces: 管线 prod 轮转/差量上传/stg 轮转的传输值与实测结论一致。

- [ ] **Step 1: 三处替换（仅 128 胜出时执行）**

`scripts/pipeline-stages.sh` 中：`-e RCLONE_TRANSFERS=64 -e RCLONE_CHECKERS=128`（prod 轮转 docker run 行）→ `=128/=256`；`RC_TRANSFERS=32 RC_CHECKERS=64`（差量上传 copy 行）→ `RC_TRANSFERS=128 RC_CHECKERS=256`；stg 轮转两处 `RC_TRANSFERS=64 RC_CHECKERS=128` → `128/256`。注释里的数字说明同步改（64→128、「#660 实测 ~54 obj/s」等措辞保留）。

- [ ] **Step 2: 语法检查、提交、推送**

```bash
bash -n scripts/pipeline-stages.sh && echo "SYNTAX OK"
git add scripts/pipeline-stages.sh
git commit -m "fix(pipeline): weed 并发压测实证 128 优于 64（<填 Task 2 实测速率>）——轮转/差量上传/stg 轮转传输值 64→128；内存曲线平稳（free 最低 <填值>MB）"
git push origin main
```
Expected: SYNTAX OK；push 成功。若 `FINAL_TRANSFERS=64`，在执行记录写明「维持 64，无代码改动」。

### Task 7: SP3 — API 启动 210s 诊断（零改动）

**Files:**
- Create: `docs/api-startup-diagnosis-2026-10-07.md`

**Interfaces:**
- Produces: 诊断报告（210s 三段拆解 + 立项建议）；零配置/零容器改动。

- [ ] **Step 1: 当前 prod 容器启动日志解剖**

```bash
ssh root@192.168.100.1 "docker logs noda-api-prod --since 2026-10-06T13:08:20Z --until 2026-10-06T13:10:30Z 2>&1 | head -80"
```
Expected: 可见启动序列（迁移输出/DB 连接/HTTP 监听就绪时点）。记录三个时点：进程启动、迁移完成、监听就绪。**若日志已轮转不可得**：改用 `docker inspect --format '{{.State.StartedAt}} {{.State.Health.Status}}'` + compose healthcheck 定义推断，并在报告注明证据缺口。

- [ ] **Step 2: healthcheck 与启动序列定义**

```bash
ssh root@192.168.100.1 "docker inspect noda-api-prod --format '{{json .Config.Healthcheck}}' | python3 -m json.tool"
ssh root@192.168.100.1 "docker inspect noda-api-prod --format 'RestartCount={{.RestartCount}} OOMKilled={{.State.OOMKilled}} Mem={{.HostConfig.Memory}}'"
```
并在本机 noda-apps 检出（`/Users/dianwenwang/Project/noda-apps`）中查 compose/entrypoint：`grep -rn "migrate\|healthcheck\|/api/health" docker/ deploy/ --include="*.yml" --include="*.sh" -l | head`，读 noda-api 的 compose 段与 entrypoint，确认迁移在哪一步跑（独立命令还是 entrypoint 内嵌）。

- [ ] **Step 3: 运行期内存 vs 256MB 限制**

```bash
ssh root@192.168.100.1 "docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.MemPerc}}' | grep -E 'noda-api|noda-jobs'"
```
Expected: 记录当前用量与限制（268435456B=256MB）的距离；RestartCount/OOMKilled 状态。结合 #661 现场「r4s 可用内存 947MB」告警与 global 约束写归因。

- [ ] **Step 4: 写诊断报告并提交**

`docs/api-startup-diagnosis-2026-10-07.md` 结构：结论先行（210s 主因归档）；证据（上面各命令输出摘录）；三段拆解表（迁移/应用就绪/健康判定，各段时长与归因）；两条立项路径成本估算（A: r4s 内存治理——含 256MB 限额是否合理；B: noda-apps 启动优化——迁移拆分/延迟建连），各列「预期收益/工作量/风险」；明确本次零改动。

```bash
git add docs/api-startup-diagnosis-2026-10-07.md
git commit -m "docs(report): noda-api 启动 210s 诊断——<一句话主因>；零改动，立项建议 A/B 成本对比"
git push origin main
```

### Task 8: SP4 — 发版预期 SOP 文档

**Files:**
- Create: `docs/deploy-expectations.md`

**Interfaces:**
- Consumes: Task 2 的 `RATE_64`/`RATE_128`/决策、Task 4 的 `ROTATE_SECONDS`、Task 5 的验收结果、Task 7 的诊断主因、#660/#661 历史实测。
- Produces: 发版预期对照表 + 日志时间线解读 + 异常判据（运维 SOP，供人和 agent 查）。

- [ ] **Step 1: 写文档**（以下为完整内容骨架，尖括号处绑定本计划前序任务的实测值；文档为单一信息源，写完删掉本计划的中间文件依赖）

```markdown
# 发版预期 SOP（noda-apps Jenkins 管线）

> 2026-10-07 治理后基线。数据来源：#660 复盘 + 2026-10-07 weed 压测/轮转实测。

## 改动类型 → 预期时长

| 改动类型 | Deploy Prod 预期 | 全程预期 | 说明 |
|---|---|---|---|
| 无内容变更（同 sha/同 tree 重发） | 秒级（0.3s 指纹跳过） | ~5-6min | Build 是物理下限 |
| 仅 chunk 图重排（小改 app 组件/文案类） | <全站重传，<填 ROTATE_SECONDS>s 轮转 + <上传>s | 12-18min | Turbopack 放大器：1 chunk 改名→42k 页全变（#660 实证 42,219 页） |
| 全站文案批（JSON-LD/共享串） | 同上 | 同上 | 内容真变，全量是正确行为 |
| API（LAYER=api） | 5-8min | — | 健康 200s 是当前地板（见 api-startup-diagnosis） |
| fast 模式 | 跳审批直发 | — | 仅紧急用 |

## Deploy Prod 日志时间线怎么读
（顺序：队列门禁→快照轮转→清单差量→对账→指纹上送→探活；各段预算与正常耗时，引用 Task 4 实测）

## 异常判据
- 「清单 GET 耗时 ≥5s」告警=weed 响应劣化，查 r4s swap/cgroup，非管线问题
- 「快照轮转 _main 失败」=轮转超预算（治理后 1500s 预算，50k 对象 @<FINAL_TRANSFERS> 并发实测 <ROTATE_SECONDS>s，不应再出现；出现则并发值失效需复查）
- 对账不平告警=镜像漏传，管线自动全量 sync 收敛 3 次；仍不平才人工
- 审批 6h 超时=无人批准记 FAILURE，非部署故障
```

- [ ] **Step 2: 提交推送**

```bash
git add docs/deploy-expectations.md
git commit -m "docs(sop): 发版预期对照表+日志时间线解读+异常判据——2026-10-07 治理基线（weed 压测 <RATE_64>/<RATE_128> obj/s、snagme 轮转 <ROTATE_SECONDS>s 实测）"
git push origin main
```

### Task 9: 收尾——记忆同步与总结

**Files:**
- Modify: auto-memory `jenkins-static-deploy-26k-diff.md`（追加治理结果一行）

**Interfaces:**
- Consumes: 全部前序任务结论。
- Produces: hindsight retain（bank=noda-infra）+ auto-memory 更新 + 面向用户的总结（速率、锚点修复、API 诊断主因、SOP 位置）。

- [ ] **Step 1: hindsight retain**（tags: jenkins, weed-bench, closed-loop；内容=最终并发决策与实测速率、锚点修复验收、API 诊断主因、SOP 路径）
- [ ] **Step 2: auto-memory 追加**（在 `jenkins-static-deploy-26k-diff.md` 的 #660 复盘小节后补一行治理结果：压测速率、FINAL_TRANSFERS、ROTATE_SECONDS、文档路径）
- [ ] **Step 3: 向用户汇报**（完成什么/实测数字/下次发版预期/SP3 立项建议要点）

---

## Self-Review 记录

1. **Spec 覆盖**：spec SP1.1 压测→Task 0-3；SP1.2 轮转+锚点→Task 4-5；SP1.3 观测闭环→属「下次真实发版后」，不在本计划内（依赖用户触发发版），已在 Task 9 汇报中说明为遗留观测项；SP3→Task 7；SP4→Task 8；条件代码改动→Task 6；回滚与安全边界→Global Constraints+Task 2 Step 4/Task 4 Step 1。无缺口（观测闭环为 spec 明示的后续验证，非本次交付物）。
2. **占位符扫描**：Task 6/8 的 `<填实测值>` 为数据绑定指令（指向具体任务的输出），非 TBD；Task 7 的证据缺口有明确退化路径。无「适当处理」类空话。
3. **一致性**：`FINAL_TRANSFERS`（Task 2 产出 → Task 4/6/8 消费）、`ROTATE_SECONDS`（Task 4 → Task 8）、`swr()`（Task 0 定义 → Task 1-5 使用）命名一致；swr 参数序 (transfers, checkers, rclone args…) 各调用一致。
