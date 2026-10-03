#!/usr/bin/env bash
# hindsight-recreate.sh — hindsight 记忆服务器容器一键重建（C4 固化，2026-10-04）
#
# 背景：hindsight 此前是裸 docker run（12+ env 手工敲），误删即复发 Session not
# found。本脚本从 2026-10-04 实测容器定义固化全部参数；状态在命名卷
# hindsight-data（内嵌 pg0），重建不丢记忆。LLM key 从 Doppler noda/prd 的
# ANTHROPIC_AUTH_TOKEN 取（2026-10-04 哈希比对确认与现容器一致）。
#
# 用法：
#   hindsight-recreate.sh check    # 仅校验前置（默认）：docker/doppler/卷在位
#   hindsight-recreate.sh rebuild  # 删旧容器并按固化定义重建（卷保留）
#
# 服务地址 http://localhost:8888（API/MCP），UI http://localhost:9999。
set -euo pipefail

IMAGE="ghcr.io/vectorize-io/hindsight:latest"
NAME="hindsight"
VOLUME="hindsight-data"
ACTION="${1:-check}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1"; exit 1; }; }
need docker
need doppler

if [ "$ACTION" = "check" ]; then
  docker volume inspect "$VOLUME" >/dev/null 2>&1 && echo "✓ 卷 $VOLUME 在位（记忆数据）" \
    || echo "⚠️ 卷 $VOLUME 不存在——重建后为全新空库（确认这是预期再 rebuild）"
  KEY=$(doppler secrets get --project noda --config prd ANTHROPIC_AUTH_TOKEN --plain 2>/dev/null | tr -d '\n')
  [ -n "$KEY" ] && echo "✓ Doppler noda/prd ANTHROPIC_AUTH_TOKEN 可读" || { echo "✗ Doppler 密钥不可读"; exit 1; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "✓ 镜像在位" || echo "ℹ️ 镜像将首次拉取"
  echo "check 通过；确认无误后执行 $0 rebuild"
  exit 0
fi

[ "$ACTION" = "rebuild" ] || { echo "用法: $0 [check|rebuild]"; exit 1; }

KEY=$(doppler secrets get --project noda --config prd ANTHROPIC_AUTH_TOKEN --plain | tr -d '\n')
[ -n "$KEY" ] || { echo "Doppler 密钥不可读，中止"; exit 1; }

docker rm -f "$NAME" 2>/dev/null || true
# 卷不删——记忆全在里面；确要清空：docker volume rm hindsight-data（不可逆）
docker run -d --name "$NAME" \
  --restart unless-stopped \
  -p 8888:8888 -p 9999:9999 \
  -v "$VOLUME":/home/hindsight/.pg0 \
  -e HINDSIGHT_API_LLM_PROVIDER=zai \
  -e HINDSIGHT_API_LLM_API_KEY="$KEY" \
  -e HINDSIGHT_API_LLM_MODEL=glm-5.3-flash \
  -e HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS=12000 \
  -e HINDSIGHT_API_REFLECT_LLM_REASONING_EFFORT=low \
  -e HINDSIGHT_API_WORKER_ID=local-worker-1 \
  -e HINDSIGHT_API_HOST=0.0.0.0 \
  -e HINDSIGHT_API_PORT=8888 \
  -e HINDSIGHT_API_LOG_LEVEL=info \
  -e HINDSIGHT_CP_DATAPLANE_API_URL=http://localhost:8888 \
  -e HINDSIGHT_ENABLE_API=true \
  -e HINDSIGHT_ENABLE_CP=true \
  -e HINDSIGHT_API_MCP_STATELESS=true \
  "$IMAGE"

echo "等待就绪..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null --max-time 3 http://localhost:8888/health 2>/dev/null ||
     curl -sf -o /dev/null --max-time 3 http://localhost:8888/ 2>/dev/null; then
    echo "✓ hindsight 已就绪：API http://localhost:8888 · UI http://localhost:9999"
    exit 0
  fi
  sleep 2
done
echo "⚠️ 60s 未探活，查日志：docker logs $NAME --tail 50"
exit 1
