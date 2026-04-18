#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 端到端配置脚本
# ============================================
# 功能：安装 Jenkins + 配置凭据 + 验证 Pipeline 就绪
# 用法：sudo bash scripts/setup-jenkins-pipeline.sh
#
# 交互式输入：
#   - 管理员密码（JENKINS_ADMIN_PASSWORD）
#   - SSH 私钥路径（默认 ~/.ssh/id_ed25519）
#   - Cloudflare API Token（可选）
#   - Cloudflare Zone ID（可选）
#
# 前置条件：
#   - Docker + Docker Compose 已安装
#   - noda-infra 基础设施容器已运行
#   - Git SSH key 可访问 noda-infra 和 noda-apps 仓库
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

JENKINS_URL="http://localhost:8888"
JENKINS_HOME="/var/lib/jenkins"
ADMIN_ENV_FILE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env"

# ============================================
# 颜色
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================
# 辅助函数
# ============================================

# 等待 Jenkins HTTP 就绪
wait_for_jenkins() {
  local max_wait=180
  local waited=0
  log_info "等待 Jenkins 启动..."
  while [ "$waited" -lt "$max_wait" ]; do
    if curl -sf "$JENKINS_URL/login" >/dev/null 2>&1; then
      log_success "Jenkins 已就绪（${waited}s）"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    printf "\r  等待中... %ds / %ds" "$waited" "$max_wait"
  done
  echo ""
  log_error "Jenkins 启动超时（${max_wait}s）"
  return 1
}

# 获取 Jenkins Crumb（CSRF 保护）
get_crumb() {
  local user="$1"
  local pass="$2"
  curl -sf -u "$user:$pass" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'] + ':' + d['crumb'])" 2>/dev/null
}

# 执行 Groovy 脚本（通过 Script Console）
run_groovy() {
  local user="$1"
  local pass="$2"
  local script="$3"

  local crumb
  crumb=$(get_crumb "$user" "$pass")
  if [ -z "$crumb" ]; then
    log_error "无法获取 Jenkins Crumb"
    return 1
  fi

  local crumb_field crumb_value
  crumb_field=$(echo "$crumb" | cut -d: -f1)
  crumb_value=$(echo "$crumb" | cut -d: -f2)

  curl -sf -u "$user:$pass" \
    -X POST \
    -H "$crumb_field: $crumb_value" \
    --data-urlencode "script=$script" \
    "$JENKINS_URL/scriptText" 2>/dev/null
}

# ============================================
# Step 1: 收集配置信息
# ============================================
step1_collect_config() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 1: 收集配置信息${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo ""

  # 管理员密码
  local admin_password=""
  if [ -f "$ADMIN_ENV_FILE" ]; then
    admin_password=$(grep "^JENKINS_ADMIN_PASSWORD=" "$ADMIN_ENV_FILE" | cut -d= -f2)
    if [ "$admin_password" = "CHANGE_ME_TO_A_STRONG_PASSWORD" ]; then
      admin_password=""
    fi
  fi

  if [ -z "$admin_password" ]; then
    echo -e "${CYAN}请输入 Jenkins 管理员密码:${NC}"
    read -rs JENKINS_ADMIN_PASSWORD
    echo ""
    if [ -z "$JENKINS_ADMIN_PASSWORD" ]; then
      log_error "密码不能为空"
      exit 1
    fi
  else
    JENKINS_ADMIN_PASSWORD="$admin_password"
    echo -e "${GREEN}✓ 从 jenkins-admin.env 读取管理员密码${NC}"
  fi

  # 写入 env 文件（供 setup-jenkins.sh 使用）
  if [ ! -f "$ADMIN_ENV_FILE" ] || grep -q "CHANGE_ME" "$ADMIN_ENV_FILE" 2>/dev/null; then
    cat > "$ADMIN_ENV_FILE" <<EOF
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=$JENKINS_ADMIN_PASSWORD
EOF
    echo -e "${GREEN}✓ 已写入 $ADMIN_ENV_FILE${NC}"
  fi

  # SSH 私钥
  local default_key=""
  for key in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
    if [ -f "$key" ]; then
      default_key="$key"
      break
    fi
  done

  echo ""
  echo -e "${CYAN}SSH 私钥路径 [默认: ${default_key}]:${NC}"
  read -r SSH_KEY_PATH
  SSH_KEY_PATH="${SSH_KEY_PATH:-$default_key}"

  if [ ! -f "$SSH_KEY_PATH" ]; then
    log_error "SSH 私钥不存在: $SSH_KEY_PATH"
    exit 1
  fi
  echo -e "${GREEN}✓ SSH 私钥: $SSH_KEY_PATH${NC}"

  SSH_PRIVATE_KEY=$(cat "$SSH_KEY_PATH")

  # Cloudflare（可选）
  echo ""
  echo -e "${CYAN}Cloudflare API Token [可选，回车跳过 CDN 清除]:${NC}"
  read -r CF_API_TOKEN

  echo -e "${CYAN}Cloudflare Zone ID [可选]:${NC}"
  read -r CF_ZONE_ID

  JENKINS_USER="admin"
}

# ============================================
# Step 2: 安装 Jenkins
# ============================================
step2_install_jenkins() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 2: 安装 Jenkins${NC}"
  echo -e "${BLUE}============================================${NC}"

  if dpkg -l jenkins >/dev/null 2>&1; then
    echo -e "${GREEN}Jenkins 已安装${NC}"
    # 确保运行中
    if [ "$(systemctl is-active jenkins 2>/dev/null || echo unknown)" != "active" ]; then
      log_info "启动 Jenkins..."
      sudo systemctl start jenkins
    fi
  else
    log_info "开始安装 Jenkins..."
    bash "$SCRIPT_DIR/setup-jenkins.sh" install || {
      log_error "Jenkins 安装失败"
      exit 1
    }
  fi

  # 等待 Jenkins 就绪
  wait_for_jenkins || exit 1
}

# ============================================
# Step 3: 配置 Git 凭据（SSH key）
# ============================================
step3_configure_git_credentials() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 3: 配置 Git SSH 凭据${NC}"
  echo -e "${BLUE}============================================${NC}"

  # 创建两个凭据（noda-infra 和 noda-apps 使用同一个 SSH key）
  local ssh_key_escaped
  ssh_key_escaped=$(echo "$SSH_PRIVATE_KEY" | sed "s/'/\\\\'/g")

  local groovy_script
  groovy_script=$(cat <<GROOVY_END
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.common.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*

def instance = Jenkins.getInstance()
def domain = Domain.global()
def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()

def sshKey = new BasicSSHUserPrivateKey(
  CredentialsScope.GLOBAL,
  "noda-infra-git-credentials",
  "git",
  new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource('''${ssh_key_escaped}'''),
  null,
  "SSH key for noda-infra repo (Jenkinsfile + deploy scripts)"
)

// 先删除旧凭据（幂等）
def existing = store.getCredentials(domain).find { it.id == "noda-infra-git-credentials" }
if (existing != null) {
  store.removeCredentials(domain, existing)
  println "Removed old noda-infra-git-credentials"
}
store.addCredentials(domain, sshKey)
println "Created: noda-infra-git-credentials"

// noda-apps 使用同一个 key
def sshKey2 = new BasicSSHUserPrivateKey(
  CredentialsScope.GLOBAL,
  "noda-apps-git-credentials",
  "git",
  new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource('''${ssh_key_escaped}'''),
  null,
  "SSH key for noda-apps repo (app source code)"
)

existing = store.getCredentials(domain).find { it.id == "noda-apps-git-credentials" }
if (existing != null) {
  store.removeCredentials(domain, existing)
  println "Removed old noda-apps-git-credentials"
}
store.addCredentials(domain, sshKey2)
println "Created: noda-apps-git-credentials"

instance.save()
println "Git SSH credentials configured successfully"
GROOVY_END
)

  local result
  result=$(run_groovy "$JENKINS_USER" "$JENKINS_ADMIN_PASSWORD" "$groovy_script")
  if echo "$result" | grep -q "configured successfully"; then
    echo -e "${GREEN}✓ Git SSH 凭据配置成功${NC}"
    echo "  - noda-infra-git-credentials"
    echo "  - noda-apps-git-credentials"
  else
    log_error "Git SSH 凭据配置失败"
    echo "$result"
    return 1
  fi
}

# ============================================
# Step 4: 配置 Cloudflare 凭据
# ============================================
step4_configure_cf_credentials() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 4: 配置 Cloudflare 凭据${NC}"
  echo -e "${BLUE}============================================${NC}"

  if [ -z "${CF_API_TOKEN:-}" ]; then
    echo -e "${YELLOW}跳过 Cloudflare 凭据配置（未提供 API Token）${NC}"
    echo -e "  后续可在 Jenkins UI 手动添加 cf-api-token 和 cf-zone-id"
    echo -e "  Pipeline 的 CDN Purge 阶段会自动跳过"
    return 0
  fi

  local groovy_script
  groovy_script=$(cat <<GROOVY_END
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.common.*
import com.cloudbees.plugins.credentials.domains.*
import org.jenkinsci.plugins.plaincredentials.impl.*

def instance = Jenkins.getInstance()
def domain = Domain.global()
def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()

// cf-api-token
def token = new StringCredentialsImpl(
  CredentialsScope.GLOBAL,
  "cf-api-token",
  "Cloudflare API Token for CDN cache purge",
  new hudson.util.Secret("${CF_API_TOKEN}")
)
def existing = store.getCredentials(domain).find { it.id == "cf-api-token" }
if (existing != null) { store.removeCredentials(domain, existing) }
store.addCredentials(domain, token)
println "Created: cf-api-token"

// cf-zone-id
def zoneId = new StringCredentialsImpl(
  CredentialsScope.GLOBAL,
  "cf-zone-id",
  "Cloudflare Zone ID for class.noda.co.nz",
  new hudson.util.Secret("${CF_ZONE_ID:-}")
)
existing = store.getCredentials(domain).find { it.id == "cf-zone-id" }
if (existing != null) { store.removeCredentials(domain, existing) }
store.addCredentials(domain, zoneId)
println "Created: cf-zone-id"

instance.save()
println "Cloudflare credentials configured successfully"
GROOVY_END
)

  local result
  result=$(run_groovy "$JENKINS_USER" "$JENKINS_ADMIN_PASSWORD" "$groovy_script")
  if echo "$result" | grep -q "configured successfully"; then
    echo -e "${GREEN}✓ Cloudflare 凭据配置成功${NC}"
    echo "  - cf-api-token"
    echo "  - cf-zone-id"
  else
    log_warn "Cloudflare 凭据配置可能失败"
    echo "$result"
  fi
}

# ============================================
# Step 5: 验证 Pipeline 作业
# ============================================
step5_verify_pipeline() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 5: 验证 Pipeline 作业${NC}"
  echo -e "${BLUE}============================================${NC}"

  local groovy_script
  groovy_script=$(cat <<'GROOVY_END'
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.*

def instance = Jenkins.getInstance()
def job = instance.getItem('findclass-ssr-deploy')

if (job == null) {
  println "ERROR: Pipeline job 'findclass-ssr-deploy' not found"
} else {
  println "Pipeline job 'findclass-ssr-deploy' exists"
  println "Type: " + job.getClass().getSimpleName()
  def defn = job.getDefinition()
  if (defn != null) {
    println "Definition: " + defn.getClass().getSimpleName()
  }
}
GROOVY_END
)

  local result
  result=$(run_groovy "$JENKINS_USER" "$JENKINS_ADMIN_PASSWORD" "$groovy_script")
  if echo "$result" | grep -q "exists"; then
    echo -e "${GREEN}✓ Pipeline 作业 'findclass-ssr-deploy' 已存在${NC}"
  else
    log_warn "Pipeline 作业未找到，尝试手动创建..."
    # 重新运行 03-pipeline-job.groovy
    local create_script
    create_script=$(cat "$SCRIPT_DIR/jenkins/init.groovy.d/03-pipeline-job.groovy")
    run_groovy "$JENKINS_USER" "$JENKINS_ADMIN_PASSWORD" "$create_script"
    echo -e "${GREEN}✓ Pipeline 作业已创建${NC}"
  fi
}

# ============================================
# Step 6: 安全检查
# ============================================
step6_security_check() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 6: 安全检查${NC}"
  echo -e "${BLUE}============================================${NC}"

  local all_ok=true

  # 检查 Jenkins 版本
  local version
  version=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
  echo -e "  Jenkins 版本: ${version}"

  # 检查 Docker 权限
  if groups jenkins 2>/dev/null | grep -q docker; then
    echo -e "  ${GREEN}✓ jenkins 用户在 docker 组中${NC}"
  else
    echo -e "  ${RED}✗ jenkins 用户不在 docker 组中${NC}"
    all_ok=false
  fi

  # 检查 active-env
  if [ -f /opt/noda/active-env ]; then
    echo -e "  ${GREEN}✓ 活跃环境: $(cat /opt/noda/active-env)${NC}"
  else
    echo -e "  ${RED}✗ /opt/noda/active-env 不存在${NC}"
    all_ok=false
  fi

  # 检查环境变量
  if [ -n "${POSTGRES_USER:-}" ] && [ -n "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "  ${GREEN}✓ POSTGRES 环境变量已设置${NC}"
  else
    echo -e "  ${YELLOW}⚠ POSTGRES_USER/PASSWORD 环境变量未设置${NC}"
    echo -e "    蓝绿容器启动需要这些变量，请确保已 export"
  fi

  # 检查凭据数量
  local cred_count
  cred_count=$(run_groovy "$JENKINS_USER" "$JENKINS_ADMIN_PASSWORD" \
    'println Jenkins.getInstance().getExtensionList("com.cloudbees.plugins.credentials.SystemCredentialsProvider")[0].getCredentials().size()' \
    2>/dev/null || echo "?")
  echo -e "  Jenkins 凭据数量: ${cred_count}"

  if [ "$all_ok" = true ]; then
    echo -e "${GREEN}✓ 安全检查通过${NC}"
  fi
}

# ============================================
# Step 7: 总结
# ============================================
step7_summary() {
  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}Jenkins Pipeline 配置完成！${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo "Pipeline 作业: findclass-ssr-deploy"
  echo "Jenkinsfile: jenkins/Jenkinsfile.findclass-ssr (9 阶段)"
  echo ""
  echo -e "${CYAN}触发方式:${NC}"
  echo "  1. 浏览器访问 $JENKINS_URL"
  echo "  2. 使用管理员账号登录"
  echo "  3. 点击 findclass-ssr-deploy"
  echo "  4. 点击 Build Now"
  echo ""
  echo -e "${CYAN}Pipeline 阶段:${NC}"
  echo "  Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → CDN Purge → Cleanup"
  echo ""
  if [ -z "${CF_API_TOKEN:-}" ]; then
    echo -e "${YELLOW}注意: Cloudflare 凭据未配置${NC}"
    echo "  CDN Purge 阶段会自动跳过"
    echo "  后续可在 Jenkins UI 手动添加 cf-api-token 和 cf-zone-id"
    echo ""
  fi
  echo -e "${CYAN}服务器环境变量提醒:${NC}"
  echo "  Pipeline 的蓝绿容器需要以下环境变量："
  echo "    export POSTGRES_USER=\"xxx\""
  echo "    export POSTGRES_PASSWORD=\"xxx\""
  echo "  确保这些变量在 Jenkins 进程环境中可用"
  echo ""
}

# ============================================
# 主流程
# ============================================
main() {
  step1_collect_config
  step2_install_jenkins
  step3_configure_git_credentials
  step4_configure_cf_credentials
  step5_verify_pipeline
  step6_security_check
  step7_summary
}

main "$@"
