# deploy/ — 构建文件 + r4s 宿主运维脚本档案

本目录有两个职责：

1. **noda-ops 容器构建文件**：`Dockerfile.noda-ops`、`entrypoint-ops.sh`、`supervisord.conf`、`crontab`（容器内 cron）
2. **r4s 宿主运维脚本档案**：`/mnt/mmc1-4/System/Scripts/` 下全部 noda 运维脚本的版本化副本（2026-10-18 起收口，此前脚本只活在 r4s 本地、无版本管理）

## 同步约定（硬规则）

- **运行时唯一执行副本**：`r4s:/mnt/mmc1-4/System/Scripts/<脚本>`；本目录副本是档案，不直接被执行
- 改脚本：**先改 repo，再 cp 到运行时**（推荐）；或在运行时应急修改后**当日回写 repo**，双方 md5 对账一致
- **crontab 源 = `deploy/crontab-r4s-host`**：安装方式 `crontab /opt/noda/noda-infra/deploy/crontab-r4s-host`；
  任何改动后必须 repo=live 对账一致（2026-10-18 曾发现 live 领先 repo 两块——ip-ban 接线与 immich 队列解暂停，已补录）
- **凭据政策：仓库零密钥**。运行时凭据全部走：
  - `/etc/noda/*.env`（0600，如 `ip-ban.env` 的 DOPPLER_SERVICE_TOKEN）
  - `System/Scripts/.` 开头的 0600 令牌/状态文件（`.tg-alert-token`、`.immich-ops-token`、`.sys-config-sync.state` 等）
  - 容器 env 注入（rclone `RCLONE_CONFIG_*` 式，零落盘）

## 宿主脚本清单（调度见 crontab-r4s-host）

| 脚本 | 用途 | 调度 | 日志 |
|---|---|---|---|
| `ip-ban.py` | 通用 IP 段黑名单（**双 zone：noda 主站 + class 黑名单同步**）：/24 行为指纹（6h 滚动窗）+ 单 IP 洪水 /32·/128 + 攻击 URL 惯犯（机密探测路径 ≥5 次/6h）自动发现 → CF WAF 封禁（普通 7 天 / 攻击型 30 天）→ 静默自动解封；**真人浏览器爆发豁免**（零 bot-UA 且命中 ≥3 个 PWA 生命周期端点 sw.js/manifest/_next chunk/__next RSC 不封，防冷缓存首访误伤）；进出黑名单 TG 通报；全 API 操作；token 需覆盖全部 zone 的 WAF Edit | `*/5 * * * *` | `/var/log/noda-ip-ban.log` |
| `rl429-alert.sh` | 429 观测面：JSON access log 真实 IP 卷限流告警 | `*/10 * * * *` | `/var/log/noda-rl-alert.log` |
| `telegram-alert.sh` | 全部运维告警的统一 TG 出口（Zcode For Ben bot → 站主 DM） | 被动调用 | — |
| `backup-snapshot.sh` | 数据盘 → /mnt/backup 硬链接增量快照（保 2 代、空间紧张自动降代、发版锁避让、闪存配置第三副本） | `10 5 * * *` | `/var/log/noda-snapshot.log` |
| `weed-watchdog.sh` | seaweedfs 哨兵健康检查 | `*/5 * * * *` | `/var/log/noda-weed-guard.log` |
| `weed-swap-guard.sh` | weed swap cgroup 漂移自愈（容器 recreate 后 memory.swap.max 复位） | `*/10 * * * *` | `/var/log/noda-weed-guard.log` |
| `weed-vacuum-nightly.sh` | 夜定 weed vacuum（三重守卫：发布中/load/内存跳过） | `0 2 * * *` | `/var/log/noda-weed-vacuum.log` |
| `swap-debt-guard.sh` | swap 债巡检（周） | `30 5 * * 0` | — |
| `log-trim.sh` | noda 日志瘦身（/var/log 内存盘保护：>2MB 留尾 200KB） | `50 4 * * *` | — |
| `baidu-sync-all.sh` | 统一百度云同步编排（配置树 + 照片/DB + nearby 素材三段，独立锁与告警） | `30 3 * * *` | `/var/log/noda-baidu-sync-all.log` |
| `system-config-backup.sh` | 关键配置整树镜像上云（BaiduPCS 单文件模式，状态驱动差量） | 被上者调用 | `/var/log/noda-sysconfig-backup.log` |
| `immich-cloud-upload.sh` | 照片两树 + immich DB 转储上云 | 被上者调用（后台） | `/var/log/noda-immich-cloud.log` |
| `nearby-baidu-backup.sh` | nearby 爬取素材 weed S3 → 百度冷备（rclone env 凭据零落盘，状态驱动幂等） | 被上者调用（后台） | `/var/log/noda-nearby-cloud.log` |
| `baidu-upload-watchdog.sh` | 上传僵死看门狗（完成数+字节双判据，90 分钟无进展才杀） | `*/10 * * * *` | `/var/log/noda-upload-watchdog.log` |
| `b2-quota-tg-guard.sh` | B2 免费额度配额守卫（TG 告警） | `20 5 * * *` | — |
| `immich-thumb-heal.sh` | Immich 缩略图/元数据任务自愈（修 asset_job_status 不写的产品 bug，load>8 跳过） | `40 * * * *` | `/var/log/noda-immich-heal.log` |
| `pipeline-resource-probe.sh` | 发布期资源探针（Jenkins 部署链路） | 发布时调用 | — |
| `issue1312-nightrun.sh` | issue1312 一次性夜跑工具（已完成，存档备查） | 无 | `/var/log/issue1312-nightrun.log` |

## 有意不入库的内容

- **个人/家庭自动化脚本**（留在运行时，与 noda 无关）：`agh_schedule.sh`、`shuotong_dns_rules.sh`、`immich-cloud-pipeline.sh`、`immich-import-baidu.sh`、`openclash_tproxy_limit.sh`
- **临时一次性脚本**：`pd-watchdog.sh`（placedesc 看护，达标自删后此行移除）
- **令牌/状态/日志**：`.tg-alert-token`、`.immich-*-token`、`.cloud-sync-state-*`、`.b2-quota-tg-last`、`dnsmasq_whitelist.conf`、`syslog.log*`、`shuotong_dns.log`——含凭据或运行态，永不入库
