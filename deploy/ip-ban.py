#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ip-ban.py — 通用 IP 段黑名单（自动发现 spam 网段 → CF WAF 封禁 7 天 → 静默自动解封）

设计（2026-10-18 用户拍板的 8 点要求）：
- 不限于搜狗：任何「伪装浏览器/无头/枚举式抓取」的网段都自动进黑名单
- 区分机器人与真人（traffic 少，规则可解释）：
  * 欢迎（永不计入、永不封）：官方爬虫网段 IP 优先（googlebot.json/bingbot.json
    全量段命中即放行，2026-10-23 起——此前只认 UA 含 googlebot 的 Google 段内
    流量，Chrome Prefetch Proxy/GoogleOther/Read-Aloud 等无 bot UA 的 Google
    合法出口被当真人计入 /24 枚举指纹，反手封了 Google 自己的 /24）、
    其他自报身份的爬虫（UA 含 bot/spider/slurp——守规矩才敢自报家门）、
    站主 IP、ALLOW_CIDRS 硬白名单
  * 假 Googlebot（UA 报 Googlebot 但 IP 不在 Google 段）= 伪装，计入 bot
  * 明显 bot UA：HeadlessChrome / python-requests / curl / wget / Go-http-client …
  * 伪造老浏览器：Chrome 主版本 < 100（2026 年不存在的人类用户）
- /24 行为指纹（6 小时滚动窗口，低慢速爬取在 5 分钟窗内攒不够阈值）：
  请求 ≥40 且不同 IP ≥3 且（静态资源占比 ≤5% 或 bot-UA 占比 ≥50%）且去重路径 ≥15
  → 真人浏览器必然带资源请求；paths 为必要条件不单独触发（2026-10-25 复盘修正：
  纯 paths 触发曾把高资源多路径的 Google Mediapartners 段与日本家宽共享出口
  一并误封）、单 IP 真人过不了「3 个不同 IP」门槛
- 单 IP 洪水（#37 2026-10-24 分档）：5 分钟窗内按档位阈值 → 封 /32（外科
  手术式）——严档 60（夹 bot-UA 或 6h 内有攻击 URL 命中）、浏览器档 300
  （零 bot-UA 且零攻击命中）；真人浏览器爆发豁免——窗口内零 bot-UA 且命中
  ≥3 次浏览器生命周期端点（sw.js/manifest/_next chunk/__next RSC/geo.json）
  即视为真 PWA 冷缓存首访，不封（WARP 真人误封事件教训）；洪水 TTL 首犯
  1 天、7 天内复犯 7 天（state.history 记前科）
- 攻击 URL 惯犯：同 IP 6h 内命中 ≥5 次机密探测路径（.env/.aws/wp-/.git/id_rsa/
  application.properties …——真人和守规矩爬虫永远不会请求这类路径，零误伤可能）
  → 封 /32、TTL 升级 30 天；/24 行为封禁若夹带攻击流量同样升级 30 天
- 机房 ASN 常驻封禁（2026-10-24 #38）：主流云/hosting ASN（AWS/GCP/Azure/Hetzner/
  DO/Linode/Vultr/OVH/Oracle/Scaleway/阿里国际/腾讯国际）命中即 block（2026-10-25
  用户裁定，原 managed_challenge——无头浏览器能过挑战，拦不住 800x600 家族）——
  与速率闸正交的常驻规则，堵低慢速分布式爬虫（800x600 headless 指纹族）速率永远够
  不上阈值的盲区；cf.client.bot 官方验证爬虫整体豁免（googlebot 从 GCP 段抓取不误伤）
  + 66.249.64.0/19 兜底 + 站主/ALLOW_CIDRS 豁免
- 封禁粒度 /24（自动化上限，/16 及以上永不自动封）；普通 TTL：/32 洪水首犯
  1 天/复犯与 /24 行为封禁 7 天（#37）、攻击型 30 天，静默满自动解封
- TG 通知：进入封禁 / 自动解封都发消息（telegram-alert.sh）
- 纯 API：Doppler REST 取 CF token → Rulesets API 管理规则（无浏览器操作）
- 多 zone：黑名单同步写入 ZONES 全部站点（noda 主站 + class）；某 zone 暂不可达
  （token 权限未覆盖/CF 故障）时记入 state.unsynced 下轮自动重试，不阻塞其他 zone
- 规则：description 以 "ip-range-blacklist" 开头（ref 同名）才归本脚本管，
  黑名单空时自动 disable，规则对象保留在 Dashboard 可见

数据源：docker logs noda-static-prod 增量（--since 上次运行 epoch，窗口上限 30 分钟）
状态：  ops-logs/ip-ban.state.json（封禁表 + /24 行为滚动计数）
cron：  */5 * * * *（deploy/crontab-r4s-host）
用法：  ip-ban.py [--dry-run] [--status]

2026-10-23 修复（误封 66.249.73.0/24 Google 官方段 / 150.249.214.0/24 日本家宽）：
- 爬虫白名单改 IP 优先：请求 IP 命中 googlebot.json（317 段）/bingbot.json（28 段）
  即 skip 枚举统计，不看 UA；另保留老 66.249.64.0/19 并集兜底（json 只发布 crawl
  IP 的 /27 明细，不含 Prefetch Proxy/GoogleOther 出口如 66.249.84.x）；
  运行时下载 + 缓存 24h，下载失败回退内置全量快照常量
- SAFETY 闸补齐：提案网段与官方爬虫段/ALLOW_CIDRS 任意交集 → 拒绝并记日志
  （原注释声称防 Google 段但只实现了站主 IP 检查，是本次误封的直接通道）
- 多级 XFF 取 CF 追加的最后一跳（CF 把访客真实 IP 追加到 XFF 尾部，等价
  CF-Connecting-IP）；解析失败跳过该行而非抛异常（此前 "a,b" 串使整轮崩溃）
- 新增 ALLOW_CIDRS 硬白名单（cron 不 source env，从 /etc/noda/ip-ban.env 或
  环境变量读取，命中请求 IP 完全跳过）；state 结构不变，老 state 直接兼容

2026-10-24 调整（#37 误封 136.70.78.248——真人快速翻页 90req/216s 被洪水线
拉黑 7 天；根因：HTML 源站 no-cache 每次导航都计数 + 老用户生命周期端点被
CF/浏览器缓存挡住 → 豁免信号攒不够 3 个）：
- /32 洪水分档：零 bot-UA 且 6h 零攻击命中 → 浏览器档 BAN32_BROWSER_REQ=300，
  其余仍 BAN32_REQ=60 严档
- /32 洪水 TTL：首犯 BAN_TTL_FIRST=1 天，7 天内复犯升 BAN_TTL=7 天
  （state.history 记 cidr→上次洪水封禁 epoch，容量 500 裁最旧；老 state 无
  history 键自动补，结构兼容）
- /24 行为封禁 7 天、攻击 URL 30 天、浏览器爆发豁免、SAFETY 闸均不变

2026-10-24 深夜补充（次日复查全天美国 IP 源站日志发现的误封判例：209.85.238.0/24
被 24h-enum 拉黑 7 天——Mediapartners-Google（AdSense 官方爬虫，AS15169）不在
googlebot.json、UA 无 bot 字样，classify 归 human 攒出 /24 枚举指纹，与
66.249.73.0/24 同型；当日源站日志实证 209.85.238.129/.130 打 /graphql//geo.json/
_next 静态资源，零攻击路径）：
- EXTRA_CRAWLER_RANGES 补 209.85.128.0/17（整段属 Google AS15169 AdSense/特种
  爬虫出口；不与 GCP 客户段 34.x/35.x 重叠，SAFETY 闸不会误 veto 云上攻击封禁）
- SELFID_MARKERS 补 Google 特种爬虫 UA（mediapartners-google/apis-google/
  feedfetcher/google-read-aloud/googleother/google-safety/google-inspectiontool
  ——均无 bot 字样），IP 段真值源未覆盖或下载失败时 UA 兜底
- DATACENTER_ASNS 补 212238（Datacamp/CDN77，当日 browser-burst 豁免×2 + Mac-UA
  低慢速爬虫出口共 5 次现身）、46635（AviationAI 代理出口）、62874（Web2Objects
  代理出口）——Mac-UA 深链爬虫家族当日的三个代理出口 ASN

2026-10-25 新增坚持不懈来访者挑战网（用户三原则：①不误封 SEO/GEO/守规矩爬虫
②不误封正常用户 ③机器访问/机房攻击/天天坚持来的访客皆可疑）：
- 事件元组扩为 (ip, path, ua, status)（LINE_RE 增捕状态码，304=真浏览器缓存
  校验回源的铁证）
- 档案只收 classify=human 流量（官方爬虫段/自报家门/白名单 skip 从不入档=原则①）；
  键=v4 /32、v6 /64（家宽 v6 后缀逐日轮换）
- 判定 decide_persistent：14 天窗口 ≥4 个不同到访日 + 累计 ≥8 请求 + 全程零
  浏览器生命周期信号 + 零 304（signals/n304 任一非零即真人铁证放行=原则②）
- 命中 → 并入 dc 规则（OR 子句，继承 dc action=block）+ cf.client.bot/
  站主双豁免兜底；名单空=子句不存在。**不建独立规则**：Free 版自定义规则上限
  5 条（2026-10-25 实测 "6 out of 5"），名单空自动 disable=原则③ 收口
2026-10-25 调整（DC_ACTION managed_challenge→block，用户裁定「机房 IP 直接 ban，
UA 路线不做——容易糊弄」；前提实证：GA「今天 2 条美国数据」= 800x600 家族，9 个
出口全部落在已列 19 个机房 ASN 里（AS212238×7 含伪装成 BR/TR/IT ISP 的注册段、
AS46635/AS62874 各 1）；12h 日志 234 个浏览器 UA 的 IP 无一命中 19 ASN=零真人；
GEO/SEO 爬虫实测全靠豁免存活：GPTBot/ChatGPT-User/OAI-SearchBot 全 Azure(AS8075)、
Amazonbot/PerplexityBot 全 AWS、Ahrefs 主力 OVH(AS16276)、Bravebot Hetzner，
cf.client.bot+官方段+UA 自报家门三层豁免原样保留即不受影响；PERSIST_ACTION 常量
随并入设计删除，persist 名单继承 block）：
- 豁免不变（cf.client.bot 验证爬虫 / 66.249.64.0/19 / 站主+ALLOW_CIDRS /
  DC_UA_EXEMPTS 自报家门）——UA 豁免的伪造面今天已存在（豁免本就跳过挑战），
  block 不扩大暴露；家族实测素浏览器 UA，撞 block 即 403
- 同日第二步（用户裁定）：ABUSE_ASNS(6)/CLOUD_ASNS(13) 拆分——滥用分支撤 UA
  豁免（伪造 bot 字样也 403，家族 100% 出口在此），大云分支保留（GEO/SEO 爬虫
  实证全在大云）；官方清单 OpenAI 252 段全 Azure+Perplexity 8 段全 AWS，0 段
  落滥用 ASN；cf.client.bot/官方段/站主两分支都保留
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ---- 配置 ----
# class.noda.co.nz 是主站 zone 的子域（同一 zone，规则天然覆盖），无需单列。
# 多 zone 能力保留：未来若新增独立 zone，把名字加进 ZONES 即可（token 需其 WAF Edit）。
ZONES = ("noda.co.nz", "shuotong.wang")   # 隧道 15 个 hostname 共用同一源站,
                                         # shuotong.wang 是独立 zone,黑名单/dc 规则必须双 zone 同步
                                         # (2026-10-24 判例:扫描器经 www.shuotong.wang 打穿 noda 黑名单盲区)
PHASE = "http_request_firewall_custom"
RULE_MARKER = "ip-range-blacklist"          # 规则 description 前缀 / ref

# ---- 机房 ASN 常驻封禁（2026-10-24，用户裁定「直接禁掉机房 IP，不误伤 google 爬虫」）----
# 与 5min/6h 速率闸正交的常驻 CF 规则，堵「低慢速分布式爬虫速率永远够不上阈值」的结构
# 盲区（GA4 实证族：800x600 headless / direct 深链 sitemap 页 / 0 互动 / AWS+GCP 出口
# 轮换 / 同 URL 跨国家重抓）。防误伤三层：①cf.client.bot=CF 官方验证爬虫整体豁免
# （googlebot/bingbot 反向 DNS 实名，GCP/Azure 段内的 Google/Bing 抓取出口全在此列）；
# ②66.249.64.0/19 老段兜底（Prefetch Proxy 判例段）；③站主 IP + ALLOW_CIDRS。
DC_MARKER = "datacenter-asn-block"
DC_ACTION = "block"    # 2026-10-25 用户裁定升级：无头浏览器能过 managed_challenge
                        # （GA 两条美国会话实证），挑战对 800x600 家族无效；12h 实测
                        # 19 个机房 ASN 上零真人（234 个浏览器 UA 的 IP 无一命中），
                        # 家族 9 个出口全在其中。豁免三层原样保留，GEO/SEO 爬虫实证
                        # 存活：GPTBot/ChatGPT-User/OAI-SearchBot(全 Azure)、
                        # Amazonbot/PerplexityBot(AWS)、Ahrefs(OVH)、Bravebot(Hetzner)。
                        # 残余代价：云 VPN 真人从一键可过变 403（用户原则 3 接受）

# ---- 坚持不懈来访者挑战网（2026-10-25 用户三原则 #3：机器访问可疑，且「换着出口
# 每天都来的同一访客」可疑——堵 Mac-UA 深链低慢速爬虫家族换到未知 ASN/家宽出口时
# 速率闸与 ASN 名单都够不上的最后缺口）----
# 判定（同一 IP，v6 按 /64）：14 天内 ≥4 个不同日到访 + 累计 ≥8 请求 + 全程零
# 浏览器生命周期信号（sw.js/manifest/_next chunk/geo.json 一个不拉）+ 零 304
# （真浏览器缓存校验必回源；无头族每天全新上下文永不发 If-None-Match）。
# 命中 → 并入 dc 规则 OR 子句（继承 action=block，2026-10-25 随 dc 升级）；
# 档案只收 classify=human 的流量，官方爬虫/自报家门/白名单（原则 1）从不入档。
PERSIST_MARKER = "persistent-visitor-challenge"   # 并入 dc 规则共用 action，无独立项
PERSIST_WINDOW = 14 * 86400          # 滚动窗口 14 天
PERSIST_MIN_DAYS = 4                 # 窗口内不同到访日下限
PERSIST_MIN_REQS = 40                # 累计请求下限：真人日访 1-3 条源站请求（资产全
                                    # 走 CF/浏览器缓存）14 天最多 ~40；无头族每天全新
                                    # 上下文整页冷加载 45+ 条，4 天即 ~180（2026-10-25
                                    # 三出口实测：_next×89+geo.json×3+graphql×9）
MAX_PERSIST_TRACK = 3000             # 档案容量（按 last 裁最旧）
MAX_PERSIST_LIST = 80                # 名单上限：与 dc 规则共用表达式，须留余量
                                    # （CF 单规则表达式 4095 字符；Free 版自定义
                                    #  规则上限 5 条，2026-10-25 实测 "6 out of 5"）
# 坚持不懈判定的「真人否决信号」只认 PWA 生命周期端点——2026-10-25 实测爬虫家族
# 会拉满 _next/static×89+geo.json×3（JS 执行≠真人），但 sw.js/manifest 从 0 触碰
# （真浏览器每次导航都做 SW 更新检查/注册，且 SW 脚本按规范绕过 HTTP 缓存）。
# BROWSER_SIGNAL_RE（含 _next）只用于洪水真人豁免，两套口径勿混。
PERSIST_VETO_RE = re.compile(
    r"/sw\.js$|/manifest\.webmanifest$|/manifest\.json$|/offline\.html?$", re.I)
# UA 自报家门豁免（大小写都写死：CF contains 不保证大小写不敏感）。"bot"/"Crawler"
# 系覆盖 GPTBot/OAI-SearchBot/ClaudeBot/PerplexityBot/Amazonbot/Applebot/CCBot；
# 三个 "-User" 是各引擎的「用户发起实时抓取」变体——GEO 引用漏斗本体，UA 里没有
# bot 字样，必须点名。伪报 bot UA 换挑战豁免=接受（公开页，且速率闸/攻击闸仍拦）。
DC_UA_EXEMPTS = ("bot", "Bot", "Spider", "spider", "Slurp", "Crawler", "crawler",
                 "ChatGPT-User", "Claude-User", "Perplexity-User",
                 "MistralAI-User", "cohere-ai")
# 2026-10-25 拆分（用户裁定：滥用 ASN 撤 UA 豁免，伪造 bot 字样也 403）。安全依据：
# ①官方爬虫 IP 清单 260 段（OpenAI chatgpt-user/gptbot + Perplexity）0 段落在滥用
# ASN——全部 Azure/AWS；②12h 全量普查：欢迎爬虫只出现在大云（Azure/AWS/OVH/
# Hetzner），滥用 ASN 上零欢迎爬虫零真人；③7 天动作日志：滥用 ASN 段唯一历史
# 痕迹=800x600 家族。cf.client.bot（IP 级验证不可伪造）两分支都保留。
ABUSE_ASNS = (
    18779,          # EGIHosting（10-24 实证：800x600 爬虫家族换用的小托管商出口）
    36352,          # ColoCrossing（10-24 实证：Java-HttpClient 爬虫 198.46.132.34 拉 item 页，
                    #  CF AI Labyrinth 已伺候；入列后整段 block）
    212238,         # Datacamp/CDN77（家族主力出口：12h 内 7/9 个出口在此，含买来的
                    #  BR/TR/IT 老 ISP 段 201.24.178.0/23 等当住宅代理池；CF Labyrinth+挑
                    #  战都拦不住——能解 JS；block 后唯一免死路径=伪造 bot UA，本拆分封掉）
    46635,          # AviationAI 小众代理出口（10-24/25 实证：Mac-UA 深链爬虫 9.151.196.x）
    62874,          # Web2Objects 代理出口（10-24/25 实证：Mac-UA 深链爬虫 176.20.202.169）
    211590,         # Bucklog SARL（10-24 实证：800x600 家族出口 185.177.72.69 洪水
                    #  161req/300s strict 档；hosting 商，同 212238/46635/62874 判例）
)
# 大云 ASN：保留 UA 自报家门豁免——GEO/SEO 爬虫实证全在此（GPTBot/ChatGPT-User/
# OAI-SearchBot 全 Azure、Amazonbot/PerplexityBot 全 AWS、AhrefsBot 主力 OVH、
# Bravebot Hetzner；Anthropic 无公开清单按大云对待）。搬到大云+伪造 bot UA+低速率
# 与真 SEO 爬虫不可区分=结构性残余，接受（速率闸/CF Labyrinth 仍在）。
CLOUD_ASNS = (
    16509, 14618,   # Amazon AWS（Amazonbot ~700req/12h、PerplexityBot）
    396982,         # Google Cloud（googlebot 的 GCP 抓取出口靠 cf.client.bot 豁免）
    8075,           # Microsoft Azure（bingbot cf.client.bot；OpenAI 全家 252 官方段在此）
    24940,          # Hetzner（Bravebot）
    14061,          # DigitalOcean
    63949,          # Linode / Akamai cloud
    20473,          # Vultr
    16276,          # OVH（AhrefsBot 主力 ~450req/12h）
    31898,          # Oracle Cloud
    12876,          # Scaleway
    45102,          # Alibaba Cloud 国际（站主出口 47.72.103.104 在 OWNER_IPS 豁免）
    132203,         # Tencent Cloud 国际
)
DATACENTER_ASNS = ABUSE_ASNS + CLOUD_ASNS
NGINX_CONTAINER = "noda-static-prod"
ENV_FILE = "/etc/noda/ip-ban.env"           # DOPPLER_SERVICE_TOKEN / ALLOW_CIDRS
STATE_FILE = "/opt/noda/noda-infra/docker/volumes/ops-logs/ip-ban.state.json"
TG_ALERT = "/mnt/mmc1-4/System/Scripts/telegram-alert.sh"

# 封禁后源站验证（2026-10-24 #3 判例：13:50 封禁后 800x600 族出口 185.177.72.69
# 仍经 CF 通道打到源站 15 分钟，人肉看日志才发现）。新封禁进观察名单连续
# VERIFY_CYCLES 轮：被封 IP 仍现于源站日志 = CF 执行缺口，log+TG 告警。
VERIFY_CYCLES = 6

OWNER_IPS = {"47.72.103.104"}               # 站主出口（nginx 白名单同源）

# 官方爬虫网段真值源：googlebot.json / bingbot.json，运行时下载 + 缓存 24h，
# 任一源失败回退内置全量快照（GOOGLEBOT_FALLBACK 317 段 / BINGBOT_FALLBACK 28 段，
# 2026-10-22 抓取）。白名单 IP 优先、不看 UA：Google 段内也有 Chrome Privacy
# Preserving Prefetch Proxy / GoogleOther 等不含 bot 字样的合法爬虫出口。
GOOGLEBOT_URL = ("https://developers.google.com/static/search/apis/"
                 "ipranges/googlebot.json")
BINGBOT_URL = "https://www.bing.com/toolbox/bingbot.json"
RANGES_CACHE = os.path.join(os.path.dirname(STATE_FILE),
                            "ip-ban.net-ranges.json")
RANGES_CACHE_TTL = 24 * 3600
# 额外兜底：googlebot.json 只发布 crawl IP 的 /27 明细，不含 Chrome Privacy
# Preserving Prefetch Proxy / GoogleOther 等同属 Google 的出口（如 66.249.84.x，
# 2026-10 真实日志的多级 XFF 里出现过），保留老 GOOGLE_RANGES=66.249.64.0/19
# 与官方 json 取并集（全部属 Google AS15169；伪造 XFF 头跳无效——取的是尾跳）。
EXTRA_CRAWLER_RANGES = ["66.249.64.0/19",
                        # Mediapartners-Google（AdSense 官方爬虫）出口段，
                        # 2026-10-24 判例：不在 googlebot.json、UA 无 bot 字样，
                        # 整段被 24h-enum 误封一周（209.85.238.129/.130 实证）；
                        # 全 /17 属 Google AS15169，与 GCP 客户段 34.x/35.x 不重叠
                        "209.85.128.0/17"]
GOOGLEBOT_FALLBACK = [
                         "2001:4860:4801:10::/64", "2001:4860:4801:11::/64", "2001:4860:4801:12::/64", "2001:4860:4801:13::/64",
                         "2001:4860:4801:14::/64", "2001:4860:4801:15::/64", "2001:4860:4801:16::/64", "2001:4860:4801:17::/64",
                         "2001:4860:4801:18::/64", "2001:4860:4801:19::/64", "2001:4860:4801:1a::/64", "2001:4860:4801:1b::/64",
                         "2001:4860:4801:1c::/64", "2001:4860:4801:1d::/64", "2001:4860:4801:1e::/64", "2001:4860:4801:1f::/64",
                         "2001:4860:4801:20::/64", "2001:4860:4801:21::/64", "2001:4860:4801:22::/64", "2001:4860:4801:23::/64",
                         "2001:4860:4801:24::/64", "2001:4860:4801:25::/64", "2001:4860:4801:26::/64", "2001:4860:4801:27::/64",
                         "2001:4860:4801:28::/64", "2001:4860:4801:29::/64", "2001:4860:4801:2::/64", "2001:4860:4801:2a::/64",
                         "2001:4860:4801:2b::/64", "2001:4860:4801:2c::/64", "2001:4860:4801:2d::/64", "2001:4860:4801:2e::/64",
                         "2001:4860:4801:2f::/64", "2001:4860:4801:30::/64", "2001:4860:4801:31::/64", "2001:4860:4801:32::/64",
                         "2001:4860:4801:33::/64", "2001:4860:4801:34::/64", "2001:4860:4801:35::/64", "2001:4860:4801:36::/64",
                         "2001:4860:4801:37::/64", "2001:4860:4801:38::/64", "2001:4860:4801:39::/64", "2001:4860:4801:3a::/64",
                         "2001:4860:4801:3b::/64", "2001:4860:4801:3c::/64", "2001:4860:4801:3d::/64", "2001:4860:4801:3e::/64",
                         "2001:4860:4801:3f::/64", "2001:4860:4801:40::/64", "2001:4860:4801:41::/64", "2001:4860:4801:42::/64",
                         "2001:4860:4801:43::/64", "2001:4860:4801:44::/64", "2001:4860:4801:45::/64", "2001:4860:4801:46::/64",
                         "2001:4860:4801:47::/64", "2001:4860:4801:48::/64", "2001:4860:4801:49::/64", "2001:4860:4801:4a::/64",
                         "2001:4860:4801:4b::/64", "2001:4860:4801:4c::/64", "2001:4860:4801:4d::/64", "2001:4860:4801:4e::/64",
                         "2001:4860:4801:50::/64", "2001:4860:4801:51::/64", "2001:4860:4801:52::/64", "2001:4860:4801:53::/64",
                         "2001:4860:4801:54::/64", "2001:4860:4801:55::/64", "2001:4860:4801:56::/64", "2001:4860:4801:57::/64",
                         "2001:4860:4801:58::/64", "2001:4860:4801:59::/64", "2001:4860:4801:60::/64", "2001:4860:4801:61::/64",
                         "2001:4860:4801:62::/64", "2001:4860:4801:63::/64", "2001:4860:4801:64::/64", "2001:4860:4801:65::/64",
                         "2001:4860:4801:66::/64", "2001:4860:4801:67::/64", "2001:4860:4801:68::/64", "2001:4860:4801:69::/64",
                         "2001:4860:4801:6a::/64", "2001:4860:4801:6b::/64", "2001:4860:4801:6c::/64", "2001:4860:4801:6d::/64",
                         "2001:4860:4801:6e::/64", "2001:4860:4801:6f::/64", "2001:4860:4801:70::/64", "2001:4860:4801:71::/64",
                         "2001:4860:4801:72::/64", "2001:4860:4801:73::/64", "2001:4860:4801:74::/64", "2001:4860:4801:75::/64",
                         "2001:4860:4801:76::/64", "2001:4860:4801:77::/64", "2001:4860:4801:78::/64", "2001:4860:4801:79::/64",
                         "2001:4860:4801:7a::/64", "2001:4860:4801:7b::/64", "2001:4860:4801:7c::/64", "2001:4860:4801:7d::/64",
                         "2001:4860:4801:7e::/64", "2001:4860:4801:7f::/64", "2001:4860:4801:80::/64", "2001:4860:4801:81::/64",
                         "2001:4860:4801:82::/64", "2001:4860:4801:83::/64", "2001:4860:4801:84::/64", "2001:4860:4801:85::/64",
                         "2001:4860:4801:86::/64", "2001:4860:4801:87::/64", "2001:4860:4801:88::/64", "2001:4860:4801:90::/64",
                         "2001:4860:4801:91::/64", "2001:4860:4801:92::/64", "2001:4860:4801:93::/64", "2001:4860:4801:94::/64",
                         "2001:4860:4801:95::/64", "2001:4860:4801:96::/64", "2001:4860:4801:97::/64", "2001:4860:4801:a0::/64",
                         "2001:4860:4801:a1::/64", "2001:4860:4801:a2::/64", "2001:4860:4801:a3::/64", "2001:4860:4801:a4::/64",
                         "2001:4860:4801:a5::/64", "2001:4860:4801:a6::/64", "2001:4860:4801:a7::/64", "2001:4860:4801:a8::/64",
                         "2001:4860:4801:a9::/64", "2001:4860:4801:aa::/64", "2001:4860:4801:ab::/64", "2001:4860:4801:ac::/64",
                         "2001:4860:4801:ad::/64", "2001:4860:4801:ae::/64", "2001:4860:4801:b0::/64", "2001:4860:4801:b1::/64",
                         "2001:4860:4801:b2::/64", "2001:4860:4801:b3::/64", "2001:4860:4801:b4::/64", "2001:4860:4801:b5::/64",
                         "2001:4860:4801:b6::/64", "2001:4860:4801:c::/64", "2001:4860:4801:f::/64", "192.178.4.0/27",
                         "192.178.4.128/27", "192.178.4.160/27", "192.178.4.192/27", "192.178.4.224/27",
                         "192.178.4.32/27", "192.178.4.64/27", "192.178.4.96/27", "192.178.5.0/27",
                         "192.178.6.0/27", "192.178.6.128/27", "192.178.6.160/27", "192.178.6.192/27",
                         "192.178.6.224/27", "192.178.6.32/27", "192.178.6.64/27", "192.178.6.96/27",
                         "192.178.7.0/27", "192.178.7.128/27", "192.178.7.160/27", "192.178.7.192/27",
                         "192.178.7.224/27", "192.178.7.32/27", "192.178.7.64/27", "192.178.7.96/27",
                         "34.100.182.96/28", "34.101.50.144/28", "34.118.254.0/28", "34.118.66.0/28",
                         "34.126.178.96/28", "34.146.150.144/28", "34.147.110.144/28", "34.151.74.144/28",
                         "34.152.50.64/28", "34.154.114.144/28", "34.155.98.32/28", "34.165.18.176/28",
                         "34.175.160.64/28", "34.176.130.16/28", "34.22.85.0/27", "34.64.82.64/28",
                         "34.65.242.112/28", "34.80.50.80/28", "34.88.194.0/28", "34.89.10.80/28",
                         "34.89.198.80/28", "34.96.162.48/28", "35.247.243.240/28", "66.249.64.0/27",
                         "66.249.64.128/27", "66.249.64.160/27", "66.249.64.192/27", "66.249.64.224/27",
                         "66.249.64.32/27", "66.249.64.64/27", "66.249.64.96/27", "66.249.65.0/27",
                         "66.249.65.128/27", "66.249.65.160/27", "66.249.65.192/27", "66.249.65.224/27",
                         "66.249.65.32/27", "66.249.65.64/27", "66.249.65.96/27", "66.249.66.0/27",
                         "66.249.66.128/27", "66.249.66.160/27", "66.249.66.192/27", "66.249.66.224/27",
                         "66.249.66.32/27", "66.249.66.64/27", "66.249.66.96/27", "66.249.67.0/27",
                         "66.249.67.32/27", "66.249.67.64/27", "66.249.68.0/27", "66.249.68.128/27",
                         "66.249.68.160/27", "66.249.68.192/27", "66.249.68.224/27", "66.249.68.32/27",
                         "66.249.68.64/27", "66.249.68.96/27", "66.249.69.0/27", "66.249.69.128/27",
                         "66.249.69.160/27", "66.249.69.192/27", "66.249.69.224/27", "66.249.69.32/27",
                         "66.249.69.64/27", "66.249.69.96/27", "66.249.70.0/27", "66.249.70.128/27",
                         "66.249.70.160/27", "66.249.70.192/27", "66.249.70.224/27", "66.249.70.32/27",
                         "66.249.70.64/27", "66.249.70.96/27", "66.249.71.0/27", "66.249.71.128/27",
                         "66.249.71.160/27", "66.249.71.192/27", "66.249.71.224/27", "66.249.71.32/27",
                         "66.249.71.64/27", "66.249.71.96/27", "66.249.72.0/27", "66.249.72.128/27",
                         "66.249.72.160/27", "66.249.72.192/27", "66.249.72.224/27", "66.249.72.32/27",
                         "66.249.72.64/27", "66.249.72.96/27", "66.249.73.0/27", "66.249.73.128/27",
                         "66.249.73.160/27", "66.249.73.192/27", "66.249.73.224/27", "66.249.73.32/27",
                         "66.249.73.64/27", "66.249.73.96/27", "66.249.74.0/27", "66.249.74.128/27",
                         "66.249.74.160/27", "66.249.74.192/27", "66.249.74.224/27", "66.249.74.32/27",
                         "66.249.74.64/27", "66.249.74.96/27", "66.249.75.0/27", "66.249.75.128/27",
                         "66.249.75.160/27", "66.249.75.192/27", "66.249.75.224/27", "66.249.75.32/27",
                         "66.249.75.64/27", "66.249.75.96/27", "66.249.76.0/27", "66.249.76.128/27",
                         "66.249.76.160/27", "66.249.76.192/27", "66.249.76.224/27", "66.249.76.32/27",
                         "66.249.76.64/27", "66.249.76.96/27", "66.249.77.0/27", "66.249.77.128/27",
                         "66.249.77.160/27", "66.249.77.192/27", "66.249.77.224/27", "66.249.77.32/27",
                         "66.249.77.64/27", "66.249.77.96/27", "66.249.78.0/27", "66.249.78.128/27",
                         "66.249.78.160/27", "66.249.78.192/27", "66.249.78.224/27", "66.249.78.32/27",
                         "66.249.78.64/27", "66.249.78.96/27", "66.249.79.0/27", "66.249.79.128/27",
                         "66.249.79.160/27", "66.249.79.192/27", "66.249.79.224/27", "66.249.79.32/27",
                         "66.249.79.64/27",
                     ]
BINGBOT_FALLBACK = [
                       "157.55.39.0/24", "207.46.13.0/24", "40.77.167.0/24", "13.66.139.0/24",
                       "13.66.144.0/24", "52.167.144.0/24", "13.67.10.16/28", "13.69.66.240/28",
                       "13.71.172.224/28", "139.217.52.0/28", "191.233.204.224/28", "20.36.108.32/28",
                       "20.43.120.16/28", "40.79.131.208/28", "40.79.186.176/28", "52.231.148.0/28",
                       "20.79.107.240/28", "51.105.67.0/28", "20.125.163.80/28", "40.77.188.0/22",
                       "65.55.210.0/24", "199.30.24.0/23", "40.77.202.0/24", "40.77.139.0/25",
                       "20.74.197.0/28", "20.15.133.160/27", "40.77.177.0/24", "40.77.178.0/23",
                   ]

# 可配置硬白名单：cron 不 source env 文件，ALLOW_CIDRS 依次从 os.environ（测试/
# 手动注入优先）与 /etc/noda/ip-ban.env 读取，逗号分隔 CIDR，命中请求 IP 即完全跳过。
ALLOW_CIDRS = os.environ.get("ALLOW_CIDRS") or ""
GOOGLE_NETS = [ipaddress.ip_network(c) for c in GOOGLEBOT_FALLBACK]
BING_NETS = [ipaddress.ip_network(c) for c in BINGBOT_FALLBACK]
EXTRA_CRAWLER_NETS = [ipaddress.ip_network(c) for c in EXTRA_CRAWLER_RANGES]

WINDOW_CAP = 1800                            # 单次扫描窗口上限 30 分钟
WINDOW_DEFAULT = 300                         # 首次运行/状态缺失默认 5 分钟
ROLL_HOURS = 6                               # /24 行为滚动窗口
BAN_TTL = 7 * 24 * 3600                      # 封禁 7 天（/24 行为封禁；/32 洪水 7 天内复犯）
BAN_TTL_FIRST = 24 * 3600                    # #37 /32 洪水首犯 1 天（原 7 天降档）
BAN24_MIN_REQ = 40                           # /24 封禁：6h 请求下限
BAN24_MIN_IPS = 3                            #   不同 IP 下限（轮换签名）
BAN24_MAX_ASSET_RATIO = 0.05                 #   静态资源占比上限（真浏览器必带资源）
BAN24_MIN_PATHS = 15                         #   或去重路径数下限（枚举签名）
BAN32_REQ = 60                               # 单 IP 5 分钟窗洪水阈值（严档：夹 bot-UA 或 6h 内有攻击命中）
BAN32_BROWSER_REQ = 300                      # #37 浏览器档阈值：零 bot-UA 且零攻击命中（5 分钟窗）
BROWSER_SIGNAL_MIN = 3                       # 真人豁免：浏览器生命周期信号下限
ATTACK_MIN = 5                               # 攻击 URL 命中下限（6h 滚动窗内按源 IP）
ATTACK_TTL = 30 * 24 * 3600                  # 攻击型封禁 30 天
MAX_ENTRIES = 64                             # 黑名单容量上限
MAX_TRACKS = 500                             # 最多跟踪 /24 数
MAX_EVENTS_PER_TRACK = 400                   # 每 /24 最多保留事件数
MAX_FLOOD_HISTORY = 500                      # #37 洪水前科档案（state.history）容量上限

TRACK_TTL = ROLL_HOURS * 3600

OBVIOUS_BOT_UA = [
    "headlesschrome", "python-requests", "python-urllib", "curl/", "wget",
    "go-http-client", "node-fetch", "axios/", "scrapy", "okhttp",
    "java/", "libwww", "fasthttp", "postman", "httpclient", "aiohttp",
]
SELFID_MARKERS = ["bot", "spider", "slurp", "crawler",
                  # Google 特种爬虫 UA（均无 bot 字样；2026-10-24 Mediapartners
                  # 判例补——IP 段真值源未覆盖/下载失败时的 UA 兜底）。
                  # AdsBot-Google/Bravebot 等已被 "bot" 覆盖，不重复列
                  "mediapartners-google", "apis-google", "feedfetcher",
                  "google-read-aloud", "googleother", "google-safety",
                  "google-inspectiontool",
                  # 平台链接预览抓取器（同样无 bot 字样；2026-10-25 persist 档案
                  # 实测 Meta 2a03:2880::/32 段 facebookexternalhit 被归 human 入档，
                  # 4 天后将误挑战 FB/WhatsApp 分享预览——违反原则①）。Twitterbot/
                  # Slackbot/Discordbot/LinkedInBot/Pinterestbot 带 bot 已覆盖
                  "externalhit", "meta-externalagent", "whatsapp", "telegram",
                  "skypeuripreview"]
ASSET_RE = re.compile(
    r"\.(js|css|mjs|png|jpe?g|webp|svg|gif|ico|woff2?|ttf|otf|map|mp4|avif)$"
    r"|/_next/static/", re.I)
ATTACK_RE = re.compile(                      # 机密探测路径（历史扫库字典高频项）
    r"\.env(\.|$)|/\.aws/|wp-(config|content|login|includes)|application\.(properties|yml)(\.|$)"
    r"|composer/installed|/\.git(/|$)|\.svn/|id_rsa|/\.ssh/|\.sql(\.|$)|\.bak(\.|$)"
    r"|debug\.log(\.|$)|phpmyadmin|web\.config|\.htaccess|\.htpasswd|\.DS_Store"
    r"|xmlrpc\.php|wlwmanifest|actuator(/|$)|\.aspx?(\.|$)|\.jsp(\.|$)|/etc/passwd|\.\./", re.I)
BROWSER_SIGNAL_RE = re.compile(              # 真 PWA 浏览器生命周期端点（爬虫不拉）
    r"/sw\.js$|/manifest\.webmanifest$|/manifest\.json$|/offline\.html?$"
    r"|/_next/static/|/__next\.|/geo\.json$", re.I)
CHROME_VER_RE = re.compile(r"chrome/(\d+)\.", re.I)
LINE_RE = re.compile(
    r'^\S+ \S+ \S+ \[[^\]]+\] "(\S+) ([^"]*) HTTP/[^"]*" (\d{3}) \d+ '
    r'"([^"]*)" "([^"]*)" "([^"]+)"')

DRY_RUN = "--dry-run" in sys.argv


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def tg(msg):
    if os.path.exists(TG_ALERT):
        try:
            subprocess.run([TG_ALERT, msg], timeout=30,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            log("tg failed: %s" % e)


def env_settings():
    """读 ENV_FILE 的 KEY=VALUE（cron 不 source 该文件，脚本自查；不存在返回空）"""
    out = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                m = re.match(r"([A-Z][A-Z0-9_]*)=(.*)", line.strip())
                if m:
                    out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def parse_cidrs(raw):
    """逗号分隔 CIDR 串 → 合法 ip_network 列表（非法项记日志丢弃）"""
    nets = []
    for c in (raw or "").split(","):
        c = c.strip()
        if not c:
            continue
        try:
            nets.append(ipaddress.ip_network(c))
        except ValueError:
            log("warn: ignore invalid CIDR %r" % c)
    return nets


def allow_nets():
    """ALLOW_CIDRS（os.environ 优先，其次 ENV_FILE）→ 解析后的网段列表"""
    return parse_cidrs(ALLOW_CIDRS or env_settings().get("ALLOW_CIDRS", ""))


def http_json(url, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def load_cf_token():
    tok = env_settings().get("DOPPLER_SERVICE_TOKEN")
    if not tok:
        raise RuntimeError("no DOPPLER_SERVICE_TOKEN in %s" % ENV_FILE)
    r = http_json("https://api.doppler.com/v3/configs/config/secret"
                  "?project=noda&config=prd&name=CF_BAN_API_TOKEN", tok)
    v = r["value"]["computed"]
    if not v.startswith("cfat_"):
        raise RuntimeError("CF token from doppler looks wrong")
    return v


def fetch_text(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": "noda-ip-ban/2"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode()


def parse_prefix_json(text):
    """googlebot.json / bingbot.json → CIDR 串列表（camelCase/连字符键名都兼容）"""
    out = []
    for p in json.loads(text).get("prefixes", []):
        for k in ("ipv4Prefix", "ipv6Prefix", "ipv4-prefix", "ipv6-prefix"):
            v = p.get(k)
            if v:
                out.append(v)
    return out


def load_crawler_ranges():
    """刷新官方爬虫网段到全局 GOOGLE_NETS/BING_NETS（缓存 24h；任一源下载或解析
    失败回退该源的内置快照——宁可白名单过宽也不丢保护）"""
    global GOOGLE_NETS, BING_NETS
    now = int(time.time())
    try:
        cache = json.load(open(RANGES_CACHE))
        if now - cache.get("fetched_at", 0) < RANGES_CACHE_TTL:
            g = parse_cidrs(",".join(cache.get("googlebot", [])))
            b = parse_cidrs(",".join(cache.get("bingbot", [])))
            if g and b:
                GOOGLE_NETS, BING_NETS = g, b
                return
    except Exception:
        pass
    fetched = {}
    for name, url in (("googlebot", GOOGLEBOT_URL), ("bingbot", BINGBOT_URL)):
        try:
            fetched[name] = parse_prefix_json(fetch_text(url))
            if not fetched[name]:
                raise ValueError("empty prefix list")
        except Exception as e:
            log("warn: fetch %s.json failed (%s), builtin fallback" % (name, e))
    data = {"fetched_at": now,
            "googlebot": fetched.get("googlebot") or GOOGLEBOT_FALLBACK,
            "bingbot": fetched.get("bingbot") or BINGBOT_FALLBACK}
    try:
        tmp = RANGES_CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, separators=(",", ":"))
        os.replace(tmp, RANGES_CACHE)
    except Exception as e:
        log("warn: ranges cache write failed: %s" % e)
    GOOGLE_NETS = parse_cidrs(",".join(data["googlebot"]))
    BING_NETS = parse_cidrs(",".join(data["bingbot"]))
    fallback = [n for n in ("googlebot", "bingbot") if n not in fetched]
    log("crawler ranges loaded: googlebot=%d bingbot=%d%s"
        % (len(GOOGLE_NETS), len(BING_NETS),
           (" (fallback: %s)" % ",".join(fallback)) if fallback else ""))


def entrypoint_url(zone_id):
    return ("https://api.cloudflare.com/client/v4/zones/%s/rulesets/phases/%s/entrypoint"
            % (zone_id, PHASE))


def get_rules(cf, zone_id):
    """404 = 该 zone 此 phase 尚无 entrypoint ruleset(如 shuotong.wang 首次同步),
    返回空列表,随后的 PUT 会自动创建"""
    try:
        r = http_json(entrypoint_url(zone_id), cf)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise
    if not r.get("success"):
        raise RuntimeError("CF get: %s" % r.get("errors"))
    return r["result"]["rules"] or []


def project(rule):
    return {k: rule[k] for k in ("id", "ref", "action", "action_parameters",
                                 "expression", "description", "enabled")
            if k in rule}


def put_rules(cf, zone_id, rules):
    if DRY_RUN:
        log("dry-run: skip PUT (%d rules)" % len(rules))
        return None
    r = http_json(entrypoint_url(zone_id), cf, method="PUT",
                  body={"rules": [project(x) for x in rules]})
    if not r.get("success"):
        raise RuntimeError("CF put: %s" % r.get("errors"))
    return r


def apply_blacklist(rules, bans):
    """在规则列表中原位维护黑名单规则（空则 disable 休眠），返回同一列表"""
    rule = next((r for r in rules
                 if str(r.get("description", "")).startswith(RULE_MARKER)
                 or r.get("ref") == RULE_MARKER), None)
    if bans:
        expr = "(ip.src in {%s})" % " ".join(sorted(bans))
        desc = "%s auto (%d active; managed by ip-ban.py)" % (RULE_MARKER, len(bans))
        if rule:
            rule["expression"] = expr
            rule["description"] = desc
            rule["enabled"] = True
        else:
            rules.append({"action": "block", "action_parameters": {},
                          "expression": expr, "description": desc,
                          "enabled": True, "ref": RULE_MARKER})
    elif rule:
        rule["enabled"] = False
        rule["description"] = "%s auto (empty; managed by ip-ban.py)" % RULE_MARKER
    return rules


def build_dc_expression(allowed=None, persist_cidrs=None):
    """机房 ASN 常驻封禁规则表达式（纯函数，单测直接打）。2026-10-25 起两分支：

    - 滥用分支（ABUSE_ASNS，block 且**无 UA 豁免**）：这些 ASN 实测/历史只有攻击
      流量，官方爬虫清单 0 命中——伪造 bot 字样也 403（堵 UA 伪造绕过 block 的洞）。
    - 大云分支（CLOUD_ASNS，block 且保留 UA 自报家门豁免）：GEO/SEO 爬虫实证全在
      此（cf.client.bot 不覆盖 AI 爬虫，靠 UA 豁免活——守规矩才敢自报家门）。
    - 两分支共同豁免：cf.client.bot（IP 级验证不可伪造，Googlebot/Bingbot 稳保）
      + 66.249.64.0/19 兜底 + 站主 IP + ALLOW_CIDRS。

    persist_cidrs 非空时 OR 进坚持不懈来访者子句（继承 dc action=block）：
    Free 版自定义规则上限 5 条，无第 6 条配额（2026-10-25 实测
    "6 out of 5"），两名单必须共用本规则；子句独立带 cf.client.bot + 站主豁免。"""
    ip_ex = "ip.src in {%s}" % " ".join(
        ["66.249.64.0/19"] + sorted(OWNER_IPS)
        + [str(n) for n in (allowed if allowed is not None else allow_nets())])
    abuse = ("(ip.src.asnum in {%s}) and not cf.client.bot and not %s"
             % (" ".join(str(a) for a in ABUSE_ASNS), ip_ex))
    ua = "(%s)" % " or ".join('http.user_agent contains "%s"' % u
                              for u in DC_UA_EXEMPTS)
    cloud = ("(ip.src.asnum in {%s}) and not cf.client.bot and not %s and not %s"
             % (" ".join(str(a) for a in CLOUD_ASNS), ua, ip_ex))
    dc = "(%s) or (%s)" % (abuse, cloud)
    if not persist_cidrs:
        return dc
    owners = " ".join(sorted(OWNER_IPS))
    return ("(%s) or (ip.src in {%s} and not cf.client.bot "
            "and not ip.src in {%s})" % (dc, " ".join(persist_cidrs), owners))


def apply_dc_rule(rules, expr):
    """在规则列表中原位维护机房 ASN 常驻规则，返回 (同一列表, 是否有变化)。

    action=block（2026-10-25 用户裁定）：无头浏览器能过 managed_challenge（实证：
    家族 GA 会话），挑战对机器无效；豁免三层保 SEO/GEO（cf.client.bot+官方段+
    UA 自报家门），12h 实测机房 ASN 零真人。"""
    rule = next((r for r in rules
                 if str(r.get("description", "")).startswith(DC_MARKER)
                 or r.get("ref") == DC_MARKER), None)
    if (rule and rule.get("expression") == expr
            and rule.get("action") == DC_ACTION and rule.get("enabled", True)):
        return rules, False
    created = rule is None
    desc = "%s auto (%d ASNs; managed by ip-ban.py)" % (DC_MARKER, len(DATACENTER_ASNS))
    if rule:
        rule["expression"] = expr
        rule["action"] = DC_ACTION
        rule["description"] = desc
        rule["enabled"] = True
    else:
        rules.append({"action": DC_ACTION, "action_parameters": {}, "expression": expr,
                      "description": desc, "enabled": True, "ref": DC_MARKER})
    log("dc-rule: %s (%d ASNs, %s)" % ("created" if created else "updated",
                                       len(DATACENTER_ASNS), DC_ACTION))
    return rules, True


def persist_key(ip):
    """坚持不懈档案键：v4 用 /32，v6 用 /64（家宽 v6 后缀逐日轮换，/64 才追得上）"""
    a = ipaddress.ip_address(ip)
    if a.version == 6:
        return str(ipaddress.ip_network((a, 64), strict=False))
    return "%s/32" % ip


def decide_persistent(days, reqs, signals, n304):
    """坚持不懈来访者判定（纯函数，单测直接打）。

    门槛=窗口内不同到访日 ≥PERSIST_MIN_DAYS 且累计请求 ≥PERSIST_MIN_REQS 且
    signals==0 且 n304==0。signals 只认 PWA 生命周期端点（PERSIST_VETO_RE：
    sw.js/manifest——2026-10-25 实测爬虫家族拉满 _next 但 sw.js 零触碰）；
    n304=真浏览器缓存校验回源（无头族每天全新上下文永不发 If-None-Match）。
    任一非零即真人铁证不挑战（原则 2 防误伤闸）。"""
    return (days >= PERSIST_MIN_DAYS and reqs >= PERSIST_MIN_REQS
            and signals == 0 and n304 == 0)


def decide_enum24(hits, ips, assets, botua, paths):
    """/24 行为指纹判定（纯函数，单测直接打）。

    枚举/爬取形状 =（低静态资源占比 或 bot-UA 过半）且 路径多样性达标。
    paths 只作必要条件、不单独触发：真人共享出口 /24（3+ 用户、高资源、
    多路径）不误封——209.85.238.0/24（assets 76%/paths 35）与 2026-10-21
    日本家宽误封同通道，2026-10-25 复盘把原 OR 改 AND。"""
    return (hits >= BAN24_MIN_REQ and ips >= BAN24_MIN_IPS
            and (assets / hits <= BAN24_MAX_ASSET_RATIO
                 or botua / hits >= 0.5)
            and len(paths) >= BAN24_MIN_PATHS)


def client_ip_from_xff(raw):
    """XFF 串 → 客户端 IP。多级 XFF 取最后一跳：CF 会把访客真实 IP 追加到 XFF
    尾部（等价 CF-Connecting-IP），头部可能是客户端自带的伪造值；从尾往前取
    第一个合法 IP；无合法 IP 返回 None（调用方跳过该行，不抛异常——修
    2026-10 多级 XFF 整轮 ValueError 崩溃）"""
    for hop in reversed([h.strip() for h in raw.split(",")]):
        try:
            ipaddress.ip_address(hop)
            return hop
        except ValueError:
            continue
    return None


def scan_window(since_epoch):
    """返回解析后的访问事件列表 [(ip, path, ua, status)]，解析失败的行丢弃"""
    out = subprocess.run(
        ["docker", "logs", "--since", str(since_epoch), NGINX_CONTAINER],
        capture_output=True, text=True, timeout=120)
    events = []
    for line in (out.stdout + out.stderr).splitlines():
        m = LINE_RE.match(line)
        if m:
            ip = client_ip_from_xff(m.group(6))
            if ip:                          # XFF 无合法 IP（含 "-"）→ 跳过该行
                events.append((ip, m.group(2).split("?", 1)[0], m.group(5),
                               m.group(3)))
    return events


def in_nets(ip, nets):
    """IP 是否命中预解析网段列表；非法 IP 串返回 False 不抛异常"""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in nets)


def in_ranges(ip, cidrs):
    """字符串 CIDR 列表版 in_nets（保留旧接口）"""
    return in_nets(ip, [ipaddress.ip_network(c) for c in cidrs])


def step_verification(verify, events, new_bans, log):
    """封禁后源站验证（2026-10-24 执行缺口判例的自动化）。

    新封禁 CIDR 进观察名单（首跳 skip_first 跳过当轮——当轮 events 还含封禁前
    流量，直接计数会假告警）；此后每轮统计被封 IP 仍现于源站日志的次数，
    命中即告警（CF 边缘未拦住 = 执行缺口，需查防火墙事件）。观察窗满
    VERIFY_CYCLES 轮出队并总结。返回 (更新后 verify dict, 本轮告警列表)。
    """
    for cidr, _reason, _ttl in new_bans:
        if cidr not in verify:
            verify[cidr] = {"left": VERIFY_CYCLES + 1, "hits": 0,
                            "alerted": False, "skip_first": True}
    alerts = []
    expired = []
    for cidr, v in verify.items():
        v["left"] -= 1
        if v.pop("skip_first", False):
            continue
        seen = sum(1 for ip, _p, _u, _s in events if in_ranges(ip, [cidr]))
        v["hits"] += seen
        if seen:
            v["alerted"] = True
            alerts.append("封禁未生效: %s 本轮仍命中源站 %d 次（累计 %d，剩余观察 %d 轮）"
                          % (cidr, seen, v["hits"], max(v["left"], 0)))
        if v["left"] <= 0:
            expired.append(cidr)
    for cidr in expired:
        v = verify.pop(cidr)
        if v["alerted"]:
            log("verify end: %s 观察窗共见 %d 次——执行缺口，查 CF 防火墙事件"
                % (cidr, v["hits"]))
        elif v["hits"]:
            log("verify end: %s 观察窗见 %d 次（封禁后前段流量，未见持续命中）"
                % (cidr, v["hits"]))
        else:
            log("verify end: %s 观察窗干净，封禁生效" % cidr)
    return verify, alerts


_crawler_ip_cache = {}


def is_crawler_ip(ip):
    """请求 IP 是否命中官方爬虫网段（googlebot/bingbot 全量 + Google /19 兜底，
    IP 优先不看 UA）"""
    hit = _crawler_ip_cache.get(ip)
    if hit is None:
        hit = (in_nets(ip, GOOGLE_NETS) or in_nets(ip, BING_NETS)
               or in_nets(ip, EXTRA_CRAWLER_NETS))
        _crawler_ip_cache[ip] = hit
    return hit


def classify(ip, ua, allowed=None):
    """返回 'whitelist' | 'bot' | 'skip'（skip=受欢迎的守规矩爬虫，不计入）"""
    if ip in OWNER_IPS:
        return "whitelist"
    if allowed is None:
        allowed = allow_nets()
    if in_nets(ip, allowed):
        return "whitelist"                   # ALLOW_CIDRS 硬白名单，完全跳过
    if is_crawler_ip(ip):
        return "skip"                        # 官方爬虫段 IP 优先，不看 UA
    u = ua.lower()
    if "googlebot" in u or "bingbot" in u:
        return "bot"          # 假 Googlebot/Bingbot（真段已在上面 skip）——
                              # bingbot 不加会被 SELFID "bot" 误放行为 skip
    if any(m in u for m in SELFID_MARKERS):
        return "skip"                                             # 自报家门的爬虫，欢迎
    if not ua.strip() or any(m in u for m in OBVIOUS_BOT_UA):
        return "bot"
    m = CHROME_VER_RE.search(u)
    if m and int(m.group(1)) < 100:
        return "bot"                                              # 2026 年不存在的老 Chrome
    return "human"


def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
        if "bans" in s and "tracks" in s:
            return s
    except Exception:
        pass
    return {"bans": {}, "tracks": {}}


def save_state(s):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, separators=(",", ":"))
    os.replace(tmp, STATE_FILE)


def apply_safety(proposals):
    """白名单防误伤闸：提案网段含站主 IP、或与官方爬虫段/ALLOW_CIDRS 有交集 →
    拒绝提案并记日志。2026-10-23 补齐：原实现只查了站主 IP（注释却声称防
    Google 段），66.249.73.0/24 由此被误封——这是防再犯的关键闸。"""
    allowed = allow_nets()
    for cidr in list(proposals):
        net = ipaddress.ip_network(cidr)
        if any(ipaddress.ip_address(o) in net for o in OWNER_IPS):
            log("SAFETY: %s contains owner IP, skip" % cidr)
            del proposals[cidr]
            continue
        for name, nets in (("googlebot", GOOGLE_NETS), ("bingbot", BING_NETS),
                           ("google-legacy /19", EXTRA_CRAWLER_NETS),
                           ("allow", allowed)):
            hit = next((n for n in nets if net.overlaps(n)), None)
            if hit:
                log("SAFETY: %s overlaps %s %s, skip" % (cidr, name, hit))
                del proposals[cidr]
                break
    return proposals


def decide_flood32(cnt, botua, signals, attack_hits, last_flood_at, now,
                   window_secs):
    """#37 /32 洪水判定（纯函数，主循环据返回值提案；单测直接打这里）。

    返回 (reason, ttl) 或 None（不封）。优先级与档位（顺序不变：攻击 >
    浏览器豁免 > 洪水阈值）：
      1. attack_hits ≥ ATTACK_MIN → 攻击 URL 优先，升级 30 天（不变）
      2. 零 bot-UA 且 signals ≥ BROWSER_SIGNAL_MIN → None，真人浏览器爆发
         豁免（WARP 事件 2026-10-18 教训，不变）
      3. 阈值分档（#37 2026-10-24 误封 136.70.78.248 根因修复）：零 bot-UA
         且 6h 零攻击命中 → 浏览器档 BAN32_BROWSER_REQ=300——HTML 源站
         no-cache 每次导航都计数 + 老用户生命周期端点被 CF/浏览器缓存挡住，
         豁免信号攒不够 3 个，真人快速翻页 90req/216s 被误封；夹 bot-UA 或
         有攻击前科 → 仍 BAN32_REQ=60 严档
      4. TTL：last_flood_at（state.history[cidr]，无前科 0）在 7 天内 →
         复犯 BAN_TTL=7 天，否则首犯 BAN_TTL_FIRST=1 天；reason 带档位与
         首犯/复犯标记，如 "single-ip flood 90 req/216s (browser-tier, first)"
    """
    if attack_hits >= ATTACK_MIN:                 # 攻击 URL 优先：升级 30 天
        return ("attack-urls %d hits + flood %d req" % (attack_hits, cnt),
                ATTACK_TTL)
    if botua == 0 and signals >= BROWSER_SIGNAL_MIN:
        return None                               # 真人浏览器爆发豁免（不变）
    browser_tier = (botua == 0 and attack_hits == 0)
    threshold = BAN32_BROWSER_REQ if browser_tier else BAN32_REQ
    if cnt < threshold:
        return None
    repeat = last_flood_at > now - 7 * 24 * 3600
    ttl = BAN_TTL if repeat else BAN_TTL_FIRST
    reason = ("single-ip flood %d req/%ds (%s-tier, %s)"
              % (cnt, window_secs,
                 "browser" if browser_tier else "strict",
                 "repeat" if repeat else "first"))
    return (reason, ttl)


def main():
    now = int(time.time())
    since = now - WINDOW_DEFAULT
    try:
        since = int(json.load(open(STATE_FILE)).get("last_run", since))
    except Exception:
        pass
    since = max(since, now - WINDOW_CAP)          # 窗口上限防积压重放
    last_run = now

    if "--status" in sys.argv:
        s = load_state()
        print("blacklist (%d):" % len(s["bans"]))
        for cidr, b in sorted(s["bans"].items(), key=lambda kv: kv[1]["until"]):
            print("  %-22s until %s  (%dd, %s)" % (
                cidr, time.strftime("%F %T", time.localtime(b["until"])),
                b.get("ttl", BAN_TTL) // 86400, b.get("reason", "")))
        print("tracked /24: %d" % len(s["tracks"]))
        pf = s.get("persist") or {}
        hits = s.get("persist_listed") or []
        print("persist tracked: %d, challenged: %d" % (len(pf), len(hits)))
        for k in hits:
            p = pf.get(k) or {}
            print("  %-40s days=%d reqs=%d signals=%d n304=%d"
                  % (k, len(p.get("days", {})), p.get("reqs", 0),
                     p.get("signals", 0), p.get("n304", 0)))
        v = s.get("verify") or {}
        if v:
            print("verifying (%d):" % len(v))
            for cidr, e in sorted(v.items()):
                print("  %-22s left=%s hits=%d%s"
                      % (cidr, e.get("left"), e.get("hits", 0),
                         " skip-first" if e.get("skip_first") else ""))
        return

    load_crawler_ranges()                     # 官方爬虫段（缓存 24h，失败回退内置）
    allowed = allow_nets()
    _crawler_ip_cache.clear()

    try:
        events = scan_window(since)
    except Exception as e:
        log("log scan failed: %s" % e)
        return

    state = load_state()
    state["last_run"] = last_run
    bans = state["bans"]
    tracks = state["tracks"]
    persist = state.setdefault("persist", {})
    cutoff = now - TRACK_TTL

    # ---- 事件入轨 ----
    window_ip_stats = {}                         # ip -> [请求数, 生命周期信号, bot-UA 数]
    for ip, path, ua, status in events:
        cls = classify(ip, ua, allowed)
        if cls == "whitelist" or cls == "skip":
            continue
        st = window_ip_stats.setdefault(ip, [0, 0, 0])
        st[0] += 1
        if BROWSER_SIGNAL_RE.search(path):
            st[1] += 1
        if cls == "bot":
            st[2] += 1
        # 坚持不懈来访者档案（只记「伪装成人的机器」：human 类；whitelist/skip/
        # bot 类不入档——bot 类要么已被 UA 规则边缘拦截，要么该走速率闸）
        if cls == "human":
            pkey = persist_key(ip)
            pf = persist.setdefault(
                pkey, {"days": {}, "reqs": 0, "signals": 0, "n304": 0, "last": 0})
            pf["days"][str(now // 86400)] = 1
            pf["reqs"] += 1
            if PERSIST_VETO_RE.search(path):
                pf["signals"] += 1            # PWA 生命周期=真人铁证（见 PERSIST_VETO_RE 注释）
            if status == "304":
                pf["n304"] += 1            # 真浏览器缓存校验回源；无头族每天全新上下文永不发
            pf["last"] = now
        if ipaddress.ip_address(ip).version != 4:
            continue                     # /24 聚合仅支持 IPv4；IPv6 只走 /32 洪水检测
        p24 = ".".join(ip.split(".")[:3]) + ".0/24"
        t = tracks.setdefault(p24, [])
        t.append([now, ip, 1 if cls == "bot" else 0,
                  1 if ASSET_RE.search(path) else 0, path])
        if len(t) > MAX_EVENTS_PER_TRACK:
            del t[0:len(t) - MAX_EVENTS_PER_TRACK]

    # ---- 清理过期跟踪 ----
    for p24 in list(tracks):
        kept = [e for e in tracks[p24] if e[0] >= cutoff]
        if kept:
            tracks[p24] = kept
        else:
            del tracks[p24]
    if len(tracks) > MAX_TRACKS:
        for k in list(tracks)[:len(tracks) - MAX_TRACKS]:
            del tracks[k]

    # ---- 攻击 URL 计数（机密探测路径，跨 6h 滚动窗按源 IP 聚合）----
    ip_attack = {}
    for p24, evs in tracks.items():
        for e in evs:
            if ATTACK_RE.search(e[4]):
                ip_attack[e[1]] = ip_attack.get(e[1], 0) + 1

    # ---- 评估封禁 ----
    proposals = {}                              # cidr -> (reason, ttl)
    for p24, evs in tracks.items():
        if p24 in bans:
            continue
        hits = len(evs)
        if hits < BAN24_MIN_REQ:
            continue
        ips = {e[1] for e in evs}
        if len(ips) < BAN24_MIN_IPS:
            continue
        assets = sum(e[3] for e in evs)
        botua = sum(e[2] for e in evs)
        paths = {e[4] for e in evs}
        attack = sum(1 for e in evs if ATTACK_RE.search(e[4]))
        if decide_enum24(hits, len(ips), assets, botua, paths):
            escalated = attack >= ATTACK_MIN
            proposals[p24] = ("24h-enum" + ("+attack" if escalated else ""),
                              ATTACK_TTL if escalated else BAN_TTL)
            log("candidate %s: hits=%d ips=%d assets=%.0f%% botua=%.0f%% "
                "paths=%d attack=%d"
                % (p24, hits, len(ips), 100.0 * assets / hits,
                   100.0 * botua / hits, len(paths), attack))
    # #37 洪水前科档案：cidr→上次洪水封禁 epoch（老 state 无 history 键自动补）
    flood_history = state.setdefault("history", {})
    for ip, st in window_ip_stats.items():
        cidr = ip + "/%s" % ("128" if ipaddress.ip_address(ip).version == 6
                             else "32")
        cnt = st[0]
        if cnt < BAN32_REQ or cidr in bans or ip in OWNER_IPS:
            continue
        ah = ip_attack.get(ip, 0)
        hit = decide_flood32(cnt, st[2], st[1], ah,
                             flood_history.get(cidr, 0), now, now - since)
        if hit is None:
            if st[2] == 0 and st[1] >= BROWSER_SIGNAL_MIN:
                # 真人浏览器爆发豁免（WARP 事件 2026-10-18：iPhone 冷缓存首访
                # 19 秒 82 请求触发洪水线误封 7 天）。零 bot-UA + 命中生命周期
                # 端点（sw.js/manifest/_next chunk/__next RSC）= 真浏览器指纹。
                log("exempt %s: browser-burst %d req (signals=%d, botua=0, "
                    "attack=0)" % (cidr, cnt, st[1]))
            continue
        reason, ttl = hit
        proposals[cidr] = (reason, ttl)
        if ttl != ATTACK_TTL:                  # #37 洪水封禁记前科（攻击 30d 不记）
            flood_history[cidr] = now
    if len(flood_history) > MAX_FLOOD_HISTORY:  # #37 前科档案容量防护：裁最旧
        for k in sorted(flood_history, key=flood_history.get)[
                :len(flood_history) - MAX_FLOOD_HISTORY]:
            del flood_history[k]
    for ip, ah in ip_attack.items():            # 低慢速机密探测（不够洪水线也封）
        if ah < ATTACK_MIN:
            continue
        cidr = ip + "/%s" % ("128" if ipaddress.ip_address(ip).version == 6
                             else "32")
        if cidr not in proposals and cidr not in bans and ip not in OWNER_IPS:
            proposals[cidr] = ("attack-urls %d hits/%dh" % (ah, ROLL_HOURS),
                               ATTACK_TTL)
            log("candidate %s: attack-url hits=%d" % (cidr, ah))

    # ---- 坚持不懈来访者（原则 3 收口网）：档案裁剪 + 评估 ----
    persist_cut = now - PERSIST_WINDOW
    for k in list(persist):
        if persist[k]["last"] < persist_cut:
            del persist[k]
    if len(persist) > MAX_PERSIST_TRACK:
        for k in sorted(persist, key=lambda x: persist[x]["last"])[
                :len(persist) - MAX_PERSIST_TRACK]:
            del persist[k]
    min_day = (now - PERSIST_WINDOW) // 86400
    persist_hits = sorted(
        k for k, p in persist.items()
        if k not in bans and decide_persistent(
            len([d for d in p["days"] if int(d) >= min_day]),
            p["reqs"], p["signals"], p["n304"]))
    if len(persist_hits) > MAX_PERSIST_LIST:
        keep = set(sorted(persist_hits,
                          key=lambda k: persist[k]["last"])[-MAX_PERSIST_LIST:])
        log("persist: 名单 %d 超 %d 上限（表达式尺寸保护），按最后到访裁最旧"
            % (len(persist_hits), MAX_PERSIST_LIST))
        persist_hits = [k for k in persist_hits if k in keep]
    persist_listed = state.get("persist_listed") or []
    new_persist = [k for k in persist_hits if k not in persist_listed]
    for k in new_persist:
        p = persist[k]
        log("PERSIST: %s 进挑战名单（%d 天到访 %d req 零信号零304）"
            % (k, len(p["days"]), p["reqs"]))

    # 白名单防误伤闸：含站主 IP / 与官方爬虫段或 ALLOW_CIDRS 交集 → 拒绝
    apply_safety(proposals)

    new_bans = []
    for cidr, (reason, ttl) in proposals.items():
        bans[cidr] = {"until": now + ttl, "banned_at": now,
                      "reason": reason, "ttl": ttl}
        new_bans.append((cidr, reason, ttl))

    # ---- 容量裁剪 ----
    while len(bans) > MAX_ENTRIES:
        oldest = min(bans, key=lambda c: bans[c]["until"])
        del bans[oldest]
        log("capacity: dropped %s" % oldest)

    # ---- 过期解封 ----
    unbanned = [(c, b.get("ttl", BAN_TTL)) for c, b in bans.items()
                if b["until"] <= now]
    for c, _ in unbanned:
        del bans[c]

    # ---- 封禁后源站验证（观察窗内被封 IP 仍现于源站=CF 执行缺口，TG 告警）----
    verify = state.get("verify") or {}
    verify, verify_alerts = step_verification(verify, events, new_bans, log)
    state["verify"] = verify

    # ---- 同步 CF 规则（多 zone：黑名单 + 机房 ASN 常驻规则同步到 ZONES 全部站点）----
    # 每轮都 GET 对账：除封禁变化外，还要校验 dc 常驻规则未被 Dashboard 手改漂移。
    unsynced = sorted(set(state.get("unsynced") or []))
    dc_expr = build_dc_expression(allowed, persist_cidrs=persist_hits)
    try:
        cf = load_cf_token()
        ids = {}
        for zname in ZONES:
            r = http_json(
                "https://api.cloudflare.com/client/v4/zones?name=" + zname, cf)
            z = (r.get("result") or [None])[0]
            if z:
                ids[zname] = z["id"]
        if len(ids) < len(ZONES):
            log("warn: zone 不可达（token 缺该 zone 权限?）: %s — 黑名单暂不覆盖"
                % ",".join(z for z in ZONES if z not in ids))
        need_put = bool(new_bans or unbanned or unsynced
                        or new_persist
                        or [k for k in persist_listed if k not in persist_hits])
        for zname in ZONES:
            zid = ids.get(zname)
            if not zid:
                unsynced = sorted(set(unsynced) | {zname})
                continue
            try:
                rules = apply_blacklist(get_rules(cf, zid), bans)
                rules, dc_changed = apply_dc_rule(rules, dc_expr)
                if need_put or dc_changed:
                    put_rules(cf, zid, rules)
                    if dc_changed and not DRY_RUN and not need_put:
                        tg("ip-ban: 机房 ASN 规则更新——%d 个 ASN 直接 %s"
                           "（滥用 %d 个无 UA 豁免，伪造 bot UA 也 403）。"
                           "豁免：CF验证爬虫+官方段+站主；大云另留 UA 自报家门"
                           % (len(DATACENTER_ASNS), DC_ACTION, len(ABUSE_ASNS)))
                unsynced = [z for z in unsynced if z != zname]
            except Exception as e:
                log("CF sync failed for %s: %s (kept, will retry)" % (zname, e))
                unsynced = sorted(set(unsynced) | {zname})
    except Exception as e:
        log("CF token/zone 解析失败: %s (kept, will retry)" % e)
        unsynced = sorted(set(unsynced) | set(ZONES))
    state["unsynced"] = unsynced
    if not unsynced:
        state["persist_listed"] = persist_hits   # 全 zone 同步成功才记账，失败下轮重试

    # ---- 通知 ----
    for cidr, reason, ttl in new_bans:
        log("BAN: %s (%s), until %s" % (
            cidr, reason, time.strftime("%F %T", time.localtime(now + ttl))))
        tg("ip-ban: 封禁 %s（%s），%d 天后自动解封。当前黑名单 %d 段"
           % (cidr, reason, ttl // 86400, len(bans)))
    for c, ttl in unbanned:
        log("UNBAN: %s silent %dd reached" % (c, ttl // 86400))
        tg("ip-ban: %s 静默满 %d 天，自动解封" % (c, ttl // 86400))
    for msg in verify_alerts:
        tg("ip-ban: %s" % msg)
    for k in new_persist:
        if not unsynced:
            tg("ip-ban: 坚持不懈来访者列入封禁 %s（14 天内≥4 日到访且零浏览器"
               "信号/零304；随 dc 规则 action=block）" % k)
    if not new_bans and not unbanned and not verify_alerts:
        log("no action: %d events scanned, blacklist=%d, tracks=%d"
            % (len(events), len(bans), len(tracks)))

    state["bans"] = bans
    state["tracks"] = tracks
    save_state(state)


if __name__ == "__main__":
    main()
