#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ip-audit.py 单元测试（判据分级/日志解析/队列复用/舰队识别/CF 规则原位维护）。
用 2026-10-28 真实判例当固定用例：RCN 拟真自动化→疑似不误封、Baxet 一次性
校验队→舰队疑似、SoftLayer Firefox/41 探测→100% 封、2degrees 真人→白名单。
不打真网络：Cymru/CF/docker 均不触达，官方段用 ip-ban 内置 fallback。
运行：pytest deploy/tests/test_ip_audit.py
"""

import importlib.util
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


ipb = _load("ip_ban_audit", os.path.join(DEPLOY, "ip-ban.py"))
ipb.ENV_FILE = "/tmp/nonexistent-ip-ban-test.env"
ipb.GOOGLE_NETS = ipb.parse_cidrs(",".join(ipb.GOOGLEBOT_FALLBACK))
ipb.BING_NETS = ipb.parse_cidrs(",".join(ipb.BINGBOT_FALLBACK))
ipb.EXTRA_CRAWLER_NETS = ipb.parse_cidrs(",".join(ipb.EXTRA_CRAWLER_RANGES))
ipb._crawler_ip_cache.clear()

ia = _load("ip_audit", os.path.join(DEPLOY, "ip-audit.py"))

T0 = 1793211650   # 2026-10-28T02:47:30Z 前后，任意固定时刻

CHROME_NEW = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")
CHROME_125 = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")
FF41 = "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:41.0) Gecko/20100101 Firefox/41.0"

AWS = "AMAZON-AES - Amazon.com, Inc., US"
RCN = "RCN-AS - RCN, US"
TD = "TWO-DEGREES-AS-AP - Two Degrees Networks Ltd, NZ"


def mk(**kw):
    """空会话模板（字段与 ip-audit.aggregate.blank 一致）"""
    s = {"reqs": 0, "heads": 0, "posts": 0, "js_assets": 0, "images": 0,
         "graphql": 0, "rsc": 0, "pwa": 0, "probe404": 0, "uas": [], "refs": [],
         "paths": [], "entry": None, "first": T0, "last": T0}
    s.update(kw)
    return s


def ctx(**kw):
    base = {"queue_keys": {}, "honey_hits": set()}
    base.update(kw)
    return base


C = ctx()   # 通用判定上下文（hosting 由 is_hosting(asn,name,ipb) 内部判）


# ---------------------------------------------------------------- 解析

def test_parse_lines_and_aggregate():
    lines = "\n".join([
        '172.18.0.7 - - [28/Oct/2026:02:47:30 +0000] "GET /zh/item/abc HTTP/1.1" '
        '301 0 "-" "curl/8.1.2" "9.142.174.8"',
        '172.18.0.7 - - [28/Oct/2026:02:47:31 +0000] "GET /zh/page HTTP/1.1" '
        '200 512 "https://x.test/" "%s" "9.142.174.8"' % CHROME_125,
        '172.18.0.7 - - [28/Oct/2026:02:47:32 +0000] "GET /_next/static/a.js HTTP/1.1" '
        '200 512 "-" "%s" "9.142.174.8"' % CHROME_125,
        '172.18.0.7 - - [28/Oct/2026:02:47:33 +0000] "POST /graphql HTTP/1.1" '
        '200 64 "-" "%s" "9.142.174.8"' % CHROME_125,
        '172.18.0.7 - - [28/Oct/2026:02:47:34 +0000] "GET /zh/__next._tree.txt HTTP/1.1" '
        '200 64 "-" "%s" "9.142.174.8"' % CHROME_125,
        '172.18.0.7 - - [28/Oct/2026:02:47:35 +0000] "HEAD /zh HTTP/1.1" '
        '200 0 "-" "%s" "9.142.174.8"' % CHROME_125,
        '172.18.0.7 - - [28/Oct/2026:02:47:36 +0000] "GET /missing HTTP/1.1" '
        '404 0 "-" "%s" "9.142.174.8"' % CHROME_125,
        'garbage line without quotes',
        '/docker-entrypoint.sh: looking for shell scripts',
    ])
    ev = ia.parse_lines(ipb, lines)
    assert len(ev) == 7
    assert ev[0][1] == "9.142.174.8" and ev[0][2] == "GET" and ev[0][3] == "/zh/item/abc"
    assert ev[3][2] == "POST" and ev[3][4] == "200"
    assert ev[0][5] == "curl/8.1.2"
    s = ia.aggregate(ev)["9.142.174.8"]
    assert s["reqs"] == 7 and s["posts"] == 1 and s["heads"] == 1
    assert s["js_assets"] == 1 and s["graphql"] == 1 and s["rsc"] == 1
    assert s["probe404"] == 1
    assert s["entry"] == "/zh/item/abc"        # 首个非资产路径（301 落地前导）
    assert "/zh/page" in s["paths"]
    assert s["first"] is not None and s["last"] > s["first"]


# ---------------------------------------------------------------- UA/ASN 判定

def test_stale_version():
    assert ia.stale_version(CHROME_125) == (True, "Chrome/125 停更≥12版")
    assert ia.stale_version(CHROME_NEW)[0] is False
    assert ia.stale_version(FF41)[0] is True
    assert ia.stale_version(
        "Mozilla/5.0 (Macintosh) Version/15.6 Safari/605.1.15")[0] is True
    assert ia.stale_version("")[0] is False


def test_is_consumer():
    assert ia.is_consumer(9790, TD)
    assert ia.is_consumer(4771, "SPARKNZ - Spark New Zealand, NZ")
    assert not ia.is_consumer(14618, AWS)
    assert not ia.is_consumer(None, "unknown")
    assert not ia.is_consumer(26383, "ASNET - Baxet Group Inc., US")
    assert ia.is_consumer(None, "Vocus Communications Limited, NZ")


def test_is_hosting():
    assert ia.is_hosting(14618, AWS, ipb)                 # ASN 真值
    assert ia.is_hosting(26383, "ASNET - Baxet Group Inc., US", ipb)   # 名称兜底
    assert ia.is_hosting(36351, "SOFTLAYER - IBM Cloud, US", ipb)
    assert not ia.is_hosting(6079, RCN, ipb)              # RCN 是住宅 ISP
    assert not ia.is_hosting(9790, TD, ipb)               # 消费 ISP 一票否决


# ---------------------------------------------------------------- 分级判定

def test_tiers_ban():
    # ① curl + 机房段 → 100%
    assert ia.classify_session(
        "3.2.3.4", mk(uas=["curl/8.1.2"], reqs=4), 14618, AWS, ipb, C)[:2] == (
        "ban", "script-client-nonres")
    # ① 空 UA + 机房段 → 100%
    assert ia.classify_session(
        "3.2.3.5", mk(uas=[""], reqs=2), 14618, AWS, ipb, C)[:2] == (
        "ban", "script-client-nonres")
    # ① 例外：curl 来自消费 ISP → 不封（住宅开发者不碰）
    v = ia.classify_session("118.149.1.2", mk(uas=["curl/8.1.2"], reqs=1),
                            9790, TD, ipb, C)
    assert v[0] != "ban"
    # ② 攻击工具 UA → 100%（不限 ASN，消费段也封）
    assert ia.classify_session(
        "3.2.3.6", mk(uas=["sqlmap/1.8"], reqs=9), 9790, TD, ipb, C)[:2] == (
        "ban", "attack-tool")
    # ③ 假浏览器零 JS + 探测 + 机房段 → 100%（10-28 SoftLayer Firefox/41 判例）
    s = mk(uas=[FF41], reqs=13, js_assets=0, probe404=12)
    assert ia.classify_session(
        "169.48.104.70", s, 36351, "SOFTLAYER - IBM Cloud, US", ipb, C)[:2] == (
        "ban", "fake-browser-probe-dc")


def test_tiers_welcome():
    # 站主 IP 一票白（哪怕 UA 是 curl、ASN 是机房）
    assert ia.classify_session("47.72.103.104", mk(uas=["curl/8"]), 45102,
                               "Alibaba, US", ipb, C)[0] == "welcome"
    # 官方段 IP 真值优先（UA 是什么都白——misban 同纪律）
    assert ia.classify_session("66.249.73.161", mk(uas=[CHROME_125], reqs=50),
                               15169, "GOOGLE, US", ipb, C)[0] == "welcome"
    # 点名欢迎 UA（Amazonbot 落在 AWS 机房也白）
    assert ia.classify_session(
        "52.203.1.2",
        mk(uas=["Mozilla/5.0 (compatible; Amazonbot/0.1; +https://developer.amazon.com)"],
           reqs=5), 14618, AWS, ipb, C)[0] == "welcome"


def test_tiers_suspect_rcn():
    """RCN 10-28 判例：Chrome/125 拟真（graphql+RSC+49 资产）但 HEAD 突发+爆发
    → 疑似 reality-mismatch，绝不进 100% 线。"""
    s = mk(uas=[CHROME_125], reqs=65, heads=3, graphql=3, rsc=7, js_assets=49,
           first=T0, last=T0 + 60)
    v, rule, _ = ia.classify_session("9.142.174.8", s, 6079, RCN, ipb, C)
    assert (v, rule) == ("suspect", "reality-mismatch")
    # 只有停更、无任何行为信号（消费 ISP 真人老机器弹跳）→ 不报疑似
    s2 = mk(uas=[CHROME_125], reqs=1, js_assets=0)
    v2, _, _ = ia.classify_session("118.149.1.3", s2, 9790, TD, ipb, C)
    assert v2 == "noise"
    # 停更 + 非消费段 + 真实浏览形状 → 疑似 stale-browser（AviationAI 型深链）
    s3 = mk(uas=[CHROME_125], reqs=12, js_assets=30, rsc=2)
    v3, rule3, _ = ia.classify_session("9.151.196.78", s3, 46635,
                                       "AviationAI, US", ipb, C)
    assert (v3, rule3) == ("suspect", "stale-browser")


def test_tiers_suspect_queue_reuse():
    """短链队列复用：停更 + 两 IP 共享同一 /item 入口 → 疑似。"""
    c = ctx(queue_keys={"/zh/item/515b4167-f129": {"9.142.174.8", "9.142.173.96"}})
    s = mk(uas=[CHROME_125], reqs=20, js_assets=20, rsc=2,
           paths=["/zh/item/515b4167-f129"])
    v, rule, ev = ia.classify_session("9.142.174.8", s, 6079, RCN, ipb, c)
    assert (v, rule) == ("suspect", "reality-mismatch")
    assert "短链复用" in ev


def test_tiers_suspect_newbot_and_human():
    # s3：自报 bot 不在欢迎名单（10-28 KeenableBot 判例）
    v, rule, _ = ia.classify_session(
        "34.1.2.3", mk(uas=["Mozilla/5.0 (compatible; KeenableBot/1.0)"], reqs=2),
        396982, "GOOGLE-CLOUD-PLATFORM, US", ipb, C)
    assert (v, rule) == ("suspect", "unknown-bot")
    # 真人铁证：消费 ISP + graphql/RSC/PWA 保真（10-26 判例）
    v2, rule2, _ = ia.classify_session(
        "118.149.1.4", mk(uas=[CHROME_NEW], reqs=40, graphql=2, rsc=5,
                          js_assets=30, pwa=1), 9790, TD, ipb, C)
    assert (v2, rule2) == ("human", "consumer-fidelity")


def test_fleet_check():
    state = {"fleet": {}}
    s = mk(uas=["Mozilla/5.0 (Windows NT 10.0) Chrome/120.0.0.0 Safari/537.36"],
           reqs=2, js_assets=0, images=1, paths=["/zh/dunedin/events/x"])
    for i, ip in enumerate(("2605:e440:3b::25b", "2605:e440:13::3:13f",
                            "89.125.76.24")):
        hit = ia.fleet_check(s, 26383, "ASNET - Baxet Group Inc., US", ipb,
                             ip, state, T0)
        assert hit is (i == 2)      # 第 3 个 IP 凑满 → 触发
    # 形状不符（有 JS 资产）不进舰队
    s2 = mk(uas=[CHROME_NEW], reqs=2, js_assets=2, paths=["/a/b"])
    assert ia.fleet_check(s2, 26383, "ASNET - Baxet Group Inc., US", ipb,
                          "1.2.3.4", state, T0) is False


# ---------------------------------------------------------------- 黑名单机制

def test_expire_bans():
    state = {"banned": {"1.1.1.1": {"until": T0 - 1}, "2.2.2.2": {"until": T0 + 99}}}
    unbanned, changed = ia.expire_bans(state, T0)
    assert unbanned == ["1.1.1.1"] and changed
    assert "1.1.1.1" not in state["banned"] and "2.2.2.2" in state["banned"]


def test_prepare_rule_lifecycle():
    # 无规则 + 有黑名单 → 创建
    rules, ch = ia.prepare_rule([], {"1.1.1.1": {}, "2.2.2.2": {}})
    assert ch and len(rules) == 1
    assert rules[0]["expression"] == "(ip.src in {1.1.1.1 2.2.2.2})"
    assert rules[0]["enabled"] is True and rules[0]["ref"] == ia.RULE_REF
    # 同表达式 → 无变化
    rules2, ch2 = ia.prepare_rule([dict(rules[0])], {"1.1.1.1": {}, "2.2.2.2": {}})
    assert not ch2
    # 清空 → disable 休眠
    rules3, ch3 = ia.prepare_rule([dict(rules[0])], {})
    assert ch3 and rules3[0]["enabled"] is False
    # 空且无规则 → 不动
    rules4, ch4 = ia.prepare_rule([], {})
    assert not ch4 and rules4 == []


def test_sid_stable():
    assert ia.sid_of("reality-mismatch", "9.142.174.8") == \
           ia.sid_of("reality-mismatch", "9.142.174.8")
    assert ia.sid_of("reality-mismatch", "9.142.174.8") != \
           ia.sid_of("unknown-bot", "9.142.174.8")


def test_resolve_target(tmp_path, monkeypatch):
    monkeypatch.setattr(ia, "STATE_FILE", str(tmp_path / "s.json"))
    state = {"suspects": {"ab12cd34": {"ip": "9.142.174.8"}}}
    assert ia.resolve_target(state, "ab12cd34") == ("9.142.174.8",
                                                    state["suspects"]["ab12cd34"])
    assert ia.resolve_target(state, "5.6.7.8") == ("5.6.7.8", None)


def test_load_save_state_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setattr(ia, "STATE_FILE", str(tmp_path / "audit-state.json"))
    st = ia.load_state()
    assert st["banned"] == {} and st["checkpoint"] is None
    st["checkpoint"] = 123
    ia.save_state(st)
    assert ia.load_state()["checkpoint"] == 123
