---
phase: 61-backup-network-migration
plan: 02
status: partial
created: 2026-05-19
---

# Plan 61-02: 验证 Cloudflare Tunnel + Nginx 端口映射

## 结果

| 验证项 | 状态 | 说明 |
|--------|------|------|
| Cloudflare Tunnel | ✅ 通过 | cloudflared 进程正常，class.noda.co.nz 返回 200 |
| Nginx 端口映射 | ✅ 通过 | 8080:80, 8081:81, 8443:443 全部生效 |
| Docker 内部 DNS | ✅ 通过 | nginx:81 返回页面内容 |
| Pre-prod 域名路由 | ⚠️ 未验证 | /etc/hosts 指向 127.0.0.1 而非 192.168.100.1 |
| Mac Tunnel 冲突 | ✅ 无冲突 | Mac 上无 noda-ops 容器运行 |

## 详细结果

### Cloudflare Tunnel (NET-01)
- cloudflared 进程 RUNNING，token 模式
- 外部域名验证: class.noda.co.nz → HTTP 200
- 无 Tunnel 竞争（Mac 上无 noda-ops 容器）

### Nginx 端口映射 (NET-02)
- 8080:80 ✅ (pre-prod HTTP)
- 8081:81 ✅ (prod HTTP，Tunnel 内部)
- 8443:443 ✅ (pre-prod HTTPS)

### Docker 内部 DNS
- nginx:81 返回 Noda 应用 HTML 页面
- noda-infra-nginx:81 同样可达

### Pre-prod 域名 (NET-03)
- /etc/hosts 当前: `127.0.0.1 class.noda.test auth.noda.test www.noda.test admin.noda.test`
- 需改为: `192.168.100.1 class.noda.test auth.noda.test www.noda.test admin.noda.test`
- 需要用户手动更新 /etc/hosts 后重新验证

## 后续行动

- [ ] 更新 /etc/hosts 将 pre-prod 域名指向 192.168.100.1
- [ ] 重新验证 `curl -k https://class.noda.test:8443/api/health`
