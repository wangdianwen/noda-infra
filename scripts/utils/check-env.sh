#!/bin/bash
set -euo pipefail

ENV_TYPE=${1:-"dev"}

required_vars=(
  "POSTGRES_USER"
  "POSTGRES_PASSWORD"
)

# 生产环境才需要 Cloudflare Tunnel Token
if [[ "$ENV_TYPE" == "prod" ]]; then
  required_vars+=("CLOUDFLARE_TUNNEL_TOKEN")
fi

missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "❌ Missing required variable: $var"
    missing=1
  fi
done

if [[ $missing -eq 1 ]]; then
  echo "请检查 .env 文件配置"
  exit 1
fi

echo "✅ 所有必需的环境变量已设置"
