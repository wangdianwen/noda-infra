#!/bin/bash
# headroom-recreate.sh — headroom-proxy 容器标准化重建（单一事实源）
#
# 背景：headroom 容器是裸 docker run（无 compose），规格散落在历史命令里。
#   2026-11-08 起以本脚本为准重建；env 与原 ghcr 0.27.0 容器逐项一致，
#   镜像默认本地构建的 headroom-proxy:0.43.1（见 docker/Dockerfile.headroom-proxy）。
#
# 用法：headroom-recreate.sh [镜像tag]（缺省 headroom-proxy:0.43.1）
# 说明：
#   - 纯透传代理，本容器不持有任何 key；客户端（ZCode provider_config.json）自带
#     Authorization 头，本脚本无需读密钥。
#   - HEADROOM_ALLOW_UNAUTHENTICATED_BIND=1：0.4x 版安全加固要求绑 0.0.0.0 时显式
#     确认端口发布受限——本容器 -p 127.0.0.1:8787:8787 仅宿主回环可达，符合豁免条件。
set -euo pipefail

IMAGE="${1:-headroom-proxy:0.43.1}"

echo "==> 重建 headroom-proxy（镜像: ${IMAGE}）"
docker rm -f headroom-proxy >/dev/null 2>&1 || true

docker run -d --name headroom-proxy \
  --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -e ANTHROPIC_TARGET_API_URL=https://api.z.ai/api/anthropic \
  -e OPENAI_TARGET_API_URL=https://api.z.ai/api/coding/paas/v4 \
  -e HEADROOM_TELEMETRY_ENABLED=true \
  -e HEADROOM_ALLOW_UNAUTHENTICATED_BIND=1 \
  "$IMAGE" >/dev/null

echo "==> 等待就绪（最多 30s）"
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:8787/readyz >/dev/null 2>&1; then
    VER=$(curl -fsS --max-time 5 http://127.0.0.1:8787/health | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))')
    echo "✓ headroom-proxy 就绪（版本 ${VER}，8787 端口）"
    exit 0
  fi
  sleep 1
done

echo "✗ 30s 内未就绪，最近日志：" >&2
docker logs headroom-proxy --tail 20 2>&1 >&2
exit 1
