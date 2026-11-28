# category-fallback-report.sh — noda-apps#496 AC5 兜底占比防护报表

r4s 宿主机周跑只读 SQL 报表 + 阈值 TG 告警（noda-apps issue #496 AC5「防护指标上线（报表可跑、阈值告警可触发）」，2026-11-28 部署）。运行副本：`r4s:/mnt/mmc1-4/System/Scripts/category-fallback-report.sh`。

## 口径（权威源：noda-apps `ops/issue496-category-audit/` @ commit 60551bdf）

- 池 = `nearby_items WHERE type='place'`；分母 = `status='active'` 行（expired/merged/rejected 非活跃行单列计数，不计入比率）。
- 归线 = `category_slugs` **按序首个**白名单命中；白名单 = `SLUG_TO_PLACE_CAT` 30 slug（`url-tree.ts:345` @ 959bb4d6，Go `urltree.go:93` 同 commit 双仓镜像）——places 5 分类（attractions/camping/national-parks/tracks/playground）+ 城市线哨兵（market/obscure）+ #397 餐饮 19 slug → food。
- 无命中（或首命中为 obscure）→ hidden-gems 兜底；**兜底率 = hidden-gems 行 / active 行**。
- 脚本为纯 SQL 实现（`unnest WITH ORDINALITY` + LATERAL 按序首命中），2026-11-28 实测与 step1 对账**逐项一致**：hidden-gems 16,747 / food 7,264 / playground 1,618 / attractions 11 / markets 4，兜底率 65.31%（16,747/25,644）；按城 top：national 98.73 / queenstown 98.19 / dunedin 98.06 / rotorua 97.49 / christchurch 58.37 / auckland 52.32 / wellington 48.26 / tauranga 48.17 / hamilton 39.71。

## 阈值

- 默认 **70%** = **临时水位**（现值 65.31% + ~4.7pp 余量），待 #496 step2 业主拍板后修订；拍板后基线 B，告警线建议 B+5pp（audit README §3.7）。
- 覆写：`FALLBACK_ALERT_PCT=<n> sh category-fallback-report.sh`（单次）；改默认值直接编辑脚本头 `ALERT_PCT` 行。
- 词表漂移哨兵：池内出现基线词表（`r4s:/mnt/mmc1-4/System/Scripts/.category-fallback-slugs`，首跑自动生成）外新 slug → 并入告警，告警后并入基线（仅首现告警）。入池管线引入新 tag 时应先扩白名单/沉底名单再放行。

## 行为

1. 三重前置守卫（参照 swap-debt-guard 形态）：1min 负载 ≥ `LOAD_MAX`(默认 4) / postgres 容器不在跑 / psql 连不上 —— 任一不过 → TG 告警 + exit 1（cron 行尾 `|| hb fail` 落心跳）。
2. 主体：4 条只读 SELECT（汇总/按城/残池 top5 slug/池 slug 词表），日志 append `/var/log/noda-category-fallback.log`。
3. 阈值 ≥ 70%（或词表新 slug 首现）→ TG 告警（走 `telegram-alert.sh`，Zcode For Ben bot）；否则静默（日志简报）。
4. 心跳由 **cron 行尾持有**（`&& hb ok … || hb fail …`），与 r4s 宿主机全部既有任务同风格；脚本自身不发心跳。

## crontab 注册（已装机，2026-11-28）

```
0 7 * * 0 /mnt/mmc1-4/System/Scripts/category-fallback-report.sh >> /var/log/noda-category-fallback.log 2>&1 && /mnt/mmc1-4/System/Scripts/hb ok r4s:category-fallback-report '0 7 * * 0' || /mnt/mmc1-4/System/Scripts/hb fail r4s:category-fallback-report '0 7 * * 0'
```

- 取位周日 07:00：**06:30 已被 container-update-check 占用**（2026-10-27 emSign 事件新增），并避开 05:00 镜像清理 / 05:10 快照 / 05:30 swap 清债 / 06:00(每月 1 号) overture / 03:30 百度上传。
- 注册方式 append-only（`(crontab -l; cat 新行) | crontab -`，前后各备份 `~/crontab-backup-<日期>-*`），未改动任何既有条目。
- ⚠️ 仓内 `deploy/crontab-r4s-host` 与 r4s 线上 crontab 此前已漂移（线上为交错损坏后手工归位版本），本行**仅注册到线上**、未回写仓内 crontab 文件——重装 crontab 时需从线上导出为准，本文件此行为准。

## 人工复跑

```bash
# 正常跑（静默/日志简报）
ssh r4s "/mnt/mmc1-4/System/Scripts/category-fallback-report.sh"
ssh r4s "tail -15 /var/log/noda-category-fallback.log"

# 验证阈值告警通路（真实 TG 一条）
ssh r4s "FALLBACK_ALERT_PCT=60 /mnt/mmc1-4/System/Scripts/category-fallback-report.sh"

# 验证守卫通路（真实 TG 一条 + exit 1）
ssh r4s "LOAD_MAX=0 /mnt/mmc1-4/System/Scripts/category-fallback-report.sh; echo rc=\$?"
```

## 词表同步纪律

改 `SLUG_TO_PLACE_CAT`（web/Go 双仓同 commit 镜像）时必须同步本脚本 `WL` VALUES 块；白名单变更会改变兜底率口径——变更当周日志里的比率与历史不可直比，需在 #496 注明断点。
