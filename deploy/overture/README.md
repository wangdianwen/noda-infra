# Overture NZ places 预处理（noda-apps #392 WS1 · infra 侧 T1+T6）

Overture Maps places 月度 release → NZ bbox 子集下载 → 过滤 → 城市标注 JSONL，
供 apps 侧 `crawl-overture` job（T2/T3，`nearby/api/nearbydata/overture.go`）摄取。
月度自动化链见同目录 `overture-monthly.sh`。

## 文件

| 文件 | 职责 |
|---|---|
| `fetch-overture-nz.py` | T1 下载脚本：DuckDB httpfs 直查 S3 GeoParquet → 过滤链 → JSONL + stats |
| `overture-monthly.sh` | T6 r4s 月度自动链：duckdb 自检 → 下载 → 触发 crawl-overture → TG/hb |

## fetch-overture-nz.py

```
fetch-overture-nz.py [--release 2026-10-21.0]
                     [--out /mnt/mmc1-4/Data/overture/overture-nz.jsonl]
                     [--selftest]
```

- 单次全 bbox 扫描 ~25 min（S3 官方通道无频控；月度一次，勿高频）。
- DuckDB 获取：`pip install duckdb`（月度链 venv 自检/安装见 overture-monthly.sh）。
- `--selftest` 不触网，内置 fixture 走完整过滤/打区/输出链（pytest 亦覆盖）。

### 过滤链（顺序执行；stats 逐阶段计数）

1. SQL 侧 NZ bbox `166,178.6,-47.3,-34.4`（parquet 行组裁剪，单次 S3 扫描）
2. 类目白名单 `CATEGORY_WHITELIST`（26 个 basic_category，osmKinds 7 类语义 +
   餐饮业态 6 类（WS6 #397）；住宿/博物馆等排除，类目扩展另立单）
3. `confidence >= 0.8`（边界含）
4. 有名称有坐标
5. operating_status：`NULL`/`operating` 放行，`closed`/`permanently_closed` 等
   closed/removed 类拒收（白名单式：新枚举值保守拒收，值见
   `stats.dropped_status_values` 供人工核对）
6. 8 城外接矩形打区 `city_slug`；未命中城市的行**不再丢弃**（#392 AC1
   region≥12 全国扩容，2026-11-19）——`city_slug` 输出空串走全国兜底，apps
   adapter 侧落 `city_slug='national'` + `geo.ResolveRegionPoint` 坐标锚点
   归属 16 大区（`fix/392-overture-nationwide` 对应 apps 仓
   `fix/392-confidence-region`）；无城市餐饮行由 apps 侧 5 城门拦截。全国行
   计数见 `stats.national`。旧 apps adapter（全国兜底前）对空 `city_slug` 按
   DroppedNoCity 丢弃——两仓部署顺序任意、双向兼容。

### JSONL 字段契约（apps T2 adapter 依赖；顺序固定）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | str | Overture place id（幂等键 `source_url=https://overturemaps.org/place/{id}`） |
| `name` | str | names.primary（非空） |
| `basic_category` | str | 白名单内类目 |
| `taxonomy` | str | taxonomy.primary，缺省 "" |
| `lat` / `lng` | float | bbox 中心 `(xmin+xmax)/2,(ymin+ymax)/2`，6 位小数 |
| `confidence` | float | ≥0.8 |
| `address` | str | addresses 首个 freeform，缺省 "" |
| `locality` | str | addresses 首个 locality，缺省 "" |
| `website` | str | websites[1]，缺省 "" |
| `phone` | str | phones[1]，缺省 "" |
| `city_slug` | str | 8 城之一（auckland/wellington/christchurch/hamilton/rotorua/tauranga/queenstown/dunedin）或空串（#392 AC1 全国兜底：8 城外行，apps 侧 national+大区归属） |
| `operating_status` | str | 恒 `"operating"`（收录语义：NULL/unknown 按开放收录后归一。⚠ T3 失效 diff 勿以裸值比较 unknown——见 fetch 脚本 JSONL_FIELDS 注释） |

示例行：
`{"id":"08f1a2...","name":"Cornwall Park","basic_category":"park","taxonomy":"park","lat":-36.897,"lng":174.779,"confidence":0.93,"address":"Greenlane, Auckland 1051","locality":"Auckland","website":"https://...","phone":"+64 9 ...","city_slug":"auckland","operating_status":"operating"}`

### stats（`<out>.stats.json`）

`stages`（bbox_rows → after_category → after_confidence → after_name_coord →
after_status → kept）、`dropped`（逐原因）、`national`（#392 AC1 全国兜底收录数）、
`dropped_status_values`（status 丢值直方图）、`dropped_categories_top`、`cities`
（各城分布）、`categories`（收录类目分布）、`minutes`、`duckdb_version`。

### 城市 bbox 来源

`CITY_BBOXES` 由 noda-apps `packages/geo/src/data/nearby-geo.json` 生成（2026-11-18
快照，8 城）：每城取全部区（centroid+radiusKm 圆）的外接矩形并集。重算：

```python
import json, math
d = json.load(open('packages/geo/src/data/nearby-geo.json'))
def bb(lat, lng, r):
    return (lng - r/(111.32*math.cos(math.radians(lat))), lng + r/(111.32*math.cos(math.radians(lat))),
            lat - r/111.32, lat + r/111.32)
for c in d['cities']:
    boxes = [bb(x['centroid']['lat'], x['centroid']['lng'], x['radiusKm']) for x in c['districts']]
    print(c['slug'], round(min(b[0] for b in boxes),3), round(max(b[1] for b in boxes),3),
          round(min(b[2] for b in boxes),3), round(max(b[3] for b in boxes),3))
```

外接矩形近郊重叠误差可接受——精确打区由 apps 侧 `geo.ResolveDistrict` 点级判定。

## 与 #400 计划的偏差（有意为之）

- **过滤链在 Python 侧、SQL 只做 bbox 裁剪**：使 selftest fixture 与生产走同一
  代码路径，且 stats 能给逐阶段计数；单次 S3 扫描成本不变。
- **fetchmany(10000) 流式读**替代 fetch_record_batch（免 pyarrow 依赖）与
  fetchall（r4s 3.77GiB 内存约束）。
- **basic_category 全分布 top120 留档未做**（计划 Step 1 需全 bbox 扫描，本地不跑
  全量）：白名单取计划候选集原样定稿；首次 r4s 全量跑（T7）后可用
  `stats.dropped_categories_top` / `categories` 复核，如需全分布留档执行计划
  Step 1 查询并归档 `basic-category-distribution-<release>.txt`。
- `phones[1]` 假定 varchar[]（当前 Overture schema）；若 release 改为
  list<struct> 首跑会报类型错，改为 `phones[1].value` 即可。
