#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins 生命周期管理脚本
# ============================================
# 功能：安装、卸载、状态检查、密码获取、重启、升级、密码重置
# 用途：单一入口管理 Jenkins 在宿主机上的所有运维操作
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/platform.sh"

PLATFORM="$(detect_platform)"

# ============================================
# 常量
# ============================================
JENKINS_PORT=8888
JENKINS_HOME_LINUX="/var/lib/jenkins"
JENKINS_LOG="/var/log/jenkins"
JENKINS_OVERRIDE_DIR="/etc/systemd/system/jenkins.service.d"
JENKINS_OVERRIDE_CONF="$JENKINS_OVERRIDE_DIR/override.conf"
GROOVY_SRC_DIR="$SCRIPT_DIR/jenkins/init.groovy.d"
ADMIN_ENV_TEMPLATE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env.example"
ADMIN_ENV_FILE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env"

# macOS Jenkins home 路径检测
macos_jenkins_home()
{
    if [ -d "/opt/homebrew/var/jenkins" ]; then
        echo "/opt/homebrew/var/jenkins"
    elif [ -d "$HOME/Library/Application Support/Jenkins" ]; then
        echo "$HOME/Library/Application Support/Jenkins"
    else
        echo "$HOME/.jenkins"
    fi
}

# 获取当前平台的 Jenkins home
jenkins_home()
{
    if [[ "$PLATFORM" == "macos" ]]; then
        macos_jenkins_home
    else
        echo "$JENKINS_HOME_LINUX"
    fi
}

# ============================================
# usage() — 显示帮助信息
# ============================================
usage()
{
    cat <<'EOF'
Jenkins 生命周期管理脚本

用法: setup-jenkins.sh <命令> [参数]

命令:
  install         安装 Java 21 + Jenkins LTS + 配置 Docker 权限 + 启动服务（仅 Linux）
  uninstall       完全卸载 Jenkins 及所有残留文件（仅 Linux）
  status          检查 Jenkins 运行状态、端口、Docker 权限
  show-password   显示初始管理员密码
  restart         重启 Jenkins 服务
  upgrade         升级 Jenkins 到最新 LTS
  reset-password <新密码>  重置管理员密码
  apply-matrix-auth   应用 Jenkins 权限矩阵配置（Admin 全权限 + Developer 最小权限）
  verify-matrix-auth  验证 Jenkins 权限矩阵配置是否正确

示例:
  setup-jenkins.sh install
  setup-jenkins.sh status
  setup-jenkins.sh show-password
  setup-jenkins.sh reset-password my-new-password
  setup-jenkins.sh apply-matrix-auth
  setup-jenkins.sh verify-matrix-auth

平台差异:
  macOS: install/uninstall 使用 Homebrew，请手动执行 brew install/uninstall jenkins
  macOS: status 检查 Homebrew Jenkins 状态
  macOS: restart/upgrade 使用 brew services
EOF
}

# ============================================
# wait_for_jenkins() — 等待 Jenkins HTTP 端口就绪
# ============================================
# 参数：无
# 返回：0=就绪，1=超时
wait_for_jenkins()
{
    local port="${JENKINS_PORT:-8888}"
    local max_wait=120
    local waited=0

    log_info "等待 Jenkins 启动（端口 ${port}）..."

    while [ "$waited" -lt "$max_wait" ]; do
        if curl -sf "http://localhost:${port}/login" >/dev/null 2>&1; then
            log_success "Jenkins 已就绪（耗时 ${waited}s）"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        log_info "已等待 ${waited}s / ${max_wait}s..."
    done

    log_error "Jenkins 启动超时（${max_wait}s）"
    return 1
}

# ============================================
# cmd_install() — 安装 Java 21 + Jenkins LTS + Docker 权限
# ============================================
cmd_install()
{
    log_info "=========================================="
    log_info "Jenkins 安装开始"
    log_info "=========================================="

    if [[ "$PLATFORM" == "macos" ]]; then
        log_error "macOS 上请使用 'brew install jenkins' 安装 Jenkins。"
        log_error "setup-jenkins.sh install 仅支持 Linux（使用 apt + systemd）。"
        exit 1
    fi

    # 步骤 1/10: 检查是否已安装
    log_info "步骤 1/10: 检查 Jenkins 安装状态"
    if dpkg -l jenkins >/dev/null 2>&1; then
        log_error "Jenkins 已安装，请先执行 uninstall 或使用 upgrade 升级"
        exit 1
    fi
    log_success "Jenkins 未安装，继续安装"

    # 步骤 2/10: 安装 Java 21
    log_info "步骤 2/10: 安装 Java 21"
    sudo apt update
    sudo apt install -y fontconfig openjdk-21-jre

    # 步骤 3/10: 验证 Java
    log_info "步骤 3/10: 验证 Java 安装"
    if ! java -version 2>&1; then
        log_error "Java 安装失败"
        exit 1
    fi
    log_success "Java 安装验证通过"

    # 步骤 4/10: 添加 Jenkins apt 源
    log_info "步骤 4/10: 添加 Jenkins apt 源"
    sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
        https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
        https://pkg.jenkins.io/debian-stable binary/ |
        sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null
    sudo apt update
    log_success "Jenkins apt 源添加成功"

    # 步骤 5/10: 安装 Jenkins
    log_info "步骤 5/10: 安装 Jenkins"
    sudo apt install -y jenkins
    log_success "Jenkins 包安装完成"

    # 步骤 6/10: 配置端口 8888 (systemd override)
    log_info "步骤 6/10: 配置端口 ${JENKINS_PORT} (systemd override)"
    sudo mkdir -p "$JENKINS_OVERRIDE_DIR"
    sudo tee "$JENKINS_OVERRIDE_CONF" >/dev/null <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
EOF
    sudo systemctl daemon-reload
    log_success "端口配置完成（${JENKINS_PORT}）"

    # 步骤 7/10: 写入 init.groovy.d 脚本
    log_info "步骤 7/10: 写入 init.groovy.d 脚本"
    if [ -d "$GROOVY_SRC_DIR" ] && ls "$GROOVY_SRC_DIR"/*.groovy >/dev/null 2>&1; then
        sudo mkdir -p "$JENKINS_HOME_LINUX/init.groovy.d"
        sudo cp "$GROOVY_SRC_DIR"/*.groovy "$JENKINS_HOME_LINUX/init.groovy.d/"
        sudo chown -R jenkins:jenkins "$JENKINS_HOME_LINUX/init.groovy.d"
        log_success "init.groovy.d 脚本已写入"
    else
        log_info "无 init.groovy.d 脚本，跳过首次自动化配置"
    fi

    # 步骤 7.5: 写入管理员凭据
    log_info "步骤 7.5/10: 写入管理员凭据"
    if [ ! -f "$JENKINS_HOME_LINUX/.admin.env" ] && [ -f "$ADMIN_ENV_FILE" ]; then
        sudo cp "$ADMIN_ENV_FILE" "$JENKINS_HOME_LINUX/.admin.env"
        sudo chown jenkins:jenkins "$JENKINS_HOME_LINUX/.admin.env"
        sudo chmod 600 "$JENKINS_HOME_LINUX/.admin.env"
        log_success "管理员凭据已写入（权限 600）"
    elif [ -f "$JENKINS_HOME_LINUX/.admin.env" ]; then
        log_info "管理员凭据已存在，跳过"
    else
        log_info "无管理员凭据文件（${ADMIN_ENV_FILE}），跳过"
    fi

    # 步骤 8/10: Docker 权限（通过 socket 属组，不加入 docker 组）
    log_info "步骤 8/10: 配置 Docker 权限（socket 属组方式）"
    # 确保不在 docker 组（幂等操作）
    sudo gpasswd -d jenkins docker 2>/dev/null || true
    # 配置 systemd override 确保 socket 属组为 jenkins
    local docker_override_dir="/etc/systemd/system/docker.service.d"
    sudo mkdir -p "$docker_override_dir"
    sudo tee "$docker_override_dir/socket-permissions.conf" >/dev/null <<'OVERRIDE'
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
OVERRIDE
    sudo systemctl daemon-reload
    # 立即应用（如果 Docker 正在运行）
    if systemctl is-active --quiet docker 2>/dev/null; then
        sudo systemctl restart docker
    fi
    log_success "Docker socket 权限配置完成（jenkins 用户通过 socket 属组访问）"

    # 步骤 9/10: 启动 Jenkins
    log_info "步骤 9/10: 启动 Jenkins"
    sudo systemctl enable jenkins
    sudo systemctl start jenkins
    log_info "Jenkins 服务已启动"

    # 步骤 9.5: 等待 Jenkins 就绪
    log_info "步骤 9.5/10: 等待 Jenkins 就绪"
    if ! wait_for_jenkins; then
        log_error "Jenkins 启动失败，请检查日志: sudo journalctl -u jenkins"
        exit 1
    fi

    # 步骤 10/10: 清理 init.groovy.d
    log_info "步骤 10/10: 清理 init.groovy.d 脚本"
    sudo rm -rf "$JENKINS_HOME_LINUX/init.groovy.d"
    log_success "init.groovy.d 脚本已清理"

    # 安装完成
    log_success "=========================================="
    log_success "Jenkins 安装完成！"
    log_success "=========================================="
    log_info "访问地址: http://localhost:${JENKINS_PORT}"
    log_info "获取初始密码: bash $0 show-password"
    log_success "=========================================="
}

# ============================================
# cmd_uninstall() — 完全卸载 Jenkins
# ============================================
cmd_uninstall()
{
    log_info "=========================================="
    log_info "Jenkins 卸载开始"
    log_info "=========================================="

    if [[ "$PLATFORM" == "macos" ]]; then
        log_error "macOS 上请使用 'brew uninstall jenkins' 卸载 Jenkins。"
        log_error "setup-jenkins.sh uninstall 仅支持 Linux（使用 apt + systemd）。"
        exit 1
    fi

    # 步骤 1/13: 停止服务
    log_info "步骤 1/13: 停止 Jenkins 服务"
    sudo systemctl stop jenkins 2>/dev/null || true

    # 步骤 2/13: 禁用服务
    log_info "步骤 2/13: 禁用 Jenkins 服务"
    sudo systemctl disable jenkins 2>/dev/null || true

    # 步骤 3/13: 卸载包
    log_info "步骤 3/13: 卸载 Jenkins 包"
    sudo apt remove --purge -y jenkins

    # 步骤 4/13: 删除数据目录
    log_info "步骤 4/13: 删除数据目录 ${JENKINS_HOME_LINUX}"
    sudo rm -rf "$JENKINS_HOME_LINUX"

    # 步骤 5/13: 删除日志目录
    log_info "步骤 5/13: 删除日志目录 ${JENKINS_LOG}"
    sudo rm -rf "$JENKINS_LOG"

    # 步骤 6/13: 删除缓存
    log_info "步骤 6/13: 删除缓存目录"
    sudo rm -rf /var/cache/jenkins

    # 步骤 7/13: 删除 APT 源
    log_info "步骤 7/13: 删除 APT 源"
    sudo rm -f /etc/apt/sources.list.d/jenkins.list

    # 步骤 8/13: 删除 keyring
    log_info "步骤 8/13: 删除 keyring"
    sudo rm -f /etc/apt/keyrings/jenkins-keyring.asc

    # 步骤 9/13: 删除 systemd override
    log_info "步骤 9/13: 删除 systemd override"
    sudo rm -rf "$JENKINS_OVERRIDE_DIR"

    # 步骤 10/13: 重新加载 systemd
    log_info "步骤 10/13: 重新加载 systemd"
    sudo systemctl daemon-reload

    # 步骤 11/13: 从 docker 组移除 jenkins 用户
    log_info "步骤 11/13: 从 docker 组移除 jenkins 用户"
    sudo gpasswd -d jenkins docker 2>/dev/null || true

    # 步骤 11.5: 删除 Docker socket override
    log_info "步骤 11.5/13: 删除 Docker socket 权限 override"
    sudo rm -f /etc/systemd/system/docker.service.d/socket-permissions.conf
    sudo systemctl daemon-reload

    # 步骤 12/13: 删除 jenkins 系统用户
    log_info "步骤 12/13: 删除 jenkins 系统用户"
    sudo userdel jenkins 2>/dev/null || true

    # 步骤 13/13: 清理残留依赖
    log_info "步骤 13/13: 清理残留依赖"
    sudo apt autoremove -y

    log_success "=========================================="
    log_success "Jenkins 完全卸载完成"
    log_success "=========================================="
}

# ============================================
# cmd_status() — 检查 Jenkins 运行状态
# ============================================
cmd_status()
{
    log_info "=========================================="
    log_info "Jenkins 状态检查 (平台: $PLATFORM)"
    log_info "=========================================="

    local all_ok=true

    # 检查 1: Jenkins 是否安装
    log_info "检查 1/5: Jenkins 安装状态"
    if [[ "$PLATFORM" == "macos" ]]; then
        if brew list jenkins >/dev/null 2>&1; then
            local jenkins_version
            jenkins_version=$(brew info jenkins --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['installed'][0]['version'])" 2>/dev/null || echo "已安装")
            log_success "Jenkins 已通过 Homebrew 安装（版本: ${jenkins_version}）"
        else
            log_error "Jenkins 未安装（macOS 上使用 brew install jenkins）"
            all_ok=false
        fi
    else
        if dpkg -l jenkins >/dev/null 2>&1; then
            local jenkins_version
            jenkins_version=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
            log_success "Jenkins 包已安装（版本: ${jenkins_version}）"
        else
            log_error "Jenkins 包未安装"
            all_ok=false
        fi
    fi

    # 检查 2: 服务状态
    log_info "检查 2/5: 服务状态"
    if [[ "$PLATFORM" == "macos" ]]; then
        local brew_status
        brew_status=$(brew services list 2>/dev/null | grep jenkins || echo "")
        if echo "$brew_status" | grep -q "started"; then
            log_success "Jenkins 服务运行中（brew services: started）"
        elif [ -n "$brew_status" ]; then
            log_warn "Jenkins 服务状态: $(echo "$brew_status" | awk '{print $NF}')"
        else
            log_error "Jenkins 未通过 brew services 管理"
            all_ok=false
        fi
    else
        local service_status
        service_status=$(systemctl is-active jenkins 2>/dev/null || echo "unknown")
        if [ "$service_status" = "active" ]; then
            log_success "Jenkins 服务运行中（active）"
        else
            log_error "Jenkins 服务状态: ${service_status}"
            all_ok=false
        fi
    fi

    # 检查 3: 监听端口
    log_info "检查 3/5: 监听端口 ${JENKINS_PORT}"
    if curl -sf "http://localhost:${JENKINS_PORT}/login" >/dev/null 2>&1; then
        log_success "Jenkins 监听端口 ${JENKINS_PORT} 正常"
    else
        log_warn "Jenkins 端口 ${JENKINS_PORT} 不可达（可能未启动或端口不同）"
    fi

    # 检查 4: Docker 权限
    log_info "检查 4/5: Docker 权限"
    if [[ "$PLATFORM" == "macos" ]]; then
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            log_success "Docker 可用（macOS Docker Desktop）"
        else
            log_error "Docker 不可用"
            all_ok=false
        fi
        log_warn "Docker socket systemd override: N/A（macOS 环境，不需要）"
    else
        if sudo -u jenkins docker info >/dev/null 2>&1; then
            log_success "jenkins 用户可以执行 docker 命令（socket 属组方式）"
        else
            log_error "jenkins 用户无法执行 docker 命令"
            all_ok=false
        fi
        # 补充: 检查 systemd override 是否存在
        if [ -f /etc/systemd/system/docker.service.d/socket-permissions.conf ]; then
            log_success "Docker socket 权限 systemd override 已配置"
        else
            log_warn "Docker socket 权限 systemd override 未配置（重启后权限可能丢失）"
        fi
    fi

    # 检查 5: Jenkins 版本
    log_info "检查 5/5: Jenkins 版本"
    if [[ "$PLATFORM" == "macos" ]]; then
        local ver
        ver=$(brew info jenkins --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['installed'][0]['version'])" 2>/dev/null || echo "未知")
        if [ "$ver" != "未知" ]; then
            log_info "Jenkins 版本: ${ver}（从 Homebrew 获取）"
        else
            log_info "无法获取 Jenkins 版本（可能未安装）"
        fi
    else
        if command -v jenkins >/dev/null 2>&1; then
            jenkins --version 2>&1 || true
        elif dpkg -l jenkins >/dev/null 2>&1; then
            local ver
            ver=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
            log_info "Jenkins 版本: ${ver}（从 dpkg 获取）"
        else
            log_info "无法获取 Jenkins 版本（未安装）"
        fi
    fi

    log_info "=========================================="
    if [ "$all_ok" = true ]; then
        log_success "所有检查通过"
    else
        log_warn "部分检查未通过，请查看上方详情"
    fi
    log_info "=========================================="
}

# ============================================
# cmd_show_password() — 获取初始管理员密码
# ============================================
cmd_show_password()
{
    log_info "=========================================="
    log_info "获取 Jenkins 初始管理员密码"
    log_info "=========================================="

    local jhome
    jhome="$(jenkins_home)"
    local password_file="${jhome}/secrets/initialAdminPassword"

    if [[ "$PLATFORM" == "macos" ]]; then
        if [ -f "$password_file" ]; then
            local password
            password=$(cat "$password_file")
            if [ -n "$password" ]; then
                log_success "初始管理员密码:"
                echo "$password"
            else
                log_error "密码文件为空: ${password_file}"
                exit 1
            fi
        else
            log_warn "初始密码文件不存在: ${password_file}"
            log_info "Jenkins home 检测路径: ${jhome}"
            log_info "可能已完成初始设置。如需重置密码，请使用:"
            log_info "  bash $0 reset-password <新密码>"
            exit 1
        fi
    else
        if sudo test -f "$password_file"; then
            local password
            password=$(sudo cat "$password_file")
            if [ -n "$password" ]; then
                log_success "初始管理员密码:"
                echo "$password"
            else
                log_error "密码文件为空: ${password_file}"
                exit 1
            fi
        else
            log_warn "初始密码文件不存在: ${password_file}"
            log_info "可能已完成初始设置。如需重置密码，请使用:"
            log_info "  bash $0 reset-password <新密码>"
            exit 1
        fi
    fi
}

# ============================================
# cmd_restart() — 重启 Jenkins 服务
# ============================================
cmd_restart()
{
    log_info "=========================================="
    log_info "重启 Jenkins 服务"
    log_info "=========================================="

    if [[ "$PLATFORM" == "macos" ]]; then
        brew services restart jenkins 2>/dev/null || {
            log_error "Jenkins 未通过 Homebrew 管理，无法重启"
            exit 1
        }
        log_info "Jenkins 服务已发送重启信号（brew services）"
    else
        sudo systemctl restart jenkins
        log_info "Jenkins 服务已发送重启信号"
    fi

    if ! wait_for_jenkins; then
        if [[ "$PLATFORM" == "macos" ]]; then
            log_error "Jenkins 重启失败，请检查日志: brew services log jenkins"
        else
            log_error "Jenkins 重启失败，请检查日志: sudo journalctl -u jenkins"
        fi
        exit 1
    fi

    log_success "=========================================="
    log_success "Jenkins 重启完成"
    log_success "=========================================="
    log_info "访问地址: http://localhost:${JENKINS_PORT}"
}

# ============================================
# cmd_upgrade() — 升级到最新 LTS
# ============================================
cmd_upgrade()
{
    log_info "=========================================="
    log_info "升级 Jenkins 到最新 LTS"
    log_info "=========================================="

    if [[ "$PLATFORM" == "macos" ]]; then
        # 步骤 1/3: 获取当前版本
        log_info "步骤 1/3: 获取当前版本"
        local old_version
        old_version=$(brew info jenkins --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['installed'][0]['version'])" 2>/dev/null || echo "未知")
        log_info "当前版本: ${old_version}"

        # 步骤 2/3: 升级
        log_info "步骤 2/3: 升级 Jenkins（brew upgrade）"
        brew upgrade jenkins

        # 步骤 3/3: 重启并验证
        log_info "步骤 3/3: 重启 Jenkins"
        brew services restart jenkins 2>/dev/null || true

        if ! wait_for_jenkins; then
            log_error "Jenkins 升级后启动失败，请检查日志: brew services log jenkins"
            exit 1
        fi

        local new_version
        new_version=$(brew info jenkins --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['installed'][0]['version'])" 2>/dev/null || echo "未知")
        log_success "=========================================="
        log_success "Jenkins 升级完成"
        log_success "=========================================="
        log_info "旧版本: ${old_version}"
        log_success "新版本: ${new_version}"
    else
        # 步骤 1/4: 获取当前版本
        log_info "步骤 1/4: 获取当前版本"
        local old_version
        old_version=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
        log_info "当前版本: ${old_version}"

        # 步骤 2/4: 升级包
        log_info "步骤 2/4: 升级 Jenkins 包"
        sudo apt update
        sudo apt install --only-upgrade jenkins

        # 步骤 3/4: 重启并等待就绪
        log_info "步骤 3/4: 重启 Jenkins"
        sudo systemctl restart jenkins

        if ! wait_for_jenkins; then
            log_error "Jenkins 升级后启动失败，请检查日志: sudo journalctl -u jenkins"
            exit 1
        fi

        # 步骤 4/4: 显示新版本
        log_info "步骤 4/4: 验证升级后版本"
        local new_version
        new_version=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
        log_success "=========================================="
        log_success "Jenkins 升级完成"
        log_success "=========================================="
        log_info "旧版本: ${old_version}"
        log_success "新版本: ${new_version}"
    fi
    log_info "访问地址: http://localhost:${JENKINS_PORT}"
}

# ============================================
# cmd_reset_password() — 重置管理员密码
# ============================================
# 参数：$2 = 新密码
# 返回：0=成功，1=失败
cmd_reset_password()
{
    log_info "=========================================="
    log_info "重置 Jenkins 管理员密码"
    log_info "=========================================="

    local new_password="${2:-}"
    if [ -z "$new_password" ]; then
        log_error "请提供新密码: bash $0 reset-password <新密码>"
        exit 1
    fi

    # 检查 Jenkins 是否运行
    if ! curl -sf "http://localhost:${JENKINS_PORT}/login" >/dev/null 2>&1; then
        log_error "Jenkins 未运行，请先启动"
        if [[ "$PLATFORM" == "macos" ]]; then
            log_info "macOS 启动命令: brew services start jenkins"
        else
            log_info "Linux 启动命令: sudo systemctl start jenkins"
        fi
        exit 1
    fi

    local jhome
    jhome="$(jenkins_home)"

    # 查找 jenkins-cli.jar
    local cli_jar=""
    local possible_paths=(
        "${jhome}/war/WEB-INF/jenkins-cli.jar"
        "${jhome}/jenkins-cli.jar"
        "/usr/share/jenkins/jenkins-cli.jar"
        "/usr/share/java/jenkins-cli.jar"
    )

    for path in "${possible_paths[@]}"; do
        if [[ "$PLATFORM" == "macos" ]]; then
            if [ -f "$path" ]; then
                cli_jar="$path"
                log_info "找到 jenkins-cli.jar: ${cli_jar}"
                break
            fi
        else
            if sudo test -f "$path"; then
                cli_jar="$path"
                log_info "找到 jenkins-cli.jar: ${cli_jar}"
                break
            fi
        fi
    done

    if [ -z "$cli_jar" ]; then
        log_error "未找到 jenkins-cli.jar，已检查以下路径:"
        for path in "${possible_paths[@]}"; do
            log_error "  ${path}"
        done
        log_info "请确认 Jenkins 安装路径或手动使用 Script Console 重置密码"
        exit 1
    fi

    # 创建临时 Groovy 脚本
    local groovy_script
    groovy_script=$(mktemp /tmp/reset-jenkins-password.groovy.XXXXXX)
    cat >"$groovy_script" <<GROOVY
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def realm = instance.getSecurityRealm()
def user = realm.getUser('admin')
if (user != null) {
    user.setPassword('${new_password}')
    instance.save()
    println 'Password reset successful'
} else {
    println 'ERROR: admin user not found'
    System.exit(1)
}
GROOVY

    log_info "执行密码重置..."

    # 使用 jenkins-cli.jar 执行 groovy 脚本
    local reset_output
    if [[ "$PLATFORM" == "macos" ]]; then
        reset_output=$(java -jar "$cli_jar" -s "http://localhost:${JENKINS_PORT}/" groovy <"$groovy_script" 2>&1) || {
            log_error "密码重置执行失败"
            log_error "输出: ${reset_output}"
            rm -f "$groovy_script"
            exit 1
        }
    else
        reset_output=$(sudo -u jenkins java -jar "$cli_jar" -s "http://localhost:${JENKINS_PORT}/" groovy <"$groovy_script" 2>&1) || {
            log_error "密码重置执行失败"
            log_error "输出: ${reset_output}"
            rm -f "$groovy_script"
            exit 1
        }
    fi

    # 清理临时脚本
    rm -f "$groovy_script"

    if echo "$reset_output" | grep -q "Password reset successful"; then
        log_success "=========================================="
        log_success "管理员密码重置成功"
        log_success "=========================================="
        log_info "请使用新密码登录: http://localhost:${JENKINS_PORT}"
    else
        log_error "密码重置可能失败，输出: ${reset_output}"
        exit 1
    fi
}

# ============================================
# cmd_apply_matrix_auth() — 通过 Jenkins CLI 执行权限矩阵 Groovy 脚本
# ============================================
# 查找 Java 可执行文件
find_java()
{
    if [[ "$PLATFORM" == "macos" ]]; then
        local brew_java="/opt/homebrew/opt/openjdk@21/bin/java"
        if [ -x "$brew_java" ]; then
            echo "$brew_java"
            return
        fi
    fi
    # Linux 或 fallback
    command -v java 2>/dev/null && return
    echo "java"
}

# 查找 jenkins-cli.jar
find_cli_jar()
{
    local jhome
    jhome="$(jenkins_home)"
    local possible_paths=(
        "${jhome}/war/WEB-INF/jenkins-cli.jar"
        "${jhome}/jenkins-cli.jar"
        "/usr/share/jenkins/jenkins-cli.jar"
        "/usr/share/java/jenkins-cli.jar"
    )
    # macOS: Homebrew Jenkins-LTS puts CLI jar alongside war
    if [[ "$PLATFORM" == "macos" ]]; then
        possible_paths=(
            "/opt/homebrew/opt/jenkins-lts/libexec/cli-"*.jar
            "${jhome}/war/WEB-INF/jenkins-cli.jar"
            "${jhome}/jenkins-cli.jar"
        )
    fi

    for path in "${possible_paths[@]}"; do
        # macOS runs as current user, Linux runs as jenkins (needs sudo)
        if [[ "$PLATFORM" == "macos" ]]; then
            if [ -f "$path" ]; then
                echo "$path"
                return
            fi
        else
            if sudo test -f "$path" 2>/dev/null; then
                echo "$path"
                return
            fi
        fi
    done
    return 1
}

# 加载管理员凭据
load_admin_credentials()
{
    local cred_file="$SCRIPT_DIR/jenkins/config/jenkins-admin.env"
    if [ ! -f "$cred_file" ]; then
        log_error "未找到凭据文件: ${cred_file}"
        log_error "请复制 jenkins-admin.env.example 为 jenkins-admin.env 并填写管理员凭据"
        exit 1
    fi
    source "$cred_file"
    if [[ -z "${JENKINS_ADMIN_USER:-}" || -z "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
        log_error "凭据文件中缺少 JENKINS_ADMIN_USER 或 JENKINS_ADMIN_PASSWORD"
        exit 1
    fi
    if [[ "$JENKINS_ADMIN_PASSWORD" == "CHANGE_ME_TO_A_STRONG_PASSWORD" ]]; then
        log_error "请先在 jenkins-admin.env 中设置实际密码或 API Token"
        exit 1
    fi
}

cmd_apply_matrix_auth()
{
    log_info "=========================================="
    log_info "应用 Jenkins 权限矩阵配置"
    log_info "=========================================="

    # macOS 不需要 root（Homebrew Jenkins 以当前用户运行）
    if [[ "$PLATFORM" != "macos" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "此命令需要 root 权限，请使用: sudo bash $0 apply-matrix-auth"
            exit 1
        fi
    fi

    # 加载管理员凭据
    load_admin_credentials

    # 检查 Jenkins 是否运行
    if ! curl -sf "http://localhost:${JENKINS_PORT}/login" >/dev/null 2>&1; then
        if [[ "$PLATFORM" == "macos" ]]; then
            log_error "Jenkins 未运行，请先启动: brew services start jenkins-lts"
        else
            log_error "Jenkins 未运行，请先启动: sudo systemctl start jenkins"
        fi
        exit 1
    fi

    # 检查 Groovy 脚本是否存在
    local groovy_script="$GROOVY_SRC_DIR/06-matrix-auth.groovy"
    if [ ! -f "$groovy_script" ]; then
        log_error "权限矩阵脚本不存在: ${groovy_script}"
        exit 1
    fi

    # 执行 Groovy 脚本（通过 REST API scriptText 端点）
    log_info "执行权限矩阵配置脚本..."
    local script_content
    script_content="$(cat "$groovy_script")"
    local apply_output
    apply_output=$(curl -sf "http://localhost:${JENKINS_PORT}/scriptText" \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        --data-urlencode "script=${script_content}" 2>&1) || {
        log_error "权限矩阵脚本执行失败"
        log_error "输出: ${apply_output}"
        exit 1
    }

    log_info "脚本输出:"
    echo "$apply_output"

    # 检查是否需要重启（插件首次安装）
    if echo "$apply_output" | grep -q "Restart required"; then
        log_warn "matrix-auth 插件已安装，需要重启 Jenkins 后再次执行此命令"
        if [[ "$PLATFORM" == "macos" ]]; then
            log_info "重启命令: brew services restart jenkins-lts && bash $0 apply-matrix-auth"
        else
            log_info "重启命令: sudo bash $0 restart && sudo bash $0 apply-matrix-auth"
        fi
    elif echo "$apply_output" | grep -q "Matrix authorization configured"; then
        log_success "=========================================="
        log_success "Jenkins 权限矩阵配置成功"
        log_success "=========================================="
        log_info "Admin:     Overall/Administer (全权限)"
        log_info "Developer: Overall/Read + Job/Read + Job/Build + Job/Discover + Run/Read + View/Read"
        log_warn "如果创建了 developer 用户，请通过 Jenkins UI 修改其初始密码"
    else
        log_warn "脚本执行完成，但未检测到预期的成功标志"
        log_info "请检查上方输出确认配置状态"
    fi
}

# ============================================
# cmd_verify_matrix_auth() — 验证 Jenkins 权限矩阵配置是否正确
# ============================================
cmd_verify_matrix_auth()
{
    log_info "=========================================="
    log_info "验证 Jenkins 权限矩阵配置"
    log_info "=========================================="

    # macOS 不需要 root（Homebrew Jenkins 以当前用户运行）
    if [[ "$PLATFORM" != "macos" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "此命令需要 root 权限，请使用: sudo bash $0 verify-matrix-auth"
            exit 1
        fi
    fi

    # 加载管理员凭据
    load_admin_credentials

    # 检查 Jenkins 是否运行
    if ! curl -sf "http://localhost:${JENKINS_PORT}/login" >/dev/null 2>&1; then
        if [[ "$PLATFORM" == "macos" ]]; then
            log_error "Jenkins 未运行，请先启动: brew services start jenkins-lts"
        else
            log_error "Jenkins 未运行，请先启动: sudo systemctl start jenkins"
        fi
        exit 1
    fi

    # 查找 jenkins-cli.jar
    local cli_jar
    cli_jar="$(find_cli_jar)" || {
        log_error "未找到 jenkins-cli.jar"
        exit 1
    }

    # 创建临时验证脚本
    local verify_script
    verify_script=$(mktemp /tmp/verify-matrix-auth.groovy.XXXXXX)
    cat >"$verify_script" <<'VERIFY_GROOVY'
import jenkins.model.*
import hudson.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def strategy = instance.getAuthorizationStrategy()
def allPassed = true
def isMatrix = strategy.getClass().getSimpleName() == 'GlobalMatrixAuthorizationStrategy'

// 检查 1: 权限策略类型为 GlobalMatrixAuthorizationStrategy
if (isMatrix) {
    println '[PASS] Authorization strategy: GlobalMatrixAuthorizationStrategy'
} else {
    println '[FAIL] Authorization strategy: ' + strategy.getClass().getSimpleName() + ' (expected GlobalMatrixAuthorizationStrategy)'
    allPassed = false
}

// 检查 2: admin 拥有 Jenkins.ADMINISTER
if (isMatrix) {
    def adminPerms = strategy.getGrantedPermissions().get(Jenkins.ADMINISTER) ?: []
    if (adminPerms.contains('admin')) {
        println '[PASS] admin has Overall/Administer'
    } else {
        println '[FAIL] admin missing Overall/Administer (found: ' + adminPerms + ')'
        allPassed = false
    }
}

// 检查 3: developer 拥有 Item.BUILD
if (isMatrix) {
    def buildPerms = strategy.getGrantedPermissions().get(Item.BUILD) ?: []
    if (buildPerms.contains('developer')) {
        println '[PASS] developer has Job/Build'
    } else {
        println '[FAIL] developer missing Job/Build (found: ' + buildPerms + ')'
        allPassed = false
    }
}

// 检查 4: developer 拥有 Item.READ
if (isMatrix) {
    def readPerms = strategy.getGrantedPermissions().get(Item.READ) ?: []
    if (readPerms.contains('developer')) {
        println '[PASS] developer has Job/Read'
    } else {
        println '[FAIL] developer missing Job/Read (found: ' + readPerms + ')'
        allPassed = false
    }
}

// 检查 5: developer 拥有 Jenkins.READ
if (isMatrix) {
    def overallRead = strategy.getGrantedPermissions().get(Jenkins.READ) ?: []
    if (overallRead.contains('developer')) {
        println '[PASS] developer has Overall/Read'
    } else {
        println '[FAIL] developer missing Overall/Read (found: ' + overallRead + ')'
        allPassed = false
    }
}

// 检查 7: developer 没有 Item.CONFIGURE
if (isMatrix) {
    def configPerms = strategy.getGrantedPermissions().get(Item.CONFIGURE) ?: []
    if (!configPerms.contains('developer')) {
        println '[PASS] developer does NOT have Job/Configure (correct)'
    } else {
        println '[FAIL] developer has Job/Configure (should not)'
        allPassed = false
    }
}

if (allPassed) {
    println ''
    println 'All matrix authorization checks PASSED'
} else {
    println ''
    println 'Some matrix authorization checks FAILED'
}
VERIFY_GROOVY

    # 执行验证脚本（通过 REST API scriptText 端点）
    local verify_output
    local script_content
    script_content="$(cat "$verify_script")"
    verify_output=$(curl -sf "http://localhost:${JENKINS_PORT}/scriptText" \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        --data-urlencode "script=${script_content}" 2>&1)
    local verify_exit=$?

    # 清理临时脚本
    rm -f "$verify_script"

    echo "$verify_output"

    # 检查输出中是否包含 FAILED
    if echo "$verify_output" | grep -q '\[FAIL\]'; then
        verify_exit=1
    fi

    if [ $verify_exit -eq 0 ]; then
        log_success "=========================================="
        log_success "Jenkins 权限矩阵验证通过"
        log_success "=========================================="
    else
        log_error "=========================================="
        log_error "Jenkins 权限矩阵验证失败"
        log_error "=========================================="
        exit 1
    fi
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    install) cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    status) cmd_status "$@" ;;
    show-password) cmd_show_password "$@" ;;
    restart) cmd_restart "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    reset-password) cmd_reset_password "$@" ;;
    apply-matrix-auth) cmd_apply_matrix_auth "$@" ;;
    verify-matrix-auth) cmd_verify_matrix_auth "$@" ;;
    *) usage && exit 1 ;;
esac
