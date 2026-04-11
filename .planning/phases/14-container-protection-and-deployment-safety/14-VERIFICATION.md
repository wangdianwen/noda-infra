---
phase: 14-container-protection-and-deployment-safety
verified: 2026-04-11T19:40:00Z
status: human_needed
score: 12/12 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 7/12
  gaps_closed:
    - "docker compose config 合并后所有生产容器包含 security_opt no-new-privileges:true"
    - "docker compose config 合并后所有生产容器包含 cap_drop: ALL（按需 cap_add）"
    - "docker compose config 合并后所有生产容器包含 read_only: true + tmpfs"
    - "docker compose config 合并后所有生产容器包含 json-file 日志驱动 + max-size/max-file"
    - "docker compose config 合并后所有生产容器包含 stop_grace_period: 30s"
  gaps_remaining: []
  regressions: []
---

# Phase 14: Container protection and deployment safety -- 验证报告

**Phase Goal:** 为生产环境 Docker 容器添加全面安全加固（security_opt/capabilities/non-root/logging/graceful shutdown）、部署自动回滚机制、Nginx upstream 故障转移和自定义错误页面
**Verified:** 2026-04-11T19:40:00Z
**Status:** human_needed
**Re-verification:** Yes -- 修复 commit 5ba69ad 后重新验证

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | docker compose config 合并后所有生产容器包含 security_opt no-new-privileges:true | VERIFIED | docker-compose.prod.yml 中 5 个服务均包含 no-new-privileges:true（grep count=5），compose config 合并后确认 5 处 |
| 2 | docker compose config 合并后所有生产容器包含 cap_drop: ALL（按需 cap_add） | VERIFIED | 4 个服务包含 cap_drop: ALL（grep count=4，keycloak 正确除外），postgres 有 cap_add [CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID]，nginx 有 cap_add NET_BIND_SERVICE，noda-ops 有 cap_add [CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID] |
| 3 | docker compose config 合并后所有生产容器包含 read_only: true + tmpfs | VERIFIED | 5 个服务均包含 read_only: true（grep count=5），每个服务配有对应的 tmpfs 路径 |
| 4 | docker compose config 合并后所有生产容器包含 json-file 日志驱动 + max-size/max-file | VERIFIED | 5 个服务均包含 logging: json-file + max-size: "10m" + max-file: "3"（grep count=5） |
| 5 | docker compose config 合并后所有生产容器包含 stop_grace_period: 30s | VERIFIED | 5 个服务均包含 stop_grace_period: 30s（grep count=5） |
| 6 | noda-ops Dockerfile 创建 nodaops 用户，以非 root 运行 | VERIFIED | Dockerfile.noda-ops 第 38 行 addgroup -S nodaops && adduser -S -G nodaops nodaops，第 45 行 COPY crontab 到 /etc/crontabs/nodaops，第 57 行 chown，第 63 行 USER nodaops |
| 7 | Nginx 配置中定义了 upstream 块并使用 upstream 名称引用 | VERIFIED | default.conf 第 4-10 行定义 upstream keycloak_backend 和 findclass_backend，第 40 行 proxy_pass http://keycloak_backend，第 82 行 proxy_pass http://findclass_backend |
| 8 | proxy_next_upstream 配置了 error timeout http_502 http_503 故障转移 | VERIFIED | 两个 server 块均包含 proxy_next_upstream error timeout http_502 http_503（grep count=2） |
| 9 | 502/503 错误时显示自定义维护页面 | VERIFIED | default.conf 包含 error_page 502 503 /50x.html（2 处），50x.html 存在（35 行中文维护页面），docker-compose.prod.yml nginx 段包含 errors volume 挂载 |
| 10 | 部署前自动保存当前运行镜像的 digest 到文件 | VERIFIED | deploy-infrastructure-prod.sh save_image_tags 函数（使用 docker inspect --format='{{.Image}}'），deploy-apps-prod.sh save_app_image_tags 函数 |
| 11 | 部署失败时通过 docker compose override 文件回退到保存的上一版本镜像 | VERIFIED | rollback_images() 生成 rollback.yml compose override，使用 docker compose -f base -f prod -f rollback up -d；rollback_app() 使用 docker compose -f app.yml -f rollback up -d。无裸 docker run -d（CLAUDE.md 合规） |
| 12 | 部署前检查最近备份时间，12 小时内已有成功备份则跳过 | VERIFIED | check_recent_backup() 读取 history.json，43200 秒阈值（12h）；12h 内无备份时 run_pre_deploy_backup() 通过 docker exec noda-ops /app/backup/backup-postgres.sh 执行备份 |

**Score:** 12/12 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `docker/docker-compose.prod.yml` | 5 个服务的安全加固 + nginx errors volume | VERIFIED | 210 行，包含 postgres/keycloak/findclass-ssr/nginx/noda-ops 全部安全配置 + nginx errors 挂载 |
| `deploy/Dockerfile.noda-ops` | nodaops 用户创建 + USER 指令 | VERIFIED | 第 38 行 addgroup/adduser，第 45 行 crontab 路径，第 57 行 chown，第 63 行 USER nodaops |
| `deploy/entrypoint-ops.sh` | rclone 使用 RCLONE_CONFIG 环境变量 | VERIFIED | 第 36 行 export RCLONE_CONFIG=/home/nodaops/.config/rclone/rclone.conf，第 37 行写入配置 |
| `deploy/supervisord.conf` | HOME 路径修正 + pidfile 修正 | VERIFIED | 第 10 行 pidfile=/run/supervisor/supervisord.pid，第 20/29 行 HOME="/home/nodaops" |
| `config/nginx/conf.d/default.conf` | upstream + proxy_next_upstream + error_page | VERIFIED | 100 行，2 个 upstream 块 + 2 处 proxy_next_upstream + 2 处 error_page |
| `config/nginx/errors/50x.html` | 自定义中文维护页面 | VERIFIED | 35 行，完整 HTML 中文维护页面 |
| `scripts/deploy/deploy-infrastructure-prod.sh` | 镜像回滚 + 部署前备份 | VERIFIED | save_image_tags/rollback_images/check_recent_backup/run_pre_deploy_backup 四个函数，7 步流程，bash -n 通过 |
| `scripts/deploy/deploy-apps-prod.sh` | 应用镜像回滚 | VERIFIED | save_app_image_tags/rollback_app 函数，超时自动回滚，bash -n 通过 |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | -- | --- | ------ | ------- |
| docker-compose.prod.yml | docker-compose.yml | compose overlay merge | WIRED | `docker compose config --quiet` 通过，安全配置正确合并 |
| Dockerfile.noda-ops | entrypoint-ops.sh | COPY + USER nodaops | WIRED | 第 51 行 COPY entrypoint，第 63 行 USER nodaops |
| Dockerfile.noda-ops | supervisord.conf | COPY + pidfile 路径一致 | WIRED | 第 48 行 COPY supervisord.conf，pidfile 在 tmpfs /run/supervisor |
| default.conf | 50x.html | error_page + root /etc/nginx/errors | WIRED | error_page 502 503 /50x.html 指向 /etc/nginx/errors，prod.yml nginx volumes 挂载 errors 目录 |
| deploy-infrastructure-prod.sh | noda-ops 容器内 backup-postgres.sh | docker exec | WIRED | 第 182 行 docker exec noda-ops /app/backup/backup-postgres.sh |
| deploy-infrastructure-prod.sh | rollback compose | 三层 overlay | WIRED | docker compose -f base -f prod -f rollback up -d --no-deps --force-recreate |
| deploy-apps-prod.sh | rollback compose | app + rollback overlay | WIRED | docker compose -f app.yml -f rollback up -d --no-deps --force-recreate |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| deploy-infrastructure-prod.sh | ROLLBACK_FILE | docker inspect --format='{{.Image}}' | YES - 实际获取运行容器镜像 ID | FLOWING |
| deploy-infrastructure-prod.sh | ROLLBACK_COMPOSE | 从 ROLLBACK_FILE 动态生成 YAML | YES - 容器名到服务名映射 + digest | FLOWING |
| deploy-infrastructure-prod.sh | history_json | docker exec noda-ops cat /app/history/history.json | YES - 读取容器内实际备份历史 | FLOWING |
| deploy-apps-prod.sh | ROLLBACK_FILE | docker inspect --format='{{.Image}}' findclass-ssr | YES - 实际获取运行镜像 ID | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| Compose config syntax valid | `docker compose -f docker-compose.yml -f docker-compose.prod.yml config --quiet` | 通过（仅有 env var 警告，无语法错误） | PASS |
| Bash syntax valid (infra) | `bash -n scripts/deploy/deploy-infrastructure-prod.sh` | 无错误 | PASS |
| Bash syntax valid (apps) | `bash -n scripts/deploy/deploy-apps-prod.sh` | 无错误 | PASS |
| Security options in merged config | `docker compose config \| grep -c security_opt` | 5 | PASS |
| stop_grace_period in merged config | `docker compose config \| grep -c stop_grace_period` | 5 | PASS |
| logging max-size in merged config | `docker compose config \| grep -c max-size` | 5 | PASS |
| Nginx upstream 定义存在 | `grep -c 'upstream.*_backend' default.conf` | 2 | PASS |
| No bare docker run in deploy scripts | `grep 'docker run -d' scripts/deploy/*.sh` | 无匹配 | PASS |
| Dev overlay untouched by Phase 14 | `git diff HEAD~6 -- docker/docker-compose.dev.yml` | 无输出 | PASS |

### Requirements Coverage

| Decision | Source Plan | Description | Status | Evidence |
| -------- | ---------- | ----------- | ------ | -------- |
| D-01 | Plan 14-01 | Full hardening (security_opt, cap_drop, read_only, tmpfs) | SATISFIED | 5 个服务均有 security_opt + read_only + tmpfs，4 个有 cap_drop:ALL + 按需 cap_add |
| D-02 | Plan 14-01 | Non-root user for noda-ops | SATISFIED | Dockerfile USER nodaops，entrypoint/supervisord 路径修正，crontab 路径修正 |
| D-03 | Plan 14-01 | Uniform json-file logging with rotation | SATISFIED | 5 个服务均有 json-file driver + max-size: 10m + max-file: 3 |
| D-04 | Plan 14-01 | Graceful shutdown stop_grace_period: 30s | SATISFIED | 5 个服务均有 stop_grace_period: 30s |
| D-05 | Plan 14-03 | Image-tag based rollback | SATISFIED | 两个部署脚本均实现 compose-based 回滚，无裸 docker run |
| D-06 | Plan 14-03 | Auto backup before deploy with 12h threshold | SATISFIED | check_recent_backup + run_pre_deploy_backup 完整实现 |
| D-07 | Plan 14-02 | Upstream with retry + proxy_next_upstream | SATISFIED | 2 个 upstream 块 + 2 处 proxy_next_upstream error timeout http_502 http_503 |
| D-08 | Plan 14-02 | Custom error page (502/503) | SATISFIED | 50x.html 存在（35 行中文页面），2 处 error_page 配置，nginx errors volume 挂载 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| (无) | - | - | - | 所有关键文件无 TODO/FIXME/PLACEHOLDER/空实现 |

### Human Verification Required

### 1. 非 root 用户运行验证

**Test:** 部署后执行 `docker exec noda-ops whoami`，应返回 `nodaops`
**Expected:** 输出 `nodaops`（非 root）
**Why human:** 需要实际构建镜像并启动容器才能验证，本地环境无法运行生产容器

### 2. 安全加固配置实际生效验证

**Test:** 部署后对每个容器执行 `docker inspect --format='{{.HostConfig.SecurityOpt}}' <container>` 验证 no-new-privileges 生效
**Expected:** 每个容器返回 `[no-new-privileges:true]`
**Why human:** 需要部署后才能验证 compose 配置被 Docker daemon 正确应用

### 3. read_only 文件系统启动测试

**Test:** 部署后检查所有容器是否正常启动（read_only 可能导致写入失败）
**Expected:** 所有 5 个容器正常启动且健康检查通过
**Why human:** read_only + tmpfs 配置需要实际运行验证，不同服务可能有未预期的写入需求

### 4. Nginx 故障转移实际行为测试

**Test:** 停止后端服务（如 `docker stop noda-infra-keycloak-prod`），访问 auth.noda.co.nz 验证是否显示 50x.html 维护页面
**Expected:** 显示自定义中文"服务维护中"页面
**Why human:** 需要实际运行环境，通过 Cloudflare Tunnel 访问

### Re-verification Summary

**Previous verification (2026-04-11T07:33:10Z):** 5 个 truths 失败（D-01/D-03/D-04 的 security_opt/cap_drop/logging/stop_grace_period），根因是 Plan 14-02 的 commit (2f9c64a) 覆盖了 Plan 14-01 添加的安全配置。

**Fix:** commit 5ba69ad 恢复了所有安全加固配置（+100 行，-11 行），同时保留了 Plan 14-02 的 nginx errors volume 挂载。

**Current verification:** 12/12 truths 全部通过，所有 8 个 decision (D-01 到 D-08) 均已满足。docker-compose.prod.yml 包含完整的 5 服务安全加固 + nginx errors 挂载。部署脚本回滚机制和自动备份功能完整。剩余 4 项人工验证需在部署后执行。

---

_Verified: 2026-04-11T19:40:00Z_
_Verifier: Claude (gsd-verifier)_
