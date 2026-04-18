# Pitfalls Research: 密钥管理集中化

**Domain:** 向现有 Docker Compose + Jenkins 单服务器基础设施添加集中式密钥管理
**Researched:** 2026-04-19
**Confidence:** MEDIUM-HIGH（基于完整代码审计 + Context7 文档验证；WebSearch 服务不可用，部分生态数据来自训练知识，已标注 LOW confidence）

---

## Critical Pitfalls

### Pitfall 1: 密钥服务故障导致完全无法部署 -- 单点故障

**What goes wrong:**
无论选择 Vault、Infisical 还是 Doppler，如果密钥管理服务不可用，Jenkins Pipeline 无法获取密钥，导致：
- `docker compose build` 缺少 `VITE_*` 构建时变量，前端构建产物中 Keycloak URL 为空
- `docker run` 缺少 `POSTGRES_PASSWORD` 等运行时变量，容器启动失败
- `envsubst` 模板渲染失败，蓝绿部署 env 文件生成错误
- `rclone` 缺少 B2 凭据，备份上传失败

**Why it happens:**
当前系统从 `docker/.env` 文件加载密钥（`pipeline-stages.sh` 第 22-29 行），文件在本地磁盘上，始终可用。迁移到集中式服务后，每次部署都需要网络请求获取密钥。如果密钥服务宕机（容器崩溃、OOM killed、磁盘满、网络分区），所有部署被阻塞。

**Consequences:**
- 紧急修复（如安全补丁）无法部署
- 备份系统如果依赖密钥服务获取 B2 凭据，恢复操作也被阻塞
- 形成恶性循环：密钥服务故障 -> 无法部署 -> 无法修复密钥服务

**How to avoid:**
1. **本地缓存优先**：密钥拉取后写入本地 `.env` 文件作为缓存。Pipeline 启动时先检查缓存是否存在且新鲜（如 24 小时内），如果新鲜则使用缓存，否则从密钥服务拉取
2. **优雅降级**：如果密钥服务不可达，回退到本地缓存文件（即使过期），在日志中标记警告
3. **密钥服务高可用**：设置 `restart: unless-stopped` + 健康检查 + 内存限制，确保容器自动重启
4. **紧急回退路径**：保留手动部署脚本（`deploy-apps-prod.sh`）作为完全独立的回退方案，不依赖密钥服务

**Warning signs:**
- 密钥服务容器的 `docker inspect` 显示 `RestartCount > 0`
- Jenkins Pipeline 在 Pre-flight 阶段超时
- `infisical export` 或 `vault kv get` 命令响应时间 > 5 秒

**Phase to address:**
Phase 1（密钥服务部署）-- 设计缓存和降级机制

**Recovery:**
| Step | Action |
|------|--------|
| 1 | `docker compose` 重启密钥服务容器 |
| 2 | 如果容器无法启动，从 B2 备份恢复密钥数据 |
| 3 | 如果 B2 也无法访问，从本地 `.env.bak` 恢复（迁移前的备份） |
| 4 | 临时回退到手动部署脚本 |

---

### Pitfall 2: 密钥迁移时遗漏密钥导致服务启动失败

**What goes wrong:**
当前系统有至少 3 个独立的 `.env` 文件，密钥分散在不同位置：

| 文件 | 密钥数量 | 用途 |
|------|---------|------|
| `docker/.env` | 12 个变量 | Docker Compose 基础设施（PostgreSQL、Keycloak、B2、Cloudflare、Anthropic） |
| `.env.production` | 14 个变量 | findclass-ssr 应用（VITE_*、SMTP、ReSend） |
| `scripts/backup/.env.backup` | 7 个变量 | 备份系统（PostgreSQL、B2） |
| `docker/env-findclass-ssr.env`（模板） | 14+ 变量 | 蓝绿部署 envsubst 模板 |

如果迁移时遗漏任何一个密钥：
- PostgreSQL 容器启动失败（缺少 `POSTGRES_PASSWORD`）
- Keycloak 无法连接数据库（缺少 `KC_DB_PASSWORD` / `KEYCLOAK_DB_PASSWORD`）
- 备份无法上传到 B2（缺少 `B2_APPLICATION_KEY`）
- findclass-ssr 构建产物中 Keycloak URL 为空（缺少 `VITE_KEYCLOAK_URL`）

**Why it happens:**
- `docker/.env` 和 `.env.production` 中有重复但值不同的变量（如 `POSTGRES_PASSWORD` 在两个文件中值相同，但 `KEYCLOAK_ADMIN_USER` 在 `.env.production` 中为空）
- `pipeline-stages.sh` 第 22-29 行有多路径加载逻辑（`$PROJECT_ROOT/docker/.env` 和 `$HOME/Project/noda-infra/docker/.env`），第二个路径是硬编码的本地开发路径
- `scripts/backup/lib/config.sh` 有独立的配置加载逻辑，与主 `.env` 文件无关
- `docker/.env` 曾被提交到 git 历史（commit `c15faba` 和 `240c59e`），历史中可能包含实际密码

**How to avoid:**
1. **迁移前审计**：`grep -rh '^\w+=' docker/.env .env.production scripts/backup/.env.backup | cut -d= -f1 | sort -u` 列出所有密钥名
2. **建立密钥清单**：为每个密钥记录名称、来源文件、使用方（哪个容器/脚本）、是否构建时需要
3. **迁移后验证脚本**：部署后自动检查所有关键变量是否已注入（类似现有 `decrypt-secrets.sh` 的 `VALIDATE_VARS` 模式）
4. **分阶段迁移**：先迁移一个服务（如 findclass-ssr），验证通过后再迁移其他服务

**Warning signs:**
- `docker compose config` 输出中某个环境变量值为空
- 容器日志中出现 `password authentication failed`
- `envsubst` 渲染后的 env 文件中存在空行或 `${VAR}` 未展开

**Phase to address:**
Phase 2（.env 迁移）-- 密钥清单 + 逐文件验证

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 从 git 历史中的 `.env` 文件（commit `c15faba` 前）恢复 |
| 2 | 或从 B2 备份中恢复加密的密钥文件 |
| 3 | 逐个比对密钥值，确保与迁移前一致 |

---

### Pitfall 3: VITE_* 构建时密钥注入失败 -- 前端白屏

**What goes wrong:**
`VITE_*` 变量在 `docker build` 时通过 `ARG` 写入 JS 文件，运行时环境变量无法覆盖。如果密钥管理服务在构建阶段不可用或注入方式错误：
- 前端 JS 中 `VITE_KEYCLOAK_URL` 为空字符串或 `undefined`
- 用户看到白屏或登录按钮无响应
- 浏览器控制台报错 `Cannot read properties of undefined`

当前构建命令在 `pipeline-stages.sh` 第 240-242 行：
```bash
--build-arg VITE_KEYCLOAK_URL=https://auth.noda.co.nz \
--build-arg VITE_KEYCLOAK_REALM=noda \
--build-arg VITE_KEYCLOAK_CLIENT_ID=noda-frontend
```

这些值当前是**硬编码在 shell 脚本中**的，不来自 `.env` 文件。

**Why it happens:**
- `VITE_*` 变量的特殊性：构建时固化，运行时不可变。不同于其他密钥可以在容器启动时注入
- 如果将 `VITE_*` 值存入密钥服务但不在 `docker build` 阶段正确取出，就会出问题
- 当前的硬编码值实际上是"非敏感配置"（Keycloak URL 是公开的），但如果未来需要通过密钥管理统一管理，需要注意注入时机

**How to avoid:**
1. **区分密钥类型**：`VITE_KEYCLOAK_URL`/`VITE_KEYCLOAK_REALM`/`VITE_KEYCLOAK_CLIENT_ID` 不是密钥（公开信息），可以保留在构建脚本或 docker-compose.yml 中
2. **如果必须纳入密钥管理**：确保 `docker build --build-arg` 之前已从密钥服务获取值，不能只在 `docker run` 时注入
3. **构建验证**：构建后用 `docker run --rm <image> grep -r "auth.noda.co.nz" /app/` 检查 JS 文件中是否包含正确的 URL

**Warning signs:**
- 构建日志中 `--build-arg VITE_KEYCLOAK_URL=` 后面为空
- 新镜像部署后 Chrome DevTools 中看到空的 keycloak 配置

**Phase to address:**
Phase 2（密钥注入设计）-- 明确区分构建时配置 vs 运行时密钥

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 回滚到上一个构建正确的镜像（蓝绿部署保留旧镜像） |
| 2 | 重新构建，确保 `--build-arg` 值正确传入 |
| 3 | 构建后验证 JS 产物 |

---

### Pitfall 4: 密钥轮换导致运行中服务中断

**What goes wrong:**
如果在密钥管理服务中轮换了数据库密码，但运行中的 Docker 容器仍在使用旧密码：
- PostgreSQL 连接池中的旧密码在重连时认证失败
- Keycloak 数据库连接断开后无法重连
- noda-ops 备份 cron 任务使用旧密码，备份静默失败

**Why it happens:**
Docker Compose 的 `environment` 值在容器启动时写入，运行中不会自动更新。即使密钥管理服务中更新了值，已运行的容器仍然使用启动时注入的环境变量。密码轮换通常只更新密钥存储，不同步更新所有消费者。

**How to avoid:**
1. **双凭据轮换模式**：
   - 步骤 1：在 PostgreSQL 中创建新用户/密码（保留旧用户）
   - 步骤 2：重新部署所有使用数据库的服务（使用新凭据）
   - 步骤 3：验证所有服务正常后，删除旧用户
2. **自动检测密钥变更**：密钥管理服务中标记密钥版本，Pipeline 在部署前检查版本是否变更
3. **蓝绿部署天然支持**：新容器使用新密码，旧容器继续运行直到切换完成

**Warning signs:**
- PostgreSQL 日志：`FATAL: password authentication failed`
- Keycloak 日志：`Connection refused` 或 `Authentication failed`
- 备份日志：`pg_dump: error: connection to server failed`

**Phase to address:**
Phase 3（密钥轮换策略设计）

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 如果是 PostgreSQL 密码：`docker exec` 进入 postgres 容器，`ALTER USER` 恢复旧密码 |
| 2 | 如果是 B2 密钥：在 Backblaze 控制台重新生成 application key |
| 3 | 如果是 Cloudflare token：在 Cloudflare Dashboard 回滚 |

---

### Pitfall 5: 备份系统与密钥管理的循环依赖

**What goes wrong:**
备份系统需要密钥才能运行（B2 凭据、PostgreSQL 密码），而密钥管理服务本身也需要备份（密钥数据备份到 B2）。如果密钥管理服务的数据库损坏且备份也依赖密钥服务，就形成死锁：
- 密钥服务需要恢复 -> 需要 B2 备份 -> 需要 B2 凭据 -> 凭据在密钥服务中 -> 密钥服务不可用

**Why it happens:**
当前备份系统通过 `scripts/backup/.env.backup` 独立获取 B2 凭据，不依赖任何外部服务。迁移后如果 B2 凭据也存入密钥服务，备份系统就必须先访问密钥服务才能备份，包括备份密钥服务本身。

**How to avoid:**
1. **备份系统独立于密钥管理**：B2 凭据和 PostgreSQL 密码保留在 `scripts/backup/.env.backup` 或 `.pgpass` 中，不迁移到密钥服务。备份系统是"最后防线"，不能依赖任何其他服务
2. **密钥服务自备份**：密钥服务的数据（如 Vault 的 Raft 存储、Infisical 的数据库）通过独立机制备份（直接文件系统备份到 B2），不经过密钥服务本身
3. **"根密钥"保护**：密钥服务的加密密钥（如 Vault unseal key、SOPS age 私钥）必须离线保存（不在任何自动化系统中）

**Warning signs:**
- 密钥服务恢复文档中提到"从 B2 恢复"但 B2 凭据存储在密钥服务中
- 备份脚本中出现 `infisical` 或 `vault` 命令调用

**Phase to address:**
Phase 1（密钥服务部署）-- 设计独立备份路径

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 从离线保存的根密钥恢复密钥服务 |
| 2 | 如果根密钥丢失，从 B2 备份恢复密钥数据库，但 B2 凭据需要从 `.env.backup` 缓存获取 |
| 3 | 如果两者都丢失，需要重新生成所有密钥（重建 PostgreSQL 用户、重新生成 B2 key 等） |

---

### Pitfall 6: 单服务器资源耗尽 -- 密钥服务 OOM

**What goes wrong:**
在单服务器上添加密钥管理服务会占用额外资源：

| 方案 | 额外内存需求 | 额外磁盘 | 额外 CPU |
|------|------------|---------|---------|
| Vault (dev mode) | ~150-300 MB | ~100 MB | 极低 |
| Vault (Raft production) | ~512 MB - 1 GB | ~500 MB+ | 低 |
| Infisical (self-hosted) | ~2-4 GB | ~10-20 GB | 中等 |
| SOPS + age (无服务) | 0 | ~10 MB | 0 |

当前服务器已运行：PostgreSQL、Keycloak（蓝绿 x2）、Nginx、noda-ops、findclass-ssr（蓝绿 x2），总内存使用约 4-6 GB。如果添加 Infisical self-hosted（需要 Node.js 后端 + PostgreSQL + Redis），可能导致 OOM。

**Why it happens:**
- Vault 需要 `IPC_LOCK` 能力（mlock 系统调用），Docker 中需要 `--cap-add=IPC_LOCK` 或 `disable_mlock = true`
- Infisical self-hosted 至少需要 3 个容器（backend + PostgreSQL + Redis），在单服务器上不现实
- Keycloak 蓝绿部署已经有两个 `1g` 内存的 Java 容器

**How to avoid:**
1. **选择轻量级方案**：SOPS + age（无服务端）或 Vault dev mode（仅用于单服务器场景）或 Infisical Cloud（免费 SaaS，不自托管）
2. **设置内存限制**：在 docker-compose 中为密钥服务设置 `mem_limit`
3. **监控资源使用**：部署前用 `docker stats` 确认当前资源余量
4. **避免 self-hosted Infisical**：单服务器不适合运行 3 个额外容器

**Warning signs:**
- `docker stats` 显示总内存使用 > 80%
- `dmesg` 中出现 `Out of memory: Killed process`
- 密钥服务容器频繁重启（OOM killed）

**Phase to address:**
Phase 1（方案选型）-- 资源评估决定方案

**Recovery:**
| Step | Action |
|------|--------|
| 1 | `docker stop` 密钥服务容器释放内存 |
| 2 | 使用本地 `.env` 缓存文件继续部署 |
| 3 | 重新评估方案（降级到 SOPS + age 无服务端方案） |

---

### Pitfall 7: Jenkins withCredentials 与密钥服务集成的 masking 盲区

**What goes wrong:**
当前 Jenkins Pipeline 已使用 `withCredentials` 管理 Cloudflare API token（`Jenkinsfile.findclass-ssr` 第 134-136 行）。如果迁移到集中式密钥管理，可能出现：
- Jenkins 的 `withCredentials` masking 只对精确字符串值生效。如果密钥值被 base64 编码、URL 编码或作为 URL 参数传递，原始值被 mask 但转换后的值不被 mask
- `infisical run` 或 `vault kv get` 的输出中密钥值可能出现在 Jenkins console log 中
- shell 脚本中的 `set -x`（debug 模式）会将密钥值打印到日志

**Why it happens:**
- Jenkins 的 secret masking 是字符串替换，不是真正的安全机制
- `pipeline-stages.sh` 中的 `set -euo pipefail` 包含了 `set -e`，某些错误场景下 bash 会打印导致失败的命令行
- 当前 `pipeline-stages.sh` 第 24-26 行的 `set -a; source "$_env_path"; set +a` 会将所有变量导出到环境中，包括密钥

**How to avoid:**
1. **不要在 Pipeline 中直接输出密钥值**：使用 `infisical export --output-file=/tmp/secrets.env` 写入文件，不输出到 stdout
2. **禁用 set -x**：确保在处理密钥的代码段前后不开启 debug 模式
3. **使用 `withCredentials` 而非环境变量**：对于 Jenkins 管理的密钥，继续使用 `withCredentials` binding，不通过 `source .env` 加载
4. **审查所有日志输出**：`grep -n 'echo.*$\|print.*$\|log.*$' scripts/pipeline-stages.sh` 确认没有泄漏密钥的 echo 语句

**Warning signs:**
- Jenkins console log 中出现 `****` masking（说明值被正确 mask）
- Jenkins console log 中出现实际的密钥值（说明 masking 失败）
- 构建日志被标记为包含敏感信息

**Phase to address:**
Phase 2（Jenkins 集成设计）

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 立即轮换泄漏的密钥 |
| 2 | 清除 Jenkins 构建日志（Manage Jenkins -> 构建历史管理） |
| 3 | 审计谁在泄漏期间访问了构建日志 |

---

### Pitfall 8: Docker Compose 启动顺序依赖密钥服务 -- 启动超时

**What goes wrong:**
如果所有服务的环境变量都从密钥服务获取，`docker compose up` 的启动链变为：
1. 密钥服务启动 -> 健康检查通过
2. PostgreSQL 启动（需要 `POSTGRES_PASSWORD`） -> 健康检查通过
3. noda-ops 启动（需要 PostgreSQL 连接 + B2 凭据） -> 健康检查通过
4. Nginx 启动

如果密钥服务启动慢（如 Vault 需要执行 unseal 操作），PostgreSQL 等待密钥超时，整个 compose stack 无法启动。

**Why it happens:**
- Docker Compose 的 `depends_on` 只保证容器启动顺序，不保证服务就绪
- 密钥服务可能有特殊的初始化步骤（Vault unseal、Infisical database migration）
- 当前系统没有这个问题因为所有密钥都在本地 `.env` 文件中

**How to avoid:**
1. **密钥预注入模式**：在 `docker compose up` 之前，先从密钥服务获取所有密钥写入 `.env` 文件，然后 compose 从文件读取
2. **不修改 docker-compose.yml 的 `environment` 加载方式**：保持 `${VAR}` 语法从 `.env` 文件读取，只改变 `.env` 文件的生成方式（从密钥服务生成 vs 手动维护）
3. **密钥服务不加入 Docker Compose**：如果使用 SaaS 方案（Infisical Cloud）或 CLI 工具（SOPS），不需要运行本地服务

**Warning signs:**
- `docker compose up` 日志中出现 `POSTGRES_PASSWORD is not set`
- 容器启动后立即退出（exit code 1）
- `docker compose ps` 显示密钥服务 `health: starting` 但其他服务已经是 `unhealthy`

**Phase to address:**
Phase 2（密钥注入架构设计）

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 手动创建 `.env` 文件（使用备份的密钥值） |
| 2 | `docker compose up` 不依赖密钥服务 |
| 3 | 修复密钥服务启动问题 |

---

### Pitfall 9: 加密密钥管理失误 -- 数据永久丢失

**What goes wrong:**
项目已有 `scripts/utils/decrypt-secrets.sh` 使用 SOPS + age 加密方案（第 74-112 行）。如果引入新的密钥管理方案并改变加密方式：
- age 私钥丢失 -> 所有 SOPS 加密文件（`secrets/.env.production.enc` 等）无法解密
- Vault unseal key 丢失 -> Vault 存储的所有密钥无法恢复
- Infisical encryption key 丢失 -> 自托管实例的所有密钥无法解密

`decrypt-secrets.sh` 第 88-102 行的密钥查找逻辑：
```bash
# 1. SOPS_AGE_KEY_FILE 环境变量
# 2. team-keys/age-key-${USER}.txt 本地文件
```

如果迁移后 age 私钥不再被正确引用，现有加密文件无法解密。

**Why it happens:**
- 加密密钥（根密钥）通常不存储在密钥管理系统中（鸡生蛋问题）
- 开发者机器上的 age 私钥可能在清理项目时被误删
- Vault 的 unseal 过程需要法定数量的 unseal key，单个 key 无法恢复

**How to avoid:**
1. **保留现有 SOPS + age 方案**：已验证可用（`decrypt-secrets.sh` 存在且逻辑完整），不要替换加密方案
2. **根密钥离线备份**：age 私钥至少保存 2 份副本在不同物理位置（如加密 U 盘 + 密码管理器）
3. **新方案使用现有加密密钥**：如果使用 Vault 或 Infisical，其内部加密密钥也必须离线备份
4. **迁移前测试恢复流程**：从备份恢复密钥服务至少做一次全流程演练

**Warning signs:**
- `sops --decrypt` 报错 `could not find matching private key`
- Vault `operator init` 后 unseal key 未保存
- `team-keys/` 目录中 age 密钥文件不存在

**Phase to address:**
Phase 1（根密钥备份策略）

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 从离线备份恢复 age 私钥 |
| 2 | 如果离线备份也丢失：密钥数据永久丢失，必须重新生成所有密码 |
| 3 | 重建成本极高：PostgreSQL ALTER USER、Keycloak 管理员密码重置、B2 key 重新生成、Cloudflare token 重新生成 |

---

### Pitfall 10: 迁移后 docker/.env 文件删除时机错误

**What goes wrong:**
迁移完成后删除 `docker/.env` 文件，但：
- 还有脚本通过 `source "$PROJECT_ROOT/docker/.env"` 加载密钥（`pipeline-stages.sh` 第 22-29 行、`blue-green-deploy.sh` 第 23-25 行）
- Jenkins workspace 中的 `.env` 是 gitignored 的，新 checkout 不会有这个文件
- `docker/.env` 曾被提交到 git（commit `c15faba`），`git clone` 可能拉到旧版本

**Why it happens:**
- 密钥文件在 `.gitignore` 中但不排除已经 tracked 的文件（`git rm --cached` 未执行）
- 多个脚本有独立的 `.env` 加载逻辑，不是通过共享函数
- `pipeline-stages.sh` 有硬编码的备用路径 `$HOME/Project/noda-infra/docker/.env`

**How to avoid:**
1. **不要删除 `.env` 文件，改为自动生成**：Pipeline 在部署前从密钥服务拉取密钥写入 `.env` 文件，脚本保持现有的 `source` 逻辑不变
2. **清理 git 历史**：`git filter-branch` 或 `BFG Repo Cleaner` 清除历史中的密钥文件
3. **迁移分两步**：(a) 先让 `.env` 文件由密钥服务自动生成（脚本不变），(b) 确认稳定后再删除旧的手动维护的 `.env` 文件
4. **修改所有硬编码路径**：`pipeline-stages.sh` 第 22 行的 `$HOME/Project/noda-infra/docker/.env` 需要改为相对路径

**Warning signs:**
- `docker compose config` 输出变量值为空（`.env` 文件不存在或为空）
- `pipeline-stages.sh` 日志中 "loading .env" 但实际没加载到任何变量
- `git status` 显示 `.env` 文件被修改（说明文件仍被 tracked）

**Phase to address:**
Phase 2（迁移执行）-- 先生成后删除

**Recovery:**
| Step | Action |
|------|--------|
| 1 | 从 B2 备份恢复 `.env` 文件 |
| 2 | 或从 `git stash` / `git show HEAD:docker/.env` 恢复（如果已 commit） |
| 3 | 或从 git 历史恢复（`git show c15faba~1:docker/.env`） |

---

## Moderate Pitfalls

### Pitfall 11: Infisical/Vault 免费额度超限

**What goes wrong:**
- **Infisical Cloud 免费版**：限制 5 个项目、3 个环境、基础 RBAC。~60 次/月部署频率可能接近 API 调用限制
- **Vault Community**：无 API 限制但需要自行运维。单节点无 HA
- **SOPS + age**：无服务端限制，纯 CLI 工具

**Prevention:**
1. 评估每月密钥读取次数：60 次部署 x 平均每次读取 3-5 个密钥 = 180-300 次 API 调用/月。Infisical 免费版应足够
2. 监控 API 使用量
3. 如果超限，降级到 SOPS + age 本地方案

### Pitfall 12: noda-ops 容器内备份脚本无法访问密钥服务

**What goes wrong:**
`noda-ops` 容器运行备份 cron 任务，需要 B2 凭据和 PostgreSQL 密码。如果密钥存储在外部服务（如 Infisical Cloud），容器内需要：
- 安装 Infisical CLI 或 Vault CLI
- 配置认证（machine identity token 或 universal auth）
- 网络访问密钥服务（通过 Cloudflare Tunnel 出站或直接公网访问）

**Prevention:**
1. noda-ops 容器保持从环境变量获取密钥（`docker-compose.yml` 第 75-83 行已配置）
2. 密钥在 `docker compose up` 前注入到 `.env` 文件，compose 自动传递给容器
3. 不在容器内安装密钥客户端

### Pitfall 13: envsubst 模板中的密钥引用缺失

**What goes wrong:**
`manage-containers.sh` 的 `prepare_env_file()` 使用 `envsubst` 渲染 env 模板。当前模板路径为 `docker/env-${SERVICE_NAME}.env`。Jenkinsfile.keycloak 第 29 行定义了：
```
ENVSUBST_VARS = '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'
```

如果密钥注入改为从密钥服务获取，但 `envsubst` 需要的环境变量在渲染时不存在，模板中的 `${VAR}` 会变成空字符串。

**Prevention:**
1. `envsubst` 执行前确保所有引用的变量已设置（从密钥服务拉取后 export）
2. 在 `prepare_env_file()` 中添加变量存在性检查
3. 不改变 `envsubst` 的工作方式，只改变变量的来源

### Pitfall 14: Jenkins workspace 中密钥文件残留

**What goes wrong:**
如果 Pipeline 将密钥写入文件（如 `infisical export --output-file=.env`），构建完成后文件残留在 Jenkins workspace 中。其他项目的构建（如果共享同一个 node）可能读取到这些文件。

**Prevention:**
1. 使用 `post { always { sh 'rm -f .env.* secrets/**' } }` 清理密钥文件
2. 将密钥文件写入 `/tmp/` 而非 workspace（已有 `decrypt-secrets.sh` 使用 `/tmp/noda-secrets/`）
3. 设置文件权限 `chmod 600`

### Pitfall 15: 密钥值中的特殊字符破坏 shell 脚本

**What goes wrong:**
密钥值可能包含 shell 特殊字符（如 B2 Application Key `K0048667N4HUsLs35TYfyJzlY8i/Gx8` 中的 `/`，Cloudflare JWT token 中的 `.` 和 `-`）。如果通过 shell 变量传递时引号处理不当：
- `source .env` 时，值中的空格、`$`、反引号会导致解析错误
- `docker run -e PASSWORD=$VALUE` 中，特殊字符可能被 shell 展开

**Prevention:**
1. `.env` 文件中的值始终用双引号包裹：`KEY="value/with+special=chars"`
2. `source` 后使用变量时始终加双引号：`"$PASSWORD"` 而非 `$PASSWORD`
3. 使用 `docker run --env-file` 而非 `-e` 传递密钥（env-file 中不需要引号）

### Pitfall 16: 多个 env 文件中同一密钥值不同步

**What goes wrong:**
当前 `POSTGRES_PASSWORD` 同时存在于 `docker/.env`、`.env.production` 和 `scripts/backup/.env.backup` 三个文件中。如果只更新了其中一个：
- 备份系统使用旧密码，备份失败
- findclass-ssr 使用新密码，连接失败
- Keycloak 使用旧密码，登录失败

集中式密钥管理应解决这个问题，但如果迁移不彻底（部分文件仍手动维护），值不一致问题会更严重。

**Prevention:**
1. 迁移时确保同一密钥只有一个 source of truth
2. 使用密钥引用（如 Infisical 的 secret references）而非复制值
3. 部署前自动检查所有文件中的关键密钥值是否一致

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| 只用 SOPS + age 不部署服务端 | 零资源消耗，零运维负担 | 无自动轮换、无审计日志、无 Web UI | 永远可接受 -- 单服务器、低频率部署场景 |
| 保留 `.env` 文件作为缓存 | Pipeline 兼容性不变，脚本改动最少 | 需要同步密钥服务和文件 | 迁移过渡期可接受 |
| 密钥服务使用 dev 模式（无 TLS） | 简化配置，Docker 内部网络已隔离 | 无法验证密钥服务身份 | 仅限 Docker 内部网络，永不暴露到公网 |
| 不加密 `.env` 缓存文件 | 简化部署流程 | 服务器被入侵时密钥泄露 | 不接受 -- `.env` 文件应 `chmod 600` + 文件系统加密 |
| 密钥服务不自备份 | 减少运维复杂度 | 密钥服务数据丢失需重建所有密钥 | 不接受 -- 密钥数据必须备份 |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Jenkins + Infisical | 在 `sh '''...'''` 块中直接调用 `infisical` CLI | 用 `withCredentials` 包装 machine identity token，在 `sh` 中 `infisical export --token=$TOKEN --output-file=.env` |
| Jenkins + Vault | 在 Declarative Pipeline `environment` 块中调用 vault CLI | `environment` 块不支持复杂 shell 命令，应在 `sh` 步骤中获取密钥 |
| Docker Compose + 密钥服务 | 在 compose 中使用 `secrets:` 指令 | `secrets:` 在非 Swarm 模式下是 bind-mount 文件，不如预生成 `.env` 文件简单 |
| envsubst + 密钥服务 | envsubst 执行时变量不存在 | 先 `source` 生成的 `.env` 文件，再执行 `envsubst` |
| rclone + B2 | 动态生成 rclone config 中暴露密钥 | rclone config 文件应 `chmod 600` 且在 `/tmp/` 中使用后立即删除 |
| Keycloak 蓝绿部署 | 新容器使用新密码但数据库中仍是旧密码 | 蓝绿部署时先更新数据库密码（通过 `ALTER USER`），再启动新容器 |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| 密钥服务 API 调用延迟 | 每次部署额外增加 5-30 秒（密钥拉取时间） | 本地缓存 + 批量获取（`infisical export` 一次获取所有） | 部署频率 > 10 次/天 |
| 密钥服务内存泄漏 | 服务器可用内存逐渐减少，最终 OOM | `mem_limit: 512m` + 定期 `docker restart` | 连续运行 > 30 天 |
| 大量密钥版本的存储膨胀 | 磁盘使用持续增长 | 设置版本保留策略（保留最近 10 个版本） | 密钥数量 > 100 |
| Vault unseal 操作耗时 | 每次重启 Vault 需要 30-60 秒 unseal | 使用 auto-unshare（需付费）或 `disable_mlock` + 文件加密 | 每次服务器重启 |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| 密钥文件权限 644（世界可读） | 服务器上任何用户可读取所有密钥 | `chmod 600 .env` + `chown root:docker .env` |
| 在 git commit message 或 PR 中粘贴密钥值 | 密钥永久暴露在 git 历史中 | 使用 `git secrets` pre-commit hook |
| docker/.env 曾被提交到 git（commit `c15faba`） | 历史中包含真实密钥 | `git filter-branch` 清除历史 + 轮换所有密钥 |
| Jenkins 构建日志中泄露密钥 | 任何有 Jenkins 访问权限的人可看到 | `withCredentials` masking + 避免 `set -x` + 避免 `echo $VAR` |
| age 私钥存储在项目目录中 | `git add .` 时可能意外提交 | `team-keys/` 加入 `.gitignore` + 离线备份 |

---

## "Looks Done But Isn't" Checklist

- [ ] **密钥迁移完成**: 看起来所有密钥已迁移，但 backup 系统仍在读 `scripts/backup/.env.backup` -- 验证所有 3 个 `.env` 文件的密钥都已迁移
- [ ] **Pipeline 正常**: 手动触发一次 Pipeline 成功，但 `set -a; source .env` 的路径硬编码在 pipeline-stages.sh 中 -- 验证 Jenkins workspace 路径正确
- [ ] **密钥服务运行**: `docker ps` 显示密钥服务容器 running，但健康检查未通过 -- 验证健康检查端点返回 200
- [ ] **B2 备份正常**: 手动运行 `backup-postgres.sh` 成功，但 cron 任务在 noda-ops 容器内运行时密钥不可用 -- 验证容器内环境变量已注入
- [ ] **密钥已删除旧文件**: 旧的 `.env` 文件已删除，但 git 中仍 tracked -- `git ls-files | grep '\.env'` 确认无 tracked 的密钥文件
- [ ] **加密密钥已备份**: age 私钥在本地存在，但未离线备份 -- 验证至少有 2 份不同物理位置的副本
- [ ] **Jenkins credentials 已更新**: `withCredentials` 中的 credential ID 已更新，但旧 ID 仍被其他 Pipeline 引用 -- `grep -r credentialsId jenkins/` 确认所有引用一致

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| 密钥服务故障（Pitfall 1） | LOW | 重启容器或使用本地 `.env` 缓存 |
| 密钥遗漏（Pitfall 2） | MEDIUM | 从 git 历史或 B2 备份恢复，逐个验证 |
| VITE_* 构建失败（Pitfall 3） | LOW | 重新构建镜像（蓝绿部署保留旧镜像） |
| 密钥轮换中断（Pitfall 4） | MEDIUM | 双凭据回退或 ALTER USER 恢复旧密码 |
| 备份循环依赖（Pitfall 5） | HIGH | 需要离线根密钥 + 重建 B2 连接 |
| 资源耗尽（Pitfall 6） | LOW | 停止密钥服务容器 + 使用 SOPS 本地方案 |
| 日志泄露（Pitfall 7） | MEDIUM | 轮换泄露密钥 + 清除 Jenkins 日志 |
| 启动顺序超时（Pitfall 8） | LOW | 手动创建 `.env` 文件 |
| 加密密钥丢失（Pitfall 9） | **CRITICAL** | 如果无离线备份，需重建所有密钥 |
| .env 删除过早（Pitfall 10） | LOW | 从 B2 或 git 历史恢复文件 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 单点故障（P1） | Phase 1: 密钥服务部署 | 模拟密钥服务宕机，验证 Pipeline 仍可用缓存部署 |
| 密钥遗漏（P2） | Phase 2: 迁移执行 | 部署后 `docker compose config` 对比所有变量值 |
| VITE_* 注入（P3） | Phase 2: Jenkins 集成 | 构建后 `docker run --rm <img> grep -r auth.noda.co.nz /app/` |
| 密钥轮换（P4） | Phase 3: 轮换策略 | 执行一次完整的 PostgreSQL 密码轮换演练 |
| 备份循环（P5） | Phase 1: 架构设计 | 验证备份系统完全不依赖密钥服务 |
| 资源耗尽（P6） | Phase 1: 方案选型 | `docker stats` 确认总内存 < 80% |
| 日志泄露（P7） | Phase 2: Jenkins 集成 | 审查 Jenkins console log 无明文密钥 |
| 启动顺序（P8） | Phase 2: 注入架构 | `docker compose up` 完整测试 |
| 加密密钥（P9） | Phase 1: 备份策略 | 验证 age 私钥至少有 2 份离线副本 |
| .env 删除（P10） | Phase 2: 迁移过渡 | 保留 `.env.bak` 一个里程碑周期 |

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| 密钥方案选型 | P6: Infisical self-hosted 资源不足 | 优先评估 SOPS + age 或 Infisical Cloud（免费 SaaS） |
| 密钥服务部署 | P5: 备份循环依赖 | 备份系统保持独立于密钥服务 |
| 密钥服务部署 | P9: 加密密钥未备份 | 部署前先备份 age 私钥到离线介质 |
| .env 文件迁移 | P2: 密钥遗漏 | 先审计所有密钥，建立清单 |
| .env 文件迁移 | P10: 删除过早 | 先自动生成 .env，确认稳定后再删旧文件 |
| Jenkins Pipeline 集成 | P3: VITE_* 构建时注入 | 保持构建时 `--build-arg` 不变 |
| Jenkins Pipeline 集成 | P7: 日志泄露 | 审查所有 `echo`/`log` 语句 |
| 密钥轮换设计 | P4: 运行中服务中断 | 设计双凭据轮换模式 |
| B2 备份集成 | P12: 容器内密钥访问 | 容器通过环境变量获取，不在容器内安装 CLI |

---

## 方案建议：最小风险路径

基于以上 10 个 Critical Pitfall 的分析，推荐最小风险的实施方案：

### 推荐：SOPS + age + Infisical Cloud（混合方案）

**原理：**
- **SOPS + age**（已有）：加密密钥文件存入 git（`secrets/*.enc`），CLI 工具解密到本地 `.env` 文件
- **Infisical Cloud 免费版**（新增）：Web UI 管理、审计日志、密钥版本历史、团队协作
- 两者同步：密钥值在 Infisical 中管理，`infisical export` 写入 `.env`，同时 `sops --encrypt` 加密版本存入 git

**避免的 Pitfall：**
- P1（单点故障）：SOPS 本地文件始终可用，Infisical 只是辅助
- P5（备份循环）：git 中的加密文件就是备份，不依赖密钥服务
- P6（资源耗尽）：无额外容器
- P8（启动顺序）：无本地服务依赖

**仍需处理的 Pitfall：**
- P2（密钥遗漏）：需要完整审计
- P3（VITE_*）：构建时注入逻辑不变
- P4（密钥轮换）：需要设计轮换流程
- P7（日志泄露）：需要审查日志输出
- P9（加密密钥）：age 私钥必须离线备份
- P10（.env 删除）：分阶段过渡

---

## Sources

- 项目代码库审计：`docker/.env`、`.env.production`、`scripts/backup/.env.backup`、`docker/docker-compose.yml`、`scripts/pipeline-stages.sh`、`scripts/utils/decrypt-secrets.sh`
- [Context7: Infisical CLI 文档](https://context7.com/infisical/cli/llms.txt) -- `infisical export`、`infisical run`、machine identity 认证，HIGH confidence
- [Context7: Infisical 平台文档](https://context7.com/websites/infisical/llms.txt) -- self-hosted 部署、定价层级、SSO 功能，HIGH confidence
- HashiCorp Vault Docker 资源需求 -- 基于训练知识（WebSearch 不可用），MEDIUM confidence
- Jenkins `withCredentials` 常见问题 -- 基于训练知识（WebSearch 不可用），MEDIUM confidence
- Docker Compose `secrets:` 指令限制 -- 基于训练知识，HIGH confidence（Docker 官方文档长期稳定）
- git 历史分析：`docker/.env` 曾在 commit `c15faba` 和 `240c59e` 中被提交

---
*Pitfalls research for: Noda v1.8 密钥管理集中化*
*Researched: 2026-04-19*
