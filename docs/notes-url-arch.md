# URL 架构 v2 — nginx 层冒烟清单与实现注记（issue#31 层D，分支 url-arch-301）

改动面：`config/nginx/conf.d/default.conf`（prod apex noda.co.nz 块 + noda.test 演练块同构镜像）、
`config/nginx/conf.d/nearby.map.conf`（新增 `$nearby_places_args_go` map + D7 桥注记）。
城市常量（七城+national）与 category25（四组 25 slug）源：noda-apps `common/go/geo/districts_gen.go` + `geo.go`。

## curl 冒烟清单（上线/W7 preprod 后逐条；prod 直接打 https://noda.co.nz，preprod 走 noda.test）

```sh
BASE=https://noda.co.nz

# 1) A1 新详情 → Go（期望：经 nginx 到 nearbyapi；Go 未上线批1 handler 前 = Go 404/502 JSON；
#    批1 Go 上线后：200 壳或 301 canonical 段强制）
curl -sI $BASE/auckland/events/some-slug-abc123def456          # → 非 nginx 404.html，应含 proxy 特征（无 X-Cache-Status 也非桶 404）
curl -sI $BASE/auckland/places/markets/matakana-a1b2c3d4e5f6   # 4 段式地点详情 → Go
curl -sI $BASE/zh/auckland/news/foo-0123456789ab               # zh 前缀 → Go
curl -sI $BASE/auckland/events/abc123def456                    # 纯 id12 → Go

# 2) 列表页 → 桶静态（不能进 Go）
curl -sI $BASE/auckland/events            # 200（桶）
curl -sI $BASE/auckland/places/markets    # 200（桶）
curl -sI $BASE/auckland/central           # 200 分区页（桶；category25 无重叠）
curl -sI $BASE/events $BASE/places        # 200（桶）

# 3) A2 旧 URL → Go（批1 Go 上线后 = 301 单跳到新树）
curl -sI $BASE/attractions/hobbiton-movie-set          # → Go（301 /auckland/places/attractions/…）
curl -sI $BASE/market/matakana-village-farmers-market  # → Go
curl -sI $BASE/event/auckland/this-weekend             # → Go（301 /auckland/events）
curl -sI $BASE/place                                   # → Go（301 /places/hidden-gems）
curl -sI $BASE/news/policy                             # → Go（301 /news）
curl -sI $BASE/auckland/event                          # → Go（301 /auckland/events）
curl -sI $BASE/auckland/food                           # → Go（301 城市新树）

# 4) slash 归一（301 无斜杠，query 保留）
curl -sI "$BASE/zh/places/"              # 301 → /zh/places
curl -sI "$BASE/auckland/events/"        # 301 → /auckland/events
curl -sI "$BASE/places/?type=market"     # 301 → /places?type=market
curl -sI "$BASE/"                        # 200（根不归一）

# 5) /places 带 query → Go（无 query 仍桶静态）
curl -sI "$BASE/places?type=market"      # → Go（批1 Go：301 /places/markets）
curl -sI "$BASE/zh/places?type=market"   # → Go
curl -sI $BASE/places                    # 200（桶）

# 6) /item/ 既有反代保持（Go 批1 改 301，nginx 无变化——确认项）
curl -sI $BASE/item/550e8400-e29b-41d4-a716-446655440000   # → Go（现状 head 注入；批1 后 301 新树）
```

断言口径：3/4/5 的 301 必须**单跳**直达最终 URL（`curl -sIL` 中转次数=1，D7）。

## 已知交互与偏差注记（评审重点）

1. **根路径 `/?type=event|place` 两跳**：`nearby.map.conf` 既有 `$nearby_type_redirect`
   先 301 到 `/event|/place`，而 `/event|/place` 现已进 Go 再 301 到 `/events|/places/hidden-gems`
   → 两跳。`/?type=news|deals` 仍单跳（目标 /news /deals 是桶页）。批次收尾时若要全量单跳，
   需把根 `?type=` 的 301 目标改为终态（或并给 Go）——本次按 A4「map 无 /item/ 项则不动」未改。
2. **`/{city}/news`、`/{city}/deals` 新旧同 URL**：旧类型页与批2 新城市列表 URL 相同。本配置按
   任务书 A2-④ 将其代理到 Go，Go 侧处置（渲染/透传/301）是 W2 契约；批2 桶静态上线后若这些
   列表要回桶，需同步回收本条 nginx 位置（W6/W8 回归项）。
3. **`/en/places?type=` 未覆盖**：任务书只列裸 /places 与 zh/zh-TW 两前缀；站内 `?type=` 内链
   经 localePath 不产生 /en 前缀形态，故 map 不含 en/ 变体。
4. **任务书 A1 正则的字面形态修正**：原文字面正则（可选分类组置于线段之前）永远匹配不到 4 段式
   地点详情 `/{city}/places/{cat}/{slug}-{id12}`；已按 issue#31 §1 结构序修正为
   `places(?:/{cat})?` 前置、末段 id12 形态约束（53/53 正反例模拟通过，见分支提交信息）。
5. **多尾斜杠（/a//）不归一**：归一 rewrite 捕获组收尾排除斜杠，防 301 到自身成环；该病态形态
   维持现状落桶。单尾斜杠全量 301。
6. **`{12}` 量词必须整体双引号**：nginx 词法在未引用正则的 `{` 处截断（本分支实测 emerg）。
7. **noda.test 演练块同步镜像**：该块自述「与 prod apex 块同构」是其存在目的（nginx -t + curl
   冒烟本地先过）；W7 preprod 冒烟依赖新路由面就位。liuyao-local.conf 的 nearby-preprod 块
   （Mac preprod 自包含挂载，不在 conf.d include 面）本次未动——若需 preprod 真机验证新路由，
   W7 前补同构镜像。

## 语法门复现（本机）

```sh
TMP=$(mktemp -d) && cp -R config/nginx "$TMP/nginx"
CID=$(docker create --entrypoint true noda-static:714ffa5)
docker cp "$CID:/etc/nginx/mime.types" "$TMP/nginx/" && mkdir -p "$TMP/nginx/geo" \
  && docker cp "$CID:/etc/nginx/geo/dbip-city-lite.mmdb" "$TMP/nginx/geo/" && docker rm "$CID"
docker run --rm -v "$TMP/nginx:/etc/nginx:ro" --entrypoint nginx noda-static:714ffa5 -t
# → syntax is ok / test is successful（官方 nginx:alpine 缺 geoip2 动态模块，不可用）
```
