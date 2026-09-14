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

# noda-api / noda-static 版本保留（2026-09-15 新增，与 Jenkins
# docker_image_retention 同策略）：按 CreatedAt 逆序、同 ID 去重后保留最新 2 版
# （当前 + 回滚锚点），其余删除。此前只清 dangling，commit-tag 旧镜像无限累积。
echo ""
echo "5. noda-api / noda-static 版本保留（各留最新 2 版）..."
for REPO in noda-api noda-static; do
    STALE=$(docker images "$REPO" --format '{{.CreatedAt}} {{.ID}}' | sort -ur | awk '{print $2}' | awk '!seen[$0]++' | tail -n +3)
    if [ -n "$STALE" ]; then
        for IMG in $STALE; do
            # -f：同 ID 多历史 tag 时裸删会静默失败（见 lib/image-cleanup.sh 注释）
            docker rmi -f "$IMG" 2>/dev/null || true
        done
        echo "✅ $REPO 旧版本已清理"
    else
        echo "✅ $REPO 无过期版本"
    fi
done

# SeaweedFS vacuum（2026-09-15 新增）：反复整站 mc mirror 会留下垃圾卷，
# vacuum 在线压缩，释放磁盘并抑制 needle map 缓慢膨胀
echo ""
echo "6. SeaweedFS vacuum..."
VACUUM_OUT=$(docker exec seaweedfs wget -qO- 'http://127.0.0.1:9333/vol/vacuum?garbageThreshold=0.3' 2>/dev/null || true)
if [ -n "$VACUUM_OUT" ]; then echo "✅ vacuum 已执行"; else echo "⚠️ vacuum 不可达（跳过，不影响清理）"; fi

# 清理构建缓存
echo ""
echo "7. 清理构建缓存..."
CACHE_BEFORE=$(docker system df --format '{{.BuildCacheSize}}' 2>/dev/null || echo "0B")
docker system prune -f 2>/dev/null || true
echo "✅ 清理完成"

# 显示清理后的空间使用
echo ""
echo "===== 清理后的空间使用 ====="
docker system df

echo ""
echo "===== Docker 镜像清理完成 $(date) ====="
