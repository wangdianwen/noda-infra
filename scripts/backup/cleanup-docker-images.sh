#!/bin/bash
# Docker 镜像清理脚本（r4s Alpine 版本）
# 清理未使用的 Docker 镜像，释放磁盘空间

set -euo pipefail

echo "===== Docker 镜像清理开始 $(date) ====="

# 获取当前正在运行容器的镜像 ID
RUNNING_IMAGES=$(docker ps --format '{{.ImageID}}' | sort -u | tr '\n' '|')
RUNNING_IMAGES="${RUNNING_IMAGES%|}"  # 移除最后的 |
echo "当前运行的镜像: $(echo "$RUNNING_IMAGES" | tr '|' '\n' | wc -l | tr -d ' ') 个"

# 清理悬空容器（已停止的无名容器）
echo ""
echo "1. 清理悬空容器..."
DANGLING_CONTAINERS=$(docker ps -a -f "status=exited" -f "status=created" --format "{{.ID}}\t{{.Image}}" | grep "<none>" | awk '{print $1}')
if [ -n "$DANGLING_CONTAINERS" ]; then
    echo "$DANGLING_CONTAINERS" | while read CONTAINER_ID; do
        docker rm "$CONTAINER_ID" 2>/dev/null || true
    done
    echo "✅ 清理了 $(echo "$DANGLING_CONTAINERS" | wc -w | tr -d ' ') 个悬空容器"
else
    echo "✅ 没有悬空容器"
fi

# 清理悬空镜像（无标签的镜像）
echo ""
echo "2. 清理悬空镜像..."
DANGLING=$(docker images -f "dangling=true" -q)
if [ -n "$DANGLING" ]; then
    docker rmi $DANGLING 2>/dev/null || true
    echo "✅ 清理了 $(echo "$DANGLING" | wc -w | tr -d ' ') 个悬空镜像"
else
    echo "✅ 没有悬空镜像"
fi

# 清理旧的 noda-apps 镜像（保留 latest 和前 1 个）
echo ""
echo "3. 清理旧的 noda-apps 镜像..."
NODA_APPS_IMAGES=$(docker images --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}' | \
    grep 'noda-apps' | \
    grep -v ':latest$' | \
    sort -k4 -r | \
    tail -n +2 | \
    awk '{print $1}')

if [ -n "$NODA_APPS_IMAGES" ]; then
    for IMG in $NODA_APPS_IMAGES; do
        # 跳过正在运行中的镜像
        if echo "$RUNNING_IMAGES" | grep -q "$IMG"; then
            continue
        fi
        TAG=$(docker images --format '{{.Tag}}' "$IMG")
        SIZE=$(docker images --format '{{.Size}}' "$IMG")
        echo "  删除: noda-apps:$TAG ($SIZE)"
        docker rmi "$IMG" 2>/dev/null || true
    done
    echo "✅ noda-apps 清理完成"
else
    echo "✅ 没有需要清理的 noda-apps 镜像"
fi

# 清理旧的 noda-ops 镜像（保留 latest 和 test）
echo ""
echo "4. 清理旧的 noda-ops 镜像..."
NODA_OPS_IMAGES=$(docker images --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}' | \
    grep 'noda-ops' | \
    grep -vE ':latest$|:test$' | \
    awk '{print $1}')

if [ -n "$NODA_OPS_IMAGES" ]; then
    for IMG in $NODA_OPS_IMAGES; do
        # 跳过正在运行中的镜像
        if echo "$RUNNING_IMAGES" | grep -q "$IMG"; then
            continue
        fi
        TAG=$(docker images --format '{{.Tag}}' "$IMG")
        SIZE=$(docker images --format '{{.Size}}' "$IMG")
        echo "  删除: noda-ops:$TAG ($SIZE)"
        docker rmi "$IMG" 2>/dev/null || true
    done
    echo "✅ noda-ops 清理完成"
else
    echo "✅ 没有需要清理的 noda-ops 镜像"
fi

# 清理构建缓存
echo ""
echo "5. 清理构建缓存..."
CACHE_BEFORE=$(docker system df --format '{{.BuildCacheSize}}' 2>/dev/null || echo "0B")
docker system prune -f 2>/dev/null || true
echo "✅ 清理完成"

# 显示清理后的空间使用
echo ""
echo "===== 清理后的空间使用 ====="
docker system df

echo ""
echo "===== Docker 镜像清理完成 $(date) ====="
