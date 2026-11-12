# GSC 404 修复：zh-longtail 301 map 数据随发布链同步 实施计划

> **For agentic workers:** 本计划由主线会话亲自执行（executing-plans 模式）。步骤用 checkbox 跟踪。

**Goal:** 消除 GSC「Not found (404)」（sitemap zh 行指向停烘页）——prod 的 zh 长尾 301 map 从「noda-infra repo 手动双仓拷贝（11-03 后停滞）」改为「数据文件随 nearby static 发布链自动同步到 r4s 挂载点，nginx 薄壳 include」。

**Architecture:** noda-apps 构建产物 `nearby/web/scripts/generated/zh-longtail-301.conf`（exact-only 双 map，每次构建全量重生成）由新增的 `pipeline_sync_zh_longtail_map`（pipeline-stages.sh）在 nearby static/all **prod** 发布成功后 scp 到 r4s `/mnt/mmc1-4/Noda/Static/nginx-conf/`（容器内 `/var/noda-static/nginx-conf/`，不进 git、不被任何 server 伺服），经 `nginx -t` 后 reload。prod 的 `config/nginx/conf.d/nearby-zh-longtail-301.map.conf` 薄壳化为单行 include。

**Spec / 证据链:**
- 根因：prune-zh-longtail.mjs（#126 P2/#131）停烘 noindex zh 详情页并生成 301 表；表滞后于桶面（repo 停在 11-03 的 2,866 条 vs 当前 2,874+）→ 新退场页（如 `/zh/places/tracks/t3-upper-makaroro-hut-to-totara-spur-tk-4a060f9e3364`）桶内已删、表内无条目 → 404 → GSC 邮件（WNC-20237597，2026-11-12）。
- 线上实测：两条 t3- URL 404；default/en/zh-TW 变体 200/301 正常；r4s 桶 zh/places/tracks=366 页 vs en=3,240。
- 5xx（另一封邮件）：57 页爬取于 8–11 Nov 部署窗口，当前全 200/301、容器日志零 5xx——瞬时性，修复动作仅为 GSC 重新验证。
- snagme/liuyao 子域 410 是 2026-10-11 定案的有意退役（衰减交给 Google 自动处理），不在本修复范围。

## Global Constraints

- exact-only 表不能改正则兜底（保留页与退场页同 `<slug>-<id12>` 形态，兜底会误 301 保留页——2026-11-03 容器实测判例）
- preprod 不动：liuyao-local.conf 消费 snippets/ 全量拷贝（演练域 noindex，滞后可容忍）；snippets 文件保留不删
- r4s infra 是 `git reset --hard` 硬同步——持久化改动必须进 repo，运行时数据走挂载点
- 上线走 Jenkins 标准链（SERVICE=nginx 蓝绿，2026-11-12 #13 改造后零中断）；nginx -t 失败必须回滚数据文件并使发布红

## Tasks

### Task 1: prod map conf 薄壳化 + snippets 文件头注释（noda-infra repo）
- [ ] conf.d/nearby-zh-longtail-301.map.conf → 单行 `include /var/noda-static/nginx-conf/zh-longtail-301.map.conf;` + 背景注释
- [ ] snippets/nearby-zh-longtail-301.map.conf 文件头加「preprod 专用（liuyao-local.conf include 本文件）；prod 已薄壳化」注释（数据内容不动）

### Task 2: pipeline_sync_zh_longtail_map（pipeline-stages.sh）
- [ ] 新增 `remote_put_file <local> <remote>`（scp，照 remote_exec 的 ssh 参数）
- [ ] 新增 `pipeline_sync_zh_longtail_map`：数据源 `$apps_dir/nearby/web/scripts/generated/zh-longtail-301.conf` → r4s nginx-conf/（.bak + 原子 mv）→ `remote_docker_exec noda-static nginx -t` → 失败回滚 return 1 → `reload_nginx`
- [ ] 挂接 `pipeline_publish_product`：`pipeline_publish_static_site` 成功后、release 产品锁前，`product == nearby && target == prod` 时调用

### Task 3: 止血（先数据后配置）
- [ ] r4s `mkdir -p /mnt/mmc1-4/Noda/Static/nginx-conf` + 数据文件（noda-apps HEAD 的 generated conf，2,874 条）落位
- [ ] 容器内路径可见性验证（ls /var/noda-static/nginx-conf/）

### Task 4: PR + 发布
- [ ] worktree commit → PR → 合并 main
- [ ] Jenkins SERVICE=nginx 发布（蓝绿切容器带新 conf）

### Task 5: 线上实测 AND 门
- [ ] t3- 两条 URL 301 → 无前缀 canonical（curl -I 看 Location）
- [ ] 全量 sitemap-catalog zh 行重扫：0×404（限速 4 并发）
- [ ] 保留页回归：/zh/places/tracks/waitaha-pa-track-* 200；/zh-TW/places/tracks/* 301（zhtw 正则兜底）
- [ ] nginx -t 无错、noda-static-prod healthy、admin/auth/shuotong 抽查 200
- [ ] GSC：Server error (5xx) 与 Not found (404) 两个 issue 点 Validate fix（浏览器）
