#!/bin/bash
# check-env-coverage.sh —— env 模板 ↔ 代码读取对账（构建期护栏）
#
# 背景（2026-09-16 三连实证）：ADMIN_ALLOWED_EMAILS / COMMENT_SERVICE_KEY 代码在读、
# 容器 env 模板漏配，全部到生产才暴露。本脚本在部署前对账：
#   代码里 os.Getenv/getenv/envBase 读取的键  ⊆  env 模板键 ∪ 豁免清单
#
# 用法: check-env-coverage.sh <noda-apps 检出路径>
#   模板/豁免清单取自本脚本所在仓库的 docker/ 目录。
# 退出码: 0=通过 1=有模板缺失（ENV_COVERAGE_STRICT=0 时降级为警告）
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODA_APPS="${1:-$SELF_DIR/noda-apps}"
STRICT="${ENV_COVERAGE_STRICT:-1}"

log_err() { printf '\033[0;31m❌ %s\033[0m\n' "$*"; }
log_warn() { printf '\033[1;33m⚠️  %s\033[0m\n' "$*"; }
log_ok() { printf '\033[0;32m✅ %s\033[0m\n' "$*"; }

if [ ! -d "$NODA_APPS" ]; then
    log_err "noda-apps 检出不存在: $NODA_APPS"
    exit 1
fi

# ── 1. 代码读取的键（排除测试文件；字面量 大写常量 才当 env 键）──
CODE_KEYS=$(grep -rhoE \
    '(os\.Getenv|[^.[:alnum:]]getenv|envBase)\("[A-Z][A-Z0-9_]+"' \
    --include='*.go' --exclude='*_test.go' \
    "$NODA_APPS"/api "$NODA_APPS"/admin "$NODA_APPS"/auth "$NODA_APPS"/class \
    "$NODA_APPS"/comment "$NODA_APPS"/common "$NODA_APPS"/liuyao \
    "$NODA_APPS"/nearby "$NODA_APPS"/snagme 2>/dev/null \
    | grep -oE '"[A-Z][A-Z0-9_]+"' | tr -d '"' | sort -u)

# ── 2. 模板定义的键（prod + preprod + Dockerfile ENV）──
TPL_KEYS=$(
    {
        grep -hE '^[A-Z][A-Z0-9_]+=' \
            "$SELF_DIR/docker/env-noda-api.env" \
            "$SELF_DIR/docker/env-noda-api-preprod.env" 2>/dev/null
        grep -hE '^ENV [A-Z][A-Z0-9_]+=' \
            "$SELF_DIR/docker/Dockerfile.noda-api" 2>/dev/null | \
            sed -E 's/^ENV ([A-Z][A-Z0-9_]+)=.*/\1/'
    } | cut -d= -f1 | sort -u)

# ── 3. 豁免清单（# 注释；三类：snagme.env 文件态配置 / 有代码默认值的可选旋钮 / 非容器消费方）──
ALLOW_FILE="$SELF_DIR/docker/env-allowlist.txt"
ALLOWED=""
[ -f "$ALLOW_FILE" ] && ALLOWED=$(grep -vE '^\s*#|^\s*$' "$ALLOW_FILE" | sort -u)

# ── 4. 对账：代码要读 ∧ 模板没有 ∧ 未豁免 = 缺失 ──
MISSING=$(comm -23 <(echo "$CODE_KEYS") <(echo -e "$TPL_KEYS\n$ALLOWED" | sort -u))
UNREAD=$(comm -13 <(echo "$CODE_KEYS") <(echo "$TPL_KEYS" | sort -u))

RC=0
if [ -n "$MISSING" ]; then
    log_err "以下键代码在读、env 模板未定义、且不在豁免清单（生产将得到空值）："
    echo "$MISSING" | sed 's/^/    - /'
    RC=1
fi
if [ -n "$UNREAD" ]; then
    log_warn "模板有定义但 Go 代码未直接读取（可能是 spawn 子进程/文档用，确认无碍可忽略）："
    echo "$UNREAD" | sed 's/^/    - /'
fi

if [ "$RC" -ne 0 ] && [ "$STRICT" != "1" ]; then
    log_warn "ENV_COVERAGE_STRICT=0：降级为警告，不阻断部署"
    exit 0
fi
if [ "$RC" -eq 0 ]; then
    log_ok "env 覆盖对账通过（代码读取 $(echo "$CODE_KEYS" | grep -c .) 键 / 模板定义 $(echo "$TPL_KEYS" | grep -c .) 键 / 豁免 $(echo "$ALLOWED" | grep -c .) 键）"
fi
exit "$RC"
