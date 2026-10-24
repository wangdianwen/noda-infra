#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ip-ban.py 单元测试（2026-10-23 误封 Googlebot 修复 + 2026-10-24 #37
洪水分档/首犯降档的回归防线）

不打真网络：官方网段走内置 fallback 常量 / monkeypatch；XFF/SAFETY/classify
/ 洪水判定全部纯函数级验证。运行：pytest deploy/tests/test_ip_ban.py
"""

import importlib.util
import ipaddress
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_PATH = os.path.join(os.path.dirname(HERE), "ip-ban.py")


def load_ip_ban(monkeypatch, env_file=None, allow_env=None):
    """按需隔离 ENV_FILE / ALLOW_CIDRS 后加载模块（每次全新 import）"""
    if env_file is None:
        env_file = os.path.join(os.path.dirname(HERE), "tests",
                                "nonexistent-ip-ban.env")
    if allow_env is None:
        monkeypatch.delenv("ALLOW_CIDRS", raising=False)
    else:
        monkeypatch.setenv("ALLOW_CIDRS", allow_env)
    spec = importlib.util.spec_from_file_location("ip_ban", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ip_ban"] = mod
    spec.loader.exec_module(mod)
    # 测试环境没有 r4s 的 /etc/noda/ip-ban.env，指到不存在的路径避免读到本机文件
    monkeypatch.setattr(mod, "ENV_FILE", env_file, raising=False)
    return mod


@pytest.fixture
def ip_ban(monkeypatch):
    mod = load_ip_ban(monkeypatch)
    mod._crawler_ip_cache.clear()
    return mod


# ---- ① 官方爬虫段 IP 优先：UA 不含 bot 也 skip（本次误封根因）----

def test_google_ip_without_bot_ua_skips(ip_ban):
    """66.249.73.x + Chrome UA（Prefetch Proxy/真人样式）→ skip，不进枚举统计"""
    ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/153.0.8010.12 Safari/537.36")
    assert ip_ban.classify("66.249.73.10", ua) == "skip"
    assert ip_ban.classify("66.249.73.254", ua) == "skip"
    assert ip_ban.classify("66.249.64.1", ua) == "skip"


def test_google_ip_v6_skips(ip_ban):
    assert ip_ban.classify("2001:4860:4801:10::1234",
                           "Mozilla/5.0 Chrome/153.0") == "skip"


def test_bing_ip_without_bot_ua_skips(ip_ban):
    assert ip_ban.classify("157.55.39.7", "Mozilla/5.0 Chrome/153.0") == "skip"
    assert ip_ban.classify("40.77.167.99", "Mozilla/5.0 Chrome/153.0") == "skip"


def test_prefetch_proxy_ip_outside_json_skips_via_legacy_19(ip_ban):
    """googlebot.json 只发布 crawl IP 的 /27 明细，不含 66.249.84.x（Chrome
    Prefetch Proxy 出口，2026-10 真实日志多级 XFF 出现过）——靠保留的
    66.249.64.0/19 并集兜底 skip，否则同类误封会复发"""
    assert ip_ban.classify("66.249.84.133",
                           "Mozilla/5.0 Chrome/153.0") == "skip"
    assert ip_ban.classify("66.249.90.1", "Mozilla/5.0 Chrome/153.0") == "skip"


def test_safety_rejects_prefetch_proxy_24(ip_ban):
    proposals = {"66.249.84.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_fake_googlebot_outside_ranges_is_bot(ip_ban):
    """UA 自称 Googlebot 但 IP 不在 Google 段 = 伪装，仍计入 bot"""
    assert ip_ban.classify("1.2.3.4",
                           "Mozilla/5.0 (compatible; Googlebot/2.1)") == "bot"


def test_normal_human_still_counted(ip_ban):
    ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/153.0 Safari/537.36")
    assert ip_ban.classify("203.0.113.9", ua) == "human"
    assert ip_ban.classify("203.0.113.9", "curl/8.0") == "bot"


def test_misbanned_googlebot_24_fully_covered_by_fallback(ip_ban):
    """误封的 66.249.73.0/24 全部 256 地址都被内置 fallback 覆盖"""
    nets = ip_ban.GOOGLE_NETS
    for i in range(256):
        a = ipaddress.ip_address("66.249.73.%d" % i)
        assert any(a in n for n in nets), "66.249.73.%d not covered" % i


def test_fallback_snapshot_sizes(ip_ban):
    assert len(ip_ban.GOOGLEBOT_FALLBACK) == 317
    assert len(ip_ban.BINGBOT_FALLBACK) == 28


# ---- ② SAFETY 闸：提案与官方爬虫段 / ALLOW_CIDRS 交集 → 拒绝 ----

def test_safety_rejects_google_range_proposal(ip_ban):
    proposals = {"66.249.73.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_safety_rejects_google_ip_32_proposal(ip_ban):
    proposals = {"66.249.74.129/32": ("single-ip flood 99 req/300s", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_safety_rejects_bing_and_allow_proposals(ip_ban, monkeypatch):
    monkeypatch.setattr(ip_ban, "ALLOW_CIDRS", "150.249.214.0/24")
    proposals = {"157.55.39.0/24": ("24h-enum", 604800),
                 "150.249.214.0/24": ("24h-enum", 604800),
                 "198.51.100.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert list(proposals) == ["198.51.100.0/24"]


def test_safety_keeps_owner_and_normal_proposals(ip_ban):
    proposals = {"47.72.0.0/16": ("24h-enum", 604800)}   # 含站主 IP 47.72.103.104
    ip_ban.apply_safety(proposals)
    assert proposals == {}
    proposals = {"203.0.113.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert list(proposals) == ["203.0.113.0/24"]


# ---- ②b 2026-10-24 Mediapartners-Google 误封判例（209.85.238.0/24）----

def test_mediapartners_google_ip_skips(ip_ban):
    """AdSense 爬虫 209.85.238.x（AS15169，不在 googlebot.json）→ EXTRA /17 兜底"""
    assert ip_ban.classify("209.85.238.129", "Mediapartners-Google") == "skip"
    assert ip_ban.classify(
        "209.85.238.130",
        "Mediapartners-Google (+http://www.google.com/adsense.html)") == "skip"


def test_google_special_crawler_uas_skip_anywhere(ip_ban):
    """无 bot 字样的 Google 特种爬虫 UA 全部 skip（IP 段数据失效也兜住）"""
    for ua in ("Mediapartners-Google",
               "APIs-Google; +https://developers.google.com/",
               "FeedFetcher-Google; +http://www.google.com/feedfetcher.html",
               "Google-Read-Aloud",
               "GoogleOther",
               "Mozilla/5.0 (compatible; Google-Safety; +https://developers"
               ".google.com/search/docs/crawling-indexing/overview-google"
               "-crawlers)"):
        assert ip_ban.classify("203.0.113.77", ua) == "skip", ua


def test_safety_rejects_mediapartners_24(ip_ban):
    proposals = {"209.85.238.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_safety_keeps_gcp_attack_32(ip_ban):
    """/17 加入后 GCP 客户段（34.x/35.x）攻击封禁不得被 SAFETY 误 veto"""
    proposals = {"34.32.24.153/32": ("attack-urls 205 hits + flood", 2592000)}
    ip_ban.apply_safety(proposals)
    assert list(proposals) == ["34.32.24.153/32"]


def test_dc_asns_cover_datacamp_and_proxy_exits(ip_ban):
    """2026-10-24 判例：browser-burst 豁免×2 + Mac-UA 低慢速爬虫出口 =
    AS212238 Datacamp（CDN77/VPN 基础设施）；AS46635/AS62874 = 同族代理出口"""
    assert 212238 in ip_ban.DATACENTER_ASNS
    assert 46635 in ip_ban.DATACENTER_ASNS
    assert 62874 in ip_ban.DATACENTER_ASNS


# ---- ②c 2026-10-25 坚持不懈来访者挑战网（用户三原则 #3）----

def test_line_re_captures_status(ip_ban):
    """事件元组扩为 (ip, path, ua, status)：304 计数依赖状态码捕获"""
    line = ('172.18.0.7 - - [24/Oct/2026:10:00:00 +0000] "GET /a HTTP/1.1" '
            '304 0 "-" "Mozilla/5.0 Chrome/153.0" "203.0.113.9"')
    m = ip_ban.LINE_RE.match(line)
    assert m and m.group(3) == "304" and m.group(5).startswith("Mozilla")
    line2 = line.replace("304 0", "200 10")
    assert ip_ban.LINE_RE.match(line2).group(3) == "200"


def test_scan_window_emits_status(ip_ban, monkeypatch):
    lines = ('172.18.0.7 - - [23/Oct/2026:11:00:00 +0000] "GET /a HTTP/1.1" '
             '200 10 "-" "Mozilla/5.0 Chrome/153.0" "203.0.113.5"\n')

    class FakeOut:
        stdout = lines
        stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *a, **k: FakeOut())
    events = ip_ban.scan_window(0)
    assert events == [("203.0.113.5", "/a", "Mozilla/5.0 Chrome/153.0", "200")]


def test_decide_persistent_four_days_zero_evidence_passes(ip_ban):
    assert ip_ban.decide_persistent(4, 49, 0, 0) is True
    assert ip_ban.decide_persistent(6, 300, 0, 0) is True


def test_decide_persistent_three_days_not_enough(ip_ban):
    assert ip_ban.decide_persistent(3, 60, 0, 0) is False


def test_decide_persistent_low_reqs_not_enough(ip_ban):
    """每天一发的良性拨测（4 天 4 发）不进名单"""
    assert ip_ban.decide_persistent(4, 4, 0, 0) is False


def test_decide_persistent_browser_signals_veto(ip_ban):
    """拉过一次 sw.js/_next = 真浏览器铁证，永不挑战（原则 2）"""
    assert ip_ban.decide_persistent(5, 100, 1, 0) is False


def test_decide_persistent_304_veto(ip_ban):
    """真浏览器缓存校验回源（If-None-Match→304），无头族每天全新上下文永不发"""
    assert ip_ban.decide_persistent(5, 100, 0, 1) is False


def test_persist_key_v6_uses_64(ip_ban):
    assert ip_ban.persist_key("2407:7000:b051:ed00:1465:32ee:5bb:4a6d") \
        == "2407:7000:b051:ed00::/64"
    assert ip_ban.persist_key("203.0.113.9") == "203.0.113.9/32"


def test_build_persist_expression(ip_ban):
    e = ip_ban.build_persist_expression(["203.0.113.9/32", "198.51.100.7/32"])
    assert e.startswith("(ip.src in {203.0.113.9/32 198.51.100.7/32})")
    assert "not cf.client.bot" in e and "47.72.103.104" in e
    assert ip_ban.build_persist_expression([]) == ""


def test_apply_persist_rule_create_update_disable(ip_ban, capsys):
    rules = []
    expr1 = ip_ban.build_persist_expression(["203.0.113.9/32"])
    rules, ch = ip_ban.apply_persist_rule(rules, expr1)
    assert ch and rules[0]["ref"] == ip_ban.PERSIST_MARKER
    assert rules[0]["action"] == "managed_challenge" and rules[0]["enabled"]
    assert "1 IPs" in rules[0]["description"]
    rules, ch = ip_ban.apply_persist_rule(rules, expr1)      # 幂等
    assert ch is False
    expr2 = ip_ban.build_persist_expression(
        ["203.0.113.9/32", "198.51.100.7/32"])
    rules, ch = ip_ban.apply_persist_rule(rules, expr2)      # 更新
    assert ch and "2 IPs" in rules[0]["description"]
    rules, ch = ip_ban.apply_persist_rule(rules, "")         # 名单空 → disable
    assert ch and rules[0]["enabled"] is False
    rules, ch = ip_ban.apply_persist_rule(rules, "")         # 再空 → 不动
    assert ch is False


# ---- ③ 多级 XFF：取 CF 追加的最后一跳，非法跳过不崩溃 ----

def test_xff_multihop_takes_last(ip_ban):
    assert ip_ban.client_ip_from_xff("63.141.225.35,66.249.84.133") \
        == "66.249.84.133"
    assert ip_ban.client_ip_from_xff(" 1.2.3.4 , 5.6.7.8 ") == "5.6.7.8"


def test_xff_single_and_invalid(ip_ban):
    assert ip_ban.client_ip_from_xff("66.249.74.129") == "66.249.74.129"
    assert ip_ban.client_ip_from_xff("-") is None
    assert ip_ban.client_ip_from_xff("") is None
    assert ip_ban.client_ip_from_xff("garbage") is None
    assert ip_ban.client_ip_from_xff("unknown, 203.0.113.5") == "203.0.113.5"


def test_scan_window_survives_multihop_xff(ip_ban, monkeypatch):
    """修前该输入让 ip_address() 抛 ValueError 整轮崩溃（ip-ban.log L1038-1078）"""
    lines = (
        '172.18.0.7 - - [23/Oct/2026:11:00:00 +0000] "GET /a HTTP/1.1" 200 10 '
        '"-" "Mozilla/5.0 Chrome/153.0" "63.141.225.35,66.249.84.133"\n'
        '172.18.0.7 - - [23/Oct/2026:11:00:01 +0000] "GET /b HTTP/1.1" 200 10 '
        '"-" "Mozilla/5.0 Chrome/153.0" "-"\n'
        '172.18.0.7 - - [23/Oct/2026:11:00:02 +0000] "GET /c HTTP/1.1" 200 10 '
        '"-" "curl/8.0" "203.0.113.5"\n'
    )

    class FakeOut:
        stdout = lines
        stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *a, **k: FakeOut())
    events = ip_ban.scan_window(0)
    assert [e[0] for e in events] == ["66.249.84.133", "203.0.113.5"]


# ---- ④ ALLOW_CIDRS 硬白名单 ----

def test_allow_cidrs_from_env(ip_ban, monkeypatch):
    monkeypatch.setattr(ip_ban, "ALLOW_CIDRS", "150.249.214.0/24")
    assert ip_ban.classify("150.249.214.99", "Mozilla/5.0 Chrome/153.0") \
        == "whitelist"
    assert ip_ban.classify("150.249.215.1", "curl/8.0") == "bot"  # 段外不受影响


def test_allow_cidrs_read_from_env_file(monkeypatch, tmp_path):
    env = tmp_path / "ip-ban.env"
    env.write_text("DOPPLER_SERVICE_TOKEN=xxx\nALLOW_CIDRS=150.249.214.0/24\n")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    assert mod.env_settings()["ALLOW_CIDRS"] == "150.249.214.0/24"
    assert [str(n) for n in mod.allow_nets()] == ["150.249.214.0/24"]
    assert mod.classify("150.249.214.1", "curl/8.0") == "whitelist"


def test_invalid_cidrs_logged_and_dropped(ip_ban, monkeypatch):
    monkeypatch.setattr(ip_ban, "ALLOW_CIDRS", "not-a-cidr, ,192.0.2.0/24")
    nets = ip_ban.allow_nets()
    assert [str(n) for n in nets] == ["192.0.2.0/24"]


# ---- ⑤ load_crawler_ranges：缓存回写/命中 + 下载失败回退 ----

GOOGLE_JSON = ('{"prefixes":[{"ipv4Prefix":"66.249.64.0/19"},'
               '{"ipv6Prefix":"2001:4860:4801:10::/64"}]}')
BING_JSON = '{"prefixes":[{"ipv4Prefix":"157.55.39.0/24"}]}'


def test_ranges_download_cache_and_fallback(monkeypatch, tmp_path):
    env = tmp_path / "ip-ban.env"
    env.write_text("")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    cache = tmp_path / "net-ranges.json"
    monkeypatch.setattr(mod, "RANGES_CACHE", str(cache))
    urls = {mod.GOOGLEBOT_URL: GOOGLE_JSON, mod.BINGBOT_URL: BING_JSON}
    monkeypatch.setattr(mod, "fetch_text",
                        lambda url, timeout=15: urls[url])
    mod.load_crawler_ranges()                       # 首次：下载 + 写缓存
    assert len(mod.GOOGLE_NETS) == 2 and len(mod.BING_NETS) == 1
    assert cache.exists()

    def boom(url, timeout=15):
        raise OSError("network down")

    monkeypatch.setattr(mod, "fetch_text", boom)
    mod.load_crawler_ranges()                       # 缓存 24h 内：不再联网
    assert len(mod.GOOGLE_NETS) == 2 and len(mod.BING_NETS) == 1

    cache.unlink()                                  # 缓存删掉 + 断网 → 内置快照
    mod.load_crawler_ranges()
    assert mod.GOOGLE_NETS == [ipaddress.ip_network(c)
                               for c in mod.GOOGLEBOT_FALLBACK]
    assert mod.BING_NETS == [ipaddress.ip_network(c)
                             for c in mod.BINGBOT_FALLBACK]


def test_stale_cache_triggers_refetch(monkeypatch, tmp_path):
    import json as _json
    import time as _time
    env = tmp_path / "ip-ban.env"
    env.write_text("")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    cache = tmp_path / "net-ranges.json"
    stale = {"fetched_at": int(_time.time()) - 2 * mod.RANGES_CACHE_TTL,
             "googlebot": ["66.249.64.0/19"], "bingbot": ["157.55.39.0/24"]}
    cache.write_text(_json.dumps(stale))
    monkeypatch.setattr(mod, "RANGES_CACHE", str(cache))
    calls = []

    def fake_fetch(url, timeout=15):
        calls.append(url)
        return GOOGLE_JSON if "googlebot" in url else BING_JSON

    monkeypatch.setattr(mod, "fetch_text", fake_fetch)
    mod.load_crawler_ranges()
    assert len(calls) == 2                           # 过期 → 重新下载


def test_parse_prefix_json_key_styles(ip_ban):
    assert ip_ban.parse_prefix_json(GOOGLE_JSON) == [
        "66.249.64.0/19", "2001:4860:4801:10::/64"]
    assert ip_ban.parse_prefix_json(
        '{"prefixes":[{"ipv4-prefix":"192.0.2.0/24"}]}') == ["192.0.2.0/24"]


# ---- ⑥ 向后兼容：老 state 结构原样可读 ----

def test_old_state_shape_untouched(ip_ban, monkeypatch, tmp_path):
    import json as _json
    state = tmp_path / "state.json"
    state.write_text(_json.dumps({
        "bans": {"203.0.113.0/24": {"until": 9999999999, "banned_at": 1,
                                    "reason": "24h-enum", "ttl": 604800}},
        "tracks": {"203.0.113.0/24": [[1, "203.0.113.1", 0, 0, "/x"]]},
        "last_run": 123, "unsynced": []}))
    monkeypatch.setattr(ip_ban, "STATE_FILE", str(state))
    s = ip_ban.load_state()
    assert set(s) == {"bans", "tracks", "last_run", "unsynced"}
    assert "203.0.113.0/24" in s["bans"]


# ---- ⑦ #37 /32 洪水分档阈值 + 首犯降档/复犯升级（误封 136.70.78.248 修复）----

NOW = 1790000000                        # 固定 epoch，测首犯/复犯 7 天窗口


def test_flood32_browser_tier_90req_not_banned(ip_ban):
    """今晨误封场景：零 bot-UA+零攻击 90req/216s（快速翻页真人）→ 不封"""
    assert ip_ban.decide_flood32(90, 0, 0, 0, 0, NOW, 216) is None


def test_flood32_browser_tier_edge_299_not_banned(ip_ban):
    """浏览器档阈值边贴：299（<300）仍不封"""
    assert ip_ban.decide_flood32(299, 0, 0, 0, 0, NOW, 300) is None


def test_flood32_browser_tier_350_first_ban_1day(ip_ban):
    """零 bot-UA+零攻击 350req → 封 1 天，reason 带 browser-tier/first"""
    reason, ttl = ip_ban.decide_flood32(350, 0, 0, 0, 0, NOW, 300)
    assert ttl == ip_ban.BAN_TTL_FIRST == 24 * 3600
    assert "browser-tier" in reason and "first" in reason
    assert "350 req/300s" in reason


def test_flood32_repeat_within_7d_upgraded_7day(ip_ban):
    """同 cidr 7 天内二次洪水 → 升 7 天（复犯标记）"""
    reason, ttl = ip_ban.decide_flood32(350, 0, 0, 0, NOW - 24 * 3600,
                                        NOW, 300)
    assert ttl == ip_ban.BAN_TTL == 7 * 24 * 3600
    assert "repeat" in reason


def test_flood32_prior_over_7d_counts_as_first(ip_ban):
    """前科超过 7 天 → 重新按首犯 1 天"""
    reason, ttl = ip_ban.decide_flood32(350, 0, 0, 0, NOW - 8 * 24 * 3600,
                                        NOW, 300)
    assert ttl == 24 * 3600 and "first" in reason


def test_flood32_mixed_botua_90req_still_60_tier(ip_ban):
    """混 1 条 bot-UA 90req → 仍按 60 严档封（首犯 1 天）"""
    reason, ttl = ip_ban.decide_flood32(90, 1, 0, 0, 0, NOW, 216)
    assert ttl == 24 * 3600
    assert "strict-tier" in reason and "first" in reason


def test_flood32_sub_threshold_botua_not_banned(ip_ban):
    """夹 bot-UA 但不足严档阈值（59<60）→ 不封"""
    assert ip_ban.decide_flood32(59, 1, 0, 0, 0, NOW, 300) is None


def test_flood32_attack_history_below_min_blocks_browser_tier(ip_ban):
    """6h 内 1-4 次攻击命中（不够 30d 线）→ 不享受浏览器档，按 60 严档"""
    reason, ttl = ip_ban.decide_flood32(90, 0, 0, 2, 0, NOW, 216)
    assert ttl == 24 * 3600 and "strict-tier" in reason


def test_flood32_attack_min_30d_unchanged(ip_ban):
    """attack≥5 → 30d 不变（夹 bot-UA 形态）"""
    reason, ttl = ip_ban.decide_flood32(90, 1, 0, 5, 0, NOW, 216)
    assert ttl == ip_ban.ATTACK_TTL == 30 * 24 * 3600
    assert reason.startswith("attack-urls")


def test_flood32_attack_priority_over_browser_shape(ip_ban):
    """零 bot-UA + 攻击≥5 → 仍 30d（攻击优先级最高，不进浏览器档）"""
    reason, ttl = ip_ban.decide_flood32(90, 0, 0, 5, 0, NOW, 216)
    assert ttl == 30 * 24 * 3600 and reason.startswith("attack-urls")


def test_attack_re_wp_probe_paths(ip_ban):
    """2026-10-24 判例：WP 扫描器 20 发 wlwmanifest/xmlrpc/wp-includes 探测
    全 404 溜走（旧规则只认 wp-config/content/login）→ 三类路径必须命中"""
    assert ip_ban.ATTACK_RE.search("/wp-includes/wlwmanifest.xml")
    assert ip_ban.ATTACK_RE.search("//blog/wp-includes/wlwmanifest.xml")
    assert ip_ban.ATTACK_RE.search("//xmlrpc.php?rsd")
    assert ip_ban.ATTACK_RE.search("/wp-includes/js/jquery/jquery.js")
    # 老模式不回归
    assert ip_ban.ATTACK_RE.search("/wp-login.php")
    assert ip_ban.ATTACK_RE.search("/wp-config.php.bak")
    # 正常业务路径不误伤
    assert not ip_ban.ATTACK_RE.search("/auckland/places/hidden-gems")
    assert not ip_ban.ATTACK_RE.search("/zh/item/4396be16-f8db")


def test_flood32_browser_exempt_unchanged(ip_ban):
    """signals≥3+零 bot-UA → exempt 不变（WARP 事件教训；超浏览器档阈值也豁免）"""
    assert ip_ban.decide_flood32(90, 0, 3, 0, 0, NOW, 216) is None
    assert ip_ban.decide_flood32(400, 0, 3, 0, NOW - 24 * 3600, NOW, 300) is None


def test_flood32_botua_disables_exempt(ip_ban):
    """有 bot-UA 时生命周期信号不构成豁免（豁免要求零 bot-UA）"""
    reason, ttl = ip_ban.decide_flood32(90, 1, 3, 0, 0, NOW, 216)
    assert ttl == 24 * 3600          # 严档封禁而非豁免


# ---- 机房 ASN 常驻规则（2026-10-24 #38，GA4 低慢速分布式爬虫，用户裁定）----

def test_dc_expression_has_asns_and_all_exemptions(ip_ban, monkeypatch):
    """表达式=ASN 集 + cf.client.bot 主闸 + 66.249.64.0/19 兜底 + 站主 + ALLOW_CIDRS"""
    monkeypatch.setattr(ip_ban, "OWNER_IPS", {"1.2.3.4"})
    expr = ip_ban.build_dc_expression(ip_ban.parse_cidrs("5.6.7.0/24"))
    for asn in ip_ban.DATACENTER_ASNS:
        assert str(asn) in expr
    assert "not cf.client.bot" in expr
    assert "66.249.64.0/19" in expr
    assert "1.2.3.4" in expr and "5.6.7.0/24" in expr


def test_dc_asns_cover_observed_bot_clouds(ip_ban):
    """10-24 实证出口（AWS Ashburn/San Jose/Santa Clara + GCP 等）必须在封禁集内"""
    assert {16509, 14618, 396982, 8075, 24940} <= set(ip_ban.DATACENTER_ASNS)
    # 10-24 中午实证换出口：EGIHosting AS18779（192.177.143.202，名单外畅通一波）
    assert 18779 in ip_ban.DATACENTER_ASNS


def test_dc_rule_create_noop_update(ip_ban):
    """首轮创建→同表达式幂等→表达式漂移（含 Dashboard 手改）触发更新"""
    rules, changed = ip_ban.apply_dc_rule([], "EXPR")
    assert changed and len(rules) == 1
    assert rules[0]["ref"] == ip_ban.DC_MARKER
    assert rules[0]["action"] == ip_ban.DC_ACTION
    assert rules[0]["enabled"] is True
    rules2, changed = ip_ban.apply_dc_rule(rules, "EXPR")
    assert not changed and len(rules2) == 1
    stale = [dict(rules2[0], expression="dashboard-edited", action="block")]
    rules3, changed = ip_ban.apply_dc_rule(stale, "EXPR")
    assert changed and rules3[0]["expression"] == "EXPR"
    assert rules3[0]["action"] == ip_ban.DC_ACTION and rules3[0]["enabled"] is True


def test_dc_managed_challenge_not_block(ip_ban):
    """action 必须 managed_challenge（云上真人可过挑战，误伤面最小——用户裁定的
    「不误伤」边界延伸到非 Google 的机房真人出口）"""
    assert ip_ban.DC_ACTION == "managed_challenge"


def test_dc_expression_exempts_selfid_ai_crawlers(ip_ban):
    """UA 自报家门豁免:Amazonbot(实测 34 req 全 AWS 段)与 ChatGPT-User(GEO 漏斗)
    必须豁免;原始 800x600 爬虫的纯 Chrome UA 不含任何豁免串,仍被挑战"""
    expr = ip_ban.build_dc_expression(ip_ban.parse_cidrs(""))
    assert 'contains "Amazonbot"' not in expr      # 不点名,走通用 bot 串
    assert 'contains "bot"' in expr and 'contains "Bot"' in expr
    assert 'contains "ChatGPT-User"' in expr
    assert 'contains "Claude-User"' in expr
    assert 'contains "Perplexity-User"' in expr
    # issue #3 ②：MistralAI-User / cohere-ai 同为无 bot 字样的 "-User" 系 GEO 漏斗
    assert 'contains "MistralAI-User"' in expr
    assert 'contains "cohere-ai"' in expr
    # 原爬虫 UA 不命中任何豁免串(教义回归:Chrome 串里无 bot/spider/slurp/crawler/-User)
    chrome_ua = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
                 " (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
    assert not any(u.lower() in chrome_ua.lower() for u in ip_ban.DC_UA_EXEMPTS)


# ---- 封禁后源站验证（2026-10-24 执行缺口判例：13:50 封禁后出口仍打穿 CF 15 分钟，
# 人肉看日志才发现——此功能把该发现自动化为 TG 告警）----

def _ev(ip):
    return (ip, "/x", "curl/8.7.1", "200")


def test_verify_first_cycle_skips_preban_traffic(ip_ban):
    """新封禁当轮不计数：当轮 events 还含封禁前流量，直接计数=假告警"""
    logs = []
    ev = [_ev("185.177.72.69")] * 50
    verify, alerts = ip_ban.step_verification({}, ev, [("185.177.72.69/32", "flood", 86400)], logs.append)
    assert alerts == [] and not verify["185.177.72.69/32"]["alerted"]
    assert "skip_first" not in verify["185.177.72.69/32"]      # 已消费
    assert verify["185.177.72.69/32"]["hits"] == 0


def test_verify_alerts_when_banned_ip_still_hits(ip_ban):
    """观察窗内被封 IP 仍现于源站日志 = 执行缺口，本轮必须告警"""
    logs = []
    verify, _ = ip_ban.step_verification({}, [], [("9.9.9.9/32", "flood", 86400)], logs.append)
    ev = [_ev("9.9.9.9")] * 7
    verify2, alerts = ip_ban.step_verification(verify, ev, [], logs.append)
    assert len(alerts) == 1 and "9.9.9.9" in alerts[0] and "7 次" in alerts[0]
    assert verify2["9.9.9.9/32"]["alerted"] and verify2["9.9.9.9/32"]["hits"] == 7


def test_verify_expires_clean_after_window(ip_ban, capsys):
    """观察窗 VERIFY_CYCLES 轮走完且零命中 → 出队 + 干净总结日志"""
    logs = []
    verify, _ = ip_ban.step_verification({}, [], [("9.9.9.9/32", "flood", 86400)], logs.append)
    for _ in range(ip_ban.VERIFY_CYCLES):
        verify, alerts = ip_ban.step_verification(verify, [_ev("8.8.8.8")], [], logs.append)
    assert alerts == [] and "9.9.9.9/32" not in verify
    assert any("观察窗干净" in l for l in logs)


def test_verify_end_reports_enforcement_gap(ip_ban):
    """窗内告警过 → 出队总结必须点明执行缺口"""
    logs = []
    verify, _ = ip_ban.step_verification({}, [], [("9.9.9.9/32", "flood", 86400)], logs.append)
    verify, _ = ip_ban.step_verification(verify, [_ev("9.9.9.9")], [], logs.append)
    for _ in range(ip_ban.VERIFY_CYCLES - 1):
        verify, _ = ip_ban.step_verification(verify, [], [], logs.append)
    assert any("执行缺口" in l for l in logs) and "9.9.9.9/32" not in verify


def test_verify_counts_whole_cidr_not_exact_ip(ip_ban):
    """/24 封禁：网段内任一出口命中都算（换出口重试也逃不掉）"""
    verify, _ = ip_ban.step_verification({}, [], [("203.0.113.0/24", "attack", 86400)], lambda m: None)
    _verify, alerts = ip_ban.step_verification(verify, [_ev("203.0.113.55")], [], lambda m: None)
    assert len(alerts) == 1 and "203.0.113.55" not in alerts[0]  # 告警按 CIDR 口径


def test_verify_tolerates_legacy_state_without_key(ip_ban):
    """旧 state JSON 无 verify 键 → main 用 .get 兜底，此处验证空字典直入不炸"""
    verify, alerts = ip_ban.step_verification({}, [], [], lambda m: None)
    assert verify == {} and alerts == []


def test_get_rules_tolerates_missing_entrypoint(ip_ban, monkeypatch):
    """shuotong.wang 首次同步时 custom phase 无 entrypoint ruleset(GET 404)
    → 返回空列表让 PUT 自动创建,不得抛异常卡死整轮同步"""
    import urllib.error
    def fake_http_json(url, token, **kw):
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
    monkeypatch.setattr(ip_ban, "http_json", fake_http_json)
    assert ip_ban.get_rules("tok", "zoneid") == []
