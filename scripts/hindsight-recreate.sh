#!/usr/bin/env bash
# hindsight-recreate.sh — hindsight 记忆服务器容器一键重建（C4 固化，2026-10-04）
#
# 背景：hindsight 此前是裸 docker run（12+ env 手工敲），误删即复发 Session not
# found。本脚本从 2026-10-04 实测容器定义固化全部参数；状态在命名卷
# hindsight-data（内嵌 pg0），重建不丢记忆。
#
# LLM 配置（2026-11-01 起）：主=env.zai（体验模型），降级=env.deepseek；
# 用本地 env 文件 $LLM_ENV_FILE（600 权限，内含 provider/model/key），
# 该文件缺失时才回退到旧方案——Doppler noda/prd 的 ANTHROPIC_AUTH_TOKEN +
# z.ai coding plan（glm-5.3-flash）。2026-10-30 切换原因：该 coding plan 的
# 周/月额度耗尽（429 code 1310）导致 retain 全部被 defer。
# 注意：embedding 与 cross-encoder 重排是本地模型，不受 LLM 配额影响。
#
# 用法：
#   hindsight-recreate.sh check    # 仅校验前置（默认）：docker/doppler/卷在位
#   hindsight-recreate.sh rebuild  # 删旧容器并按固化定义重建（卷保留）
#
# 服务地址 http://localhost:8888（API/MCP），UI http://localhost:9999。
#
# --shm-size 2g（2026-10-25）：PG 并行查询的动态共享内存段放在 /dev/shm，
# Docker 默认仅 64M；实测 533MB 段扩容失败报 DiskFullError「No space left
# on device」，表象是"磁盘满"但所有真实盘均有大量余量。
set -euo pipefail

IMAGE="ghcr.io/vectorize-io/hindsight:latest"
NAME="hindsight"
VOLUME="hindsight-data"
ACTION="${1:-check}"
# 2026-11-01 用户定：主=体验模型（zai/glm-5.3-flash，coding plan 11-01 已重置）；
# deepseek 降级=env.deepseek（watchdog 自动切或 HINDSIGHT_LLM_ENV_FILE 手动覆盖）
DEFAULT_LLM_ENV="$HOME/.config/hindsight/env.deepseek"
[ -f "$HOME/.config/hindsight/env.zai" ] && DEFAULT_LLM_ENV="$HOME/.config/hindsight/env.zai"
LLM_ENV_FILE="${HINDSIGHT_LLM_ENV_FILE:-$DEFAULT_LLM_ENV}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1"; exit 1; }; }
need docker

# LLM 参数：本地 env 文件优先，缺失则回退 Doppler + z.ai（每行一个参数，兼容 bash 3.2）
llm_args() {
  if [ -f "$LLM_ENV_FILE" ]; then
    printf '%s\n' "--env-file" "$LLM_ENV_FILE"
    return 0
  fi
  need doppler >&2
  local key
  key=$(doppler secrets get --project noda --config prd ANTHROPIC_AUTH_TOKEN --plain 2>/dev/null | tr -d '\n')
  [ -n "$key" ] || return 1
  printf '%s\n' "-e" "HINDSIGHT_API_LLM_PROVIDER=zai" \
                "-e" "HINDSIGHT_API_LLM_API_KEY=$key" \
                "-e" "HINDSIGHT_API_LLM_MODEL=glm-5.3-flash"
}

if [ "$ACTION" = "check" ]; then
  docker volume inspect "$VOLUME" >/dev/null 2>&1 && echo "✓ 卷 $VOLUME 在位（记忆数据）" \
    || echo "⚠️ 卷 $VOLUME 不存在——重建后为全新空库（确认这是预期再 rebuild）"
  if [ -f "$LLM_ENV_FILE" ]; then
    echo "✓ LLM 配置：$LLM_ENV_FILE"
    grep -E '^HINDSIGHT_API_LLM_(PROVIDER|MODEL|BASE_URL)=' "$LLM_ENV_FILE" | sed 's/^/    /'
    [ -r "$LLM_ENV_FILE" ] || { echo "✗ $LLM_ENV_FILE 不可读"; exit 1; }
  elif [ -n "$(llm_args)" ]; then
    echo "✓ Doppler noda/prd ANTHROPIC_AUTH_TOKEN 可读（回退 z.ai）"
  else
    echo "✗ 既无 $LLM_ENV_FILE 也读不到 Doppler 密钥"; exit 1
  fi
  docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "✓ 镜像在位" || echo "ℹ️ 镜像将首次拉取"
  echo "check 通过；确认无误后执行 $0 rebuild"
  exit 0
fi

[ "$ACTION" = "rebuild" ] || { echo "用法: $0 [check|rebuild]"; exit 1; }

LLM_ARGS=()
while IFS= read -r arg; do LLM_ARGS+=("$arg"); done < <(llm_args)
[ "${#LLM_ARGS[@]}" -gt 0 ] || { echo "LLM 参数为空：缺 $LLM_ENV_FILE 且 Doppler 密钥不可读，中止"; exit 1; }
echo "LLM 配置来源：$([ -f "$LLM_ENV_FILE" ] && echo "$LLM_ENV_FILE" || echo 'Doppler noda/prd (z.ai)')"

docker rm -f "$NAME" 2>/dev/null || true
# 卷不删——记忆全在里面；确要清空：docker volume rm hindsight-data（不可逆）
docker run -d --name "$NAME" \
  --restart unless-stopped \
  --shm-size 2g \
  -p 127.0.0.1:8888:8888 -p 127.0.0.1:9999:9999 \
  -v "$VOLUME":/home/hindsight/.pg0 \
  "${LLM_ARGS[@]}" \
  -e HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS=4000 \
  -e HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION=false \
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
