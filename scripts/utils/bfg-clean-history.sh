#!/usr/bin/env bash
# Git 历史敏感文件清理脚本
# 使用 git-filter-repo 替代 BFG Repo Cleaner（无需 Java）
# 用途：从 Git 历史中彻底删除敏感文件
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 目标文件列表（per D-04, D-07）
TARGET_FILES=(
    ".env.production"
    ".sops.yaml"
    "config/secrets.sops.yaml"
)

echo "=========================================="
echo "Git 历史敏感文件清理"
echo "=========================================="
echo ""
echo "将清除以下文件的完整历史:"
for f in "${TARGET_FILES[@]}"; do
    count=$(git log --all --oneline -- "$f" 2>/dev/null | wc -l | tr -d ' ')
    echo "  - $f ($count 次提交)"
done
echo ""
echo "注意: docker/.env 从未被 git 追踪，无需清理 (per D-07)"
echo ""
warn "此操作将重写 Git 历史，不可逆！"
warn "所有 commit hash 将会改变。"
echo ""

# 步骤 1: 确认
read -p "确认继续？(输入 yes 继续): " confirm
[[ "$confirm" != "yes" ]] && echo "已取消" && exit 0

# 步骤 2: 检查 git-filter-repo
if ! command -v git-filter-repo &>/dev/null; then
    error "git-filter-repo 未安装"
    error "安装: brew install git-filter-repo"
    exit 1
fi

# 步骤 3: 检查未提交的更改
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    error "存在未提交的更改，请先提交或暂存"
    git status --short
    exit 1
fi

# 步骤 4: 执行清理（per D-05）
info "执行 git-filter-repo 清理..."
git filter-repo \
    --path .env.production \
    --path .sops.yaml \
    --path config/secrets.sops.yaml \
    --invert-paths \
    --force

# 步骤 5: 验证（per D-06）
echo ""
info "=== 验证结果 ==="
all_clean=true
for f in "${TARGET_FILES[@]}"; do
    result=$(git log --all --oneline -- "$f" 2>/dev/null || true)
    if [[ -z "$result" ]]; then
        echo "  [OK] $f 已从历史中清除"
    else
        echo "  [FAIL] $f 仍存在于历史中:"
        echo "$result"
        all_clean=false
    fi
done

# 步骤 6: 生成验证报告
REPORT_FILE="git-history-cleanup-report.txt"
echo "Git 历史清理验证报告" > "$REPORT_FILE"
echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
echo "清理文件: ${TARGET_FILES[*]}" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
for f in "${TARGET_FILES[@]}"; do
    result=$(git log --all --oneline -- "$f" 2>/dev/null || true)
    if [[ -z "$result" ]]; then
        echo "[OK] $f 已清除" >> "$REPORT_FILE"
    else
        echo "[FAIL] $f 未清除" >> "$REPORT_FILE"
    fi
done

if [[ "$all_clean" == true ]]; then
    echo ""
    info "验证通过！所有敏感文件已从历史中清除。"
    info "验证报告: $REPORT_FILE"
    echo ""
    warn "下一步需要手动执行 force push 更新远端:"
    echo "  git push --force --mirror origin"
    echo ""
    echo "注意: 如果在其他机器上有此仓库的克隆，需要重新克隆。"
else
    echo ""
    error "验证失败，部分文件未清除。请检查报告: $REPORT_FILE"
    exit 1
fi
