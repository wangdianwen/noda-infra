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


def test_chrome_private_prefetch_proxy_v6_skips(ip_ban):
    """2001:4860:7::/48（Chrome 私密预取代理/SERP 预取出口，ARIN 2001:4800::/23
    Google LLC）不在 googlebot.json——2026-11-01 判例：persist 惯犯网把
    2001:4860:7:40b::/64 列入挑战名单（源站 14 req 全 referer google.com、
    真实内容页、零攻击信号），同族 :50b/:80b 在档案 3/4 天排队。预取代理
    天生零 PWA 信号+零 304+多日重复，persist 三铁证恰是它的正常形状。"""
    ua = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36")
    assert ip_ban.classify("2001:4860:7:40b::ff", ua) == "skip"
    assert ip_ban.classify("2001:4860:7:50b::ff", ua) == "skip"
    assert ip_ban.classify("2001:4860:7:80b::1", ua) == "skip"
    # SAFETY 闸镜像：同段提案必须被拒，防止任何通道再封进 Google 预取段
    assert "2001:4860:7:40b::/64" not in ip_ban.apply_safety(
        {"2001:4860:7:40b::/64": ("x", 60)})


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
    AS212238 Datacamp（CDN77/VPN 基础设施）；AS46635/AS62874 = 同族代理出口；
    AS211590 Bucklog = 800x600 家族出口（10-25 黑名单精简轮补）"""
    assert 212238 in ip_ban.DATACENTER_ASNS
    assert 46635 in ip_ban.DATACENTER_ASNS
    assert 62874 in ip_ban.DATACENTER_ASNS
    assert 211590 in ip_ban.DATACENTER_ASNS


def test_dc_asns_cover_hk_datacenter_batch(ip_ban):
    """2026-11-18 判例：45.138.12.6/.16（AS218785 TC DATACENTER，HK 机房）真
    Chrome/133 Linux UA 解掉 managed_challenge 后打 /.git/.svn/.hg 密探路径
    （attack-urls 8/11 hits）。用户裁定「香港机房全部加入黑名单」：RIPE+APNIC
    delegated 全量 1385 ASN 筛查出 216 个机房/托管 ASN 入滥用分支"""
    assert 218785 in ip_ban.DATACENTER_ASNS        # 本案主犯 TC DATACENTER
    assert 132839 in ip_ban.DATACENTER_ASNS        # POWER LINE DATACENTER
    assert 135377 in ip_ban.DATACENTER_ASNS        # UCloud HK
    assert 23881 in ip_ban.DATACENTER_ASNS         # UDomain Web Hosting
    # 住宅/固网 ISP 不得混入（Towngas 固网有真家庭用户；Juniper=厂商网）
    assert 9899 not in ip_ban.DATACENTER_ASNS
    assert 10098 not in ip_ban.DATACENTER_ASNS
    assert 10132 not in ip_ban.DATACENTER_ASNS
    assert 24023 not in ip_ban.DATACENTER_ASNS


def test_dc_expression_hk_batch_in_abuse_branch_and_length_guard(ip_ban):
    """HK 批落滥用分支（无 UA 豁免）；234+13 ASN 后表达式仍须低于 CF 4096
    上限——Free 版 5 条规则配额已满，机房 ASN 只能挤单条 DC 规则，越限即死"""
    expr = ip_ban.build_dc_expression(ip_ban.parse_cidrs(""))
    parts = expr.split(") or (")
    assert len(parts) == 2                          # 无 persist 名单=恰好两支
    abuse = parts[0]
    assert "218785" in abuse and "132839" in abuse
    assert len(expr) < 4096


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
             '200 10 "-" "Mozilla/5.0 Chrome/153.0" "203.0.113.5"\n'
             '172.18.0.7 - - [23/Oct/2026:11:00:01 +0000] "GET /b HTTP/1.1" '
             '403 0 "https://www.google.com/" "Mozilla/5.0 Chrome/156.0" '
             '"198.51.100.7"\n')

    class FakeOut:
        stdout = lines
        stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *a, **k: FakeOut())
    events = ip_ban.scan_window(0)
    # #18 起事件元组扩为 (ip, path, ua, status, referer)——tripwire 取证需要
    assert events == [("203.0.113.5", "/a", "Mozilla/5.0 Chrome/153.0",
                       "200", "-"),
                      ("198.51.100.7", "/b", "Mozilla/5.0 Chrome/156.0",
                       "403", "https://www.google.com/")]


def test_decide_persistent_four_days_zero_evidence_passes(ip_ban):
    assert ip_ban.decide_persistent(4, 49, 0, 0) is True
    assert ip_ban.decide_persistent(6, 180, 0, 0) is True
    assert ip_ban.decide_persistent(4, 40, 0, 0) is True   # 新门槛边界


def test_decide_persistent_three_days_not_enough(ip_ban):
    assert ip_ban.decide_persistent(3, 60, 0, 0) is False


def test_decide_persistent_low_reqs_not_enough(ip_ban):
    """真人忠实用户：1-3 条源站请求/天 × 4 天（资产全走缓存）远低于 40 门槛"""
    assert ip_ban.decide_persistent(4, 12, 0, 0) is False
    assert ip_ban.decide_persistent(4, 4, 0, 0) is False


def test_decide_persistent_browser_signals_veto(ip_ban):
    """PWA 生命周期端点（sw.js/manifest）任一命中 = 真人铁证，永不挑战"""
    assert ip_ban.decide_persistent(5, 100, 1, 0) is False


def test_decide_persistent_304_veto(ip_ban):
    """真浏览器缓存校验回源（If-None-Match→304），无头族每天全新上下文永不发"""
    assert ip_ban.decide_persistent(5, 100, 0, 1) is False


def test_persist_veto_re_excludes_next_includes_pwa(ip_ban):
    """2026-10-25 实测：爬虫家族 _next/static×89+geo.json×3 但 sw.js/manifest 零
    触碰——否决信号必须只认 PWA 生命周期，含 _next 会把目标家族反向豁免掉"""
    r = ip_ban.PERSIST_VETO_RE
    assert r.search("/sw.js") and r.search("/manifest.webmanifest")
    assert r.search("/zh/manifest.json")
    assert not r.search("/_next/static/chunks/xyz.js")
    assert not r.search("/geo.json")
    assert not r.search("/zh/__next/whatever")


def test_classify_platform_preview_fetchers_skip(ip_ban):
    """平台链接预览抓取器（无 bot 字样）= 守规矩爬虫，不入任何机器判定（原则①）。
    2026-10-25 实测 Meta 2a03:2880::/32 的 facebookexternalhit 已混入 persist 档案"""
    for ua in ("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
               "meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)",
               "WhatsApp/2.23.20.0",
               "TelegramLike/4.0",
               "SkypeUriPreview Preview/0.5"):
        assert ip_ban.classify("203.0.113.77", ua) == "skip", ua


def test_dc_expression_within_cf_limit_at_persist_cap(ip_ban):
    """dc 规则单表达式 CF 上限 4095 字符：名单打满 MAX_PERSIST_LIST 个最长形态
    条目（persist_key 产出的压缩 /64=24 字符是真实上界）仍须留余量。
    回归：Free 版 5 条规则上限判例的同族防线。"""
    worst_v6 = "2a02:8071:22a1:a981::/64"        # 4 满组+/64=压缩形态最长 24 字符
    e = ip_ban.build_dc_expression(
        [], persist_cidrs=[worst_v6] * ip_ban.MAX_PERSIST_LIST)
    assert len(e) < 4095 - 200, len(e)   # 200 字符安全余量


def test_persist_key_v6_uses_64(ip_ban):
    assert ip_ban.persist_key("2407:7000:b051:ed00:1465:32ee:5bb:4a6d") \
        == "2407:7000:b051:ed00::/64"
    assert ip_ban.persist_key("203.0.113.9") == "203.0.113.9/32"


def test_build_persist_expression_merged_into_dc(ip_ban):
    """Free 版自定义规则上限 5 条（实测 "6 out of 5"）→ 挑战名单并入 dc 规则"""
    e = ip_ban.build_dc_expression([], persist_cidrs=["203.0.113.9/32",
                                                      "2407:7000:b051:ed00::/64"])
    assert ") or (ip.src in {203.0.113.9/32" in e
    assert "2407:7000:b051:ed00::/64} and not cf.client.bot" in e
    # 子句独立豁免：cf.client.bot + 站主
    tail = e.split(") or (ip.src in")[1]
    assert "not cf.client.bot" in tail and "47.72.103.104" in tail
    # 名单空 → 与老表达式完全一致
    assert ip_ban.build_dc_expression([], persist_cidrs=None) \
        == ip_ban.build_dc_expression([], persist_cidrs=[])


def test_apply_dc_rule_carries_persist_clause(ip_ban):
    rules = []
    expr = ip_ban.build_dc_expression([], persist_cidrs=["203.0.113.9/32"])
    rules, ch = ip_ban.apply_dc_rule(rules, expr)
    assert ch and rules[0]["action"] == ip_ban.DC_ACTION
    rules, ch = ip_ban.apply_dc_rule(rules, expr)            # 幂等
    assert ch is False
    expr2 = ip_ban.build_dc_expression([])                    # 名单清空 → 更新
    rules, ch = ip_ban.apply_dc_rule(rules, expr2)
    assert ch and "or (ip.src in" not in rules[0]["expression"]


# ---- CDN 图片防盗链子句（2026-11-07，并入 dc 规则）----

def test_hotlink_clause_structure(ip_ban):
    """host 定界 cdn.noda.co.nz + 三重豁免（空 Referer/cf.client.bot/白名单域）"""
    e = ip_ban.HOTLINK_CLAUSE
    assert 'http.host eq "cdn.noda.co.nz"' in e
    assert "http.referer ne" in e                      # 空 Referer 放行
    assert "not cf.client.bot" in e                    # 验证爬虫放行（原则①）
    for allow in ip_ban.HOTLINK_REFERER_ALLOW:
        assert 'lower(http.referer) contains "%s"' % allow in e, allow


def test_hotlink_referer_allowlist_covers_own_and_search_domains(ip_ban):
    """自家 apex+子域与主流搜索引擎转介域的 contains 锚都命中（模拟 Referer 值）"""
    import re as _re
    clause = ip_ban.HOTLINK_CLAUSE
    markers = ip_ban.HOTLINK_REFERER_ALLOW
    for ref in ("https://noda.co.nz/zh",
                "https://www.noda.co.nz/",
                "https://nearby.noda.co.nz/places/xyz",
                "https://www.google.com/search?q=x",
                "https://www.google.co.nz/imghp",
                "https://www.bing.com/images",
                "https://image.baidu.com/detail",
                "https://pic.sogou.com/pics",
                "https://duckduckgo.com/?q=x",
                "https://nz.yahoo.com/"):
        lo = ref.lower()
        assert any(m in lo for m in markers), ref
    # 结构自检：这些 referer 都会命中子句里的豁免 contains（防锚写错）
    for m in markers:
        assert m in clause


def test_hotlink_clause_not_in_dc_expression(ip_ban):
    """防盗链 2026-11-07 升格独立规则后，dc 表达式不得再携带（防止双份/占用配额）"""
    assert "cdn.noda.co.nz" not in ip_ban.build_dc_expression([])
    assert "http.referer" not in ip_ban.build_dc_expression(
        [], persist_cidrs=["203.0.113.9/32"])


def test_apply_hotlink_rule_creates_adopts_and_heals(ip_ban):
    """创建/收养/自愈三形态：无规则→创建；CF 上已有同 ref 规则（API 预建）→
    收养不重复；表达式被手改漂移→拉回"""
    # 创建
    rules, ch = ip_ban.apply_hotlink_rule([])
    assert ch and len(rules) == 1 and rules[0]["ref"] == ip_ban.HOTLINK_MARKER
    assert rules[0]["action"] == "block" and rules[0]["expression"] \
        == ip_ban.HOTLINK_CLAUSE
    # 幂等
    rules, ch = ip_ban.apply_hotlink_rule(rules)
    assert ch is False and len(rules) == 1
    # 收养：CF 上预建的规则（ref 同 marker，description 同文）→ 不新建
    adopted = [{"ref": ip_ban.HOTLINK_MARKER, "action": "block",
                "expression": ip_ban.HOTLINK_CLAUSE, "enabled": True,
                "description": "cdn-hotlink-block (Referer anti-hotlink; managed by ip-ban.py)"}]
    rules, ch = ip_ban.apply_hotlink_rule(adopted)
    assert ch is False and len(adopted) == 1
    # 自愈：表达式被手改 → 拉回原表达式
    drifted = [dict(adopted[0], expression='http.host eq "cdn.noda.co.nz"')]
    rules, ch = ip_ban.apply_hotlink_rule(drifted)
    assert ch and rules[0]["expression"] == ip_ban.HOTLINK_CLAUSE


def test_hotlink_clause_matches_cf_deployed_rule(ip_ban):
    """代码生成的表达式与 CF 线上 453cd99e 的 expression 逐字节一致（收养不漂移）。
    线上快照 2026-11-07 上线时固化；若本测试失败=有人改了豁免名单，需同步重发 CF。"""
    deployed = ('(http.host eq "cdn.noda.co.nz" and http.referer ne "" '
                "and not cf.client.bot and not ("
                + " or ".join('lower(http.referer) contains "%s"' % s
                              for s in ip_ban.HOTLINK_REFERER_ALLOW) + "))")
    assert ip_ban.HOTLINK_CLAUSE == deployed


# ---- /24 枚举闸 OR→AND 修正（2026-10-25 复盘）----

def test_enum24_google_case_not_banned(ip_ban):
    """Mediapartners 判例复盘：高资源(76%)+多路径 → 不再封"""
    assert ip_ban.decide_enum24(42, 6, 32, 0, {"p%d" % i for i in range(35)}) is False


def test_enum24_real_user_shared_exit_not_banned(ip_ban):
    """日本家宽判例复盘：真人共享出口（高资源、多路径、botua 0）→ 不封"""
    assert ip_ban.decide_enum24(60, 5, 45, 0, {"p%d" % i for i in range(25)}) is False


def test_enum24_pure_page_crawler_banned(ip_ban):
    assert ip_ban.decide_enum24(42, 3, 1, 0, {"p%d" % i for i in range(35)}) is True


def test_enum24_script_ua_enumerator_banned(ip_ban):
    assert ip_ban.decide_enum24(40, 3, 4, 20, {"p%d" % i for i in range(15)}) is True


def test_enum24_low_paths_or_low_hits_or_few_ips_not_banned(ip_ban):
    assert ip_ban.decide_enum24(40, 3, 1, 0, {"p%d" % i for i in range(10)}) is False
    assert ip_ban.decide_enum24(30, 3, 1, 0, {"p%d" % i for i in range(30)}) is False
    assert ip_ban.decide_enum24(40, 2, 1, 0, {"p%d" % i for i in range(30)}) is False


def test_bingbot_spoof_outside_ranges_is_bot(ip_ban):
    """假 bingbot（IP 不在 bing 段）必须归 bot 计数，不得借 SELFID "bot" 溜成 skip"""
    assert ip_ban.classify("1.2.3.4",
                           "Mozilla/5.0 (compatible; bingbot/2.0)") == "bot"


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
OAI_JSON = '{"prefixes":[{"ipv4Prefix":"40.67.175.0/25"},{"ipv4Prefix":"20.169.77.0/25"}]}'


def test_ranges_download_cache_and_fallback(monkeypatch, tmp_path):
    env = tmp_path / "ip-ban.env"
    env.write_text("")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    cache = tmp_path / "net-ranges.json"
    monkeypatch.setattr(mod, "RANGES_CACHE", str(cache))
    urls = {mod.GOOGLEBOT_URL: GOOGLE_JSON, mod.BINGBOT_URL: BING_JSON,
            mod.OAI_URL: OAI_JSON}
    monkeypatch.setattr(mod, "fetch_text",
                        lambda url, timeout=15: urls[url])
    mod.load_crawler_ranges()                       # 首次：下载 + 写缓存
    assert len(mod.GOOGLE_NETS) == 2 and len(mod.BING_NETS) == 1
    assert mod.OAI_NETS == [ipaddress.ip_network(c)
                            for c in ("40.67.175.0/25", "20.169.77.0/25")]
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
    assert mod.OAI_NETS == [ipaddress.ip_network(c)
                            for c in mod.OAI_FALLBACK]


def test_stale_cache_triggers_refetch(monkeypatch, tmp_path):
    import json as _json
    import time as _time
    env = tmp_path / "ip-ban.env"
    env.write_text("")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    cache = tmp_path / "net-ranges.json"
    stale = {"fetched_at": int(_time.time()) - 2 * mod.RANGES_CACHE_TTL,
             "googlebot": ["66.249.64.0/19"], "bingbot": ["157.55.39.0/24"],
             "openai": mod.OAI_FALLBACK}
    cache.write_text(_json.dumps(stale))
    monkeypatch.setattr(mod, "RANGES_CACHE", str(cache))
    calls = []

    def fake_fetch(url, timeout=15):
        calls.append(url)
        return {mod.GOOGLEBOT_URL: GOOGLE_JSON, mod.BINGBOT_URL: BING_JSON,
                mod.OAI_URL: OAI_JSON}.get(url)

    monkeypatch.setattr(mod, "fetch_text", fake_fetch)
    mod.load_crawler_ranges()
    assert len(calls) == 3                           # 过期 → 三源全部重新下载


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


def test_dc_action_is_block(ip_ban):
    """action 必须 block（2026-10-25 用户裁定：800x600 无头家族能过
    managed_challenge——GA 美国会话实证；12h 实测 19 ASN 上零真人，
    豁免三层保 SEO/GEO 爬虫）"""
    assert ip_ban.DC_ACTION == "block"


def test_dc_expression_exempts_selfid_ai_crawlers(ip_ban):
    """大云分支 UA 自报家门豁免:Amazonbot(实测全 AWS 段)与 ChatGPT-User(GEO 漏斗)
    必须豁免;纯 Chrome UA 不含任何豁免串,仍被 block。
    滥用分支(2026-10-25 拆分):零 UA 豁免——伪造 bot 字样也 403,但 cf.client.bot/
    官方段/站主豁免保留"""
    expr = ip_ban.build_dc_expression(ip_ban.parse_cidrs(""))
    parts = expr.split(") or (")
    assert len(parts) == 2                          # 无 persist 名单=恰好两支
    abuse, cloud = parts[0], parts[1]
    # 滥用分支:6 个滥用 ASN、零 UA 豁免、豁免三层保留
    assert "asnum in {18779" in abuse and "212238" in abuse
    assert "asnum in {16509" not in abuse           # 大云不混入滥用分支
    assert "user_agent" not in abuse
    assert "cf.client.bot" in abuse and "66.249.64.0/19" in abuse \
        and "47.72.103.104" in abuse
    # 大云分支:13 个大云、UA 豁免保留、豁免三层保留
    assert "asnum in {16509" in cloud and "8075" in cloud
    assert "18779" not in cloud
    assert 'contains "bot"' in cloud and 'contains "Bot"' in cloud
    assert 'contains "Amazonbot"' not in cloud      # 不点名,走通用 bot 串
    assert 'contains "ChatGPT-User"' in cloud
    assert 'contains "Claude-User"' in cloud
    assert 'contains "Perplexity-User"' in cloud
    # issue #3 ②：MistralAI-User / cohere-ai 同为无 bot 字样的 "-User" 系 GEO 漏斗
    assert 'contains "MistralAI-User"' in cloud
    assert 'contains "cohere-ai"' in cloud
    assert "cf.client.bot" in cloud and "66.249.64.0/19" in cloud
    # 原爬虫 UA 不命中任何豁免串(教义回归:Chrome 串里无 bot/spider/slurp/crawler/-User)
    chrome_ua = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
                 " (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
    assert not any(u.lower() in chrome_ua.lower() for u in ip_ban.DC_UA_EXEMPTS)


def test_abuse_and_cloud_asns_partition(ip_ban):
    """234+13 拆分覆盖原 19 个+10-26 扩容 11 个+10-26 终验补录 19148+
    11-19 HK 机房批 216（用户裁定），无交集无遗漏"""
    assert len(ip_ban.ABUSE_ASNS) == 234 and len(ip_ban.CLOUD_ASNS) == 13
    assert set(ip_ban.ABUSE_ASNS) & set(ip_ban.CLOUD_ASNS) == set()
    assert set(ip_ban.DATACENTER_ASNS) == set(ip_ban.ABUSE_ASNS) | set(ip_ban.CLOUD_ASNS)
    # 10-26 批回归锁:GA 溯源定案的 11 家不得缺失,大云 13 家不得误挪
    for a in (60068, 9009, 262287, 11798, 203020, 136557, 30058, 7203,
              60781, 51167, 199524, 19148):
        assert a in ip_ban.ABUSE_ASNS
    for a in (16509, 14618, 396982, 8075, 24940):
        assert a in ip_ban.CLOUD_ASNS


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


# ---- ⑨ tripwire：800x600 指纹自报端点（2026-11-06）----
# GA4 判例 2026-10-24：800x600 headless 族（美/英 direct 深链 sitemap 事件页、
# 单页零互动、城市 not set）真实受众分辨率零撞车；nearby 内联 JS 对该分辨率
# sendBeacon('/__trip') 自报，源站见路径即封出口。出口逐会话轮换，同 IP 凑不
# 出第二次命中 → 单发即封；/24 会殃及机房无辜邻居，不用（v4 /32、v6 /64）。

def test_trip_single_hit_bans_exit_ip(ip_ban):
    """单次 /__trip 命中即 /32 提案 30 天——低慢速族速率闸永远够不上，指纹网补位"""
    events = [("203.0.113.7", "/__trip", "Mozilla/5.0 Chrome/156.0", "403"),
              ("203.0.113.7", "/zh/queenstown", "Mozilla/5.0 Chrome/156.0", "200")]
    assert ip_ban.trip_bans(events) == {
        "203.0.113.7/32": ("fingerprint-tripwire", ip_ban.TRIP_TTL)}


def test_trip_v6_bans_slash64(ip_ban):
    """v6 出口按 /64 封（家宽/机房 /64 即订户级，不殃及邻居前缀）"""
    bans = ip_ban.trip_bans([("2001:db8:1::ff", "/__trip", "UA", "403")])
    assert "2001:db8:1::/64" in bans


def test_trip_path_must_be_exact(ip_ban):
    """只有 exact /__trip 是 tripwire JS 发的；子路径/无端点路径不提案（防伪造路径构陷误封）"""
    assert ip_ban.trip_bans([("203.0.113.8", "/__trip/x", "UA", "403")]) == {}
    assert ip_ban.trip_bans([("203.0.113.9", "/zh/queenstown", "UA", "200")]) == {}
    assert ip_ban.trip_bans([("203.0.113.9", "/trip", "UA", "200")]) == {}


def test_trip_dedupes_same_ip(ip_ban):
    """同 IP 一窗多次 beacon 只出一案（封禁提案按 cidr 去重）"""
    events = [("203.0.113.7", "/__trip", "UA", "403")] * 3
    assert list(ip_ban.trip_bans(events)) == ["203.0.113.7/32"]


def test_trip_google_range_rejected_by_safety(ip_ban):
    """trip 误命中官方爬虫段（理论不可能——爬虫视口非 800x600）时 SAFETY 闸兜底拒绝"""
    proposals = ip_ban.trip_bans([("66.249.73.10", "/__trip", "UA", "403")])
    assert proposals                                        # 提案生成
    assert "66.249.73.10/32" not in ip_ban.apply_safety(proposals)  # SAFETY 拒绝


# ---- ⑩ OAI-SearchBot 官方段真值豁免（2026-11-17 误封判例）----
# 判例：51 黑名单里 17 个来自 openai.com/searchbot.json 官方段
# （40.67.175.0/25 ×11 + 20.169.77.0/25 ×6）——OpenAI 爬虫管线在 headless
# 默认 800×600 视口下渲染页面执行 JS，撞 nearby 分辨率哨兵 /__trip，
# 出口轮换一次封一个，ChatGPT 搜索收录被逐出口掐断。cf.client.bot 在 CF
# 边缘全规则豁免（firewall events 零事件实证），源站 tripwire 是唯一拦截层，
# 官方段真值必须在此豁免（与 Google 2026-10-23 / Mediapartners 2026-10-24
# 同款「官方网段 IP 真值优先」修复模式）。

OAI_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36; compatible; "
          "OAI-SearchBot/1.4; +https://openai.com/searchbot")


def test_openai_official_ip_skips(ip_ban):
    """官方段 IP + SearchBot UA → skip（不计入枚举/洪水/档案，永不封）"""
    assert ip_ban.classify("40.67.175.127", OAI_UA) == "skip"
    assert ip_ban.classify("40.67.175.36", OAI_UA) == "skip"
    assert ip_ban.classify("20.169.77.14", OAI_UA) == "skip"


def test_openai_official_ip_skips_without_bot_ua(ip_ban):
    """IP 优先不看 UA：段内渲染器出口即使纯浏览器样式 UA（渲染管线常见）也 skip"""
    chrome_ua = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                 "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 "
                 "Safari/537.36")
    assert ip_ban.is_crawler_ip("40.67.175.127")
    assert ip_ban.classify("20.169.77.56", chrome_ua) == "skip"


def test_trip_proposal_for_openai_ip_vetoed_by_safety(ip_ban):
    """/__trip 命中 OpenAI 官方段出口 → 提案生成但 SAFETY 拒绝（本次误封的直接通道）"""
    proposals = ip_ban.trip_bans([("40.67.175.127", "/__trip", OAI_UA, "403")])
    assert "40.67.175.127/32" in proposals                 # 提案照常生成
    assert "40.67.175.127/32" not in ip_ban.apply_safety(proposals)  # SAFETY 拒绝


def test_trip_still_bans_non_official_800x600(ip_ban):
    """非官方段出口撞哨兵照封——敌对 800x600 族主判例不回退"""
    proposals = ip_ban.trip_bans([("198.51.100.7", "/__trip", OAI_UA, "403")])
    assert proposals == {"198.51.100.7/32": ("fingerprint-tripwire",
                                             ip_ban.TRIP_TTL)}
    ip_ban.apply_safety(proposals)
    assert list(proposals) == ["198.51.100.7/32"]


def test_safety_rejects_openai_24_proposal(ip_ban):
    """/24 级提案与官方段交集同样 veto（段内已知出口 +30 天全在 /25 内）"""
    proposals = {"40.67.175.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_openai_fallback_snapshot_size(ip_ban):
    """内置快照规模防护：官方段缺失/下载失败时白名单不许静默归零"""
    assert len(ip_ban.OAI_FALLBACK) >= 30
    assert ip_ban.OAI_NETS                                 # import 即可用（测试不联网）


# ---- ⑪ Ahrefs 官方段豁免 + 规则顺序重排（2026-11-17 判例②③）----
# Ahrefs 判例：34 黑名单里 6 个 202.8.40-43.x 全部属 AS140577（APNIC
# AHREFS-AS-AP 注册段）——cf.client.bot 认证 bot 边缘零事件实证（11-14/11-15
# 封禁在 72h 保留期内却零事件），其 JS 渲染器（Site Audit）800×600 撞哨兵，
# OpenAI 同款第二例。/23 注册段（2003 年起）稳定，静态常量即可。
# 规则顺序判例：CF 自定义规则 first-match-wins，geo-challenge 排第 1、
# blacklist 排第 3 → 136.66.124.196 在 11-15 封禁后仍 200 次 managed_challenge
# 事件、零 block——blacklist 对持续匹配挑战规则的请求根本轮不到执行，
# 解掉挑战即穿透封禁名单。重排=最狠处置先行（blacklist→dc→UA→geo→hotlink）。

def test_ahrefs_official_ip_skips(ip_ban):
    """APNIC 注册段 IP 优先不看 UA → skip（不计枚举/洪水/档案，永不封）"""
    ahrefs_ua = "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"
    assert ip_ban.classify("202.8.40.46", ahrefs_ua) == "skip"
    assert ip_ban.classify("202.8.42.173", ahrefs_ua) == "skip"
    assert ip_ban.is_crawler_ip("202.8.43.130")
    assert ip_ban.is_crawler_ip("202.8.41.110")


def test_trip_proposal_for_ahrefs_ip_vetoed_by_safety(ip_ban):
    """/__trip 命中 Ahrefs 段出口 → 提案生成但 SAFETY 拒绝"""
    proposals = ip_ban.trip_bans([("202.8.42.173", "/__trip", "UA", "403")])
    assert "202.8.42.173/32" in proposals
    assert not ip_ban.apply_safety(proposals)


def test_ahrefs_24_proposal_vetoed_by_safety(ip_ban):
    """/24 级提案与 Ahrefs /23 注册段交集同样 veto"""
    proposals = {"202.8.40.0/24": ("24h-enum", 604800)}
    ip_ban.apply_safety(proposals)
    assert proposals == {}


def test_rule_order_canonical_reorder(ip_ban):
    """first-match-wins 下最狠处置先行：blacklist→dc→UA→geo→hotlink"""
    def r(desc):
        return {"description": desc, "expression": "true", "action": "block"}
    rules = [r("geo-challenge merged 2026-11-07"),
             r("block empty/fake/script user agent"),
             r("ip-range-blacklist auto (34 active; managed by ip-ban.py)"),
             r("datacenter-asn-block auto (31 ASNs; managed by ip-ban.py)"),
             r("cdn-hotlink-block (Referer anti-hotlink; managed by ip-ban.py)")]
    out, changed = ip_ban.sort_rules_canonical(rules)
    assert changed
    descs = [x["description"] for x in out]
    assert descs[0].startswith("ip-range-blacklist")
    assert descs[1].startswith("datacenter-asn-block")
    assert descs[2].startswith("block empty/fake")
    assert descs[3].startswith("geo-challenge")
    assert descs[4].startswith("cdn-hotlink-block")


def test_rule_order_canonical_noop_when_sorted(ip_ban):
    """已合规顺序不触发重排（changed=False，PUT 不空转）"""
    def r(desc):
        return {"description": desc}
    rules = [r("ip-range-blacklist auto"), r("datacenter-asn-block auto"),
             r("block empty/fake"), r("geo-challenge merged"),
             r("cdn-hotlink-block")]
    out, changed = ip_ban.sort_rules_canonical(rules)
    assert not changed
    assert [x["description"] for x in out] == [x["description"] for x in rules]


def test_rule_order_unknown_rules_last_stable(ip_ban):
    """手工/未知规则排尾且保持相对顺序（不吞没 Dashboard 手建规则）"""
    def r(desc):
        return {"description": desc}
    rules = [r("some-manual-rule"), r("ip-range-blacklist auto"),
             r("another-manual-rule"), r("geo-challenge")]
    out, changed = ip_ban.sort_rules_canonical(rules)
    assert changed
    assert [x["description"] for x in out] == [
        "ip-range-blacklist auto", "geo-challenge",
        "some-manual-rule", "another-manual-rule"]


# ---- ⑫ 2026-11-17 复审修正：段外伪造官方爬虫 UA 按伪装计 bot ----
# 复审判例（code review）：SELFID_MARKERS 含 "bot"，段外伪造 OAI-SearchBot/
# AhrefsBot UA 原本拿到 skip（自报家门欢迎）=对枚举/洪水/攻击档案全隐身——
# 与头注释「伪造 UA 仍按伪装计 bot」的声明相反。修正：镜像 fake-googlebot
# 先例（2026-10-18），官方身份 UA + 段外 IP = 伪装计 bot；真爬虫在 IP 真值层
# （is_crawler_ip）先行 skip，不受影响。

def test_spoofed_official_bot_ua_outside_ranges_counts_as_bot(ip_ban):
    """OAI 官方 UA + 段外 IP → bot（计入枚举/洪水/攻击门，非 skip）。
    ahrefsbot 有意不在伪官方分支：官方段只覆盖 APNIC /23s，段外 UA 可能是
    Ahrefs 自己的 OVH/AWS 真实出口——列了反而开新误封通道（复审自纠）"""
    assert ip_ban.classify("198.51.100.7", OAI_UA) == "bot"
    assert ip_ban.classify(
        "198.51.100.8",
        "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)") == "skip"


def test_real_official_bots_still_skip_via_ip_truth(ip_ban):
    """真官方爬虫走 IP 真值层先行 skip，UA 伪装修正不影响它们"""
    assert ip_ban.classify("40.67.175.127", OAI_UA) == "skip"
    assert ip_ban.classify(
        "202.8.42.173",
        "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)") == "skip"


def test_selfid_ua_without_official_impersonation_still_welcomed(ip_ban):
    """非冒充官方身份的自报家门爬虫不受影响（2026-10-18 设计保持）"""
    assert ip_ban.classify(
        "198.51.100.9", "Kimi-SearchBot/1.0 (+https://kimi.ai/)") == "skip"
    assert ip_ban.classify(
        "198.51.100.10", "Mozilla/5.0 (compatible; SiriBot/1.0)") == "skip"


# ---- ⑬ 老格式缓存迁移（复审 Issue 3）：无 openai 键的新鲜缓存不降级 g/b ----

def test_fresh_old_format_cache_migrates_without_downgrade(monkeypatch, tmp_path):
    """老格式缓存（无 openai 键）命中缓存路径：g/b 保持缓存值，openai 用内置
    快照补位，零网络请求——不因迁移缺键把 google/bing 降级到 10-22 旧快照"""
    import json as _json
    import time as _time
    env = tmp_path / "ip-ban.env"
    env.write_text("")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    cache = tmp_path / "net-ranges.json"
    fresh_old = {"fetched_at": int(_time.time()) - 60,          # 新鲜（1 分钟前）
                 "googlebot": ["66.249.64.0/19"],
                 "bingbot": ["157.55.39.0/24"]}                 # 无 openai 键
    cache.write_text(_json.dumps(fresh_old))
    monkeypatch.setattr(mod, "RANGES_CACHE", str(cache))
    calls = []

    def boom(url, timeout=15):
        calls.append(url)
        raise OSError("network down")                           # 断网也应零请求

    monkeypatch.setattr(mod, "fetch_text", boom)
    mod.load_crawler_ranges()
    assert calls == []                                          # 缓存路径零网络
    assert mod.GOOGLE_NETS == [ipaddress.ip_network("66.249.64.0/19")]
    assert mod.BING_NETS == [ipaddress.ip_network("157.55.39.0/24")]
    assert mod.OAI_NETS == [ipaddress.ip_network(c)
                            for c in mod.OAI_FALLBACK]          # 内置快照补位


# ---- ⑭ #18 tripwire 取证增强：candidate 日志带 UA + state 命中样本环形缓冲 ----
# 背景（2026-11-17 判例链承接）：Ahrefs 段外出口（OVH/AWS）的 JS 渲染会话撞
# /__trip 仍会单发即封 30 天——疑似实证 11-08 的 54.174.58.237/241（AWS，封禁
# 相隔 5 分钟=单会话出口轮换，渲染器行为特征），但源站日志只留 8 小时，UA 已
# 不可考，误封无处申诉。取证三件套：candidate 日志带 UA 样本（截断）+ state
# 环形缓冲记 ip/ua/referer/时间（防日志滚动丢失）+ 写入时容量裁剪防膨胀。

HEADLESS_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) HeadlessChrome/131.0.0.0 Safari/537.36")


def test_trip_samples_record_ip_ua_referer_ts(ip_ban):
    """/__trip 命中落样：四字段齐备；普通路径流量不落样"""
    events = [("54.174.58.237", "/__trip", HEADLESS_UA, "403",
               "https://www.google.com/"),
              ("203.0.113.5", "/zh/queenstown", "Mozilla/5.0 Chrome/156.0",
               "200", "-")]
    out = ip_ban.record_trip_samples([], events, 1790000000)
    assert len(out) == 1
    s = out[0]
    assert s["ip"] == "54.174.58.237"
    assert s["ua"] == HEADLESS_UA
    assert s["referer"] == "https://www.google.com/"
    assert s["ts"] == 1790000000


def test_trip_samples_truncate_ua_and_referer(ip_ban):
    """UA/referer 截断到 TRIP_UA_MAX（200），防长样本撑爆 state"""
    out = ip_ban.record_trip_samples(
        [], [("198.51.100.9", "/__trip", "A" * 500, "403",
              "https://example.com/" + "b" * 500)], 1)
    assert ip_ban.TRIP_UA_MAX == 200
    assert len(out[0]["ua"]) == 200 and len(out[0]["referer"]) == 200


def test_trip_samples_ring_capacity_trim(ip_ban):
    """环形缓冲写入时裁剪：超容丢最旧；容量 ≥20（issue 下限）"""
    assert ip_ban.TRIP_SAMPLES_MAX >= 20
    events = [("10.1.%d.7" % i, "/__trip", "UA-%d" % i, "403", "-")
              for i in range(ip_ban.TRIP_SAMPLES_MAX + 10)]
    out = ip_ban.record_trip_samples([], events, 1)
    assert len(out) == ip_ban.TRIP_SAMPLES_MAX
    assert out[0]["ip"] == "10.1.10.7"          # 最旧的 10 条被裁
    assert out[-1]["ip"] == "10.1.%d.7" % (ip_ban.TRIP_SAMPLES_MAX + 9)
    # 评审修正后的新结构：下一轮老 IP 再命中 → 恒占 1 格（移到尾），
    # 不因跨轮重复 append 挤占他人格位
    out2 = ip_ban.record_trip_samples(
        out, [("10.1.10.7", "/__trip", "UA-rehit", "403", "-")], 2)
    assert len(out2) == ip_ban.TRIP_SAMPLES_MAX
    ips = [s["ip"] for s in out2]
    assert ips.count("10.1.10.7") == 1 and ips[-1] == "10.1.10.7"
    assert out2[-1]["ua"] == "UA-rehit" and out2[-1]["ts"] == 2


def test_trip_samples_cross_round_per_ip_dedupe_move_to_end(ip_ban):
    """评审 Important：跨轮按 IP 去重（move-to-end）——SAFETY 豁免段
    （AHREFS_NETS /23s）origin 持续可见反复撞 /__trip，append 式缓冲
    4-8 小时即被单一 IP 挤满 50 容量、逐出真被封候选的取证样本。
    新语义：每 IP 恒占 1 格、最近命中在尾。"""
    # 跨轮同 IP：只留最新一条（ts/ua 刷新），且在缓冲末尾
    r1 = ip_ban.record_trip_samples(
        [], [("202.8.40.46", "/__trip", "UA-r1", "403", "-")], 100)
    r2 = ip_ban.record_trip_samples(
        r1, [("198.51.100.7", "/__trip", "UA-other", "403", "-")], 200)
    r3 = ip_ban.record_trip_samples(
        r2, [("202.8.40.46", "/__trip", "UA-r3", "403",
              "https://ahrefs.com/")], 300)
    assert [s["ip"] for s in r3] == ["198.51.100.7", "202.8.40.46"]
    assert r3[-1] == {"ip": "202.8.40.46", "ua": "UA-r3",
                      "referer": "https://ahrefs.com/", "ts": 300}
    # 豁免段刷屏场景：同 IP 连撞 20 轮，仍恒占 1 格、不逐出他人样本
    buf = ip_ban.record_trip_samples(
        [], [("10.9.%d.9" % i, "/__trip", "UA-%d" % i, "403", "-")
             for i in range(10)], 1)
    for rnd in range(2, 22):
        buf = ip_ban.record_trip_samples(
            buf, [("202.8.42.173", "/__trip", "AhrefsBot-r%d" % rnd,
                   "403", "-")], rnd)
    assert len(buf) == 11                       # 10 个候选项 + 1 格豁免段
    ahrefs = [s for s in buf if s["ip"] == "202.8.42.173"]
    assert len(ahrefs) == 1 and ahrefs[0]["ua"] == "AhrefsBot-r21"
    assert [s["ip"] for s in buf][-1] == "202.8.42.173"
    kept = {s["ip"] for s in buf if s["ip"] != "202.8.42.173"}
    assert kept == {"10.9.%d.9" % i for i in range(10)}   # 候选取证未被挤掉


def test_trip_samples_last_hit_per_ip_in_round(ip_ban):
    """同 IP 一轮多次 beacon 只留一条（取最后 UA），防单轮刷屏占满缓冲"""
    events = [("198.51.100.7", "/__trip", "UA-first", "403", "-"),
              ("198.51.100.7", "/__trip", "UA-second", "403", "-")]
    out = ip_ban.record_trip_samples([], events, 1)
    assert len(out) == 1 and out[0]["ua"] == "UA-second"


def test_trip_samples_only_exact_trip_path(ip_ban):
    """与 trip_bans 判例同口径：只有 exact /__trip 落样（子路径不构陷）"""
    events = [("198.51.100.7", "/__trip/x", "UA", "403", "-"),
              ("198.51.100.8", "/trip", "UA", "200", "-")]
    assert ip_ban.record_trip_samples([], events, 1) == []


def test_trip_ua_map_truncates_and_last_wins(ip_ban):
    """cidr → 本轮最后 UA（截断 200）：candidate 日志取证的数据源"""
    events = [("198.51.100.7", "/__trip", "U" * 500, "403", "-"),
              ("198.51.100.7", "/__trip", "short", "403", "-")]
    assert ip_ban.trip_ua_map(events) == {"198.51.100.7/32": "short"}
    m = ip_ban.trip_ua_map([("2001:db8:1::1", "/__trip", "x" * 300, "403", "-")])
    assert m == {"2001:db8:1::/64": "x" * 200}


def test_trip_candidate_log_carries_ua(ip_ban, capsys):
    """candidate 日志行必须带 UA 样本（#18 验收：封禁时取证同步留痕）"""
    events = [("54.174.58.237", "/__trip",
               "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
               "403", "-")]
    proposals = {}
    new = ip_ban.apply_trip_proposals(events, {}, proposals)
    out = capsys.readouterr().out
    assert "54.174.58.237/32" in proposals
    assert "ua=Mozilla/5.0 (compatible; AhrefsBot/7.0" in out
    assert len(new) == 1 and new[0][0] == "54.174.58.237/32"


def test_trip_candidate_skips_known_cidr_no_log(ip_ban, capsys):
    """既有判例不回退：已在 proposals/bans 的 cidr 不重复提案、不打 candidate"""
    events = [("54.174.58.237", "/__trip", "UA", "403", "-")]
    proposals = {"54.174.58.237/32": ("single-ip flood", 86400)}
    assert ip_ban.apply_trip_proposals(events, {}, proposals) == []
    assert ip_ban.apply_trip_proposals(
        events, {"54.174.58.237/32": {"until": 9}}, proposals) == []
    assert "candidate" not in capsys.readouterr().out


def test_trip_bans_judgments_unchanged_with_referer_events(ip_ban):
    """事件元组扩为 (ip, path, ua, status, referer) 后既有 trip 判例不回退"""
    events = [("203.0.113.7", "/__trip", "Mozilla/5.0 Chrome/156.0", "403",
               "https://nearby.noda.co.nz/"),
              ("203.0.113.7", "/zh/queenstown", "Mozilla/5.0 Chrome/156.0",
               "200", "-"),
              ("203.0.113.8", "/__trip/x", "UA", "403", "-")]
    assert ip_ban.trip_bans(events) == {
        "203.0.113.7/32": ("fingerprint-tripwire", ip_ban.TRIP_TTL)}
    # 老 4 元组（无 referer）同样兼容——纯函数按索引取值不炸
    assert ip_ban.trip_bans([("203.0.113.7", "/__trip", "UA", "403")]) == {
        "203.0.113.7/32": ("fingerprint-tripwire", ip_ban.TRIP_TTL)}
    assert ip_ban.record_trip_samples(
        [], [("203.0.113.7", "/__trip", "UA", "403")], 5) == [
        {"ip": "203.0.113.7", "ua": "UA", "referer": "-", "ts": 5}]


# ---- ⑮ #19 apply_geo_rule：geo-challenge 收编守护（observe 优先，enforce 备用）----
# geo-challenge 是 noda zone 唯一手工维护规则，已连产两次事故（11-07 规则顺序
# 缺口使 blacklist 失效 / 11-17 www 盲区=解挑战免费旁路）——文档快照防不了
# 漂移，仿 cdn-hotlink-block 先例收编为代码自愈。canonical 表达式逐字符取自
# 2026-11-17 CF live（rule b62507ea2ec243098ea2ce8eaac599e5 / ref
# geo-admin-challenge），获取命令（只读 GET）：
#   ssh r4s "cat /etc/noda/ip-ban.env" 拿 DOPPLER_SERVICE_TOKEN →
#   GET api.doppler.com/v3/configs/config/secret?project=noda&config=prd&name=CF_BAN_API_TOKEN →
#   GET api.cloudflare.com/client/v4/zones?name=noda.co.nz（zone 2ed51678bb82d8def5a5dcae28635c11）→
#   GET zones/{zone}/rulesets/phases/http_request_firewall_custom/entrypoint

GEO_LIVE_EXPR = ('(http.host eq "admin.noda.co.nz" and ip.geoip.country ne "NZ") '
                 'or ((not cf.client.bot) and (not ip.src in {66.249.64.0/19 '
                 '209.85.128.0/17 2001:4860:7::/48}) and '
                 '(http.host in {"noda.co.nz" "www.noda.co.nz"}) and '
                 '(not ip.geoip.country in {"NZ" "AU" "TW"}))')
GEO_LIVE_DESC = ("geo-challenge merged 2026-11-07 (www added 2026-11-17): "
                 "admin non-NZ + web non-NZ/AU apex+www")


def _geo_live_rule():
    return {"id": "b62507ea2ec243098ea2ce8eaac599e5",
            "ref": "geo-admin-challenge", "action": "managed_challenge",
            "enabled": True, "description": GEO_LIVE_DESC,
            "expression": GEO_LIVE_EXPR}


def test_geo_clause_matches_cf_live_2026_11_17(ip_ban):
    """canonical=2026-11-17 CF live 逐字符一致（非手抄重构）——若本测试失败
    = 有人改了 canonical，需重新对 CF API 校准并同步重发"""
    assert ip_ban.GEO_CLAUSE == GEO_LIVE_EXPR
    assert ip_ban.GEO_DESC == GEO_LIVE_DESC
    assert ip_ban.GEO_REF == "geo-admin-challenge"
    assert ip_ban.GEO_ACTION == "managed_challenge"
    assert ip_ban.GEO_MARKER == "geo-challenge"      # 与 RULE_ORDER 前缀一致


def test_geo_rule_zone_isolation(ip_ban):
    """仅 noda.co.nz zone 生效（GEO_ZONES 复用 HOTLINK_ZONES 模式）——
    shuotong.wang 无此规则，main 循环根本不会对它调 apply_geo_rule"""
    assert ip_ban.GEO_ZONES == ("noda.co.nz",)
    assert "shuotong.wang" not in ip_ban.GEO_ZONES
    assert set(ip_ban.GEO_ZONES) <= set(ip_ban.ZONES)
    assert ip_ban.GEO_MARKER in ip_ban.RULE_ORDER      # 收编后排序位不变


def test_geo_rule_healthy_live_shape_noop_both_modes(ip_ban):
    """live 现值形态（含 live description/ref）两模式都零动作——observe 零误报
    是转 enforce 的前提"""
    for mode in ("observe", "enforce"):
        out, ch, alerts, fp = ip_ban.apply_geo_rule(
            [_geo_live_rule()], mode, "noda.co.nz")
        assert ch is False and alerts == [] and fp == "" and len(out) == 1


def test_geo_rule_observe_drift_alerts_zero_write(ip_ban):
    """observe：www 修复丢失形态（表达式被打回 apex-only）→ 只告警零写回，
    文案含漂移前后全文 + 首个差异定位"""
    drifted = _geo_live_rule()
    drifted["expression"] = ('(http.host eq "noda.co.nz" and '
                             'not ip.geoip.country in {"NZ" "AU"})')
    out, ch, alerts, fp = ip_ban.apply_geo_rule([drifted], "observe",
                                                "noda.co.nz")
    assert ch is False                                   # 零写回
    assert out[0]["expression"] != ip_ban.GEO_CLAUSE     # 规则对象未被动过
    assert len(alerts) == 1 and fp
    msg = alerts[0]
    assert "observe" in msg and "零回写" in msg and "noda.co.nz" in msg
    assert drifted["expression"] in msg                  # 漂移前（线上现值）
    assert ip_ban.GEO_CLAUSE in msg                      # 漂移后（canonical 期望）
    assert "首个差异@" in msg


def test_geo_rule_observe_missing_alerts_no_create(ip_ban):
    """observe：规则被删 → 告警缺失但不重建（零写回）"""
    out, ch, alerts, fp = ip_ban.apply_geo_rule([], "observe", "noda.co.nz")
    assert ch is False and len(out) == 0 and len(alerts) == 1 and fp == "missing"
    assert "缺失" in alerts[0] and ip_ban.GEO_CLAUSE in alerts[0]


def test_geo_rule_enforce_pulls_back_drift(ip_ban):
    """enforce：表达式/action/enabled 任一漂移 → 原位拉回 canonical"""
    drifted = _geo_live_rule()
    drifted.update(expression="true", action="block", enabled=False)
    out, ch, alerts, fp = ip_ban.apply_geo_rule([drifted], "enforce",
                                                "noda.co.nz")
    assert ch is True and fp
    assert out[0]["expression"] == ip_ban.GEO_CLAUSE
    assert out[0]["action"] == "managed_challenge" and out[0]["enabled"] is True
    assert out[0]["description"] == ip_ban.GEO_DESC
    assert any("拉回" in a for a in alerts)


def test_geo_rule_enforce_recreates_deleted(ip_ban):
    """enforce：规则被删 → 删除重建（继承 hotlink 自愈语义），ref/desc/expression
    全 canonical"""
    out, ch, alerts, fp = ip_ban.apply_geo_rule([], "enforce", "noda.co.nz")
    assert ch is True and len(out) == 1 and fp == "missing"
    r = out[0]
    assert r["ref"] == ip_ban.GEO_REF and r["expression"] == ip_ban.GEO_CLAUSE
    assert r["action"] == ip_ban.GEO_ACTION and r["enabled"] is True
    assert r["description"] == ip_ban.GEO_DESC
    assert any("重建" in a for a in alerts)


def test_geo_rule_desc_not_compared_but_ref_adopts(ip_ban):
    """健康判定只比 expression/action/enabled：description 后缀被改不算漂移
    （desc 由 live 起步，比了会在 enforce 首轮产生无谓写）；description 前缀
    丢了仍能被 ref 收养——前缀漂移的告警归 #20 前缀守护"""
    r1 = _geo_live_rule()
    r1["description"] = "geo-challenge 面板里被人改了后缀"
    _out, ch, alerts, fp = ip_ban.apply_geo_rule([r1], "enforce", "noda.co.nz")
    assert ch is False and alerts == [] and fp == ""
    r2 = _geo_live_rule()
    r2["description"] = "面板改名丢了前缀"          # 不再 startswith geo-challenge
    _out, ch, alerts, fp = ip_ban.apply_geo_rule([r2], "observe", "noda.co.nz")
    assert ch is False and alerts == [] and fp == ""   # ref 兜底找到=表达式健康


def test_geo_rule_mode_env_and_default(monkeypatch, tmp_path):
    """GEO_RULE_MODE：os.environ 优先 / ENV_FILE 兜底 / 默认 observe /
    未知值不进 enforce（影响面大，宁守勿攻）"""
    env = tmp_path / "ip-ban.env"
    env.write_text("GEO_RULE_MODE=enforce\n")
    mod = load_ip_ban(monkeypatch, env_file=str(env))
    monkeypatch.delenv("GEO_RULE_MODE", raising=False)
    assert mod.geo_rule_mode() == "enforce"             # ENV_FILE 兜底
    monkeypatch.setenv("GEO_RULE_MODE", "observe")
    assert mod.geo_rule_mode() == "observe"             # os.environ 优先
    monkeypatch.setenv("GEO_RULE_MODE", " ENFORCE ")
    assert mod.geo_rule_mode() == "enforce"             # 大小写/空白容错
    monkeypatch.setenv("GEO_RULE_MODE", "garbage")
    assert mod.geo_rule_mode() == "observe"             # 未知值回落 observe


def test_geo_rule_dry_run_enforce_stays_observe(ip_ban, monkeypatch):
    """DRY_RUN 下 enforce 不得改规则对象（put_rules 被跳过，改了就是假自愈）"""
    monkeypatch.setattr(ip_ban, "DRY_RUN", True)
    drifted = _geo_live_rule()
    drifted["expression"] = "true"
    out, ch, alerts, fp = ip_ban.apply_geo_rule([drifted], "enforce",
                                                "noda.co.nz")
    assert ch is False and out[0]["expression"] == "true"
    assert fp and "DRY_RUN" in alerts[0] and "零回写" in alerts[0]


def test_geo_guard_dedup_same_drift_and_recovery(ip_ban):
    """observe 告警去重（cron */5，漂移持续会刷屏）：同指纹只发一次，变化再发；
    解除记日志不再 TG"""
    logs = []
    guard, a1 = ip_ban.step_geo_guard({}, "noda.co.nz", "drift:x", ["m1"],
                                      logs.append)
    assert a1 == ["m1"] and guard["noda.co.nz"] == "drift:x"
    guard, a2 = ip_ban.step_geo_guard(guard, "noda.co.nz", "drift:x", ["m1"],
                                      logs.append)
    assert a2 == [] and any("静默" in l for l in logs)     # 同漂移去重
    guard, a3 = ip_ban.step_geo_guard(guard, "noda.co.nz", "drift:y", ["m2"],
                                      logs.append)
    assert a3 == ["m2"]                                    # 变化才再报
    guard, a4 = ip_ban.step_geo_guard(guard, "noda.co.nz", "", [], logs.append)
    assert a4 == [] and "noda.co.nz" not in guard          # 解除：只记日志
    assert any("解除" in l for l in logs)


# ---- ⑯ #20 规则清单前缀漂移检测告警（缺失/重复/正常 × 分 zone 期望集）----
# ip-ban.py 按 description 前缀定位规则。前缀漂移后果不对称且部分静默：
# blacklist/dc 漂移 → apply_* 找不到 → 新建第二条 → Free 版 5 条上限立刻
# 6/5、PUT 每轮失败（高）；UA-block 漂移 → 排尾落到 geo-challenge 之后，
# headless UA 从 403 降级挑战（中，静默变松）。检测+告警兜底，TG 带现场清单。

NODA_HEALTHY_DESCS = [
    "ip-range-blacklist auto (28 active; managed by ip-ban.py)",
    "datacenter-asn-block auto (31 ASNs + cdn hotlink; managed by ip-ban.py)",
    "block empty/fake/script user agent",
    GEO_LIVE_DESC,
    "cdn-hotlink-block (Referer anti-hotlink; managed by ip-ban.py)",
]
SHUOTONG_HEALTHY_DESCS = NODA_HEALTHY_DESCS[:3]   # geo/hotlink 仅 noda zone


def _rules(descs):
    return [{"description": d} for d in descs]


def test_expected_prefixes_by_zone(ip_ban):
    """分 zone 期望集：blacklist/dc/UA 两 zone 都应在；geo/hotlink 仅 noda"""
    assert ip_ban.expected_rule_prefixes("noda.co.nz") == (
        ip_ban.RULE_MARKER, ip_ban.DC_MARKER, ip_ban.UA_MARKER,
        ip_ban.GEO_MARKER, ip_ban.HOTLINK_MARKER)
    assert ip_ban.expected_rule_prefixes("shuotong.wang") == (
        ip_ban.RULE_MARKER, ip_ban.DC_MARKER, ip_ban.UA_MARKER)


def test_rule_guard_healthy_no_alert_both_zones(ip_ban):
    """正常态：两 zone 期望集齐全且无重复 → 零告警，guard 不留痕"""
    for zone, descs in (("noda.co.nz", NODA_HEALTHY_DESCS),
                        ("shuotong.wang", SHUOTONG_HEALTHY_DESCS)):
        guard, alerts = ip_ban.step_rule_guard({}, zone, _rules(descs),
                                               lambda m: None)
        assert alerts == [] and guard == {}


def test_rule_guard_geo_hotlink_absence_fine_in_shuotong(ip_ban):
    """zone 期望集隔离：shuotong 没有 geo/hotlink 不是漂移（noda 才期望它们）"""
    missing, dups = ip_ban.check_rule_inventory(
        "shuotong.wang", _rules(SHUOTONG_HEALTHY_DESCS))
    assert missing == [] and dups == []


def test_rule_guard_missing_prefix_alerts_with_listing(ip_ban):
    """缺失（noda 的 UA-block 被 Dashboard 改名）：告警带 zone+前缀+现场全部
    规则 description 清单（可直接定位手改了什么）"""
    descs = [d for d in NODA_HEALTHY_DESCS
             if not d.startswith("block empty/fake")]
    guard, alerts = ip_ban.step_rule_guard({}, "noda.co.nz", _rules(descs),
                                           lambda m: None)
    assert len(alerts) == 1
    msg = alerts[0]
    assert "noda.co.nz" in msg and "block empty/fake" in msg and "缺失" in msg
    for d in descs:                       # 现场清单全量在文案里
        assert d in msg
    assert guard["noda.co.nz"]            # 指纹入 state（去重用）


def test_rule_guard_missing_geo_in_noda_flagged(ip_ban):
    descs = [d for d in NODA_HEALTHY_DESCS if not d.startswith("geo-challenge")]
    missing, _ = ip_ban.check_rule_inventory("noda.co.nz", _rules(descs))
    assert ip_ban.GEO_MARKER in missing


def test_rule_guard_missing_blacklist_in_shuotong_flagged(ip_ban):
    """blacklist/dc 是两 zone 共同期望——shuotong 缺 blacklist 同样告警"""
    missing, _ = ip_ban.check_rule_inventory(
        "shuotong.wang", _rules(SHUOTONG_HEALTHY_DESCS[1:]))
    assert ip_ban.RULE_MARKER in missing and ip_ban.DC_MARKER not in missing


def test_rule_guard_duplicate_alerts(ip_ban):
    """重复（blacklist 前缀命中两条=漂移产物）：告警带两条 description"""
    descs = NODA_HEALTHY_DESCS + ["ip-range-blacklist dashboard 手建第二条"]
    guard, alerts = ip_ban.step_rule_guard({}, "noda.co.nz", _rules(descs),
                                           lambda m: None)
    assert len(alerts) == 1
    assert "重复" in alerts[0] and "ip-range-blacklist" in alerts[0]
    assert "dashboard 手建第二条" in alerts[0]


def test_rule_guard_dedup_same_drift_silent(ip_ban):
    """同一漂移不每 5 分钟重复轰炸：同指纹第二轮静默"""
    rules = _rules([d for d in NODA_HEALTHY_DESCS
                    if not d.startswith("geo-challenge")])
    guard, a1 = ip_ban.step_rule_guard({}, "noda.co.nz", rules, lambda m: None)
    guard, a2 = ip_ban.step_rule_guard(guard, "noda.co.nz", rules, lambda m: None)
    assert len(a1) == 1 and a2 == []


def test_rule_guard_changed_drift_realerts(ip_ban):
    """漂移变化（缺失→重复）才再报"""
    missing_only = _rules([d for d in NODA_HEALTHY_DESCS
                           if not d.startswith("geo-challenge")])
    guard, a1 = ip_ban.step_rule_guard({}, "noda.co.nz", missing_only,
                                       lambda m: None)
    dup_too = _rules(NODA_HEALTHY_DESCS + ["datacenter-asn-block 重复"])
    guard, a2 = ip_ban.step_rule_guard(guard, "noda.co.nz", dup_too,
                                       lambda m: None)
    assert len(a1) == 1 and len(a2) == 1


def test_rule_guard_recovery_alerts_once(ip_ban):
    """解除后报恢复（带此前漂移指纹可定位），再健康则持续静默"""
    bad = _rules([d for d in NODA_HEALTHY_DESCS
                  if not d.startswith("geo-challenge")])
    guard, _ = ip_ban.step_rule_guard({}, "noda.co.nz", bad, lambda m: None)
    guard, a2 = ip_ban.step_rule_guard(guard, "noda.co.nz",
                                       _rules(NODA_HEALTHY_DESCS),
                                       lambda m: None)
    assert len(a2) == 1 and "恢复" in a2[0] and "geo-challenge" in a2[0]
    guard, a3 = ip_ban.step_rule_guard(guard, "noda.co.nz",
                                       _rules(NODA_HEALTHY_DESCS),
                                       lambda m: None)
    assert a3 == [] and "noda.co.nz" not in guard


def test_rule_guard_disabled_blacklist_still_counts(ip_ban):
    """黑名单空时 disable 休眠形态（规则对象保留）不算缺失"""
    rules = _rules(NODA_HEALTHY_DESCS)
    rules[0]["enabled"] = False
    rules[0]["description"] = ("ip-range-blacklist auto (empty; "
                               "managed by ip-ban.py)")
    missing, dups = ip_ban.check_rule_inventory("noda.co.nz", rules)
    assert missing == [] and dups == []


def test_rule_guard_blank_description_not_crash(ip_ban):
    """无 description 的规则（理论上的手工残渣）按空串处理，不误匹配前缀"""
    missing, dups = ip_ban.check_rule_inventory("shuotong.wang",
                                                [{"expression": "true"}])
    assert len(missing) == 3 and dups == []
