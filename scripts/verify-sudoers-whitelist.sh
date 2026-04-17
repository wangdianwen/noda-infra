#!/bin/bash
set -euo pipefail

# ============================================
# Phase 32: sudoers 白名单独立验证脚本
# ============================================
# 功能：验证 sudoers 白名单规则是否正确工作
# 输出：逐项 PASS/FAIL 结果
# 退出码：全部 PASS 返回 0，任何 FAIL 返回 1
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SUDOERS_FILE="/etc/sudoers.d/noda-docker-readonly"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 平台检测
# ============================================
detect_platform() {
    local os
    os="$(uname)"
    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

PLATFORM="$(detect_platform)"

# ============================================
# 验证结果追踪
# ============================================
PASS_COUNT=0
FAIL_COUNT=0

check_pass() {
    local name="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "  ${_GREEN}PASS${_NC}  $name"
}

check_fail() {
    local name="$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "  ${_RED}FAIL${_NC}  $name"
}

# ============================================
# 验证逻辑
# ============================================
main() {
    log_info "Phase 32: 验证 sudoers 白名单规则 (平台: $PLATFORM)"
    echo ""

    # macOS 跳过
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 跳过（Docker Desktop 无 sudoers 需求）"
        exit 0
    fi

    echo "检查项                                         结果"
    echo "─────────────────────────────────────────────────────"

    # 1. sudoers 文件存在
    if [ -f "$SUDOERS_FILE" ]; then
        check_pass "sudoers 文件存在 ($SUDOERS_FILE)"
    else
        check_fail "sudoers 文件存在 ($SUDOERS_FILE)"
    fi

    # 如果文件不存在，后续检查无法进行
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo ""
        log_error "sudoers 文件不存在，跳过后续检查"
        exit 1
    fi

    # 2. sudoers 语法正确
    if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        check_pass "sudoers 语法正确 (visudo -cf)"
    else
        check_fail "sudoers 语法正确 (visudo -cf)"
    fi

    # 3-7. 白名单包含 5 个只读命令
    local read_only_cmds=("docker ps" "docker logs" "docker inspect" "docker stats" "docker top")
    for cmd in "${read_only_cmds[@]}"; do
        if grep -qF "$cmd" "$SUDOERS_FILE"; then
            check_pass "白名单包含: $cmd"
        else
            check_fail "白名单包含: $cmd"
        fi
    done

    # 8. 黑名单包含 docker exec (D-04)
    if grep -qF "docker exec" "$SUDOERS_FILE"; then
        check_pass "黑名单包含: docker exec (D-04)"
    else
        check_fail "黑名单包含: docker exec (D-04)"
    fi

    # 9. 黑名单包含 docker run
    if grep -qF "docker run" "$SUDOERS_FILE"; then
        check_pass "黑名单包含: docker run"
    else
        check_fail "黑名单包含: docker run"
    fi

    # 10. 黑名单包含 docker rm
    if grep -qF "docker rm" "$SUDOERS_FILE"; then
        check_pass "黑名单包含: docker rm"
    else
        check_fail "黑名单包含: docker rm"
    fi

    # 11. 黑名单包含 docker compose
    if grep -qF "docker compose" "$SUDOERS_FILE"; then
        check_pass "黑名单包含: docker compose"
    else
        check_fail "黑名单包含: docker compose"
    fi

    # 12. 文件权限正确 (0440 root:root)
    local perms owner group
    perms="$(stat -c '%a' "$SUDOERS_FILE")"
    owner="$(stat -c '%U' "$SUDOERS_FILE")"
    group="$(stat -c '%G' "$SUDOERS_FILE")"

    if [[ "$perms" == "440" && "$owner" == "root" && "$group" == "root" ]]; then
        check_pass "文件权限正确 (0440 root:root)"
    else
        check_fail "文件权限正确 (0440 root:root, 当前: $perms $owner:$group)"
    fi

    # 汇总
    echo ""
    echo "─────────────────────────────────────────────────────"
    echo -e "  通过: ${_GREEN}${PASS_COUNT}${_NC}  失败: ${_RED}${FAIL_COUNT}${_NC}"
    echo ""

    if [ "$FAIL_COUNT" -eq 0 ]; then
        log_success "所有检查通过 (PASS)"
        exit 0
    else
        log_error "部分检查失败 (FAIL: $FAIL_COUNT)"
        exit 1
    fi
}

main
