# Requirements: v1.9 部署后磁盘清理自动化

**Defined:** 2026-04-19
**Core Value:** 数据库永不丢失。清理操作不得影响持久化数据卷和备份系统。

## v1 Requirements

### A. Docker 清理增强 (DOCK)

- [ ] **DOCK-01**: Pipeline 部署成功后自动清理 Docker build cache（`docker buildx prune --filter until=24h`），保留 24h 内的热缓存
- [ ] **DOCK-02**: Pipeline 部署成功后自动清理已停止的容器（`docker container prune -f`）
- [ ] **DOCK-03**: Pipeline 部署成功后自动清理未使用的匿名卷（`docker volume prune -f`，不含 `--all`，保护命名卷如 postgres_data）
- [ ] **DOCK-04**: Pipeline 部署前后记录磁盘用量对比（`df -h` + `docker system df`），输出到日志

### B. 构建缓存清理 (CACHE)

- [ ] **CACHE-01**: Jenkins workspace 中 findclass-ssr/noda-site 的 `node_modules` 在部署成功后清理
- [ ] **CACHE-02**: pnpm store 定期 prune（每 7 天一次，非每次部署），可通过参数强制触发
- [ ] **CACHE-03**: npm cache 定期清理（`npm cache clean --force`），与 pnpm store prune 同频率

### C. 旧文件清理 (FILE)

- [ ] **FILE-01**: 清理 `infra-pipeline/` 目录下超过 N 天的旧备份文件（可配置保留天数，默认 30 天）
- [ ] **FILE-02**: Pipeline 结束后清理 `deploy-failure-*.log` 临时日志文件

### D. Jenkins Pipeline 清理 (JENK)

- [ ] **JENK-01**: 清理 Jenkins 已完成的旧 Pipeline 构建（保留最近 N 次构建记录，删除更早的 artifacts 和构建目录）
- [ ] **JENK-02**: 清理 Jenkins workspace 中已完成构建的工作目录（释放磁盘空间）

## Future Requirements

### 高级清理

- **DOCK-F01**: `docker system prune -a --volumes` 全量清理（风险高，需人工确认）
- **CACHE-F01**: 构建产物 `dist/` 清理策略
- **MON-F01**: 磁盘用量超过阈值时发送告警（邮件/webhook）

## Out of Scope

| Feature | Reason |
|---------|--------|
| `docker system prune -a` 全量清理 | 会删除所有未使用镜像（含回滚镜像），风险过高 |
| `docker volume prune --all` | 会删除命名卷，威胁 postgres_data 等持久化数据 |
| Jenkins 构建历史清理 | 改为 JENK-01 纳入 v1.9 范围 |
| 备份系统文件清理 | 备份系统是核心价值保障，必须保持独立 |
| 删除正在运行的容器 | 安全底线，只清理已停止的容器 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| DOCK-01 | Phase 43 | Pending |
| DOCK-02 | Phase 43 | Pending |
| DOCK-03 | Phase 43 | Pending |
| DOCK-04 | Phase 43 | Pending |
| CACHE-01 | Phase 43 | Pending |
| CACHE-02 | Phase 44 | Pending |
| CACHE-03 | Phase 44 | Pending |
| FILE-01 | Phase 43 | Pending |
| FILE-02 | Phase 43 | Pending |
| JENK-01 | Phase 44 | Pending |
| JENK-02 | Phase 44 | Pending |

**Coverage:**
- v1 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0

---
*Requirements defined: 2026-04-19*
*Last updated: 2026-04-19 -- v1.9 roadmap created, traceability updated*
