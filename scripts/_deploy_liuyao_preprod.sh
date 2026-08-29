#!/bin/bash
# 临时部署驱动：复用 pipeline 函数部署 liuyao 到 preprod
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
export DEPLOY_TARGET="local"

echo "===== Loading Doppler secrets ====="
# 绕过 load_secrets（它需要 service token），直接用 CLI 导出
# set -a：eval 注入的变量自动 export，否则 docker compose 子进程继承不到（STRIPE_* 会是空）
set -a
eval "$(doppler secrets download --project noda --config prd_pre --no-file --format=env 2>/dev/null)"
set +a
export DOPPLER_TOKEN="cli-bypass"  # 占位，load_secrets 检查非空即可
export SKIP_LOAD_SECRETS=1  # secrets 已由上方 eval 注入，跳过 pipeline 顶层 load_secrets

echo "===== Loading pipeline functions ====="
source scripts/lib/log.sh
source scripts/pipeline-stages.sh

GIT_SHA=$(git -C "$PROJECT_ROOT/../noda-apps" rev-parse --short HEAD)
echo "===== GIT_SHA: $GIT_SHA ====="

echo "===== Phase 1: Preflight ====="
pipeline_preflight "$PROJECT_ROOT/../noda-apps"

echo "===== Phase 2: Build image ====="
export DOCKERFILE="$HOME/project/noda-apps/infra/docker/Dockerfile.noda-apps"
pipeline_build "$PROJECT_ROOT/../noda-apps" "$GIT_SHA"

echo "===== Phase 3: Deploy preprod ====="
pipeline_deploy_preprod "$GIT_SHA"

echo "===== Phase 4: Health check ====="
pipeline_health_check_preprod

echo "===== DEPLOY COMPLETE ====="
