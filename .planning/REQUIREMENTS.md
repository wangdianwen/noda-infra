# Requirements: Noda v1.4 CI/CD 零停机部署

**Defined:** 2026-04-14
**Core Value:** Jenkins + 蓝绿部署实现编译失败不 down 站，自动回滚保护

## v1.4 Requirements

### Jenkins 基础设施

- [ ] **JENK-01**: 管理员可以通过 `setup-jenkins.sh install` 在宿主机原生安装 Jenkins LTS
- [ ] **JENK-02**: 管理员可以通过 `setup-jenkins.sh uninstall` 完全卸载 Jenkins 及其残留文件
- [ ] **JENK-03**: Jenkins 用户自动加入 docker 组，可直接操作 Docker daemon
- [ ] **JENK-04**: Jenkins 安装后首次启动可获取初始管理员密码

### Pipeline 核心

- [ ] **PIPE-01**: Pipeline 按 Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → Cleanup 八阶段执行
- [ ] **PIPE-02**: 每次构建的镜像使用 Git SHA 短哈希标签（如 `findclass-ssr:abc1234`），替代 latest
- [ ] **PIPE-03**: 构建阶段失败时自动中止 Pipeline，不进入部署阶段
- [ ] **PIPE-04**: Pipeline 通过手动触发执行，不支持自动触发
- [ ] **PIPE-05**: 部署失败时自动归档构建日志和容器日志到 Jenkins

### 蓝绿部署

- [ ] **BLUE-01**: 同一时刻存在 blue 和 green 两个 findclass-ssr 容器实例，活跃容器对外服务，目标容器等待验证
- [ ] **BLUE-02**: nginx 通过 upstream include 文件指向活跃容器，Pipeline 切换时更新文件并 `nginx -s reload`
- [ ] **BLUE-03**: 活跃环境状态通过 `/opt/noda/active-env` 文件持久化追踪（内容为 `blue` 或 `green`）
- [ ] **BLUE-04**: 蓝绿容器通过 `docker run` 独立管理生命周期，不通过 docker-compose.yml 管理
- [ ] **BLUE-05**: 蓝绿容器均在 `noda-network` Docker 网络上，nginx 通过容器名 DNS 解析访问

### 测试与质量门禁

- [ ] **TEST-01**: Pipeline Test 阶段执行 `pnpm lint`，lint 不通过则中止部署
- [ ] **TEST-02**: Pipeline Test 阶段执行 `pnpm test`，单元测试不通过则中止部署
- [ ] **TEST-03**: 部署后对目标容器执行 HTTP 健康检查（直接 curl 容器内部端点），最多重试 10 次每次间隔 5 秒
- [ ] **TEST-04**: 流量切换后通过 nginx 执行 E2E 验证（curl 外部可达性），确认完整请求链路正常
- [ ] **TEST-05**: 健康检查或 E2E 验证失败时，不切换流量、不停止旧容器，自动回滚到当前活跃环境

### 增强特性

- [ ] **ENH-01**: Pipeline Pre-flight 阶段检查数据库备份是否在 12 小时内，不满足则阻止部署
- [ ] **ENH-02**: 部署成功后自动调用 Cloudflare API 清除 CDN 缓存（index.html 和静态资源）
- [ ] **ENH-03**: Pipeline Cleanup 阶段自动清理超过 7 天的旧 Docker 镜像，防止磁盘空间耗尽
- [ ] **ENH-04**: 现有部署脚本（deploy-infrastructure-prod.sh、deploy-apps-prod.sh）保留为手动回退方案

## Future Requirements

### v1.4.x

- **NOTIF-01**: 部署成功/失败时发送通知（邮件/Slack/Discord webhook）
- **PARAM-01**: 支持参数化构建（指定 BUILD_ID 或分支名）
- **NOTIF-02**: 浏览器级 E2E 测试（Playwright/Cypress 模拟用户完整流程）

### v2+

- 多环境 Pipeline（dev/staging/prod 自动化）
- Pipeline as Code（Jenkinsfile 放入 noda-apps 仓库）
- 基础设施服务蓝绿部署（PostgreSQL/Keycloak 有状态，复杂度远高于无状态应用）

## Out of Scope

| Feature | Reason |
|---------|--------|
| Jenkins 容器化部署 | Docker-in-Docker 安全风险大，宿主机直接操作 Docker 最简单 |
| 自动 Git push/webhook 触发 | 单服务器生产环境，手动触发更安全 |
| Kubernetes 编排 | 7 个容器不需要 K8s 的复杂度 |
| Canary 金丝雀部署 | 单服务器无法分流百分比流量，蓝绿已提供安全保障 |
| Docker Registry 镜像仓库 | 单服务器本地镜像足够，自建 registry 增加维护负担 |
| 外部 KV 存储（Consul/etcd） | 只为存一个 active_color 状态是过度设计，文件足够 |
| 多节点 Agent 分布式构建 | 只有一台服务器，无性能收益 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| JENK-01 | Phase 19 | Pending |
| JENK-02 | Phase 19 | Pending |
| JENK-03 | Phase 19 | Pending |
| JENK-04 | Phase 19 | Pending |
| BLUE-02 | Phase 20 | Pending |
| BLUE-01 | Phase 21 | Pending |
| BLUE-03 | Phase 21 | Pending |
| BLUE-04 | Phase 21 | Pending |
| BLUE-05 | Phase 21 | Pending |
| PIPE-02 | Phase 22 | Pending |
| PIPE-03 | Phase 22 | Pending |
| TEST-03 | Phase 22 | Pending |
| TEST-04 | Phase 22 | Pending |
| TEST-05 | Phase 22 | Pending |
| PIPE-01 | Phase 23 | Pending |
| PIPE-04 | Phase 23 | Pending |
| PIPE-05 | Phase 23 | Pending |
| TEST-01 | Phase 23 | Pending |
| TEST-02 | Phase 23 | Pending |
| ENH-01 | Phase 24 | Pending |
| ENH-02 | Phase 24 | Pending |
| ENH-03 | Phase 24 | Pending |
| ENH-04 | Phase 25 | Pending |

**Coverage:**
- v1.4 requirements: 23 total
- Mapped to phases: 23
- Unmapped: 0

---
*Requirements defined: 2026-04-14*
*Last updated: 2026-04-14 after roadmap creation*
