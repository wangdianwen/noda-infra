#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ip-audit.py — 源站日志判据式 bot 判定器（2026-10-28 用户需求：把人工判据固化成脚本）

三个处置线（用户定的口径：自动处理但只有 100% 确认非真人才动手）：
- 白名单永不碰：官方爬虫段 IP 真值（google/bing/extra，UA 不看）、点名欢迎 UA、
  站主 IP、过真人铁证的会话（消费 ISP + JS 执行保真）。
- 100% 线自动封 7 天 + TG 通知（单信号永不触发，必须无真人解释的组合）：
  ① 非浏览器客户端 UA（curl/python/Go-http/Java/Headless 系，含空 UA）且非消费
    ISP 段——真人浏览不会发这些客户端；住宅段里的 curl 开发者不碰
  ② 显式攻击工具 UA（sqlmap/nikto/zgrab 系）——不限 ASN
  ③ 假浏览器（Chrome/Firefox<100 既有判例）零 JS 资产 + ≥8 个 404/410 探测且
    机房段（10-28 SoftLayer Firefox/41 判例）
  ④ 蜜罐命中（HONEY_PATHS 预留，部署后自动生效）
  粒度只封单 IP（不做 /24 扩大）；命中站主 IP / 官方段的提案自动否决。
- 疑似线分级处置（2026-10-31 用户底线：正常爬虫和真人永不自动封）：
  ① 新线自动封 7 天 = 机房段 ASN + 非自报身份 + 冒充浏览器/无爬虫礼仪：
     reality-mismatch（停更+行为硬信号）∧机房、mass-scraper∧机房∧非自报、
     odd-client-dc（monitor 类 UA 除外→TG）、任意 tier 惯犯 seen≥20∧机房∧非自报。
     联通/VNPT 等消费与模糊 ISP 一票否决（10-18 WARP 误封判例形态在此）；
     自报身份爬虫永不自动封（可能是正常新爬虫）。
  ② 静默归档 = 一次性自报小爬虫 unknown-bot（seen≤2 不封不发，留档供舰队判定）；
     自报爬虫舰队（同族新 IP≥3）只发一条 TG，状态仍静默。
  ③ TG 待裁决 = 消费/模糊 ISP 疑似、stale-browser 弱信号（VN/RO 家宽老电脑判例）、
     自报的重爬虫——ip-audit.py ban <sid> / dismiss <sid> 不变。
  影子期：IP_AUDIT_SHADOW=1 时新线决策只记 state.shadow_banned+TG（🧪）不动 CF；
  切实后首个非影子 run 自动转正（转正前重过 owner/官方段否决）。
  s1 拟真自动化 = UA 停更(主版本落后≥12) 且 (HEAD≥3 / 单页爆发≥40req≤120s /
     短链队列复用) 占一——RCN 10-28 判例（Chrome/125+HEAD 突发+65req/60s）
  s2 一次性校验队 = 单页≤3req 零 JS 机房段，同 ASN 同形状 ≥3 IP——Baxet 10-28 判例
  s3 自报 bot 但不在欢迎名单（10-28 KeenableBot/Reflectionbot 判例）
  s4 重爬虫 = ≥100req 且 JS 资产占比<10% 且零 graphql/PWA
- 全拦静默（2026-10-29 用户口径：机器人没拉到页面就别发 TG）：会话 0 次成功
  取页（无 2xx/3xx）且多数响应是本方拦截态（nginx 限速 429 / botblock 403 /
  origin-gate 444）→ 判 blocked，不动手、不进疑似、不发通知——拦它的防线继续
  拦；404/410 是应用真实应答（探测证据），不算拦截态。

机制：独立 CF 自定义规则（ref=ip-audit-tempban）只装本脚本临时 IP，GET→原位改
自己那条→PUT 整表，不碰 ip-ban.py 的 ASN/黑名单规则；7 天到期自动解封（空则
disable 休眠，同 apply_blacklist 判例）；写失败记 state.unsynced 下轮重试。
cron 每小时 :17（错开 ip-ban */5 与 misban-watch */10 的边界，降低同 ruleset
PUT 竞争）。GA 对账不进自动回路（GA 映射不到 IP，人工周对账）。
复用 ip-ban.py：tg/LINE_RE/client_ip_from_xff/官方段/SELFID/OBVIOUS_BOT_UA/
get_rules/put_rules/load_cf_token/http_json/DATACENTER_ASNS/OWNER_IPS。
ASN 真值：whois.cymru.com 批量（端口 43），state.asn_cache 永久缓存。
state：ops-logs/ip-audit.state.json（checkpoint/黑名单/疑似档案/短链队列/舰队图）。
"""

import hashlib
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
IPB_PATH = os.path.join(SCRIPT_DIR, "ip-ban.py")
STATE_FILE = "/opt/noda/noda-infra/docker/volumes/ops-logs/ip-audit.state.json"

RULE_REF = "ip-audit-tempban"          # CF 规则 ref/描述前缀（本脚本独占）
BAN_TTL = 7 * 86400                    # 用户定：黑名单 7 天
TEMP_BAN_MAX = 40                      # CF in-set 容量上限（40×~40B 远小于表达式限）
FIRST_RUN_WINDOW = 3600                # 首跑/状态缺失回看 1 小时
CRON_MIN = 17
SILENT_MAX_SEEN = 2                    # 静默线：unknown-bot seen≤2 不封不发
REPEAT_BAN_SEEN = 20                   # 惯犯线：机房段+非自报 seen≥20 自动封
# 探活/拨测服务 UA（可能是站主自己配的监控，不自动封，进 TG 裁决/欢迎名单）
MONITOR_UA = ("uptimerobot", "pingdom", "statuscake", "betteruptime",
              "healthcheck", "cron-job", "site24x7", "freshping", "uptime")
# 自报判定补充（10-31 判例 74.125.210.x UA=Google 无 bot 字样）：裸大厂
# fetcher 也算自报——自报爬虫永不自动封，只进静默/裁决线
SELFID_EXTRA = ("google",)

# 影子期开关（crontab 设 IP_AUDIT_SHADOW=1）：新线自动封只记决策不动 CF
SHADOW = os.environ.get("IP_AUDIT_SHADOW") == "1"

ASSET_EXT = (".js", ".css", ".woff2", ".woff", ".png", ".jpg", ".jpeg",
             ".svg", ".webp", ".ico", ".map", ".avif")
ITEM_RE = re.compile(r"^/(?:[a-z]{2}(?:-TW)?/)?item/[0-9a-f-]{20,}")
QUEUE_TTL = 48 * 3600                  # 短链队列复用回看窗
FLEET_TTL = 7 * 86400
PROBE_MIN = 8                          # 100%③：404/410 探测下限
BURST_REQS = 40                        # s1：单页爆发请求数
BURST_SECS = 120
HEAD_MIN = 3                           # s1：HEAD 突发下限
FLEET_MIN_IPS = 3                      # s2：同形状 IP 数下限
SCRAPER_MIN_REQS = 100                 # s4：重爬虫请求数下限
STALE_DELTA = 12                       # s1：浏览器主版本落后≥12 视为停更
CUR_CHROME = 141                       # 2026-10 现值，每年校准
CUR_FIREFOX = 145
CUR_EDGE = 141
CUR_SAFARI = 27                        # Version/ 主版本

# 点名欢迎名单（具体串，不用泛化 bot/spider——新面孔自报 bot 要进疑似线，
# 10-28 KeenableBot/Reflectionbot 留用户裁定的口径）
WELCOME_UA = (
    "googlebot", "bingbot", "applebot", "duckduckbot", "amazonbot",
    "facebookexternalhit", "meta-externalagent", "whatsapp", "telegrambot",
    "chatgpt-user", "gptbot", "oai-searchbot", "claude-user", "claude-web",
    "claudebot", "perplexitybot", "perplexity-user", "mistralai-user",
    "cohere-ai",
    "exasearchbot", "google-inspectiontool", "adsbot", "mediapartners-google",
    "apis-google", "feedfetcher", "google-read-aloud", "googleother",
    "google-safety", "twitterbot", "slackbot", "discordbot", "linkedinbot",
    "pinterestbot", "yandexbot", "petalbot", "semrushbot", "ahrefsbot",
    "privacy preserving prefetch proxy", "skypeuripreview", "vkshare",
)
ATTACK_RE = re.compile(
    r"sqlmap|nikto|zgrab|masscan|nmap|dirbuster|gobuster|acunetix|nessus"
    r"|openvas|w3af|havij|wfuzz|whatweb", re.I)
# 蜜罐（预留：往 nginx 加 location 后把陷阱路径填进来即自动生效）
HONEY_PATHS = ()

# 消费 ISP（ASN 真值 + 名称启发式；命中=真人可能的网络，100% 线全部回避）
CONSUMER_ASNS = {
    9790,   # 2degrees
    4771,   # Spark
    9500,   # One NZ
    55850,  # Mercury
}
CONSUMER_NAME_HINTS = ("broadband", "fibre", "fiber", "telecom", "cable",
                       "wireless", "communications")
CONSUMER_NAME_ANTI = ("cloud", "host", "data", "server", "colo", "amazon",
                      "google", "microsoft", "oracle", "alibaba", "tencent",
                      "digitalocean", "linode", "ovh", "hetzner", "leaseweb",
                      "scaleway", "baxet", "zenlayer", "cdn", "proxy")
# 机房/托管判定：ip-ban 的 DATACENTER_ASNS 真值 + 名称启发式（10-28 判例：
# Baxet/SoftLayer 不在 ip-ban ASN 名单里，纯集合判定会漏）
HOSTING_NAME_HINTS = ("cloud", "host", "data center", "datacenter", "server",
                      "colo", "cdn", "amazon", "google", "microsoft", "oracle",
                      "digitalocean", "linode", "ovh", "hetzner", "leaseweb",
                      "scaleway", "baxet", "zenlayer", "softlayer", "proxy",
                      "vps", "networks")


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def load_ipb():
    spec = importlib.util.spec_from_file_location("ipb_shared_audit", IPB_PATH)
    m = importlib.util.module_from_spec(spec)
    sys.modules["ipb_shared_audit"] = m
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------- 日志解析

def parse_lines(ipb, text):
    """实际解析入口（LINE_RE 取自 ip-ban）：group 1=method 2=path 3=status
    4=referer 5=UA 6=XFF。"""
    TS = re.compile(r"\[(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-]\d{4})\]")
    MON = {m: i for i, m in enumerate(
        "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
    import calendar
    out = []
    for line in text.splitlines():
        m = ipb.LINE_RE.match(line)
        if not m:
            continue
        ip = ipb.client_ip_from_xff(m.group(6))
        if not ip:
            continue
        t = TS.search(line)
        if t:
            d, mon, y, hh, mm, ss, tz = t.groups()
            off = (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60) * (1 if tz[0] == "+" else -1)
            epoch = calendar.timegm((int(y), MON[mon], int(d), int(hh), int(mm),
                                     int(ss), 0, 0, 0)) - off
        else:
            epoch = 0
        out.append((epoch, ip, m.group(1), m.group(2).split("?", 1)[0],
                    m.group(3), m.group(5), m.group(4)))
    return out


def aggregate(events):
    """事件 → {ip: session}。session 记行为指纹：资产/JS/RSC/ graphql/PWA/HEAD/
    探测 404/时序。paths 只存非资产路径（证据用），uas/refs 有界。"""
    sess = {}

    def blank():
        return {"reqs": 0, "heads": 0, "posts": 0, "js_assets": 0, "images": 0,
                "graphql": 0, "rsc": 0, "pwa": 0, "probe404": 0,
                "ok200": 0, "blocked": 0,
                "uas": [], "refs": [], "paths": [], "entry": None,
                "first": None, "last": None}

    for epoch, ip, method, path, status, ua, ref in events:
        s = sess.setdefault(ip, blank())
        s["reqs"] += 1
        if method == "HEAD":
            s["heads"] += 1
        if method == "POST":
            s["posts"] += 1
        if epoch:
            s["first"] = epoch if s["first"] is None else min(s["first"], epoch)
            s["last"] = epoch if s["last"] is None else max(s["last"], epoch)
        if status in ("404", "410"):
            s["probe404"] += 1
        if status[:1] in ("2", "3"):        # 拿到过内容（页面/跳转）＝成功取页
            s["ok200"] += 1
        if status in BLOCK_STATUS:          # 被本方防线拦下（没拿到东西）
            s["blocked"] += 1
        if path == "/graphql":
            s["graphql"] += 1
        elif "__next" in path:
            s["rsc"] += 1
        elif path.endswith("sw.js") or "manifest" in path or "offline" in path:
            s["pwa"] += 1
        elif path.endswith(".js") or path.endswith(".css") or "/_next/static/" in path:
            s["js_assets"] += 1
        elif path.endswith((".png", ".jpg", ".jpeg", ".webp", ".svg", ".avif",
                            ".gif")):
            s["images"] += 1
        elif not path.endswith(ASSET_EXT):
            s["paths"].append(path)
            if s["entry"] is None:
                s["entry"] = path
        if len(s["uas"]) < 5 and ua not in s["uas"]:
            s["uas"].append(ua)
        if len(s["refs"]) < 3 and ref not in s["refs"]:
            s["refs"].append(ref)
        s["paths"] = s["paths"][:40]
    return sess


# ---------------------------------------------------------------- ASN 真值

def cymru_bulk(ips, timeout=60):
    """whois.cymru.com 端口 43 批量：{ip: [asn, "AS-Name, CC"]}。批量失败
    返回部分结果（缺失方按 unknown 处理，不抛——Cymru 抖动不阻塞判定）。"""
    out = {}
    B = 350
    for i in range(0, len(ips), B):
        chunk = ips[i:i + B]
        try:
            s = socket.create_connection(("whois.cymru.com", 43), timeout=timeout)
            s.settimeout(timeout)
            s.sendall(("begin\nverbose\n" + "\n".join(chunk) + "\nend\n").encode())
            data = b""
            while True:
                b = s.recv(65536)
                if not b:
                    break
                data += b
            s.close()
        except Exception as e:
            log("warn: cymru batch %d failed: %s" % (i, e))
            continue
        for ln in data.decode(errors="replace").splitlines():
            f = ln.split("|")
            if len(f) >= 2 and f[0].strip() not in ("Bulk", "Error"):
                try:
                    asn = int(f[0])
                except ValueError:
                    continue
                out[f[1].strip()] = [asn, (f[6].strip() if len(f) > 6 else "?")]
    return out


def is_consumer(asn, name):
    """消费 ISP 判定：ASN 集合真值优先，名称启发式兜底（反词防机房名带
    communications 之类误判）。unknown ASN 一律按非消费处理（从严）。"""
    if asn in CONSUMER_ASNS:
        return True
    n = (name or "").lower()
    if any(a in n for a in CONSUMER_NAME_ANTI):
        return False
    return any(h in n for h in CONSUMER_NAME_HINTS)


def is_hosting(asn, name, ipb):
    """机房/托管判定：ASN 集合真值（ip-ban.DATACENTER_ASNS）优先，名称启发式
    兜底；消费 ISP 一票否决。unknown ASN 按名称处理（unknown 不含关键词→非机房）。"""
    if is_consumer(asn, name):
        return False
    if asn in ipb.DATACENTER_ASNS:
        return True
    n = (name or "").lower()
    return any(h in n for h in HOSTING_NAME_HINTS)


def is_hosting_strict(asn, name, ipb):
    """自动封专用严格版：只认 ASN 真值集合，不用名称启发式。
    10-31 预演判例：HOSTING_NAME_HINTS 子串匹配把消费 ISP 误判成机房——
    Colombia 含 colo、AFRIHOST 含 host、Airtel Networks 含 networks——这些
    网段上的拟真嫌疑一旦进自动封就是误封真人。启发式仍可用于 classify/TG
    线（人工复核，错了无害），不可用于动手线。"""
    if is_consumer(asn, name):
        return False
    return asn in ipb.DATACENTER_ASNS


def stale_version(ua):
    """浏览器主版本停更判定 → (bool, 说明)。UA 可伪造，单独永不封——只作
    s1 拟真自动化的一个信号。"""
    for pat, cur, label in ((r"Chrome/(\d+)", CUR_CHROME, "Chrome"),
                            (r"Edg/(\d+)", CUR_EDGE, "Edge"),
                            (r"Firefox/(\d+)", CUR_FIREFOX, "Firefox")):
        m = re.search(pat, ua, re.I)
        if m and int(m.group(1)) < cur - STALE_DELTA:
            return True, "%s/%s 停更≥%d版" % (label, m.group(1), STALE_DELTA)
    m = re.search(r"Version/(\d+)\.", ua, re.I)
    if m and "safari" in ua.lower() and int(m.group(1)) < CUR_SAFARI - 10:
        return True, "Safari/%s 停更" % m.group(1)
    return False, ""


# ---------------------------------------------------------------- 判定

def ua_lower(s):
    return " ".join(s["uas"]).lower()


def is_welcome_ua(s):
    return any(w in ua_lower(s) for w in WELCOME_UA)


def is_selfid_ua(s, ipb):
    return (any(m in ua_lower(s) for m in ipb.SELFID_MARKERS)
            or any(m in ua_lower(s) for m in SELFID_EXTRA))


def is_scanner_client(s, ipb):
    u = ua_lower(s)
    return (not u.strip()) or any(m in u for m in ipb.OBVIOUS_BOT_UA)


def burst(s):
    return (s["first"] and s["last"] is not None
            and s["reqs"] >= BURST_REQS and s["last"] - s["first"] <= BURST_SECS)


# 本方拦截态：botblock 403（自报蜘蛛）/ nginx limit_req 429 / origin-gate 444
BLOCK_STATUS = ("403", "429", "444")


def classify_session(ip, s, asn, asn_name, ipb, ctx):
    """单会话判定 → (verdict, rule, evidence)。
    verdict: welcome / human / ban / suspect / noise / blocked。
    ctx: {"queue_keys": {短链: {ip,...}}}（主循环已并入 state 并含历史窗）。"""
    u = ua_lower(s)

    def ev(*parts):
        return " | ".join(p for p in parts if p)

    # ---- 白名单（IP 真值优先，UA 不看——misban 同纪律）----
    if ip in ipb.OWNER_IPS:
        return "welcome", "owner", "站主出口"
    if ipb.is_crawler_ip(ip):
        return "welcome", "official-net", "官方爬虫段 IP"
    if is_welcome_ua(s):
        return "welcome", "selfid-welcome", "点名欢迎 UA"

    # ---- 全拦静默（2026-10-29 用户口径：机器人没拉到页面就别发 TG）----
    # 0 次成功取页（无 2xx/3xx）且多数响应是本方拦截态（429 限速/403
    # botblock/444 origin-gate）→ 判 blocked：不动手、不进疑似、不发通知，
    # 拦它的防线继续拦。404/410 是应用真实应答（探测证据），不算拦截态。
    if s["ok200"] == 0 and s["blocked"] * 2 >= s["reqs"]:
        return "blocked", "rule-blocked", ev(
            "全拦 %d/%d" % (s["blocked"], s["reqs"]),
            "UA=%s" % (s["uas"][0][:70] if s["uas"] else "(空)"))

    evidence = ev("UA=%s" % (s["uas"][0][:70] if s["uas"] else "(空)"),
                  "%dreq%s" % (s["reqs"],
                               "/%ds" % (s["last"] - s["first"])
                               if burst(s) else ""),
                  "js=%d" % s["js_assets"],
                  "probe404=%d" % s["probe404"])

    # ---- 100% 线 ----
    if ATTACK_RE.search(u):
        return "ban", "attack-tool", evidence
    if is_scanner_client(s, ipb) and not is_consumer(asn, asn_name):
        return "ban", "script-client-nonres", evidence
    if ctx.get("honey_hits") and ip in ctx["honey_hits"]:
        return "ban", "honeypot", "蜜罐路径命中"

    browser = "mozilla" in u
    if browser:
        stale, stale_note = stale_version(u)
        if (stale and s["js_assets"] == 0
                and s["probe404"] >= PROBE_MIN
                and is_hosting(asn, asn_name, ipb)):
            return "ban", "fake-browser-probe-dc", evidence

        # ---- 真人铁证：消费 ISP + JS 执行保真 ----
        if is_consumer(asn, asn_name) and (s["rsc"] or s["graphql"] or s["pwa"]
                                           or s["js_assets"] >= 10):
            return "human", "consumer-fidelity", evidence

        # ---- 疑似 s1：拟真自动化（停更 + 行为信号占一）----
        sigs = []
        if s["heads"] >= HEAD_MIN:
            sigs.append("HEAD×%d" % s["heads"])
        if burst(s):
            sigs.append("单页爆发%dreq/%ds" % (s["reqs"], s["last"] - s["first"]))
        for key in s["paths"]:
            if key in ctx["queue_keys"] and len(ctx["queue_keys"][key]) >= 2:
                sigs.append("短链复用 %s ×%dIP" % (key[:40],
                                                  len(ctx["queue_keys"][key])))
                break
        if stale and sigs:
            return "suspect", "reality-mismatch", ev(
                "拟真自动化", stale_note, *sigs,
                "graphql×%d RSC×%d" % (s["graphql"], s["rsc"]))
        # ---- 疑似 s4：重爬虫 ----
        if (s["reqs"] >= SCRAPER_MIN_REQS
                and s["js_assets"] / max(s["reqs"], 1) < 0.1
                and s["graphql"] == 0 and s["pwa"] == 0):
            return "suspect", "mass-scraper", evidence
        # ---- 疑似 s3：自报 bot 但不在欢迎名单 ----
        if is_selfid_ua(s, ipb):
            return "suspect", "unknown-bot", evidence
        if (stale and not is_consumer(asn, asn_name)
                and (s["js_assets"] > 0 or s["reqs"] >= 5)):
            # 单发老 Chrome 抓取太弱（VN/RO 家宽老电脑也可能），要求最低行为量
            return "suspect", "stale-browser", ev(evidence, stale_note)
        return "noise", "-", "-"

    # 非浏览器且非已知客户端 UA（漏网 client 库/怪 UA）
    if is_selfid_ua(s, ipb):
        return "suspect", "unknown-bot", evidence
    if is_hosting(asn, asn_name, ipb):
        return "suspect", "odd-client-dc", evidence
    return "noise", "-", "-"


def auto_ban_rule(tier, seen, asn, asn_name, selfid, ua_str, ipb):
    """疑似→自动封裁定 → rule | None（2026-10-31 用户底线：正常爬虫和真人
    永不自动封）。三重前提缺一不可：非自报身份（自报可能是正常新爬虫，只 TG）
    + 机房段 ASN 严格真值（is_hosting_strict——名称启发式会把 Colombia/
    Airtel 等消费 ISP 误判机房，只许用于 TG 线）+ 冒充浏览器或无爬虫礼仪。"""
    if selfid:
        return None
    if not is_hosting_strict(asn, asn_name, ipb):
        return None
    if tier == "odd-client-dc":
        if any(m in ua_str for m in MONITOR_UA):
            return None                       # 探活/拨测服务 → TG 裁决
        return "auto:odd-client-dc"
    if tier == "reality-mismatch":            # 冒充浏览器（停更+行为硬信号）
        return "auto:reality-mismatch-dc"
    if tier == "mass-scraper":                # 无礼仪重爬（自报早被排除）
        return "auto:mass-scraper-dc"
    if seen >= REPEAT_BAN_SEEN:               # 惯犯（机房段+非自报才到这）
        return "auto:repeat-offender-dc"
    return None


def suspect_notify_mode(rule, new_count):
    """疑似 TG 模式：unknown-bot（自报爬虫）一次性静默，舰队（≥FLEET_MIN_IPS
    个新 IP）发一条；其余 tier 维持即时报（防刷屏聚合照旧）。"""
    if rule != "unknown-bot":
        return "tg"
    return "fleet" if new_count >= FLEET_MIN_IPS else "silent"


def promote_shadow(state, ipb, now):
    """影子名单转正 → (promoted, vetoed)。owner/官方段最终否决（双保险：
    影子判定时已否决过一次，转正再验一次）。"""
    sb = state.get("shadow_banned") or {}
    promoted, vetoed = [], []
    for ip, b in list(sb.items()):
        if ip in ipb.OWNER_IPS or ipb.is_crawler_ip(ip):
            vetoed.append(ip)
        else:
            state["banned"][ip] = {"until": now + BAN_TTL, "rule": b["rule"],
                                   "since": now, "evidence": b["evidence"]}
            promoted.append(ip)
    state["shadow_banned"] = {}
    return promoted, vetoed


def fleet_check(s, asn, asn_name, ipb, ip, state, now):
    """s2 一次性校验队：同 ASN 同形状 ≥FLEET_MIN_IPS 个 IP → 全员疑似。
    形状 = 单页 ≤3req 零 JS 机房段；pattern 取路径前 3 段。
    自报 bot 不进舰队（那是 unknown-bot 线，10-28 判例：Reflectionbot 舰队）"""
    if not (s["reqs"] <= 3 and s["js_assets"] == 0
            and not is_selfid_ua(s, ipb)
            and is_hosting(asn, asn_name, ipb)):
        return False
    pattern = "/".join((s["paths"][0] if s["paths"] else "/").split("/")[:3])
    key = "%s|%s" % (asn, pattern)
    fleet = state.setdefault("fleet", {})
    rec = fleet.setdefault(key, {"ips": {}, "ts": now})
    rec["ips"][ip] = now
    rec["ts"] = now
    fresh = {i for i, t in rec["ips"].items() if now - t <= FLEET_TTL}
    rec["ips"] = {i: t for i, t in rec["ips"].items() if i in fresh}
    return len(fresh) >= FLEET_MIN_IPS


# ---------------------------------------------------------------- CF 同步

def prepare_rule(rules, banned):
    """纯函数：在规则列表中原位维护 ip-audit-tempban（空则 disable 休眠，
    同 ip-ban.apply_blacklist 判例）→ (同一列表, 是否变化)。"""
    rule = next((r for r in rules
                 if r.get("ref") == RULE_REF
                 or str(r.get("description", "")).startswith(RULE_REF)), None)
    changed = False
    if banned:
        expr = "(ip.src in {%s})" % " ".join(sorted(banned))
        desc = "%s (%d IPs; %dd; managed by ip-audit.py)" % (
            RULE_REF, len(banned), BAN_TTL // 86400)
        if rule:
            if (rule.get("expression") != expr or not rule.get("enabled", True)):
                rule["expression"] = expr
                rule["description"] = desc
                rule["enabled"] = True
                changed = True
        else:
            rules.append({"action": "block", "action_parameters": {},
                          "expression": expr, "description": desc,
                          "enabled": True, "ref": RULE_REF})
            changed = True
    elif rule and rule.get("enabled", True):
        rule["enabled"] = False
        rule["description"] = "%s (empty; managed by ip-audit.py)" % RULE_REF
        changed = True
    return rules, changed


def sync_cf(ipb, cf, banned, dry):
    """双 zone 同步；返回是否全部成功（失败方由调用方记 unsynced 重试）。"""
    ok = True
    for zone in ipb.ZONES:
        try:
            rules = ipb.get_rules(cf, zone)
            rules, changed = prepare_rule(rules, banned)
            if changed:
                if dry:
                    log("dry-run: PUT %s (%d rules)" % (zone, len(rules)))
                else:
                    ipb.put_rules(cf, zone, rules)
                    log("cf sync: %s -> %d IPs" % (zone, len(banned)))
        except Exception as e:
            log("cf sync failed for %s: %s" % (zone, e))
            ok = False
    return ok


# ---------------------------------------------------------------- 通知

def bot_family(s):
    """UA → campaign 家族名（自报 bot 取名字，浏览器 UA 归 browser）"""
    u = s["uas"][0] if s["uas"] else ""
    m = re.search(r"([A-Za-z][A-Za-z0-9_-]{2,30}(?:[Bb]ot|spider|Spider|externalhit))", u)
    return m.group(1) if m else "browser"


def tg(ipb, msg):
    ipb.tg("[ip-audit] " + msg)


def sid_of(tier, ip):
    return hashlib.md5(("%s|%s" % (tier, ip)).encode()).hexdigest()[:8]


# ---------------------------------------------------------------- state

def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
        if isinstance(s, dict) and "checkpoint" in s:
            s.setdefault("asn_cache", {})
            s.setdefault("banned", {})
            s.setdefault("suspects", {})
            s.setdefault("fleet", {})
            s.setdefault("queue", {})
            s.setdefault("counters", {})
            s.setdefault("shadow_banned", {})
            return s
    except Exception:
        pass
    return {"checkpoint": None, "asn_cache": {}, "banned": {}, "suspects": {},
            "fleet": {}, "queue": {}, "counters": {}, "unsynced": False,
            "daily_sent": None, "shadow_banned": {}}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, STATE_FILE)


def container_started_at():
    """容器 StartedAt epoch（重建即丢日志——checkpoint 超前则收缩并记盲窗）。"""
    try:
        out = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.StartedAt}}", "noda-static-prod"],
            capture_output=True, text=True, timeout=30).stdout.strip()
        import calendar
        t = time.strptime(out[:19], "%Y-%m-%dT%H:%M:%S")
        return calendar.timegm(t)
    except Exception:
        return None


def expire_bans(state, now):
    """到期解封 → (解封列表, 是否变化)。"""
    unbanned = [ip for ip, b in state["banned"].items() if now > b["until"]]
    for ip in unbanned:
        del state["banned"][ip]
    return unbanned, bool(unbanned)


def prune(state, now):
    """短链队列/舰队图过期清理；asn 缓存超限丢最旧（dict 保序）。"""
    for key in list(state["queue"]):
        rec = state["queue"][key]
        rec["ips"] = {i: t for i, t in rec["ips"].items() if now - t <= QUEUE_TTL}
        if not rec["ips"]:
            del state["queue"][key]
    for key in list(state["fleet"]):
        if now - state["fleet"][key]["ts"] > FLEET_TTL:
            del state["fleet"][key]
    for sid in list(state["suspects"]):
        rec = state["suspects"][sid]
        if (rec.get("status") in ("banned", "dismissed", "silent")
                and now - rec.get("last", 0) > 30 * 86400):
            del state["suspects"][sid]
    if len(state["asn_cache"]) > 20000:
        for k in list(state["asn_cache"])[:len(state["asn_cache"]) - 20000]:
            del state["asn_cache"][k]


# ---------------------------------------------------------------- 主流程

def cmd_run(dry):
    ipb = load_ipb()
    now = int(time.time())
    state = load_state()

    def notify(msg):
        """统一通知出口：dry-run 只记日志不发 TG（2026-10-28 判例：首轮 dry-run
        忘记抑制把 6 条疑似真发了 TG）"""
        if dry:
            log("dry-tg: " + msg)
        else:
            tg(ipb, msg)
    if os.path.exists(STATE_FILE) is False and dry is False:
        log("first run: state created")
    if SHADOW:
        log("SHADOW mode: 新线自动封只记决策不动 CF（IP_AUDIT_SHADOW=1）")
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)

    ipb.load_crawler_ranges()
    ipb._crawler_ip_cache.clear()

    # ---- 窗口：checkpoint → now，容器重建截断感知 ----
    since = state["checkpoint"] or (now - FIRST_RUN_WINDOW)
    blind = 0
    c_start = container_started_at()
    if c_start and c_start > since:
        blind = c_start - since
        log("blind window: %d s (container recreated)" % blind)
        since = c_start

    out = subprocess.run(
        ["docker", "logs", "--since", str(since), ipb.NGINX_CONTAINER],
        capture_output=True, text=True, timeout=300)
    events = parse_lines(ipb, out.stdout + out.stderr)
    sess = aggregate(events)
    log("window %s..%s: %d events, %d client IPs%s"
        % (time.strftime("%F %T", time.gmtime(since)),
           time.strftime("%F %T", time.gmtime(now)), len(events), len(sess),
           (" (blind %ds)" % blind) if blind else ""))

    # ---- ASN 真值（缓存优先，缺的批量查）----
    missing = [ip for ip in sess if ip not in state["asn_cache"]]
    if missing:
        state["asn_cache"].update(cymru_bulk(missing))
    hosting_asns = set(ipb.DATACENTER_ASNS)

    # ---- 短链队列并入历史窗（48h）----
    for ip, s in sess.items():
        for p in s["paths"]:
            if ITEM_RE.match(p):
                rec = state["queue"].setdefault(p.lower(), {"ips": {}, "ts": now})
                rec["ips"][ip] = now
                rec["ts"] = now
    queue_keys = {k: set(r["ips"]) for k, r in state["queue"].items()}

    # ---- 蜜罐命中（预留）----
    honey_hits = set()
    if HONEY_PATHS:
        for ip, s in sess.items():
            if any(p in HONEY_PATHS for p in s["paths"]):
                honey_hits.add(ip)

    ctx = {"queue_keys": queue_keys, "hosting_asns": hosting_asns,
           "honey_hits": honey_hits}

    # ---- 到期解封 ----
    unbanned, unbanned_changed = expire_bans(state, now)
    for ip in unbanned:
        notify("🔓 解封 %s（7 天期满）" % ip)
        log("unbanned %s" % ip)

    # ---- 影子名单转正（切实后首个非影子 run）----
    if (state.get("shadow_banned") or {}) and not SHADOW:
        promoted, vetoed = promote_shadow(state, ipb, now)
        if promoted:
            notify("🧪→🔒 shadow 名单转正 %dIP 7天: %s"
                   % (len(promoted), ",".join(promoted[:10])))
        if vetoed:
            log("SAFETY: shadow promote vetoed: %s" % vetoed)

    # ---- 一次性迁移：存量一次性自报小爬虫转静默（新口径 2026-10-31）----
    if not state.get("migrated_lanes"):
        n = 0
        for rec in state["suspects"].values():
            if (rec.get("status") == "open" and rec.get("tier") == "unknown-bot"
                    and rec.get("seen", 1) <= SILENT_MAX_SEEN):
                rec["status"] = "silent"
                n += 1
        state["migrated_lanes"] = True
        if n:
            log("migration: %d one-off unknown-bot -> silent" % n)

    # ---- 逐会话判定 ----
    counts = {"welcome": 0, "human": 0, "ban": 0, "suspect": 0, "noise": 0,
              "blocked": 0}
    new_bans = {}          # ip -> (rule, evidence)（100% 线）
    auto_bans = {}         # ip -> (rule, evidence)（新线，受 SHADOW 支配）
    new_suspects = []      # (sid, ip, rule, evidence)
    for ip, s in sess.items():
        asn, asn_name = state["asn_cache"].get(ip, [None, "unknown"])
        verdict, rule, evidence = classify_session(ip, s, asn, asn_name, ipb, ctx)
        counts[verdict] += 1
        if verdict == "ban":
            if ip in ipb.OWNER_IPS or ipb.is_crawler_ip(ip):
                log("SAFETY: ban proposal for %s (%s) vetoed" % (ip, rule))
                continue
            new_bans[ip] = (rule, evidence)
        elif verdict == "suspect":
            if fleet_check(s, asn, asn_name, ipb, ip, state, now):
                rule = "one-shot-fleet"
            selfid = is_selfid_ua(s, ipb)
            sid = sid_of(rule, ip)
            is_new = sid not in state["suspects"]
            rec = state["suspects"].get(sid)
            if rec:
                rec["last"] = now
                rec["seen"] = rec.get("seen", 1) + 1
            else:
                rec = state["suspects"][sid] = {
                    "ip": ip, "asn": asn, "asn_name": asn_name, "tier": rule,
                    "evidence": evidence, "first": now, "last": now,
                    "seen": 1, "status": "open", "notified": False,
                    "selfid": selfid}
            rec["selfid"] = selfid          # 老档案回填（缺失时按当次会话真值）
            # ---- 新线自动封（底线：自报爬虫/消费模糊 ISP 永不自动封）----
            if (ip not in state["banned"]
                    and ip not in (state.get("shadow_banned") or {})
                    and rec.get("status") not in ("banned", "dismissed")):
                ab = auto_ban_rule(rule, rec["seen"], asn, asn_name, selfid,
                                   ua_lower(s), ipb)
                if ab:
                    auto_bans[ip] = (ab, evidence)
                    rec["status"] = "banned"
                    rec["ban_rule"] = ab
                    continue
            if is_new:
                new_suspects.append((sid, ip, rule, evidence))

    # ---- 新疑似 → 分级 TG（自报爬虫静默/舰队一条；其余 campaign 聚合防刷屏）----
    groups = {}
    for sid, ip, rule, evidence in new_suspects:
        asn, asn_name = state["asn_cache"].get(ip, ["?", "?"])
        fam = bot_family(sess[ip])
        groups.setdefault((rule, asn, fam), []).append((sid, ip, evidence))
    silent_count = 0
    tg_groups = []
    for (rule, asn, fam), items in groups.items():
        mode = suspect_notify_mode(rule, len(items))
        if rule == "unknown-bot":
            for sid, _, _ in items:
                state["suspects"][sid]["status"] = "silent"
            silent_count += len(items)
            if mode == "fleet":
                sample = "; ".join("%s %s" % (ip, ev[:70]) for _, ip, ev in items[:2])
                notify("🤖 自报爬虫 %s ×%dIP AS%s | %s | 封: ip-audit.py ban %s"
                       % (fam, len(items), asn, sample[:240], items[0][0]))
        else:
            tg_groups.append(((rule, asn, fam), items))
    for (rule, asn, fam), items in tg_groups[:6]:
        sample = "; ".join("%s %s" % (ip, ev[:70]) for _, ip, ev in items[:2])
        notify("🤔 疑似机器人 %s ×%dIP AS%s | %s | 封: ip-audit.py ban %s"
            % (fam, len(items), asn, sample[:240], items[0][0]))
    if len(tg_groups) > 6:
        notify("…另有 %d 组新疑似未推送（见 ip-audit.py status）" % (len(tg_groups) - 6))
    for sid, ip, rule, evidence in new_suspects:
        state["suspects"][sid]["notified"] = True

    # ---- 100% 线 → 封 7 天 ----
    for ip, (rule, evidence) in new_bans.items():
        state["banned"][ip] = {"until": now + BAN_TTL, "rule": rule,
                               "since": now, "evidence": evidence}
        notify("🔒 封禁 %s 7天（%s）证据: %s | 解封 %s"
            % (ip, rule, evidence,
               time.strftime("%F", time.gmtime(now + BAN_TTL))))
        log("banned %s (%s)" % (ip, rule))
    if len(state["banned"]) > TEMP_BAN_MAX:
        keep = sorted(state["banned"].items(), key=lambda kv: kv[1]["until"])[:TEMP_BAN_MAX]
        state["banned"] = dict(keep)

    # ---- 新线自动封 → shadow 记账或实封（2026-10-31 底线版）----
    if auto_bans:
        by_rule = {}
        for ip, (rule, evidence) in auto_bans.items():
            by_rule.setdefault(rule, []).append(ip)
        detail = "; ".join("%s: %s" % (r, ",".join(ips[:6]))
                           for r, ips in sorted(by_rule.items())[:5])
        if SHADOW:
            sb = state.setdefault("shadow_banned", {})
            for ip, (rule, evidence) in auto_bans.items():
                sb[ip] = {"until": now + BAN_TTL, "rule": rule, "since": now,
                          "evidence": evidence}
            if len(sb) > TEMP_BAN_MAX:
                keep = sorted(sb.items(), key=lambda kv: kv[1]["until"])[:TEMP_BAN_MAX]
                state["shadow_banned"] = dict(keep)
            notify("🧪 shadow 将自动封 %dIP（未动手）: %s" % (len(auto_bans), detail))
            log("shadow auto-bans: %s"
                % {ip: r for ip, (r, _) in auto_bans.items()})
        else:
            for ip, (rule, evidence) in auto_bans.items():
                state["banned"][ip] = {"until": now + BAN_TTL, "rule": rule,
                                       "since": now, "evidence": evidence}
                log("auto-banned %s (%s)" % (ip, rule))
            notify("🔒 新线自动封 %dIP 7天: %s" % (len(auto_bans), detail))

    # ---- CF 同步（变更或上轮失败都重推）----
    sync_ok = True
    if new_bans or unbanned_changed or state.get("unsynced"):
        cf = ipb.load_cf_token()
        sync_ok = sync_cf(ipb, cf, state["banned"], dry)
    state["unsynced"] = not sync_ok

    # ---- 日简报（NZ 日界翻转时发昨日计数）----
    nz_day = time.strftime("%F", time.gmtime(now + 13 * 3600))
    if state["counters"].get("day") and state["counters"]["day"] != nz_day:
        c = state["counters"]
        notify("📊 %s 简报: 真人%d 欢迎爬虫%d 疑似%d(新%d 静默%d) 拦截%d "
               "自动封%d(百%%线%d 新线%d shadow%d) 解封%d 样本IP%d"
            % (c["day"], c["human"], c["welcome"], c["suspect"],
               c.get("suspect_new", 0), c.get("silent", 0), c.get("blocked", 0),
               c["ban"] + c.get("ban_auto", 0), c["ban"], c.get("ban_auto", 0),
               c.get("shadow", 0), c["unban"], c["ips"]))
        state["counters"] = {}
    c = state["counters"]
    c["day"] = nz_day
    for k in ("human", "welcome", "suspect", "noise", "blocked"):
        c[k] = c.get(k, 0) + counts[k]
    c["ban"] = c.get("ban", 0) + len(new_bans)
    c["ban_auto"] = c.get("ban_auto", 0) + (0 if SHADOW else len(auto_bans))
    c["shadow"] = c.get("shadow", 0) + (len(auto_bans) if SHADOW else 0)
    c["silent"] = c.get("silent", 0) + silent_count
    c["unban"] = c.get("unban", 0) + len(unbanned)
    c["suspect_new"] = c.get("suspect_new", 0) + len(new_suspects)
    c["ips"] = c.get("ips", 0) + len(sess)

    state["checkpoint"] = now
    prune(state, now)
    save_state(state)
    log("done: %s bans=%d shadow_bans=%d suspects_open=%d%s"
        % (counts, len(state["banned"]), len(state.get("shadow_banned") or {}),
           sum(1 for x in state["suspects"].values() if x["status"] == "open"),
           " (dry)" if dry else ""))


def resolve_target(state, target):
    """ban/dismiss 的目标解析：sid → (ip, suspect记录)；裸 IP → (ip, None)"""
    if target in state["suspects"]:
        return state["suspects"][target]["ip"], state["suspects"][target]
    return target, None


def cmd_ban(target, reason):
    ipb = load_ipb()
    now = int(time.time())
    state = load_state()
    ip, rec = resolve_target(state, target)
    if ip in ipb.OWNER_IPS:
        log("SAFETY: %s is owner IP, refuse" % ip)
        return
    ipb.load_crawler_ranges()
    if ipb.is_crawler_ip(ip):
        log("SAFETY: %s is official crawler range, refuse" % ip)
        return
    state["banned"][ip] = {"until": now + BAN_TTL, "rule": "manual:%s" % (reason or "user"),
                           "since": now,
                           "evidence": (rec or {}).get("evidence", "手动封禁")}
    if rec:
        rec["status"] = "banned"
    save_state(state)
    cf = ipb.load_cf_token()
    ok = sync_cf(ipb, cf, state["banned"], dry=("--dry-run" in sys.argv))
    state["unsynced"] = not ok
    save_state(state)
    tg(ipb, "🔒 手动封禁 %s 7天（%s）解封 %s"
        % (ip, reason or "user", time.strftime("%F", time.gmtime(now + BAN_TTL))))
    log("manual ban %s ok" % ip)


def cmd_dismiss(target):
    state = load_state()
    ip, rec = resolve_target(state, target)
    if rec:
        rec["status"] = "dismissed"
        save_state(state)
        log("dismissed %s (%s)" % (target, rec["ip"]))
    else:
        log("no suspect %s" % target)


def cmd_status():
    state = load_state()
    print("== banned (%d) ==" % len(state["banned"]))
    for ip, b in sorted(state["banned"].items(), key=lambda kv: kv[1]["until"]):
        print("  %s until %s rule=%s" % (ip, time.strftime(
            "%F %T", time.gmtime(b["until"])), b["rule"]))
    sb = state.get("shadow_banned") or {}
    if sb:
        print("== shadow_banned (%d) 待转正 ==" % len(sb))
        for ip, b in sorted(sb.items(), key=lambda kv: kv[1]["until"]):
            print("  %s rule=%s since %s" % (ip, b["rule"], time.strftime(
                "%F %T", time.gmtime(b.get("since", 0)))))
    st = {}
    for r in state["suspects"].values():
        st[r.get("status", "?")] = st.get(r.get("status", "?"), 0) + 1
    print("== suspects by status: %s ==" % st)
    open_s = [(sid, r) for sid, r in state["suspects"].items()
              if r["status"] == "open"]
    print("== suspects open (%d) ==" % len(open_s))
    for sid, r in sorted(open_s, key=lambda kv: -kv[1]["last"]):
        print("  %s %s AS%s %s seen=%d %s"
              % (sid, r["ip"], r["asn"], r["tier"], r["seen"], r["evidence"][:90]))


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv
    if not args or args[0] == "run":
        cmd_run(dry)
    elif args[0] == "ban":
        cmd_ban(args[1], " ".join(args[2:]) if len(args) > 2 else "")
    elif args[0] == "dismiss":
        cmd_dismiss(args[1])
    elif args[0] == "status":
        cmd_status()
    else:
        log("usage: ip-audit.py [run|--dry-run] | ban <sid|ip> [reason] | "
            "dismiss <sid> | status")
        sys.exit(2)


if __name__ == "__main__":
    main()
