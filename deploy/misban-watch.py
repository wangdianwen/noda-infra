#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
misban-watch.py — 误封哨兵 + admin 安全报表（2026-10-26 用户需求：报表上 admin 站
随时看 + 主动消息 + 误封自动发现「不要等 Google 发邮件」）

两个检测器（互补，一个断另一个仍活）：
- D1 事件流（需 CF_REPORT_API_TOKEN 带 Zone→Analytics→Read；CF_BAN_API_TOKEN/
  CF_API_TOKEN 均无此权限 2026-10-26 实测）：CF GraphQL firewallEventsAdaptive
  双 zone 增量拉封禁/挑战事件 → 命中官方爬虫段（googlebot.json/bingbot.json/
  66.249.64.0/19/209.85.128.0/17，IP 真值优先不看 UA）= 实锤误封 → TG 即报。
  host 过滤：admin./auth./comments./api./health. 等后台 host 被挑战是正确行为
  （robots.txt 全站 Disallow，守规矩爬虫本就不该来），不计误封。
- D2 源站心跳（零新权限，token 到位前唯一活着的哨兵）：索引中的站点必然有官方
  爬虫 IP 定期打源站；源站日志里 Googlebot 连续 GOOGLE_SILENCE_H 小时无踪 = 疑似
  边缘误封（含 GSC 之外的静默 403），TG 即报；恢复自动解除。反向价值：心跳在 =
  「Google 能进」的持续证明。
  2026-10-25 判例：部署重建容器会截断 docker logs（access.log→stdout，随容器归零），
  48h 扫描窗瞬间只剩几分钟数据，「窗口内零到访」被误报成「48 小时未见」——修复
  三件套：① None 态静默按「日志实际覆盖时长」封顶；② canary_last 高水位入
  watch-state（跨容器重建存活）；③ 扫描窗 80h ≥ bing 阈值 72h，零到访态够得到判定线。

报表：ops-logs/security-report/{report.json, page.html, alerts.jsonl}
  ops-logs 卷已挂 noda-static-prod:/var/log/rl429 → nginx admin server 块
  /security/ 静态伺服（admin.noda.co.nz/security/，CF admin non-NZ challenge
  保护；robots.txt 全站 Disallow）。
通知：误封/心跳静默即时 TG；事件源缺失仅提示一次（state 记账，配置好自动消）。
复用 ip-ban.py：官方网段/is_crawler_ip/load_crawler_ranges/tg/env/LINE_RE。
state：security-report/watch-state.json（last_run/告警去重/一次性提示记账）。
cron：*/10（deploy/crontab-r4s-host，带 hb 心跳）。
"""

import importlib.util
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
IPB_PATH = os.path.join(SCRIPT_DIR, "ip-ban.py")
REPORT_DIR = os.path.join("/opt/noda/noda-infra/docker/volumes/ops-logs",
                          "security-report")
PAGE_SRC = os.path.join(SCRIPT_DIR, "security-report.html")
WATCH_STATE = os.path.join(REPORT_DIR, "watch-state.json")
ALERTS_JSONL = os.path.join(REPORT_DIR, "alerts.jsonl")
MAX_ALERTS = 200
MAX_DEDUP = 500

WINDOW_CAP = 24 * 3600        # 事件回看窗口上限（Free 版事件留存仅 ~3 天）
WINDOW_DEFAULT = 600          # 首跑/状态缺失回看 10 分钟
CRON_STEP = 600
GOOGLE_SILENCE_H = 36         # Googlebot 源站心跳静默阈值（正常数小时一访）
BING_SILENCE_H = 72           # bing 抓取节奏慢，阈值放宽
PAGE_FETCH_WINDOW = 80        # 心跳扫描窗口（小时）——必须 ≥ BING_SILENCE_H，
                              # 否则「窗口内零到访」态永远够不到 bing 判定线
HW_MAX_AGE = 14 * 86400       # 心跳高水位保留期（超期视为失忆，重新观测）
EVENT_PAGE_LIMIT = 50         # GraphQL 单页事件数（稳妥）
EVENT_MAX = 1000              # 单轮回看事件上限（防首次回灌刷屏；截断记进报表）
DASH_URL = "https://admin.noda.co.nz/security/"

# 后台 host 前缀：被挑战/封禁=正确行为，不计误封（robots.txt 全站 Disallow 在位）
NON_CONTENT_PREFIX = ("admin.", "auth.", "comments.", "api.", "health.",
                      "localhost.", "www-preprod.", "admin-preprod.",
                      "class-preprod.", "auth-preprod.")
CONTENT_SUFFIX = ("noda.co.nz", "shuotong.wang")
WATCH_ACTIONS = ("block", "managed_challenge", "challenge", "js_challenge")

EVENTS_QUERY = """query($z: String!, $since: Time!) {
  viewer { zones(filter: {zoneTag: $z}) {
    firewallEventsAdaptive(limit: %d, orderBy: [datetime_DESC],
      filter: {datetime_geq: $since}) {
      action source datetime clientIP clientCountryName
      clientRequestHTTPHost clientRequestPath userAgent
    } } } }""" % EVENT_PAGE_LIMIT


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def load_ipb():
    spec = importlib.util.spec_from_file_location("ipb_shared", IPB_PATH)
    m = importlib.util.module_from_spec(spec)
    sys.modules["ipb_shared"] = m
    spec.loader.exec_module(m)
    return m


def tg(ipb, msg):
    ipb.tg("[misban-watch] " + msg)


def alert(ipb, state, key, msg, alerts):
    """去重告警：同 key 只发一次（state.alerted 记账），全部落 alerts.jsonl"""
    if key in state.get("alerted", []):
        return
    state.setdefault("alerted", []).append(key)
    rec = {"t": int(time.time()), "key": key, "msg": msg}
    alerts.append(rec)
    with open(ALERTS_JSONL, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    tg(ipb, msg)


def is_content_host(host):
    h = (host or "").lower()
    return (any(h == s or h.endswith("." + s) for s in CONTENT_SUFFIX)
            and not h.startswith(NON_CONTENT_PREFIX))


def ua_class(ua, ipb):
    """事件 UA 分类（官方段判定在外层，这里只看 UA 自身）：fake=点名伪装
    googlebot/bingbot；selfid=自报家门；script=诚实脚本/空 UA；human=其余"""
    u = (ua or "").lower()
    if "googlebot" in u or "bingbot" in u:
        return "fake"
    if any(m in u for m in ipb.SELFID_MARKERS):
        return "selfid"
    if not u.strip() or any(m in u for m in ipb.OBVIOUS_BOT_UA):
        return "script"
    return "human"


def classify_event(ev, ipb):
    """事件 → (类别, 是否误封)。官方段 IP 命中即 misban（IP 真值优先，与
    ip-ban.py 白名单同源）；UA 类别只作计数归档。"""
    if ev.get("_official_ip"):
        return "misban", True
    return ua_class(ev.get("ua") or "", ipb), False


def fetch_events(cf_token, zone_id, since_iso):
    """GraphQL 增量事件（分页拉全窗口内事件，上限 EVENT_MAX）"""
    out = []
    after = since_iso
    while len(out) < EVENT_MAX:
        req = urllib.request.Request(
            "https://api.cloudflare.com/client/v4/graphql",
            data=json.dumps({"query": EVENTS_QUERY,
                             "variables": {"z": zone_id, "since": after}}).encode(),
            headers={"Authorization": "Bearer " + cf_token,
                     "Content-Type": "application/json"})
        r = json.load(urllib.request.urlopen(req, timeout=30))
        if r.get("errors"):
            raise RuntimeError("graphql: %s" % json.dumps(r["errors"])[:200])
        evs = r["data"]["viewer"]["zones"][0]["firewallEventsAdaptive"]
        if not evs:
            break
        out.extend(evs)
        if len(evs) < EVENT_PAGE_LIMIT:
            break
        after = evs[-1]["datetime"]        # DESC 末条 = 最旧，下一页从它往前
        if len(out) >= EVENT_MAX:
            out = out[:EVENT_MAX]
            break
    return out


def origin_crawler_scan_ts(ipb, since_epoch):
    """D2 源站心跳扫描：扫 nginx 日志统计官方爬虫段 IP 的最后到访（google/bing
    分族，行级时间戳），同时记录本轮解析到的最早日志行时刻——容器重建截断日志时
    用它识别「真实观测窗」。返回 (last_by_fam, earliest_epoch|None)"""
    try:
        out = subprocess.run(
            ["docker", "logs", "--since", str(since_epoch), ipb.NGINX_CONTAINER],
            capture_output=True, text=True, timeout=300)
    except Exception as e:
        log("origin scan failed: %s" % e)
        return {}, None
    import re as _re
    TS = _re.compile(r"\[(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-]\d{4})\]")
    MON = {m: i for i, m in enumerate(
        "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
    last = {}
    earliest = None
    for line in (out.stdout + out.stderr).splitlines():
        m = ipb.LINE_RE.match(line)
        if not m:
            continue
        ts = TS.search(line)
        if ts:
            d, mon, y, hh, mm, ss, tz = ts.groups()
            off = (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60) * (1 if tz[0] == "+" else -1)
            import calendar as _cal
            epoch = _cal.timegm((int(y), MON[mon], int(d), int(hh), int(mm),
                                 int(ss), 0, 0, 0)) - off
            earliest = epoch if earliest is None else min(earliest, epoch)
        else:
            epoch = since_epoch
        ip = ipb.client_ip_from_xff(m.group(6))
        if not ip or not ipb.is_crawler_ip(ip):
            continue
        fam = "bing" if ipb.in_nets(ip, ipb.BING_NETS) else (
            "google" if (ipb.in_nets(ip, ipb.GOOGLE_NETS)
                         or ipb.in_nets(ip, ipb.EXTRA_CRAWLER_NETS)) else "other")
        last[fam] = max(last.get(fam, 0), epoch)
    return last, earliest


def threshold_of(fam):
    if fam == "google":
        return GOOGLE_SILENCE_H
    if fam == "bing":
        return BING_SILENCE_H
    return None


def canary_quiet_hours(scan_last, hw_last, earliest_line, now):
    """心跳真实静默时长（小时）→ (quiet_h, 有效最后到访或 None)。
    有效到访取「本轮扫描 ↔ 高水位」较大者（高水位跨容器重建存活）；两者皆无
    （窗口内零到访）时静默按「日志实际覆盖时长」封顶，不再把截断后的短观测窗
    夸大成满窗（2026-10-25 判例：10 分钟观测被误报成 48 小时未见）。"""
    seen = [x for x in (scan_last, hw_last) if x]
    if seen:
        eff = max(seen)
        return (now - eff) / 3600.0, eff
    win_start = now - PAGE_FETCH_WINDOW * 3600
    cover_from = max(win_start, earliest_line or win_start)
    return (now - cover_from) / 3600.0, None


def decide_canary(fam, quiet_h):
    """D2 判定（纯函数）：真实静默超阈值 → True。bing 节奏慢阈值放宽；
    google 是 SEO 主命脉用严阈值。"""
    th = threshold_of(fam)
    return th is not None and quiet_h > th


def build_report(now, state, bans, ipb, canary, events_digest):
    iso = lambda t: time.strftime("%F %T", time.localtime(t)) if t else None
    canary_out = {}
    for fam in ("google", "bing"):
        d = canary.get(fam) or {}
        canary_out[fam] = {
            "last_seen": iso(d.get("scan_last")),
            "last_seen_epoch": d.get("scan_last"),
            "high_water": iso(d.get("high_water")),
            "high_water_epoch": d.get("high_water"),
            "hours_quiet": d.get("quiet_h"),
            "threshold_h": threshold_of(fam),
            "status": d.get("status")}
    return {
        "generated_at": iso(now), "generated_epoch": now, "tz": "NZ",
        "events": events_digest,
        "canary": canary_out,
        "bans": [{"cidr": c, "reason": b.get("reason", ""),
                  "until": iso(b["until"]), "ttl_days": b.get("ttl", 0) // 86400,
                  "banned_at": iso(b.get("banned_at", 0))}
                 for c, b in sorted(bans.items(), key=lambda kv: kv[1]["until"])],
        "blacklist": "%d/%d" % (len(bans), ipb.MAX_ENTRIES),
        "persist_listed": state.get("persist_listed") or [],
        "persist_tracked": len(state.get("persist") or {}),
        "verify": state.get("verify") or {},
        "history_count": len(state.get("history") or {}),
        "tracks": len(state.get("tracks") or {}),
        "zones": list(ipb.ZONES),
    }


def write_page():
    os.makedirs(REPORT_DIR, exist_ok=True)
    dst = os.path.join(REPORT_DIR, "page.html")
    try:
        with open(PAGE_SRC, "rb") as s:
            data = s.read()
    except FileNotFoundError:
        log("page template missing: %s" % PAGE_SRC)
        return
    try:
        with open(dst, "rb") as d:
            same = d.read() == data
    except FileNotFoundError:
        same = False
    if not same:
        with open(dst, "wb") as d:
            d.write(data)
        os.chmod(dst, 0o644)


def main():
    ipb = load_ipb()
    now = int(time.time())
    os.makedirs(REPORT_DIR, exist_ok=True)
    try:
        state = json.load(open(WATCH_STATE))
    except Exception:
        state = {}
    since = max(state.get("last_run", now - WINDOW_DEFAULT), now - WINDOW_CAP)

    ipb.load_crawler_ranges()
    ipb._crawler_ip_cache.clear()

    alerts = []

    # ---- D1 事件流（token 缺失则降级，只提示一次）----
    cf_token = ipb.env_settings().get("CF_REPORT_API_TOKEN")
    events_digest = {"available": False, "window_hours": round((now - since) / 3600, 1),
                     "counts": {}, "recent": [], "note": ""}
    if cf_token:
        events_digest = collect_events(ipb, cf_token, since, now, state, alerts)
    else:
        if not state.get("no_token_notified"):
            tg(ipb, "事件流误封检测未启用（CF_REPORT_API_TOKEN 未配置，"
                    "需 Zone→Analytics→Read；D2 源站心跳哨兵已独立运行）。"
                    "token 步骤见 deploy/cf-custom-rules.md")
            state["no_token_notified"] = True
            alerts.append({"t": now, "key": "no-token",
                           "msg": "events source unavailable"})
            with open(ALERTS_JSONL, "a") as f:
                f.write(json.dumps(alerts[-1], ensure_ascii=False) + "\n")
        events_digest["note"] = "CF_REPORT_API_TOKEN 未配置"

    # ---- D2 源站心跳 ----
    scan_last, earliest_line = origin_crawler_scan_ts(
        ipb, now - PAGE_FETCH_WINDOW * 3600)
    hw = state.setdefault("canary_last", {})
    for fam in ("google", "bing"):
        if scan_last.get(fam):
            hw[fam] = max(hw.get(fam, 0), scan_last[fam])
    for fam in [f for f, t in hw.items() if now - t > HW_MAX_AGE]:
        hw.pop(fam)
    canary = {}
    for fam in ("google", "bing"):
        quiet_h, eff = canary_quiet_hours(
            scan_last.get(fam), hw.get(fam), earliest_line, now)
        th = threshold_of(fam)
        silent = decide_canary(fam, quiet_h)
        canary[fam] = {"scan_last": scan_last.get(fam),
                       "high_water": hw.get(fam),
                       "quiet_h": round(quiet_h, 1),
                       "status": "SILENT" if silent else "ok"}
        k = "canary:%s" % fam
        if silent:
            alert(ipb, state, k,
                  "%s 心跳消失：源站 %.1f 小时未见官方段请求（阈值 %dh），"
                  "疑似边缘误封，查 CF Security Events %s"
                  % (fam, quiet_h, th, DASH_URL), alerts)
        elif k in state.get("alerted", []):        # 恢复自动解除
            state["alerted"].remove(k)
            if eff:
                text = ("%s 心跳恢复（最后到访 %s，静默 %.1fh<%dh）——解除误封怀疑"
                        % (fam, time.strftime("%F %T", time.localtime(eff)),
                           quiet_h, th))
            else:
                text = ("%s 心跳解除：窗口内零到访但静默 %.1fh 未超阈值 %dh"
                        "（日志覆盖不足防误报）——解除误封怀疑" % (fam, quiet_h, th))
            tg(ipb, text)
            with open(ALERTS_JSONL, "a") as f:     # 解除也落账，报表列表自带闭环
                f.write(json.dumps({"t": now, "key": k, "msg": text,
                                    "resolved": True}, ensure_ascii=False) + "\n")

    state["last_run"] = now
    if len(state.get("alerted", [])) > MAX_DEDUP:
        state["alerted"] = state["alerted"][-MAX_DEDUP:]

    ipb_state = ipb.load_state()
    report = build_report(now, ipb_state, ipb_state["bans"], ipb,
                          canary, events_digest)
    report["alerts"] = alerts_tail()
    tmp = os.path.join(REPORT_DIR, "report.json.tmp")
    with open(tmp, "w") as f:
        json.dump(report, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, os.path.join(REPORT_DIR, "report.json"))
    write_page()
    with open(WATCH_STATE, "w") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
    log("report ok: canary=%s events_avail=%s bans=%d alerts_this_run=%d"
        % ({k: v["status"] for k, v in report["canary"].items()},
           events_digest["available"], len(ipb_state["bans"]), len(alerts)))


def alerts_tail(n=50):
    try:
        with open(ALERTS_JSONL) as f:
            lines = f.readlines()[-n:]
        return [json.loads(l) for l in reversed(lines)]
    except FileNotFoundError:
        return []


def collect_events(ipb, cf_token, since, now, state, alerts):
    """D1 主逻辑：双 zone 拉事件 → 分类 → 误封告警 → 聚合 digest"""
    digest = {"available": True, "window_hours": round((now - since) / 3600, 1),
              "counts": {}, "recent": [], "note": "", "truncated": False}
    per_class = {}
    by_source = {}
    recent = []
    misban_seen = 0
    for zname in ipb.ZONES:
        try:
            zid = json.load(urllib.request.urlopen(urllib.request.Request(
                "https://api.cloudflare.com/client/v4/zones?name=" + zname,
                headers={"Authorization": "Bearer " + cf_token}),
                timeout=30))["result"][0]["id"]
            evs = fetch_events(cf_token, zid, time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(since)))
        except Exception as e:
            log("events fetch failed for %s: %s" % (zname, e))
            digest["note"] = "fetch failed: %s" % str(e)[:120]
            continue
        for ev in evs:
            host = ev.get("clientRequestHTTPHost") or ""
            if not is_content_host(host):
                continue
            if (ev.get("action") or "").lower() not in WATCH_ACTIONS:
                continue
            ip = ev.get("clientIP") or ""
            official = ipb.is_crawler_ip(ip) if ip else False
            item = {"zone": zname, "action": ev.get("action"),
                    "source": ev.get("source"), "ts": ev.get("datetime"),
                    "ip": ip, "country": ev.get("clientCountryName"),
                    "host": host, "path": (ev.get("clientRequestPath") or "")[:120],
                    "ua": (ev.get("userAgent") or "")[:120],
                    "_official_ip": official}
            cls, misban = classify_event(item, ipb)
            item.pop("_official_ip", None)
            item["_cls"] = cls
            per_class[cls] = per_class.get(cls, 0) + 1
            src = item["source"] or "?"
            by_source[src] = by_source.get(src, 0) + 1
            recent.append(item)
            if misban:
                misban_seen += 1
                alert(ipb, state,
                      "misban:%s|%s|%s|%s" % (item["ts"], ip, item["action"], src),
                      "🚨误封实锤：官方爬虫段 IP %s 被 %s/%s 拦截（%s%s UA=%s）"
                      "——查豁免！%s" % (ip, zname, src, host, item["path"],
                                        item["ua"][:60], DASH_URL), alerts)
    recent.sort(key=lambda x: x["ts"] or "", reverse=True)
    digest["counts"] = per_class
    digest["by_source"] = by_source
    digest["recent"] = recent[:30]
    digest["misban_total"] = misban_seen
    if sum(per_class.values()) >= EVENT_MAX:
        digest["truncated"] = True
    return digest


if __name__ == "__main__":
    main()
