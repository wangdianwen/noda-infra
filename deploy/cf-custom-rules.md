# Cloudflare 自定义规则清单（两 zone）与 UA 规则演变

> 权威源=CF API（entrypoint ruleset, phase `http_request_firewall_custom`）。
> 本文件是留档快照；ip-ban.py 每 5 分钟 get→改黑名单/dc→put 回写，**其余规则原样透传**——
> 手工改规则走 API 或面板均可，改完无需动 ip-ban.py。
> 核验命令：见文末。

## 规则清单（2026-10-25 快照）

### noda.co.nz（5 条自定义 + 1 条限速，按求值顺序）

| # | 描述 | action | 维护方 |
|---|---|---|---|
| 1 | admin non-NZ managed challenge | managed_challenge | 手工（后台入口仅 NZ 访问） |
| 2 | block empty/fake/script user agent | block | 手工（本次加严，见下） |
| 3 | cn-traffic-managed-challenge（cf.client.bot 豁免，10-25 补） | managed_challenge | 手工 |
| 4 | ip-range-blacklist auto（10-25 精简至 7 段） | block | ip-ban.py 自动 |
| 5 | datacenter-asn-block auto（19 ASN 两分支：滥用 6 个无 UA 豁免/大云 13 个保留；10-25 升 block+拆分） | block | ip-ban.py 自动 |
| RL | content-nav-burst-guard：150 req/10s（http_ratelimit 阶段，HTML 路径） | block | 手工（#37 放宽） |

### shuotong.wang（3 条）

| # | 描述 | action | 维护方 |
|---|---|---|---|
| 1 | ip-range-blacklist auto | block | ip-ban.py 自动 |
| 2 | datacenter-asn-block auto（两分支同 noda；10-25 升 block+拆分） | block | ip-ban.py 自动 |
| 3 | block empty/fake/script user agent（ref=ua-block） | block | 手工（10-24 从 noda 同步） |

## UA 规则（block empty/fake/script user agent）

### v1（2026-10-24 上午，仅 noda.co.nz）
只拦**空 UA**与**截断式伪装浏览器**（自称 AppleWebKit 无 Safari/；自称 Mozilla/5.0 无任何真实引擎标记
Chrome//Safari//Gecko/AppleWebKit/Trident），站主 IP 豁免、UA 自带 bot/spider/slurp/crawler 字样豁免。
判例来源：2026-10-24 上午搜狗系伪装浏览器扫描。

### v2（2026-10-24 晚，用户裁定加严，两 zone 同步）
新增第三类拦截：**诚实自报脚本身份的 UA 一律 block**。起因=同日晚 ColoCrossing AS36352 的
`Apache-HttpClient/4.5.14 (Java/21.0.9)` 爬虫（198.46.132.34）从 UA 规则下合法穿过抵达源站——
诚实脚本 UA 不假扮浏览器，v1 射程外。

- 脚本 UA 名单（24 marker，与 ip-ban.py `OBVIOUS_BOT_UA` 同族+大小写变体）：
  Apache-HttpClient / HttpClient / httpclient / python-requests / python-urllib / Python-urllib /
  python-httpx / curl/ / Wget/ / wget / Go-http-client / node-fetch / axios/ / okhttp /
  Java/ / java/ / Scrapy / scrapy / aiohttp / libwww / fasthttp / HeadlessChrome /
  headlesschrome / PostmanRuntime
- 豁免（CF `contains` 区分大小写，故 bot 类豁免全列大小写成对）：
  1. `ip.src` = 47.72.103.104（站主出口；本机 curl/无头测试全走这里）
  2. `cf.client.bot`（CF 验证爬虫：googlebot/bingbot 等）
  3. 自报家门 UA：bot/Bot/spider/Spider/slurp/Slurp/crawler/Crawler +
     点名 ChatGPT-User / Claude-User / Perplexity-User / MistralAI-User / cohere-ai
     （=GEO 引用漏斗，与 dc 规则 `DC_UA_EXEMPTS` 同口径；v1 只豁免 bot 类字样，
     Claude-User/Perplexity-User 的 Mozilla 型 UA 会被 v1 误拦，v2 修正）
- 表达式（1911 字符，noda/shuotong 同文；ref：noda=原规则 id cde18ca8a97d46509ac50029365cb7ca，
  shuotong=ua-block）：

```
(http.user_agent eq "") or (ip.src ne 47.72.103.104 and not cf.client.bot and not (
  http.user_agent contains "bot" or http.user_agent contains "Bot" or
  http.user_agent contains "spider" or http.user_agent contains "Spider" or
  http.user_agent contains "slurp" or http.user_agent contains "Slurp" or
  http.user_agent contains "crawler" or http.user_agent contains "Crawler" or
  http.user_agent contains "ChatGPT-User" or http.user_agent contains "Claude-User" or
  http.user_agent contains "Perplexity-User" or http.user_agent contains "MistralAI-User" or
  http.user_agent contains "cohere-ai")
  and ( ((AppleWebKit 无 Safari/) or (Mozilla/5.0 无任何引擎标记)) or (脚本UA名单 OR 链) ))
```

## 变更记录
### 2026-10-25 二（D1 事件流点亮：token 配置 + GraphQL UA 字段判例）
CF_REPORT_API_TOKEN 已配置（token 名 `cf-report-misban-watch`，Zone.Zone Read +
Zone.Analytics Read，All zones，永不过期，r4s /etc/noda/ip-ban.env）。首次真跑暴露
两个判例：
- **firewallEventsAdaptive 的 UA 字段名 = `userAgent`**——`clientRequestUserAgent`
  不存在（那是 httpRequestsAdaptiveGroups 的命名）；Free 版内省被封，且 schema
  校验**一次只报一个 unknown field**，逐字段试出来。D1 当时是无 token 盲写，首跑
  才暴露。
- token 首版从面板截图人工转抄错字符 → API 9109 Invalid access token；**Roll**
  功能重发密钥（权限保留）+ 从页面 DOM 直提不再转抄。secrets 永不经截图/人手转写。
24h 回看验证：两 zone 事件正常入库（block/managed_challenge/link_maze），官方爬虫
段命中 = 0，与 D2 心跳结论互证（bing 无误封）。

### 2026-10-25（misban-watch 首报即误报：容器重建截断，已修复）
bing 心跳告警「源站 48 小时未见官方段请求」查实为**误报**：当日 13:30 class-410
部署重建 noda-static-prod，access.log→/dev/stdout 随容器归零，13:40 轮的 48h 扫描窗
实际只剩 10 分钟数据，`last_seen is None` 分支绕过 bing 72h 阈值直接告警
（消息里的「48 小时」是窗口常量，不是观测值；bing 真实静默 ≤48h，封禁表 7 条全是
攻击封禁、UA 规则豁免 bingbot、google 心跳正常，无任何误封证据）。
修复三件套（misban-watch.py，单测 21 个全绿）：
① `canary_quiet_hours`——None 态静默按「日志实际覆盖时长」封顶，短观测窗不再虚报；
② `canary_last` 高水位入 watch-state——容器重建不丢最后到访，跨截断持续累计静默；
③ 扫描窗 48h→80h（≥ bing 阈值，零到访态也能够到 72h 判定线）。
**判例：部署重建容器 = docker logs 归零**。凡基于 docker logs 的观测（misban 心跳、
ip-ban 速率窗）都要有「覆盖时长」意识；这类哨兵的告警文案必须带真实观测时长+阈值。

### 2026-10-26（misban-watch 误封哨兵 + admin 安全报表上线）
用户需求：报表上 admin 随时看 + 主动消息 + 误封自动发现（「不要等 Google 发邮件」）。
- **报表**：已内嵌 admin 应用 UI（noda-apps admin/web `/security` 页，direct-fetch 同源 JSON）；数据端点=nginx admin 块 `/security-report/` 静态 location（**前缀不可用 /security——会遮蔽应用路由，2026-10-26 判例**），
  alias ops-logs 卷 `security-report/`，misban-watch cron */10 每轮回写 page.html+
  report.json；保护层=CF admin non-NZ challenge + robots.txt 全站 Disallow；
  无应用鉴权，数据敏感度=防御姿态摘要，v2 可迁 BFF Keycloak 后面）。
- **D1 事件流检测**（2026-10-25 已启用：`CF_REPORT_API_TOKEN` 在 r4s
  /etc/noda/ip-ban.env，Zone.Zone Read + Zone.Analytics Read，All zones）：
  `firewallEventsAdaptive` 双 zone 增量
  → 官方爬虫段 IP（与 ip-ban 白名单同源）被封/被挑战 = 实锤误封，TG 即时告警，
  同事件去重。admin./auth./comments./api./health. 后台 host 被挑战不计（robots
  Disallow 全站，守规矩爬虫本就不该来）。
- **D2 源站心跳**（零权限已活）：Googlebot 源站 36h、Bingbot 72h 无官方段请求
  即 TG（反向哨兵：心跳在=Google/Bing 能进的持续证明），恢复自动解除。
- 事件 schema 判例：数据集真名 `firewallEventsAdaptive`/`firewallEventsAdaptiveGroups`
  （`firewallAdaptiveEvents`/`firewallAdaptiveGroups` 不存在）；事件级**无 clientASN
  字段**（schema 校验先于 authz 报错，两个错误别混淆）；GraphQL 内省 Viewer/Zone
  类型被封（__type 返回 null），字段靠别名探测。
- 部署：deploy/misban-watch.py + security-report.html → r4s /mnt/mmc1-4/System/Scripts/；
  crontab-r4s-host + hb 心跳；nginx default.conf admin 块加 `/security/` location
  （reload 验证 200）。单测 16 个（分类/心跳/去重/报表组装）。

### 2026-10-25（ALLOW_CIDRS 撤成员：150.249.214.0/24 回归正常闸门）
用户裁定「不能走白名单，该怎么封怎么封」：日本 So-net 家宽段（AS2527，10-23 误封
判例入列 ALLOW_CIDRS）撤出硬白名单——白名单=该段永久免疫，真被滥用反而无手段；
10-25 枚举闸 OR→AND 修复已关死当年纯 paths 误触发通道，家宽共享出口回归正常闸门
管辖，误封风险由 AND 结构承担。dc 规则 ip_ex 现仅 `66.249.64.0/19 + 站主 IP`；
机制空置保留。双 zone 读回验证：表达式无 150.249，unsynced 空。

### 2026-10-25 深夜二（黑名单精简：30→7 段，dc 名单 18→19）
用户裁定：已有机房 ASN 全量挑战，黑名单可精简。30 段逐一解析 ASN：
- **移除 23 段**（22 段 ASN 已在 dc 挑战名单：GCP 396982×16 / AWS×4 / Alibaba 国际
  AS45102×1 / Datacamp AS212238×1 + 185.177.72.69——其 ASN 211590 Bucklog 本轮
  按判例补进 dc 名单）。机器人过不了挑战→到不了源站→黑名单 block 完全重复；
  即便真人在 VPS 上点过挑战回访，洪水/攻击/UA/限速四闸仍会自动重封，自愈闭环。
- **保留 7 段**（无其他防线覆盖）：205.169.39.0/24（AS3356 Level3/Lumen 主干传输，
  **绝不可整段挑战**——承载真实用户，只能 /24 精封）、45.88.217.88（AS206092）、
  176.65.132.251（AS197170）、47.102.184.31（AS37963 阿里中国云——CN 规则在 noda
  覆盖但 shuotong 无 CN 规则，保留）、169.40.142.177（AS215599）、93.123.109.107
  （AS48090）、143.244.57.86（AS60068 手动 wp-probe）。全部自然到期自清。
- 教训：黑名单是历史自动封禁的堆积面，dc 名单每扩一家 ASN 就应回头清一次
  被覆盖的存量段；state.bans 与 CF 必须同删（unsynced 强制下轮 PUT）。

### 2026-10-25 深夜（第三轮 review：运行态+证据复盘）
1. **persist 判据反向失效修复（关键）**：实测爬虫家族昨天拉满 `_next/static×89
   +geo.json×3`（JS 执行≠真人）——原判据把 BROWSER_SIGNAL_RE（含 _next）当真人
   否决信号，目标家族会被反向豁免，永不进名单；而真实老用户资产全走 CF/浏览器
   缓存（源站 1-3 条/天、零信号）反而会被累积误伤——方向完全反了。重构：
   否决信号改 PERSIST_VETO_RE 只认 PWA 生命周期端点（sw.js/manifest/offline，
   家族实测零触碰）；PERSIST_MIN_REQS 8→40（真人日访源站 1-3 条 14 天最多 ~40，
   家族每天整页冷加载 45+ 条 4 天即 180）。
2. **平台链接预览抓取器豁免（原则①）**：persist 档案实测混入 Meta 2a03:2880::/32
   段 facebookexternalhit（UA 无 bot 字样被归 human）——4 天后将误挑战 FB/WhatsApp
   分享预览。SELFID_MARKERS 补 externalhit/meta-externalagent/whatsapp/telegram/
   skypeuripreview（Twitterbot/Slackbot/Discordbot/LinkedInBot 带 bot 已覆盖）。
3. 家族指纹留档：UA=Chrome/125.0.0.0（2024 年中版本；真实现网 145/142）——
   暂不做 UA 版本拦截（误伤真实老旧浏览器），CHROME_VER_RE<100 门槛维持。
4. 尺寸回归测试：dc 表达式在 MAX_PERSIST_LIST=80×最长压缩 /64（24 字符）下
   =2752 字符 < 4095-200 余量。
5. **盘点补遗：noda zone 另有一条 http_ratelimit 阶段规则**（此前文档漏记）：
   `content-nav-burst-guard`：150 req/10s block，`not cf.client.bot`，覆盖
   //zh//en//item//city//category//login HTML 路径（2026-10-24 #37 放宽，
   ip-ban 源站闸兜底）。与全规则体系无豁免冲突（150/10s 远超任何礼貌爬虫速率）。
6. 其余清查全净：两 zone 无其他规则阶段内容（cache_settings=default 无规则）、
   遗留 firewall access_rules/lockdowns/ua_rules 全 0；state unsynced=[]、
   verify 空、黑名单 30 段、tracks 141/500、persist 20 条全 days=1。
   第三轮未再发现新问题，review 收敛。

### 2026-10-25 晚（全量规则 review 轮，review 至无新问题）
逐条复审两 zone 全部表达式 + 黑名单 30 段理由 + ip-ban.py 各判定闸，修复 5 处：
1. **persist 名单并入 dc 规则**（严重）：Free 版自定义规则上限 5 条，实测第 6 条
   PUT 报 50001 "exceeded the maximum number of rules: 6 out of 5"——独立
   persistent-visitor-challenge 规则建不出来，首名单出现时将永远同步失败。
   现 OR 进 dc 规则表达式（同 managed_challenge 语义），MAX_PERSIST_LIST=80
   保护单规则 4095 字符表达式上限。
2. **/24 枚举闸 OR→AND**（误封通道）：原 `低资源 OR botua≥50% OR paths≥15`
   允许纯 paths 单独触发——Google Mediapartners 段（assets 76%/paths 35）与
   2026-10-21 日本家宽共享出口正是此通道误封。改 `(低资源 OR botua) AND paths≥15`
   纯函数 decide_enum24 + 6 测试。存量 205.169.39.0/24 复核=Palo Alto Networks
   扫描段（hosting）保留；47.79.13.0/24=Alibaba SG 保留。
3. **CN 规则补 cf.client.bot 豁免**：原 `ip.geoip.country eq "CN"` 裸表达式会
   挑战 Baiduspider 等 CF 验证爬虫（违反原则①）。现 `(CN) and not cf.client.bot`。
   Sogou/Bytespider 等无验证标记 CN 爬虫仍按 CN 政策挑战（Bytespider 处置仍留用户裁定）。
4. **UA 规则空 UA 条款补豁免**（两 zone）：原首条款 `(ua eq "")` 无条件 block，
   不吃站主 IP 与 cf.client.bot 豁免。现 `((ua eq "") and not cf.client.bot
   and ip.src ne 47.72.103.104) or …`。
5. **假 bingbot 归类修正**：classify 只点名假 googlebot，bingbot 伪装 UA 会经
   SELFID "bot" 字样溜成 skip（不计入速率统计）。现 googlebot/bingbot 伪装均归 bot。
黑名单 30 段逐段复核：22 攻击路径 + 6 洪水 + 2 enum + 1 手动 wp-probe，全部有实据。
无 RSS feed（/feed 等全 404）→ RSS 阅读器 UA 无误封面。admin.noda.co.nz DNS 在位。
第二遍全文复审未再发现新问题，review 收敛。

### 2026-10-25（下午：坚持不懈来访者挑战网，用户三原则）
用户定三原则：①不误封 SEO/GEO/守规矩爬虫 ②不误封正常用户 ③机器访问/机房攻击/
天天坚持来的访客皆可疑。新增 ip-ban.py 第 6 条自动规则 **persistent-visitor-challenge**：
- 档案只收 classify=human 的源站流量（官方爬虫段/自报家门 UA/白名单 skip 从不入档）；
  键=v4 /32、v6 /64（家宽 v6 后缀逐日轮换追得上）
- 判定=14 天窗口 ≥4 个不同到访日 + 累计 ≥8 请求 + 全程零浏览器生命周期信号
  （sw.js/manifest/_next chunk/geo.json 一个不拉）+ 零 304（真浏览器缓存校验必回源，
  无头族每天全新上下文永不发 If-None-Match）；signals/304 任一非零=真人铁证永不挑战
- action=managed_challenge（真人一键可过）；cf.client.bot+站主 IP 表达式双豁免；
  名单空=规则不创建/自动 disable；进名单 TG 通报
- 背景：Mac-UA 深链低慢速爬虫家族每天换代理出口（已挑战其已知 ASN 212238/46635/62874），
  此网收口「下一次换到未知 ASN/家宽出口」的场景；同日上午核实 07:30 美国 IP=AS14618
  AWS 敲门，全部被 dc 规则边缘挑战、零源站命中——面板里的美国事件=拦截成功记录非漏防

### 2026-10-25（次日全天复查判例）
- **误封 Google /24 已回滚**：10-24 23:35 ip-ban 的 24h-enum 闸把 209.85.238.0/24 拉黑 7 天——
  实为 Mediapartners-Google（AdSense 官方爬虫，AS15169），不在 googlebot.json、UA 无 bot 字样，
  classify 归 human（与 10-23 误封 66.249.73.0/24 同型）。处置=state 摘除+CF 黑名单同步清两 zone；
  判据修复=EXTRA_CRAWLER_RANGES 补 209.85.128.0/17 + SELFID_MARKERS 补 Google 特种爬虫 UA
  （mediapartners-google/apis-google/feedfetcher/google-read-aloud/googleother/google-safety/
  google-inspectiontool），apply_safety 现会 veto 该段提案，tests 53 绿。
- 机房 ASN 规则 15→18：补 AS212238（Datacamp/CDN77，单日 browser-burst 豁免×2 + Mac-UA 低慢速
  爬虫出口共 5 次现身）、AS46635（AviationAI 代理出口）、AS62874（Web2Objects 代理出口）。
- 边缘实测（Security Events, last 24h, Country=US）：美国命中事件全部=dc 规则 Managed Challenge
  （AWS 出口 34.x/44.x/3.232.x/98.84.x/100.5x），无一漏到源站的恶意美国 IP；Singapore 47.79.x
  script UA 被 UA 规则 Block；AI Labyrinth 正常喂爬虫。

### 2026-10-24
- 机房 ASN 规则补 AS36352（ColoCrossing，Java 爬虫实证）→ noda-infra `5260c88`。
- 内置层实测快照：AI Labyrinth=开（工作正常）；Bot Fight Mode=关
  （**勿开**：免费版无 IP 豁免，会拦站主自有 HeadlessChrome 测试栈）；AI bot policies 4 条配置。

### 2026-10-25（DC_ACTION managed_challenge → block，用户裁定）
起因：GA「今天 2 条美国数据」复核=800x600 家族（9.151.196.78/AS46635 + 172.252.155.132/AS212238，
都能过 managed_challenge）。用户裁定：机房 IP 直接 ban、UA 拦截路线不做（易伪造）。
前提实证：
- 家族 12h 内 9 个出口**全部**落在已列 19 个机房 ASN（AS212238×7——含伪装成 BR/TR/IT ISP 的
  注册段 201.24.178.0/23、189.104.106.0/23、189.81.226.0/23；AS62874/AS46635 各 1）。
- 12h 日志 234 个浏览器 UA 的 IP 落在 19 ASN 上=**0**（机房零真人，block 误伤面空）。
- GEO/SEO 爬虫实测全靠豁免存活（豁免原样保留）：GPTBot/ChatGPT-User/OAI-SearchBot 全 Azure
  (AS8075，OpenAI 跑 Azure)；Amazonbot/PerplexityBot 全 AWS；AhrefsBot 主力 OVH(AS16276)+
  自有 AS140577；Bravebot Hetzner。cf.client.bot 覆盖 Googlebot(GCP)/Bingbot(Azure)。
- UA 豁免的伪造面今天已存在（豁免本就跳过挑战），block 不扩大暴露；家族实测素浏览器 UA。
残余代价：云 VPN 真人从一键可过变 403（用户原则 3 接受）。persist 名单继承 block
（PERSIST_ACTION 常量删除）。API 读回双 zone action=block、四层豁免完整。noda-infra commit 见 git。

### 2026-10-25 第二步（ABUSE/CLOUD 拆分，用户裁定「攻击者伪造 UA 是否能漏进来」后）
漏洞：UA 加 "bot" 字样可绕过 dc block + UA 规则豁免 + 源站全部六道闸（classify skip）。
拆分：ABUSE_ASNS 6 个（18779/36352/212238/46635/62874/211590）**撤 UA 豁免**——伪造
bot UA 也 403；CLOUD_ASNS 13 个保留 UA 豁免（GEO/SEO 爬虫实证全在此）。仍是同一条规则。
安全依据（研究结论）：①OpenAI/Perplexity 官方 IP 清单 260 段 0 命中滥用 ASN（全 Azure/
AWS）；②12h 普查滥用 ASN 零欢迎爬虫零真人；③7 天动作日志滥用 ASN 段唯一痕迹=家族；
④cf.client.bot/官方段/站主豁免两分支都保留。家族 12h 内 9 出口 100% 在滥用 6 ASN。
监控盲区：若未来有欢迎爬虫迁到滥用 ASN 会被 403 且源站看不到——月度抽查 CF Security
Events 滥用 ASN 的 block 事件 UA 列。残余不可关死：搬大云+伪造 bot UA+低速率=与真 SEO
爬虫不可区分。73 测试绿，API 读回双 zone 两分支生效（滥用分支零 UA 豁免验证过）。

### 2026-10-26（dc 名单 17+13：GA「美国 Direct」溯源定案 + 小运营商全禁用户令）
- 溯源链：GA 当日 6 用户 = 4 US Direct（headless 全 JS 层）+ HK/UK organic（真人，
  源站 PWA 三件套坐实）。按「JS 资产>0 + HTML 1-2 页 + 无外链 referer」从源站日志
  筛 12 候选 → Team Cymru BGP 定 ASN。GA 4×3=12 事件与 4 IP 各 1 页完美对账。
- **判例：whois OrgName 不可信（陈旧注册数据）**——195.40.x 注册名 Code200 实为
  FDCservers 宣告、189.104.x netname "US_TX_internet" 实为 M247（LT 注册 RO 宣告）、
  152.163.x 误标 RIPE 实为 LeaseWeb-SFO；定 ASN 一律 Cymru BGP。
- 用户令（10-26）：小运营商完全不允许（ABUSE=block 无 UA 豁免）；大云有 bot 的可进
  （CLOUD=block+UA 自报家门豁免）——与 10-25 拆分同构，落实为名单扩容。
- 新入 ABUSE 11 家（当日实证 8 + 立案候选 3）：M247 9009 / Latitude.sh 262287 /
  Ace 11798 / HostRoyale 203020 / Host Universal 136557 / FDCservers 30058 /
  LeaseWeb 7203+60781 / Contabo 51167 / GCore 199524 / CDN77 二号牌 60068。
- 不动：Charter 11426（家宽，206.232.103.197 出口老 Edge iPhone 存真人可能）、
  Starlink 14593、Dimension Data 20011、Lumen 骨干 3561、Google 15169。
- 模式判例：家族按「不在册托管商」轮换租出口（Bucklog 10-24 → M247/Latitude/Ace
  10-26），名单扩张只是抬对方换租成本；主力防线=PWA 三件套判据/速率闸/persist 档案。
- GA 新口径：用户数=headless+真人混合体（对方一直 headless 执行 JS），真人下限=
  源站 PWA 三件套会话数（当日≈10）；「GA 某天无某国」无信号价值。
- 部署：双 zone 读回 dc 规则 30 ASNs block、新 11 家命中 11/11、unsynced 空、
  表达式 850 字符；94 测试绿（17+13 分区锁 + 11 家回归锁）。

## 核验命令（r4s 上跑）
```bash
python3 - <<'PYEOF'
import sys, importlib.util, urllib.request, json
spec = importlib.util.spec_from_file_location("ipb", "/mnt/mmc1-4/System/Scripts/ip-ban.py")
m = importlib.util.module_from_spec(spec); sys.modules["ipb"]=m; spec.loader.exec_module(m)
cf = m.load_cf_token()
def api(url):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer %s" % cf})
    return json.load(urllib.request.urlopen(req, timeout=30))
for z in m.ZONES:
    zid = api("https://api.cloudflare.com/client/v4/zones?name=" + z)["result"][0]["id"]
    for r in m.get_rules(cf, zid):
        print(z, "|", r.get("description", "")[:80], "|", r.get("action"), "| enabled:", r.get("enabled"))
PYEOF
```
