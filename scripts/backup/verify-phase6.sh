#!/bin/bash
# Phase 6 验证脚本 - 修复变量冲突（纯验证，不修改代码）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
FAILED=0
WARNINGS=0

echo "=========================================="
echo "Phase 6 验证：修复变量冲突（只读检查）"
echo "=========================================="
echo ""

# 检查 1: constants.sh 存在且定义了所有退出码（per D-04）
echo -n "检查 1: constants.sh 存在并定义退出码... "
if [[ -f "$LIB_DIR/constants.sh" ]] && grep -q '^readonly EXIT_SUCCESS=0' "$LIB_DIR/constants.sh"; then
  echo "通过"
else
  echo "失败"
  FAILED=$((FAILED + 1))
fi

# 检查 2: 无重复 EXIT_* 定义（constants.sh 除外）（per D-05, D-09）
echo -n "检查 2: 无重复 readonly EXIT_* 定义... "
DUPES=$(grep -rn '^readonly EXIT_' "$LIB_DIR"/*.sh 2>/dev/null | grep -v constants.sh || true)
if [[ -z "$DUPES" ]]; then
  echo "通过"
else
  echo "失败"
  echo "  发现重复定义: $DUPES"
  FAILED=$((FAILED + 1))
fi

# 检查 3: 所有使用 EXIT_* 的库文件有条件加载或主脚本加载 constants.sh（per D-08）
echo -n "检查 3: 所有 EXIT_* 使用者有防御性加载... "
MISSING_GUARD=0
for file in db.sh verify.sh cloud.sh health.sh test-verify.sh alert.sh metrics.sh restore.sh; do
  if [[ -f "$LIB_DIR/$file" ]]; then
    if grep -q 'return \$EXIT_\|exit \$EXIT_\|exit \$EXIT_' "$LIB_DIR/$file" 2>/dev/null; then
      if ! grep -q 'EXIT_SUCCESS+x\|source.*constants.sh' "$LIB_DIR/$file"; then
        echo "失败"
        echo "  $file 使用 EXIT_* 但无显式加载 constants.sh（依赖主脚本加载）"
        MISSING_GUARD=$((MISSING_GUARD + 1))
      fi
    fi
  fi
done
if [[ $MISSING_GUARD -eq 0 ]]; then
  echo "通过"
else
  # 这是 WARNING 而非 FAILURE：隐式依赖在当前加载顺序下可以工作
  echo "  [WARNING] $MISSING_GUARD 个文件使用 EXIT_* 但依赖主脚本隐式加载"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查 4: 所有库文件使用 _*_LIB_DIR 前缀（无裸 LIB_DIR）（per D-06）
echo -n "检查 4: 无裸 LIB_DIR 变量名... "
BARE_LIB_DIR=$(grep -rn '^\(LIB_DIR=\|readonly LIB_DIR\)' "$LIB_DIR"/*.sh 2>/dev/null || true)
if [[ -z "$BARE_LIB_DIR" ]]; then
  echo "通过"
else
  echo "警告"
  echo "  发现裸 LIB_DIR: $BARE_LIB_DIR"
  echo "  [WARNING] alert.sh 和 metrics.sh 使用裸 LIB_DIR，其他库使用 _*_LIB_DIR 前缀"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查 5: 无 .bak 残留文件
echo -n "检查 5: 无 .bak 残留文件... "
BAK_FILES=$(find "$LIB_DIR" -name '*.bak' -o -name '*.bak2' 2>/dev/null || true)
if [[ -z "$BAK_FILES" ]]; then
  echo "通过"
else
  echo "警告"
  echo "  发现残留文件: $BAK_FILES"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查 6: 所有库文件语法检查通过
echo -n "检查 6: 所有库文件语法检查... "
SYNTAX_FAILED=0
for file in "$LIB_DIR"/*.sh; do
  if ! bash -n "$file" 2>/dev/null; then
    echo "失败"
    echo "  语法错误: $file"
    SYNTAX_FAILED=$((SYNTAX_FAILED + 1))
  fi
done
if [[ $SYNTAX_FAILED -eq 0 ]]; then
  echo "通过"
else
  FAILED=$((FAILED + 1))
fi

# 检查 7: 主脚本语法检查通过
echo -n "检查 7: 主脚本语法检查... "
if bash -n "$SCRIPT_DIR/backup-postgres.sh" 2>/dev/null; then
  echo "通过"
else
  echo "失败"
  FAILED=$((FAILED + 1))
fi

# 检查 8: 主脚本正确加载 constants.sh（per D-07）
echo -n "检查 8: 主脚本加载 constants.sh... "
if grep -q 'source.*constants.sh' "$SCRIPT_DIR/backup-postgres.sh" 2>/dev/null; then
  echo "通过"
else
  echo "失败"
  FAILED=$((FAILED + 1))
fi

# 汇总
echo ""
echo "=========================================="
if [[ $FAILED -eq 0 && $WARNINGS -eq 0 ]]; then
  echo "所有检查通过（0 failed, 0 warnings）"
  echo "=========================================="
  exit 0
elif [[ $FAILED -eq 0 ]]; then
  echo "核心检查通过，$WARNINGS 项警告（非阻塞）"
  echo "=========================================="
  echo ""
  echo "警告项目可通过 06-02 可选修复计划解决"
  exit 0
else
  echo "$FAILED 项检查失败, $WARNINGS 项警告"
  echo "=========================================="
  exit 1
fi
