# Mac mini 定时任务（launchd 版）

2026-11-05 自宿主 crontab 整体迁出（原因：ZCode 宿主环境写 crontab 被 TCC 卡死，
launchd 的 plist 是普通文件、可版本管理）。r4s 侧仍走 `deploy/crontab-r4s-host`，不在本目录管辖。

## 任务清单

| 标签 | 时间 | 任务 | 日志 |
|---|---|---|---|
| com.noda.gate-probe | 每天 05:30 | website-gate 探针（零凭据） | website-gate/logs/cron.log |
| com.noda.gate-digest | 每天 06:30 | website-gate 日报 --tg --llm | website-gate/logs/cron.log |
| com.noda.container-update-check | 周日 04:00 | 容器镜像自动更新 v2（漂浮 tag pull+recreate+健康验证，失败才 TG）+ r4s 心跳；r4s 侧同款周日 04:30（root cron 错峰） | ~/Library/Logs/noda-container-update.log |
| com.noda.gate-ga4 | 周日 07:50 | GA4 周读数+行为习惯段（28d）--tg --save | website-gate/logs/cron.log |
| com.noda.gate-check | 周日 08:00 | website-gate 全四门+TG+git 提交推送 | website-gate/logs/cron.log |
| com.noda.disk-guard | 每天 07:10 | 磁盘阈值守卫 + r4s 心跳 | ~/Library/Logs/noda-disk-guard.log |
| com.noda.headroom-liveness | 每 5 分钟 | headroom-proxy 存活看门狗（自愈+TG 告警） | ~/.config/headroom/ |
| com.noda.hindsight-llm-watchdog | 每天 03/09/15/21 | hindsight LLM 配额看门狗（zai 429/402 降级自愈） | hindsight 容器 env 切换 |
| com.noda.gate-bot-watch | 每天 08:00 | website-gate bot_watch（dc 规则残余监测） | website-gate/logs/bot-watch.log |
| com.noda.ops-rounds | 每天 03/09/15/23 | noda-social 小红书四轮运营（run_round.py，工作目录 noda-social） | noda-social xhs-ops 账本 |
| noda.weekly-maintenance | 周日 03:30 | scripts/maintenance/weekly-maintenance.sh | ~/Library/Logs/noda-maintenance.log |

`reeval-timers/` 下是带日期的一次性复评提醒（TG 通知 noda-apps issue 数据窗到期），火过即失效，仅存档不复用。

07:50/08:00 的时间差是有意的：ga4 落盘的报告由 check 的 git 提交顺带入库，错峰避免同分钟 git 竞争。

## 操作

```bash
# 安装/刷新（幂等）
sh deploy/launchd-mac/install.sh

# 手动触发一次（验证用；会真实执行任务）
launchctl kickstart gui/$(id -u)/com.noda.gate-probe

# 查看状态
launchctl print gui/$(id -u)/com.noda.gate-probe

# 卸载单个
launchctl bootout gui/$(id -u)/com.noda.gate-probe
```

## 与原 cron 的语义差异（逐条核对过）

1. `gate-check` 原文 `date +\%F` 的 `\%` 是 **cron 转义**；bash/launchd 下还原为 `date +%F`。
2. 所有命令显式注入 PATH（launchd 默认 PATH 不含 /opt/homebrew/bin；cron 默认路径更窄，原文用的都是绝对路径，此改动为冗余兜底）。
3. 原命令的重定向 `>> ... 2>&1` 保留；plist 的 StandardOut/ErrPath 指向同一文件，兜住 cd 失败等更早的输出。

## 退役记录

原 crontab 全文存档：`crontab-retired-2026-11-05.txt`。用户终端执行
`crontab -l > ~/project/noda-infra/deploy/launchd-mac/crontab-retired-2026-11-05.txt && crontab -r`
即完成退役（launchd 验装成功后执行，避免双跑窗口）。
