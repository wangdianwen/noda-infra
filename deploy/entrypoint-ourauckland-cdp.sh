#!/bin/sh
# ============================================
# OurAuckland CDP sidecar 入口（issue #182）
# ============================================
# Xvfb 起 :99 虚拟显示 → socat 外发 CDP 端口 → 有头 chromium 前台保持。
# 有头是硬要求：无头引擎指纹被源站 WAF 识别 403（UA/IP 无关，spike 实证）；
# --dump-dom/--virtual-time-budget 是 headless 专属参数，有头必须走 CDP。
# --no-sandbox：容器内无特权内核沙箱依赖（compose 侧 cap_drop ALL）。
# 端口拓扑：chromium DevTools 只绑 127.0.0.1:9223（chromium ≥13x 起
# --remote-debugging-address 被忽略，2026-11-07 chromium 156 实证），
# socat 把 0.0.0.0:9222 → 127.0.0.1:9223 供 noda-network 内 noda-jobs 访问
#（无宿主端口发布；chromium DNS-rebinding Host 校验由客户端侧
# Host: localhost 覆写处理，见 noda-apps cdpclient.go）。
# --disable-dev-shm-usage：/dev/shm 64MB 默认不够渲染用，改写 /tmp。
set -e

Xvfb :99 -screen 0 1280x900x24 -nolisten tcp &
XVFB_PID=$!
# DISPLAY 必须显式导出给 chromium（sh 不自动设）
export DISPLAY=:99

# 等 X 就绪（最多 10s；chromium 起在 X 前会立刻退）
i=0
until [ -e /tmp/.X11-unix/X99 ]; do
    i=$((i + 1))
    if [ "$i" -ge 40 ]; then
        echo "entrypoint: Xvfb :99 10s 内未就绪" >&2
        kill "$XVFB_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 0.25
done

# CDP 外发转发：socat 先起（chromium 未起时连接排队重试由客户端承担）
socat TCP-LISTEN:9222,bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:9223 &
SOCAT_PID=$!

# 前台保持：chromium 即容器主进程（退出=容器重启，unless-stopped 自愈）
# user-data-dir=/tmp/profile：容器层可写即可（recreate=全新 profile，指纹会话
# 无累积状态依赖——spike 实证全新容器即直通）
exec chromium \
    --no-sandbox \
    --headful \
    --disable-gpu \
    --disable-dev-shm-usage \
    --remote-debugging-port=9223 \
    --user-data-dir=/tmp/profile \
    --window-size=1280,900 \
    about:blank
