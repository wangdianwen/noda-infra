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


def test_fake_googlebot_ua_non_official_ip_not_misban(mw, ipb):
    ev = {"ip": "203.0.113.9", "ua": "Mozilla/5.0 (compatible; Googlebot/2.1)",
          "_official_ip": False}
    cls, misban = mw.classify_event(ev, ipb)
    assert misban is False and cls == "fake"


def test_human_ua_block_is_info_not_misban(mw, ipb):
    ev = {"ip": "52.94.76.1", "ua": "Mozilla/5.0 (Macintosh)", "_official_ip": False}
    assert mw.classify_event(ev, ipb) == ("human", False)


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


# ---- build_report ----

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
