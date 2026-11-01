# 退役 SeaweedFS 迁本地文件系统（方案 A）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 noda-infra#8 已拍板的方案 A，把静态站与 CDN 图片从 SeaweedFS 迁到 r4s 本地文件系统，完成 P0→P4 全链路落地与线上实测验收（应用侧 = noda-apps#123）。

**Architecture:** nginx `try_files` 本地根 + rsync(rsync-over-ssh) 推送 + `mv` 原子蓝绿切换 + `cp -al` 硬链接快照；blobstore/authapi 增加 `BLOBSTORE_MODE=fs` 后端（write-then-rename）；数据 copy 不 move，weed 停机保留 30 天，nginx conf / env / pipeline 三重回退锚。

**Tech Stack:** bash/rsync/nginx(minio-go→os)/Go 1.2x、docker、rclone（仅存量数据迁移）、Jenkins。

**Spec:** noda-infra issue #8 正文（含裁定、备份设计、AND 退役门、回退锚）+ noda-apps issue #123。本计划是两 issue 的执行分解。

## Global Constraints

- **默认行为不变**：`BLOBSTORE_MODE` 未设 = `s3`，一切现有 env/调用方零感知（#123 验收项）。
- **copy 不 move**：weed 数据 41.2G 卷与容器原封保留 ≥30 天；任一阶段可回退（nginx git revert+reload 分钟级 / env 翻回 s3 / pipeline 双实现保留一个发布周期）。
- **对账口径**：对象数按前缀独立重算（remote `rclone size --json` vs local `find -type f|wc -l`），抽样 md5 必须下载远端对比（weed ETag 非 MD5，禁止采信 ETag）。
- **weed 压力红线**：对 weed 的大规模读（P0 拷贝/对账）`--transfers ≤ 8 --checkers ≤ 16`，避开 02:00 vacuum / 03:30 百度 / 05:10 快照窗口与任何发布窗口（r4s 出现 `tmp-s3-relay-*` 即发布中）。
- **布局**：r4s `/mnt/mmc1-4/Noda/Static/{sites,cdn}`；`cdn/` = 桶内除 `sites/` 外全部顶层前缀（含 `nearby/`、`avatars/`）。nginx 容器挂 `/mnt/mmc1-4/Noda/Static:/var/noda-static:ro`；api/jobs 挂 `/mnt/mmc1-4/Noda/Static/cdn:/data/blobstore`。
- **backend 探测**：pipeline 以目标机上的标记文件判定后端——stg 看 `docker/volumes/static-stg/.backend-fs`（Mac），prod 看 r4s `/mnt/mmc1-4/Noda/Static/.backend-fs`。标记存在 = fs，缺失 = s3。回退 = 删标记。
- **两仓独立 worktree**：noda-apps → `/Users/dianwenwang/Project/noda-wt/123-blobstore-fs`（branch `issue-123-blobstore-fs`）；noda-infra → 每任务独立 worktree（branch `issue-8-<task>`），顺序合并。主 checkout 的 Jenkins 部署面只在 M2 合入 main 后使用。
- 现有守卫（watchdog */5、swap-guard */10、vacuum 02:00）在 P4 前必须原样保留——weed 还在线。

---

## 背景速览（执行者必读）

- r4s = `ssh r4s`（root@192.168.100.1，iStoreOS，4GB RAM）。prod 全部在此：seaweedfs 容器（无宿主端口，docker 网内 `seaweedfs:8333`）、`noda-static-prod`(nginx，pipeline `docker run` 起)、`noda-api-prod`/`noda-jobs-prod`(pipeline `docker run` 起，`--read-only`，共享 `/tmp/prod-api.env`)。
- Mac mini = Jenkins(`http://localhost:8080`) + preprod（`docker/docker-compose.preprod-local.yml`：`preprod-noda-api`、`preprod-noda-static`(挂 `config/nginx/liuyao-local.conf`)、`seaweedfs-stg`）。
- 桶 `noda-static`（32.9G / 347,382 对象）：`sites/{nearby,www,admin,auth,comment,shuotong,...}`、`nearby/{crawled,pool}`、`avatars/`。stg 桶 `noda-static-stg`。
- 消费面细节（行号基于 noda-infra@921a5e9 / noda-apps@d6864236）：见 issue #8 表格与下方各任务。

## 任务总览与并行编排

```
M0 r4s 数据层(P0) ──────────────后台长任务───────────────┐
T1 apps blobstore fs 后端 ──┐                            │
T2 apps 头像fs+shellURL ────┴─ 同worktree 串行            ├── M3 P2 prod api/jobs fs
T3 infra nginx 本地根 ────────┐                           │      ↓
T4 infra pipeline 手术 ───────┼─ 各自worktree 并行 → M1 stg 验证(Mac) → M2 合入main
T5 infra 备份链切换 ──────────┘                            │      ↓
M4 终增量copy+对账 ←──────────────────────────────────────┘
M5 P3 prod cutover（nginx reload + shuotong force 复发布 + 回滚演练）
M6 P4 退役（baidu 切换+restore 演练+守卫摘除+weed down+复测+关单）
```

M0 立即后台启动；T1-T5 五路并行（T2 依赖 T1 交付的接口，串行在 T1 后）。

---

## M0（r4s 实机运行手册，主会话执行，非 worktree）

### M0.1 前置核查 + 桶顶层清单

- [ ] `ssh r4s` 跑 `sh /mnt/mmc1-4/System/Scripts/pipeline-resource-probe.sh`：`weed_health=healthy`、`relays=0`、`load1<3`、`mem_avail_mb>600` 才继续。
- [ ] 桶顶层（r4s 本地 docker rclone 模式，凭据从 noda-ops env 取）：
```bash
ssh r4s 'A=$(docker inspect noda-ops --format "{{range .Config.Env}}{{println .}}{{end}}" | grep SEAWEED_S3_ACCESS_KEY | cut -d= -f2); \
S=$(docker inspect noda-ops --format "{{range .Config.Env}}{{println .}}{{end}}" | grep SEAWEED_S3_SECRET_KEY | cut -d= -f2); \
docker run --rm --network noda-network -v /opt/noda/bin/rclone:/usr/local/bin/rclone:ro \
  -e RCLONE_CONFIG_SW_TYPE=s3 -e RCLONE_CONFIG_SW_PROVIDER=Other \
  -e RCLONE_CONFIG_SW_ENDPOINT=http://seaweedfs:8333 \
  -e RCLONE_CONFIG_SW_ACCESS_KEY_ID=$A -e RCLONE_CONFIG_SW_SECRET_ACCESS_KEY=$S \
  alpine/socat rclone lsd SW:noda-static; \
echo ===; docker run ... rclone size SW:noda-static --json'  # 同上参数
```
  记录每个顶层前缀的 objects/bytes（对账基线，存 `deploy/` 侧记 issue 评论）。
- [ ] 确认 `sites/` 下的产品集合与 `_static_product_config()` 表一致；确认除 `sites/` 外的前缀清单（预期 `nearby`、`avatars`，可能还有 `www`/`class`/`liuyao` 残骸——残骸照拷，宁多勿缺）。

### M0.2 P0 全量拷贝（后台）

- [ ] 建 L1 目录：`ssh r4s 'mkdir -p /mnt/mmc1-4/Noda/Static/sites /mnt/mmc1-4/Noda/Static/cdn /mnt/backup/weed-final-20261102'`
- [ ] 拷 `sites/`（后台、setsid、限速 8/16、日志 `/var/log/noda-p0-copy.log`）：
```bash
ssh r4s 'setsid sh -c "A=...; S=...; docker run --rm --name p0-copy-sites --network noda-network \
  -v /opt/noda/bin/rclone:/usr/local/bin/rclone:ro -v /mnt/mmc1-4/Noda/Static/sites:/dst \
  -e RCLONE_CONFIG_SW_... alpine/socat \
  rclone copy SW:noda-static/sites /dst --transfers=8 --checkers=16 --retries=3 --low-level-retries=10 \
  --stats=one-line --stats-log-level NOTICE --log-level INFO" >/var/log/noda-p0-copy.log 2>&1 &'
```
- [ ] sites 完成后依次（脚本串行，同一日志）：拷其余顶层前缀 → `/mnt/mmc1-4/Noda/Static/cdn/<prefix>`；再拷终态快照 `rclone copy SW:noda-static /mnt/backup/weed-final-20261102/noda-static`（sda1 空闲 64G > 32.9G）。
- [ ] 过程监控（每 10-15 分钟）：`probe`（weed_health/relays/load）+ `rclone stats` 日志尾。若 `weed_health≠healthy` 或 load>6 → `docker stop p0-copy-*` 中止，weed 自愈后降 `--transfers=4` 重跑（rclone copy 幂等续传）。

### M0.3 对账（AND 门第 1 条）

- [ ] 每顶层前缀对象数：remote `rclone size SW:noda-static/<p> --json` vs local `find /mnt/mmc1-4/Noda/Static/<映射目录> -type f | wc -l`。差 0 才过；差 >0 → `rclone check --missing-on-dst`（注意勿用 --fast-list）定位补拷。
- [ ] 抽样 md5：随机取 ≥200 个 key（`rclone lsf -R | shuf -n 200`），`rclone copy SW:noda-static/<key...>` 到 /tmp 对比 `md5sum`。200/200 一致才过。
- [ ] 终态快照抽样 50 个同法校验。
- [ ] 全程探活：期间每轮监控记录 `curl -s -o /dev/null -w %{http_code}` 打 https://noda.co.nz / https://www.noda.co.nz / https://admin.noda.co.nz / cdn 抽样图 URL，全 200/301 不变。

---

## Task 1（noda-apps）：blobstore fs 后端 + 单测

**Worktree:** `/Users/dianwenwang/Project/noda-wt/123-blobstore-fs`，branch `issue-123-blobstore-fs`，基 `main`(d6864236)。

**Files:**
- Modify: `common/go/blobstore/blobstore.go`（Config/Validate/New）
- Modify: `common/go/blobstore/client.go`（s3Client 接口摘除 GetObject）
- Create: `common/go/blobstore/fs_client.go`
- Create: `common/go/blobstore/fs_client_test.go`
- Test: 现有 `common/go/blobstore/{blobstore_test,store_test}.go` 必须全绿不改动（除极小必要）

**Interfaces（T2/M3 依赖）:**
- `Config` 新字段：`Mode string`（env `BLOBSTORE_MODE`，空/"s3" = s3；"fs" = fs；其他值 Validate 报错）、`FSDir string`（env `BLOBSTORE_FS_DIR`）。
- `Validate()`：mode s3 → 现有 5 字段校验不变；mode fs → 仅要求 `FSDir` 与 `CDNBaseURL` 非空。
- `New(cfg Config) (*Store, error)`：mode fs → `newFSClient(cfg.FSDir)`；否则 `newMinioClient(cfg)`。`newStore` 注入点签名不变。
- `fsClient` 实现（与 minio 客户端同一接口面）：
```go
type fsClient struct{ root string }
func newFSClient(dir string) (*fsClient, error) // filepath.Abs + MkdirAll 0755；EvalSymlinks 后必须仍在 root 下
func (c *fsClient) StatObject(ctx, bucket, object string, opts minio.StatObjectOptions) (minio.ObjectInfo, error)
    // os.Stat → ObjectInfo{Key: object, Size, LastModified}；IsNotExist → minio.ErrorResponse{Code: "NoSuchKey", StatusCode: 404, Bucket: bucket, Object: object}（复用现有 isErrNoSuchKey 判定路径，零改 Store 逻辑）
func (c *fsClient) PutObject(ctx, bucket, object string, r io.Reader, size int64, opts minio.PutObjectOptions) (minio.UploadInfo, error)
    // key 清洗：reject 含 ".." 元素/绝对路径/空；MkdirAll 父目录 0755；写同目录临时文件 .<base>.tmp-<rand>；copy（size>0 时校验字节数一致）；chmod 0644；os.Rename 原子落位；失败清理临时文件
func (c *fsClient) RemoveObject(ctx, bucket, object string, opts minio.RemoveObjectOptions) error // os.Remove，IsNotExist → nil（S3 幂等语义）
func (c *fsClient) ListObjects(ctx, bucket string, opts minio.ListObjectsOptions) <-chan minio.ObjectInfo // filepath.WalkDir root+opts.Prefix，目录错误跳过，ctx.Done 短路
```

**关键事实（执行者上下文）:** `Store.PutFromURLPrefix` 现流程 = download → whitelist → key → StatObject(NoSuchKey 才继续) → PutObject(CacheControl/ContentType)。fs 后端忽略 opts 里的 CacheControl（nginx map 注入）与 ContentType（nginx 按扩展名），只落内容。`GetObject` 在 s3Client 接口里目前无生产调用方（fakeS3 也是 panic 桩）→ 直接从接口删除，`store_test.go` 若因接口收窄报编译错仅删桩行。

- [ ] **Step 1 失败测试**：`fs_client_test.go` 覆盖（用 `t.TempDir()`，包内 `newTestStore(c, transport)` 组装）：put→文件存在于 root/key 且 0644；PutFromURLPrefix 端到端（fakeTransport 喂 PNG）→ Skipped=false、URL=cdnBase+key、再跑一次 Skipped=true 且 mtime 不变（dedup 不重写）；Remove 幂等；ListByPrefix 递归；key `../../escape` 与 `/abs` 拒绝；put 中途 reader 错误 → 无 .tmp 残留、目标文件不存在；New(mode fs) 全链路（真实临时目录，无网络）。
- [ ] **Step 2** `go test ./common/go/blobstore/...` 确认新用例 FAIL（未实现）。
- [ ] **Step 3** 实现 `fs_client.go` + Config/Validate/New 改动。
- [ ] **Step 4** `go test ./common/go/blobstore/...` 全绿（新旧全量）；`go build ./...` 全仓编译过。
- [ ] **Step 5** Commit: `feat(blobstore): fs backend behind BLOBSTORE_MODE=fs (default s3) — noda-apps#123`

---

## Task 2（noda-apps）：authapi 头像 fs + nearbyapi shell URL env（依赖 T1）

**Worktree:** 同 T1。

**Files:**
- Modify: `auth/api/authapi/deps.go`（lazy avatarFSStore）
- Modify: `auth/api/authapi/domain.go:464-492`（UploadAvatar 分支）
- Create: `auth/api/authapi/avatarfs_test.go`
- Modify: `nearby/api/nearbyapi/page.go:283-296`（shellBaseURL env 覆盖）
- Test: `nearby/api/nearbyapi/` 相关既有测试

**Interfaces:**
- 头像 key 不变：`avatars/<userID>.<ext>`（`avatarKeyPrefix`）。fs 落盘 = `BLOBSTORE_FS_DIR` + `/avatars/<key同现有>`——注意 UploadAvatar 现传的 object 名是 `<userID>.<ext>`（bucket 相对，无前缀）？读 `domain.go:479` 确认实际传参：若传 `avatars/<id>.<ext>` 则 fs 直接拼 root；若传 `<id>.<ext>` 且 bucket=avatars 语义，则 fs 侧加 `avatars/` 前缀常量，保证落盘路径 = `<FSDir>/avatars/<userID>.<ext>`（与 nginx `/avatars/` → `cdn/avatars/` 对齐）。**以实际代码为准，测试固化最终路径。**
- `Deps` 增加 lazy `avatarFS() *fsAvatarStore`：env `BLOBSTORE_MODE=fs` 时 `UploadAvatar` 走它（write-then-rename 同 T1 语义，`os.MkdirAll(FSDir+"/avatars", 0755)`），否则原 minio 路径零改动。错误映射沿用 `ErrAvatarStore`（读现名）。
- `shellBaseURL()`：env `STATIC_SHELL_BASE_URL` 存在 → 直接返回该值（自带上 scheme，如 `http://noda-static-prod`，函数内不再拼 bucket）；未设 → 现行为 `${S3_ENDPOINT}/${NEARBY_STATIC_BUCKET}` 逐字节不变。prod fs 值在 M3 定（见 M5 runbook）。

- [ ] **Step 1 失败测试**：avatarfs_test（key 形状/落盘路径/write-then-rename/2MB 与类型白名单沿用现有校验不重复测）；shellBaseURL 两种模式 URL 构造测试（fs=env 直返、默认=现状拼接）。
- [ ] **Step 2** 跑测试确认 FAIL。
- [ ] **Step 3** 实现两处。
- [ ] **Step 4** `go test ./auth/... ./nearby/api/nearbyapi/... ./common/go/blobstore/...` 全绿 + `go build ./...`。
- [ ] **Step 5** Commit: `feat(authapi,nearbyapi): avatar fs store + STATIC_SHELL_BASE_URL override — noda-apps#123`

---

## Task 3（noda-infra）：nginx 本地根切换（11 snippets + cdn + avatars + preprod）

**Worktree:** `/Users/dianwenwang/Project/noda-infra/.worktrees/issue-8-nginx`，branch `issue-8-nginx`，基 main(921a5e9)。

**Files:**
- Modify: `config/nginx/snippets/seaweedfs-{nearby,www,admin,auth,comment,shuotong}-static.conf`（6 个 prod）
- Modify: `config/nginx/snippets/seaweedfs-{nearby,www,admin,auth,comment}-static-stg.conf`（5 个 stg）
- Modify: `config/nginx/conf.d/cdn.conf`
- Modify: `config/nginx/conf.d/default.conf`（avatars 两处 location：L135-145 与 preprod L1120-1124 附近）
- Modify: `config/nginx/liuyao-local.conf`（Mac preprod：-stg includes + L928 直连 proxy_pass 块）
- Modify: `docker/docker-compose.r4s.yml`、`docker/docker-compose.apps-prod.yml`（reference：nginx 服务挂 `/mnt/mmc1-4/Noda/Static:/var/noda-static:ro`）
- Modify: `docker/docker-compose.preprod-local.yml`（preprod-noda-static 挂 `<PROJECT_ROOT>/docker/volumes/static-stg:/var/noda-static:ro`）

**转换规则（每个 snippet 同一手术，语义逐条保真）:**
1. 保留：location 匹配、全部 `rewrite ... break;`（改写目标前缀 `/noda-static[-stg]/sites/<p>` → `/sites/<p>`、stg 同理）、Cache-Control add_header、安全头、`strip-conditional-get.conf` 等 include、error_page 兜底结构。
2. 移除：`proxy_set_header Host "seaweedfs:8333"`、`proxy_pass http://$seaweedfs_upstream`、`proxy_intercept_errors`、S3 相关 proxy 头。
3. 新增：`root /var/noda-static;`（prod 与 stg 同一容器根；stg 数据由 Mac 端目录区分——见 T4 stg 节奏）；`try_files $uri =404;`（rewrite 后的 URI 直接对 root）。
4. prod snippet 例（nearby-static.conf 核心）：
```nginx
root /var/noda-static;
rewrite ^(/[^.]+)$ $1.html break;   # 原有无扩展名→.html 规则逐条保留
rewrite ... break;                   # 其余 rewrite 原样，仅前缀替换
try_files $uri =404;
add_header Cache-Control $nearby_cache_control;
```
5. `cdn.conf` `location /`：删 rewrite `/noda-static$1` + proxy_pass/Host，改 `root /var/noda-static/cdn; try_files $uri =404;`，CORS/Cache-Control map 注入原样保留；`/cdn-health` 改 `return 200 "ok";`（或 try_files 探针文件）。
6. avatars location（default.conf ×2）：`root /var/noda-static/cdn;`（URI /avatars/x → cdn/avatars/x），删 rewrite+proxy；`add_header Cache-Control $auth_cache_control` 保留。
7. `liuyao-local.conf`：同规则（stg 前缀 `/noda-static-stg/...` → `/...`，root 同 `/var/noda-static`——Mac compose 挂的 static-stg 目录里同样有 `sites/`+`cdn/` 布局）；L928-929 直连 `proxy_pass http://seaweedfs:8333` 块改本地根。
8. `upstream-seaweedfs.conf` 与各 server 块的 include **不动**（P4 清理），仅 snippet 不再引用 `$seaweedfs_upstream`。

**验证:**
- [ ] `docker run --rm -v $PWD/config/nginx:/etc/nginx:ro nginx:1.25-alpine nginx -t`（整树语法；errors/ ssl 缺文件时按现 repo 既有方式补 dummy 或沿用 CI 脚本）
- [ ] `python3 scripts/check-nginx-urltree.py`（若其校验 S3 形态，按其失败信息调整为本地根形态——改脚本属本任务范围，提交内注明）
- [ ] 语义对照表：每 snippet 改前后各取 3 条代表性 URI（无扩展名页/资产/兜底 404 shell）人工核对映射一致，写入 commit message。
- [ ] Commit: `feat(nginx): serve static sites & cdn from local fs root (/var/noda-static) — noda-infra#8 P3`

---

## Task 4（noda-infra）：pipeline 手术（stg/prod 发布、回滚、快照、backend 探测）

**Worktree:** `.worktrees/issue-8-pipeline`，branch `issue-8-pipeline`（与 T3 并行，文件不相交——本任务只动 `scripts/pipeline-stages.sh` 与 `docker/env-noda-api.env`、`docker/docker-compose.preprod-local.yml` 的 api 服务部分）。

**Files:**
- Modify: `scripts/pipeline-stages.sh`：`_publish_static_to_stg` L2688-2807、`_publish_static_to_prod` L2463-2679、`_pipeline_rollback_static_site_impl` L3215-3302、`_static_snapshot_rotate_prod` L2955-3018、`_weed_fs_mv` L3027-3031、`_static_product_config` L2215-2250（表加 LocalDir 无需——目录名=sites/<product>）、`_start_prod_static` L915-1018（挂 Static 卷）、`_start_prod_api` L744-835 与 `_start_prod_jobs` L843-910（挂 cdn 卷 + env）、main dispatch。
- Modify: `docker/env-noda-api.env`（S3 块后加：`BLOBSTORE_MODE`、`BLOBSTORE_FS_DIR=/data/blobstore`，值由 Doppler/入册流程注入——本任务先加注释与模板行，M3 定值）
- Modify: `docker/docker-compose.preprod-local.yml` preprod-noda-api（挂 `../docker/volumes/static-stg/cdn:/data/blobstore` + env）

**新原语（顶部函数区，~L2900 附近）：**
```bash
STG_STATIC_ROOT="$PROJECT_ROOT/docker/volumes/static-stg"      # Mac
PROD_STATIC_ROOT="/mnt/mmc1-4/Noda/Static"                     # r4s
prod_static_backend() { remote_exec "test -f $PROD_STATIC_ROOT/.backend-fs && echo fs || echo s3"; }
stg_static_backend()  { [ -f "$STG_STATIC_ROOT/.backend-fs" ] && echo fs || echo s3; }
# rsync 推送（prod 走 ssh；stg 本地）
_prod_rsync_push() { rsync -az --delete --exclude .noda-manifest.tmp -e ssh "$OUT_DIR/" "root@192.168.100.1:$PROD_STATIC_ROOT/sites/$p-green/"; }
_prod_atomic_switch() { # mv 双跳，同 remote_exec；失败自动反向 mv 回滚（对齐现 L2574-2580 语义）
  remote_exec "cd $PROD_STATIC_ROOT/sites && mv $p $p-old && mv $p-green $p" ;}
_prod_snapshot_cp al() { remote_exec "cd $PROD_STATIC_ROOT/sites && cp -al $p $p-prev0 2>/dev/null; ls -d $p-prev* | sort -V | tail -n +$((MAX_STATIC_SNAPSHOTS+1)) | xargs -r rm -rf"; }
_prod_count() { remote_exec "find $PROD_STATIC_ROOT/sites/$p -type f | wc -l"; }
```
（stg 同构，去 ssh；快照层沿用 `MAX_STATIC_SNAPSHOTS` 默认 1。）

**行为规格：**
- `_publish_static_to_prod`：backend=s3 → 走现 rclone+relay+`_weed_fs_mv` 路径**原样**（双实现回退锚）；backend=fs → 无 relay/无 S3 凭据/无 mc：rsync push → `_prod_count` 对账（与 `.noda-manifest` 行数差 0，3 次重试）→ 原子 mv → sentinel `test -f` → `cp -al` 快照轮转 → 清理 green 残留。unchanged-skip 逻辑共用；新增 env `STATIC_PUBLISH_FORCE=1` 仅跳过 unchanged-skip（供切换演练）。
- `_publish_static_to_stg`：backend=fs 同构（本地 rsync+mv+cp -al+find 对账+sentinel）；backend=s3 保留现路径。
- 回滚 `_pipeline_rollback_static_site_impl`：双分支。fs 分支：优先 `$p-prev0` 存在 → `cp -al` 反向兜底 + rsync `$p-prev0/ → $p/`；无 prev → 反向 mv（$p ↔ $p-old）；对象数对账后收尾；stg 镜像分支（原 L3279-3290）fs 模式改 rsync 到 stg 目录。
- `_start_prod_static`：docker run 增 `-v $PROD_STATIC_ROOT:/var/noda-static:ro`。
- `_start_prod_api`/`_start_prod_jobs`：增 `-v $PROD_STATIC_ROOT/cdn:/data/blobstore`（api 或 jobs 写卷非 ro）；env 由 env-file 提供。
- `STATIC_BLUEGREEN`、锁、`_static_content_unchanged`、manifest 生成逻辑全部不动。
- `shellcheck` 无新增 error（repo 现状基线为准）；`bash -n` 过。

**验证:**
- [ ] `bash -n scripts/pipeline-stages.sh` + `shellcheck`（不劣于基线）
- [ ] 干跑（dry）：新增 `--dry-run`？不引入——改为 M1 实测为准。
- [ ] Commit: `feat(pipeline): fs backend for static publish/rollback (rsync+mv+cp -al) behind .backend-fs marker — noda-infra#8 P1/P3`

---

## Task 5（noda-infra）：备份链切换（百度冷备本地源 + 头像前缀 + B2 源本地化）

**Worktree:** `.worktrees/issue-8-backup`，branch `issue-8-backup`。

**Files:**
- Modify: `deploy/nearby-baidu-backup.sh`：`SRC` 由 `s3weed:noda-static/nearby` 改为本地 `/mnt/mmc1-4/Noda/Static/cdn/nearby`（listing 从 `docker exec noda-ops rclone` 改为宿主 `/opt/noda/bin/rclone lsf -R --files-only`，去 S3WEED env）；状态文件/TG 通报/批量上传/宁多勿缺语义逐行保留。
- Create: `deploy/avatars-baidu-backup.sh`：同上模式，SRC=`/mnt/mmc1-4/Noda/Static/cdn/avatars`，远端 `/noda备份/avatars`，状态文件 `.cloud-sync-state-avatars`（补齐冷备缺口——issue #8 备份设计节）。
- Modify: `deploy/crontab-r4s-host`：`baidu-sync-all.sh` 行后追加 avatars 备份调用行（参照 nearby 挂接方式，实际挂接点以 `baidu-sync-all.sh` L24 附近为准——**改 baidu-sync-all.sh 增一行后台 setsid 调用**，不动 crontab 行）。
- Modify: `scripts/backup/lib/cloud.sh` + `scripts/backup/backup-filesystem.sh`：source 支持 `/mnt/...` 绝对路径（现仅 `s3weed:*`）；对应 `docker-compose.yml` noda-ops 增挂 `/mnt/mmc1-4/Noda/Static/cdn/avatars:/backup-sources/avatars:ro`，`BACKUP_FS_SOURCES` 值在 r4s `docker/.env` 于 M6 切（repo 侧只改能力与 `.env.r4s.example` 注释）。

**验证:**
- [ ] `bash -n` ×3 脚本；附近 shellcheck 不劣于基线。
- [ ] 语义对照：nearby 脚本 diff 中仅 SRC/listing 行变化（commit message 附 diff 摘要）。
- [ ] Commit: `feat(backup): baidu cold-backup reads local fs + avatars prefix coverage — noda-infra#8`

---

## M1（Mac）stg 验证（P1 门）

前置：T1-T5 全部合到各自分支；T3+T4+T5 合并顺序 `issue-8-nginx` → `issue-8-pipeline` → `issue-8-backup`（无冲突预期，有则主会话手解）。

- [ ] `mkdir -p docker/volumes/static-stg/{sites,cdn} && touch docker/volumes/static-stg/.backend-fs`（stg 切 fs；weed-stg 容器继续跑作回退）
- [ ] 从**合并后的 worktree**目录直调：`bash scripts/pipeline-stages.sh <stg 发布入口> <product>`（以 main() dispatch 实名为准）对 `nearby`、`www` 各发布 1 次（共 2 次全链路）：push→count 对账→mv→sentinel→快照→cleanup 全绿；`https://<p>-preprod.noda.co.nz` 探活 + 新内容指纹。
- [ ] 回滚演练 1 次：对 `www` 跑 rollback（Jenkinsfile.rollback 同入口或直调 impl），验证 prev0 rsync/mv 回滚 + 对账 + 探活。
- [ ] preprod api fs 端到端：worktree 构建 `docker build -f infra/docker/Dockerfile.noda-api -t noda-api:wt123 <apps-worktree>`；起临时容器（env BLOBSTORE_MODE=fs BLOBSTORE_FS_DIR=/data/blobstore CDN_BASE_URL=https://cdn.noda.co.nz MIRROR_IMAGES=1 + 挂 static-stg/cdn）跑 `crawl-nearby` 小样本（如 council 单页）→ 对象落 `static-stg/cdn/nearby/crawled/`、key/URL 正确、文件 0644 无 .tmp 残留。
- [ ] preprod-noda-static 用新 nginx conf（合并后 main 或 worktree 路径起临时 8081 容器）抽测：无扩展名页→.html 映射、/avatars/、cdn 路径、Cache-Control 头值与 weed 版逐头一致（curl -sD 对比基线，基线在切换前抓取存档）。

## M2 合入 main（两仓）

- [ ] apps worktree：`go test ./...` 全绿 → merge `issue-123-blobstore-fs` → main；Jenkins 构建 noda-api 镜像成功。
- [ ] infra：三分支依序 merge → main；`git push`。
- [ ] r4s 配置同步：nginx conf 与 pipeline 脚本按现有 infra 部署面同步（`scripts/deploy/deploy-infrastructure-prod.sh` 或 pipeline 已有同步机制，以 repo 现状为准）。

## M3（r4s）P2 prod：api/jobs fs 模式

- [ ] env 入册：`/etc/noda/jobs.env`（或 env 模板流程）加 `BLOBSTORE_MODE=fs`、`BLOBSTORE_FS_DIR=/data/blobstore`（Doppler 流程照 #114 先例；或 env-file 直改+注释）。
- [ ] Jenkins 发 noda-api（pipeline `_start_prod_api`/`_start_prod_jobs` 新 run 含 cdn 卷挂载）→ 容器 healthy。
- [ ] 爬虫镜像实测：`docker exec noda-jobs-prod /usr/local/bin/crawl-nearby council`（或当周最小源）→ 新对象落 `/mnt/mmc1-4/Noda/Static/cdn/nearby/crawled/`（宿主侧 find 新文件）→ 此时 CDN 仍走 weed → **该新对象经 cdn.noda.co.nz 404 属预期**（记录，M5 后复测）。
- [ ] s3 回归锚：不动 weed；确认 s3 模式回归靠"未改默认值+单测"证据（#123 验收项 3）。
- [ ] 期间观察 api/jobs 日志无 S3 报错（jobs 已不再触 weed）。

## M4 终增量 copy + 再对账（AND 门第 1 条终验）

- [ ] M0.2 同法对 `nearby/`、`avatars/`（M0 后新写入 weed 的增量）补拷 → 对账差 0 → 抽样 md5。
- [ ] 此刻起 weed 只读冻结（api/jobs 已 fs；pipeline prod 仍 s3 分支但无发布计划——M5 立即切换）。

## M5（r4s）P3 cutover

- [ ] `touch /mnt/mmc1-4/Noda/Static/.backend-fs`（prod pipeline 落 fs 分支）
- [ ] 为 9 产品建本地快照锚：`for p in <产品表>: cd sites && cp -al $p $p-prev0`（首次发布后由轮转接管）
- [ ] nginx：同步新 conf → `docker run --rm <新conf> nginx -t` → reload `noda-static-prod`（`docker exec noda-static-prod nginx -s reload`）→ **秒级**；立即全产品探活（noda.co.nz / www / admin / auth / comment / shuotong.wang / cdn 抽样图 ×每站 ≥3 URL，200 且内容指纹与切换前一致）。
- [ ] shuotong force 复发布：`STATIC_PUBLISH_FORCE=1 bash scripts/pipeline-stages.sh <prod 发布入口> shuotong prod` → rsync/mv/sentinel/快照全绿 → 线上探活不变（内容未变）。
- [ ] prod 回滚演练：对 shuotong 跑 rollback → prev0 生效路径验证 → 再正向发布恢复。
- [ ] CF 检查：cdn 抽样图响应头 CF-Cache-Status 命中正常；`cf purge` 一张图验证回源 200。
- [ ] M3 的 404 新对象复测：cdn.noda.co.nz/<新key> 200 + immutable 头。
- [ ] 回退锚声明：此刻若异常 → `rm .backend-fs` + nginx conf `git revert` + reload + api env 翻回 s3 重启（分钟级），weed 数据未动。

## M6 P4 退役（AND 退役门全过才执行）

- [ ] AND 门逐条留证：①对象数+md5 对账（M0/M4 记录）②百度冷备覆盖 crawled/pool/avatars 且状态文件最新（跑一轮 nearby+avatars 备份，state 文件时间戳）③终态快照抽样（M0.3）④restore 演练：BaiduPCS-Go 从百度拉回 ≥10 对象 md5 对比 ⑤api/jobs fs 稳定运行 ≥1 发布周期（M3→M5 期间 shuotong 发布+爬虫任务证据）。
- [ ] B2 备份源切换：r4s `docker/.env` `BACKUP_FS_SOURCES` → 本地路径（T5 能力），跑一轮验证 noda-ops 日志成功。
- [ ] 摘守卫（顺序硬性）：先 `crontab -l | grep -v weed-watchdog/swap-guard/vacuum | crontab -` + r4s 侧脚本移除，再 `docker stop seaweedfs`（先删 cron 防 watchdog 拉起）；**容器与卷保留 30 天**。
- [ ] 停机后复测：api/jobs 上传链路（crawl-nearby 小样本 + 头像写路径单元证据）+ 全站探活 + cdn 新对象 GET。
- [ ] weed-stg（Mac）停用：`docker compose -f docker/docker-compose.preprod-local.yml stop seaweedfs`（卷保留）。
- [ ] 收尾：#123/#7/#8 逐条验收矩阵评论（证据+复现命令）；时间门遗留（30 天删卷、发布周期观察）→ 立后续 issue，注明去向；请用户关单。

---

## Self-Review 结论

- 覆盖对照：#8 的 P0-P4 逐段 → M0/T3/T4/T5/M1/M3-M6；#123 五个改动面 → T1/T2/M3 env+挂载/单测/停机复测；消费方表 7 行全覆盖（nginx×2→T3、api/jobs→T1/T2、pipeline→T4、百度→T5、守卫→M6）。
- 时序缺陷修正：先 M3(api fs) 再 M5(nginx fs) 的新对象 404 窗口已显式声明并复测。
- 事实修正：头像 B2 备份在线（issue #8「无备份」表述已过时）→ T5 仅补百度侧覆盖 + B2 源本地化。
