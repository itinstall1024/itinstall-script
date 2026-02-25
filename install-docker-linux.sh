#!/bin/bash

################################################################################
# Docker 一键安装脚本 for Linux
# 
# 功能说明：
# 1. 自动检测Linux发行版和版本
# 2. 检测系统架构（x86_64/ARM64）
# 3. 检测并处理已安装的Docker
# 4. 支持自定义Docker版本安装
# 5. 自动配置国内镜像加速
# 6. 完整的错误处理和日志记录
# 7. 安装后验证和测试
#
# 使用方法：
#   sudo bash install-docker-linux.sh              # 安装默认版本
#   sudo bash install-docker-linux.sh --version 24.0.7  # 安装指定版本
#   sudo bash install-docker-linux.sh --help       # 查看帮助
#
# 作者：itinstall.dev
# 版本：1.0.0
# 日期：2026-02-16
################################################################################

set -e  # 遇到错误立即退出
set -o pipefail  # 管道命令中任何一个失败都返回失败

################################################################################
# 全局变量配置
################################################################################

# 颜色定义（用于美化输出）
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# Docker默认版本（可通过参数覆盖）
DOCKER_VERSION="27.5.0"  # Docker最新稳定版
VERSION_FROM_CLI=false    # 是否通过CLI参数指定了版本

# Docker Compose默认版本（供参考，实际由docker-compose-plugin包决定）
# DOCKER_COMPOSE_VERSION="2.24.0"

# 安装选项
INSTALL_COMPOSE=true  # 是否安装Docker Compose
USE_MIRROR=true       # 是否使用国内镜像
AUTO_START=true       # 是否设置开机自启

# 日志文件路径
LOG_DIR="/var/log/docker-install"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

# 系统信息变量
OS_TYPE=""
OS_VERSION=""
OS_ARCH=""
PACKAGE_MANAGER=""

################################################################################
# 工具函数：日志和输出
################################################################################

# 初始化日志目录
init_log() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {
            echo "警告: 无法创建日志目录，日志将仅输出到终端"
            LOG_FILE="/dev/null"
        }
    fi
}

# 打印信息日志（绿色）
log_info() {
    local msg
    msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${COLOR_GREEN}${msg}${COLOR_RESET}"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# 打印警告日志（黄色）
log_warn() {
    local msg
    msg="[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${COLOR_YELLOW}${msg}${COLOR_RESET}"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# 打印错误日志（红色）
log_error() {
    local msg
    msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${COLOR_RED}${msg}${COLOR_RESET}" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# 打印步骤标题（蓝色）
log_step() {
    local msg="[STEP] $1"
    echo -e "\n${COLOR_BLUE}==================== ${msg} ====================${COLOR_RESET}\n"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# 打印成功信息
log_success() {
    local msg="✓ $1"
    echo -e "${COLOR_GREEN}${msg}${COLOR_RESET}"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

################################################################################
# 工具函数：错误处理
################################################################################

# 错误处理函数
handle_error() {
    local line_no=$1
    local error_code=$2
    
    log_error "脚本在第 ${line_no} 行执行失败，退出码: ${error_code}"
    log_error "请查看日志文件获取详细信息: ${LOG_FILE}"
    
    # 根据错误类型给出建议
    case $error_code in
        1)
            log_error "解决方案: 请检查网络连接或使用代理"
            ;;
        2)
            log_error "解决方案: 请确保以root权限运行此脚本"
            ;;
        126)
            log_error "解决方案: 命令无法执行，检查文件权限"
            ;;
        127)
            log_error "解决方案: 命令未找到，检查PATH环境变量"
            ;;
        *)
            log_error "解决方案: 请查看上方详细错误信息"
            ;;
    esac
    
    # 回滚操作
    log_warn "执行清理操作..."
    cleanup_on_error
    
    exit "$error_code"
}

# 设置错误陷阱
trap 'handle_error ${LINENO} $?' ERR

# 清理函数（安装失败时调用）
cleanup_on_error() {
    log_warn "清理未完成的安装..."
    
    # 停止Docker服务（如果已启动）
    if systemctl is-active --quiet docker 2>/dev/null; then
        log_warn "停止Docker服务..."
        systemctl stop docker || true
    fi
    
    # 这里不自动删除已安装的包，因为可能是更新失败
    # 让用户手动决定是否卸载
    log_info "清理完成。如需完全卸载，请手动运行卸载命令"
}

################################################################################
# 工具函数：检查和验证
################################################################################

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        log_error "请使用: sudo bash $0"
        exit 2
    fi
    log_success "权限检查通过"
}

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    
    local test_urls=(
        "www.baidu.com"
        "www.google.com"
        "8.8.8.8"
    )
    
    local network_ok=false
    for url in "${test_urls[@]}"; do
        if ping -c 1 -W 3 "$url" &>/dev/null; then
            network_ok=true
            break
        fi
    done
    
    if [[ "$network_ok" == false ]]; then
        log_error "网络连接失败，无法访问外部网络"
        log_error "解决方案："
        log_error "  1. 检查网络连接是否正常"
        log_error "  2. 检查防火墙设置"
        log_error "  3. 如在内网环境，请配置HTTP代理"
        log_error "     export http_proxy=http://proxy.example.com:8080"
        log_error "     export https_proxy=http://proxy.example.com:8080"
        exit 1
    fi
    
    log_success "网络连接正常"
}

# 检查磁盘空间
check_disk_space() {
    log_info "检查磁盘空间..."
    
    # 检查根目录可用空间（至少需要5GB）
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=$((5 * 1024 * 1024))  # 5GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        log_error "磁盘空间不足"
        log_error "可用空间: $(echo "scale=2; $available_space/1024/1024" | bc)GB"
        log_error "所需空间: 至少 5GB"
        log_error "解决方案: 请清理磁盘空间后重试"
        exit 1
    fi
    
    log_success "磁盘空间充足 (可用: $(echo "scale=2; $available_space/1024/1024" | bc)GB)"
}

# 检测系统信息
detect_system() {
    log_step "检测系统信息"
    
    # 检测架构
    OS_ARCH=$(uname -m)
    case "$OS_ARCH" in
        x86_64)
            log_info "系统架构: x86_64 (AMD64)"
            ;;
        aarch64|arm64)
            log_info "系统架构: ARM64"
            OS_ARCH="aarch64"
            ;;
        armv7l)
            log_info "系统架构: ARMv7"
            ;;
        *)
            log_error "不支持的系统架构: $OS_ARCH"
            log_error "Docker仅支持: x86_64, ARM64, ARMv7"
            exit 1
            ;;
    esac
    
    # 检测Linux发行版
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_TYPE=$ID
        OS_VERSION=$VERSION_ID
        
        log_info "操作系统: $NAME"
        log_info "版本: $VERSION"
        
        # 确定包管理器
        case "$OS_TYPE" in
            ubuntu|debian)
                PACKAGE_MANAGER="apt"
                ;;
            centos|rhel|rocky|almalinux)
                PACKAGE_MANAGER="yum"
                ;;
            fedora)
                PACKAGE_MANAGER="dnf"
                ;;
            arch|manjaro)
                PACKAGE_MANAGER="pacman"
                log_error "Arch Linux用户建议直接使用: sudo pacman -S docker"
                exit 1
                ;;
            *)
                log_error "不支持的Linux发行版: $OS_TYPE"
                log_error "当前支持: Ubuntu, Debian, CentOS, RHEL, Rocky Linux, Fedora"
                exit 1
                ;;
        esac
        
        log_success "系统检测完成: $OS_TYPE $OS_VERSION ($OS_ARCH)"
    else
        log_error "无法检测Linux发行版（缺少 /etc/os-release 文件）"
        exit 1
    fi
}

################################################################################
# Docker检测和卸载函数
################################################################################

# 检测已安装的Docker
check_existing_docker() {
    log_step "检查现有Docker安装"
    
    local docker_found=false
    local docker_version=""
    local docker_packages=()
    
    # 检查Docker命令是否存在
    if command -v docker &>/dev/null; then
        docker_found=true
        docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "未知")
        log_warn "检测到已安装的Docker"
        log_info "当前Docker版本: $docker_version"
        log_info "Docker路径: $(which docker)"
    fi
    
    # 检查Docker包（根据不同的包管理器）
    case "$PACKAGE_MANAGER" in
        apt)
            # Ubuntu/Debian可能安装的Docker包
            local apt_packages=(
                "docker"
                "docker-engine"
                "docker.io"
                "docker-ce"
                "docker-ce-cli"
                "containerd.io"
                "docker-compose-plugin"
            )
            
            for pkg in "${apt_packages[@]}"; do
                if dpkg -l | grep -q "^ii.*$pkg"; then
                    docker_packages+=("$pkg")
                fi
            done
            ;;
            
        yum|dnf)
            # CentOS/RHEL/Fedora可能安装的Docker包
            local rpm_packages=(
                "docker"
                "docker-engine"
                "docker-ce"
                "docker-ce-cli"
                "containerd.io"
                "docker-compose-plugin"
            )
            
            for pkg in "${rpm_packages[@]}"; do
                if rpm -qa | grep -q "^${pkg}"; then
                    docker_packages+=("$pkg")
                fi
            done
            ;;
    esac
    
    # 如果发现Docker，询问用户如何处理
    if [[ "$docker_found" == true ]] || [[ ${#docker_packages[@]} -gt 0 ]]; then
        echo ""
        log_warn "=========================================="
        log_warn "检测到系统已安装Docker"
        log_warn "=========================================="
        
        if [[ "$docker_found" == true ]]; then
            echo -e "${COLOR_YELLOW}当前版本: $docker_version${COLOR_RESET}"
        fi
        
        if [[ ${#docker_packages[@]} -gt 0 ]]; then
            echo -e "${COLOR_YELLOW}已安装的包:${COLOR_RESET}"
            for pkg in "${docker_packages[@]}"; do
                echo "  - $pkg"
            done
        fi
        
        echo ""
        echo "请选择操作："
        echo "  1) 卸载现有Docker并重新安装 (推荐)"
        echo "  2) 跳过安装，保持现有版本"
        echo "  3) 仅升级到指定版本"
        echo "  4) 退出脚本"
        echo ""
        
        local choice
        read -p "请输入选项 [1-4]: " choice
        
        case "$choice" in
            1)
                log_info "用户选择: 卸载并重新安装"
                uninstall_existing_docker "${docker_packages[@]}"
                return 0
                ;;
            2)
                log_info "用户选择: 跳过安装"
                log_success "保持现有Docker版本: $docker_version"
                exit 0
                ;;
            3)
                log_info "用户选择: 升级Docker"
                # 继续安装流程，不卸载
                return 0
                ;;
            4)
                log_info "用户选择: 退出脚本"
                exit 0
                ;;
            *)
                log_error "无效的选项，退出脚本"
                exit 1
                ;;
        esac
    else
        log_success "系统未安装Docker，可以开始全新安装"
    fi
}

# 卸载现有Docker
uninstall_existing_docker() {
    local packages=("$@")
    
    log_step "卸载现有Docker"
    
    # 停止Docker服务（先停socket，防止socket激活导致服务重启）
    log_info "停止Docker服务..."
    for svc in docker.socket docker containerd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" || log_warn "停止 $svc 服务失败"
        fi
    done
    
    # 询问是否保留数据
    echo ""
    read -p "是否保留Docker镜像和容器数据? [y/N]: " keep_data
    keep_data=${keep_data:-n}
    
    # 卸载Docker包
    log_info "卸载Docker软件包..."
    case "$PACKAGE_MANAGER" in
        apt)
            apt-get purge -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "卸载失败"
                exit 1
            }
            apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE"
            ;;
            
        yum)
            yum remove -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "卸载失败"
                exit 1
            }
            ;;
            
        dnf)
            dnf remove -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "卸载失败"
                exit 1
            }
            ;;
    esac
    
    # 清理数据（如果用户选择不保留）
    if [[ "$keep_data" =~ ^[Nn]$ ]]; then
        log_warn "清理Docker数据目录..."
        
        # 备份配置文件（以防万一）
        if [[ -f /etc/docker/daemon.json ]]; then
            cp /etc/docker/daemon.json "/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)" || true
            log_info "已备份 daemon.json 配置文件"
        fi
        
        # 删除数据目录
        rm -rf /var/lib/docker || log_warn "删除 /var/lib/docker 失败"
        rm -rf /var/lib/containerd || log_warn "删除 /var/lib/containerd 失败"
        rm -rf /etc/docker || log_warn "删除 /etc/docker 失败"
        rm -rf /var/run/docker.sock || log_warn "删除 docker.sock 失败"
        
        log_success "Docker数据已清理"
    else
        log_info "保留Docker数据，升级后仍可使用现有镜像和容器"
    fi
    
    log_success "卸载完成"
}

################################################################################
# 版本选择函数
################################################################################

# 让用户选择Docker版本
select_docker_version() {
    log_step "选择Docker版本"

    # 如果用户已通过CLI参数指定了版本，直接使用，跳过交互
    if [[ "$VERSION_FROM_CLI" == true ]]; then
        log_info "使用命令行指定版本: $DOCKER_VERSION"
        # 仍然询问是否安装Compose
        echo ""
        read -p "是否安装Docker Compose? [Y/n]: " install_compose
        install_compose=${install_compose:-y}
        if [[ "$install_compose" =~ ^[Yy]$ ]]; then
            INSTALL_COMPOSE=true
            log_info "将同时安装Docker Compose"
        else
            INSTALL_COMPOSE=false
            log_info "跳过Docker Compose安装"
        fi
        return 0
    fi

    echo ""
    echo "当前默认版本: ${COLOR_GREEN}${DOCKER_VERSION}${COLOR_RESET}"
    echo ""
    echo "常用Docker版本："
    echo "  - 27.5.0 (推荐，最新稳定版)"
    echo "  - 26.1.0"
    echo "  - 25.0.0"
    echo "  - 24.0.9"
    echo "  - 23.0.6"
    echo ""
    
    read -p "是否使用默认版本 ${DOCKER_VERSION}? [Y/n]: " use_default
    use_default=${use_default:-y}
    
    if [[ ! "$use_default" =~ ^[Yy]$ ]]; then
        read -p "请输入要安装的Docker版本号 (例如: 24.0.7): " custom_version
        
        if [[ -n "$custom_version" ]]; then
            # 简单验证版本号格式
            if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                DOCKER_VERSION="$custom_version"
                log_info "将安装Docker版本: $DOCKER_VERSION"
            else
                log_error "无效的版本号格式，应该类似: 24.0.7"
                exit 1
            fi
        else
            log_info "使用默认版本: $DOCKER_VERSION"
        fi
    else
        log_info "使用默认版本: $DOCKER_VERSION"
    fi
    
    # 询问是否安装Docker Compose
    echo ""
    read -p "是否安装Docker Compose? [Y/n]: " install_compose
    install_compose=${install_compose:-y}
    
    if [[ "$install_compose" =~ ^[Yy]$ ]]; then
        INSTALL_COMPOSE=true
        log_info "将同时安装Docker Compose"
    else
        INSTALL_COMPOSE=false
        log_info "跳过Docker Compose安装"
    fi
}

################################################################################
# 安装前准备函数
################################################################################

# 更新系统软件包索引
update_package_index() {
    log_step "更新软件包索引"
    
    case "$PACKAGE_MANAGER" in
        apt)
            log_info "执行: apt-get update"
            apt-get update 2>&1 | tee -a "$LOG_FILE" || {
                log_error "apt-get update 失败"
                log_error "解决方案："
                log_error "  1. 检查 /etc/apt/sources.list 配置是否正确"
                log_error "  2. 检查网络连接"
                log_error "  3. 尝试: apt-get update --fix-missing"
                exit 1
            }
            ;;
            
        yum)
            log_info "执行: yum makecache"
            yum makecache 2>&1 | tee -a "$LOG_FILE" || {
                log_error "yum makecache 失败"
                exit 1
            }
            ;;
            
        dnf)
            log_info "执行: dnf makecache"
            dnf makecache 2>&1 | tee -a "$LOG_FILE" || {
                log_error "dnf makecache 失败"
                exit 1
            }
            ;;
    esac
    
    log_success "软件包索引更新完成"
}

# 安装必要的依赖包
install_dependencies() {
    log_step "安装系统依赖"
    
    case "$PACKAGE_MANAGER" in
        apt)
            local deps=(
                "ca-certificates"
                "curl"
                "gnupg"
                "lsb-release"
                "apt-transport-https"
                "software-properties-common"
            )
            
            log_info "安装依赖包: ${deps[*]}"
            apt-get install -y "${deps[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "依赖包安装失败"
                log_error "解决方案："
                log_error "  1. 手动执行: apt-get install -y ${deps[*]}"
                log_error "  2. 检查软件源配置"
                exit 1
            }
            ;;
            
        yum)
            local deps=(
                "yum-utils"
                "device-mapper-persistent-data"
                "lvm2"
            )
            
            log_info "安装依赖包: ${deps[*]}"
            yum install -y "${deps[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "依赖包安装失败"
                exit 1
            }
            ;;
            
        dnf)
            local deps=(
                "dnf-plugins-core"
            )
            
            log_info "安装依赖包: ${deps[*]}"
            dnf install -y "${deps[@]}" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "依赖包安装失败"
                exit 1
            }
            ;;
    esac
    
    log_success "系统依赖安装完成"
}

################################################################################
# Docker安装函数
################################################################################

# 添加Docker官方GPG密钥
add_docker_gpg_key() {
    log_step "添加Docker官方GPG密钥"
    
    case "$PACKAGE_MANAGER" in
        apt)
            # 创建密钥目录
            mkdir -p /etc/apt/keyrings
            
            # 选择下载源（国内或官方）
            if [[ "$USE_MIRROR" == true ]]; then
                log_info "使用阿里云镜像下载GPG密钥"
                local key_url="https://mirrors.aliyun.com/docker-ce/linux/$OS_TYPE/gpg"
            else
                log_info "使用Docker官方源下载GPG密钥"
                local key_url="https://download.docker.com/linux/$OS_TYPE/gpg"
            fi
            
            # 下载并添加GPG密钥
            curl -fsSL "$key_url" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>&1 | tee -a "$LOG_FILE" || {
                log_error "GPG密钥下载失败"
                log_error "解决方案："
                log_error "  1. 检查网络连接"
                log_error "  2. 尝试使用代理"
                log_error "  3. 手动下载密钥: curl -fsSL $key_url"
                exit 1
            }
            
            chmod a+r /etc/apt/keyrings/docker.gpg
            log_success "GPG密钥添加成功"
            ;;
            
        yum|dnf)
            if [[ "$USE_MIRROR" == true ]]; then
                log_info "使用阿里云镜像"
            else
                log_info "使用Docker官方源"
            fi
            # yum/dnf的GPG密钥会在添加仓库时自动导入
            ;;
    esac
}

# 添加Docker软件源
add_docker_repository() {
    log_step "添加Docker软件仓库"
    
    case "$PACKAGE_MANAGER" in
        apt)
            # 构建软件源地址
            if [[ "$USE_MIRROR" == true ]]; then
                local repo_url="https://mirrors.aliyun.com/docker-ce/linux/$OS_TYPE"
            else
                local repo_url="https://download.docker.com/linux/$OS_TYPE"
            fi
            
            # 添加Docker仓库
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $repo_url \
                $(lsb_release -cs) stable" | \
                tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            log_info "Docker仓库配置文件: /etc/apt/sources.list.d/docker.list"
            
            # 更新包索引
            log_info "更新软件包索引..."
            apt-get update 2>&1 | tee -a "$LOG_FILE" || {
                log_error "更新包索引失败"
                exit 1
            }
            
            log_success "Docker仓库添加成功"
            ;;
            
        yum)
            # 添加Docker-CE仓库
            if [[ "$USE_MIRROR" == true ]]; then
                yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo 2>&1 | tee -a "$LOG_FILE" || {
                    log_error "添加仓库失败"
                    exit 1
                }
            else
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>&1 | tee -a "$LOG_FILE" || {
                    log_error "添加仓库失败"
                    exit 1
                }
            fi
            
            log_success "Docker仓库添加成功"
            ;;
            
        dnf)
            # 添加Docker-CE仓库
            if [[ "$USE_MIRROR" == true ]]; then
                dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/fedora/docker-ce.repo 2>&1 | tee -a "$LOG_FILE" || {
                    log_error "添加仓库失败"
                    exit 1
                }
            else
                dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>&1 | tee -a "$LOG_FILE" || {
                    log_error "添加仓库失败"
                    exit 1
                }
            fi
            
            log_success "Docker仓库添加成功"
            ;;
    esac
}

# 安装Docker Engine
install_docker_engine() {
    log_step "安装Docker Engine"
    
    log_info "准备安装Docker版本: $DOCKER_VERSION"
    
    # 构建可选包列表（根据INSTALL_COMPOSE决定是否包含compose插件）
    local compose_pkgs=()
    if [[ "$INSTALL_COMPOSE" == true ]]; then
        compose_pkgs=("docker-buildx-plugin" "docker-compose-plugin")
    else
        compose_pkgs=("docker-buildx-plugin")
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            # 查询可用的Docker版本
            log_info "查询可用的Docker版本..."
            apt-cache madison docker-ce | head -10 | tee -a "$LOG_FILE"

            # 现代Docker的APT版本字符串格式为: 5:VERSION-1~distro.osver~codename
            # 例如: 5:27.5.0-1~ubuntu.24.04~noble
            # 从 apt-cache madison 输出中找匹配版本号的完整版本字符串
            local full_version_string
            full_version_string=$(apt-cache madison docker-ce 2>/dev/null | \
                grep -m1 "${DOCKER_VERSION}" | awk '{print $3}')

            log_info "开始安装Docker..."
            if [[ -n "$full_version_string" ]]; then
                log_info "找到版本: $full_version_string"
                apt-get install -y \
                    docker-ce="${full_version_string}" \
                    docker-ce-cli="${full_version_string}" \
                    containerd.io \
                    "${compose_pkgs[@]}" \
                    2>&1 | tee -a "$LOG_FILE" || {
                        log_error "Docker安装失败"
                        log_error "解决方案："
                        log_error "  1. 查看可用版本: apt-cache madison docker-ce"
                        log_error "  2. 检查版本号是否正确"
                        exit 1
                    }
            else
                log_warn "未找到版本 $DOCKER_VERSION，安装最新可用版本"
                apt-get install -y \
                    docker-ce \
                    docker-ce-cli \
                    containerd.io \
                    "${compose_pkgs[@]}" \
                    2>&1 | tee -a "$LOG_FILE" || {
                        log_error "Docker安装失败"
                        exit 1
                    }
            fi
            ;;

        yum|dnf)
            local cmd=$PACKAGE_MANAGER

            # 查询可用版本
            log_info "查询可用的Docker版本..."
            $cmd list docker-ce --showduplicates | sort -r | head -10 | tee -a "$LOG_FILE"

            # 根据OS类型构建版本字符串
            # RHEL/CentOS/Rocky: VERSION-1.el{major}；Fedora: VERSION-1.fc{major}
            local rpm_release
            local version_string
            if [[ "$OS_TYPE" == "fedora" ]]; then
                rpm_release=$(rpm -E '%{fedora}')   # 单引号防止shell展开%{}
                version_string="${DOCKER_VERSION}-1.fc${rpm_release}"
            else
                rpm_release=$(rpm -E '%{rhel}')     # 单引号防止shell展开%{}
                version_string="${DOCKER_VERSION}-1.el${rpm_release}"
            fi

            log_info "开始安装Docker..."
            if $cmd list docker-ce --showduplicates 2>/dev/null | grep -q "$version_string"; then
                $cmd install -y \
                    "docker-ce-${version_string}" \
                    "docker-ce-cli-${version_string}" \
                    containerd.io \
                    "${compose_pkgs[@]}" \
                    2>&1 | tee -a "$LOG_FILE" || {
                        log_error "Docker安装失败"
                        exit 1
                    }
            else
                log_warn "未找到版本 $DOCKER_VERSION，安装最新可用版本"
                $cmd install -y \
                    docker-ce \
                    docker-ce-cli \
                    containerd.io \
                    "${compose_pkgs[@]}" \
                    2>&1 | tee -a "$LOG_FILE" || {
                        log_error "Docker安装失败"
                        exit 1
                    }
            fi
            ;;
    esac
    
    log_success "Docker Engine 安装完成"
}

################################################################################
# Docker配置函数
################################################################################

# 配置Docker镜像加速器
configure_docker_daemon() {
    log_step "配置Docker守护进程"
    
    # 创建配置目录
    mkdir -p /etc/docker
    
    # 构建daemon.json配置
    log_info "创建Docker配置文件: /etc/docker/daemon.json"
    
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.rainbond.cc",
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://dockerhub.icu",
    "https://docker.chenby.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "max-concurrent-downloads": 10
}
EOF
    
    log_info "配置说明："
    log_info "  - 镜像加速器: 使用国内多个镜像源"
    log_info "  - 日志限制: 单文件最大100MB，保留3个文件"
    log_info "  - 存储驱动: overlay2（推荐）"
    log_info "  - 实时恢复: 启用（容器在Docker重启后继续运行）"
    
    log_success "Docker配置文件创建完成"
}

# 配置用户权限（添加到docker组）
configure_user_permissions() {
    log_step "配置用户权限"
    
    # 获取当前实际用户（即使使用sudo也能获取）
    local real_user=${SUDO_USER:-$USER}
    
    if [[ "$real_user" != "root" ]] && [[ -n "$real_user" ]]; then
        log_info "添加用户 $real_user 到 docker 组"
        
        # 添加用户到docker组
        usermod -aG docker "$real_user" 2>&1 | tee -a "$LOG_FILE" || {
            log_warn "添加用户到docker组失败"
            log_warn "您可能需要手动执行: sudo usermod -aG docker $real_user"
        }
        
        log_success "用户权限配置完成"
        log_warn "注意: 需要重新登录或执行 'newgrp docker' 才能生效"
    else
        log_info "当前用户为root，跳过用户权限配置"
    fi
}

################################################################################
# Docker服务管理函数
################################################################################

# 启动Docker服务
start_docker_service() {
    log_step "启动Docker服务"
    
    # 重新加载systemd配置
    log_info "重新加载systemd配置..."
    systemctl daemon-reload
    
    # 启动Docker服务
    log_info "启动Docker服务..."
    systemctl start docker 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Docker服务启动失败"
        log_error "解决方案："
        log_error "  1. 查看详细日志: journalctl -xeu docker.service"
        log_error "  2. 检查配置文件: /etc/docker/daemon.json"
        log_error "  3. 尝试手动启动: systemctl start docker"
        exit 1
    }
    
    # 检查服务状态
    sleep 2
    if systemctl is-active --quiet docker; then
        log_success "Docker服务已启动"
    else
        log_error "Docker服务启动失败"
        log_error "查看状态: systemctl status docker"
        exit 1
    fi
    
    # 设置开机自启
    if [[ "$AUTO_START" == true ]]; then
        log_info "设置Docker服务开机自启..."
        systemctl enable docker 2>&1 | tee -a "$LOG_FILE"
        log_success "Docker已设置为开机自启"
    fi
}

################################################################################
# 安装验证函数
################################################################################

# 验证Docker安装
verify_docker_installation() {
    log_step "验证Docker安装"
    
    # 1. 检查Docker命令
    log_info "检查Docker命令..."
    if ! command -v docker &>/dev/null; then
        log_error "Docker命令未找到"
        log_error "解决方案："
        log_error "  1. 检查PATH环境变量"
        log_error "  2. 重新登录shell"
        exit 1
    fi
    log_success "✓ Docker命令可用"
    
    # 2. 检查Docker版本
    log_info "检查Docker版本..."
    local installed_version
    installed_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    log_info "已安装的Docker版本: $installed_version"
    log_success "✓ Docker版本检查通过"
    
    # 3. 检查Docker服务状态
    log_info "检查Docker服务状态..."
    if systemctl is-active --quiet docker; then
        log_success "✓ Docker服务运行中"
    else
        log_error "Docker服务未运行"
        exit 1
    fi
    
    # 4. 检查Docker信息
    log_info "检查Docker系统信息..."
    docker info > /tmp/docker_info.txt 2>&1 || {
        log_error "无法获取Docker信息"
        log_error "查看详细日志: cat /tmp/docker_info.txt"
        exit 1
    }
    log_success "✓ Docker系统信息正常"
    
    # 5. 运行测试容器
    log_info "运行测试容器 (hello-world)..."
    if docker run --rm hello-world 2>&1 | tee -a "$LOG_FILE" | grep -q "Hello from Docker"; then
        log_success "✓ Docker容器运行测试通过"
    else
        log_error "Docker容器运行测试失败"
        log_error "解决方案："
        log_error "  1. 检查网络连接"
        log_error "  2. 检查镜像加速器配置"
        log_error "  3. 手动运行: docker run hello-world"
        exit 1
    fi
    
    # 6. 检查Docker Compose（如果已安装）
    if [[ "$INSTALL_COMPOSE" == true ]]; then
        log_info "检查Docker Compose..."
        if docker compose version &>/dev/null; then
            local compose_version
            compose_version=$(docker compose version --short)
            log_info "Docker Compose版本: $compose_version"
            log_success "✓ Docker Compose 可用"
        else
            log_warn "Docker Compose不可用（非致命错误）"
        fi
    fi
    
    log_success "所有验证检查通过！"
}

################################################################################
# 安装总结和后续步骤
################################################################################

# 显示安装总结
show_installation_summary() {
    log_step "安装总结"
    
    local installed_version
    installed_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)

    echo ""
    echo "=========================================="
    echo "  Docker 安装成功！"
    echo "=========================================="
    echo ""
    echo "安装信息："
    echo "  Docker版本: $installed_version"
    echo "  安装时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  系统: $OS_TYPE $OS_VERSION ($OS_ARCH)"
    echo "  日志文件: $LOG_FILE"
    echo ""
    
    if [[ "$INSTALL_COMPOSE" == true ]]; then
        local compose_version
        compose_version=$(docker compose version --short 2>/dev/null || echo "已安装")
        echo "  Docker Compose: $compose_version"
        echo ""
    fi
    
    echo "配置信息："
    echo "  配置文件: /etc/docker/daemon.json"
    echo "  数据目录: /var/lib/docker"
    echo "  镜像加速: 已启用（国内多镜像源）"
    echo "  开机自启: $(systemctl is-enabled docker 2>/dev/null || echo '未设置')"
    echo ""
    
    # 获取当前用户
    local real_user=${SUDO_USER:-$USER}
    
    echo "=========================================="
    echo "  后续步骤"
    echo "=========================================="
    echo ""
    echo "1. 重新登录以使docker组权限生效："
    if [[ "$real_user" != "root" ]]; then
        echo "   - 退出并重新登录，或执行: newgrp docker"
    fi
    echo ""
    echo "2. 验证Docker安装："
    echo "   docker --version"
    echo "   docker run hello-world"
    echo ""
    echo "3. 查看Docker信息："
    echo "   docker info"
    echo ""
    echo "4. 常用Docker命令："
    echo "   docker ps              # 查看运行中的容器"
    echo "   docker images          # 查看镜像列表"
    echo "   docker pull <image>    # 拉取镜像"
    echo "   docker run <image>     # 运行容器"
    echo ""
    
    if [[ "$INSTALL_COMPOSE" == true ]]; then
        echo "5. Docker Compose命令："
        echo "   docker compose up      # 启动服务"
        echo "   docker compose down    # 停止服务"
        echo "   docker compose ps      # 查看服务状态"
        echo ""
    fi
    
    echo "6. 管理Docker服务："
    echo "   sudo systemctl start docker    # 启动Docker"
    echo "   sudo systemctl stop docker     # 停止Docker"
    echo "   sudo systemctl restart docker  # 重启Docker"
    echo "   sudo systemctl status docker   # 查看状态"
    echo ""
    
    echo "7. 卸载Docker（如需要）："
    case "$PACKAGE_MANAGER" in
        apt)
            echo "   sudo apt-get purge docker-ce docker-ce-cli containerd.io"
            echo "   sudo rm -rf /var/lib/docker /etc/docker"
            ;;
        yum|dnf)
            echo "   sudo $PACKAGE_MANAGER remove docker-ce docker-ce-cli containerd.io"
            echo "   sudo rm -rf /var/lib/docker /etc/docker"
            ;;
    esac
    echo ""
    
    echo "=========================================="
    echo "  问题排查"
    echo "=========================================="
    echo ""
    echo "如遇到问题，请检查："
    echo "  1. 日志文件: $LOG_FILE"
    echo "  2. Docker日志: journalctl -xeu docker.service"
    echo "  3. Docker状态: systemctl status docker"
    echo "  4. 网络连接: ping docker.io"
    echo ""
    echo "获取帮助："
    echo "  - Docker官方文档: https://docs.docker.com"
    echo "  - Docker中文社区: https://www.docker.org.cn"
    echo ""
}

################################################################################
# 显示帮助信息
################################################################################

show_help() {
    cat << EOF
Docker 一键安装脚本 - 使用帮助

用法:
    sudo bash $0 [选项]

选项:
    --version <版本号>    指定Docker版本（例如: 24.0.7）
    --no-compose         不安装Docker Compose
    --no-mirror          不使用国内镜像源
    --no-autostart       不设置开机自启
    --help               显示此帮助信息

示例:
    # 安装默认版本（交互式选择）
    sudo bash $0

    # 安装指定版本
    sudo bash $0 --version 24.0.7

    # 安装但不使用国内镜像
    sudo bash $0 --no-mirror

    # 安装Docker但不安装Compose
    sudo bash $0 --no-compose

支持的系统:
    - Ubuntu 20.04/22.04/24.04
    - Debian 11/12
    - CentOS 7/8/9
    - RHEL 8/9
    - Rocky Linux 8/9
    - Fedora 38/39

注意事项:
    1. 此脚本必须以root权限运行
    2. 确保系统能够访问互联网
    3. 建议在干净的系统上安装
    4. 安装前会检测已有的Docker并询问如何处理

更多信息:
    - 项目主页: https://github.com/docker/docker-ce
    - 官方文档: https://docs.docker.com

EOF
}

################################################################################
# 主函数
################################################################################

main() {
    # 先初始化日志，确保参数解析阶段的错误信息也能正常写入日志
    init_log

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                if [[ -z "$2" ]]; then
                    log_error "--version 参数需要指定版本号，例如: --version 24.0.7"
                    exit 1
                fi
                if [[ ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log_error "版本号格式错误: $2，应为 X.Y.Z 格式（例如: 24.0.7）"
                    exit 1
                fi
                DOCKER_VERSION="$2"
                VERSION_FROM_CLI=true
                shift 2
                ;;
            --no-compose)
                INSTALL_COMPOSE=false
                shift
                ;;
            --no-mirror)
                USE_MIRROR=false
                shift
                ;;
            --no-autostart)
                AUTO_START=false
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
    
    # 打印脚本标题
    echo ""
    echo "=========================================="
    echo "  Docker 一键安装脚本"
    echo "  版本: 1.0.0"
    echo "  作者: itinstall.dev"
    echo "=========================================="
    echo ""
    
    log_info "开始执行Docker安装流程..."
    log_info "日志文件: $LOG_FILE"
    echo ""
    
    # 执行安装流程
    check_root                    # 1. 检查root权限
    check_network                 # 2. 检查网络
    check_disk_space             # 3. 检查磁盘空间
    detect_system                # 4. 检测系统信息
    check_existing_docker        # 5. 检查已安装的Docker
    select_docker_version        # 6. 选择Docker版本
    update_package_index         # 7. 更新包索引
    install_dependencies         # 8. 安装依赖
    add_docker_gpg_key          # 9. 添加GPG密钥
    add_docker_repository       # 10. 添加Docker仓库
    install_docker_engine       # 11. 安装Docker
    configure_docker_daemon     # 12. 配置Docker
    configure_user_permissions  # 13. 配置用户权限
    start_docker_service        # 14. 启动Docker服务
    verify_docker_installation  # 15. 验证安装
    show_installation_summary   # 16. 显示安装总结
    
    log_success "Docker安装完成！"
    echo ""
}

# 执行主函数
main "$@"
