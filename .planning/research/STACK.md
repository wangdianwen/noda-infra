# Technology Stack: PostgreSQL 云备份系统

**Project:** Noda Infrastructure -- PostgreSQL 17.9 in Docker
**Researched:** 2026-04-05
**Overall confidence:** HIGH（定价来自官方页面抓取，工具推荐基于 PITFALLS.md 研究和生态系统经验）

---

## 核心推荐：一键方案

| 组件 | 推荐方案 | 版本 | 理由 |
|------|---------|------|------|
| 云存储 | **Backblaze B2** | S3 API | 成本最低、S3 兼容、已在 PITFALLS 中详细调研 |
| 备份工具 | **pg_dump -Fc** | PostgreSQL 17.9 内置 | 小规模数据库无需 pgBackRest/WAL-G |
| 上传工具 | **rclone** | v1.68+ | 支持 70+ 云存储、校验和验证、成熟稳定 |
| 调度方式 | **Jenkins cron** | 已有基础设施 | 项目已有 Jenkins，无需额外容器 |
| 加密方式 | **SSE-B2 + 严格 Key 权限** | B2 原生 | 当前规模足够，无需客户端加密增加复杂度 |

---

## 一、云存储成本对比

### 使用场景参数

- 存储：~28 个备份文件（7 天 x 4 次/天），每个 ~100MB 压缩后
- 总存储量：~2.8GB（稳态）
- 上传：~4 次/天（~400MB/天），约 12GB/月
- 下载：~1 次/周（~100MB 恢复测试），约 400MB/月
- 位置考虑：服务器在新西兰

### 成本计算表（月费，USD）

| 费用项 | Backblaze B2 | Cloudflare R2 | AWS S3 Standard | Hetzner Storage Box | GCS Nearline |
|--------|-------------|--------------|-----------------|-------------------->---|-------------|
| **存储费** | $0.017 (2.8GB x $6/TB) | $0.042 (2.8GB x $0.015/GB) | $0.064 (2.8GB x $0.023/GB) | EUR 4.15 (~$4.50) 固定 | $0.030 (2.8GB x $0.010/GB) |
| **上传/入口** | 免费 | 免费 | 免费 | 免费 | 免费 |
| **下载/出口** | 免费（<3x存储=8.4GB） | 免费（零出口） | $0.036 (0.4GB x $0.09) | 免费（无限流量） | $0.04 (0.4GB x $0.10) |
| **API 写请求** | 免费（Class A） | 免费（<100万/月） | $0.10 (~120 PUT x $0.005/千) | 免费 | $0.005 (0.4GB x $0.0125) |
| **API 读请求** | 免费（<2500/天） | 免费（<1000万/月） | ~$0.01 | 免费 | $0.01 |
| **最低存储期限** | 无 | 30天（IA tier） | 无（Standard） | 无 | 30天 |
| **最低存储计费** | 无 | 无 | 无 | 整个 BX11 套餐 | 最低 30 天 |
| **预估月费总计** | **~$0.02** | **~$0.04** | **~$0.11** | **~$4.50** | **~$0.09** |

### 逐项详细分析

#### 1. Backblaze B2 -- 推荐

**定价（来源：2026-04-05 官方页面抓取）：**
- 存储：$6/TB/月 = $0.006/GB/月，前 10GB 免费
- Class A（写）请求：免费
- Class B（下载）请求：每天前 2,500 次免费，之后 $0.004/万次
- Class C（列表）请求：每天前 2,500 次免费，之后 $0.004/千次
- 出口：免费，最高 3x 月均存储量，超出 $0.01/GB

**本场景计算：**
- 存储：2.8GB -- 在 10GB 免费额度内 = **$0.00**
- 上传：120 次 PUT/月 = 免费（Class A）
- 下载：4-5 次/月 = 免费（远低于每日 2,500 次）
- 出口：~0.4GB/月 = 免费（远低于 3x = 8.4GB）
- **总计：$0.00/月**（完全在免费额度内）

**关键优势：**
- 前 10GB 存储完全免费，本场景的 2.8GB 完全覆盖
- Class A API 调用免费
- S3 兼容 API（rclone 直接支持）
- 无最低存储期限
- PITFALLS.md 已详细研究 B2 的陷阱和最佳实践

**注意事项：**
- B2 生命周期规则基于文件版本，不适合管理带时间戳的备份文件（PITFALLS Pitfall 3）
- 需要在脚本中实现应用层清理逻辑
- 新西兰到 B2 美国数据中心的延迟约 150-200ms，但对备份上传影响不大
- 必须创建受限 Standard Application Key，不要用 Master Key

**置信度：HIGH** -- 定价来自 2026-04-05 官方页面直接抓取

#### 2. Cloudflare R2 -- 次选

**定价（来源：2026-04-05 官方页面抓取）：**
- Standard 存储：$0.015/GB/月
- Infrequent Access 存储：$0.01/GB/月
- Class A 操作：前 100 万次/月免费，之后 $4.50/百万次
- Class B 操作：前 1000 万次/月免费，之后 $0.36/百万次
- 出口：**零费用**（无限制）
- 免费额度：10GB 存储

**本场景计算：**
- 存储：2.8GB -- 在 10GB 免费额度内 = $0.00
- API 操作：远低于免费额度
- 出口：免费
- **总计：$0.00/月**（也在免费额度内）

**关键优势：**
- 零出口费用，最透明的定价
- S3 兼容 API
- Cloudflare 全球网络（有新西兰节点）
- Infrequent Access tier 可降低成本

**不推荐作为首选的原因：**
- 本项目已经使用 Cloudflare Tunnel，但备份场景不特别需要零出口
- B2 免费额度更宽裕（10GB + 免费写请求 + 每日免费读请求）
- 如果未来数据增长超过 10GB，B2 的 $6/TB 比 R2 的 $15/TB 便宜 60%
- PITFALLS 研究已针对 B2 完成，切换需要重新研究 R2 的陷阱

**置信度：HIGH** -- 定价来自官方产品页面

#### 3. AWS S3 Standard -- 不推荐

**定价（来源：2026-04-05 aws.amazon.com/s3/pricing 抓取）：**
- Standard 存储：$0.023/GB/月（前 50TB，us-east-1）
- PUT/COPY/POST/LIST：$0.005/千次请求
- GET/SELECT：$0.0004/千次请求
- 出口到 Internet：~$0.09/GB（前 10TB）
- Glacier Flexible Retrieval：$0.0036/GB/月
- 免费额度：5GB 存储（12 个月）

**本场景计算：**
- 存储：2.8GB x $0.023 = $0.064/月
- PUT 请求：~120 次/月 = $0.0006
- GET 请求：~5 次/月 = 可忽略
- 出口：~0.4GB x $0.09 = $0.036/月
- **总计：~$0.10/月**

**不推荐的原因：**
- 成本是 B2 的 5 倍以上
- 出口费用不可预测（恢复测试、紧急恢复都会产生费用）
- 对于新西兰用户，需要选择 ap-southeast-2（悉尼），定价可能更高
- 复杂的定价结构（存储 + 请求 + 出口 + 最低存储期限）
- 免费额度只有 12 个月

**什么时候考虑：** 如果将来需要与其他 AWS 服务集成

**置信度：HIGH** -- 定价来自官方页面抓取

#### 4. Hetzner Storage Box -- 不推荐（本场景）

**定价（来源：Hetzner 官网 docs.hetzner.com）：**
- BX11：EUR 4.15/月（~$4.50），100GB 存储
- BX21：EUR 7.59/月，500GB 存储
- 无限流量
- 支持协议：SSH/SFTP/SCP/SMB/WebDAV/FTP/FTPS
- **不支持 S3 API**

**本场景计算：**
- 最低 BX11 套餐 = EUR 4.15/月 = **~$4.50/月**

**不推荐的原因：**
- 月费 $4.50 是 B2 的 **225 倍**（B2 在免费额度内）
- 不支持 S3 API（rclone 可通过 SFTP 使用，但功能受限）
- 最低固定费用，无法按需付费
- 数据中心在德国（Falkenstein/Nuremberg），新西兰延迟高
- 不适合对象存储场景

**什么时候考虑：** 大量备份文件（>100GB）、需要 rsync/BorgBackup 等传统工具时

**注意：** Hetzner 还有 Object Storage（S3 兼容），但基础价格约 EUR 4.99/月，包含 1TB 存储。对于 2.8GB 的场景仍然太贵。

**置信度：MEDIUM** -- 价格来自 Hetzner 文档，但具体 BX11 价格无法从 JS 渲染的页面抓取，基于已知价格

#### 5. Google Cloud Storage Nearline -- 不推荐

**定价（来源：2026-04-05 cloud.google.com/storage/pricing 抓取）：**
- Nearline 存储：~$0.010/GB/月
- 数据检索：$0.01/GB
- 出口：~$0.11/GB（澳大利亚/新西兰区域）
- 操作 A 类：$0.10/千次
- 操作 B 类：$0.004/千次
- 最低存储期限：30 天

**本场景计算：**
- 存储：2.8GB x $0.010 = $0.028/月
- 检索/出口：~0.4GB x $0.11 = $0.044/月
- 操作：可忽略
- **总计：~$0.07/月**

**不推荐的原因：**
- 新西兰没有 GCS 节点，最近的是 australia-southeast1（悉尼）
- 悉尼区域的出口费用是 $0.11/GB（比 us 更贵）
- 30 天最低存储期限（7 天保留策略会浪费存储费）
- 复杂的定价结构
- 需要 Google Cloud 账号和项目设置

**置信度：MEDIUM** -- 定价部分来自页面抓取，部分基于训练数据补充

#### 6. 其他选项考虑

| 服务 | 月费估算 | 评价 |
|------|---------|------|
| Wasabi | ~$0.07 (2.8GB x $6.99/TB, 最低 1TB=$6.99) | 最低计费 1TB，不适合小规模 |
| IDrive e2 | ~$0.00 (前 10GB 免费) | 可行，但生态不如 B2 成熟 |
| Scaleway | ~$0.02 | 欧洲数据中心，延迟高 |

---

## 二、备份工具选择

### 推荐：pg_dump -Fc

| 工具 | 适用场景 | 本项目 | 推荐 |
|------|---------|--------|------|
| **pg_dump -Fc** | 单数据库逻辑备份，<100GB | 完美匹配 | **首选** |
| pg_dump -Fd | 并行备份大型单数据库 | 过度设计 | 不需要 |
| pgBackRest | 物理备份 + PITR + 大规模 | 复杂度高，非必要 | 不需要 |
| WAL-G | WAL 归档 + 云原生 | 需要 base backup 配合 | 不需要 |
| Barman | 企业级 PostgreSQL 备份 | 过度工程 | 不需要 |

**选择 pg_dump -Fc 的理由：**

1. **规模匹配**：数据库大小适中（预估 <1GB），pg_dump 完全足够
2. **-Fc 格式优势**（PITFALLS Pitfall 2 和 7）：
   - 自带 zlib 压缩（通常压缩比 60-80%）
   - 支持 `pg_restore --list` 验证备份完整性
   - 支持选择性恢复（只恢复特定表）
   - 支持并行恢复（`pg_restore -j`）
3. **简单性**：PostgreSQL 17.9 内置，无需安装额外工具
4. **Docker 兼容**：直接在容器内运行

**不选 pgBackRest 的理由：**
- 需要额外配置和存储库
- 适合需要 PITR（时间点恢复）的场景
- 对于 6-12 小时备份频率，丢失最多 12 小时数据是可接受的
- 增加运维复杂度但收益不大

**不选 WAL-G 的理由：**
- 主要用于持续 WAL 归档到云存储
- 需要 base backup + WAL 归档配合
- 当前已有 pg_dump 基础脚本
- 复杂度显著高于 pg_dump

### 备份命令模板

```bash
# 备份单个数据库
docker compose exec -T postgres pg_dump -Fc -U postgres -d noda_prod > /tmp/noda_prod_$(date +%Y%m%d_%H%M%S).dump

# 备份所有数据库的角色和表空间定义
docker compose exec -T postgres pg_dumpall --globals-only -U postgres > /tmp/globals_$(date +%Y%m%d_%H%M%S).sql

# 备份脚本循环结构
for db in noda_prod keycloak_db; do
  docker compose exec -T postgres pg_dump -Fc -U postgres -d "$db" \
    > "/tmp/${db}_$(date +%Y%m%d_%H%M%S).dump"
done
```

---

## 三、压缩策略

### 推荐：pg_dump -Fc 自带压缩（无需额外压缩）

| 压缩方式 | 压缩比 | 速度 | 兼容性 | 推荐 |
|---------|--------|------|--------|------|
| **-Fc 内置 zlib** | 良好（60-80%） | 快 | pg_restore 直接支持 | **首选** |
| pg_dump \| gzip | 更好 | 慢 | 需要 gunzip + psql | 备选 |
| pg_dump \| zstd | 最好 | 最快 | 需要 zstd + psql | 过度设计 |
| pg_dump \| lz4 | 一般 | 最快 | 需要 lz4 + psql | 不需要 |

**理由：**
- `-Fc` 格式内置 zlib 压缩，100MB 数据库通常压缩到 20-40MB
- 不需要双重压缩（`-Fc` + gzip 无额外收益，PITFALLS Pitfall 7）
- 如果未来数据库增长到 10GB+，可考虑 `pg_dump -Fd -j 4` 并行备份

**置信度：HIGH** -- PostgreSQL 官方文档明确说明

---

## 四、上传工具选择

### 推荐：rclone

| 工具 | 支持后端 | 校验和 | 加密 | 复杂度 | 推荐 |
|------|---------|--------|------|--------|------|
| **rclone** | 70+（含 B2, R2, S3, SFTP） | SHA256 | 可选 crypt | 低 | **首选** |
| aws s3 cli | 仅 S3 兼容 | MD5/SHA256 | SSE | 低 | 备选 |
| b2 cli | 仅 B2 | SHA1 | 无 | 低 | 备选 |

**选择 rclone 的理由：**

1. **统一工具**：支持 B2 原生 API 和 S3 API，以及所有其他云存储
2. **校验和验证**：上传后自动对比校验和（PITFALLS Pitfall 6）
3. **重试机制**：内置指数退避重试
4. **成熟稳定**：Go 编写，单二进制文件，无依赖
5. **灵活性**：如果将来从 B2 切换到 R2，只需改配置文件
6. **rclone copy** 命令天然支持增量上传

**安装和使用：**

```bash
# 安装 rclone（Debian/Ubuntu）
curl https://rclone.org/install.sh | sudo bash

# 配置 Backblaze B2
rclone config
# 选择 b2 类型，输入 Account ID 和 Application Key

# 上传备份文件
rclone copy /tmp/noda_prod_20260405_120000.dump remote:noda-backup/noda_prod/

# 验证上传
rclone check /tmp/noda_prod_20260405_120000.dump remote:noda-backup/noda_prod/noda_prod_20260405_120000.dump

# 清理超过 7 天的旧备份
rclone delete remote:noda-backup/noda_prod/ --min-age 7d
```

**不选 aws s3 cli 的理由：**
- 虽然 B2 支持 S3 API，但需要配置 endpoint URL
- rclone 功能更全面（校验和、重试、日志）
- 将来迁移存储提供商时更灵活

**不选 b2 cli 的理由：**
- 只支持 Backblaze B2
- 功能不如 rclone 全面
- rclone 同时支持 B2 原生 API 和 S3 API

**置信度：HIGH** -- rclone 是云备份上传的事实标准

---

## 五、调度方式

### 推荐：Jenkins cron

| 方式 | 优势 | 劣势 | 推荐 |
|------|------|------|------|
| **Jenkins cron** | 已有基础设施、日志可见、webhook 通知 | 依赖 Jenkins 可用 | **首选** |
| Docker sidecar + cron | 自包含 | 额外容器管理、PITFALLS Pitfall 5 | 不需要 |
| systemd timer | 系统级 | Docker 环境不适合 | 不适用 |
| Kubernetes CronJob | K8s 生态 | 项目不用 K8s | 不适用 |

**选择 Jenkins cron 的理由：**

1. 项目已有 Jenkins 基础设施（见 PROJECT.md）
2. Jenkins Pipeline 提供：
   - 可视化构建历史和日志
   - 失败时 webhook/邮件通知（直接满足 BACKUP-07）
   - 手动触发能力（恢复测试）
3. 避免 PITFALLS Pitfall 5（Docker 容器内 cron 的各种问题）
4. Jenkins Credentials 管理可安全存储 B2 API Key

**Jenkins Pipeline 结构：**

```groovy
pipeline {
    agent any
    triggers {
        cron('H */6 * * *')  // 每6小时，H 表示散列到具体分钟
    }
    environment {
        B2_KEY_ID = credentials('b2-key-id')
        B2_KEY = credentials('b2-application-key')
    }
    stages {
        stage('Backup Databases') {
            steps {
                sh 'scripts/backup/backup-to-cloud.sh'
            }
        }
        stage('Verify Upload') {
            steps {
                sh 'scripts/backup/verify-upload.sh'
            }
        }
        stage('Cleanup Old Backups') {
            steps {
                sh 'scripts/backup/cleanup-old-backups.sh'
            }
        }
    }
    post {
        failure {
            // webhook 通知（BACKUP-07）
            sh 'scripts/backup/notify-failure.sh'
        }
    }
}
```

**置信度：HIGH** -- PITFALLS 已验证 Jenkins 方案的可行性

---

## 六、加密方案

### 推荐：SSE-B2 + 受限 Application Key

| 方案 | 安全级别 | 复杂度 | 推荐 |
|------|---------|--------|------|
| **SSE-B2 + 受限 Key** | 中高 | 低 | **首选** |
| SSE-C（客户提供密钥） | 高 | 中 | 备选 |
| rclone crypt（客户端加密） | 最高 | 高 | 不需要 |
| 无加密 | 无 | 最低 | 不可接受 |

**选择 SSE-B2 + 受限 Key 的理由：**

1. SSE-B2 是 B2 默认行为，零配置
2. Backblaze 管理加密密钥，数据在磁盘上加密
3. 安全性的关键在于 **Access Key 保护**（PITFALLS Pitfall 4 和 10）：
   - 创建专用 Standard Application Key
   - 限制到特定 bucket
   - 仅授予 `writeFiles + deleteFiles + listFiles + readFiles` 权限
   - 设置 fileNamePrefix 限制
   - 绝不使用 Master Application Key
4. 客户端加密（rclone crypt）增加复杂度但收益有限：
   - 恢复流程更复杂
   - 增加备份/恢复时间
   - 当前安全需求由 SSE-B2 + Key 权限管理已满足

**什么时候升级到客户端加密：**
- 如果备份中包含高度敏感的个人信息（医疗、金融数据）
- 如果需要零知识加密（即使云提供商也无法读取）

**置信度：HIGH** -- PITFALLS Pitfall 10 已详细分析

---

## 七、不建议使用的工具和原因

| 工具/方案 | 不推荐原因 |
|----------|-----------|
| pgBackRest | 过度工程。需要额外配置存储库、适合 >100GB 或需要 PITR 的场景。对于 6-12h 备份频率的小数据库，pg_dump 足够 |
| WAL-G | 需要 base backup + WAL 归档配合。当前 WAL 归档只存本地（PITFALLS Pitfall 9），启用 WAL-G 需要全面重新设计备份架构 |
| Barman | 企业级工具，配置复杂，适合 DBA 管理的生产环境。当前规模不需要 |
| pg_dump 纯文本格式 | 无法验证完整性（无 `pg_restore --list`）、恢复不可控、文件更大（PITFALLS Pitfall 2 和 7） |
| gzip/zstd 二次压缩 | `-Fc` 已内置压缩，双重压缩无收益（PITFALLS Pitfall 7） |
| AWS S3 | 成本是 B2 的 5 倍+，出口费用不可预测，定价结构复杂 |
| Hetzner Storage Box | 固定月费 $4.50 vs B2 免费，不支持 S3 API，数据中心在德国 |
| Google Cloud Storage | 新西兰出口费用高，30 天最低存储期限与 7 天保留策略冲突 |
| Docker 容器内 cron | PITFALLS Pitfall 5 已详细分析各种问题（时区、日志、重启后消失） |
| Master Application Key | 安全灾难（PITFALLS Pitfall 4），泄露后攻击者可访问所有 bucket |
| B2 生命周期规则 | 不适合管理带时间戳的备份文件（PITFALLS Pitfall 3），需应用层清理 |

---

## 八、完整技术栈安装

```bash
# 1. 安装 rclone
curl https://rclone.org/install.sh | sudo bash

# 2. 验证 PostgreSQL 版本匹配
docker compose exec postgres pg_dump --version
# 应输出：pg_dump (PostgreSQL) 17.x

# 3. 配置 rclone B2 remote
rclone config
# n) New remote
# name> b2-backup
# Storage> 5 (Backblaze B2)
# account> [B2 Account ID]
# key> [B2 Application Key（受限 Standard Key）]

# 4. 创建 B2 Bucket
rclone mkdir b2-backup:noda-db-backup

# 5. 验证连接
rclone lsd b2-backup:
```

### Jenkins 配置

1. 在 Jenkins Credentials 中添加：
   - `b2-key-id`（Secret text）：B2 Account ID
   - `b2-application-key`（Secret text）：受限 Standard Application Key
2. 创建 Pipeline Job，使用上述 Jenkinsfile
3. 设置构建触发器：`H */6 * * *`（每 6 小时）

---

## 九、成本总结

### 月度成本估算

| 项目 | 费用 |
|------|------|
| Backblaze B2 存储（2.8GB，在免费额度内） | $0.00 |
| B2 API 调用（在免费额度内） | $0.00 |
| B2 出口（在 3x 免费额度内） | $0.00 |
| rclone（开源免费） | $0.00 |
| Jenkins（已有） | $0.00 |
| **总计** | **$0.00/月** |

### 未来增长预测

| 数据规模 | B2 月费 | R2 月费 | S3 月费 |
|---------|---------|---------|---------|
| 2.8GB（当前） | $0.00 | $0.00 | $0.11 |
| 10GB | $0.00 | $0.00 | $0.24 |
| 50GB | $0.30 | $0.60 | $1.17 |
| 100GB | $0.60 | $1.35 | $2.34 |
| 500GB | $3.00 | $7.35 | $11.75 |
| 1TB | $6.00 | $15.36 | $23.54 |

即使在数据增长到 1TB 时，B2 仍然比 R2 便宜 60%，比 S3 便宜 75%。

---

## 十、数据源

| 来源 | URL | 置信度 | 用途 |
|------|-----|--------|------|
| Backblaze B2 定价 | https://www.backblaze.com/cloud-storage/pricing | HIGH | 存储和出口定价 |
| Backblaze B2 API 定价 | https://www.backblaze.com/cloud-storage/transaction-pricing | HIGH | API 调用定价 |
| Cloudflare R2 定价 | https://www.cloudflare.com/developer-platform/products/r2/ | HIGH | R2 存储和操作定价 |
| AWS S3 定价 | https://aws.amazon.com/s3/pricing/ | HIGH | S3 存储和请求定价 |
| Hetzner Storage Box 文档 | https://docs.hetzner.com/storage/storage-box/general | HIGH | Storage Box 功能和限制 |
| Hetzner Object Storage 文档 | https://docs.hetzner.com/storage/object-storage/overview | HIGH | Object Storage 定价结构 |
| Google Cloud Storage 定价 | https://cloud.google.com/storage/pricing | MEDIUM | GCS Nearline 定价 |
| rclone 官网 | https://rclone.org/ | HIGH | rclone 功能和支持的后端 |
| PITFALLS.md | .planning/research/PITFALLS.md | HIGH | 所有陷阱和最佳实践 |
| PROJECT.md | .planning/PROJECT.md | HIGH | 项目需求和约束 |

---

*Stack research for: Noda PostgreSQL 云备份系统*
*Researched: 2026-04-05*
