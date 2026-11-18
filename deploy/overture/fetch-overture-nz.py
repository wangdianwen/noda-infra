#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch-overture-nz.py — 下载 Overture Maps NZ places 子集 → 过滤 → 城市标注 JSONL。

noda-apps #392 WS1 Task 1（infra 侧预处理）。月度由 overture-monthly.sh（同目录）
驱动；也可手动跑。DuckDB httpfs 直查 S3 GeoParquet（单次全 bbox 扫描 ~25min，
月度一次，不做高频查询）。

用法:
  fetch-overture-nz.py [--release 2026-10-21.0]
                       [--out /mnt/mmc1-4/Data/overture/overture-nz.jsonl]
                       [--selftest]

--selftest 不触网：内置 fixture 行走完整 过滤链 → 打区 → JSONL 输出 → stats 断言，
CI/pytest 可跑（deploy/tests/test_fetch_overture_nz.py）。

设计（与 #400 计划的差异见 README「偏差」节）:
  - SQL 侧只做 NZ bbox 行组裁剪（单次 S3 扫描）；过滤链整体在 Python 侧执行，
    使 selftest fixture 与生产走同一代码路径，且 stats 能给出逐阶段剩余数。
  - 流式 fetchmany(10000)，不整表 fetchall（r4s 3.77GiB 内存约束），无需 pyarrow。

JSONL 契约（apps 侧 T2 overture.go adapter 依赖，字段顺序固定）:
  {"id","name","basic_category","taxonomy","lat","lng","confidence",
   "address","locality","website","phone","city_slug"}
  lat/lng = bbox 中心 (xmin+xmax)/2,(ymin+ymax)/2（point 数据二者相等），6 位小数；
  city_slug 由 8 城外接矩形判定，未命中城市的行丢弃并计数（national 非地理判定）。
"""

import argparse
import json
import os
import sys
import tempfile
import time

RELEASE_DEFAULT = "2026-10-21.0"
OUT_DEFAULT = "/mnt/mmc1-4/Data/overture/overture-nz.jsonl"

# NZ bbox: minLng, maxLng, minLat, maxLat（#392/#400 规格）。
NZ_BBOX = (166.0, 178.6, -47.3, -34.4)

# 类目白名单：与 apps 侧 osmKinds 7 类语义对齐的 basic_category 集合
# （#400 计划 Task 1 Step 1 候选集；餐饮/住宿/博物馆等不在首批——类目扩展另立单）。
# 映射真值源 = osm.go osmKinds + T2 overtureCategoryMap：
#   playground→playground; beach→beach; garden/botanical_garden/park→garden/recreation;
#   viewpoint/scenic_lookout→viewpoint; art_gallery/public_art/art_studio→art;
#   theater/stadium/concert_hall/arena→venues;
#   sports_and_recreation/sport_or_fitness_facility/gym/fitness_studio/
#   swimming_pool/recreation_center→recreation
CATEGORY_WHITELIST = frozenset({
    "playground", "beach", "park", "garden", "viewpoint",
    "scenic_lookout", "art_gallery", "public_art", "theater",
    "stadium", "concert_hall", "sports_and_recreation",
    "sport_or_fitness_facility", "gym", "fitness_studio",
    "swimming_pool", "recreation_center", "botanical_garden",
    "art_studio", "arena",
})

# operating_status 门：正常/未知放行（NULL=未知），closed/removed 类拒收。
# 实现为白名单式（NULL 或 'operating' 之外一律拒收并按值计数）——与 #400 计划
# SQL `operating_status IS NULL OR operating_status='operating'` 等价；未来 release
# 出现新枚举值时保守拒收，值会出现在 stats.dropped_status_values 供人工核对。
OPERATING_STATUS_ALLOW = frozenset({None, "operating"})

# 城市外接矩形 (slug, minLng, maxLng, minLat, maxLat)。
# 生成方式：读 noda-apps packages/geo/src/data/nearby-geo.json，每城取其全部区
# （centroid+radiusKm 圆）的外接矩形并集；顺序即命中优先级（geo json 城市序，
# 实测八城矩形互不重叠）。national 是兜底分类非地理判定，不参与。8 城生成快照见
# README「城市 bbox 来源」——geo 数据变化时按同法重算。
CITY_BBOXES = (
    ("auckland", 174.479, 175.041, -37.074, -36.615),
    ("wellington", 174.537, 175.015, -41.466, -41.106),
    ("christchurch", 172.388, 172.884, -43.712, -43.352),
    ("hamilton", 175.109, 175.451, -37.922, -37.652),
    ("rotorua", 176.079, 176.421, -38.275, -38.005),
    ("tauranga", 175.996, 176.336, -37.822, -37.552),
    ("queenstown", 168.471, 168.913, -45.166, -44.887),
    ("dunedin", 170.270, 170.697, -46.009, -45.739),
)

# JSONL 字段契约（顺序即输出顺序；apps T2 依赖）。
# operating_status：收录语义——T1 仅收录 NULL/unknown（=按开放处理）与 'operating'
# 行，故恒归一为 "operating"。⚠ apps T3 失效 diff 的「operating_status != 'operating'」
# 分支对本输出恒不触发（by design），月度失效检测靠「行消失于本批」分支；若未来
# 放行 closed 行进 JSONL，此字段立即携带真实值——切勿改回输出 NULL/unknown 裸值
# （T3 裸值比较会把 unknown 行全部误 expired）。
JSONL_FIELDS = ("id", "name", "basic_category", "taxonomy", "lat", "lng",
                "confidence", "address", "locality", "website", "phone",
                "city_slug", "operating_status")

# 过滤链阶段名（顺序即执行序；after_X = 通过第 X 步后剩余行数）。
STAGE_KEYS = ("after_category", "after_confidence", "after_name_coord",
              "after_status", "kept")
# 丢弃原因 → 已通过的阶段数（category=第一步就没过，no_city=前四步全过）。
_PASSED_STAGES = {"category": 0, "confidence": 1, "name_coord": 2,
                  "status": 3, "no_city": 4, None: 5}


def city_for_point(lng, lat):
    """命中首个城市外接矩形即返回 slug；未命中返回 None（丢弃计数）。"""
    for slug, x0, x1, y0, y1 in CITY_BBOXES:
        if x0 <= lng <= x1 and y0 <= lat <= y1:
            return slug
    return None


def new_stats(release=""):
    return {
        "release": release,
        "stages": {"bbox_rows": 0, "after_category": 0, "after_confidence": 0,
                   "after_name_coord": 0, "after_status": 0, "kept": 0},
        "dropped": {"category": 0, "confidence": 0, "name_coord": 0,
                    "status": 0, "no_city": 0},
        "dropped_status_values": {},
        "dropped_categories_top": {},
        "cities": {},
        "categories": {},
    }


def process_row(row):
    """单行过滤链（纯函数，selftest 与生产共用）。

    返回 (record, None) 收录；或 (None, drop_reason) 丢弃。
    reason ∈ {category, confidence, name_coord, status, no_city}。
    row 键 = build_query 的 SELECT 列名（duckdb 行字典或 fixture）。
    """
    # ① 类目白名单
    cat = row.get("basic_category")
    if cat not in CATEGORY_WHITELIST:
        return None, "category"
    # ② confidence >= 0.8
    try:
        conf = float(row.get("confidence"))
    except (TypeError, ValueError):
        return None, "confidence"
    if conf < 0.8:
        return None, "confidence"
    # ③ 有名称有坐标
    name = row.get("name")
    if not name or not str(name).strip():
        return None, "name_coord"
    try:
        lng = float(row.get("lng"))
        lat = float(row.get("lat"))
    except (TypeError, ValueError):
        return None, "name_coord"
    # ④ operating_status：NULL/'operating' 放行，closed/removed 类拒收
    status = row.get("operating_status")
    if status not in OPERATING_STATUS_ALLOW:
        return None, "status"
    # ⑤ 城市打区（bbox 外丢弃计数）
    slug = city_for_point(lng, lat)
    if slug is None:
        return None, "no_city"
    rec = {
        "id": row["id"],
        "name": str(name).strip(),
        "basic_category": cat,
        "taxonomy": row.get("taxonomy") or "",
        "lat": round(lat, 6),
        "lng": round(lng, 6),
        "confidence": conf,
        "address": row.get("address") or "",
        "locality": row.get("locality") or "",
        "website": row.get("website") or "",
        "phone": row.get("phone") or "",
        "city_slug": slug,
        "operating_status": "operating",
    }
    return rec, None


def run_chain(rows, out_fh, stats):
    """整链驱动：逐行 过滤 → 打区 → 写 JSONL → 更新 stats。

    rows 为 duckdb 行字典（或 selftest fixture）可迭代对象；返回 stats。
    """
    for row in rows:
        stats["stages"]["bbox_rows"] += 1
        rec, reason = process_row(row)
        for i in range(_PASSED_STAGES[reason]):
            stats["stages"][STAGE_KEYS[i]] += 1
        if rec is None:
            stats["dropped"][reason] += 1
            if reason == "category":
                cat = str(row.get("basic_category"))
                stats["dropped_categories_top"][cat] = \
                    stats["dropped_categories_top"].get(cat, 0) + 1
            elif reason == "status":
                sv = str(row.get("operating_status"))
                stats["dropped_status_values"][sv] = \
                    stats["dropped_status_values"].get(sv, 0) + 1
            continue
        stats["cities"][rec["city_slug"]] = stats["cities"].get(rec["city_slug"], 0) + 1
        stats["categories"][rec["basic_category"]] = \
            stats["categories"].get(rec["basic_category"], 0) + 1
        out_fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return stats


def build_query(release):
    """S3 直查 SQL：只做 NZ bbox 行组裁剪 + 列抽取；过滤链在 Python 侧。"""
    min_lng, max_lng, min_lat, max_lat = NZ_BBOX
    return f"""
    SELECT id,
           names.primary AS name,
           basic_category,
           taxonomy.primary AS taxonomy,
           confidence,
           operating_status,
           (bbox.xmin + bbox.xmax) / 2 AS lng,
           (bbox.ymin + bbox.ymax) / 2 AS lat,
           list_filter(addresses, a -> a.locality IS NOT NULL)[1].locality AS locality,
           list_filter(addresses, a -> a.freeform IS NOT NULL)[1].freeform AS address,
           websites[1] AS website,
           phones[1] AS phone
    FROM read_parquet(
        's3://overturemaps-us-west-2/release/{release}/theme=places/type=place/*',
        hive_partitioning=1)
    WHERE bbox.xmin >= {min_lng} AND bbox.xmin <= {max_lng}
      AND bbox.ymin >= {min_lat} AND bbox.ymin <= {max_lat}
    """


def fetch_and_write(release, out):
    """真实下载路径：duckdb httpfs 流式读 → run_chain → 原子替换 out。"""
    import duckdb  # 延迟导入：selftest/pytest 不依赖

    out_dir = os.path.dirname(os.path.abspath(out))
    os.makedirs(out_dir, exist_ok=True)
    t0 = time.time()
    stats = new_stats(release)
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs; SET s3_region='us-west-2';")
    # duckdb 1.4+ 弃用单箭头 lambda（build_query 的 list_transform 用 x -> ... 形态，
    # 2026-11-18 docker 兜底首跑 BinderException 判例）：新版本显式开回旧语法兼容，
    # 旧版本不识该 SET 则忽略（本查询 lambda 形态在旧版本本就合法）。
    try:
        con.execute("SET lambda_syntax='ENABLE_SINGLE_ARROW'")
    except Exception:
        pass
    cur = con.execute(build_query(release))
    cols = [d[0] for d in cur.description]
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        while True:
            batch = cur.fetchmany(10000)
            if not batch:
                break
            run_chain((dict(zip(cols, tup)) for tup in batch), fh, stats)
            n = stats["stages"]["bbox_rows"]
            if n % 100000 < 10000:
                print(f"... scanned {n} bbox rows, kept {stats['stages']['kept']}",
                      file=sys.stderr, flush=True)
    os.replace(tmp, out)
    stats["minutes"] = round((time.time() - t0) / 60, 1)
    stats["duckdb_version"] = duckdb.__version__
    with open(out + ".stats.json", "w", encoding="utf-8") as fh:
        json.dump(stats, fh, ensure_ascii=False, indent=1, sort_keys=True)
    print("kept=%d dropped_nocity=%d minutes=%s out=%s"
          % (stats["stages"]["kept"], stats["dropped"]["no_city"],
             stats["minutes"], out))
    return stats


# ---------------------------------------------------------------------------
# --selftest：内置 fixture 走完整 过滤/打区/输出 链，不触网。
# ---------------------------------------------------------------------------

def _fixture_row(pid, name, cat, conf, status, lng, lat,
                 taxonomy="", locality="", address="", website="", phone=""):
    """构造与 build_query 列名一致的合成行。"""
    return {"id": pid, "name": name, "basic_category": cat, "taxonomy": taxonomy,
            "confidence": conf, "operating_status": status, "lng": lng, "lat": lat,
            "locality": locality, "address": address, "website": website,
            "phone": phone}


SELFTEST_ROWS = [
    # 收录：park conf 0.93 operating，Auckland 坐标
    _fixture_row("08f1a2selftest0001", "Cornwall Park", "park", 0.93, "operating",
                 174.779, -36.897, taxonomy="park", locality="Auckland",
                 address="Greenlane, Auckland 1051", website="https://example.co.nz",
                 phone="+64 9 000 0000"),
    # 丢弃 confidence：0.5 < 0.8
    _fixture_row("08f1a2selftest0002", "Low Conf Beach", "beach", 0.5, "operating",
                 174.78, -36.90),
    # 丢弃 status：closed
    _fixture_row("08f1a2selftest0003", "Closed Garden", "garden", 0.95, "closed",
                 174.78, -36.90),
    # 丢弃 status：permanently_closed（removed 类拒收）
    _fixture_row("08f1a2selftest0004", "Gone Pool", "swimming_pool", 0.99,
                 "permanently_closed", 174.78, -36.90),
    # 丢弃 category：餐饮类排除
    _fixture_row("08f1a2selftest0005", "Cafe One", "restaurant", 0.99, "operating",
                 174.78, -36.90),
    # 丢弃 name_coord：无名称
    _fixture_row("08f1a2selftest0006", None, "park", 0.99, "operating",
                 174.78, -36.90),
    # 丢弃 name_coord：无坐标
    _fixture_row("08f1a2selftest0007", "No Coords", "park", 0.99, "operating",
                 None, None),
    # 收录：garden status NULL（未知放行），Wellington 坐标
    _fixture_row("08f1a2selftest0008", "Botanic Playground 花园", "botanical_garden",
                 0.80, None, 174.776, -41.288),
    # 收录：viewpoint，Queenstown 坐标（conf=0.8 边界含）
    _fixture_row("08f1a2selftest0009", "Queenstown Lookout", "scenic_lookout",
                 0.8, "operating", 168.66, -45.03),
    # 丢弃 no_city：whitelist+conf+status 全过但坐标不在任何城市矩形
    _fixture_row("08f1a2selftest0010", "Wild Coast Park", "park", 0.9, "operating",
                 172.0, -41.0),
]

SELFTEST_EXPECT = {
    "kept": 3,
    "dropped": {"category": 1, "confidence": 1, "name_coord": 2,
                "status": 2, "no_city": 1},
    "cities": {"auckland": 1, "wellington": 1, "queenstown": 1},
}


def selftest():
    """完整链 fixture 断言；全过打印 selftest ok 并返回 0。"""
    # 打区基础断言（#400 计划骨架形态）
    assert city_for_point(174.77, -36.90) == "auckland"
    assert city_for_point(174.776, -41.288) == "wellington"
    assert city_for_point(168.66, -45.03) == "queenstown"
    assert city_for_point(0.0, 0.0) is None
    tmpdir = tempfile.mkdtemp(prefix="overture-selftest-")
    out = os.path.join(tmpdir, "overture-nz.jsonl")
    stats = new_stats("selftest")
    with open(out, "w", encoding="utf-8") as fh:
        run_chain(SELFTEST_ROWS, fh, stats)
    # 阶段/丢弃/城市分布断言
    st = stats["stages"]
    assert st["bbox_rows"] == len(SELFTEST_ROWS), st
    assert st["kept"] == SELFTEST_EXPECT["kept"], st
    assert stats["dropped"] == SELFTEST_EXPECT["dropped"], stats["dropped"]
    assert stats["cities"] == SELFTEST_EXPECT["cities"], stats["cities"]
    # 各阶段剩余精确值（10 行 → cat 过 9 → conf 过 8 → name/coord 过 6
    #   → status 过 4 → 城市（kept）3）
    assert st["after_category"] == 9, st
    assert st["after_confidence"] == 8, st
    assert st["after_name_coord"] == 6, st
    assert st["after_status"] == 4, st
    # 链上守恒：bbox_rows = kept + 全部丢弃
    assert st["bbox_rows"] == st["kept"] + sum(stats["dropped"].values())
    # status 丢弃按值计数可见
    assert stats["dropped_status_values"] == {"closed": 1, "permanently_closed": 1}
    # JSONL 契约：字段顺序/类型/rounding/UTF-8 保留
    lines = open(out, encoding="utf-8").read().splitlines()
    assert len(lines) == SELFTEST_EXPECT["kept"]
    recs = [json.loads(ln) for ln in lines]
    for rec in recs:
        assert tuple(rec.keys()) == JSONL_FIELDS, rec
        assert isinstance(rec["id"], str) and rec["id"]
        assert isinstance(rec["name"], str) and rec["name"]
        assert isinstance(rec["lat"], float) and isinstance(rec["lng"], float)
        assert isinstance(rec["confidence"], float) and rec["confidence"] >= 0.8
        assert rec["city_slug"] in {c[0] for c in CITY_BBOXES}
    by_id = {r["id"]: r for r in recs}
    zh = by_id["08f1a2selftest0008"]
    assert zh["name"] == "Botanic Playground 花园"      # ensure_ascii=False
    assert zh["taxonomy"] == "" and zh["city_slug"] == "wellington"
    assert zh["operating_status"] == "operating"         # NULL 归一（T3 防误杀）
    full = by_id["08f1a2selftest0001"]
    assert full["lat"] == round(-36.897, 6) and full["lng"] == round(174.779, 6)
    assert full["phone"] == "+64 9 000 0000"
    # 白名单/状态门语义抽查
    assert "restaurant" not in CATEGORY_WHITELIST
    assert "park" in CATEGORY_WHITELIST and "arena" in CATEGORY_WHITELIST
    assert len(CATEGORY_WHITELIST) == 20
    for bad in ("closed", "permanently_closed", "temporarily_closed",
                "relocated", "removed"):
        assert bad not in OPERATING_STATUS_ALLOW
    # build_query 守卫：S3 参数化路径 + bbox + 无 python 侧过滤残留
    sql = build_query("2026-10-21.0")
    assert "s3://overturemaps-us-west-2/release/2026-10-21.0/" in sql
    assert "hive_partitioning=1" in sql and "166.0" in sql
    assert "confidence >=" not in sql    # 过滤链在 Python 侧（by design）
    print("selftest ok")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Overture NZ places 预处理下载（#392 T1）")
    ap.add_argument("--release", default=RELEASE_DEFAULT,
                    help="Overture release 版本号（默认 %s）" % RELEASE_DEFAULT)
    ap.add_argument("--out", default=OUT_DEFAULT,
                    help="JSONL 输出路径（默认 %s；月度链传日期版本目录）" % OUT_DEFAULT)
    ap.add_argument("--selftest", action="store_true",
                    help="不触网，内置 fixture 走完整过滤/打区/输出链")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    fetch_and_write(args.release, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
