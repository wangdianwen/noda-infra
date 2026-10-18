#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ip-ban.py — 通用 IP 段黑名单（自动发现 spam 网段 → CF WAF 封禁 7 天 → 静默自动解封）

设计（2026-10-18 用户拍板的 8 点要求）：
- 不限于搜狗：任何「伪装浏览器/无头/枚举式抓取」的网段都自动进黑名单
- 区分机器人与真人（traffic 少，规则可解释）：
  * 欢迎（永不计入、永不封）：真 Googlebot（UA+Google 网段双验证）、
    其他自报身份的爬虫（UA 含 bot/spider/slurp——守规矩才敢自报家门）、站主 IP
  * 假 Googlebot（UA 报 Googlebot 但 IP 不在 Google 段）= 伪装，计入 bot
  * 明显 bot UA：HeadlessChrome / python-requests / curl / wget / Go-http-client …
  * 伪造老浏览器：Chrome 主版本 < 100（2026 年不存在的人类用户）
- /24 行为指纹（6 小时滚动窗口，低慢速爬取在 5 分钟窗内攒不够阈值）：
  请求 ≥40 且不同 IP ≥3 且（静态资源占比 ≤5% 或 bot-UA 占比 ≥50% 或去重路径 ≥15）
  → 真人浏览器必然带资源请求、单 IP 真人过不了「3 个不同 IP」门槛
- 单 IP 洪水：5 分钟窗内 ≥60 请求 → 封 /32（外科手术式）；真人浏览器爆发豁免——
  窗口内零 bot-UA 且命中 ≥3 次浏览器生命周期端点（sw.js/manifest/_next chunk/
  __next RSC/geo.json）即视为真 PWA 冷缓存首访，不封（WARP 真人误封事件教训）
- 攻击 URL 惯犯：同 IP 6h 内命中 ≥5 次机密探测路径（.env/.aws/wp-/.git/id_rsa/
  application.properties …——真人和守规矩爬虫永远不会请求这类路径，零误伤可能）
  → 封 /32、TTL 升级 30 天；/24 行为封禁若夹带攻击流量同样升级 30 天
- 封禁粒度 /24（自动化上限，/16 及以上永不自动封）；普通 TTL 7 天、攻击型 30 天，
  静默满自动解封
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
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

# ---- 配置 ----
ZONES = ("noda.co.nz", "class.noda.co.nz")  # 黑名单同步到全部 zone（token 需各 zone WAF Edit）
PHASE = "http_request_firewall_custom"
RULE_MARKER = "ip-range-blacklist"          # 规则 description 前缀 / ref
NGINX_CONTAINER = "noda-static-prod"
ENV_FILE = "/etc/noda/ip-ban.env"           # DOPPLER_SERVICE_TOKEN
STATE_FILE = "/opt/noda/noda-infra/docker/volumes/ops-logs/ip-ban.state.json"
TG_ALERT = "/mnt/mmc1-4/System/Scripts/telegram-alert.sh"

OWNER_IPS = {"47.72.103.104"}               # 站主出口（nginx 白名单同源）
GOOGLE_RANGES = ["66.249.64.0/19"]          # 真 Googlebot 网段

WINDOW_CAP = 1800                            # 单次扫描窗口上限 30 分钟
WINDOW_DEFAULT = 300                         # 首次运行/状态缺失默认 5 分钟
ROLL_HOURS = 6                               # /24 行为滚动窗口
BAN_TTL = 7 * 24 * 3600                      # 封禁 7 天
BAN24_MIN_REQ = 40                           # /24 封禁：6h 请求下限
BAN24_MIN_IPS = 3                            #   不同 IP 下限（轮换签名）
BAN24_MAX_ASSET_RATIO = 0.05                 #   静态资源占比上限（真浏览器必带资源）
BAN24_MIN_PATHS = 15                         #   或去重路径数下限（枚举签名）
BAN32_REQ = 60                               # 单 IP 5 分钟窗洪水阈值
BROWSER_SIGNAL_MIN = 3                       # 真人豁免：浏览器生命周期信号下限
ATTACK_MIN = 5                               # 攻击 URL 命中下限（6h 滚动窗内按源 IP）
ATTACK_TTL = 30 * 24 * 3600                  # 攻击型封禁 30 天
MAX_ENTRIES = 64                             # 黑名单容量上限
MAX_TRACKS = 500                             # 最多跟踪 /24 数
MAX_EVENTS_PER_TRACK = 400                   # 每 /24 最多保留事件数

TRACK_TTL = ROLL_HOURS * 3600

OBVIOUS_BOT_UA = [
    "headlesschrome", "python-requests", "python-urllib", "curl/", "wget",
    "go-http-client", "node-fetch", "axios/", "scrapy", "okhttp",
    "java/", "libwww", "fasthttp", "postman", "httpclient", "aiohttp",
]
SELFID_MARKERS = ["bot", "spider", "slurp", "crawler"]
ASSET_RE = re.compile(
    r"\.(js|css|mjs|png|jpe?g|webp|svg|gif|ico|woff2?|ttf|otf|map|mp4|avif)$"
    r"|/_next/static/", re.I)
ATTACK_RE = re.compile(                      # 机密探测路径（历史扫库字典高频项）
    r"\.env(\.|$)|/\.aws/|wp-(config|content|login)|application\.(properties|yml)(\.|$)"
    r"|composer/installed|/\.git(/|$)|\.svn/|id_rsa|/\.ssh/|\.sql(\.|$)|\.bak(\.|$)"
    r"|debug\.log(\.|$)|phpmyadmin|web\.config|\.htaccess|\.htpasswd|\.DS_Store"
    r"|actuator(/|$)|\.aspx?(\.|$)|\.jsp(\.|$)|/etc/passwd|\.\./", re.I)
BROWSER_SIGNAL_RE = re.compile(              # 真 PWA 浏览器生命周期端点（爬虫不拉）
    r"/sw\.js$|/manifest\.webmanifest$|/manifest\.json$|/offline\.html?$"
    r"|/_next/static/|/__next\.|/geo\.json$", re.I)
CHROME_VER_RE = re.compile(r"chrome/(\d+)\.", re.I)
LINE_RE = re.compile(
    r'^\S+ \S+ \S+ \[[^\]]+\] "(\S+) ([^"]*) HTTP/[^"]*" \d{3} \d+ '
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


def http_json(url, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def load_cf_token():
    tok = None
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                m = re.match(r"DOPPLER_SERVICE_TOKEN=(\S+)", line.strip())
                if m:
                    tok = m.group(1)
    if not tok:
        raise RuntimeError("no DOPPLER_SERVICE_TOKEN in %s" % ENV_FILE)
    r = http_json("https://api.doppler.com/v3/configs/config/secret"
                  "?project=noda&config=prd&name=CF_BAN_API_TOKEN", tok)
    v = r["value"]["computed"]
    if not v.startswith("cfat_"):
        raise RuntimeError("CF token from doppler looks wrong")
    return v


def entrypoint_url(zone_id):
    return ("https://api.cloudflare.com/client/v4/zones/%s/rulesets/phases/%s/entrypoint"
            % (zone_id, PHASE))


def get_rules(cf, zone_id):
    r = http_json(entrypoint_url(zone_id), cf)
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


def scan_window(since_epoch):
    """返回解析后的访问事件列表 [(ip, path, ua)]，解析失败的行丢弃"""
    out = subprocess.run(
        ["docker", "logs", "--since", str(since_epoch), NGINX_CONTAINER],
        capture_output=True, text=True, timeout=120)
    events = []
    for line in (out.stdout + out.stderr).splitlines():
        m = LINE_RE.match(line)
        if m:
            events.append((m.group(5).strip(), m.group(2).split("?", 1)[0],
                           m.group(4)))
    return events


def in_ranges(ip, cidrs):
    a = ipaddress.ip_address(ip)
    return any(a in ipaddress.ip_network(c) for c in cidrs)


def classify(ip, ua):
    """返回 'whitelist' | 'bot' | 'skip'（skip=受欢迎的守规矩爬虫，不计入）"""
    if ip in OWNER_IPS:
        return "whitelist"
    u = ua.lower()
    if "googlebot" in u:
        return "skip" if in_ranges(ip, GOOGLE_RANGES) else "bot"  # 假 Googlebot
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
        return

    try:
        events = scan_window(since)
    except Exception as e:
        log("log scan failed: %s" % e)
        return

    state = load_state()
    state["last_run"] = last_run
    bans = state["bans"]
    tracks = state["tracks"]
    cutoff = now - TRACK_TTL

    # ---- 事件入轨 ----
    window_ip_stats = {}                         # ip -> [请求数, 生命周期信号, bot-UA 数]
    for ip, path, ua in events:
        cls = classify(ip, ua)
        if cls == "whitelist" or cls == "skip":
            continue
        st = window_ip_stats.setdefault(ip, [0, 0, 0])
        st[0] += 1
        if BROWSER_SIGNAL_RE.search(path):
            st[1] += 1
        if cls == "bot":
            st[2] += 1
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
        if (assets / hits <= BAN24_MAX_ASSET_RATIO or botua / hits >= 0.5
                or len(paths) >= BAN24_MIN_PATHS):
            escalated = attack >= ATTACK_MIN
            proposals[p24] = (
                ("24h-enum" if len(paths) >= BAN24_MIN_PATHS
                 else "headless/rotation") + ("+attack" if escalated else ""),
                ATTACK_TTL if escalated else BAN_TTL)
            log("candidate %s: hits=%d ips=%d assets=%.0f%% botua=%.0f%% "
                "paths=%d attack=%d"
                % (p24, hits, len(ips), 100.0 * assets / hits,
                   100.0 * botua / hits, len(paths), attack))
    for ip, st in window_ip_stats.items():
        cidr = ip + "/%s" % ("128" if ipaddress.ip_address(ip).version == 6
                             else "32")
        cnt = st[0]
        if cnt < BAN32_REQ or cidr in bans or ip in OWNER_IPS:
            continue
        ah = ip_attack.get(ip, 0)
        if ah >= ATTACK_MIN:                    # 攻击 URL 优先：升级 30 天
            proposals[cidr] = ("attack-urls %d hits + flood %d req"
                               % (ah, cnt), ATTACK_TTL)
            continue
        if st[2] == 0 and st[1] >= BROWSER_SIGNAL_MIN:
            # 真人浏览器爆发豁免（WARP 事件 2026-10-18：iPhone 冷缓存首访
            # 19 秒 82 请求触发洪水线误封 7 天）。零 bot-UA + 命中生命周期
            # 端点（sw.js/manifest/_next chunk/__next RSC）= 真浏览器指纹。
            log("exempt %s: browser-burst %d req (signals=%d, botua=0, "
                "attack=0)" % (cidr, cnt, st[1]))
            continue
        proposals[cidr] = ("single-ip flood %d req/%ds"
                           % (cnt, now - since), BAN_TTL)
    for ip, ah in ip_attack.items():            # 低慢速机密探测（不够洪水线也封）
        if ah < ATTACK_MIN:
            continue
        cidr = ip + "/%s" % ("128" if ipaddress.ip_address(ip).version == 6
                             else "32")
        if cidr not in proposals and cidr not in bans and ip not in OWNER_IPS:
            proposals[cidr] = ("attack-urls %d hits/%dh" % (ah, ROLL_HOURS),
                               ATTACK_TTL)
            log("candidate %s: attack-url hits=%d" % (cidr, ah))

    # 白名单防误伤：提案网段内不得包含站主 IP / Google 段
    for cidr in list(proposals):
        net = ipaddress.ip_network(cidr)
        if any(ipaddress.ip_address(o) in net for o in OWNER_IPS):
            log("SAFETY: %s contains owner IP, skip" % cidr)
            del proposals[cidr]

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

    # ---- 同步 CF 规则（多 zone：黑名单同步到 ZONES 全部站点）----
    unsynced = sorted(set(state.get("unsynced") or []))
    need_put = bool(new_bans or unbanned or unsynced)
    if need_put:
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
            for zname in ZONES:
                zid = ids.get(zname)
                if not zid:
                    unsynced = sorted(set(unsynced) | {zname})
                    continue
                try:
                    put_rules(cf, zid, apply_blacklist(get_rules(cf, zid), bans))
                    unsynced = [z for z in unsynced if z != zname]
                except Exception as e:
                    log("CF sync failed for %s: %s (kept, will retry)" % (zname, e))
                    unsynced = sorted(set(unsynced) | {zname})
        except Exception as e:
            log("CF token/zone 解析失败: %s (kept, will retry)" % e)
            unsynced = sorted(set(unsynced) | set(ZONES))
    state["unsynced"] = unsynced

    # ---- 通知 ----
    for cidr, reason, ttl in new_bans:
        log("BAN: %s (%s), until %s" % (
            cidr, reason, time.strftime("%F %T", time.localtime(now + ttl))))
        tg("ip-ban: 封禁 %s（%s），%d 天后自动解封。当前黑名单 %d 段"
           % (cidr, reason, ttl // 86400, len(bans)))
    for c, ttl in unbanned:
        log("UNBAN: %s silent %dd reached" % (c, ttl // 86400))
        tg("ip-ban: %s 静默满 %d 天，自动解封" % (c, ttl // 86400))
    if not new_bans and not unbanned:
        log("no action: %d events scanned, blacklist=%d, tracks=%d"
            % (len(events), len(bans), len(tracks)))

    state["bans"] = bans
    state["tracks"] = tracks
    save_state(state)


if __name__ == "__main__":
    main()
