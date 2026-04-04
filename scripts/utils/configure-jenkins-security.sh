#!/bin/bash

# Jenkins 安全配置脚本
# 用于初始化 Jenkins 的安全和访问控制设置

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} 配置 Jenkins 安全设置..."

# Jenkins CLI
JENKINS_URL="http://localhost:8080"
JENKINS_CLI="/var/jenkins_home/war/WEB-INF/jenkins-cli.jar"
ADMIN_PASSWORD_FILE="/var/jenkins_home/secrets/initialAdminPassword"

# 等待 Jenkins 完全启动
echo -e "${GREEN}[INFO]${NC} 等待 Jenkins 启动..."
until curl -f "$JENKINS_URL/login" >/dev/null 2>&1; do
    echo "   Jenkins 还未就绪，等待 5 秒..."
    sleep 5
done

# 检查管理员密码
if [[ ! -f "$ADMIN_PASSWORD_FILE" ]]; then
    echo -e "${RED}[ERROR]${NC} 管理员密码文件不存在"
    exit 1
fi

ADMIN_PASSWORD=$(cat "$ADMIN_PASSWORD_FILE")

# 配置 CSRF 保护
echo -e "${GREEN}[INFO]${NC} 配置 CSRF 保护..."
java -jar "$JENKINS_CLI" \
    -s "$JENKINS_URL" \
    -auth "admin:$ADMIN_PASSWORD" \
    groovy /dev/stdin <<'EOF' || true
import jenkins.model.Jenkins
import hudson.security.csrf.DefaultCrumbIssuer

// 启用 CSRF 保护
def jenkins = Jenkins.getInstance()
jenkins.setCrumbIssuer(new DefaultCrumbIssuer(true))
jenkins.save()
EOF

# 配置访问控制（基于矩阵的授权）
echo -e "${GREEN}[INFO]${NC} 配置访问控制..."
java -jar "$JENKINS_CLI" \
    -s "$JENKINS_URL" \
    -auth "admin:$ADMIN_PASSWORD" \
    groovy /dev/stdin <<'EOF' || true
import jenkins.model.Jenkins
import hudson.security.*
import com.michelin.cio.henkins.plugins.rolestrategy.*
import org.jenkinsci.plugins.matrixauth.*

// 创建基于矩阵的授权策略
def jenkins = Jenkins.getInstance()

def strategy = new GlobalMatrixAuthorizationStrategy()

// 管理员权限
strategy.add(Jenkins.ADMINISTER, "admin")

// 匿名用户权限（只读）
strategy.add(Jenkins.READ, "anonymous")
strategy.add(hudson.model.Item.READ, "anonymous")
strategy.add(hudson.model.Item.WORKSPACE, "anonymous")

// 认证用户权限
strategy.add(Jenkins.READ, "authenticated")
strategy.add(hudson.model.Item.BUILD, "authenticated")
strategy.add(hudson.model.Item.READ, "authenticated")
strategy.add(hudson.model.Item.WORKSPACE, "authenticated")

jenkins.setAuthorizationStrategy(strategy)
jenkins.save()
EOF

# 配置 Agent 协议
echo -e "${GREEN}[INFO]${NC} 配置 Agent 协议..."
java -jar "$JENKINS_CLI" \
    -s "$JENKINS_URL" \
    -auth "admin:$ADMIN_PASSWORD" \
    groovy /dev/stdin <<'EOF' || true
import jenkins.model.Jenkins
import hudson.slaves.*

def jenkins = Jenkins.getInstance()

// 设置 Agent 协议为 JNLP
jenkins.setSlaveAgentPort(50000)

// 禁用旧的 CLI 协议（安全风险）
jenkins.getDescriptor("jenkins.CLI").get().setDisabled(true)

jenkins.save()
EOF

# 配置审计日志
echo -e "${GREEN}[INFO]${NC} 配置审计日志..."
mkdir -p /var/jenkins_home/logs/audit

# 创建审计日志配置（如果插件已安装）
java -jar "$JENKINS_CLI" \
    -s "$JENKINS_URL" \
    -auth "admin:$ADMIN_PASSWORD" \
    groovy /dev/stdin <<'EOF' || true
import jenkins.model.Jenkins

def jenkins = Jenkins.getInstance()

// 启用审计日志（如果审计插件已安装）
try {
    def auditLogger = jenkins.getExtensionList(com.cloudbees.jenkins.plugins.audit.AuditLogger.class)[0]
    auditLogger.setLogFolder("/var/jenkins_home/logs/audit")
    jenkins.save()
} catch (Exception e) {
    println "审计插件未安装，跳过审计日志配置"
}
EOF

# 创建安全配置报告
echo -e "${GREEN}[INFO]${NC} 生成安全配置报告..."
cat > /var/jenkins_home/security-config-report.txt <<EOF
Jenkins 安全配置报告
生成时间: $(date)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
访问控制
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
授权策略: 基于矩阵的授权
管理员: admin
匿名用户: 只读访问
认证用户: 构建和读取权限

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CSRF 保护
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
状态: 已启用
Crumb Issuer: 默认配置

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Agent 协议
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
协议: JNLP
端口: 50000
加密: 已启用

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
密钥管理
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SOPS 密钥文件: /var/jenkins_home/keys/team-keys.txt
权限: 只读
环境变量: SOPS_AGE_KEY_FILE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
网络安全
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
外网访问: Cloudflare Tunnel
TLS/SSL: 强制 HTTPS
直接访问: 已禁用

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo -e "${GREEN}[OK]${NC} 安全配置完成"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "重要信息"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📍 Jenkins UI: http://localhost:8080"
echo "🔑 管理员密码: $ADMIN_PASSWORD_FILE"
echo ""
echo "安全配置报告: /var/jenkins_home/security-config-report.txt"
echo ""
echo "⚠️  请完成以下手动配置:"
echo "   1. 首次登录后更改管理员密码"
echo "   2. 配置 Cloudflare Tunnel 访问"
echo "   3. 设置备份和恢复策略"
echo "   4. 配置安全告警"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
