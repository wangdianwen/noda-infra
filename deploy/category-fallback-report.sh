#!/bin/sh
# noda-apps#496 AC5 —— hidden-gems 兜底占比防护报表（周跑只读，2026-11-28 部署）。
# 口径（=noda-apps ops/issue496-category-audit/audit.mjs @ 60551bdf，纯 SQL 复刻）：
#   池 = nearby_items WHERE type='place'；分母 = status='active' 行（非 active 单列不计率）；
#   归线 = category_slugs 按序首个白名单命中（SLUG_TO_PLACE_CAT 30 slug，来源
#   nearby/web/src/lib/url-tree.ts:345 @ 959bb4d6，Go urltree.go:93 同 commit 镜像核对）；
#   无命中（或首命中为 obscure 哨兵）→ hidden-gems 兜底；兜底率 = hidden-gems 行/active 行。
# 基线 2026-11-28 = 65.31%（16,747/25,644，已与本脚本 SQL 实测对账一致）。
# 阈值默认 70% = 临时水位（现值 +~4.7pp 余量），待 #496 step2 业主拍板后修订
#   （拍板后基线 B，告警线建议 B+5pp，audit README §3.7）；env FALLBACK_ALERT_PCT 可覆写。
# 三重前置守卫（参照 swap-debt-guard 形态）：1min 负载 / postgres 容器在跑 / psql 可连，
#   任一不过 → TG 告警 + exit 1（cron 行尾 `|| hb fail` 落心跳；hb 由 cron 行持有，
#   与 r4s 宿主机全部既有任务同风格，脚本自身不发心跳）。
# 词表漂移哨兵（audit README §3.7 建议）：池内出现基线词表外新 slug → 并入告警，
#   基线存同目录 .category-fallback-slugs（首跑自动生成；新 slug 告警后并入基线=仅首现告警）。
# 周跑周日 07:00：06:30 已被 container-update-check 占用（2026-10-27 emSign 事件新增），
#   避开 05:00 镜像清理 / 05:10 快照 / 05:30 swap 清债 / 03:30 百度上传 / 06:00(每月1号) overture。
# 只读承诺：全程仅 SELECT；唯一写入 = 本机日志 + 词表基线文件（r4s 本地，非业务库）。
# 存档：noda-infra deploy/category-fallback-report.sh（本文件为其运行副本）。

LOG=/var/log/noda-category-fallback.log
SLUGS_FILE=/mnt/mmc1-4/System/Scripts/.category-fallback-slugs
ALERT_PCT=${FALLBACK_ALERT_PCT:-70}   # 临时水位，#496 step2 拍板后修订
LOAD_MAX=${LOAD_MAX:-4}
DB_CONTAINER=${DB_CONTAINER:-noda-infra-postgres-prod}
TS=$(date "+%F %T")
log() { echo "$TS $*" >> "$LOG"; }
tg() { /mnt/mmc1-4/System/Scripts/telegram-alert.sh "$*" >/dev/null 2>&1; }
psql() { docker exec "$DB_CONTAINER" psql -U postgres -d noda_prod -At -c "$1"; }

# SLUG_TO_PLACE_CAT 白名单 30 slug（url-tree.ts:345 @ 959bb4d6 镜像；改词表必须
# 同步 web/Go 双仓并在此同步，见 README）
WL="(VALUES
 ('market','markets'),('national-park','national-parks'),('obscure','hidden-gems'),
 ('attraction','attractions'),('campsite','camping'),('playground','playground'),
 ('track','tracks'),('attractions','attractions'),('camping','camping'),
 ('national-parks','national-parks'),('tracks','tracks'),
 ('restaurant','food'),('cafe','food'),('bar','food'),('casual_eatery','food'),
 ('fast_food','food'),('coffee_shop','food'),('chinese','food'),('japanese','food'),
 ('indian','food'),('thai','food'),('korean','food'),('vietnamese','food'),
 ('italian','food'),('pizza','food'),('mexican','food'),('turkish','food'),
 ('greek','food'),('seafood','food'),('malaysian','food'))"

# ---- 守卫 1：1 分钟负载 ----
load=$(awk '{print int($1)}' /proc/loadavg)
if [ "$load" -ge "$LOAD_MAX" ]; then
  log "SKIP: load=$load >= $LOAD_MAX"
  tg "noda#496 兜底报表跳过：r4s 1 分钟负载 $load >= $LOAD_MAX，周跑窗口另行观察（下个周日 07:00 自动重试）。"
  exit 1
fi

# ---- 守卫 2：DB 容器在跑 ----
state=$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)
if [ "$state" != "true" ]; then
  log "FAIL: container $DB_CONTAINER not running (state=$state)"
  tg "noda#496 兜底报表失败：postgres 容器 $DB_CONTAINER 未在运行（state=$state），请人工检查。"
  exit 1
fi

# ---- 守卫 3：psql 可连 ----
if [ "$(psql 'SELECT 1' 2>/dev/null)" != "1" ]; then
  log "FAIL: psql not connectable to noda_prod"
  tg "noda#496 兜底报表失败：容器在跑但 psql 连不上 noda_prod，请人工检查。"
  exit 1
fi

# ---- 主体：只读查询（任一失败 → TG + exit 1） ----
failq() {
  log "FAIL: $1"
  tg "noda#496 兜底报表失败：$1，请人工检查 /var/log/noda-category-fallback.log。"
  exit 1
}

# Q1 汇总：分母/分子/比率/落线分布/非 active 单列
q1=$(psql "WITH w(slug,cat) AS $WL,
classified AS (
  SELECT i.status AS status, COALESCE(c.cat,'hidden-gems') AS line
  FROM nearby_items i
  LEFT JOIN LATERAL (
    SELECT w.cat FROM unnest(i.category_slugs) WITH ORDINALITY AS u(slug,ord)
    JOIN w ON w.slug=u.slug ORDER BY u.ord LIMIT 1) c ON true
  WHERE i.type='place')
SELECT 'DEN|'||count(*) FROM classified WHERE status='active'
UNION ALL SELECT 'HG|'||count(*) FROM classified WHERE status='active' AND line='hidden-gems'
UNION ALL SELECT 'NA|'||count(*) FROM classified WHERE status<>'active'
UNION ALL SELECT 'LINE|'||line||'|'||count(*) FROM classified WHERE status='active' GROUP BY line
UNION ALL SELECT 'RATE|'||round(
  (SELECT count(*) FROM classified WHERE status='active' AND line='hidden-gems')::numeric*100
  / NULLIF((SELECT count(*) FROM classified WHERE status='active'),0), 2)") \
  || failq "兜底率汇总查询报错"
DEN=$(echo "$q1" | sed -n 's/^DEN|//p')
HG=$(echo "$q1" | sed -n 's/^HG|//p')
NA=$(echo "$q1" | sed -n 's/^NA|//p')
RATE=$(echo "$q1" | sed -n 's/^RATE|//p')
LINES=$(echo "$q1" | grep '^LINE|' | tr '\n' ' ')
if [ -z "$DEN" ] || [ -z "$HG" ] || [ -z "$RATE" ]; then failq "汇总结果缺失（DEN=$DEN HG=$HG RATE=$RATE，池结构异常？）"; fi

# Q2 按城兜底率（rate 降序，全城）
CITIES=$(psql "WITH w(slug,cat) AS $WL,
classified AS (
  SELECT i.city_slug AS city, COALESCE(c.cat,'hidden-gems') AS line
  FROM nearby_items i
  LEFT JOIN LATERAL (
    SELECT w.cat FROM unnest(i.category_slugs) WITH ORDINALITY AS u(slug,ord)
    JOIN w ON w.slug=u.slug ORDER BY u.ord LIMIT 1) c ON true
  WHERE i.type='place' AND i.status='active')
SELECT city||'|'||count(*)||'|'||count(*) FILTER (WHERE line='hidden-gems')||'|'||
       round(count(*) FILTER (WHERE line='hidden-gems')::numeric*100/count(*),2)
FROM classified GROUP BY city
ORDER BY round(count(*) FILTER (WHERE line='hidden-gems')::numeric*100/count(*),2) DESC") \
  || failq "按城分布查询报错"

# Q3 hidden-gems 残池 top5 slug
TOPSLUGS=$(psql "WITH w(slug,cat) AS $WL,
classified AS (
  SELECT i.category_slugs AS slugs, COALESCE(c.cat,'hidden-gems') AS line
  FROM nearby_items i
  LEFT JOIN LATERAL (
    SELECT w.cat FROM unnest(i.category_slugs) WITH ORDINALITY AS u(slug,ord)
    JOIN w ON w.slug=u.slug ORDER BY u.ord LIMIT 1) c ON true
  WHERE i.type='place' AND i.status='active')
SELECT unnest(slugs) AS slug, count(*) AS n FROM classified
WHERE line='hidden-gems' GROUP BY slug ORDER BY n DESC, slug LIMIT 5") \
  || failq "残池 top slug 查询报错"

# Q4 池内全量 slug 词表（漂移哨兵基线源）
POOLSLUGS=$(psql "SELECT unnest(category_slugs) AS slug, count(*) AS n
FROM nearby_items WHERE type='place' AND status='active'
GROUP BY slug ORDER BY slug") || failq "池 slug 词表查询报错"

# ---- 词表漂移哨兵（仅 r4s 本地文件写入，非业务库） ----
NEW=""
if [ ! -f "$SLUGS_FILE" ]; then
  echo "$POOLSLUGS" | cut -d'|' -f1 > "$SLUGS_FILE"
  log "vocabulary baseline created: $(wc -l < "$SLUGS_FILE") slugs"
else
  NEW=$(echo "$POOLSLUGS" | cut -d'|' -f1 | grep -vxFf "$SLUGS_FILE" | sort)
  if [ -n "$NEW" ]; then
    echo "$NEW" >> "$SLUGS_FILE"
    log "new slugs appended to vocabulary: $(echo "$NEW" | tr '\n' ' ')"
  fi
fi

# ---- 常规日志（简报级） ----
log "OK: fallback ${RATE}% (${HG}/${DEN}) threshold=${ALERT_PCT}% non_active=${NA}"
log "lines: $LINES"
echo "$CITIES" | while IFS= read -r row; do log "city $row"; done
log "top-fallback-slugs: $(echo "$TOPSLUGS" | tr '\n' ' ')"

# ---- 阈值判断 / 告警 ----
OVER=$(awk -v r="$RATE" -v t="$ALERT_PCT" 'BEGIN{print (r+0>=t+0)?1:0}')
if [ "$OVER" = "1" ] || [ -n "$NEW" ]; then
  CITYTOP=$(echo "$CITIES" | head -4 | awk -F'|' '{printf "%s %.2f%%(%s/%s)  ", $1,$4,$3,$2}')
  SLUGTOP=$(echo "$TOPSLUGS" | awk -F'|' '{printf "%s=%s  ", $1,$2}')
  msg="[noda#496 兜底率告警] hidden-gems 兜底 ${RATE}%（${HG}/${DEN}）≥ 阈值 ${ALERT_PCT}%（临时水位，step2 拍板后修订）"
  msg="$msg
Top城: $CITYTOP"
  msg="$msg
Top兜底slug: $SLUGTOP"
  [ -n "$NEW" ] && msg="$msg
词表新slug首现: $(echo "$NEW" | tr '\n' ' ')（已并入基线，入池管线引入新 tag 请先扩白名单/沉底名单）"
  msg="$msg
日志: /var/log/noda-category-fallback.log"
  tg "$msg"
  log "ALERT: TG sent (rate=${RATE}% >= ${ALERT_PCT}% and/or new slugs)"
fi
exit 0
