#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nginx URL 树跨仓对账守卫（noda-infra#4，2026-10-26）

背景：2026-10-24/#48 上线 playground 分类 + geo 仓补 rotorua 八城后，仅
nginx default.conf 城市正则/分类组落后 —— 794 条 playground 详情 URL 全 404
（T0 两页红）。本守卫把 nginx 正则里的集合与 noda-apps 单一真源逐项对账，
多/少都报错，防再次漂移。Jenkins nginx 发版路径（Jenkinsfile.infra Deploy
阶段）在构建镜像前运行本脚本。

真源（noda-apps）：
  - 城市集: packages/geo/src/data/nearby-geo.json 的 cities[].slug
    （生成 common/go/geo/districts_gen.go 的同一份 JSON）
  - 分类集: nearby/api/nearbyapi/urltree.go 的 placeCategoryWhitelist
    （places 线分类白名单，issue#31 规则 1）
  - 城市线组: 同文件 proxyCityLines（issue #283 新增真源——A1 城市线
    alternation；2026-11-10 #283 实证漏 markets 致 sitemap 在列市场页
    三语 404，本组对账即防复发）

被查面（本仓 config/nginx）：
  - conf.d/default.conf: 六处城市组（prod apex 块 A1/A2-④/A2-⑤ + noda.test
    演练块镜像三处）+ A1 分类组（prod 与演练块两处）
  - liuyao-local.conf.example: nearby-prepred 块镜像的同类组（若文件存在）
    语义：A1 城市组 == 真源城市 + national 兜底；A2-④/⑤ 城市组 == 真源城市；
    A1 分类组 == 真源分类白名单。集合序不敏感（nginx 正则 alternation 无序语义）。

用法：
  NODA_APPS_DIR=/path/to/noda-apps python3 scripts/check-nginx-urltree.py
  # NODA_APPS_DIR 缺省时依次尝试 <本仓>/noda-apps、<本仓>/../noda-apps
退出码：0=对账通过；1=任何集合不等/文件缺失/解析失败（附带多/少明细）。
纯标准库，无第三方依赖。
"""

import json
import os
import re
import sys

GEO_JSON_RELPATH = "packages/geo/src/data/nearby-geo.json"
URLTREE_GO_RELPATH = "nearby/api/nearbyapi/urltree.go"
NATIONAL = "national"

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  [FAIL] {msg}")


def ok(msg):
    print(f"  [ok] {msg}")


def repo_root():
    # 脚本位于 <repo>/scripts/ 下
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def resolve_apps_dir():
    """定位 noda-apps 检出：环境变量优先，其次仓内 symlink / 兄弟目录。"""
    candidates = []
    env = os.environ.get("NODA_APPS_DIR")
    if env:
        candidates.append(env)
    root = repo_root()
    candidates += [os.path.join(root, "noda-apps"), os.path.join(root, "..", "noda-apps")]
    for c in candidates:
        if os.path.isfile(os.path.join(c, GEO_JSON_RELPATH)):
            return os.path.normpath(c), (c == env and "env" or "auto")
    print("找不到 noda-apps 检出（需含 %s）。尝试过:" % GEO_JSON_RELPATH)
    for c in candidates:
        print("  - %s" % c)
    print("请设置 NODA_APPS_DIR 指向 noda-apps 仓路径。")
    sys.exit(1)


def load_truth_sets(apps_dir):
    """真源集合：城市 slug 集 + places 线分类白名单集。"""
    with open(os.path.join(apps_dir, GEO_JSON_RELPATH), encoding="utf-8") as f:
        cities = {c["slug"] for c in json.load(f)["cities"]}

    go_path = os.path.join(apps_dir, URLTREE_GO_RELPATH)
    with open(go_path, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"placeCategoryWhitelist\s*=\s*\[\]string\{([^}]*)\}", src)
    if not m:
        print(f"无法在 {URLTREE_GO_RELPATH} 解析 placeCategoryWhitelist（定义漂移？）")
        sys.exit(1)
    cats = set(re.findall(r'"([^"]+)"', m.group(1)))
    # proxyCityLines 元素是 line* 常量标识符：先建 标识符→字面量 映射再解析
    idents = dict(re.findall(r"^\s*(\w+)\s*=\s*\"([^\"]+)\"", src, re.M))
    m = re.search(r"proxyCityLines\s*=\s*\[\]string\{([^}]*)\}", src)
    if not m:
        print(f"无法在 {URLTREE_GO_RELPATH} 解析 proxyCityLines（定义漂移？）")
        sys.exit(1)
    toks = [t.strip() for t in m.group(1).split(",") if t.strip()]
    lines = set()
    for t in toks:
        lm = re.fullmatch(r'"([^"]+)"', t)
        val = lm.group(1) if lm else idents.get(t)
        if not val:
            print(f"proxyCityLines 含未解析标识符 {t}（常量定义漂移？）")
            sys.exit(1)
        lines.add(val)
    return cities, cats, lines


def check_set(label, line_no, actual, expected):
    """集合全等断言：多/少都逐项列出。"""
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    where = f"{label}(L{line_no})"
    if missing or extra:
        if missing:
            fail(f"{where} 少了: {','.join(missing)}")
        if extra:
            fail(f"{where} 多了: {','.join(extra)}")
    else:
        ok(f"{where} == 期望集（{len(actual)} 项）")


# ── nginx 侧解析 ────────────────────────────────────────────────────────────
# 城市组形态：(?:auckland|wellington|...|national?) —— 锚定首城 auckland 防误配
CITY_GROUP_RE = re.compile(r"\(\?:auckland((?:\|[a-z0-9-]+)+)\)")
# A1 分类组形态：places(?:/(?:attractions|...))? —— 仅 A1 城市树详情线有
A1_CATEGORY_RE = re.compile(r"places\(\?:/\(\?:([a-z0-9-]+(?:\|[a-z0-9-]+)*)\)\)\?")
# A1 城市线组形态：)?|events|news|deals|hidden-gems|markets)/ —— 紧跟分类组
# 之后的 alternation（#283 对账面：漏 markets = sitemap 在列市场页 404）
A1_CITYLINE_RE = re.compile(r"\)\?\|([a-z][a-z-]*(?:\|[a-z][a-z-]*)*)\)/")


def check_conf(path, label, cities, cats, city_lines, min_city_hits):
    """解析单个 conf 文件中的城市组、A1 分类组与 A1 城市线组并对账。"""
    print(f"\n[{label}] {os.path.relpath(path, repo_root())}")
    if not os.path.isfile(path):
        fail(f"文件不存在: {path}")
        return
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    city_hits = cat_hits = line_hits = 0
    for i, line in enumerate(lines, 1):
        is_a1 = A1_CATEGORY_RE.search(line) is not None
        if is_a1:
            lm = A1_CITYLINE_RE.search(line)
            if not lm:
                fail(f"L{i} A1 行未解析出城市线组（形态漂移，守卫失明）")
            else:
                check_set(f"A1 城市线组", i, set(lm.group(1).split("|")), city_lines)
                line_hits += 1
        for m in CITY_GROUP_RE.finditer(line):
            group = set(("auckland",) + tuple(m.group(1).lstrip("|").split("|")))
            # 含 national = A1 城市树详情线（+兜底城）；A2-④/⑤ 旧城市线不含
            if NATIONAL in group:
                check_set(f"A1 城市组", i, group, cities | {NATIONAL})
            else:
                check_set(f"A2 城市组", i, group, cities)
            city_hits += 1
        for m in A1_CATEGORY_RE.finditer(line):
            check_set(f"A1 分类组", i, set(m.group(1).split("|")), cats)
            cat_hits += 1

    if city_hits < min_city_hits:
        fail(f"城市组命中 {city_hits} 处 < 期望 {min_city_hits} 处（正则形态漂移，守卫失明）")
    else:
        ok(f"城市组共 {city_hits} 处全部核对")
    if cat_hits == 0:
        fail("A1 分类组零命中（places(?:/(?:…))? 形态漂移，守卫失明）")
    else:
        ok(f"A1 分类组共 {cat_hits} 处全部核对")
    if line_hits == 0:
        fail("A1 城市线组零命中（)?|线段)/ 形态漂移，守卫失明）")
    else:
        ok(f"A1 城市线组共 {line_hits} 处全部核对")


def main():
    apps_dir, how = resolve_apps_dir()
    cities, cats, city_lines = load_truth_sets(apps_dir)
    print("== nginx URL 树跨仓对账守卫 ==")
    print(f"noda-apps 检出({how}): {apps_dir}")
    print(f"真源城市集({len(cities)}): {','.join(sorted(cities))}")
    print(f"真源分类集({len(cats)}): {','.join(sorted(cats))}")
    print(f"真源城市线组({len(city_lines)}): {','.join(sorted(city_lines))}")

    root = repo_root()
    # default.conf：六处城市组（A1×2 + A2-④×2 + A2-⑤×2）+ A1 分类组×2
    check_conf(os.path.join(root, "config/nginx/conf.d/default.conf"),
               "prod 主面", cities, cats, city_lines, min_city_hits=6)
    # liuyao 本机模板：nearby-prepred 镜像面（A1 + A2-④/⑤ = 3 处城市组 + 1 分类组）
    check_conf(os.path.join(root, "config/nginx/liuyao-local.conf.example"),
               "prepred 模板", cities, cats, city_lines, min_city_hits=3)
    # liuyao-local.conf 实文件（Mac preprod nginx 真跑面，2026-11-11 #283 排查发现
    # 它落后 example 一整个 W1 同步——漏 hidden-gems/markets 双线，纳入对账防再漂）。
    # 该文件 gitignore、仅存在于实跑机本盘；CI workspace 无此文件属正常，跳过不算过（不算败）
    live_conf = os.path.join(root, "config/nginx/liuyao-local.conf")
    if os.path.exists(live_conf):
        check_conf(live_conf, "prepred 实面", cities, cats, city_lines, min_city_hits=3)
    else:
        print("[skip] prepred 实面 config/nginx/liuyao-local.conf 本机不存在（gitignore 实跑文件，CI 跳过）")

    print()
    if FAILURES:
        print(f"对账失败：{len(FAILURES)} 处不等/缺失（上方明细）。nginx 与 noda-apps 真源漂移，禁止发版。")
        sys.exit(1)
    print("对账通过：nginx 城市组/分类组/城市线组与 noda-apps 真源全等。")
    sys.exit(0)


if __name__ == "__main__":
    main()
