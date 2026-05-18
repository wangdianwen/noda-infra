# Phase 60: CI/CD 改造 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-18
**Phase:** 60-CI/CD 改造
**Areas discussed:** 改造策略, Compose 文件同步, 远程命令封装, 健康检查与 Nginx reload, Pipeline 并发控制, 远程部署回滚策略, 日志与可观测性

---

## 改造策略

| Option | Description | Selected |
|--------|-------------|----------|
| Remote Wrapper 层 | 新建 remote-ops.sh 封装层，保留 Mac 本地部署回退能力 | ✓ |
| 直接替换 | 直接修改 pipeline-stages.sh 全部改为 SSH 远程执行 | |
| 两套并行脚本 | pipeline-stages.sh 保持不变，新建 pipeline-stages-remote.sh | |

**Notes:** 用户选择了 Remote Wrapper 层方案，明确要求保留 Mac 回退能力。

| Option | Description | Selected |
|--------|-------------|----------|
| 保留 Mac 回退 | 通过 DEPLOY_TARGET 环境变量切换本地/远程 | ✓ |
| 纯远程，不保留 | 只支持 SSH 远程执行 | |

| Option | Description | Selected |
|--------|-------------|----------|
| 单函数封装 | docker_remote() 统一函数 | |
| 分类函数封装 | 按 compose/build/run 分类 | |
| Claude 决定 | 由 Claude 判断最合适的封装方式 | ✓ |

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins 环境变量 | DEPLOY_TARGET 和 R4S_HOST 在 Jenkins environment 中定义 | ✓ |
| 配置文件 | scripts/lib/ 下 deploy-target.env 文件 | |

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins Credentials | SSH 私钥存 Jenkins Credentials，withCredentials 加载 | ✓ |
| 默认 SSH 密钥 | jenkins 用户 ~/.ssh/id_rsa 已配置免密 | |

| Option | Description | Selected |
|--------|-------------|----------|
| 快速失败 | set -e，任何错误立即停止 Pipeline | ✓ |
| 重试容错 | SSH 连接重试，增加容错 | |

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkinsfile 不变 | 只改 pipeline-stages.sh 内部实现 | ✓ |
| Jenkinsfile 同步重构 | 添加 Image Transfer 等新阶段 | |

| Option | Description | Selected |
|--------|-------------|----------|
| Mac 构建 + 传输 | Mac 本地 docker build，docker save/load 传输 | ✓ |
| r4s 本地构建 | r4s 上构建镜像 | |
| 混合模式 | 分服务决定构建位置 | |

---

## Compose 文件同步

| Option | Description | Selected |
|--------|-------------|----------|
| rsync/scp 同步 | 每次部署时 Jenkins 通过 rsync/scp 同步 compose 文件 | |
| r4s git pull | r4s 上 git clone noda-infra，每次 git pull 更新 | ✓ |
| 手动同步 | r4s 上 compose 文件固定不变 | |

**Notes:** 用户主动选择了 git pull 方案。后续讨论确认 r4s 只需要部署配置（compose 文件、nginx 配置），不需要应用源代码。

| Option | Description | Selected |
|--------|-------------|----------|
| Deploy Key | r4s 配置 SSH deploy key 只读访问 GitHub | ✓ |
| HTTPS + PAT | Personal Access Token | |

| Option | Description | Selected |
|--------|-------------|----------|
| /opt/noda/noda-infra/ | 标准部署路径 | ✓ |
| /root/noda-infra/ | root 用户 HOME 下 | |

| Option | Description | Selected |
|--------|-------------|----------|
| 固定 main 分支 | r4s 始终 pull main | ✓ |
| Pipeline 指定分支 | 动态 checkout 指定分支 | |

---

## 远程命令封装

| Option | Description | Selected |
|--------|-------------|----------|
| 显式分步执行 | 每步明确本地/远程，代码最清晰 | ✓ |
| 透明代理函数 | docker_remote() 自动决定本地/远程 | |

**Notes:** 用户选择了显式分步执行。提问"如果本地 mac build，为什么 r4s 需要代码？"——澄清了 r4s 只需要 noda-infra 仓库（部署配置），不需要 noda-apps（应用源代码）。

| Option | Description | Selected |
|--------|-------------|----------|
| 嵌套 SSH exec | ssh root@r4s 'docker exec container cmd' | ✓ |
| 远程脚本 | r4s 上部署脚本，ssh 执行远程脚本 | |

| Option | Description | Selected |
|--------|-------------|----------|
| Mac envsubst + 管道传输 | envsubst 后管道传输 env 文件到 r4s | ✓ |
| 本地文件 + scp | envsubst 后 scp 传输 | |

---

## 健康检查与 Nginx reload

| Option | Description | Selected |
|--------|-------------|----------|
| SSH docker inspect | 远程执行 docker inspect 检查容器健康 | ✓ |
| Mac curl r4s 端口 | 从 Mac 直接 curl r4s 暴露端口 | |

| Option | Description | Selected |
|--------|-------------|----------|
| 保持不变 | Mac curl class.noda.co.nz 走完整链路 | ✓ |
| r4s 内部验证 | SSH 到 r4s 后内部 curl | |

| Option | Description | Selected |
|--------|-------------|----------|
| SSH exec reload | ssh root@r4s 'docker exec nginx nginx -s reload' | ✓ |
| 重启 nginx 容器 | docker compose restart nginx | |

| Option | Description | Selected |
|--------|-------------|----------|
| 保持 DNS resolver | resolver 127.0.0.11 动态 DNS，reload 刷新 | ✓ |
| upstream 文件切换 | 固定 IP 或配置文件切换 | |

| Option | Description | Selected |
|--------|-------------|----------|
| SSH inspect + Mac curl | 组合验证：远程容器健康 + 本地 HTTP 检查 | ✓ |
| 纯 r4s 内部检查 | 只在 r4s 上检查 | |

---

## Pipeline 并发控制

| Option | Description | Selected |
|--------|-------------|----------|
| r4s flock 文件锁 | Pipeline 执行前 SSH 获取 /tmp/noda-deploy.lock | ✓ |
| 人工自律 | 信任手动触发 | |

| Option | Description | Selected |
|--------|-------------|----------|
| Pre-flight 获取锁 | Pipeline 开始时获取锁 | ✓ |
| 每命令加锁 | 每个远程命令包装在 flock 中 | |

---

## 远程部署回滚策略

| Option | Description | Selected |
|--------|-------------|----------|
| 镜像 tag 备份 | 部署前 docker tag 保存当前镜像 | ✓ |
| 容器 commit 快照 | docker commit 保存容器状态 | |
| 回退到 Mac 本地 | DEPLOY_TARGET=local 切回 Mac | |

---

## 日志与可观测性

| Option | Description | Selected |
|--------|-------------|----------|
| SSH stdout 即日志 | SSH 命令输出直接显示在 Jenkins console | ✓ |
| 拉取远程日志到 workspace | docker logs 重定向到 Jenkins workspace | |

---

## Claude's Discretion

- remote-ops.sh 的具体封装粒度和函数设计
- pipeline-stages.sh 中各函数的具体改造细节
- flock 锁的超时参数和清理逻辑
- SSH 连接参数
- Jenkins Credentials 的 ID 命名
- r4s 上 git pull 的错误处理
- 镜像 tag 备份的命名策略

## Deferred Ideas

None — discussion stayed within phase scope
