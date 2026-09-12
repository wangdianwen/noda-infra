# 任务状态：r4s 内存优化至 40% —— ✅ 已达标（2026-09-06 01:00）

## 最终结果
- **整机 used 1544MB / 3863MB = 39.97%**（起点 54% / 1.98GB）
- 容器明细：apps 326M（原 358-385）· keycloak 421M · ops 45M（爬虫窗口 +80M）· postgres 36M · nginx 12M · remark42 15M
- 全部 6 容器 healthy；五站点冒烟全通过（class/www/auth/liuyao/keycloak OIDC）

## 各批次完成情况
- [x] Phase 1（09-05）: Keycloak JVM 调参（-Xmx256m 等，env-keycloak.env）
- [x] 批次 3（09-06）: hermes 清理 + procd 重新接管（-313MB）
- [x] 批次 1（09-06）: noda-apps 进程收敛 9→7（commit 8f3bf0fe，Jenkins #240 部署）
  - api-mono 单进程承载 class-api:3001 + liuyao-api:3007 + email:3010
  - admin/server tsc 预编译替代 tsx（省 wrapper+esbuild 双进程）
  - 各进程 NODE_OPTIONS=--max-old-space-size 封顶（mono 320/class 256/其余 192）
- [x] 批次 2（09-06）: healthcheck 抗抖动（commit 90bf3fd + 461a6dd，infra-deploy #49/#51）
  - postgres/noda-ops 检查加 -t 5、放宽 interval/retries，已 recreate 生效
  - 顺带修复 r4s 备份路径双重拼接 bug（#50 复现：backup_file 已含文件名再拼一次）
- [ ] 批次 4（未启用，备用）: www 静态化移交 nginx（-30~50MB，余量不足时执行）
- [ ] keycloak 门控（未启用，备用）: -Xmx192m + MaxMetaspace 128m + limit 640（-70~90MB）

## 余量提示
39.97% 贴线达标。爬虫窗口 noda-ops 会 +80M（→ ~41-42% 峰值）；apps 长时间预热
可能再涨 ~30M。若要舒适余量：执行批次 4 或 keycloak 门控项（二选一即到 ~38%）。

## hermes 防复发规范（重要）
- gateway 生命周期一律走 `/etc/init.d/hermes {start|stop|restart}`，**禁止** SSH 内手动 `hermes gateway [restart|run]`（09-04 脱管根因）
- 裸 `hermes` 交互会话用完即退
- 验证受管：`ubus call service list` 中 hermes `running:true` 且 pid == gateway.pid
- 孤儿存活时**不能**只跑 init.d restart（procd stop 不追踪孤儿，start 被 gateway.lock 顶掉）——先 kill 孤儿再 start

## prod 登录事故（09-06，已修复）
- 现象：www 登录跳 Keycloak 报 "Client not found"（client_id=noda-www）；preprod 正常
- 根因：SSO 重构（e51a7671/e86fb23e）让 www 用 noda-www client，但该 client 只建在
  preprod 的 Keycloak（docker/keycloak-realm.json），**prod realm 是独立实例+独立 DB，从没有它**。
  另发现 noda-frontend/noda-auth 的 webOrigins="+" 配 redirectUris="*"，token 端点无 CORS 头，
  浏览器兑换 code 失败（587c1c9 在 preprod 修过，prod 漏修）
- 修复（kc admin API 直改 prod realm，即时生效无需重启）：
  1. 新建 noda-www（redirect https://noda.co.nz/* + localhost:3000）
  2. noda-frontend webOrigins → 显式 [class, localhost:3006, admin, admin-preprod]
  3. noda-auth webOrigins → 显式 [auth, localhost:3004]
- 验证：授权端点四 client 全 200/Sign in；token 端点 CORS 三 origin 全部返回 ACAO 头
- 防复发：services/keycloak/realm/noda-realm.json 已同步为 prod 实际配置快照（5430c60）；
  **prod realm 与 preprod realm 是两份独立配置，改 client 必须两边都改**（preprod=Mac 容器
  走 realm json 导入；prod=r4s DB，用 kc admin API 或 admin console 改）

## Keycloak 登录页 CSS 全丢事故（09-06，已修复）
- 现象：auth.noda.co.nz 的 Keycloak 登录页（noda 自定义主题）完全无样式
- 根因：**keycloak 26.2.3 对带 `Accept-Encoding: gzip` 的 /resources/* 请求返回 404**
  （主题资源压缩变体 bug；deflate/br/zstd/identity 均正常）。浏览器默认带 gzip →
  登录页 CSS/JS 全 404；排查时 curl 不带 AE 所以直连一直 200，nginx 日志里
  隧道请求（172.18.0.3）404 vs 本地请求（172.18.0.1）200 才定位到
- 修复：nginx auth 块新增 `location /resources/` 剥掉 Accept-Encoding（5229482，
  infra-deploy #52），keycloak 返回明文。prod 与 auth.noda.test 两块同步
- 排查方法论：逐层状态码（容器内 200 → nginx 200 → 公网 404）+ 头二分
- 遗留：keycloak 升级时留意此 bug 是否修复，届时可撤掉 nginx 的 AE 剥离

## www 登录态建不起来事故（09-06，已修复——CSP/XFO 拦死 keycloak-js 探测 iframe）
- 现象：Keycloak 认证成功、带 code 回跳 noda.co.nz/auth/callback，但首页仍显示登录按钮
- 根因（nginx 日志对比 + 浏览器复现 + 头二分）：
  1. nginx auth 块 CSP frame-ancestors 列表**漏了 https://noda.co.nz**（preprod 各站都在）
  2. security-headers.conf 的 **X-Frame-Options: SAMEORIGIN** 与 CSP 并存时浏览器以 XFO 为准
  → www 挂的 keycloak-js 3p-cookies 探测 iframe 被 CSP/XFO 拦死，探测结果永远回不来 →
  init 挂到 8s watchdog → **兑换 code 之前就被掐死**（token 请求从未发出）→ 弹回首页未登录态
- 修复（b8404dd，infra-deploy #54）：
  - auth 块不再 include security-headers.conf（XFO 与 CSP 冲突），改内联安全头、不发 XFO，
    帧策略只由 frame-ancestors allowlist 管控（已补 noda.co.nz）
  - proxy_hide_header 掉 keycloak 内置 XFO/CSP（realm securityDefenses 未配置时的默认值）
- 验证：E2E 测试账号（已删）真实走完 登录→回跳→兑换→页头头像 全链路 ✓；
  silent check-sso 恢复后 SSO 静默续登也正常 ✓
- 附带启用：prod realm 登录事件日志（eventsEnabled，24h 过期），后续登录问题可查
  GET /admin/realms/noda/events（kc admin API）
- 排查方法论：token 端点 CORS/gzip 都正常后，用浏览器 performance entries 看"兑换请求
  是否发出"——没发出就不是端点问题，而是前置的 iframe 探测被拦

## www 登录态显示说明（非 bug）
SSO 重构后的设计：各站用自己 client 独立建立会话，www 靠 keycloak-js（noda-www）
跨站 iframe 静默探测被三方 cookie 拦截，**看不到 auth 应用的会话**。
www 页头显示登录态的前提是用户在 www 上完整走一次 noda-www 登录流。
Keycloak 登录页修好后再登录一次即显示；若仍不显示再查 /auth/callback 兑换。

## 关键教训（累计）
- JAVA_OPTS_APPEND 追加在 kc.sh 默认参数之后：不能与默认 -XX:+UseG1GC 重复指定另一个 GC
- keycloak 配置变更后首次启动触发 re-augmentation，慢 3 分钟以上，靠 start-period 900s 保护
- wait_container_healthy 对 unhealthy 立即判死（无重试）
- 生产容器操作只能走 Jenkins；Jenkins input 表单审批 curl 提交始终 400（"expects a form submission"），
  用浏览器 UI 点击可行（浏览器自动化）
- docker stats RSS 重复计数共享页（9 node RSS 求和 856MB vs cgroup 316MB）——账本用 free used + cgroup 口径
- pg-pool end() 双调 reject（"Called end on pool more than once"）——多服务共享 pool 的进程合并
  必须统一由入口 disconnect 一次（api-mono 的 disconnectOnClose 设计）
- postgres 自定义 conf 从未生效（官方镜像不读 /etc/postgresql/ 且无 config_file 指定）——
  "shared_buffers 256→128 省 30MB" 是伪收益
