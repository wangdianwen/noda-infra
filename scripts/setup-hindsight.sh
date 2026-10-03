#!/usr/bin/env bash
# setup-hindsight.sh — hindsight 记忆服务容器固化（Mac mini 本机 docker，不在 r4s）
#
# 2026-10-03 定案：必须带 HINDSIGHT_API_MCP_STATELESS=true 重建。
# 不带时为 stateful MCP：容器一旦重启/重建，ZCode 客户端的旧 session id 失效，
# 服务端按规范回 404 但客户端不会自动 re-initialize → 所有 mcp__hindsight__* 报
# -32600 "Session not found"（docker start/restart 治不好，只能换客户端会话）。
# stateless 模式 POST-only、忽略 session 头，重启对客户端透明。
#
# 数据在命名卷 hindsight-data（内嵌 pg0 库），重建不丢。UI 在 :9999。
set -euo pipefail

docker inspect hindsight >/dev/null 2>&1 && { echo "hindsight 已在运行，先 docker rm -f hindsight"; exit 1; }

ENV_FILE=$(mktemp /tmp/hindsight-env.XXXXXX)
trap 'rm -f "$ENV_FILE"' EXIT
docker inspect hindsight --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
  grep -E '^(HINDSIGHT_|ANTHROPIC_)' > "$ENV_FILE" ||
  true
# 全新机器（无旧容器可导出 env）时按需手工填充 HINDSIGHT_API_LLM_* 后再跑
[ -s "$ENV_FILE" ] || { echo "$ENV_FILE 为空：请先手工填 HINDSIGHT_API_LLM_PROVIDER/API_KEY/MODEL 等"; exit 1; }

docker run -d --name hindsight --restart unless-stopped \
  -p 8888:8888 -p 9999:9999 \
  -v hindsight-data:/home/hindsight/.pg0 \
  --env-file "$ENV_FILE" \
  -e HINDSIGHT_API_MCP_STATELESS=true \
  ghcr.io/vectorize-io/hindsight:latest

echo "已启动。自检（期望 200）："
sleep 8
curl -s -o /dev/null -w 'stale-session tools/list HTTP=%{http_code}\n' -X POST http://localhost:8888/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -H 'mcp-session-id: deadbeef000000000000000000000000' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
