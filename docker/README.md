# docker/ — env 模板与镜像构建

## 新增环境密钥的三步流程（check-env-coverage 门禁会硬卡漏项）

代码里新读一个 `os.Getenv("X_TOKEN_SECRET")` 类键后，按序：

1. **Doppler 存值**（值源，双配置都要）：
   `doppler secrets set --project noda --config prd X_TOKEN_SECRET=<值>`
   `doppler secrets set --project noda --config prd_pre X_TOKEN_SECRET=<值>`
2. **env 模板加键名行**（本目录 `env-noda-api.env` 与 `env-noda-api-preprod.env`
   ——两文件 **gitignore**，含真实值不入库；本机仓库副本 + **所有 Jenkins
   工作区副本**都要加，工作区路径
   `~/.jenkins/noda-apps/ws-*/docker/env-noda-api.env`）：
   模板键名决定容器能否拿到值——"Doppler 全量注入"不成立，容器只认模板列出的键。
3. **preprod 白名单**（若键不在 `TOKEN_SECRET` 等既有前缀内）：`scripts/pipeline-stages.sh`
   中 prd_pre 下载后的 `grep -E '^(...)'` 过滤加前缀。

漏 2 → Jenkins check-env-coverage 门禁 FAILURE（"键代码在读、env 模板未定义"）。
历史踩坑：TELEGRAM_*（2026-10-03）、RENEWAL_TOKEN_SECRET（2026-10-04，两次）。

## 模板与 allowlist 的分工

- `env-noda-api.env` / `env-noda-api-preprod.env`：容器实际注入的键（含值）。
- `env-allowlist.txt`：代码在读但**有意不注入**的键（豁免对账），不是密钥通道。
