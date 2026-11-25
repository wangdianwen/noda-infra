#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch-overture-nz.py 单元测试（#392 T1：过滤链/打区/JSONL 契约/stats/SQL 守卫）。

不打真网络：全部用脚本内置 fixture 与合成行；--selftest 独立进程另测（CI 可跑）。
运行：pytest deploy/tests/test_fetch_overture_nz.py
"""

import importlib.util
import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY = os.path.dirname(HERE)
SCRIPT = os.path.join(DEPLOY, "overture", "fetch-overture-nz.py")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


fo = _load("fetch_overture_nz", SCRIPT)


def _row(**kw):
    base = dict(id="08f1test", name="Some Park", basic_category="park",
                taxonomy="park", confidence=0.9, operating_status="operating",
                lng=174.779, lat=-36.897, locality="Auckland",
                address="Greenlane", website="https://example.co.nz",
                phone="+64 9 000")
    base.update(kw)
    return base


# ---------------------------------------------------------------- 打区

def test_city_for_point_all_eight_cities():
    # 各城质心（nearby-geo.json 城市级 centroid）必须命中本城
    centroids = {
        "auckland": (174.76, -36.84), "wellington": (174.78, -41.29),
        "christchurch": (172.64, -43.53), "hamilton": (175.28, -37.79),
        "rotorua": (176.25, -38.14), "tauranga": (176.17, -37.69),
        "queenstown": (168.69, -45.03), "dunedin": (170.48, -45.87),
    }
    assert {c[0] for c in fo.CITY_BBOXES} == set(centroids)
    for slug, (lng, lat) in centroids.items():
        assert fo.city_for_point(lng, lat) == slug, slug


def test_city_for_point_rejects_outside():
    assert fo.city_for_point(0.0, 0.0) is None
    assert fo.city_for_point(172.0, -41.0) is None     # 城市间荒野（NZ bbox 内）
    assert fo.city_for_point(180.0, -40.0) is None     # NZ bbox 外


def test_process_row_national_fallback():
    # #392 AC1（2026-11-19）：8 城 bbox 外行不再丢弃——city_slug 置空串收录
    rec, reason = fo.process_row(_row(id="n1", lng=172.0, lat=-41.0))
    assert reason is None and rec["city_slug"] == ""
    # Northland 小镇同形态（apps 侧归 northland 大区）
    rec2, _ = fo.process_row(_row(id="n2", lng=174.324, lat=-35.732))
    assert rec2["city_slug"] == ""


def test_city_bbox_within_nz_bbox():
    nz = fo.NZ_BBOX
    for slug, x0, x1, y0, y1 in fo.CITY_BBOXES:
        assert nz[0] <= x0 < x1 <= nz[1], slug
        assert nz[2] <= y0 < y1 <= nz[3], slug


# ---------------------------------------------------------------- 过滤链

def test_whitelist_semantics_osm_kinds_alignment():
    wl = fo.CATEGORY_WHITELIST
    # 7 类语义锚点（osm.go osmKinds 同源类目必须收）+ 餐饮 6 类（WS6 #397 放行）
    # + 住宿 5 类（WS #477，2026-11-23 激活）
    for keep in ("playground", "beach", "park", "garden", "botanical_garden",
                 "viewpoint", "scenic_lookout", "art_gallery", "public_art",
                 "theater", "stadium", "gym", "swimming_pool", "arena",
                 "restaurant", "cafe", "bar", "casual_eatery", "coffee_shop",
                 "fast_food_restaurant",
                 "hotel", "lodging", "bed_and_breakfast", "private_lodging",
                 "inn"):
        assert keep in wl, keep
    for drop in ("museum", "shop", "supermarket", "atm", "hospital",
                 # resort 抽样噪音 ~40%（误分类零售/酒铺/美发）不收；
                 # campground 与既有 campsites 目录同域重叠不收（#477 报告 §1）
                 "resort", "campground"):
        assert drop not in wl, drop
    # fast_food 是 Overture 未用名——实名 fast_food_restaurant（#392 实测）
    assert "fast_food" not in wl
    assert len(wl) == 31


def test_confidence_gate_boundary():
    assert fo.process_row(_row(confidence=0.8))[1] is None      # 含边界
    assert fo.process_row(_row(confidence=0.799))[1] == "confidence"
    assert fo.process_row(_row(confidence=None))[1] == "confidence"


def test_operating_status_gate():
    assert fo.process_row(_row(operating_status="operating"))[1] is None
    assert fo.process_row(_row(operating_status=None))[1] is None     # 未知放行
    for bad in ("closed", "permanently_closed", "temporarily_closed",
                "relocated", "removed"):
        assert fo.process_row(_row(operating_status=bad))[1] == "status", bad


def test_name_and_coords_required():
    assert fo.process_row(_row(name=None))[1] == "name_coord"
    assert fo.process_row(_row(name="  "))[1] == "name_coord"
    assert fo.process_row(_row(lat=None))[1] == "name_coord"
    assert fo.process_row(_row(lng=None))[1] == "name_coord"


def test_category_drop_before_confidence():
    # 链序：白名单最前——未收类目即使 conf 高也在 category 阶段丢弃
    # （餐饮/住宿已放行，用 museum 锁链序分支）
    rec, reason = fo.process_row(_row(basic_category="museum", confidence=0.9))
    assert rec is None and reason == "category"
    # 住宿 5 类已放行（#477）：hotel 低 conf 穿过 category 门、落在 conf 门
    rec, reason = fo.process_row(_row(basic_category="hotel", confidence=0.5))
    assert rec is None and reason == "confidence"
    # hotel 正常 conf 应收
    rec, reason = fo.process_row(_row(basic_category="hotel"))
    assert reason is None and rec is not None


# ---------------------------------------------------------------- 链/契约

def test_run_chain_stage_counts_and_conservation(tmp_path):
    rows = [
        _row(id="k1"),                                             # 收（城市行）
        _row(id="d1", basic_category="museum"),                    # 类目（未收类目锁丢弃分支；住宿已放行不再适用）
        _row(id="d2", confidence=0.5),                             # conf
        _row(id="d3", name=None),                                  # 名称
        _row(id="d4", operating_status="closed"),                  # 状态
        _row(id="h1", basic_category="hotel"),                     # 住宿放行（#477）：全程通过计入 kept
        _row(id="n1", lng=172.0, lat=-41.0),                       # 8 城外（#392 AC1 全国兜底收）
    ]
    out = tmp_path / "o.jsonl"
    stats = fo.new_stats("test")
    with open(out, "w", encoding="utf-8") as fh:
        fo.run_chain(rows, fh, stats)
    st, dr = stats["stages"], stats["dropped"]
    assert st["bbox_rows"] == 7
    assert st["after_category"] == 6
    assert st["after_confidence"] == 5
    assert st["after_name_coord"] == 4
    assert st["after_status"] == 3
    assert st["kept"] == 3
    assert dr == {"category": 1, "confidence": 1, "name_coord": 1,
                  "status": 1}                                     # no_city 不再是丢弃原因
    assert st["bbox_rows"] == st["kept"] + sum(dr.values())       # 守恒
    assert stats["cities"] == {"auckland": 2}
    assert stats["national"] == 1                                  # 全国兜底计数
    assert st["kept"] == sum(stats["cities"].values()) + stats["national"]
    assert stats["categories"] == {"park": 2, "hotel": 1}          # 住宿放行计入（#477）
    assert stats["dropped_status_values"] == {"closed": 1}
    # 全国行 city_slug 空串（apps adapter 兜底 national + 大区归属）
    recs = [json.loads(ln) for ln in open(out, encoding="utf-8")]
    assert {r["id"]: r["city_slug"] for r in recs} == {"k1": "auckland", "h1": "auckland", "n1": ""}


def test_jsonl_line_contract(tmp_path):
    out = tmp_path / "o.jsonl"
    stats = fo.new_stats("t")
    with open(out, "w", encoding="utf-8") as fh:
        fo.run_chain([_row(id="a1", name="中文公園", lat=-36.897123456,
                           lng=174.779987654)], fh, stats)
    line = open(out, encoding="utf-8").read().rstrip("\n")
    rec = json.loads(line)
    # 字段名+顺序 = 契约（apps T2 adapter 依赖）
    assert list(rec.keys()) == list(fo.JSONL_FIELDS)
    assert rec["id"] == "a1" and rec["name"] == "中文公園"     # UTF-8 不转义
    assert rec["lat"] == -36.897123 and rec["lng"] == 174.779988  # 6 位小数
    assert rec["confidence"] == 0.9
    assert rec["city_slug"] == "auckland"
    assert "\\" not in line or "\\u" not in line              # ensure_ascii=False


def test_taxonomy_and_contacts_defaults(tmp_path):
    out = tmp_path / "o.jsonl"
    with open(out, "w", encoding="utf-8") as fh:
        fo.run_chain([_row(id="b1", taxonomy=None, locality=None,
                           address=None, website=None, phone=None)], fh,
                     fo.new_stats("t"))
    rec = json.loads(open(out, encoding="utf-8").read())
    assert rec["taxonomy"] == "" and rec["locality"] == ""
    assert rec["address"] == "" and rec["website"] == "" and rec["phone"] == ""


# ---------------------------------------------------------------- SQL/自检

def test_build_query_guards():
    sql = fo.build_query("2026-10-21.0")
    assert "s3://overturemaps-us-west-2/release/2026-10-21.0/" \
           "theme=places/type=place/*" in sql
    assert "hive_partitioning=1" in sql
    for v in ("166.0", "178.6", "-47.3", "-34.4"):
        assert v in sql, v
    # 过滤链在 Python 侧（by design，见脚本 docstring）：SQL 不含类目/置信门
    assert "confidence >=" not in sql
    assert "basic_category IN" not in sql


def test_selftest_mode_standalone():
    # --selftest 独立进程可跑（CI 形态），不 import duckdb
    r = subprocess.run([sys.executable, SCRIPT, "--selftest"],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert "selftest ok" in r.stdout


# ---------------------------------------------------------------- T6 月度链脚本

MONTHLY = os.path.join(DEPLOY, "overture", "overture-monthly.sh")


def test_monthly_script_syntax_and_dryrun(tmp_path):
    # 语法检查 + 干跑模式：全链只打印不触网/不 docker；lock 落盘并随退出清理
    r = subprocess.run(["sh", "-n", MONTHLY], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    env = dict(os.environ, OVERTURE_DATA_DIR=str(tmp_path / "data"))
    r = subprocess.run(["sh", MONTHLY, "--dry-run"], capture_output=True,
                       text=True, timeout=120, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout + r.stderr
    for marker in ("步骤1", "步骤2", "步骤3", "步骤4", "步骤5", "DONE",
                   "crawl-overture"):
        assert marker in out, marker
    # 干跑不留 lock、不写月份目录（无副作用）
    assert not (tmp_path / "data" / ".monthly-lock").exists()
    assert not (tmp_path / "data" / "overture-nz-latest.jsonl").exists()


def test_monthly_script_idempotent_marker_short_circuits(tmp_path):
    # .done-<当月> 存在且未设 OVERTURE_FORCE → 立即退出 0 且不进入链
    import datetime
    data = tmp_path / "data"
    data.mkdir(parents=True)
    month = datetime.date.today().strftime("%Y-%m")
    (data / f".done-{month}").write_text("1")
    env = dict(os.environ, OVERTURE_DATA_DIR=str(data))
    r = subprocess.run(["sh", MONTHLY, "--dry-run"], capture_output=True,
                       text=True, timeout=60, env=env)
    assert r.returncode == 0
    assert "本月已完成" in (r.stdout + r.stderr)
    assert "步骤1" not in (r.stdout + r.stderr)
