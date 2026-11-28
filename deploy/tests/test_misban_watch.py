#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""misban-watch.py 单元测试（误封分类/心跳判定/告警去重/报表组装）

不打真网络：CF GraphQL/origin 扫描不触达；官方网段用 ip-ban 内置 fallback。
运行：pytest deploy/tests/test_misban_watch.py
"""

import importlib.util
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY = os.path.dirname(HERE)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def ipb(monkeypatch, tmp_path):
    """加载 ip-ban（隔离 ENV_FILE/ALLOW_CIDRS），官方段走内置 fallback"""
    monkeypatch.delenv("ALLOW_CIDRS", raising=False)
    m = _load("ip_ban_tw", os.path.join(DEPLOY, "ip-ban.py"))
    monkeypatch.setattr(m, "ENV_FILE", str(tmp_path / "no.env"), raising=False)
    monkeypatch.setattr(m, "GOOGLE_NETS",
                        m.parse_cidrs(",".join(m.GOOGLEBOT_FALLBACK)))
    monkeypatch.setattr(m, "BING_NETS",
                        m.parse_cidrs(",".join(m.BINGBOT_FALLBACK)))
    monkeypatch.setattr(m, "EXTRA_CRAWLER_NETS",
                        m.parse_cidrs(",".join(m.EXTRA_CRAWLER_RANGES)))
    m._crawler_ip_cache.clear()
    return m


@pytest.fixture
def mw(tmp_path):
    mod = _load("misban_watch", os.path.join(DEPLOY, "misban-watch.py"))
    mod.REPORT_DIR = str(tmp_path / "sr")
    mod.WATCH_STATE = os.path.join(mod.REPORT_DIR, "watch-state.json")
    mod.ALERTS_JSONL = os.path.join(mod.REPORT_DIR, "alerts.jsonl")
    os.makedirs(mod.REPORT_DIR, exist_ok=True)
    return mod


# ---- is_content_host ----

def test_content_hosts(mw):
    assert mw.is_content_host("noda.co.nz")
    assert mw.is_content_host("www.noda.co.nz")
    assert mw.is_content_host("class.noda.co.nz")
    assert mw.is_content_host("shuotong.wang")
    assert mw.is_content_host("www.shuotong.wang")


def test_non_content_hosts_excluded(mw):
    for h in ("admin.noda.co.nz", "auth.noda.co.nz", "comments.noda.co.nz",
              "api.noda.co.nz", "health.noda.co.nz", "admin-preprod.noda.co.nz",
              "localhost.noda.co.nz", "evil.attacker.com", "", None):
        assert not mw.is_content_host(h), h


# ---- ua_class ----

def test_ua_class_fake(mw, ipb):
    assert mw.ua_class("Mozilla/5.0 (compatible; Googlebot/2.1; +http://google.com/bot.html)", ipb) == "fake"
    assert mw.ua_class("bingbot-ish chrome", ipb) == "fake"


def test_ua_class_selfid_and_script_and_human(mw, ipb):
    assert mw.ua_class("GPTBot/1.0", ipb) == "selfid"
    assert mw.ua_class("Meta-ExternalAgent/1.1", ipb) == "selfid"
    assert mw.ua_class("curl/8.4.0", ipb) == "script"
    assert mw.ua_class("", ipb) == "script"
    ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1"
    assert mw.ua_class(ua, ipb) == "human"


# ---- classify_event ----

def test_official_ip_hit_is_misban_even_with_bot_ua(mw, ipb):
    ev = {"ip": "66.249.73.130", "ua": "Mozilla/5.0 (compatible; Googlebot/2.1)",
          "_official_ip": True}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "misban"


def test_official_ip_hit_human_ua_still_misban(mw, ipb):
    # Mediapartners 判例：官方段 + 无 bot 字样 UA 也是官方爬虫
    ev = {"ip": "209.85.238.129", "ua": "Mozilla/5.0", "_official_ip": True}
    assert mw.classify_event(ev, ipb)[1] is True


# ---- 官方段政策豁口（2026-11-23 DuckAssistBot 判例）----
# DuckAssistBot=Duck.ai AI 助手爬虫（duckduckbot.json 官方段收录其 486 个 Azure
# 出口），10-17「AI bot 全 Block」裁定优先于「官方清单=欢迎」教义——geo-challenge
# managed_challenge 拦它属政策执行非误封，出口轮换不该轮番触发「误封实锤」
# （11-22 的 20.253.114.51 → 11-23 的 20.80.135.7 连报实据）。豁口只对
# managed_challenge；action=block 仍告警兜底真异常。

def test_duckassist_managed_challenge_is_policy_not_misban(mw, ipb):
    ev = {"ip": "20.80.135.7", "action": "managed_challenge",
          "source": "firewallCustom",
          "ua": "DuckAssistBot/1.2; (+http://duckduckgo.com/duckassistbot.htm)",
          "_official_ip": True}
    assert mw.classify_event(ev, ipb) == ("policy-challenge", False)


def test_duckassist_block_still_misban(mw, ipb):
    # block（如撞 blacklist）不是 geo 裁定面，仍告警兜底
    ev = {"ip": "20.80.135.7", "action": "block", "source": "firewallCustom",
          "ua": "DuckAssistBot/1.2; (+http://duckduckgo.com/duckassistbot.htm)",
          "_official_ip": True}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "misban"


def test_official_ip_other_ua_challenge_still_misban(mw, ipb):
    # 豁口只认 DuckAssistBot：官方段其他 UA 被 challenge 仍属误封实锤
    ev = {"ip": "66.249.73.130", "action": "managed_challenge",
          "source": "firewallCustom",
          "ua": "Mozilla/5.0 (compatible; Googlebot/2.1)", "_official_ip": True}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "misban"


def test_fake_googlebot_ua_non_official_ip_not_misban(mw, ipb):
    ev = {"ip": "203.0.113.9", "ua": "Mozilla/5.0 (compatible; Googlebot/2.1)",
          "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is False and cls == "fake"


def test_human_ua_block_is_info_not_misban(mw, ipb):
    ev = {"ip": "52.94.76.1", "ua": "Mozilla/5.0 (Macintosh)", "_official_ip": False}
    assert mw.classify_event(ev, ipb) == ("human", False)


# ---- D3：官方清单外自报 UA 被 block = 疑似误封（2026-11-22 HubSpot 判例）----
# ABUSE ASN 无 UA 豁免/hotlink 规则/blacklist 残留都可能拦到守规矩爬虫——
# official 段之外 D1 看不见，D3 用 UA 维度补盲区（block 才报，challenge 是
# geo-challenge 用户裁定面；fake UA 本就该拦不报）。

def test_selfid_ua_block_is_suspected_misban(mw, ipb):
    ev = {"ip": "203.0.113.9", "action": "block", "source": "firewallCustom",
          "ua": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; "
                "HubSpot Crawler; +https://www.hubspot.com/)", "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "selfid-block"


def test_selfid_ua_challenge_not_flagged(mw, ipb):
    """challenge 是 geo-challenge 裁定面，不算误封候选"""
    ev = {"ip": "203.0.113.9", "action": "managed_challenge",
          "source": "firewallCustom", "ua": "Twitterbot/1.0", "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is False and cls == "selfid"


def test_selfid_ua_non_custom_source_not_flagged(mw, ipb):
    """非 firewallCustom 来源（如 ratelimit）不归 D3 管"""
    ev = {"ip": "203.0.113.9", "action": "block", "source": "ratelimit",
          "ua": "AhrefsBot/7.0", "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is False and cls == "selfid"


# ---- D3 政策归档两层（2026-11-28 判例三修三）----
# ①死站归档：DEAD_HOSTS block 非官方段自报 UA = 死站只放 verified 爬虫的政策
#   执行（11-19 判据）——PerplexityBot/SERanking 换 IP 重报噪音不再告警；
# ②vendor-ASN 真值：自报 UA 对照 VENDOR_ASN_TRUTH，ASN 对不上=伪装假身份
#   归档（11-23 GPTBot 四假 UA 同分钟同页集群）；对得上或缺 ASN=fail-open 仍告警。

def test_selfid_block_on_deadhost_archived(mw, ipb):
    # PerplexityBot 在 snagme（AWS 真出口 18.97.9.97 本周 4 连报判例）→ 政策归档
    ev = {"ip": "18.97.9.97", "asn": 16509, "action": "block",
          "source": "firewallCustom", "host": "snagme.noda.co.nz",
          "ua": "Mozilla/5.0 (compatible; PerplexityBot/1.0; "
                "+https://perplexity.ai/perplexitybot.htm)", "_official_ip": False}
    assert mw.classify_event(ev, ipb) == ("policy-deadhost", False)


def test_official_ip_block_on_deadhost_still_misban(mw, ipb):
    # 官方段被死站拦 = 豁免漂移（11-22 ::f4/fa 判例同型），必须继续实锤告警
    ev = {"ip": "66.249.72.6", "asn": 15169, "action": "block",
          "source": "firewallCustom", "host": "snagme.noda.co.nz",
          "ua": "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X)",
          "_official_ip": True}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "misban"


def test_selfid_vendor_asn_mismatch_is_fake_archived(mw, ipb):
    # 11-23 四假 UA 集群判例：GPTBot 自报但 ASN 非 Azure → 伪装假身份归档
    ev = {"ip": "89.34.79.193", "asn": 49447, "action": "block",
          "source": "firewallCustom", "host": "noda.co.nz",
          "ua": "Mozilla/5.0 (compatible; GPTBot/1.0)", "_official_ip": False}
    assert mw.classify_event(ev, ipb) == ("policy-fakeua", False)


def test_selfid_meta_asn_mismatch_is_fake_archived(mw, ipb):
    ev = {"ip": "46.28.197.228", "asn": 204601, "action": "block",
          "source": "firewallCustom", "host": "noda.co.nz",
          "ua": "Meta-ExternalAgent/1.0", "_official_ip": False}
    assert mw.classify_event(ev, ipb) == ("policy-fakeua", False)


def test_selfid_vendor_asn_match_still_alerts(mw, ipb):
    # ASN 对得上（Perplexity 在 AWS 16509）+ 官方段外的活站 = 仍疑似误封
    ev = {"ip": "44.205.89.55", "asn": 16509, "action": "block",
          "source": "firewallCustom", "host": "noda.co.nz",
          "ua": "Mozilla/5.0 (compatible; PerplexityBot/1.0)",
          "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "selfid-block"


def test_selfid_asn_missing_fails_open(mw, ipb):
    # 事件缺 ASN（GraphQL 字段异常等）→ fail-open 仍告警，不静默归档
    ev = {"ip": "203.0.113.9", "asn": 0, "action": "block",
          "source": "firewallCustom", "host": "noda.co.nz",
          "ua": "GPTBot/1.0", "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "selfid-block"


def test_selfid_unknown_vendor_no_truth_fails_open(mw, ipb):
    # 真值表外 vendor（OusanBot 判例型）维持 ⚠️ 待人工复核
    ev = {"ip": "203.0.113.9", "asn": 63949, "action": "block",
          "source": "firewallCustom", "host": "shuotong.wang",
          "ua": "Mozilla/5.0 (compatible; OusanBot/1.0; +https://ousan.io/bot)",
          "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is True and cls == "selfid-block"


# ---- decide_canary / canary_quiet_hours ----

def test_canary_google_silence_threshold(mw):
    assert mw.decide_canary("google", 35.0) is False
    assert mw.decide_canary("google", 37.0) is True


def test_canary_bing_slower_threshold(mw):
    assert mw.decide_canary("bing", 60.0) is False
    assert mw.decide_canary("bing", 73.0) is True


def test_canary_other_family_never(mw):
    assert mw.decide_canary("other", 9999.0) is False


def test_scan_window_covers_bing_threshold(mw):
    # 零到访态的静默封顶=扫描窗；窗 < 阈值则 bing 永远够不到判定线（2026-10-25 判例）
    assert mw.PAGE_FETCH_WINDOW >= mw.BING_SILENCE_H


def test_quiet_zero_crawler_full_window_both_alert(mw):
    # 日志覆盖满窗 + 窗口内零到访：google(36h)/bing(72h) 均超阈值 → 都告警
    now = 1_800_000_000
    earliest = now - mw.PAGE_FETCH_WINDOW * 3600 + 60
    q, eff = mw.canary_quiet_hours(None, None, earliest, now)
    assert eff is None
    assert q > mw.GOOGLE_SILENCE_H
    assert mw.decide_canary("google", q) is True
    assert mw.decide_canary("bing", q) is True


def test_quiet_truncated_logs_caps_silence(mw):
    # 容器刚重建（日志只覆盖 10 分钟）：静默按覆盖时长封顶，不得虚报满窗
    now = 1_800_000_000
    earliest = now - 600
    q, eff = mw.canary_quiet_hours(None, None, earliest, now)
    assert eff is None and q * 3600 <= 600.001
    assert mw.decide_canary("google", q) is False
    assert mw.decide_canary("bing", q) is False


def test_quiet_high_water_survives_truncation(mw):
    # 重建前的最后到访留在高水位：静默跨截断持续累计，bing 超 72h 照样告警
    now = 1_800_000_000
    hw = now - 80 * 3600
    q, eff = mw.canary_quiet_hours(None, hw, now - 600, now)
    assert eff == hw and q > mw.BING_SILENCE_H
    assert mw.decide_canary("bing", q) is True


def test_quiet_scan_and_hw_take_max(mw):
    now = 1_800_000_000
    q, eff = mw.canary_quiet_hours(now - 2 * 3600, now - 5 * 3600, None, now)
    assert eff == now - 2 * 3600 and 1.9 < q < 2.1


# ---- alert 去重与落盘 ----

def test_alert_dedup_and_jsonl(mw, ipb):
    state = {}
    alerts = []
    mw.alert(ipb, state, "k1", "msg-1", alerts)
    mw.alert(ipb, state, "k1", "msg-1-dup", alerts)   # 同 key 不重复
    mw.alert(ipb, state, "k2", "msg-2", alerts)
    assert len(alerts) == 2
    lines = [json.loads(l) for l in open(mw.ALERTS_JSONL)]
    assert [r["msg"] for r in lines] == ["msg-1", "msg-2"]
    assert state["alerted"] == ["k1", "k2"]


def test_alert_recovery_removes_key(mw, ipb):
    state = {"alerted": ["canary:google"]}
    alerts = []
    # 恢复路径在 main 里；这里验证去重账本可移除后能再次告警
    state["alerted"].remove("canary:google")
    mw.alert(ipb, state, "canary:google", "again", alerts)
    assert alerts and state["alerted"] == ["canary:google"]


def test_alert_cooldown_suppresses_and_resumes(mw, ipb):
    """2026-11-23 判例：TG 按 cool_key 冷却降噪——窗口内只发首条 TG，jsonl
    全量记账（suppressed 标记）；窗过期再触发时附静默计数并清零。
    判例原型：SERanking 30min 重试 robots.txt 连轰 D3；::f4/fa 13min 两条实锤"""
    state = {}
    alerts = []
    ck = "misban-d3:46.4.28.29|firewallCustom"
    mw.alert(ipb, state, "k1", "first", alerts, cool_key=ck, cool_h=24)
    mw.alert(ipb, state, "k2", "second", alerts, cool_key=ck, cool_h=24)
    mw.alert(ipb, state, "k3", "third", alerts, cool_key=ck, cool_h=24)
    assert [r["msg"] for r in alerts] == ["first", "second", "third"]
    lines = [json.loads(l) for l in open(mw.ALERTS_JSONL)]
    assert [r["msg"] for r in lines] == ["first", "second", "third"]
    assert lines[1].get("suppressed") and lines[2].get("suppressed")
    assert state["cool_suppressed"][ck] == 2
    # 冷却窗过期（时钟回拨模拟）
    state["cooldown"][ck] -= 25 * 3600
    mw.alert(ipb, state, "k4", "fourth", alerts, cool_key=ck, cool_h=24)
    assert "冷却窗内另有 2 次" in alerts[3]["msg"]
    assert ck not in state["cool_suppressed"]
    # 冷却位重置后再次触发 → 重新进入静默
    mw.alert(ipb, state, "k5", "fifth", alerts, cool_key=ck, cool_h=24)
    assert alerts[4].get("suppressed")


def test_prune_cooldown_expired(mw):
    """超 COOL_MAX_AGE 的冷却位清掉，静默计数随位清，孤儿计数不残留"""
    now = 1_800_000_000
    state = {"cooldown": {"old": now - mw.COOL_MAX_AGE - 10,
                          "fresh": now - 60},
             "cool_suppressed": {"old": 3, "fresh": 1, "ghost": 9}}
    mw.prune_cooldown(state, now)
    assert state["cooldown"] == {"fresh": now - 60}
    assert state["cool_suppressed"] == {"fresh": 1}


# ---- build_report ----

class _FakeResp:
    def __init__(self, payload):
        self._p = payload

    def read(self):
        return json.dumps(self._p).encode()


def test_fetch_events_lt_pagination_and_dedup(mw, monkeypatch):
    """2026-11-23 判例：datetime_lt 排他翻页（页边界必然前移，虚增读数不再
    原地死循环烧尽 EVENT_MAX）+ 行级去重（同 (ts,ip,path,action,source) 只计
    一次）——SERanking 4 事件只报 2 的漏报根因"""
    event = {"action": "block", "source": "firewallCustom",
             "clientRequestPath": "/a", "userAgent": "ua",
             "clientRequestHTTPHost": "noda.co.nz"}
    page1 = [dict(event, datetime="2026-11-23T10:00:00Z", clientIP="1.2.3.4")
             for _ in range(mw.EVENT_PAGE_LIMIT)]     # 50 条同键重复行=虚增读数
    page2 = [dict(event, datetime="2026-11-23T09:00:00Z", clientIP="5.6.7.8"),
             dict(event, datetime="2026-11-23T08:00:00Z", clientIP="9.9.9.9")]
    seen_vars = []

    def fake_urlopen(req, timeout=30):
        body = json.loads(req.data.decode())
        seen_vars.append(body["variables"])
        payload = {"data": {"viewer": {"zones": [{
            "firewallEventsAdaptive":
                page1 if len(seen_vars) == 1 else page2}]}}}
        return _FakeResp(payload)

    monkeypatch.setattr(mw.urllib.request, "urlopen", fake_urlopen)
    out = mw.fetch_events("tok", "zone", "2026-11-23T00:00:00Z")
    assert len(out) == 3                              # 50 重复行收敛为 1 条
    assert [e["clientIP"] for e in out].count("1.2.3.4") == 1
    # 首页 lt=当前时刻（非 since）；翻页 lt=上页最旧 ts（排他前进）；geq 恒为 since
    assert seen_vars[0]["lt"] != "2026-11-23T00:00:00Z"
    assert seen_vars[1]["lt"] == "2026-11-23T10:00:00Z"
    assert seen_vars[1]["since"] == "2026-11-23T00:00:00Z"


def test_build_report_shape(mw, ipb):
    now = 1_800_000_000
    state = {"persist_listed": ["203.0.113.0/32"], "persist": {"x": {"last": now}},
             "verify": {"v1": {"left": 3}}, "history": {"h": 1}, "tracks": {"a": []}}
    bans = {"1.2.3.4/32": {"until": now + 86400, "banned_at": now - 3600,
                           "reason": "test", "ttl": 86400}}
    canary = {"google": {"scan_last": now - 3600, "high_water": now - 3600,
                         "quiet_h": 1.0, "status": "ok"},
              "bing": {"scan_last": None, "high_water": now - 80 * 3600,
                       "quiet_h": 80.0, "status": "SILENT"}}
    digest = {"available": True, "window_hours": 0.2,
              "counts": {"fake": 2, "human": 1}, "by_source": {"custom_rules": 3},
              "recent": [], "misban_total": 0}
    r = mw.build_report(now, state, bans, ipb, canary, digest)
    assert r["generated_epoch"] == now
    assert r["bans"][0]["cidr"] == "1.2.3.4/32"
    assert r["bans"][0]["ttl_days"] == 1
    assert r["canary"]["google"]["status"] == "ok"
    assert r["canary"]["bing"]["status"] == "SILENT"
    assert r["canary"]["bing"]["threshold_h"] == mw.BING_SILENCE_H
    assert r["canary"]["bing"]["high_water"] is not None
    assert r["canary"]["bing"]["hours_quiet"] == 80.0
    assert r["persist_listed"] == ["203.0.113.0/32"]
    assert r["events"]["counts"]["fake"] == 2
    assert r["blacklist"] == "1/%d" % ipb.MAX_ENTRIES


def test_watch_actions_cover_challenges(mw):
    # 挑战类也算拦截（爬虫不会解挑战——真 Googlebot 被挑战=误封）
    for a in ("block", "managed_challenge", "challenge", "js_challenge"):
        assert a in mw.WATCH_ACTIONS


def test_events_query_has_needed_fields(mw):
    for f in ("clientIP", "userAgent", "clientRequestHTTPHost",
              "clientRequestPath", "action", "source", "datetime"):
        assert f in mw.EVENTS_QUERY
    assert str(mw.EVENT_PAGE_LIMIT) in mw.EVENTS_QUERY
