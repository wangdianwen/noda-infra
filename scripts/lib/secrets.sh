#!/bin/bash
set -euo pipefail

# ============================================
# 密钥加载库（Doppler Only）
# ============================================
# 功能：提供 load_secrets() 函数，从 Doppler API 拉取密钥
# 用途：被 pipeline-stages.sh、deploy-apps-prod.sh 等脚本 source 加载
# 模式：DOPPLER_TOKEN 存在 → doppler secrets download 拉取密钥（不落盘）
# 设计决策：per D-03 (Doppler only), D-04 (--no-file 不落盘), D-05 (config=$DOPPLER_CONFIG, 默认 prd)
# ============================================

# ============================================
# 函数: load_secrets
# ============================================
# Doppler-only 密钥加载：
#   - DOPPLER_TOKEN 非空时：从 Doppler API 拉取密钥注入 shell 环境
#   - DOPPLER_TOKEN 为空时：输出错误提示并 return 1
# 返回：0=成功，1=失败
# 环境变量：
#   DOPPLER_TOKEN - Doppler Service Token（必须设置）
load_secrets()
{
    # log 函数 fallback（调用者可能未 source log.sh）
    if ! declare -f log_info >/dev/null 2>&1; then
        log_info()    { echo "[INFO] $*"; }
        log_error()   { echo "[ERROR] $*" >&2; }
        log_success() { echo "[OK] $*"; }
        log_warn()    { echo "[WARN] $*"; }
    fi

    # 安全防护：从函数入口就禁用 bash trace（set -x），否则 Jenkins 的 sh 步骤
    # （以 bash -xe 运行）会在以下点泄露密钥：
    #   - [ -z "$DOPPLER_TOKEN" ] 检查打印 token 值
    #   - _secrets=$(doppler ...) 赋值打印所有密钥
    #   - eval "$_secrets" 展开打印每个 VAR="value"
    local _restore_trace=""
    if [[ $- == *x* ]]; then _restore_trace="set -x"; set +x; fi

    if [ -z "${DOPPLER_TOKEN:-}" ]; then
        $_restore_trace
        log_error "DOPPLER_TOKEN 未设置。请 export DOPPLER_TOKEN=<service-token> 后重试。"
        return 1
    fi

    # doppler 可能安装在 brew 路径下，Jenkins 的 PATH 可能找不到
    if [ -x /opt/homebrew/bin/doppler ]; then
        export PATH="/opt/homebrew/bin:$PATH"
    fi

    if ! command -v doppler >/dev/null 2>&1; then
        $_restore_trace
        log_error "DOPPLER_TOKEN 已设置但 doppler CLI 不可用"
        log_error "安装方式: brew install dopplerhq/cli/doppler"
        return 1
    fi

    # DOPPLER_CONFIG 环境变量控制加载哪个 config，默认 prd（向后兼容）
    local _config="${DOPPLER_CONFIG:-prd}"
    local _secrets

    _secrets=$(doppler secrets download --no-file --format=env --project noda --config "$_config" 2>/dev/null)

    if [ $? -ne 0 ]; then
        $_restore_trace
        log_error "Doppler 密钥拉取失败（检查 DOPPLER_TOKEN 是否有效）"
        return 1
    fi

    set -a
    eval "$_secrets"
    set +a

    # 恢复 trace 状态
    $_restore_trace

    log_success "密钥已从 Doppler 加载（project=noda, config=${_config:-unknown}）"
}

# ============================================
# 函数: restore_ssl_certs
# ============================================
# 从 Doppler 恢复 SSL 证书到磁盘
#   - r4s 远程模式（DEPLOY_TARGET=r4s）：通过 remote_exec 写入 r4s 的 config/nginx/ssl/
#   - 本地模式：直接写入本地 config/nginx/ssl/
# 用途：git reset --hard 会删除未跟踪的证书文件，部署 nginx 前需确保证书存在
# 前提：DOPPLER_TOKEN 已设置，NGINX_SSL_CERT_B64 / NGINX_SSL_KEY_B64 存在于 Doppler
# 返回：0=成功，1=失败
restore_ssl_certs()
{
    # log 函数 fallback
    if ! declare -f log_info >/dev/null 2>&1; then
        log_info()    { echo "[INFO] $*"; }
        log_error()   { echo "[ERROR] $*" >&2; }
        log_success() { echo "[OK] $*"; }
        log_warn()    { echo "[WARN] $*"; }
    fi

    # 安全防护：从函数入口就禁用 bash trace，避免 DOPPLER_TOKEN 检查
    # 和 doppler 下载内容打印到 Jenkins 日志
    local _restore_trace=""
    if [[ $- == *x* ]]; then _restore_trace="set -x"; set +x; fi

    if [ -z "${DOPPLER_TOKEN:-}" ]; then
        $_restore_trace
        log_error "DOPPLER_TOKEN 未设置，无法恢复 SSL 证书"
        return 1
    fi

    # doppler 可能安装在 brew 路径下
    if [ -x /opt/homebrew/bin/doppler ]; then
        export PATH="/opt/homebrew/bin:$PATH"
    fi

    local _config="${DOPPLER_CONFIG:-prd}"
    local _ssl_dir="$PROJECT_ROOT/config/nginx/ssl"

    $_restore_trace
    log_info "从 Doppler 恢复 SSL 证书..."
    # 重新禁用 trace 用于下载阶段
    _restore_trace=""
    if [[ $- == *x* ]]; then _restore_trace="set -x"; set +x; fi

    # 下载证书到本地临时文件并 base64 解码
    local _crt_tmp _key_tmp
    _crt_tmp=$(mktemp /tmp/noda-ssl-cert.XXXXXX.crt)
    _key_tmp=$(mktemp /tmp/noda-ssl-key.XXXXXX.key)

    # 确保临时文件在退出时被清理（防止密钥残留）
    _SSL_RESTORE_TMP_FILES=("$_crt_tmp" "$_key_tmp")
    _ssl_restore_cleanup() {
        rm -f "${_SSL_RESTORE_TMP_FILES[@]}" 2>/dev/null || true
    }
    trap '_ssl_restore_cleanup' EXIT

    # 从 Doppler 下载 base64 编码的证书并解码
    if ! doppler secrets get NGINX_SSL_CERT_B64 --project noda --config "$_config" --plain 2>/dev/null | base64 -d > "$_crt_tmp"; then
        $_restore_trace
        log_error "无法从 Doppler 获取 NGINX_SSL_CERT_B64"
        _ssl_restore_cleanup
        return 1
    fi

    if ! doppler secrets get NGINX_SSL_KEY_B64 --project noda --config "$_config" --plain 2>/dev/null | base64 -d > "$_key_tmp"; then
        $_restore_trace
        log_error "无法从 Doppler 获取 NGINX_SSL_KEY_B64"
        _ssl_restore_cleanup
        return 1
    fi

    # 校验解码后的文件非空
    if [ ! -s "$_crt_tmp" ] || [ ! -s "$_key_tmp" ]; then
        $_restore_trace
        log_error "SSL 证书解码后为空（检查 Doppler 中 NGINX_SSL_CERT_B64 / NGINX_SSL_KEY_B64）"
        _ssl_restore_cleanup
        return 1
    fi

    # 密钥内容已安全写入文件，恢复 trace 状态
    $_restore_trace

    if [ "${DEPLOY_TARGET:-}" = "r4s" ]; then
        # r4s 远程模式：通过 SSH 管道写入远程文件
        if ! declare -f remote_exec >/dev/null 2>&1; then
            log_error "remote_exec 不可用（未 source remote-ops.sh？）"
            _ssl_restore_cleanup
            return 1
        fi

        local _remote_ssl_dir="/opt/noda/noda-infra/config/nginx/ssl"
        log_info "写入 SSL 证书到 r4s: $_remote_ssl_dir"

        remote_exec "mkdir -p $_remote_ssl_dir"

        # 通过 stdin 管道传输文件（二进制安全，per D-22 模式）
        cat "$_crt_tmp" | remote_exec "cat > $_remote_ssl_dir/noda.dev.crt"
        if [ $? -ne 0 ]; then
            log_error "SSL 证书写入 r4s 失败"
            _ssl_restore_cleanup
            return 1
        fi

        cat "$_key_tmp" | remote_exec "cat > $_remote_ssl_dir/noda.dev.key && chmod 600 $_remote_ssl_dir/noda.dev.key"
        if [ $? -ne 0 ]; then
            log_error "SSL 私钥写入 r4s 失败"
            _ssl_restore_cleanup
            return 1
        fi
    else
        # 本地模式：直接写入本地 ssl 目录
        mkdir -p "$_ssl_dir"

        cp "$_crt_tmp" "$_ssl_dir/noda.dev.crt"
        cp "$_key_tmp" "$_ssl_dir/noda.dev.key"
        chmod 600 "$_ssl_dir/noda.dev.key"
    fi

    _ssl_restore_cleanup
    log_success "SSL 证书恢复完成"
}
