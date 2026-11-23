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

2026-10-25 用户裁定：ALLOW_CIDRS 撤掉唯一成员 150.249.214.0/24（日本 So-net
家宽 AS2527，10-23 误封判例入列）——「不能走白名单，该怎么封怎么封」：白名单=
该段永久免疫，真被滥用反而无手段；且 /24 枚举闸 OR→AND 修复（同日）已关死当年
纯 paths 误触发通道，家宽共享出口回归正常闸门管辖，误封风险由 AND 结构承担、
不再用白名单兜底。机制空置保留备用。
- 同日第二步（用户裁定）：ABUSE_ASNS(6)/CLOUD_ASNS(13) 拆分——滥用分支撤 UA
  豁免（伪造 bot 字样也 403，家族 100% 出口在此），大云分支保留（GEO/SEO 爬虫
  实证全在大云）；官方清单 OpenAI 252 段全 Azure+Perplexity 8 段全 AWS，0 段
  落滥用 ASN；cf.client.bot/官方段/站主两分支都保留

2026-11-17 修复（OAI-SearchBot 官方段误封判例）：51 黑名单里 17 个来自
openai.com/searchbot.json 官方段（40.67.175.0/25 ×11 + 20.169.77.0/25 ×6，
40.67.175.127 实证）——OpenAI 爬虫管线在 headless 默认 800×600 视口渲染页面
执行 JS，撞 nearby 分辨率哨兵 /__trip，出口逐会话轮换一个封一个（守规矩不重试、
换 IP 再撞），tripwire「真实受众零撞车」判例只验证过人类、没料到官方渲染器；
CF 边缘 cf.client.bot 全规则豁免（firewall events 零事件实证，伪装 UA 拿不到
该身份），源站层是唯一拦截层也必须同步豁免。修复=官方段真值入 is_crawler_ip/
apply_safety（googlebot.json/bingbot.json 同款三号真值源），段外伪造
OAI-SearchBot UA 仍按伪装计 bot、撞哨兵照封。

2026-11-22 修复（misban 全面复查，三处）：
- HubSpot Crawler 误封判例：54.174.58.233/.237/.238（AWS AS14618，UA 自报
  "HubSpot Crawler"）撞 /__trip 被 30 天封禁——tripwire 原版只认官方 IP 清单，
  不在清单里的合法渲染器出口漏网。修复=trip_exempt_ua：UA 自报家门
  （SELFID_MARKERS）豁免 trip 提案；伪装 googlebot/bingbot/oai-searchbot 字样
  不豁免照封（classify 反制先例）。当日解封三条。
- Ahrefs 存量条目滞留判例：11-17 AHREFS_RANGES 修复只堵新提案（SAFETY 闸），
  已入库 6 条 202.8.40-43.x 等 7 天 TTL 到 11-21 才自然消失——misban-watch
  11-20 07:07 实锤 202.8.41.72 仍被 blacklist block（/sw.js，Site Audit 渲染器
  拉 PWA 生命周期端点）。修复=sweep_exempt_bans：每轮把存量黑名单与豁免面
  （官方段/ALLOW/站主）对账，相交即清退+触发 CF 同步，清单更新即刻生效。
- 姊妹 ASN 补列：396356（Latitude.sh 二号牌，104.252.188.x 判例）、207990
  （HostRoyale 二号牌，persist 网实证 194.31.179.168/195.3.137.167）——同
  Datacamp 212238/60068 判例。复查确认无误封保留：9.142.x(RCN)×10/
  185.201.43.x+5.182.186.178(Comcast)×3=800×600 族换住宅代理池出口，
  27.115.124.0/24（上海联通）=枚举指纹 AND 闸达标，均维持。
- 结构性防误封收口：第四官方真值源 duckduckgo（duckduckbot.json，486 个 /32
  内置快照——classify=skip/SAFETY/sweep/misban-watch D1 四层自动覆盖 DDG 全部
  出口）；Apple（applebot.apple.com/json）2026-11-22 实测连接失败暂缓，
  Yandex 无 JSON 源暂缓——官方清单仍不全，misban-watch D3 兜底检测。
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
MAX_PERSIST_LIST = 48                # 名单上限：与 dc 规则共用 4095 字符表达式须留余量
                                    # （CF 单规则表达式 4095 字符；Free 版自定义
                                    #  规则上限 5 条，2026-10-25 实测 "6 out of 5"）。
                                    # 2026-11-19 HK 机房批 216 ASN 后 80→48 重平衡：
                                    # worst case 实测 3604<3895 守卫线（安全余量 200）；
                                    # persist_listed 实际用量 0，LRU 保最新，功能无损。
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
    60068,          # Datacamp/CDN77 二号 ASN（212238 同一公司双牌；10-26 实证
                    #  152.233.12.x 入站；判例：主牌入列后家族换姐妹 ASN，一起封）
    # ---- 2026-10-26 批（GA「美国 Direct 用户」溯源定案，用户裁定：小运营商全禁）----
    #  当日 GA 6 用户里 4 个 US Direct 全为 headless 会话；按「JS 资产>0+HTML 1-2 页
    #  +无外链 referer」筛 12 候选 → Team Cymru BGP 定 ASN（whois OrgName 全是陈旧
    #  注册数据，BGP 实际宣告才作准）。11 ASN 全部为托管/代理出口，官方爬虫 0 落点。
    9009,           # M247 Europe（全球最大 VPN/代理出口商；10-26 实证 189.104.18.171
                    #  Chrome/125 Mac headless 走 /zh/item/{uuid} 301 入站。whois
                    #  netname "US_TX_internet" 系误导——BGP=LT 注册 RO 宣告）
    262287,         # Latitude.sh 裸金属云市场（10-26 实证 104.252.109.130 EdgiOS/120
                    #  headless 主页进入；与 Charter 出口同指纹=同工具双出口）
    11798,          # Ace Data Centers（10-26 实证 31.76.162.235 Chrome/125 Linux
                    #  headless 从 /zh-TW/item/{uuid} 301 入站）
    203020,         # HostRoyale Technologies（10-26 实证 103.194.112.x 三出口：
                    #  sw.js+manifest+offline 全拉的全 JS 层，google.co.nz referer）
    136557,         # Host Universal Pty AU（10-26 实证 103.75.11.70 Linux Chrome/156
                    #  headless 单页 6 资产）
    30058,          # FDCservers（10-26 实证 195.40.x 三出口 Chrome/125 Mac headless
                    #  直入 zh 活动详情页；whois 旧注册名 Code200 已易主，BGP=FDC）
    7203,           # LeaseWeb USA-SFO（10-26 实证 152.163.156.134 Chrome/125 Mac
                    #  headless——whois 误标 RIPE NL；LeaseWeb 主 ASN=60781 同批）
    60781,          # LeaseWeb 全球主 ASN（10-24/25 段立案扩容候选，7203 同公司）
    51167,          # Contabo（10-24/25 段立案扩容候选：预算 VPS 重灾区）
    199524,         # GCore（10-24/25 段立案扩容候选：CDN/边缘代理）
    19148,          # 152.163.152.0/22（10-26 08:37 NZ 实证 152.163.154.167 Mac Chrome/125
                    #  headless 2 分钟 46 请求完整渲染 /zh/item/{uuid}：_next chunks×30+/
                    #  geo.json/POST graphql——与 7203（152.163.156.0/22）判例同指纹，
                    #  邻段姐妹 ASN 一起封，noda-infra#3 终验 live 抓获）
    # ---- 2026-11-18/19 HK 机房全禁批（用户裁定「香港机房全部加入黑名单」）----
    # 判例：45.138.12.6/.16（AS218785 TC DATACENTER）真 Chrome/133 Linux UA 解掉
    # managed_challenge 后打 /.git/.svn/.hg 密探路径（源站全 404 零泄密，
    # attack-urls 8/11 hits 30 天封禁）——真浏览器能解挑战（2026-10-25 DC action
    # 升级 block 的同款判例），AS218785 名单外裸奔只吃到软防线。
    # 全量筛查：RIPE(215)+APNIC(1170) delegated 文件 CC=HK 共 1385 ASN →
    # Team Cymru 批量取名 → 关键词分类（datacenter/hosting/cloud/vps/idc/
    # server/colo/cdn + network hk|hong|ltd|limited）：
    #   入列 216 个机房/托管 ASN（下方逐条带机构名）→ 滥用分支（无 UA 豁免；
    #   HK 官方爬虫零落点，cf.client.bot/官方段/站主豁免保留）；
    #   剔除关键词误报 7 个：Towngas 固网 ISP 9899/10098/10132（真家庭用户）、
    #   Reach IX 转接 17500、Juniper 厂商网 24023、HomeISP/Sakura 219462、
    #   Haruue 社区网 146950；
    #   保守排除：住宅/移动运营商 112 个（HKT/PCCW/HKBN/CMHK/Smartone/HGC 等
    #   CARRIER_RE 拦下）+ 1050 个无 hosting 信号名称（银行/大学/企业网/IX）。
    # 长度实测：表达式 2331-2450 字符 / 4096 上限（Free 版 5 条规则配额，
    # 机房 ASN 只能挤单条 DC 规则；余量 ~1600 字符够未来再扩容）。
    2042,        # GCT-HK - HK Global Cloud DataCenter
    4142,        # ERX-GIN-HK - Global Information Networks Limited
    4614,        # ASIAONLINE-HK-AS - VDC Powerbase Hong Kong Data Centers Limited
    4748,        # RESOLINK-AS-AP - Resources Link Network Limited
    4899,        # WENJING-HK - Hongkong Wen Jing Network Limited
    9259,        # WEBHOST-AS-AP - Web Host Limited
    9826,        # ILINK-HK-AP - VDC Powerbase Hong Kong Data Centers Limited
    17476,       # CHL-AS-AP - CloudRadium (HK) Limited
    23749,       # GLOBAL-TRANSIT-AS-HKCOLO-AP - HKCOLO ltd. Internet Service Provide
    23881,       # UDOMAIN-AS-AP - UDomain Web Hosting Company Ltd
    24345,       # FH-HK - Fasthost Limited
    24544,       # LAWSCLOUDINFRASTRUCTURELIMITED-AS-HK - Law_s Cloud Infrastructure 
    45187,       # RACKSPACE-AP - Rackspace IT Hosting AS IT Hosting Provider Hong Ko
    55369,       # DEDIPOWERHK-AS - DediPower Managed Hosting Limited
    55558,       # SPEEDYGROUPCLOUD-AS-AP - Speedy Group Cloud Limited
    55933,       # CLOUDIE-AS-AP - Cloudie Limited
    58627,       # ONEASIA-NET-AS - OneAsia Network Limited
    58797,       # CARPATHIAHOSTING-HK - Carpathia Hosting
    59270,       # CLOUD-RELY - Cloud Rely Limited
    59436,       # AKARI-AS-HK - Akari Networks Limited
    60699,       # SixtyNet - CDN1.com Limited
    62325,       # HDHK - HUNGTAK International Network Limited
    63849,       # EASYTONENETWORKLIMITED-AS-HK - Easy Tone Network Limited
    63857,       # CLOUD-RELY - Cloud Rely Limited
    63889,       # CLOUDIVLIMITED-AS - Cloud Iv Limited
    63959,       # HKSTL-HK - Hong Kong Syscloud Technology Limited
    64004,       # SSDHOSTING-HK - 18/F, Well Tech Centre
    64009,       # HK36CLOUD-HK - 18/F, Well Tech Centre
    64050,       # BGNL-HK - BGP Network Limited
    64087,       # CNET-HK - Clouds Network Limited
    131224,      # SGC-CAL-AS - SGC-Cloud Alliance Limited
    131324,      # M9TCL-AS-AP - 92Cloud Technology Co., Limited
    132139,      # VECLOUD1-AS-AP - VECLOUD LIMITED
    132304,      # MC-AS-AP - MIND CLOUD (HK)LIMITED
    132422,      # TELECOM-HK - Hong Kong Telecom Global Data Centre
    132499,      # HKCOLONETLIMITED-AS-AP - HKCOLO.NET LIMITED
    132597,      # SERVERWORKS-AS - Hong Kong Serverworks Limited
    132705,      # UDOMAIN-AS - UDomain Web Hosting Company Limited
    132813,      # AISI-AS-AP - HK AISI CLOUD COMPUTING LIMITED
    132839,      # POWERLINE-AS-AP - POWER LINE DATACENTER
    133012,      # CONL-AS-AP - Cocoa Oriental Network Limited
    133178,      # SAITEIDCLIMITED-AS-AP - SAITEIDC Limited
    133199,      # SONDERCLOUDLIMITED-AS-AP - SonderCloud Limited
    133441,      # CLOUDITIDC-KR - CloudITIDC Global
    133454,      # WGNL-AS-AP - Wexstack Global Network Limited
    133526,      # HENGDA-AS-AP - HENGDA NETWORK LIMITED
    133549,      # GCT-AS-AP - Global Cloud DataCenter
    133731,      # CLOUDIE-AS-AP - Cloudie Limited
    133744,      # BETTER-HK - Better Cloud Limited
    133861,      # SONDERCLOUDLIMITED-AS-AP - SonderCloud Limited
    133871,      # GIGAHOST-AS-AP - Gigahost Limited
    133893,      # DIYIXIAN-DIC-AS - Dyxnet Data Centre Services Limited
    134120,      # HVISCL-HK - HongKong Virtual Internal Server Company Limited
    134121,      # RAINBOW-HK - Rainbow network limited
    134130,      # WENJING-HK - Hongkong Wen Jing Network Limited
    134176,      # CLOUDIE-AS-AP - Cloudie Limited
    134198,      # CLOUD-RELY - Cloud Rely Limited
    134200,      # CLOUD-RELY - Cloud Rely Limited
    134207,      # CNIPV4-AS - Asia Pacific Cloud (Hong Kong) Holdings Limited
    134366,      # CCHL-AS-AP - Cloud Computing HK Limited
    134428,      # ECG-AS-AP - Edge Cloud Globe Co., Limited
    134492,      # GSJZCHINATECHNOLO-AS-AP - Guosheng IDC lease
    134520,      # GigsGigsCloud-AS-AP - GigsGigs Network Services
    134664,      # LAYER1-AS-AP - LayerOne Network Limited
    134675,      # HKSERVER-AS-AP - 7/F, TRANS ASIA CTR 18 KIN HONG ST, KWAI CHUNG HO
    134687,      # TWIDC-AS-AP - TWIDC Limited
    134700,      # SINOYCLOUD-AS-AP - Sinoycloud Limited
    134727,      # PING-AS-AP - Ping Network Limited
    134815,      # FIRSTNETWORK-AS-AP - First Network Limited
    134835,      # SNL-HK - Starry Network Limited
    134972,      # IKUUU-AS-AP - IKUUU NETWORK LTD
    135017,      # DCNL-HK - Data Center Network Limited
    135097,      # MYCLOUD-AS-AP - LUOGELANG (FRANCE) LIMITED
    135143,      # HKDCL-AS-AP - Hong Kong Data Centre Limited
    135293,      # EZCHK-AS-AP - Ezlink Cloud Technology Co., Limted
    135314,      # IMCLOUD-AS-AP - IMCLOUD TECHNOLOGY COMPANY LIMITED
    135338,      # STARCLOUD-AS-AP - STARCLOUD INFORMATION LIMITED
    135377,      # UCLOUD-HK-AS-AP - UCLOUD INFORMATION TECHNOLOGY (HK) LIMITED
    135392,      # MILLENIALHOSTLIMITED-AS-GB - MillenialHost Limited
    135398,      # ASIATECH-HK - E-Tech Media Company Data Centre
    135489,      # FENGYENET-AS - FENGYE NETWORKS LIMITED
    135515,      # NPNHL-AS-AP - NEW POS NETWORK HK LIMITED
    136038,      # HDTIDCCLOUD-AS-AP - HDTIDC LIMITED
    136160,      # M92HOSTLIMITED-AS-AP - 92host Limited
    136162,      # ANL-AS-AP - ANSON NETWORK LIMITED
    136222,      # BAJICLOUD-AS-AP - HK BAJI CLOUD COMPUTING LIMITED
    136387,      # DEEPIDC-AS-AP - Deepidc technology international co.,limted
    136472,      # CLOUDYIX-AS-AP - CLOUDYIX Limited
    136476,      # HRMNL-AS-AP - HK RUN MEI NETWORK LIMITED
    136526,      # ALLCLOUD-AS-AP - ALLCLOUD LIMITED
    136576,      # CNIPV4-AS - Asia Pacific Cloud (Hong Kong) Holdings Limited
    136578,      # IPS1-AS-AP - IP SERVERONE SOLUTIONS (HK) LIMITED
    136739,      # ASIACOLOHKLIMITED-AS-HK - Asia Colo (HK) Limited
    136746,      # XRCLOUDNETINC-AS-AP - XRCLOUD.NET INC.
    136897,      # ENJOYVC-AS-AP - Enjoyvc Cloud Group Limited.
    136907,      # HWCLOUDS-AS-AP - HUAWEI CLOUDS
    136950,      # HIITL-AS-AP - Hong Kong FireLine Network LTD
    136970,      # YISUCLOUDLTD-AS-AP - YISU CLOUD LTD
    136993,      # CVTL-AS-AP - CLOUD VALLEY TECHNOLOGY LIMITED
    137280,      # KSYUNGLOBAL-AS-AP - Kingsoft cloud corporation limited
    137427,      # KIDC2-AS-AP - KIDC LIMITED
    137523,      # YUNDUNETWORK-AS-AP - HONGKONG CLOUD NETWORK TECHNOLOGY CO., LIMITE
    137816,      # CLOUDNET-AS-AP - Cloud Net Technologies Limited
    137877,      # LIGHTCLOUD-AS-AP - LIGHT CLOUD (HK) LIMITED
    137913,      # EAST-AS-AP - EDISON Global Networks Limited
    137944,      # CLOUDBASE-AS-AP - HONG KONG CLOUDBASE TECHNOLOGY CO., LIMITED
    138152,      # YISUCLOUDLTD-HK - YISU CLOUD LTD
    138196,      # ONEASIA-NET-AS-TH - OneAsia Network Limited
    138456,      # OCTL-AS-AP - OceanBlue Cloud Technology Limited
    138564,      # GAOSHI-CLOUD - Gaoshi Cloud
    138571,      # SUPERCLOUDSLIMITED-AS-AP - SUPERCLOUDS LIMITED
    138576,      # CODECCLOUD-AS-AP - CodecCloud (HK) Limited
    138586,      # GAOSHICLOUD-AS-AP - CodecCloud (HK) Limited
    138672,      # TRCLOUD-AS-AP - TR CLOUD CO,. LIMITED
    138915,      # KAOPU-HK - Kaopu Cloud HK Limited
    138995,      # ANTBOX1-AS-AP - Antbox Networks Limited
    139086,      # ONL-HK - OCEAN NETWORK LIMITED
    139228,      # STREAMLINESERVERS-AS - Streamline Servers Limited
    139293,      # UFO-AS-AP - UFO Network Limited
    139327,      # UCLOUD-AS-AP - UCLOUD INFORMATION TECHNOLOGY (HK) LIMITED
    139340,      # GIGALINK-AS-AP - HONG KONG GIGALINK NETWORK LIMITED
    139606,      # SPEEDYGROUPCLOUD-IX - Internet Service Provider - Speedy Group Clo
    139638,      # ANTBOX1-AS-AP - Antbox Networks Limited
    139659,      # LUCID-AS-AP - LUCIDACLOUD LIMITED
    139750,      # IDCSERVICESNETINC-AS-AP - IDCServices.net Inc
    139797,      # HONGKONG-CLOUD-AP - Unit 3110, 31/F
    139800,      # CLOUDBASE-AS-AP - HONG KONG CLOUDBASE TECHNOLOGY CO., LIMITED
    139803,      # INLWW-AS-AP - iOVZ Networks Limited
    139817,      # GIGALINK-AS-AP - HONG KONG GIGALINK NETWORK LIMITED
    139851,      # CICCL-AS-AP - CHINA INTERNATIONAL CRANCLOUD CO., LIMITED
    139918,      # CNSERVERSLLC-AS-AP - CNSERVERS LLC
    140048,      # MCTL-AS-AP - MAX CLOUD TECHNOLOGY LIMITED
    140212,      # ZUNCLOUDLIMITED-AS-AP - ZUN CLOUD LIMITED
    140525,      # GIGALINK-AS-AP - HONG KONG GIGALINK NETWORK LIMITED
    140570,      # HKBCS-AS-AP - Hong Kong Beecloud System Technology Services Limite
    140634,      # CODECCLOUD-CDN - CodecCloud (HK) Limited
    140688,      # KAOPU-HK - Kaopu Cloud HK Limited
    140723,      # EDGECLOUDCAMBODIACOLTD-AS-KH - EDGE CLOUD (CAMBODIA) CO., LTD
    140733,      # WUJIDUN-AS-AP - Wujidun Network Limited
    140841,      # LING1-AS-AP - Ling Cloud Corporation Limited
    140882,      # CCHL-AS-AP - Cloud Computing HK Limited
    141444,      # WICKED-AS-AP - Wicked Networks Limited
    141724,      # ITL1-AS-AP - icloud telecom limited
    141750,      # HCJBTC-AS-AP - PC Cloud
    141884,      # INL-AS-AP - Immerse Networks Limited
    142040,      # HKCTNTC-AS-AP - Hong Kong Cloud Times Network Technology Co.,Limit
    142113,      # ESERVER-AS-AP - eServer
    142142,      # LING1-AS-AP - Ling Cloud Corporation Limited
    142259,      # M92HOSTLIMITED-AS-AP - 92host Limited
    142267,      # HKBEE-AS-AP - Hong Kong Beecloud System Technology Services Limite
    142286,      # HKIDC-AS-AP - LUOGELANG (FRANCE) LIMITED
    142403,      # YISUCLOUDLTD-HK - YISU CLOUD LTD
    142645,      # O2NETWORKLIMITED-AS-AP - O2 Network Limited
    148996,      # GCNL-AS-AP - GLOBAL COMMUNICATION NETWORK LIMITED
    149042,      # SITCL-AS-AP - Silicon Cloud Global (US)
    149045,      # SITCL-AS-AP - Silicon Cloud Global (JP)
    149457,      # ANGELCLOUDLIMITED-AS-AP - Angel cloud Limited
    149625,      # NETCLOUD1-AS-AP - NETCLOUD INTERNATIONAL DATA CENTRE LIMITED
    149641,      # HKXC-AS-AP - XCLOUD TECHNOLOGY LIMITED
    149651,      # BETTER-AS-AP - Better Cloud Limited
    149769,      # GCTKL-AS-AP - GA Cloud
    150337,      # HKPENG-AS-AP - PENG CLOUD TECHNOLOGY LIMITED
    151206,      # HKCLOUDDATA-AS-AP - HK CLOUD DATA CO., LIMITED
    151338,      # POLONETWORK-AS-AP - POLONETWORK LIMITED
    151352,      # LIGHT-AS-AP - Light Moon Networks Limited
    151487,      # AWESOMECLOUD-AS-AP - Awesomecloud Limited
    151492,      # ELINK2-AS-AP - E-LINK CLOUD LIMITED
    151850,      # CTG-AS-AP - CTG Server Limited
    151970,      # OCTL-AS-AP - OceanBlue Cloud Technology Limited
    152159,      # HZCL-AS-AP - HK ZUNGWAI CLOUD LIMITED
    152179,      # GCNL-AS-AP - GLOBAL COMMUNICATION NETWORK LIMITED
    152187,      # HOMURANETWORKLTD-AS-AP - Homura Network LTD
    152194,      # CTGSERVERLIMITED-AS-AP - CTG Server Limited
    152705,      # GCTL-AS-AP - Gcc Cloud Technology Limited
    152740,      # IXTECH-AS-AP - IXTECH NETWORK LIMITED
    153457,      # VIEWCLOUD-AS-AP - VIEWCLOUD NETWORK LIMITED
    153476,      # ALICENETWORKSLTD-AS-AP - Alice Networks LTD
    153567,      # NUCLEUSCLOUDLLC-AS-AP - Nucleus Cloud LLC
    153611,      # CLOUDHKLIMITED-AS-AP - CLOUD (HK) LIMITED
    153686,      # SPEED1-AS-AP - SPEED CLOUD LIMITED
    153757,      # IMC-AS-AP - IMC NETWORKS LIMITED
    153867,      # WIDEWIRED-AS-AP - WideWired Networks Limited
    153974,      # ECG-AS-AP - EDGE CLOUD (THAILAND) COMPANY LIMITED
    154107,      # DGNL-AS-AP - DigitalLink Global Network Limited
    154206,      # CDN1COM-AS-AP - CDN1.com Limited
    154309,      # INTELLIGENT1-AS-AP - Intelligent Cloud Limited
    154346,      # OCTL-AS-AP - OceanBlue Cloud Technology Limited
    154432,      # BIL-AS-AP - BeeCloud ICT Limited
    154493,      # CNOL-AS-AP - Cloud Net Operations Limited
    154696,      # ANDCLOUDLTD-AS-AP - Andcloud Limited
    154832,      # HALOCLOUD-AS-HK - HaloCloud Network Limited
    197196,      # PANSTAR-AS - PANSTAR CLOUD LIMITED
    199107,      # HUANGSHENGLONG - Nexatrise Hosting Limited
    201245,      # PZYTA-Network-Limited - PZYTA Network Limited
    204071,      # AS-DEBEE - DEBEE NETWORK LIMITED
    204708,      # ANGELCLOUD - ANGEL CLOUD LIMITED
    205960,      # HDT - HDTIDC LIMITED
    206675,      # PumpCloud - PAN-LIAN TECHNOLOGY CO., LIMITED
    209642,      # MEJIRONETWORK - Mejiro Network Limited
    210110,      # KVMCLOUD-AS - Kvmcloud Network CO., LIMITED
    212921,      # HDT - HDTIDC LIMITED
    214053,      # CLUSTERFAST-AS - ClusterFast Network Limited
    214134,      # Hakimi - Hakimi Network Limited
    214454,      # PoloNetwork-Limited-AS - PoloNetwork Limited
    215958,      # FENGYE - FENGYE NETWORKS LIMITED
    216101,      # HOMURA-AS-RIPE - Homura Network Limited
    218130,      # orientalvps - HONG KONG ORIENTAL SCIENCE AND TECHNOLOGY CO., LIMIT
    218304,      # NEWCLOUD-NET - HONG KONG NEW CLOUD NETWORK TECHNOLOGY CO., LIMITED
    218692,      # KIDC - KIDC LIMITED
    218694,      # TermRatNetworkLimited - TermRat Network Limited
    218785,      # TC-DATACENTER - TC DATACENTER LIMITED
    218915,      # OPENSKY - OpenSky Cloud Infrastructure Limited
    218955,      # Zenlayer - LOCKLINE NETWORKS LIMITED
    218968,      # NOVALINK - NovaLink Integrated Networks Limited
    219263,      # ALLCLOUD - ALLCLOUD LIMITED
    219499,      # ZUNGWAICLOUD - HK ZUNGWAI CLOUD LIMITED

    # ---- 2026-11-19 attack-urls 判例批（CF 挑战盲区入口直达源站实证）----
    # 判例：195.178.110.94（AS48090 DMZHOST/TECHOFF SRV LIMITED，RIPE BG 段
    # GB 注册）5min 窗 306 req 洪水 + 54 条攻击 URL（/.git/config、/.circleci/
    # .azure-pipelines、gcloud access_tokens.db 等密探路径）→ /32 封 30 天。
    # 攻击窗内 CF 事件 0 条（noda zone 其余 IP 有 200 条 challenge/block 事件）
    # = 未走 apex/www 的 geo-challenge，经无挑战 proxied 入口直达源站——入口
    # 收口见 DEAD_HOSTS 子句（2026-11-19 同日落地）。
    48090,          # DMZHOST - TECHOFF SRV LIMITED（195.178.110.0/24）
    # ---- 2026-11-22 姊妹 ASN 补列批（同公司双牌判例：212238/60068 Datacamp
    # 先例、7203/60781 LeaseWeb 先例——主牌入列后家族换姐妹 ASN 继续出口）----
    396356,         # Latitude.sh 裸金属云市场二号 ASN（主牌 262287 已列；2026-11-22
                    # 实证 104.252.188.251/.173/.110 800×600 headless 撞 /__trip
                    # 30 天封禁×3——Team Cymru org 同为 LATITUDE-SH，与 10-26
                    # 判例 104.252.109.130(AS262287) 同指纹同公司）
    207990,         # HostRoyale Technologies 二号 ASN（主牌 203020 已列；2026-11-22
                    # 实证 194.31.179.168/195.3.137.167 14 天 4 到访日零信号零 304
                    # 进 persist 挑战名单——Team Cymru org HR-CUSTOMER HostRoyale
                    # 同公司；此前只吃到 persist 软防线，ASnum 名单漏接）
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

# 官方爬虫网段真值源：googlebot.json / bingbot.json / openai.com/searchbot.json，
# 运行时下载 + 缓存 24h，任一源失败回退内置全量快照（GOOGLEBOT_FALLBACK 317 段 /
# BINGBOT_FALLBACK 28 段，2026-10-22 抓取；OAI_FALLBACK 39 段，2026-11-17 抓取）。
# 白名单 IP 优先、不看 UA：Google 段内也有 Chrome Privacy
# Preserving Prefetch Proxy / GoogleOther 等不含 bot 字样的合法爬虫出口。
# OpenAI 段判例（2026-11-17）：其爬虫管线在 headless 默认 800×600 视口渲染页面，
# 撞 nearby 分辨率哨兵 /__trip，51 黑名单里 17 个是官方段出口——ChatGPT 搜索
# 收录被逐出口掐断；CF 边缘 cf.client.bot 全规则豁免（firewall events 零事件
# 实证），源站层必须同步豁免，否则白名单只剩半边。
# 2026-11-23 实测旧路径 302 至 common-crawlers.json（同 317 段结构，
# 34.155.98.32/28 等 geo-crawl 段在列，66.249.x 在列）——直接指向新路径，
# 防 Google 未来砍掉旧跳转
GOOGLEBOT_URL = ("https://developers.google.com/static/crawling/"
                 "ipranges/common-crawlers.json")
BINGBOT_URL = "https://www.bing.com/toolbox/bingbot.json"
OAI_URL = "https://openai.com/searchbot.json"
# DuckDuckGo 官方段（duckduckbot.json，Google 式 prefixes 结构，parse_prefix_json
# 直接兼容；2026-11-22 实测 486 个 /32 无 v6）。第四真值源：misban 复查判例的
# 结构性收口——官方清单每多一家，classify=skip/SAFETY/sweep/misban-watch D1
# 四层防线自动覆盖该家全部出口。
DDG_URL = "https://duckduckgo.com/duckduckbot.json"
RANGES_CACHE = os.path.join(os.path.dirname(STATE_FILE),
                            "ip-ban.net-ranges.json")
RANGES_CACHE_TTL = 24 * 3600
# 额外兜底：googlebot.json 只发布 crawl IP 的 /27 明细，不含 Chrome Privacy
# Preserving Prefetch Proxy / GoogleOther 等同属 Google 的出口（如 66.249.84.x，
# 2026-10 真实日志的多级 XFF 里出现过），保留老 GOOGLE_RANGES=66.249.64.0/19
# 与官方 json 取并集（全部属 Google AS15169；伪造 XFF 头跳无效——取的是尾跳）。
# 2026-11-23 起本清单同时是 CF 边缘豁免集的单一真值源：build_dc_expression
# 各分支 ip_ex 与 geo-challenge 静态豁免段均镜像此清单（11-23 死站分支只补
# IPv4 /19 漏掉 IPv6 段复发 ::f4/fa 的判例教训——豁免面必须同源同步）。
EXTRA_CRAWLER_RANGES = ["66.249.64.0/19",
                        # Mediapartners-Google（AdSense 官方爬虫）出口段，
                        # 2026-10-24 判例：不在 googlebot.json、UA 无 bot 字样，
                        # 整段被 24h-enum 误封一周（209.85.238.129/.130 实证）；
                        # 全 /17 属 Google AS15169，与 GCP 客户段 34.x/35.x 不重叠
                        "209.85.128.0/17",
                        # Chrome 私密预取代理/Google SERP 预取出口（Google 官方
                        # 文档明示该服务走 2001:4860:7::/48；ARIN 2001:4800::/23
                        # = GOOGLE-IPV6 Google LLC）。2026-11-01 判例：persist
                        # 惯犯网把 2001:4860:7:40b::/64 列入挑战名单——源站 14 req
                        # 全部 referer=https://www.google.com/、真实内容页 200/301、
                        # 零攻击路径；预取代理天生「零 PWA 信号+零 304+多日重复」，
                        # persist 三铁证恰好是它的正常形状。同族 :50b/:80b 已在
                        # 档案 3/4 天排队，/48 级白名单一次根治
                        "2001:4860:7::/48"]
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

# OAI-SearchBot 官方段（openai.com/searchbot.json 全量，2026-11-17 抓取）。
# OpenAI 全家在 Azure（AS8075）——dc 规则 Azure 组靠 not cf.client.bot 豁免
# googlebot 式放行，源站层靠此真值段对应豁免；敌对族无法从官方段发包（IP
# 归属硬验证），豁免不破防。伪造 OAI-SearchBot UA 的段外流量不豁免（classify
# 仍按伪装计 bot，2026-10-18 设计保持）。
OAI_FALLBACK = [
                 "4.227.36.0/25", "13.66.216.176/28", "20.14.99.96/28", "20.25.151.224/28",
                 "20.42.10.176/28", "20.168.18.32/28", "20.169.6.224/28", "20.169.7.48/28",
                 "20.169.77.0/25", "20.171.53.224/28", "20.171.123.64/28", "23.102.145.48/28",
                 "40.67.175.0/25", "40.90.214.16/28", "51.8.102.0/24", "74.7.175.128/25",
                 "74.7.228.0/25", "74.7.228.128/25", "74.7.229.0/25", "74.7.229.128/25",
                 "74.7.230.0/25", "74.7.241.128/25", "74.7.242.128/25", "74.7.243.0/25",
                 "74.7.244.0/25", "104.210.140.128/28", "135.234.64.0/24", "172.182.193.80/28",
                 "172.182.193.224/28", "172.182.194.32/28", "172.182.194.144/28", "172.182.195.48/28",
                 "172.182.209.208/28", "172.182.211.192/28", "172.182.213.192/28", "172.182.224.0/28",
                 "172.203.190.80/28", "172.203.190.112/28", "172.203.190.128/28",
                 ]


# DuckDuckGo 官方段（duckduckbot.json 全量，2026-11-22 抓取；
# 486 个 /32 无 v6，Azure 前端出口 + DDG 自有段混合）。第四真值源：
# 2026-11-22 misban 复查结构性收口——官方清单每多一家，classify=skip/
# SAFETY/sweep/misban-watch D1 四层防线自动覆盖该家全部出口。
DDG_FALLBACK = [
                 "104.43.54.127/32",
                 "104.43.55.116/32",
                 "104.43.55.117/32",
                 "104.43.55.166/32",
                 "104.43.55.167/32",
                 "108.141.83.74/32",
                 "128.203.132.152/32",
                 "128.203.181.79/32",
                 "128.203.214.241/32",
                 "128.203.236.110/32",
                 "128.203.82.154/32",
                 "13.86.35.212/32",
                 "13.89.106.77/32",
                 "13.90.178.139/32",
                 "130.107.228.224/32",
                 "131.145.39.118/32",
                 "131.189.183.241/32",
                 "132.164.209.198/32",
                 "132.196.106.146/32",
                 "132.220.1.71/32",
                 "134.33.207.189/32",
                 "135.171.251.169/32",
                 "135.233.63.237/32",
                 "135.234.221.112/32",
                 "135.235.183.95/32",
                 "172.168.115.250/32",
                 "172.168.12.93/32",
                 "172.168.133.76/32",
                 "172.168.137.102/32",
                 "172.168.152.88/32",
                 "172.168.173.230/32",
                 "172.168.190.186/32",
                 "172.168.227.120/32",
                 "172.168.254.119/32",
                 "172.168.43.43/32",
                 "172.168.51.216/32",
                 "172.168.53.53/32",
                 "172.168.81.217/32",
                 "172.168.94.160/32",
                 "172.169.164.109/32",
                 "172.169.17.165/32",
                 "172.169.177.131/32",
                 "172.169.181.237/32",
                 "172.169.28.184/32",
                 "172.169.36.43/32",
                 "172.169.53.208/32",
                 "172.169.60.134/32",
                 "172.169.7.33/32",
                 "172.169.93.148/32",
                 "172.171.37.221/32",
                 "172.179.105.87/32",
                 "172.179.128.118/32",
                 "172.188.250.220/32",
                 "172.189.40.18/32",
                 "172.193.184.42/32",
                 "172.193.197.146/32",
                 "172.193.245.229/32",
                 "172.194.141.49/32",
                 "172.199.55.212/32",
                 "172.210.111.68/32",
                 "191.233.3.197/32",
                 "191.233.3.202/32",
                 "191.234.216.178/32",
                 "191.234.216.4/32",
                 "191.235.201.214/32",
                 "191.235.202.38/32",
                 "191.235.202.48/32",
                 "20.100.136.36/32",
                 "20.100.140.155/32",
                 "20.101.17.173/32",
                 "20.102.34.205/32",
                 "20.109.129.162/32",
                 "20.109.130.190/32",
                 "20.109.241.18/32",
                 "20.112.58.44/32",
                 "20.113.14.159/32",
                 "20.113.3.121/32",
                 "20.115.181.187/32",
                 "20.118.11.251/32",
                 "20.119.127.146/32",
                 "20.12.141.99/32",
                 "20.12.249.123/32",
                 "20.12.252.21/32",
                 "20.121.75.32/32",
                 "20.13.44.19/32",
                 "20.15.142.178/32",
                 "20.166.171.150/32",
                 "20.170.75.54/32",
                 "20.175.232.228/32",
                 "20.185.79.15/32",
                 "20.185.79.47/32",
                 "20.190.21.172/32",
                 "20.191.44.119/32",
                 "20.191.44.16/32",
                 "20.191.44.22/32",
                 "20.191.44.234/32",
                 "20.191.45.212/32",
                 "20.193.12.126/32",
                 "20.193.24.10/32",
                 "20.193.24.251/32",
                 "20.193.25.197/32",
                 "20.193.27.215/32",
                 "20.193.45.113/32",
                 "20.195.108.47/32",
                 "20.195.58.189/32",
                 "20.197.209.11/32",
                 "20.197.209.27/32",
                 "20.198.132.126/32",
                 "20.198.152.208/32",
                 "20.201.15.208/32",
                 "20.204.228.200/32",
                 "20.204.240.172/32",
                 "20.204.241.148/32",
                 "20.204.242.101/32",
                 "20.204.242.19/32",
                 "20.204.243.55/32",
                 "20.204.246.254/32",
                 "20.204.246.81/32",
                 "20.207.107.181/32",
                 "20.207.117.66/32",
                 "20.207.72.11/32",
                 "20.207.72.110/32",
                 "20.207.72.113/32",
                 "20.207.72.21/32",
                 "20.207.97.190/32",
                 "20.207.99.197/32",
                 "20.212.139.34/32",
                 "20.212.90.107/32",
                 "20.216.200.223/32",
                 "20.219.43.246/32",
                 "20.219.45.190/32",
                 "20.219.45.67/32",
                 "20.221.10.115/32",
                 "20.221.84.185/32",
                 "20.226.133.105/32",
                 "20.23.88.231/32",
                 "20.231.254.179/32",
                 "20.232.249.95/32",
                 "20.232.51.46/32",
                 "20.236.195.196/32",
                 "20.236.198.192/32",
                 "20.236.227.113/32",
                 "20.236.233.23/32",
                 "20.236.247.180/32",
                 "20.236.40.93/32",
                 "20.237.1.51/32",
                 "20.241.135.19/32",
                 "20.241.147.151/32",
                 "20.241.153.203/32",
                 "20.241.164.5/32",
                 "20.241.241.100/32",
                 "20.242.133.53/32",
                 "20.242.135.165/32",
                 "20.242.211.139/32",
                 "20.242.215.53/32",
                 "20.242.237.240/32",
                 "20.246.132.168/32",
                 "20.246.225.34/32",
                 "20.247.235.11/32",
                 "20.250.51.113/32",
                 "20.252.16.193/32",
                 "20.252.41.18/32",
                 "20.252.63.162/32",
                 "20.252.88.10/32",
                 "20.252.9.6/32",
                 "20.253.114.51/32",
                 "20.253.59.76/32",
                 "20.253.96.199/32",
                 "20.29.149.44/32",
                 "20.29.154.56/32",
                 "20.3.1.178/32",
                 "20.3.60.212/32",
                 "20.40.133.240/32",
                 "20.40.147.172/32",
                 "20.43.150.85/32",
                 "20.43.150.93/32",
                 "20.43.152.28/32",
                 "20.43.172.120/32",
                 "20.44.222.1/32",
                 "20.49.129.236/32",
                 "20.49.136.28/32",
                 "20.50.168.91/32",
                 "20.50.48.159/32",
                 "20.50.48.192/32",
                 "20.50.49.0/32",
                 "20.50.49.237/32",
                 "20.50.49.25/32",
                 "20.50.49.40/32",
                 "20.50.49.55/32",
                 "20.50.50.118/32",
                 "20.50.50.121/32",
                 "20.50.50.123/32",
                 "20.50.50.130/32",
                 "20.50.50.134/32",
                 "20.50.50.145/32",
                 "20.50.50.146/32",
                 "20.50.50.163/32",
                 "20.50.50.46/32",
                 "20.53.134.160/32",
                 "20.53.78.106/32",
                 "20.53.78.123/32",
                 "20.53.78.138/32",
                 "20.53.78.144/32",
                 "20.53.78.236/32",
                 "20.53.91.2/32",
                 "20.53.92.211/32",
                 "20.54.224.39/32",
                 "20.56.197.58/32",
                 "20.56.197.63/32",
                 "20.59.0.65/32",
                 "20.61.142.192/32",
                 "20.61.34.40/32",
                 "20.62.224.44/32",
                 "20.64.185.45/32",
                 "20.69.129.205/32",
                 "20.69.131.45/32",
                 "20.69.138.149/32",
                 "20.69.138.189/32",
                 "20.69.144.137/32",
                 "20.69.146.171/32",
                 "20.69.147.21/32",
                 "20.69.171.204/32",
                 "20.69.74.250/32",
                 "20.71.12.143/32",
                 "20.71.69.210/32",
                 "20.72.197.110/32",
                 "20.72.203.250/32",
                 "20.72.218.29/32",
                 "20.72.221.33/32",
                 "20.72.221.45/32",
                 "20.72.225.13/32",
                 "20.72.242.209/32",
                 "20.72.242.93/32",
                 "20.73.132.240/32",
                 "20.73.202.147/32",
                 "20.75.144.152/32",
                 "20.75.254.61/32",
                 "20.77.146.108/32",
                 "20.79.226.26/32",
                 "20.79.238.198/32",
                 "20.79.239.66/32",
                 "20.8.252.26/32",
                 "20.80.114.203/32",
                 "20.80.120.41/32",
                 "20.80.129.80/32",
                 "20.80.135.7/32",
                 "20.80.156.88/32",
                 "20.81.115.13/32",
                 "20.82.24.207/32",
                 "20.84.138.61/32",
                 "20.84.219.45/32",
                 "20.84.251.223/32",
                 "20.85.138.75/32",
                 "20.85.167.56/32",
                 "20.85.187.146/32",
                 "20.88.168.65/32",
                 "20.9.114.242/32",
                 "20.93.28.24/32",
                 "20.93.49.96/32",
                 "20.99.154.113/32",
                 "20.99.255.235/32",
                 "4.144.148.23/32",
                 "4.144.182.50/32",
                 "4.144.227.142/32",
                 "4.144.251.39/32",
                 "4.149.142.7/32",
                 "4.149.159.102/32",
                 "4.149.159.71/32",
                 "4.149.216.220/32",
                 "4.150.142.218/32",
                 "4.154.193.167/32",
                 "4.156.136.79/32",
                 "4.156.154.107/32",
                 "4.156.30.123/32",
                 "4.157.77.76/32",
                 "4.172.49.103/32",
                 "4.177.16.196/32",
                 "4.182.10.198/32",
                 "4.182.131.108/32",
                 "4.195.133.120/32",
                 "4.201.125.59/32",
                 "4.201.141.71/32",
                 "4.201.197.203/32",
                 "4.201.206.133/32",
                 "4.201.220.8/32",
                 "4.207.220.92/32",
                 "4.209.224.56/32",
                 "4.213.46.14/32",
                 "4.226.40.135/32",
                 "4.228.76.163/32",
                 "4.237.155.54/32",
                 "4.237.244.80/32",
                 "4.242.119.13/32",
                 "4.246.10.252/32",
                 "4.248.234.26/32",
                 "4.249.216.104/32",
                 "4.249.223.51/32",
                 "4.249.238.11/32",
                 "4.254.123.56/32",
                 "4.255.35.121/32",
                 "4.255.39.80/32",
                 "40.114.182.153/32",
                 "40.114.182.172/32",
                 "40.114.182.45/32",
                 "40.114.183.196/32",
                 "40.114.183.251/32",
                 "40.114.183.88/32",
                 "40.119.232.146/32",
                 "40.119.232.215/32",
                 "40.119.232.218/32",
                 "40.119.232.251/32",
                 "40.119.232.50/32",
                 "40.121.121.54/32",
                 "40.127.154.196/32",
                 "40.64.105.247/32",
                 "40.64.106.11/32",
                 "40.64.106.152/32",
                 "40.64.67.220/32",
                 "40.64.78.45/32",
                 "40.64.88.145/32",
                 "40.65.78.86/32",
                 "40.76.162.17/32",
                 "40.76.162.191/32",
                 "40.76.162.208/32",
                 "40.76.162.247/32",
                 "40.76.163.23/32",
                 "40.76.163.7/32",
                 "40.76.173.151/32",
                 "40.81.250.205/32",
                 "40.82.218.203/32",
                 "40.88.195.62/32",
                 "40.88.21.235/32",
                 "40.89.243.175/32",
                 "48.192.16.86/32",
                 "48.192.74.178/32",
                 "48.200.33.227/32",
                 "48.202.155.200/32",
                 "48.202.171.124/32",
                 "48.204.32.87/32",
                 "48.206.18.152/32",
                 "48.217.129.210/32",
                 "48.217.212.89/32",
                 "48.217.23.236/32",
                 "48.223.209.110/32",
                 "51.104.144.31/32",
                 "51.104.146.225/32",
                 "51.104.146.235/32",
                 "51.104.160.167/32",
                 "51.104.160.177/32",
                 "51.104.161.32/32",
                 "51.104.162.149/32",
                 "51.104.163.250/32",
                 "51.104.164.109/32",
                 "51.104.164.147/32",
                 "51.104.164.189/32",
                 "51.104.164.215/32",
                 "51.104.166.111/32",
                 "51.104.167.104/32",
                 "51.104.167.110/32",
                 "51.104.167.19/32",
                 "51.104.167.52/32",
                 "51.104.167.54/32",
                 "51.104.167.61/32",
                 "51.104.167.71/32",
                 "51.104.167.87/32",
                 "51.104.167.88/32",
                 "51.104.167.95/32",
                 "51.104.167.96/32",
                 "51.104.180.26/32",
                 "51.104.180.47/32",
                 "51.104.180.53/32",
                 "51.107.40.209/32",
                 "51.116.131.221/32",
                 "51.120.48.122/32",
                 "51.138.90.161/32",
                 "51.138.90.206/32",
                 "51.138.90.233/32",
                 "51.143.114.45/32",
                 "51.145.185.16/32",
                 "51.8.253.152/32",
                 "51.8.31.28/32",
                 "51.8.71.117/32",
                 "52.142.24.149/32",
                 "52.142.26.175/32",
                 "52.143.241.111/32",
                 "52.143.242.6/32",
                 "52.143.243.117/32",
                 "52.143.244.81/32",
                 "52.143.247.235/32",
                 "52.143.95.162/32",
                 "52.143.95.204/32",
                 "52.146.57.51/32",
                 "52.146.58.236/32",
                 "52.146.59.12/32",
                 "52.146.59.154/32",
                 "52.146.59.156/32",
                 "52.146.63.80/32",
                 "52.148.161.87/32",
                 "52.148.165.38/32",
                 "52.149.25.43/32",
                 "52.149.28.18/32",
                 "52.149.28.83/32",
                 "52.149.30.45/32",
                 "52.149.56.151/32",
                 "52.149.58.139/32",
                 "52.149.58.173/32",
                 "52.149.58.27/32",
                 "52.149.58.69/32",
                 "52.149.60.38/32",
                 "52.149.61.51/32",
                 "52.154.169.200/32",
                 "52.154.169.50/32",
                 "52.154.170.113/32",
                 "52.154.170.117/32",
                 "52.154.170.122/32",
                 "52.154.170.209/32",
                 "52.154.170.229/32",
                 "52.154.170.243/32",
                 "52.154.170.26/32",
                 "52.154.170.28/32",
                 "52.154.170.88/32",
                 "52.154.170.96/32",
                 "52.154.171.0/32",
                 "52.154.171.150/32",
                 "52.154.171.196/32",
                 "52.154.171.205/32",
                 "52.154.171.235/32",
                 "52.154.171.250/32",
                 "52.154.171.44/32",
                 "52.154.171.70/32",
                 "52.154.171.87/32",
                 "52.154.172.2/32",
                 "52.154.204.93/32",
                 "52.154.60.82/32",
                 "52.185.93.208/32",
                 "52.186.37.211/32",
                 "52.188.89.106/32",
                 "52.189.70.103/32",
                 "52.190.37.160/32",
                 "52.191.222.158/32",
                 "52.191.82.242/32",
                 "52.224.147.21/32",
                 "52.224.16.221/32",
                 "52.224.16.229/32",
                 "52.224.19.152/32",
                 "52.224.191.245/32",
                 "52.224.20.174/32",
                 "52.224.20.181/32",
                 "52.224.20.186/32",
                 "52.224.20.190/32",
                 "52.224.20.193/32",
                 "52.224.20.203/32",
                 "52.224.20.204/32",
                 "52.224.20.223/32",
                 "52.224.20.227/32",
                 "52.224.20.249/32",
                 "52.224.21.19/32",
                 "52.224.21.20/32",
                 "52.224.21.23/32",
                 "52.224.21.27/32",
                 "52.224.21.4/32",
                 "52.224.21.49/32",
                 "52.224.21.51/32",
                 "52.224.21.53/32",
                 "52.224.21.55/32",
                 "52.224.21.61/32",
                 "52.242.224.168/32",
                 "52.250.46.221/32",
                 "57.151.44.140/32",
                 "57.152.17.237/32",
                 "57.152.62.107/32",
                 "57.152.72.128/32",
                 "57.155.18.44/32",
                 "57.165.205.172/32",
                 "57.167.88.38/32",
                 "64.236.118.43/32",
                 "64.236.15.33/32",
                 "64.236.93.100/32",
                 "68.219.152.220/32",
                 "72.144.95.185/32",
                 "74.163.169.106/32",
                 "74.163.208.206/32",
                 "74.179.200.126/32",
                 "74.179.232.116/32",
                 "74.242.194.48/32",
                 "98.70.219.37/32",
                 ]

# Ahrefs 官方段（APNIC AHREFS-AS-AP 注册段，AS140577；2026-11-17 判例）：
# 34 黑名单里 6 个 202.8.40-43.x——cf.client.bot 认证 bot 边缘零事件实证
# （11-14/11-15 封禁在 72h 保留期内却零事件=没匹配任何规则），其 JS 渲染器
# （Site Audit）800×600 撞 nearby 分辨率哨兵，OpenAI 同款第二例。/23 注册段
# 2003 年起稳定，静态常量即可（无需运行时源）。
AHREFS_RANGES = ["202.8.40.0/23", "202.8.42.0/23"]

# 可配置硬白名单：cron 不 source env 文件，ALLOW_CIDRS 依次从 os.environ（测试/
# 手动注入优先）与 /etc/noda/ip-ban.env 读取，逗号分隔 CIDR，命中请求 IP 即完全跳过。
ALLOW_CIDRS = os.environ.get("ALLOW_CIDRS") or ""
GOOGLE_NETS = [ipaddress.ip_network(c) for c in GOOGLEBOT_FALLBACK]
BING_NETS = [ipaddress.ip_network(c) for c in BINGBOT_FALLBACK]
OAI_NETS = [ipaddress.ip_network(c) for c in OAI_FALLBACK]
DDG_NETS = [ipaddress.ip_network(c) for c in DDG_FALLBACK]
AHREFS_NETS = [ipaddress.ip_network(c) for c in AHREFS_RANGES]
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
TRIP_PATH = "/__trip"                # 800x600 指纹 tripwire 自报端点（nearby 内联 JS sendBeacon）
TRIP_TTL = ATTACK_TTL                # 单发即封 30 天：出口逐会话轮换，同 IP 凑不出复犯
TRIP_REASON = "fingerprint-tripwire" # 800x600 headless 族（GA4 判例 2026-10-24 真实受众零撞车）
TRIP_UA_MAX = 200                    # #18 取证样本 UA/referer 截断长度（合理长度，防撑爆日志/state）
TRIP_SAMPLES_MAX = 50                # #18 state 命中样本环形缓冲容量（issue 下限 ≥20；单轮样本≈1 条，50 条≈数天）
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
    """刷新官方爬虫网段到全局 GOOGLE_NETS/BING_NETS/OAI_NETS/DDG_NETS（缓存
    24h；任一源下载或解析失败回退该源的内置快照——宁可白名单过宽也不丢保护）"""
    global GOOGLE_NETS, BING_NETS, OAI_NETS, DDG_NETS
    now = int(time.time())
    try:
        cache = json.load(open(RANGES_CACHE))
        if now - cache.get("fetched_at", 0) < RANGES_CACHE_TTL:
            g = parse_cidrs(",".join(cache.get("googlebot", [])))
            b = parse_cidrs(",".join(cache.get("bingbot", [])))
            if g and b:
                # 老格式缓存（无 openai/duckduckgo 键）迁移：g/b 保持缓存新鲜
                # 值，新源用内置快照补位（openai 2026-11-17 / ddg 2026-11-22
                # 抓取）——不因迁移缺键把老源一并降级到更旧的快照
                o_raw = cache.get("openai")
                o = parse_cidrs(",".join(o_raw)) if o_raw else OAI_NETS
                d_raw = cache.get("duckduckgo")
                d = parse_cidrs(",".join(d_raw)) if d_raw else DDG_NETS
                if o and d:
                    GOOGLE_NETS, BING_NETS, OAI_NETS, DDG_NETS = g, b, o, d
                    return
    except Exception:
        pass
    fetched = {}
    for name, url in (("googlebot", GOOGLEBOT_URL), ("bingbot", BINGBOT_URL),
                      ("openai", OAI_URL), ("duckduckgo", DDG_URL)):
        try:
            fetched[name] = parse_prefix_json(fetch_text(url))
            if not fetched[name]:
                raise ValueError("empty prefix list")
        except Exception as e:
            log("warn: fetch %s.json failed (%s), builtin fallback" % (name, e))
    data = {"fetched_at": now,
            "googlebot": fetched.get("googlebot") or GOOGLEBOT_FALLBACK,
            "bingbot": fetched.get("bingbot") or BINGBOT_FALLBACK,
            "openai": fetched.get("openai") or OAI_FALLBACK,
            "duckduckgo": fetched.get("duckduckgo") or DDG_FALLBACK}
    try:
        tmp = RANGES_CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, separators=(",", ":"))
        os.replace(tmp, RANGES_CACHE)
    except Exception as e:
        log("warn: ranges cache write failed: %s" % e)
    GOOGLE_NETS = parse_cidrs(",".join(data["googlebot"]))
    BING_NETS = parse_cidrs(",".join(data["bingbot"]))
    OAI_NETS = parse_cidrs(",".join(data["openai"]))
    DDG_NETS = parse_cidrs(",".join(data["duckduckgo"]))
    fallback = [n for n in ("googlebot", "bingbot", "openai", "duckduckgo")
                if n not in fetched]
    log("crawler ranges loaded: googlebot=%d bingbot=%d openai=%d ddg=%d%s"
        % (len(GOOGLE_NETS), len(BING_NETS), len(OAI_NETS), len(DDG_NETS),
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


# 已知规则 description 前缀（apply_* 按前缀定位规则；#20 前缀守护按前缀对账）。
GEO_MARKER = "geo-challenge"          # #19 起由 apply_geo_rule 守护（observe 优先）
UA_MARKER = "block empty/fake"        # 手工维护（v3 演变见 cf-custom-rules.md）
HOTLINK_MARKER = "cdn-hotlink-block"  # apply_hotlink_rule 托管（2026-11-07）


# 规则顺序（first-match-wins：CF 自定义规则只执行第一条命中的）。最狠处置
# 先行——2026-11-17 判例：blacklist 排 geo-challenge 之后时，136.66.124.196
# 封禁后仍持续匹配挑战规则打出 200 次 managed_challenge 事件、零 block
# （blacklist 根本轮不到执行），解掉挑战即穿透封禁名单。UA block 在 geo 之前：
# headless UA 直接 403，不给解挑战的机会。手工/未知规则稳定排尾不吞没。
RULE_ORDER = (RULE_MARKER, DC_MARKER, UA_MARKER, GEO_MARKER, HOTLINK_MARKER)


def _rule_rank(rule):
    desc = str(rule.get("description", ""))
    for i, prefix in enumerate(RULE_ORDER):
        if desc.startswith(prefix):
            return i
    return len(RULE_ORDER)


def sort_rules_canonical(rules):
    """规则顺序重排为 RULE_ORDER（稳定排序，未知规则保持相对顺序排尾）。
    返回 (rules, order_changed)。"""
    out = sorted(rules, key=_rule_rank)
    changed = ([r.get("description") for r in out]
               != [r.get("description") for r in rules])
    return out, changed


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


# ---- CDN 图片防盗链（2026-11-07 用户拍板落地）----
# cdn.noda.co.nz 此前三层（CF 边缘/nginx/应用）零防盗措施：伪造外站 Referer 实测
# 返回完整图片（200 + Access-Control-Allow-Origin *）。防盗链是独立语义（只允许
# 自家页面引用），与地理挑战/UA/黑名单/机房 ASN 均不同族。
# 规则形态演变：落地时 Free 版 5/5 满额，曾按 persist 先例并入 dc 规则；同日用户
# 拍板把两条极少变的 challenge 规则（admin 非 NZ + geo 非 NZ/AU，同 action）合并
# 腾出 1 个空位 → 防盗链升格为独立规则（ref=cdn-hotlink-block，仅 noda zone——
# cdn host 不存在于 shuotong zone，不占其配额）。apply_hotlink_rule 每轮对账：
# 被手改漂移则拉回、被删则重建（自愈，同 dc 规则）。
# 语义（三重豁免，原则①②不误封）：
#   - 空 Referer 放行：og:image 预览（Meta/Telegram/微信卡片抓取）、邮件客户端、
#     RSS、QR 扫码全走这条——带 Referer 的盗链才拦，不带的不拦（攻击者本来
#     就能 referrerpolicy 去Referer 绕过，本规则定位是拦「懒盗链」省带宽）；
#   - cf.client.bot 放行：CF 验证爬虫（Googlebot/Bingbot 抓图不误伤，原则①）；
#   - Referer 含 noda.co.nz（apex+全部子域，contains 域锚）/主流搜索引擎图片
#     转介放行：Google 图片点击转介 Referer=google.*，中文站另保 baidu/sogou。
# 已知松弛（接受）：Referer 是客户端可任意伪造的字段，contains 匹配可被构造
# Referer 绕过——与空 Referer 绕过同性质，不值得为此上签名 URL。
HOTLINK_HOST = "cdn.noda.co.nz"
HOTLINK_REFERER_ALLOW = (   # contains 子串（lower() 后匹配；域锚自带，宁松勿误拦）
    "noda.co.nz",           # 自家 apex+子域（www/nearby/admin/…）
    "google.",              # Google 图片/搜索转介（com/co.nz/…）
    "bing.",
    "baidu.",               # 中文用户主用
    "sogou.",               # 搜狗（本机黑名单脚本的出身项目，中文用户仍用）
    "duckduckgo.com",
    "yahoo.",               # Yahoo Japan 图片重度用户也在内
    "yandex.",
)
HOTLINK_CLAUSE = (
    '(http.host eq "%s" and http.referer ne "" and not cf.client.bot and not (%s))'
    % (HOTLINK_HOST, " or ".join(
        'lower(http.referer) contains "%s"' % s for s in HOTLINK_REFERER_ALLOW)))
HOTLINK_ZONES = ("noda.co.nz",)   # cdn host 只在 noda zone，shuotong 不建（不占配额）

# ---- 死站收口（2026-11-19 攻击判例：挑战盲区入口直接 block，不再 410 到源站）----
# geo-challenge 只盖 admin 非 NZ + apex/www 非 NZ/AU/TW；liuyao/snagme 是已退役
# proxied host（源站 410），实测零挑战覆盖——195.178.110.94 攻击（见 ABUSE_ASNS
# 判例批）正是经此类入口打穿到源站（CF 事件 0 条实锤）。并入 dc 规则 block
# （Free 版 5 条配额占满，复用 hotlink/persist 合并先例）。
# 豁免修正（2026-11-19 misban-watch 实锤，上线 ~1 分钟内告警）：初版「无豁免——
# 验证爬虫也该吃 403」的判据是错的——66.249.72.5/.6 真 Googlebot 上线即被拦，
# 它爬 snagme /wiki/* 三语旧路径正是 GSC 18k 积压衰减机制本体（爬到 410 才弃，
# 源站语义不变），403 会重演 2026-10「Blocked due to access forbidden (403)」
# 索引事故。故死站分支照 abuse 分支豁免集（cf.client.bot + 官方段/站主 IP）放行
# 验证爬虫，非验证扫描器流量照封。教训：retired host 的「无合法流量」不含官方
# 爬虫——衰减期爬虫流量是合法流量。
# nearby.noda.co.nz 是 301 桥（GSC 18k 发现积压自然衰减用，llm-context 定到
# 2026-11 月底退役）——退役当日把 host 追加进本元组即完成收口，勿提前。
DEAD_HOSTS = ("liuyao.noda.co.nz", "snagme.noda.co.nz")


def build_dc_expression(allowed=None, persist_cidrs=None):
    """机房 ASN 常驻封禁规则表达式（纯函数，单测直接打）。2026-10-25 起两分支：

    - 滥用分支（ABUSE_ASNS，block 且**无 UA 豁免**）：这些 ASN 实测/历史只有攻击
      流量，官方爬虫清单 0 命中——伪造 bot 字样也 403（堵 UA 伪造绕过 block 的洞）。
    - 大云分支（CLOUD_ASNS，block 且保留 UA 自报家门豁免）：GEO/SEO 爬虫实证全在
      此（cf.client.bot 不覆盖 AI 爬虫，靠 UA 豁免活——守规矩才敢自报家门）。
    - 死站分支（DEAD_HOSTS，2026-11-19）：已退役 proxied host 整 host block，
      豁免集照 abuse 分支——衰减期官方爬虫流量=合法流量（攻击判例见常量注释）。
    - 各分支共同豁免：cf.client.bot（IP 级验证不可伪造，Googlebot/Bingbot 稳保）
      + EXTRA_CRAWLER_RANGES 三段（2026-11-23 判例：原集只含 IPv4 /19，
      2001:4860:7:80b::f4/fa IPv6 Read Aloud 族在死站分支被 block 复发——
      豁免面必须镜像 geo-challenge 同款三段，与源站 EXTRA_CRAWLER_NETS 同源）
      + 站主 IP + ALLOW_CIDRS。

    persist_cidrs 非空时 OR 进坚持不懈来访者子句（继承 dc action=block）：
    Free 版自定义规则上限 5 条，无第 6 条配额（2026-10-25 实测
    "6 out of 5"），两名单必须共用本规则；子句独立带 cf.client.bot + 站主豁免。
    （CDN 防盗链 2026-11-07 曾因同配额压力并入本规则，同日 challenge 规则合并
    腾位后升格独立规则 HOTLINK_MARKER，不再走这里。）"""
    ip_ex = "ip.src in {%s}" % " ".join(
        list(EXTRA_CRAWLER_RANGES) + sorted(OWNER_IPS)
        + [str(n) for n in (allowed if allowed is not None else allow_nets())])
    abuse = ("(ip.src.asnum in {%s}) and not cf.client.bot and not %s"
             % (" ".join(str(a) for a in ABUSE_ASNS), ip_ex))
    ua = "(%s)" % " or ".join('http.user_agent contains "%s"' % u
                              for u in DC_UA_EXEMPTS)
    cloud = ("(ip.src.asnum in {%s}) and not cf.client.bot and not %s and not %s"
             % (" ".join(str(a) for a in CLOUD_ASNS), ua, ip_ex))
    dc = "(%s) or (%s)" % (abuse, cloud)
    if DEAD_HOSTS:
        # 死站收口第三分支（2026-11-19 判例）：豁免集照 abuse 分支（cf.client.bot
        # + 官方段/站主 IP）——GSC 积压衰减靠官方爬虫爬到 410（misban-watch 实锤
        # 修正，见 DEAD_HOSTS 常量注释），非验证扫描器流量照封。
        # 2026-11-23 二次判例：f0bc802 豁免集只含 IPv4 /19，2001:4860:7:80b::f4/fa
        # （IPv6 Read Aloud 族，geo 豁免同款段）在 snagme /wiki/* 仍被本分支
        # block——豁免面必须镜像 EXTRA_CRAWLER 三段（见 ip_ex），非全量重演一遍
        dc += (' or (http.host in {%s} and not cf.client.bot and not %s)'
               % (" ".join('"%s"' % h for h in DEAD_HOSTS), ip_ex))
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
    desc = "%s auto (%d ASNs + dead-hosts; managed by ip-ban.py)" % (
        DC_MARKER, len(DATACENTER_ASNS))
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


def apply_hotlink_rule(rules):
    """CDN 图片防盗链独立规则（2026-11-07）原位维护，返回 (同一列表, 是否有变化)。

    表达式恒定 HOTLINK_CLAUSE（纯静态，不随封禁名单变化）；每轮对账拉漂移/重建，
    同 dc 规则的自愈语义。仅 HOTLINK_ZONES（noda.co.nz）调用——cdn host 不在
    shuotong zone，不占其 Free 版规则配额。"""
    rule = next((r for r in rules
                 if str(r.get("description", "")).startswith(HOTLINK_MARKER)
                 or r.get("ref") == HOTLINK_MARKER), None)
    if (rule and rule.get("expression") == HOTLINK_CLAUSE
            and rule.get("action") == "block" and rule.get("enabled", True)):
        return rules, False
    created = rule is None
    desc = "%s (Referer anti-hotlink; managed by ip-ban.py)" % HOTLINK_MARKER
    if rule:
        rule["expression"] = HOTLINK_CLAUSE
        rule["action"] = "block"
        rule["description"] = desc
        rule["enabled"] = True
    else:
        rules.append({"action": "block", "action_parameters": {},
                      "expression": HOTLINK_CLAUSE, "description": desc,
                      "enabled": True, "ref": HOTLINK_MARKER})
    log("hotlink-rule: %s (host=%s, %d referer allows)"
        % ("created" if created else "updated", HOTLINK_HOST,
           len(HOTLINK_REFERER_ALLOW)))
    return rules, True


# ---- geo-challenge 规则守护（2026-11-17 #19：手工规则收编自愈，先 observe）----
# geo-challenge 是 noda zone 唯一手工维护规则，已连产两次事故：①11-07 规则
# 顺序缺口（first-match-wins 下排第 1 使 blacklist 失效，b773b3f 重排修复）；
# ②11-17 www 盲区（表达式只 match apex，www 完全无挑战=解挑战免费旁路，当日
# API 补 host in {apex www}）。文档快照防不了漂移——规则被手改/误删/重建后
# www 修复会静默丢失，仿 cdn-hotlink-block 先例收编为代码自愈。
# canonical 表达式逐字符取自 2026-11-17 CF live 现值（只读 GET，非手抄重构）：
#   ssh r4s "cat /etc/noda/ip-ban.env" 取 DOPPLER_SERVICE_TOKEN →
#   GET api.doppler.com .../secret?project=noda&config=prd&name=CF_BAN_API_TOKEN →
#   GET zones?name=noda.co.nz（2ed51678bb82d8def5a5dcae28635c11）→
#   GET zones/{id}/rulesets/phases/http_request_firewall_custom/entrypoint
#   命中规则 id b62507ea2ec243098ea2ce8eaac599e5 / ref geo-admin-challenge。
# 未来改动走代码+测试，不再面板手改。
# Phase 1 observe（默认）：每轮 GET 比对，漂移只记日志+TG 告警（含前后 diff），
#   零写回——零误报跑一周确认 canonical 与真实期望一致后才准转 enforce。
# Phase 2 enforce（GEO_RULE_MODE=enforce）：漂移拉回+删除重建（继承 hotlink
#   自愈语义）。该规则影响面大（非 NZ/AU/TW 全部 web 流量进挑战），默认不启用。
GEO_REF = "geo-admin-challenge"       # 2026-11-07 合并规则沿用 ref（live 同名）
GEO_ACTION = "managed_challenge"
GEO_DESC = ("geo-challenge merged 2026-11-07 (www added 2026-11-17, "
            "Google ASN exempt 2026-11-23, DuckAssistBot exempt 2026-11-23): "
            "admin non-NZ + web non-NZ/AU apex+www")
# 2026-11-23 Storebot geo-crawl 判例扩 Google ASN 豁免：34.155.98.39（Google
# 新 geo-crawl 基建，AS396982 GCP，PTR geo-crawl-*.geo.googlebot.com 正反确认）
# 在 /cdn-cgi/rum 被 managed_challenge——cf.client.bot 验不出 Storebot，静态
# 三段追不上 Google 段扩张（googlebot.json 已收录数十个 34.x /28）。按 ASN
# 豁免一劳永逸：15169=Google proper（legacy crawl/209.85 Mediapartners 段），
# 396982=GCP（geo-crawl 现役及未来扩张）。层级保护不破：dc 大云分支本就含
# 396982 且带自报 UA 豁免，非 bot 的 GCP 租户流量仍被 dc 分支先拦
# （first-match 顺序 dc→geo），geo 豁免只是不再重复挑战同一批 IP。
# 2026-11-23 DuckAssistBot 放行（用户拍板，web 分支 UA 豁免）：DuckAssistBot=
# Duck.ai 用户引用的服务端执行器（官方 duckduckbot.json 段收录其 486 个 Azure
# 出口，抓 sw.js 等 PWA 生命周期端点），不做训练采集——与 UA 规则豁免
# ChatGPT-User 等五家「GEO 引用漏斗」同构（GA 实证 chatgpt.com/ai-assistant
# 互动率 73% 全站最高，AI 引用渠道质量最优）。伪造面≈0：managed_challenge 本是
# 软面，伪造 UA 仅获真人同等浏览能力，洪水/枚举有源站四闸+限速兜底。admin 分支
# 不豁（后台挑战正确）；搜索爬虫 DuckDuckBot 是 CF verified bot 本就放行。
GEO_CLAUSE = (
    '(http.host eq "admin.noda.co.nz" and ip.geoip.country ne "NZ") '
    'or ((not cf.client.bot) and (ip.geoip.asnum ne 15169 '
    'and ip.geoip.asnum ne 396982) and '
    '(not ip.src in {66.249.64.0/19 '
    '209.85.128.0/17 2001:4860:7::/48}) and '
    '(http.host in {"noda.co.nz" "www.noda.co.nz"}) and '
    '(not ip.geoip.country in {"NZ" "AU" "TW"}) and '
    'not http.user_agent contains "DuckAssistBot")')
GEO_ZONES = ("noda.co.nz",)   # shuotong.wang zone 无此规则，不受影响（复用
                              # HOTLINK_ZONES 模式：main 循环只对成员 zone 调用）


def geo_rule_mode():
    """GEO_RULE_MODE（os.environ 优先，其次 ENV_FILE，同 ALLOW_CIDRS 口径）：
    observe（默认）/ enforce。未知值一律回落 observe——影响面大，宁守勿攻。"""
    raw = (os.environ.get("GEO_RULE_MODE")
           or env_settings().get("GEO_RULE_MODE") or "").strip().lower()
    return "enforce" if raw == "enforce" else "observe"


def _geo_diff_note(live, canonical, ctx=40):
    """首个差异定位（±ctx 字符上下文）——漂移往往只差一小段（如 www host 被
    删），全文对照难一眼定位"""
    i = 0
    while i < min(len(live), len(canonical)) and live[i] == canonical[i]:
        i += 1
    return ("首个差异@%d: 线上 …%s… / canonical …%s…"
            % (i, live[max(0, i - ctx):i + ctx],
               canonical[max(0, i - ctx):i + ctx]))


def apply_geo_rule(rules, mode, zone):
    """geo-challenge 规则守护（#19）。返回 (同一列表, 是否有变化, TG 告警列表,
    漂移指纹)。健康判定只比 expression/action/enabled——description 不比
    （desc 由 live 起步，比了会在首轮 enforce 产生无谓写；前缀漂移归 #20 守护），
    规则按 description 前缀 GEO_MARKER 或 ref GEO_REF 定位（desc 前缀被手改
    丢了 ref 仍能收养）。

    observe：漂移/缺失只告警零写回；enforce：拉回/重建（DRY_RUN 下按 observe
    处理——put_rules 被跳过，改内存对象是假自愈）。
    零写承诺的边界：仅覆盖 expression/action/enabled 漂移与整条缺失。description
    前缀漂移不在承诺内——该规则会归「未知」落入既有 sort_rules_canonical 顺序
    收敛（排尾重排触发 PUT），其检测告警归 #20 前缀守护。"""
    rule = next((r for r in rules
                 if str(r.get("description", "")).startswith(GEO_MARKER)
                 or r.get("ref") == GEO_REF), None)
    if (rule and rule.get("expression") == GEO_CLAUSE
            and rule.get("action") == GEO_ACTION
            and rule.get("enabled", True)):
        return rules, False, [], ""
    enforce = mode == "enforce" and not DRY_RUN
    label = ("enforce" if enforce else
             "enforce+DRY_RUN" if mode == "enforce" else "observe")
    if rule is None:
        fp = "missing"
        if enforce:
            rules.append({"action": GEO_ACTION, "action_parameters": {},
                          "expression": GEO_CLAUSE, "description": GEO_DESC,
                          "enabled": True, "ref": GEO_REF})
            log("geo-rule[%s]: missing → recreated (enforce)" % zone)
            return rules, True, ["ip-ban: geo-challenge 规则缺失[%s]，%s 已按 "
                                 "canonical 重建:\n%s"
                                 % (zone, label, GEO_CLAUSE)], fp
        log("geo-rule[%s]: missing（%s 只告警零回写）" % (zone, label))
        return rules, False, ["ip-ban: geo-challenge 规则缺失[%s]（%s：零回写"
                             "仅告警）——canonical 期望:\n%s"
                             % (zone, label, GEO_CLAUSE)], fp
    live = str(rule.get("expression", ""))
    fp = "drift:%r:%s:%s" % (live, rule.get("action"), rule.get("enabled"))
    if enforce:
        rule["expression"] = GEO_CLAUSE
        rule["action"] = GEO_ACTION
        rule["description"] = GEO_DESC
        rule["enabled"] = True
        log("geo-rule[%s]: drifted → pulled back (enforce)" % zone)
        return rules, True, ["ip-ban: geo-challenge 漂移[%s]，%s 已拉回 canonical。"
                             "漂移前(线上):\n%s\n拉回后(canonical):\n%s\n%s"
                             % (zone, label, live, GEO_CLAUSE,
                                _geo_diff_note(live, GEO_CLAUSE))], fp
    log("geo-rule[%s]: drift detected（%s 零回写）" % (zone, label))
    return rules, False, ["ip-ban: geo-challenge 漂移[%s]（%s：零回写仅告警）。"
                          "漂移前(线上):\n%s\n漂移后(canonical):\n%s\n%s"
                          % (zone, label, live, GEO_CLAUSE,
                             _geo_diff_note(live, GEO_CLAUSE))], fp


def step_geo_guard(guard, zone, drift_fp, alerts, log):
    """#19 observe 告警去重（cron */5 实跑，漂移持续会每轮刷屏 TG）：
    同漂移指纹只发一次（记 state geo_guard[zone]），变化才再发；解除只记日志。
    返回 (更新后 guard, 待发送 alerts)。"""
    if drift_fp:
        if guard.get(zone) == drift_fp:
            log("geo-guard[%s]: 漂移持续（已告警，本轮静默）" % zone)
            return guard, []
        guard[zone] = drift_fp
        return guard, alerts
    if guard.pop(zone, None) is not None:
        log("geo-guard[%s]: 漂移解除，live 已与 canonical 一致" % zone)
    return guard, []


# ---- 规则清单前缀守护（2026-11-17 #20：防 description 前缀漂移静默降级）----
# ip-ban.py 按 description 前缀定位规则（apply_* 各认自家前缀 + RULE_ORDER
# 排序）。前缀漂移（Dashboard 手改 description）后果不对称且部分静默：
#   - ip-range-blacklist / datacenter-asn-block：apply_* 找不到 → 新建第二条
#     → Free 版 5 条上限立刻 6/5 报错，PUT 每轮失败（高）；
#   - block empty/fake（UA-block，手工规则）：sort_rules_canonical 归「未知」
#     排尾 → 落到 geo-challenge 之后，headless UA 从 403 降级为挑战（中，
#     静默变松）；
#   - geo-challenge / cdn-hotlink-block：同上排尾（hotlink/#19 有自愈拉回，低）。
# 文档防不了手滑——每轮 zone 对账时校验清单形态，异常 TG 告警（带 zone +
# 前缀 + 现场全部规则 description 清单，可直接定位手改了什么）。


def expected_rule_prefixes(zone):
    """分 zone 期望集（单一真值源 RULE_ORDER）：blacklist/dc/UA 两 zone 都应在
    （ZONES 全员）；geo/hotlink 仅其托管 zone（GEO_ZONES/HOTLINK_ZONES）。"""
    zone_scoped = {GEO_MARKER: GEO_ZONES, HOTLINK_MARKER: HOTLINK_ZONES}
    return tuple(p for p in RULE_ORDER
                 if p not in zone_scoped or zone in zone_scoped[p])


def check_rule_inventory(zone, rules):
    """规则清单形态校验（纯函数）：返回 (缺失前缀列表, 重复 [(前缀, [全部命中
    description])])。同前缀多条=漂移产物（apply_* 只改第一条，第二条是手建
    残渣）。无 description 的规则按空串处理（不误匹配任何前缀）。"""
    descs = [str(r.get("description", "")) for r in rules]
    missing, dups = [], []
    for prefix in expected_rule_prefixes(zone):
        hits = [d for d in descs if d.startswith(prefix)]
        if not hits:
            missing.append(prefix)
        elif len(hits) > 1:
            dups.append((prefix, hits))
    return missing, dups


def inventory_fingerprint(missing, dups):
    """漂移指纹（state 去重键）：缺失前缀 + 重复前缀及其全部现场 description
    ——漂移形态变（如重复第二条又改名）指纹即变，变化才再报。"""
    return ";".join(["missing:%s" % p for p in missing]
                    + ["dup:%s:%s" % (p, "|".join(ds)) for p, ds in dups])


def step_rule_guard(guard, zone, rules, log):
    """#20 前缀守护（每轮 zone 对账时调用，输入为 GET 到的 live 清单）。

    告警去重：state rule_guard[zone] 记已告警指纹，同一漂移不每 5 分钟重复
    轰炸，变化才再报；解除后报恢复（带此前指纹可定位）。返回 (更新后 guard,
    本轮 TG 告警列表)。"""
    missing, dups = check_rule_inventory(zone, rules)
    fp = inventory_fingerprint(missing, dups)
    prev = guard.get(zone)
    alerts = []
    if fp:
        if fp != prev:
            listing = "\n".join(
                "%d. %s" % (i + 1, str(r.get("description", "")) or "(无 description)")
                for i, r in enumerate(rules))
            parts = ["ip-ban: 规则清单漂移[%s]（前缀守护）" % zone]
            if missing:
                parts.append("缺失前缀: %s" % ", ".join(missing))
            for p, ds in dups:
                parts.append("重复前缀 %s ×%d: %s" % (p, len(ds), " | ".join(ds)))
            parts.append("现场规则清单:\n%s" % listing)
            alerts.append("\n".join(parts))
            guard[zone] = fp
            log("rule-guard[%s]: 漂移告警（%s）" % (zone, fp))
        else:
            log("rule-guard[%s]: 漂移持续（已告警，本轮静默）" % zone)
    elif prev:
        alerts.append("ip-ban: 规则清单恢复[%s]：此前漂移（%s）已解除，"
                      "期望前缀全部在位且无重复" % (zone, prev))
        log("rule-guard[%s]: 恢复" % zone)
        guard.pop(zone, None)
    return guard, alerts


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
    """返回解析后的访问事件列表 [(ip, path, ua, status, referer)]，解析失败的行丢弃。
    referer 2026-11-17（#18）起保留——tripwire 命中取证需要（此前在解析层丢弃）。"""
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
                               m.group(3), m.group(4)))
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
        seen = sum(1 for ev in events if in_ranges(ev[0], [cidr]))
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


def trip_bans(events):
    """tripwire 命中 → 封禁提案（纯函数，单测直接打）。

    800x600 headless 族（GA4 判例 2026-10-24：direct 深链 sitemap 事件页、
    单页零互动、城市 not set）真实受众分辨率零撞车——nearby 页面内联 JS 对该
    分辨率 sendBeacon('/__trip') 自报，源站日志见 exact /__trip 即封出口
    （v4 /32、v6 /64 复用 persist_key：机房 /24 有无辜邻居，/64 即订户级）。
    族出口逐会话轮换，同 IP 凑不出第二次命中 → 单发即封 30 天；速率闸
    （60/5min）与 persist 网（14 天 4 到访日）都够不上的低慢速模式由此补位，
    且出口无关（不依赖 ABUSE_ASNS 名单）。分辨率清单漂移由 GA4 哨兵人工判读
    后与读数层 BOT_RESOLUTIONS 同步扩表，不自动扩。
    #18 起 UA/referer 不再在判定层丢弃：取证交给 trip_ua_map /
    record_trip_samples（按索引取值，老 4 元组事件兼容）。
    2026-11-22 HubSpot 判例：UA 自报家门的守规矩爬虫（不在任何官方 IP 清单）
    撞 /__trip 不再提案封禁——trip_exempt_ua 豁免，伪装 bot 字样不豁免。"""
    out = {}
    for ev in events:
        if ev[1] != TRIP_PATH:
            continue
        if trip_exempt_ua(ev[2]):
            log("trip-exempt %s: selfid crawler UA %s"
                % (ev[0], ev[2][:TRIP_UA_MAX]))
            continue
        out[persist_key(ev[0])] = (TRIP_REASON, TRIP_TTL)
    return out


# tripwire 豁免的 UA 反制名单：与 classify 的 fake-bot 反制同语义（真官方段
# 在 IP 层已放行，段内流量根本不会走到 UA 判定；UA 报 googlebot/bingbot/
# oai-searchbot 而 IP 不在官方段=伪装，2026-11-17 复审修正先例）。
TRIP_FAKE_UA = ("googlebot", "bingbot", "oai-searchbot")


def trip_exempt_ua(ua):
    """/__trip 命中请求是否自报家门的守规矩爬虫（2026-11-22 HubSpot 判例）。

    官方 IP 清单（googlebot/bingbot/openai/ahrefs json + Google 兜底段）只
    覆盖搜索巨头与 OpenAI/Ahrefs；HubSpot Crawler、各平台链接预览等合法
    渲染器出口不在任何清单里，撞 800×600 哨兵按原逻辑被 30 天封禁——违反
    原则①「自报家门=守规矩才敢自报，欢迎」。豁免规则：UA 含 SELFID_MARKERS
    即豁免；含 TRIP_FAKE_UA（伪装官方 bot）不豁免照封。伪装自报以逃避
    tripwire=自降为「自报家门的爬虫」流量类（public 页设计接受该残余，
    速率闸/攻击闸/persist 网仍在）。"""
    u = (ua or "").lower()
    if any(m in u for m in TRIP_FAKE_UA):
        return False
    return any(m in u for m in SELFID_MARKERS)


def sweep_exempt_bans(bans, allowed=None):
    """清退黑名单中与新豁免面相交的条目（2026-11-22 Ahrefs 判例的根治面）。

    判例：2026-11-17 AHREFS_RANGES 修复只堵了新提案（SAFETY 闸），修复日前
    已入库的 6 条 202.8.40-43.x 只能等 7 天 TTL 自然过期——其间 Ahrefs 渲染
    器持续被边缘 blacklist block（misban-watch 11-20 07:07 实锤 /sw.js）。
    本闸每轮把存量黑名单与官方爬虫段/ALLOW_CIDRS/站主 IP 对账，相交即清退
    并记日志（下次官方清单更新新增段时同样自动生效）。返回清退列表（并入
    unbanned → 触发 need_put 同步 CF + TG 通知）。"""
    allowed = allow_nets() if allowed is None else allowed
    swept = []
    for cidr in list(bans):
        b = bans[cidr]
        net = ipaddress.ip_network(cidr)
        if any(ipaddress.ip_address(o) in net for o in OWNER_IPS):
            name = "owner-ip"
        else:
            hit = next((n for nets in (GOOGLE_NETS, BING_NETS, OAI_NETS,
                                       AHREFS_NETS, DDG_NETS,
                                       EXTRA_CRAWLER_NETS, allowed)
                        for n in nets if net.overlaps(n)), None)
            if hit is None:
                continue
            name = str(hit)
        log("sweep: %s overlaps exempt %s, unbanned early"
            % (cidr, name))
        swept.append((cidr, b.get("ttl", BAN_TTL)))
        del bans[cidr]
    return swept


def trip_ua_map(events):
    """cidr → 本轮 /__trip 最后见到的 UA（截断 TRIP_UA_MAX）。
    #18 取证：candidate 日志行带 UA 样本——11-08 AWS 54.174.58.237/241 疑似
    Ahrefs 段外渲染器出口，但源站日志只留 8 小时 UA 不可考，封禁时取证同步留痕。"""
    out = {}
    for ev in events:
        if ev[1] == TRIP_PATH:
            out[persist_key(ev[0])] = ev[2][:TRIP_UA_MAX]
    return out


def record_trip_samples(samples, events, now):
    """#18 state 命中样本环形缓冲（评审修正：跨轮按 IP 去重 move-to-end）。

    语义=每 IP 恒占 1 格、最近命中在尾：本轮 /__trip 命中更新该 IP 的样本
    （ua/referer/ts 刷新）并移到缓冲末尾，未命中 IP 原位保留；写入时容量裁剪
    到 TRIP_SAMPLES_MAX（丢最久未命中）。字段 ip/ua/referer/ts，UA/referer 截断
    TRIP_UA_MAX。返回新列表（不改动入参）。
    跨轮去重的动机：SAFETY 豁免段（如 AHREFS_NETS /23s，因反复撞 /__trip 被
    豁免、origin 持续可见）每 5 分钟命中一条，append 式缓冲 4-8 小时即被单一
    IP 挤满容量、逐出真被封候选的取证样本——恰是 #18 要保的证据面。
    老格式 4 元组事件（无 referer）按 "-" 补位兼容。"""
    buf = {s.get("ip"): dict(s) for s in samples}   # py3.7+ dict 保持插入序
    for ev in events:
        if ev[1] != TRIP_PATH:
            continue
        ip = ev[0]
        buf.pop(ip, None)                            # 命中即更新并移到末尾
        buf[ip] = {"ip": ip, "ua": ev[2][:TRIP_UA_MAX],
                   "referer": (ev[4] if len(ev) > 4 else "-")[:TRIP_UA_MAX],
                   "ts": now}
    out = list(buf.values())
    if len(out) > TRIP_SAMPLES_MAX:          # 环形裁剪：丢最旧=最久未命中（含防御性裁老 state 超量）
        del out[:len(out) - TRIP_SAMPLES_MAX]
    return out


def apply_trip_proposals(events, bans, proposals):
    """tripwire 提案并入 proposals（main 的原内联逻辑，#18 起日志带 UA 样本）。
    返回本轮新增提案 [(cidr, reason, ttl)]；已在 proposals/bans 的 cidr 跳过
    （既有判例）。SAFETY 复核由调用方统一执行。"""
    new = []
    uas = trip_ua_map(events)
    for cidr, (reason, ttl) in trip_bans(events).items():
        if cidr not in proposals and cidr not in bans:
            proposals[cidr] = (reason, ttl)
            new.append((cidr, reason, ttl))
            log("candidate %s: %s（tripwire 自报，SAFETY 复核后生效）ua=%s"
                % (cidr, reason, uas.get(cidr, "-")))
    return new


_crawler_ip_cache = {}


def is_crawler_ip(ip):
    """请求 IP 是否命中官方爬虫网段（googlebot/bingbot/openai/ahrefs/duckduckgo
    全量 + Google /19 兜底，IP 优先不看 UA）"""
    hit = _crawler_ip_cache.get(ip)
    if hit is None:
        hit = (in_nets(ip, GOOGLE_NETS) or in_nets(ip, BING_NETS)
               or in_nets(ip, OAI_NETS) or in_nets(ip, AHREFS_NETS)
               or in_nets(ip, DDG_NETS) or in_nets(ip, EXTRA_CRAWLER_NETS))
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
    if "googlebot" in u or "bingbot" in u or "oai-searchbot" in u:
        return "bot"          # 假 Googlebot/Bingbot/OAI-SearchBot（真段已在
                              # 上面 skip）——不加会被 SELFID "bot" 误放行为
                              # skip（2026-11-17 复审修正，fake-googlebot
                              # 2026-10-18 先例同款）。注意 ahrefsbot 有意
                              # 不列：Ahrefs 官方段只覆盖 APNIC /23s（其
                              # OVH/AWS 真实出口在段外），列了会把真爬虫计
                              # bot 开新误封通道；其真值源不完整是已知残留
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
                           ("openai", OAI_NETS), ("ahrefs", AHREFS_NETS),
                           ("duckduckgo", DDG_NETS),
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
        ts = s.get("trip_samples") or []
        print("tripwire samples: %d (cap %d)" % (len(ts), TRIP_SAMPLES_MAX))
        for t in ts[-3:]:                    # #18 取证样本（最近 3 条）
            print("  %-40s %s ua=%r ref=%r"
                  % (t.get("ip"),
                     time.strftime("%F %T", time.localtime(t.get("ts", 0))),
                     t.get("ua", ""), t.get("referer", "")))
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
    for ip, path, ua, status, _ref in events:
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

    # ---- 爬虫指纹 tripwire（800x600 headless 族，出口无关，单发即封）----
    # 站主/官方爬虫段兜底交给 apply_safety（提案含站主 IP 或撞白名单段即拒）。
    # #18 取证增强：candidate 日志带 UA 样本；命中样本入 state 环形缓冲
    # （ip/ua/referer/时间——源站日志只留 8 小时，state 是唯一长期取证面）。
    apply_trip_proposals(events, bans, proposals)
    state["trip_samples"] = record_trip_samples(
        state.get("trip_samples") or [], events, now)

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

    # ---- 豁免面对账清退（2026-11-22 Ahrefs 判例根治：修复日存量条目不再
    # 等 TTL 自然过期，立即清退并触发 CF 同步）----
    unbanned = unbanned + sweep_exempt_bans(bans, allowed)

    # ---- 封禁后源站验证（观察窗内被封 IP 仍现于源站=CF 执行缺口，TG 告警）----
    verify = state.get("verify") or {}
    verify, verify_alerts = step_verification(verify, events, new_bans, log)
    state["verify"] = verify

    # ---- 同步 CF 规则（多 zone：黑名单 + 机房 ASN 常驻规则同步到 ZONES 全部站点）----
    # 每轮都 GET 对账：除封禁变化外，还要校验 dc 常驻规则未被 Dashboard 手改漂移。
    unsynced = sorted(set(state.get("unsynced") or []))
    dc_expr = build_dc_expression(allowed, persist_cidrs=persist_hits)
    geo_guard = state.get("geo_guard") or {}   # #19 observe 告警去重指纹
    rule_guard = state.get("rule_guard") or {}  # #20 前缀守护告警去重指纹
    guard_alerts = []                         # #19/#20 守护告警（对账发现即收集）
    geo_mode = geo_rule_mode()
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
                rules = get_rules(cf, zid)
                # #20 前缀守护：对账 live 清单（apply_* 改写前的现场形态）——
                # 缺失/重复前缀即 TG 告警（同漂移指纹去重，解除报恢复）
                rule_guard, r_alerts = step_rule_guard(rule_guard, zname,
                                                       rules, log)
                guard_alerts.extend(r_alerts)
                rules = apply_blacklist(rules, bans)
                rules, dc_changed = apply_dc_rule(rules, dc_expr)
                hl_changed = False
                if zname in HOTLINK_ZONES:
                    rules, hl_changed = apply_hotlink_rule(rules)
                # #19 geo-challenge 守护（仅 GEO_ZONES；observe 默认零写回——
                # 零写承诺限 expression/action/enabled 漂移与整条缺失，desc
                # 前缀漂移仍会触发下方 sort_rules_canonical 顺序收敛 PUT（#20 域）；
                # 告警去重防每 5 分钟刷屏）
                geo_changed = False
                if zname in GEO_ZONES:
                    rules, geo_changed, g_alerts, geo_fp = apply_geo_rule(
                        rules, geo_mode, zname)
                    geo_guard, g_alerts = step_geo_guard(
                        geo_guard, zname, geo_fp, g_alerts, log)
                    guard_alerts.extend(g_alerts)
                rules, order_changed = sort_rules_canonical(rules)
                if order_changed:
                    log("rule order canonicalized: %s"
                        % " → ".join(str(r.get("description", ""))[:24]
                                     for r in rules))
                if need_put or dc_changed or hl_changed or geo_changed \
                        or order_changed:
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
    state["geo_guard"] = geo_guard
    state["rule_guard"] = rule_guard
    if not unsynced:
        state["persist_listed"] = persist_hits   # 全 zone 同步成功才记账，失败下轮重试

    # ---- 通知 ----
    for msg in guard_alerts:                    # #19/#20 守护告警（自带 ip-ban: 前缀）
        tg(msg)
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
