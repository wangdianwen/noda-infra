#!/usr/bin/env bash
# Doppler 密钥离线备份脚本
# 用途：从 Doppler 下载密钥 → age 加密 → 上传到 Backblaze B2
# 使用：DOPPLER_TOKEN='dp.st.prd.xxx' bash scripts/backup/backup-doppler-secrets.sh [--dry-run] [--project noda] [--config prd]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 默认参数
DRY_RUN=false
PROJECT="noda"
CONFIG="prd"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --project)  PROJECT="$2"; shift 2 ;;
        --config)   CONFIG="$2"; shift 2 ;;
        -h|--help)
            echo "用法: bash scripts/backup/backup-doppler-secrets.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --dry-run        仅下载和加密，不上传 B2"
            echo "  --project NAME   Doppler 项目名（默认: noda）"
            echo "  --config NAME    Doppler 环境名（默认: prd）"
            echo "  -h, --help       显示帮助"
            exit 0
            ;;
        *) error "未知参数: $1"; exit 1 ;;
    esac
done

# 检查 DOPPLER_TOKEN
if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
    error "DOPPLER_TOKEN 环境变量未设置"
    error "使用方法: export DOPPLER_TOKEN='dp.st.prd.xxx'"
    exit 1
fi

# 检查依赖
for cmd in doppler age; do
    if ! command -v "$cmd" &>/dev/null; then
        error "缺少依赖: $cmd"
        exit 1
    fi
done

if [[ "$DRY_RUN" == "false" ]]; then
    if ! command -v rclone &>/dev/null; then
        error "缺少依赖: rclone（非 dry-run 模式需要）"
        exit 1
    fi
fi

# Doppler 备份加密公钥（age 公钥，可安全公开）
AGE_PUBLIC_KEY="${AGE_PUBLIC_KEY:-age1869smm93r878hzgarhv5uggkg58mttaz54l05wwc0s3zmp264e7qw7rc3w}"

if [[ -z "$AGE_PUBLIC_KEY" ]]; then
    error "AGE_PUBLIC_KEY 未设置"
    error "使用方法: export AGE_PUBLIC_KEY='age1xxx...'"
    exit 1
fi

# 生成输出文件名
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="/tmp/doppler-backup-${TIMESTAMP}.env.age"

info "开始 Doppler 密钥备份..."
info "项目: $PROJECT | 环境: $CONFIG | 模式: $([ "$DRY_RUN" = true ] && echo 'dry-run' || echo '生产')"

# 下载密钥并通过管道加密（明文不落盘）
info "下载密钥并加密..."
if doppler secrets download --format=env --no-file --project "$PROJECT" --config "$CONFIG" \
    | age -r "$AGE_PUBLIC_KEY" -o "$OUTPUT_FILE"; then
    info "密钥已加密保存到: $OUTPUT_FILE"
else
    error "密钥下载或加密失败"
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# 验证加密文件
if [[ ! -s "$OUTPUT_FILE" ]]; then
    error "加密文件为空或不存在: $OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
    exit 1
fi
FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
info "加密文件大小: ${FILE_SIZE} bytes"

# B2 云存储配置（从环境变量或 docker-compose 注入）
B2_BUCKET="${B2_BUCKET_NAME:-noda-backups}"
B2_REMOTE_PATH="doppler-backup/doppler-backup-${TIMESTAMP}.env.age"

# 上传到 B2
if [[ "$DRY_RUN" == "false" ]]; then
    info "上传到 Backblaze B2..."
    info "Bucket: $B2_BUCKET | 路径: $B2_REMOTE_PATH"

    # 容器内使用 entrypoint-ops.sh 配置的 rclone，本地使用临时配置
    local_rclone_config=""
    if [[ -z "${RCLONE_CONFIG:-}" ]] || [[ ! -f "${RCLONE_CONFIG:-}" ]]; then
        if [[ -z "${B2_ACCOUNT_ID:-}" ]] || [[ -z "${B2_APPLICATION_KEY:-}" ]]; then
            error "B2_ACCOUNT_ID 和 B2_APPLICATION_KEY 环境变量未设置"
            exit 1
        fi
        local_rclone_config=$(mktemp)
        chmod 600 "$local_rclone_config"
        cat >"$local_rclone_config" <<EOF
[b2remote]
type = b2
account = $B2_ACCOUNT_ID
key = $B2_APPLICATION_KEY
EOF
    fi

    RCLONE_FLAGS=("--log-level" "INFO")
    if [[ -n "$local_rclone_config" ]]; then
        RCLONE_FLAGS+=("--config" "$local_rclone_config")
    fi

    if rclone copy "$OUTPUT_FILE" "b2remote:${B2_BUCKET}/doppler-backup/" \
        "${RCLONE_FLAGS[@]}"; then
        info "上传成功"
    else
        error "rclone 上传失败"
        rm -f "$local_rclone_config"
        warn "加密文件仍保留在本地: $OUTPUT_FILE"
        exit 1
    fi

    rm -f "$local_rclone_config"
else
    info "[dry-run] 跳过 B2 上传"
    info "[dry-run] 加密文件保留在: $OUTPUT_FILE"
fi

# 清理临时文件（仅在生产模式下上传成功后清理）
if [[ "$DRY_RUN" == "false" ]]; then
    rm -f "$OUTPUT_FILE"
    info "临时文件已清理"
fi

echo ""
info "备份完成"
echo "  项目: $PROJECT"
echo "  环境: $CONFIG"
echo "  模式: $([ "$DRY_RUN" = true ] && echo 'dry-run（未上传 B2）' || echo '已上传 B2')"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
