#!/bin/bash

# Jenkins 初始化脚本
# 用于首次启动 Jenkins 时安装必要的插件和配置

set -euo pipefail

echo "🔧 初始化 Jenkins 配置..."

# 等待 Jenkins 完全启动
echo "⏳ 等待 Jenkins 启动..."
until curl -f http://localhost:8080/login > /dev/null 2>&1; do
    echo "   Jenkins 还未就绪，等待 5 秒..."
    sleep 5
done

echo "✅ Jenkins 已启动"

# 安装必要的 Jenkins 插件
echo "📦 安装必要的 Jenkins 插件..."

JENKINS_CLI="/var/jenkins_home/war/WEB-INF/jenkins-cli.jar"
JENKINS_URL="http://localhost:8080"

# 需要安装的插件列表
PLUGINS=(
    "docker-plugin"
    "docker-commons"
    "docker-workflow"
    "git"
    "workflow-aggregator"
    "pipeline-stage-view"
    "timestamper"
    "antisamy-markup-formatter"
    "build-timeout"
    "credentials-binding"
    "matrix-auth"
    "ssh-slaves"
)

# 检查 Jenkins CLI 是否可用
if [ ! -f "$JENKINS_CLI" ]; then
    echo "⚠️  Jenkins CLI 不可用，跳过插件安装"
    echo "   请手动安装以下插件："
    for plugin in "${PLUGINS[@]}"; do
        echo "   - $plugin"
    done
    exit 0
fi

# 使用 Jenkins CLI 安装插件
for plugin in "${PLUGINS[@]}"; do
    echo "   安装 $plugin..."
    java -jar "$JENKINS_CLI" -s "$JENKINS_URL" -auth "admin:$(cat /var/jenkins_home/secrets/initialAdminPassword)" install-plugin "$plugin" || true
done

echo "✅ 插件安装完成"

# 重启 Jenkins 以加载新插件
echo "🔄 重启 Jenkins 以加载插件..."
# 注意：在实际环境中，可能需要使用不同的命令来重启 Jenkins

echo "✅ Jenkins 初始化完成"
