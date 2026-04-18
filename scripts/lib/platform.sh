#!/bin/bash
# ============================================
# 平台检测共享库
# ============================================
# 提供 detect_platform() 函数检测运行平台
# 依赖：无
# ============================================

# Source Guard
if [[ -n "${_NODA_PLATFORM_LOADED:-}" ]]; then
    return 0
fi
_NODA_PLATFORM_LOADED=1

# detect_platform - 检测运行平台
# 返回：macos 或 linux
detect_platform()
{
    local os
    os="$(uname)"
    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}
