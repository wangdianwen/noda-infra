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
