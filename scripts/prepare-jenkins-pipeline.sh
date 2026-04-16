#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 发布准备脚本
# ============================================
# 功能：在服务器上一次性完成 Jenkins 安装、凭据配置、Pipeline 准备
# 用法：
#   # 1. 先编辑管理员密码（必须）
#   vim scripts/jenkins/config/jenkins-admin.env
#
#   # 2. 设置环境变量（必须）
#   export POSTGRES_USER="xxx"
#   export POSTGRES_PASSWORD="xxx"
#   export RESEND_API_KEY="xxx"  # 可选
#
#   # 3. 运行脚本
#   sudo bash scripts/prepare-jenkins-pipeline.sh
#
# 前置条件：
#   - noda-infra 仓库已 clone 到服务器
#   - Docker + Docker Compose 已安装
#   - noda-infra 基础设施容器已运行（postgres, nginx, keycloak 等）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 颜色标记
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# Step 1: 检查前置条件
# ============================================
step1_check_prerequisites() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 1: 检查前置条件${NC}"
  echo -e "${BLUE}============================================${NC}"

  local ok=true

  # 检查 Docker
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}✗ Docker 未安装${NC}"
    ok=false
  else
    echo -e "${GREEN}✓ Docker: $(docker --version)${NC}"
  fi

  # 检查 Docker Compose
  if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}✗ Docker Compose 未安装${NC}"
    ok=false
  else
    echo -e "${GREEN}✓ Docker Compose: $(docker compose version)${NC}"
  fi

  # 检查 noda-infra 容器
  local running_containers
  running_containers=$(docker ps --filter "name=noda-infra" --format "{{.Names}}" | wc -l)
  if [ "$running_containers" -eq 0 ]; then
    echo -e "${YELLOW}⚠ 没有运行中的 noda-infra 容器${NC}"
    echo -e "  请先启动基础设施: bash scripts/deploy/deploy-infrastructure-prod.sh"
    ok=false
  else
    echo -e "${GREEN}✓ noda-infra 容器运行中: ${running_containers} 个${NC}"
  fi

  # 检查 nginx 容器
  if ! docker ps --filter "name=noda-infra-nginx" --format "{{.Names}}" | grep -q nginx; then
    echo -e "${RED}✗ nginx 容器未运行${NC}"
    ok=false
  else
    echo -e "${GREEN}✓ nginx 容器运行中${NC}"
  fi

  # 检查 noda-network
  if ! docker network inspect noda-network >/dev/null 2>&1; then
    echo -e "${RED}✗ Docker 网络 noda-network 不存在${NC}"
    ok=false
  else
    echo -e "${GREEN}✓ Docker 网络 noda-network 存在${NC}"
  fi

  # 检查 active-env 文件
  if [ ! -f /opt/noda/active-env ]; then
    echo -e "${YELLOW}⚠ /opt/noda/active-env 不存在，将使用默认值 blue${NC}"
    echo -e "  创建默认文件..."
    sudo mkdir -p /opt/noda
    echo "blue" | sudo tee /opt/noda/active-env >/dev/null
    echo -e "${GREEN}✓ 已创建 /opt/noda/active-env (blue)${NC}"
  else
    local active
    active=$(cat /opt/noda/active-env)
    echo -e "${GREEN}✓ 活跃环境: ${active}${NC}"
  fi

  # 检查 upstream include 文件
  local upstream_conf="$PROJECT_ROOT/config/nginx/snippets/upstream-findclass.conf"
  if [ ! -f "$upstream_conf" ]; then
    echo -e "${RED}✗ upstream include 文件不存在: ${upstream_conf}${NC}"
    ok=false
  else
    echo -e "${GREEN}✓ upstream include 文件存在${NC}"
  fi

  # 检查环境变量
  if [ -z "${POSTGRES_USER:-}" ]; then
    echo -e "${YELLOW}⚠ POSTGRES_USER 环境变量未设置（蓝绿容器启动需要）${NC}"
  else
    echo -e "${GREEN}✓ POSTGRES_USER 已设置${NC}"
  fi

  if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "${YELLOW}⚠ POSTGRES_PASSWORD 环境变量未设置（蓝绿容器启动需要）${NC}"
  else
    echo -e "${GREEN}✓ POSTGRES_PASSWORD 已设置${NC}"
  fi

  # 检查 Node.js 和 pnpm
  if ! command -v node >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Node.js 未安装（Pipeline Test 阶段需要）${NC}"
    echo -e "  安装: curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash - && sudo apt install -y nodejs"
  else
    echo -e "${GREEN}✓ Node.js: $(node --version)${NC}"
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ pnpm 未安装（Pipeline Test 阶段需要）${NC}"
    echo -e "  安装: sudo npm install -g pnpm"
  else
    echo -e "${GREEN}✓ pnpm: $(pnpm --version)${NC}"
  fi

  if [ "$ok" = false ]; then
    echo ""
    echo -e "${RED}前置条件检查失败，请修复上述问题后重试${NC}"
    return 1
  fi

  echo ""
  echo -e "${GREEN}前置条件检查通过${NC}"
}

# ============================================
# Step 2: 安装 Jenkins（如果未安装）
# ============================================
step2_install_jenkins() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 2: 安装 Jenkins${NC}"
  echo -e "${BLUE}============================================${NC}"

  # 检查是否已安装
  if dpkg -l jenkins >/dev/null 2>&1; then
    echo -e "${GREEN}Jenkins 已安装，跳过${NC}"

    # 检查服务状态
    local service_status
    service_status=$(systemctl is-active jenkins 2>/dev/null || echo "unknown")
    if [ "$service_status" != "active" ]; then
      echo -e "${YELLOW}Jenkins 服务未运行，启动中...${NC}"
      sudo systemctl start jenkins
    fi

    # 检查端口
    if curl -sf "http://localhost:8888/login" >/dev/null 2>&1; then
      echo -e "${GREEN}✓ Jenkins 运行中（端口 8888）${NC}"
    else
      echo -e "${YELLOW}Jenkins 端口 8888 不可达，可能正在启动...${NC}"
    fi
    return 0
  fi

  # 检查管理员密码配置
  local admin_env="$SCRIPT_DIR/jenkins/config/jenkins-admin.env"
  if [ ! -f "$admin_env" ]; then
    echo -e "${RED}管理员凭据文件不存在: ${admin_env}${NC}"
    echo -e "  请先创建:"
    echo -e "  cp scripts/jenkins/config/jenkins-admin.env.example ${admin_env}"
    echo -e "  vim ${admin_env}"
    return 1
  fi

  # 检查密码是否还是默认值
  if grep -q "CHANGE_ME_TO_A_STRONG_PASSWORD" "$admin_env" 2>/dev/null; then
    echo -e "${RED}管理员密码仍为默认值，请先修改: ${admin_env}${NC}"
    return 1
  fi

  echo -e "${YELLOW}开始安装 Jenkins...${NC}"
  bash "$SCRIPT_DIR/setup-jenkins.sh" install
}

# ============================================
# Step 3: 配置 Jenkins 凭据
# ============================================
step3_configure_credentials() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 3: 配置 Jenkins 凭据${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo ""
  echo "Pipeline 需要 4 个凭据，必须在 Jenkins UI 手动配置："
  echo ""
  echo -e "${YELLOW}  访问 http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>'):8888${NC}"
  echo "  Manage Jenkins → Credentials → System → Global credentials → Add Credentials"
  echo ""
  echo -e "  ${GREEN}1. noda-infra-git-credentials${NC}"
  echo "     类型: SSH Username with private key"
  echo "     用途: 拉取 noda-infra 仓库（含 Jenkinsfile + 部署脚本）"
  echo ""
  echo -e "  ${GREEN}2. noda-apps-git-credentials${NC}"
  echo "     类型: SSH Username with private key"
  echo "     用途: 拉取 noda-apps 仓库（构建应用镜像）"
  echo ""
  echo -e "  ${GREEN}3. cf-api-token${NC}"
  echo "     类型: Secret text"
  echo "     用途: Cloudflare API Token（CDN 缓存清除）"
  echo ""
  echo -e "  ${GREEN}4. cf-zone-id${NC}"
  echo "     类型: Secret text"
  echo "     用途: Cloudflare Zone ID（class.noda.co.nz 的 zone）"
  echo ""

  # 检查是否有 SSH key 可用
  echo -e "${BLUE}SSH Key 提示:${NC}"
  if [ -f ~/.ssh/id_ed25519 ]; then
    echo -e "  ${GREEN}✓ 找到 ~/.ssh/id_ed25519${NC}"
    echo "  可直接用作 Jenkins Git 凭据的私钥"
  elif [ -f ~/.ssh/id_rsa ]; then
    echo -e "  ${GREEN}✓ 找到 ~/.ssh/id_rsa${NC}"
    echo "  可直接用作 Jenkins Git 凭据的私钥"
  else
    echo -e "  ${YELLOW}⚠ 未找到 SSH key${NC}"
    echo "  生成: ssh-keygen -t ed25519 -C 'jenkins@noda'"
  fi
  echo ""
}

# ============================================
# Step 4: 验证 Pipeline 就绪
# ============================================
step4_verify_pipeline() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 4: 验证 Pipeline 就绪${NC}"
  echo -e "${BLUE}============================================${NC}"

  local all_ok=true

  # 检查 Jenkins 运行
  if curl -sf "http://localhost:8888/login" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Jenkins 运行中（端口 8888）${NC}"
  else
    echo -e "${RED}✗ Jenkins 不可达${NC}"
    all_ok=false
  fi

  # 检查 Jenkinsfile 存在
  if [ -f "$PROJECT_ROOT/jenkins/Jenkinsfile" ]; then
    echo -e "${GREEN}✓ Jenkinsfile 存在${NC}"
  else
    echo -e "${RED}✗ Jenkinsfile 不存在${NC}"
    all_ok=false
  fi

  # 检查 pipeline-stages.sh
  if [ -f "$PROJECT_ROOT/scripts/pipeline-stages.sh" ]; then
    echo -e "${GREEN}✓ pipeline-stages.sh 存在${NC}"
  else
    echo -e "${RED}✗ pipeline-stages.sh 不存在${NC}"
    all_ok=false
  fi

  # 检查 manage-containers.sh
  if [ -f "$PROJECT_ROOT/scripts/manage-containers.sh" ]; then
    echo -e "${GREEN}✓ manage-containers.sh 存在${NC}"
  else
    echo -e "${RED}✗ manage-containers.sh 不存在${NC}"
    all_ok=false
  fi

  # 检查 env-findclass-ssr.env
  if [ -f "$PROJECT_ROOT/docker/env-findclass-ssr.env" ]; then
    echo -e "${GREEN}✓ env-findclass-ssr.env 存在${NC}"
  else
    echo -e "${RED}✗ env-findclass-ssr.env 不存在${NC}"
    all_ok=false
  fi

  # 检查 active-env
  if [ -f /opt/noda/active-env ]; then
    local active
    active=$(cat /opt/noda/active-env)
    echo -e "${GREEN}✓ 活跃环境: ${active}${NC}"
  else
    echo -e "${RED}✗ /opt/noda/active-env 不存在${NC}"
    all_ok=false
  fi

  if [ "$all_ok" = true ]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}Pipeline 就绪！${NC}"
    echo -e "${GREEN}============================================${NC}"
  else
    echo ""
    echo -e "${YELLOW}部分检查未通过，请先修复${NC}"
  fi
}

# ============================================
# Step 5: 显示触发指令
# ============================================
step5_show_trigger() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Step 5: 触发 Pipeline${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo ""
  echo -e "${GREEN}所有准备工作完成！${NC}"
  echo ""
  echo "触发方式："
  echo ""
  echo "  1. 浏览器访问 Jenkins:"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<server-ip>")
  echo -e "     ${YELLOW}http://${ip}:8888${NC}"
  echo ""
  echo "  2. 找到 noda-apps-deploy Pipeline 作业"
  echo ""
  echo "  3. 点击 Build Now 按钮"
  echo ""
  echo "Pipeline 自动执行 9 阶段："
  echo "  Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → CDN Purge → Cleanup"
  echo ""
  echo "查看构建日志："
  echo "  点击构建号 → Console Output"
  echo ""
  echo -e "${YELLOW}注意事项:${NC}"
  echo "  - 首次构建需要从 git 拉取两个仓库，耗时较长"
  echo "  - Test 阶段需要 noda-apps 有 lint 和 test 脚本"
  echo "  - 确保凭据已在 Jenkins UI 中配置（Step 3）"
  echo "  - 失败时 Pipeline 自动归档日志，可在构建页面下载"
  echo ""
  echo -e "${BLUE}============================================${NC}"
}

# ============================================
# 主流程
# ============================================
main() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}Jenkins Pipeline 发布准备${NC}"
  echo -e "${BLUE}============================================${NC}"

  step1_check_prerequisites || { echo ""; echo -e "${RED}前置条件检查失败，退出${NC}"; exit 1; }
  step2_install_jenkins     || { echo ""; echo -e "${RED}Jenkins 安装失败，退出${NC}"; exit 1; }
  step3_configure_credentials
  step4_verify_pipeline
  step5_show_trigger
}

main "$@"
