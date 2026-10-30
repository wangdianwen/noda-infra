# r4s zram swap 上线记录（issue noda-apps#103 第 8 条 SeaweedFS 变慢）

日期：2026-10-30 ｜ 执行人：ZCode（issue #103 会话） ｜ 状态：已上线

## 根因链（实测证据）

1. r4s（iStoreOS 24.10.7，4GB RAM，6.6.141）长期内存超卖：seaweedfs 稳态 ~1.36GiB（限额 2.5G，沿 512M→1G→1.5G→2G→2.5G 上调史）+ immich 全家 ~0.5G + noda postgres/api/jobs/ops ~0.5G + 系统杂项。
2. 唯一活跃 swap 是 `/mnt/mmc1-4/System/swapfile`（1GB）——**与 SeaweedFS 数据卷同一块 USB 3.0 外置机械硬盘（sda，ROTA=1）**。
3. 实测（2026-10-30 上午）：swap 977MB/1GB（93% 满），available 内存仅 1.2G。换出页读回 = USB HDD 随机寻道，与 weed 数据读/夜班 vacuum/compaction 同盘争抢 → S3 响应劣化 → Jenkins static 发版（manifest GET 哨兵 ≥5s 告警、rclone 上传变慢）跟着变慢。与 `pipeline-stages.sh` 内注的 2026-10-04「33s manifest GET 事故（swap 债务）」同模式，故称「又变慢了」。

## 处置（已执行，全部可逆）

```sh
# 1) 启用 zram swap（iStoreOS 自带 zram-swap 包，此前未启用）
uci set system.@system[0].zram_enabled='1'
uci set system.@system[0].zram_size_mb='1536'
uci set system.@system[0].zram_comp_algo='zstd'
uci commit system
/etc/init.d/zram enable && /etc/init.d/zram start
# → /dev/zram0 1536MB zstd，priority 100（新换页全部进内存压缩，不再打 USB 盘）

# 2) 重启 seaweedfs 回收换出页（安全窗口=无 Jenkins 构建；CDN 有缓存，秒级恢复）
docker restart seaweedfs
# 实测：Mem used 2.41G→1.11G，available 1.2G→2.58G；S3 热命中 TTFB 8-38ms

# 3) 排空 USB 盘 swapfile 存量换出页后，降为低优先级溢出位（-3，zram 100 优先）
swapoff /mnt/mmc1-4/System/swapfile   # 强制换出页回 RAM（当时 available 2.5G > 977MB 存量）
swapon -p -3 /mnt/mmc1-4/System/swapfile
```

## 回滚

```sh
swapoff /dev/zram0; /etc/init.d/zram stop; /etc/init.d/zram disable
uci delete system.@system[0].zram_enabled; uci commit system   # 其余键无害可留
swapon -p -2 /mnt/mmc1-4/System/swapfile   # 恢复原唯一 swap
```

## 验收口径

- `swapon -s`：zram0 priority 100 在列；USB swapfile 存量 used 应显著低于处置前 977MB。
- S3 真实对象 GET（`docker run --network noda-network curlimages/curl http://seaweedfs:8333/noda-static/<key>`）：热命中 TTFB <100ms。
- Jenkins static 发版日志不再出现「桶内清单 GET 耗时 ≥5s：weed 响应劣化」哨兵。
- `deploy/swap-debt-guard.sh` 告警频率下降（存量在盘 swap 不再累计）。

## 后续建议（未做，留档）

- seaweedfs 内存限额 2.5G 在 zram 到位后可观察是否回收至 2G（给 immich 留余量），观察期 ≥1 周再动。
- 桶 33GB/336k 对象规模下蓝绿 fs.mv 的元数据尖峰（#1102 判例）依旧存在，zram 缓解的是 swap 面；若再现 OOM 再议分桶/缩量。
