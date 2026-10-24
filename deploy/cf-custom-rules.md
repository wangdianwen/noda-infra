# Cloudflare 自定义规则清单（两 zone）与 UA 规则演变

> 权威源=CF API（entrypoint ruleset, phase `http_request_firewall_custom`）。
> 本文件是留档快照；ip-ban.py 每 5 分钟 get→改黑名单/dc→put 回写，**其余规则原样透传**——
> 手工改规则走 API 或面板均可，改完无需动 ip-ban.py。
> 核验命令：见文末。

## 规则清单（2026-10-25 快照）

### noda.co.nz（5 条+1 潜在，按求值顺序）

| # | 描述 | action | 维护方 |
|---|---|---|---|
| 1 | admin non-NZ managed challenge | managed_challenge | 手工（后台入口仅 NZ 访问） |
| 2 | block empty/fake/script user agent | block | 手工（本次加严，见下） |
| 3 | cn-traffic-managed-challenge | managed_challenge | 手工 |
| 4 | ip-range-blacklist auto (N active) | block | ip-ban.py 自动 |
| 5 | datacenter-asn-block auto (N ASNs) | managed_challenge | ip-ban.py 自动 |
| 6* | persistent-visitor-challenge auto | managed_challenge | ip-ban.py 自动（**名单非空才创建**，空=不存在） |

### shuotong.wang（3 条）

| # | 描述 | action | 维护方 |
|---|---|---|---|
| 1 | ip-range-blacklist auto | block | ip-ban.py 自动 |
| 2 | datacenter-asn-block auto | managed_challenge | ip-ban.py 自动 |
| 3 | block empty/fake/script user agent（ref=ua-block） | block | 手工（10-24 从 noda 同步） |
| 4* | persistent-visitor-challenge auto | managed_challenge | ip-ban.py 自动（名单非空才创建） |

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
