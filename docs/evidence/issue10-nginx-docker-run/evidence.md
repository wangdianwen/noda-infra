# infra #10 验证证据：SERVICE=nginx 班次 compose→docker run 改造

- 日期：2026-11-11（NZDT 深夜低风险窗口）
- 交付：PR #11（compose→docker run 主体）、PR #12（verify 探针补 Host，#94 失败补救）
- 班次：Jenkins noda-infra **#95 = SUCCESS**（#94 中途失败，原因见下）
- 生产容器：`noda-static-prod` 重建于 `noda-static:72be087c`（noda-apps main HEAD）

## #93 根因复核（ Jenkins consoleText 实证）

失败点在 **Pre-flight** 而非 Deploy：`pipeline_infra_preflight` 发现反代容器未运行，
走 compose 兜底 `remote_compose "up -d --no-deps nginx"`，**未传 NODA_STATIC_IMAGE**，
compose 模板回退 `noda-static:latest` → Docker Hub pull denied：

```
[2026-11-10T12:39:28.888Z] + remote_compose 'up -d --no-deps nginx' ...（无 env_prefix）
[2026-11-10T12:39:32.483Z]  nginx Error pull access denied for noda-static, repository does not exist or may require 'docker login': denied
```

（事后 main 上已有 67bdbfc 给兜底路径补了 env 传参，但 deploy 路径与兜底仍走 compose；
本次按 issue 方案 1 全部改走 `_start_prod_static` docker run，与 prod 实态单源。）

## 交付改动（PR #11 + #12，均已合并 main）

1. `pipeline_deploy_nginx` r4s 路径：`remote_compose up nginx` → `_start_prod_static remote <tag>`
   （卷挂载 / health-cmd 含 Host / 资源限制 128m+0.25cpu / 别名 noda-infra-nginx /
   loopback+LAN 18080/18081/18443 / restart=always 全套）；无 noda-static 镜像时响亮失败
2. `pipeline_infra_preflight` r4s nginx 兜底：同口径 docker run
3. `docker-compose.r4s.yml` nginx 段：注释标明非部署路径；healthcheck 补 Host 头（633577a 同款）
4. `pipeline_infra_verify` cdn-health 探针补 `Host: cdn.noda.co.nz`（r4s+local 两分支）——
   1ef8aaf 起 :81 default_server 444，无 Host 探针必被断连（#94 Verify 失败实证，
   容器内实测：无 Host = error getting response；带 Host = 200 OK）

## AND 门逐条结果

### ① 班次全绿 ✅（附一条 ❌→✅ 过程）

Jenkins noda-infra **#95**（2026-11-11T10:48Z 触发，SERVICE=nginx）：

```
Queue Gate SUCCESS / Build Info SUCCESS / Pre-flight SUCCESS
Backup NOT_EXECUTED（postgres 专属，nginx 班次设计性跳过）
Human Approval NOT_EXECUTED（postgres 专属 input 门，nginx 班次无审批门——设计性跳过）
Deploy SUCCESS / Health Check SUCCESS / Verify SUCCESS / Post Actions SUCCESS
=> SUCCESS
```

Deploy 关键日志摘录（#95 consoleText）：

```
10:50:23 nginx 重建使用静态镜像: noda-static:72be087c
10:50:29 ✅ 部署前预检通过（新镜像 × 新配置 nginx -t）
10:50:29 启动容器: noda-static-prod (noda-static:72be087c)   ← docker run 路径
10:50:35 反代容器已就绪（等待 0 秒）→ ✅ Nginx 重建完成（r4s）
10:50:42 ✅ noda-static-prod — healthy（wait_container_healthy remote）
Verify: wget cdn-health（Host: cdn.noda.co.nz）+ /geo.json（Host: noda.co.nz）均过
```

过程记录：**#94 FAILURE**——Deploy/Health Check 已绿（docker run 路径本身工作正常），
Verify 的 cdn-health 探针无 Host 被 1ef8aaf catch-all 444 断连（该探针缺陷自 1ef8aaf
2026-11-08 起潜伏，此前 nginx 班次从未跑到 Verify；与本次改造无关的旧伤复发）。
PR #12 修探针后 #95 全绿。

### ② noda.co.nz 全程 200 ❌（诚实未过——两段 ~7s 502，各对应一次容器 recreate）

监控：每 2s curl https://noda.co.nz/（浏览器 UA），2026-11-11T10:38:52Z–10:57:32Z，
**509 样本 = 503×200 + 6×502**（原始序列见 curl-monitor.log）：

```
10:44:51 502 / 10:44:53 502 / 10:44:56 502 → 10:44:59 恢复 200   ← build#94 容器 recreate
10:50:30 502 / 10:50:32 502 / 10:50:34 502 → 10:50:37 恢复 200   ← build#95 容器 recreate
```

两段 502 各 ~7-8 秒，与本班次固有 recreate 语义一致（函数头自述「秒级中断，非零停机」；
原 compose 路径同为 stop/rm→up，中断窗只会更长）。若要求字面「全程 200」，需给 static
容器做蓝绿/双别名切换（参照 api B4 蓝绿），超出 issue 方案 1 范围——建议另立 issue 承接。

### ③ prod 容器 health-cmd 含 Host 头 ✅（docker inspect 只读）

```
$ ssh r4s docker inspect noda-static-prod --format '{{json .Config.Healthcheck.Test}}'
["CMD-SHELL","wget --quiet --tries=1 --spider --header='Host: auth.noda.co.nz' http://127.0.0.1:81/health || exit 1"]
image=noda-static:72be087c state=running health=healthy started=2026-11-11T10:50:33Z
restart=always  DNSNames=[noda-static-prod noda-infra-nginx ...]
（近 3 次 health 探针 ExitCode=0）
```

与 2026-11-11 手工复刻实态逐项对齐（卷挂载 6 项 / 128m+32m+0.25cpu /
127.0.0.1+192.168.100.1 × 18080/18081/18443 / 别名 noda-infra-nginx / restart=always）。

### ④ 功能面抽查 ✅（发布后 vs 发布前基线一致）

| URL | 发布前 | 发布后 |
|---|---|---|
| https://noda.co.nz/ | 200 | 200 |
| https://noda.co.nz/en.html | - | 200 |
| https://noda.co.nz/geo.json | 200 | 200 |
| https://www.noda.co.nz/ | 301 | 301 |
| https://auth.noda.co.nz/zh/login.html | 302 | 302 |
| https://admin.noda.co.nz/login.html | 200 | 200 |
| https://comments.noda.co.nz/ | 302 | 302 |
| https://nearby.noda.co.nz/ | 301 | 301 |
| https://shuotong.wang/ | 200 | 200 |
| https://cdn.noda.co.nz/nearby/pool/cb001f862f0c5bd6.jpg（真实资产） | - | 200 |

（302/301 与 CLAUDE.md 架构表语义一致：www→apex 301、nearby→apex 301、auth/comments 登录重定向。）

## 复现命令

```bash
# 班次各阶段
curl -s -u admin:*** http://localhost:8080/job/noda-infra/95/wfapi/describe
# 容器健康定义
ssh r4s 'docker inspect noda-static-prod --format "{{json .Config.Healthcheck.Test}}"'
# 健康探针手工复刻（容器内）
ssh r4s 'docker exec noda-static-prod wget -S --spider --header="Host: cdn.noda.co.nz" http://127.0.0.1:81/cdn-health'
```

## 遗留

- **「全程 200」未达标**（②）：static 容器 recreate 固有 ~7s 502 窗，需蓝绿化才能根除
- cdn.conf 内「本块成为 81 端口默认 server」注释已过时（1ef8aaf 后 default_server 是
  00-default-catchall.conf）——纯注释陈旧，行为无影响
