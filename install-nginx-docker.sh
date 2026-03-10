#!/usr/bin/env bash
# =============================================================================
#  Nginx Docker 一键安装脚本
#  版本: 1.0.0
#  适用: Linux (Ubuntu / Debian / CentOS / Rocky / AlmaLinux / Fedora)
#  用途: 生产环境级别的 Nginx Docker 部署
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# 全局配置（可按需修改）
# ─────────────────────────────────────────────────────────────────────────────
NGINX_VERSION="latest"                    # Nginx 镜像版本，可改为 "1.26" 等
CONTAINER_NAME="nginx-prod"               # 容器名称
HTTP_PORT=80                              # 对外 HTTP 端口
BASE_DIR="/opt/nginx"                     # 安装根目录
CONF_DIR="${BASE_DIR}/conf.d"             # 虚拟主机配置目录
HTML_DIR="${BASE_DIR}/html"               # 静态网页目录
SCRIPT_LOG="/var/log/nginx-docker-install.log"  # 本脚本运行日志
DOCKER_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
NGINX_CONF="${BASE_DIR}/nginx.conf"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_PREINSTALLED=false
NON_INTERACTIVE=0                       # 1=非交互模式（CI 等场景）
FORCE_SYSTEMD_CGROUP="auto"           # auto|1|0：是否写入 native.cgroupdriver=systemd
PAUSED_CONTAINERS=()                    # 记录被暂停的容器，便于恢复

# ─────────────────────────────────────────────────────────────────────────────
# 国内镜像源配置（中国大陆加速）
# ─────────────────────────────────────────────────────────────────────────────
# Docker 安装源（阿里云镜像）
ALIYUN_DOCKER_REPO="https://mirrors.aliyun.com/docker-ce"

# Docker Hub 镜像加速列表（按优先级排列，脚本自动探活选最快的）
CN_REGISTRY_MIRRORS=(
  "https://docker.m.daocloud.io"
  "https://hub-mirror.c.163.com"
  "https://mirror.baidubce.com"
  "https://ccr.ccs.tencentyun.com"
  "https://registry.docker-cn.com"
)

# ─────────────────────────────────────────────────────────────────────────────
# 终端颜色 & 图标
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ICON_OK="✅"
ICON_ERR="❌"
ICON_WARN="⚠️ "
ICON_INFO="ℹ️ "
ICON_RUN="🚀"
ICON_DOCKER="🐳"
ICON_NGINX="🌐"
ICON_LOG="📋"
ICON_FOLDER="📁"
ICON_CHECK="🔍"

# ─────────────────────────────────────────────────────────────────────────────
# 日志函数
# ─────────────────────────────────────────────────────────────────────────────
_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
_log_raw() { echo -e "$*" | tee -a "${SCRIPT_LOG}" 2>/dev/null || echo -e "$*"; }

log_info()    { _log_raw "${DIM}[$(_ts)]${RESET} ${BLUE}${ICON_INFO} INFO${RESET}    $*"; }
log_success() { _log_raw "${DIM}[$(_ts)]${RESET} ${GREEN}${ICON_OK} SUCCESS${RESET}  $*"; }
log_warn()    { _log_raw "${DIM}[$(_ts)]${RESET} ${YELLOW}${ICON_WARN}WARN${RESET}    $*"; }
log_error()   { _log_raw "${DIM}[$(_ts)]${RESET} ${RED}${ICON_ERR} ERROR${RESET}   $*" >&2; }
log_step()    { _log_raw "\n${BOLD}${CYAN}────────────────────────────────────────${RESET}"; \
                _log_raw "${BOLD}${CYAN}  $*${RESET}"; \
                _log_raw "${BOLD}${CYAN}────────────────────────────────────────${RESET}"; }
log_cmd()     { _log_raw "${DIM}[$(_ts)]${RESET} ${DIM}  ▶ $*${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# 参数解析
# ─────────────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes|--non-interactive)
        NON_INTERACTIVE=1
        ;;
      --force-systemd-cgroup)
        FORCE_SYSTEMD_CGROUP="1"
        ;;
      --no-systemd-cgroup)
        FORCE_SYSTEMD_CGROUP="0"
        ;;
      -h|--help)
        cat << 'HELP_EOF'
用法: install-nginx-docker-prod.sh [选项]

选项:
  -y, --yes, --non-interactive   非交互模式（默认选择安全策略）
      --force-systemd-cgroup     强制写入 native.cgroupdriver=systemd
      --no-systemd-cgroup        不写入 native.cgroupdriver=systemd
  -h, --help                     显示帮助
HELP_EOF
        exit 0
        ;;
      *)
        log_warn "未知参数: $1（忽略）"
        ;;
    esac
    shift
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 错误处理 / 退出清理
# ─────────────────────────────────────────────────────────────────────────────
trap '_on_error $LINENO' ERR
trap '_on_exit' EXIT

_on_error() {
  log_error "脚本在第 ${1} 行发生错误，安装已中止！"
  log_error "查看完整日志: ${SCRIPT_LOG}"
  exit 1
}

_on_exit() {
  # 若脚本中途失败且曾暂停过其他容器，尽量恢复，避免影响业务
  resume_paused_containers || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 欢迎 Banner
# ─────────────────────────────────────────────────────────────────────────────
show_banner() {
  clear
  echo -e "${BOLD}${BLUE}"
  cat << 'EOF'
  ███╗   ██╗ ██████╗ ██╗███╗   ██╗██╗  ██╗
  ████╗  ██║██╔════╝ ██║████╗  ██║╚██╗██╔╝
  ██╔██╗ ██║██║  ███╗██║██╔██╗ ██║ ╚███╔╝
  ██║╚██╗██║██║   ██║██║██║╚██╗██║ ██╔██╗
  ██║ ╚████║╚██████╔╝██║██║ ╚████║██╔╝ ██╗
  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝
EOF
  echo -e "${RESET}${BOLD}         🐳 Docker 一键安装脚本  v1.0.0${RESET}"
  echo -e "${DIM}         生产环境级别 · 开箱即用 · 安全加固${RESET}"
  echo ""
  echo -e "  ${DIM}日志文件: ${SCRIPT_LOG}${RESET}"
  echo -e "  ${DIM}安装目录: ${BASE_DIR}${RESET}"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 环境检测
# ─────────────────────────────────────────────────────────────────────────────
check_root() {
  log_step "${ICON_CHECK} 步骤 1/9 · 环境预检"
  if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要 root 权限，请使用 sudo 执行！"
    exit 1
  fi
  log_success "当前用户: root"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/etc/os-release
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID}"
    OS_NAME="${PRETTY_NAME}"
  else
    log_error "无法识别操作系统，仅支持带有 /etc/os-release 的 Linux 发行版"
    exit 1
  fi

  case "${OS_ID}" in
    ubuntu|debian)             PKG_MANAGER="apt-get"; PKG_UPDATE="apt-get update -qq" ;;
    centos|rhel|rocky|almalinux) PKG_MANAGER="yum";     PKG_UPDATE="yum makecache -q"  ;;
    fedora)                    PKG_MANAGER="dnf";     PKG_UPDATE="dnf makecache -q"   ;;
    *)
      log_error "不支持的发行版: ${OS_ID}（${OS_NAME}）"
      log_error "请先手动安装 Docker 与 docker compose，再重新运行本脚本。"
      exit 1
      ;;
  esac

  log_success "操作系统: ${OS_NAME}"
  log_info    "包管理器: ${PKG_MANAGER}"
}

check_arch() {
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|aarch64|arm64) log_success "系统架构: ${ARCH}" ;;
    *)
      log_warn "架构 ${ARCH} 可能不受 Docker 官方支持"
      ;;
  esac
}

is_port_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} " || \
  netstat -tlnp 2>/dev/null | grep -q ":${port} "
}

kill_port_processes() {
  local port="$1"
  local pids=()

  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && pids+=("${pid}")
    done < <(lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u)
  fi

  if [[ ${#pids[@]} -eq 0 ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && pids+=("${pid}")
    done < <(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {if (match($0,/pid=[0-9]+/)) {print substr($0,RSTART+4,RLENGTH-4)}}' | sort -u)
  fi

  if [[ ${#pids[@]} -eq 0 ]]; then
    log_error "无法自动识别占用端口 ${port} 的进程 PID，请手动处理后重试。"
    exit 1
  fi

  log_warn "端口 ${port} 占用进程 PID: ${pids[*]}"
  for pid in "${pids[@]}"; do
    if kill -TERM "${pid}" 2>/dev/null; then
      log_info "已发送 TERM 信号: PID=${pid}"
      sleep 2
      if kill -0 "${pid}" 2>/dev/null; then
        log_warn "进程仍存活，发送 KILL 信号: PID=${pid}"
        if kill -KILL "${pid}" 2>/dev/null; then
          log_success "已强制终止进程 PID=${pid}"
        else
          log_warn "强制终止失败或进程已退出: PID=${pid}"
        fi
      else
        log_success "进程已正常退出: PID=${pid}"
      fi
    else
      log_warn "发送 TERM 失败或进程已退出: PID=${pid}"
    fi
  done
}

handle_port_conflict() {
  local role="$1"
  local port="$2"

  while is_port_in_use "${port}"; do
    log_warn "${role} 端口 ${port} 已被占用。"

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
      log_info "非交互模式：默认尝试释放端口 ${port}"
      kill_port_processes "${port}"
      sleep 1
      if is_port_in_use "${port}"; then
        log_error "非交互模式下端口 ${port} 仍被占用，无法继续。"
        exit 1
      fi
      log_success "端口 ${port} 已释放。"
      continue
    fi

    log_warn "请选择处理方式:"
    log_warn "  1) Kill 占用端口的进程并继续"
    log_warn "  2) 退出安装"

    read -r -p "  请输入选项 [1/2]: " action
    case "${action}" in
      1)
        kill_port_processes "${port}"
        sleep 1
        if is_port_in_use "${port}"; then
          log_warn "端口 ${port} 仍被占用，请重试或手动处理。"
        else
          log_success "端口 ${port} 已释放。"
        fi
        ;;
      2)
        log_info "用户取消安装。"
        exit 0
        ;;
      *)
        log_warn "无效选项，请输入 1 或 2。"
        ;;
    esac
  done
}

diagnose_port_occupier() {
  local port="$1"
  log_warn "自动诊断：检测端口 ${port} 占用详情..."

  if command -v ss >/dev/null 2>&1; then
    log_info "ss 结果（监听端口）:"
    ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}' | while IFS= read -r line; do
      log_warn "  ${line}"
    done
  elif command -v netstat >/dev/null 2>&1; then
    log_info "netstat 结果（监听端口）:"
    netstat -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}' | while IFS= read -r line; do
      log_warn "  ${line}"
    done
  fi

  if command -v lsof >/dev/null 2>&1; then
    log_info "lsof 结果（占用进程）:"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | while IFS= read -r line; do
      log_warn "  ${line}"
    done
  fi

  log_info "Docker 容器端口映射检查:"
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E "(0\.0\.0\.0|:::)?${port}->|:${port}->" | while IFS= read -r line; do
    log_warn "  ${line}"
  done || true
}

try_recover_from_log_permission_issue() {
  log_warn "检测到 Nginx 日志权限异常，尝试自动修复并重启容器..."

  if docker rm -f "${CONTAINER_NAME}" >> "${SCRIPT_LOG}" 2>&1; then
    log_info "已移除异常容器，准备重建。"
  fi

  if docker compose -f "${DOCKER_COMPOSE_FILE}" up -d 2>&1 | tee -a "${SCRIPT_LOG}"; then
    log_success "自动修复后容器已重建。"
    return 0
  fi

  log_error "自动修复后仍启动失败。"
  return 1
}

check_ports() {
  handle_port_conflict "HTTP" "${HTTP_PORT}"
  log_success "端口检测完成: ${HTTP_PORT}(HTTP) 可用"
}

check_disk_space() {
  local required_mb=500
  local available_mb

  # BASE_DIR 可能尚未创建，优先检查其父目录；失败则回退根分区
  available_mb=$(df -Pm "${BASE_DIR%/*}" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -z "${available_mb}" || ! "${available_mb}" =~ ^[0-9]+$ ]]; then
    available_mb=$(df -Pm / | awk 'NR==2{print $4}')
  fi

  if [[ -z "${available_mb}" || ! "${available_mb}" =~ ^[0-9]+$ ]]; then
    log_error "无法获取磁盘可用空间，请手动检查后重试。"
    exit 1
  fi

  if (( available_mb < required_mb )); then
    log_error "磁盘空间不足！需要至少 ${required_mb}MB，当前可用: ${available_mb}MB"
    exit 1
  fi
  log_success "磁盘空间: ${available_mb}MB 可用（最低要求 ${required_mb}MB）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装 Docker
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
  log_step "${ICON_DOCKER} 步骤 2/9 · 安装 Docker"

  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+,?$/) {gsub(/,/,"",$i); print $i; exit}}')
    DOCKER_PREINSTALLED=true
    log_success "Docker 已安装，版本: ${ver}，跳过安装步骤"
    return 0
  fi

  DOCKER_PREINSTALLED=false

  log_info "开始安装 Docker Engine（使用阿里云镜像加速）..."
  log_cmd "${PKG_UPDATE}"
  eval "${PKG_UPDATE}" >> "${SCRIPT_LOG}" 2>&1

  # 安装依赖
  case "${OS_ID}" in
    ubuntu|debian)
      log_cmd "安装 Docker 依赖包"
      apt-get install -y -qq ca-certificates curl gnupg lsb-release >> "${SCRIPT_LOG}" 2>&1

      log_cmd "添加 Docker GPG 密钥（阿里云）"
      install -m 0755 -d /etc/apt/keyrings
      # 优先使用阿里云 GPG，失败时回退官方源
      curl -fsSL "${ALIYUN_DOCKER_REPO}/linux/${OS_ID}/gpg" \
        -o /tmp/docker.gpg 2>> "${SCRIPT_LOG}" \
        || curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
             -o /tmp/docker.gpg 2>> "${SCRIPT_LOG}"
      gpg --dearmor < /tmp/docker.gpg > /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      rm -f /tmp/docker.gpg

      log_cmd "添加 Docker APT 源（阿里云）"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
${ALIYUN_DOCKER_REPO}/linux/${OS_ID} \
$(
# shellcheck source=/etc/os-release
# shellcheck disable=SC1091
. /etc/os-release && echo "$VERSION_CODENAME"
) stable" \
        > /etc/apt/sources.list.d/docker.list

      apt-get update -qq >> "${SCRIPT_LOG}" 2>&1
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >> "${SCRIPT_LOG}" 2>&1
      ;;

    centos|rhel|rocky|almalinux)
      log_cmd "安装 Docker 依赖包"
      yum install -y -q yum-utils >> "${SCRIPT_LOG}" 2>&1
      log_cmd "添加 Docker YUM 源（阿里云）"
      # 阿里云 CentOS Docker 源，并将 baseurl 替换为阿里云镜像
      yum-config-manager --add-repo \
        "${ALIYUN_DOCKER_REPO}/linux/centos/docker-ce.repo" >> "${SCRIPT_LOG}" 2>&1 \
        || yum-config-manager --add-repo \
             "https://download.docker.com/linux/centos/docker-ce.repo" >> "${SCRIPT_LOG}" 2>&1
      # 将 repo 文件中的官方地址替换为阿里云
      sed -i "s|https://download.docker.com|${ALIYUN_DOCKER_REPO}|g" \
        /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
      yum install -y -q docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >> "${SCRIPT_LOG}" 2>&1
      ;;

    fedora)
      dnf install -y -q dnf-plugins-core >> "${SCRIPT_LOG}" 2>&1
      dnf config-manager --add-repo \
        "${ALIYUN_DOCKER_REPO}/linux/fedora/docker-ce.repo" >> "${SCRIPT_LOG}" 2>&1 \
        || dnf config-manager --add-repo \
             "https://download.docker.com/linux/fedora/docker-ce.repo" >> "${SCRIPT_LOG}" 2>&1
      sed -i "s|https://download.docker.com|${ALIYUN_DOCKER_REPO}|g" \
        /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
      dnf install -y -q docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >> "${SCRIPT_LOG}" 2>&1
      ;;
  esac

  log_cmd "启动 Docker 服务"
  systemctl enable --now docker >> "${SCRIPT_LOG}" 2>&1
  log_success "Docker 安装完成: $(docker --version)"
}

install_docker_compose_standalone() {
  # docker compose plugin 已随 Docker 安装，此处仅作补充检测
  if docker compose version &>/dev/null 2>&1; then
    log_success "Docker Compose 插件: $(docker compose version --short 2>/dev/null || echo 'OK')"
  elif command -v docker-compose &>/dev/null; then
    log_success "docker-compose 独立版本已存在"
  else
    log_warn "未检测到 docker compose，尝试安装独立版本..."
    local compose_ver="v2.27.0"
    local compose_url
    compose_url="https://github.com/docker/compose/releases/download/${compose_ver}/docker-compose-$(uname -s)-$(uname -m)"
    curl -fsSL "${compose_url}" -o /usr/local/bin/docker-compose >> "${SCRIPT_LOG}" 2>&1
    chmod +x /usr/local/bin/docker-compose
    log_success "docker-compose 安装完成: $(docker-compose --version)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 配置 Docker Hub 镜像加速（国内专用）
# ─────────────────────────────────────────────────────────────────────────────
configure_docker_mirrors() {
  if [[ "${DOCKER_PREINSTALLED}" == "true" ]]; then
    log_info "检测到 Docker 已预装，按策略跳过镜像加速配置。"
    return 0
  fi

  log_step "🇨🇳 步骤 3/9 · 配置 Docker Hub 镜像加速（国内）"

  # 探活：找出响应最快的镜像源
  log_info "正在探测各镜像源连通性，选择最优节点..."
  local alive_mirrors=()
  for mirror in "${CN_REGISTRY_MIRRORS[@]}"; do
    local host
    host="${mirror//https:\/\//}"
    if curl -fsSL --max-time 5 --connect-timeout 3 \
         "https://${host}/v2/" -o /dev/null 2>/dev/null; then
      alive_mirrors+=("\"${mirror}\"")
      log_success "  ✅ 可用: ${mirror}"
    else
      log_warn "  ⏳ 超时/不可达: ${mirror}"
    fi
  done

  # 若全部不通（极少数内网环境），则保留全部列表作为兜底
  if [[ ${#alive_mirrors[@]} -eq 0 ]]; then
    log_warn "所有镜像源探活均失败（可能是内网或网络限制），将写入全量列表作为兜底"
    for mirror in "${CN_REGISTRY_MIRRORS[@]}"; do
      alive_mirrors+=("\"${mirror}\"")
    done
  fi

  # 拼接 JSON 数组
  local mirrors_json
  mirrors_json=$(IFS=','; echo "${alive_mirrors[*]}")

  # 备份旧配置
  mkdir -p /etc/docker
  if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
    cp "${DOCKER_DAEMON_JSON}" "${DOCKER_DAEMON_JSON}.bak.$(date +%s)"
    log_info "已备份旧 daemon.json"
  fi

  # cgroup driver 策略：默认 auto（仅在 systemd 环境写入）
  local apply_systemd_cgroup=false
  case "${FORCE_SYSTEMD_CGROUP}" in
    1) apply_systemd_cgroup=true ;;
    0) apply_systemd_cgroup=false ;;
    auto)
      if pidof systemd >/dev/null 2>&1; then
        apply_systemd_cgroup=true
      fi
      ;;
  esac

  # 合并写入 daemon.json（避免覆盖用户已有配置）
  local merged_ok=false
  if command -v jq >/dev/null 2>&1; then
    local tmp_daemon
    tmp_daemon=$(mktemp)

    if [[ -s "${DOCKER_DAEMON_JSON}" ]]; then
      if jq . "${DOCKER_DAEMON_JSON}" >/dev/null 2>&1; then
        if [[ "${apply_systemd_cgroup}" == "true" ]]; then
          if jq --argjson mirrors "[${mirrors_json}]" '
            .["registry-mirrors"] = $mirrors
            | .["log-driver"] = "json-file"
            | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size":"50m","max-file":"3"})
            | .["exec-opts"] = ([((.["exec-opts"] // [])[] | select(. != "native.cgroupdriver=systemd")), "native.cgroupdriver=systemd"])
            | .["live-restore"] = true
          ' "${DOCKER_DAEMON_JSON}" > "${tmp_daemon}"; then
            mv "${tmp_daemon}" "${DOCKER_DAEMON_JSON}"
            merged_ok=true
          else
            rm -f "${tmp_daemon}"
            log_warn "jq 合并 daemon.json 失败，将回退到保守写入。"
          fi
        else
          if jq --argjson mirrors "[${mirrors_json}]" '
            .["registry-mirrors"] = $mirrors
            | .["log-driver"] = "json-file"
            | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size":"50m","max-file":"3"})
            | .["live-restore"] = true
          ' "${DOCKER_DAEMON_JSON}" > "${tmp_daemon}"; then
            mv "${tmp_daemon}" "${DOCKER_DAEMON_JSON}"
            merged_ok=true
          else
            rm -f "${tmp_daemon}"
            log_warn "jq 合并 daemon.json 失败，将回退到保守写入。"
          fi
        fi
      else
        rm -f "${tmp_daemon}"
        log_warn "检测到现有 daemon.json 非法 JSON，将保守重写。"
      fi
    else
      if [[ "${apply_systemd_cgroup}" == "true" ]]; then
        if jq -n --argjson mirrors "[${mirrors_json}]" '{
          "registry-mirrors": $mirrors,
          "log-driver": "json-file",
          "log-opts": {"max-size":"50m","max-file":"3"},
          "exec-opts": ["native.cgroupdriver=systemd"],
          "live-restore": true
        }' > "${tmp_daemon}"; then
          mv "${tmp_daemon}" "${DOCKER_DAEMON_JSON}"
          merged_ok=true
        else
          rm -f "${tmp_daemon}"
        fi
      else
        if jq -n --argjson mirrors "[${mirrors_json}]" '{
          "registry-mirrors": $mirrors,
          "log-driver": "json-file",
          "log-opts": {"max-size":"50m","max-file":"3"},
          "live-restore": true
        }' > "${tmp_daemon}"; then
          mv "${tmp_daemon}" "${DOCKER_DAEMON_JSON}"
          merged_ok=true
        else
          rm -f "${tmp_daemon}"
        fi
      fi
    fi
  fi

  if [[ "${merged_ok}" != "true" ]]; then
    if [[ "${apply_systemd_cgroup}" == "true" ]]; then
      cat > "${DOCKER_DAEMON_JSON}" << DAEMON_EOF
{
  "registry-mirrors": [${mirrors_json}],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true
}
DAEMON_EOF
    else
      cat > "${DOCKER_DAEMON_JSON}" << DAEMON_EOF
{
  "registry-mirrors": [${mirrors_json}],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "live-restore": true
}
DAEMON_EOF
    fi
  fi

  log_info "已写入 ${DOCKER_DAEMON_JSON}，内容如下:"
  tee -a "${SCRIPT_LOG}" < "${DOCKER_DAEMON_JSON}" | sed 's/^/    /'

  # 重载 Docker 使配置生效
  log_info "重载 Docker daemon..."
  systemctl daemon-reload >> "${SCRIPT_LOG}" 2>&1
  systemctl restart docker >> "${SCRIPT_LOG}" 2>&1
  sleep 2

  # 验证配置
  if docker info 2>/dev/null | grep -q "Registry Mirrors"; then
    log_success "镜像加速配置生效："
    docker info 2>/dev/null | grep -A5 "Registry Mirrors" | tee -a "${SCRIPT_LOG}" | sed 's/^/    /'
  else
    log_warn "无法从 docker info 验证镜像加速（Docker 版本差异），配置已写入文件，应会正常生效"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 创建目录结构
# ─────────────────────────────────────────────────────────────────────────────
create_directories() {
  log_step "${ICON_FOLDER} 步骤 4/9 · 创建目录结构"

  local dirs=("${CONF_DIR}" "${HTML_DIR}" "${BASE_DIR}/cache")
  for d in "${dirs[@]}"; do
    mkdir -p "${d}"
    log_info "  创建目录: ${d}"
  done

  # 日志默认输出到 stdout/stderr，不再依赖宿主机日志目录写权限

  log_success "目录结构创建完成"
  tree "${BASE_DIR}" 2>/dev/null || find "${BASE_DIR}" -maxdepth 2 -print | sed 's|[^/]*/|  |g'
}

# ─────────────────────────────────────────────────────────────────────────────
# 生成 Nginx 主配置
# ─────────────────────────────────────────────────────────────────────────────
generate_nginx_conf() {
  log_step "${ICON_NGINX} 步骤 5/9 · 生成 Nginx 主配置"

  if [[ -f "${NGINX_CONF}" ]]; then
    log_warn "nginx.conf 已存在，备份为 nginx.conf.bak.$(date +%s)"
    cp "${NGINX_CONF}" "${NGINX_CONF}.bak.$(date +%s)"
  fi

  cat > "${NGINX_CONF}" << 'NGINX_CONF_EOF'
# ====================================================================
# Nginx 生产环境主配置
# 自动生成 by nginx-docker-install.sh
# ====================================================================

user  nginx;
worker_processes  auto;
worker_rlimit_nofile 65535;
# 生产环境容器建议输出到 stdout/stderr，避免宿主机权限差异导致启动失败
error_log  /dev/stderr warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  4096;
    use epoll;
    multi_accept on;
}

http {
    # ── 基础 ────────────────────────────────────────────────────────
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    charset       utf-8;

    # ── 日志格式（单行，兼容所有 nginx 版本）────────────────────────
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';

    log_format json_combined escape=json '{"time":"$time_iso8601","remote_addr":"$remote_addr","method":"$request_method","uri":"$request_uri","status":$status,"bytes_sent":$body_bytes_sent,"request_time":$request_time,"http_referer":"$http_referer","http_user_agent":"$http_user_agent"}';

    access_log  /dev/stdout json_combined;

    # ── 性能优化 ────────────────────────────────────────────────────
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    keepalive_requests 1000;
    reset_timedout_connection on;

    # ── 缓冲区 ──────────────────────────────────────────────────────
    client_body_buffer_size     128k;
    client_max_body_size        50m;
    client_header_buffer_size   1k;
    large_client_header_buffers 4 16k;

    # ── Gzip 压缩 ────────────────────────────────────────────────────
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml application/rss+xml application/atom+xml image/svg+xml;

    # ── 安全加固 ─────────────────────────────────────────────────────
    server_tokens off;
    add_header X-Frame-Options        "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"      always;
    add_header X-XSS-Protection       "1; mode=block" always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    # ── 速率 / 连接限制 ─────────────────────────────────────────────
    limit_req_zone  $binary_remote_addr zone=req_limit:10m  rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # ── 代理缓存（按需取消注释）──────────────────────────────────────
    # proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=proxy_cache:10m max_size=1g inactive=60m use_temp_path=off;

    # ── 加载虚拟主机配置 ─────────────────────────────────────────────
    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF_EOF

  log_success "Nginx 主配置已写入: ${NGINX_CONF}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 生成默认站点配置
# ─────────────────────────────────────────────────────────────────────────────
generate_default_site() {
  log_step "${ICON_NGINX} 步骤 6/9 · 生成默认站点 & 欢迎页"

  cat > "${CONF_DIR}/default.conf" << 'SITE_EOF'
# ====================================================================
# 默认站点配置（HTTP 欢迎页）
# 自动生成 by nginx-docker-install.sh
# ====================================================================
server {
    listen       80 default_server;
    listen       [::]:80 default_server;
    server_name  _;

    root   /usr/share/nginx/html;
    index  index.html index.htm;

    # 速率 / 连接限制（zone 在 nginx.conf 中定义）
    limit_req  zone=req_limit  burst=50 nodelay;
    limit_conn conn_limit 20;

    # 健康检查端点
    location = /health {
        access_log off;
        add_header Content-Type "application/json" always;
        return 200 "{\"status\":\"ok\",\"service\":\"nginx\"}";
    }

    # 禁止访问隐藏文件（.git .env 等）
    location ~ /\. {
        deny all;
        access_log  off;
        log_not_found off;
    }

    # 静态资源浏览器缓存 30 天
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|woff|ttf|svg|webp)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    # 默认路由
    location / {
        try_files $uri $uri/ =404;
    }

    # 错误页
    error_page 404             /404.html;
    error_page 500 502 503 504 /50x.html;

    location = /50x.html {
        root /usr/share/nginx/html;
        internal;
    }
}
SITE_EOF

  # 生成欢迎页 HTML
  cat > "${HTML_DIR}/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Nginx · 部署成功</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
      min-height: 100vh; display: flex; align-items: center; justify-content: center;
      color: #fff;
    }
    .card {
      text-align: center; padding: 60px 80px;
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 20px; backdrop-filter: blur(10px);
      box-shadow: 0 25px 50px rgba(0,0,0,0.4);
    }
    .icon { font-size: 80px; margin-bottom: 24px; animation: bounce 2s infinite; }
    @keyframes bounce {
      0%,100% { transform: translateY(0); }
      50%      { transform: translateY(-12px); }
    }
    h1 { font-size: 2.4rem; font-weight: 700; margin-bottom: 12px;
         background: linear-gradient(90deg, #43e97b, #38f9d7);
         -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    p  { font-size: 1.1rem; color: rgba(255,255,255,0.65); margin-bottom: 32px; }
    .badge {
      display: inline-block; padding: 6px 18px;
      background: rgba(67,233,123,0.15); border: 1px solid #43e97b;
      border-radius: 999px; font-size: 0.85rem; color: #43e97b;
    }
    .meta { margin-top: 40px; font-size: 0.78rem; color: rgba(255,255,255,0.3); }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🚀</div>
    <h1>Nginx 部署成功！</h1>
    <p>您的 Nginx Docker 容器正在运行中<br>现在可以配置您的站点了</p>
    <span class="badge">✅ 服务运行正常</span>
    <div class="meta">Powered by nginx-docker-install.sh · 生产环境就绪</div>
  </div>
</body>
</html>
HTML_EOF

  # 生成 404 页面，匹配 default.conf 中的 error_page 配置
  cat > "${HTML_DIR}/404.html" << 'HTML_404_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>404 Not Found</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background:#0b1020; color:#e5e7eb; display:flex; min-height:100vh; align-items:center; justify-content:center; margin:0; }
    .box { text-align:center; padding:40px; border:1px solid #334155; border-radius:16px; background:rgba(15,23,42,.7); }
    h1 { margin:0 0 10px; font-size:48px; color:#60a5fa; }
    p { margin:0; color:#94a3b8; }
  </style>
</head>
<body>
  <div class="box">
    <h1>404</h1>
    <p>您访问的页面不存在。</p>
  </div>
</body>
</html>
HTML_404_EOF

  log_success "默认站点配置已写入: ${CONF_DIR}/default.conf"
  log_success "欢迎页已写入:       ${HTML_DIR}/index.html"
  log_success "404 页面已写入:      ${HTML_DIR}/404.html"
}

# ─────────────────────────────────────────────────────────────────────────────
# 生成 Docker Compose 文件
# ─────────────────────────────────────────────────────────────────────────────
generate_compose() {
  log_step "${ICON_DOCKER} 步骤 7/9 · 生成 docker-compose.yml"

  cat > "${DOCKER_COMPOSE_FILE}" << COMPOSE_EOF
# ====================================================================
# Nginx Docker Compose - 生产环境配置
# 自动生成 by nginx-docker-install.sh @ $(date '+%Y-%m-%d %H:%M:%S')
# ====================================================================

services:
  nginx:
    image: nginx:${NGINX_VERSION}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped

    ports:
      - "${HTTP_PORT}:80"

    volumes:
      # 主配置文件
      - ${NGINX_CONF}:/etc/nginx/nginx.conf:ro
      # 虚拟主机配置目录（保持可写，避免 entrypoint 的 IPv6 脚本只读告警）
      - ${CONF_DIR}:/etc/nginx/conf.d
      # 静态文件目录
      - ${HTML_DIR}:/usr/share/nginx/html:ro
      # 代理缓存
      - ${BASE_DIR}/cache:/var/cache/nginx

    environment:
      - TZ=Asia/Shanghai

    # 容器资源限制（Docker Compose 本地模式可生效）
    cpus: "2.0"
    mem_limit: 512m
    mem_reservation: 64m

    # 健康检查（避免依赖 curl/wget，使用 nginx 自检）
    healthcheck:
      test: ["CMD-SHELL", "nginx -t >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s

    # 系统能力（最小权限原则）
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID

    # 安全选项
    security_opt:
      - no-new-privileges:true

    # 日志驱动
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "7"
        compress: "true"

    networks:
      - nginx_net

networks:
  nginx_net:
    name: nginx_network
    driver: bridge
COMPOSE_EOF

  log_success "docker-compose.yml 已写入: ${DOCKER_COMPOSE_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 检查已有 Nginx 镜像/容器
# ─────────────────────────────────────────────────────────────────────────────
check_existing_nginx_image_and_container() {
  local image_ref="nginx:${NGINX_VERSION}"

  if ! docker image inspect "${image_ref}" >/dev/null 2>&1; then
    log_info "本机未检测到 ${image_ref} 镜像，将在后续步骤拉取。"
    return 0
  fi

  log_warn "检测到本机已存在 ${image_ref} 镜像。"

  local running_containers
  running_containers=$(docker ps --filter "ancestor=${image_ref}" --format '{{.Names}}' 2>/dev/null || true)

  if [[ -z "${running_containers}" ]]; then
    log_info "当前没有正在运行且使用 ${image_ref} 的容器。"
    return 0
  fi

  log_warn "以下容器正在使用 ${image_ref}:"
  while IFS= read -r c; do
    [[ -n "${c}" ]] && log_warn "  - ${c}"
  done <<< "${running_containers}"

  local pause_ans="n"
  if [[ "${NON_INTERACTIVE}" == "1" ]]; then
    log_info "非交互模式：默认不暂停已有容器。"
  else
    read -r -p "  是否暂停以上容器？[y/N] " pause_ans
  fi

  if [[ "${pause_ans,,}" == "y" ]]; then
    while IFS= read -r c; do
      [[ -z "${c}" ]] && continue
      if docker pause "${c}" >> "${SCRIPT_LOG}" 2>&1; then
        PAUSED_CONTAINERS+=("${c}")
        log_success "已暂停容器: ${c}"
      else
        log_warn "暂停容器失败（可忽略并手动处理）: ${c}"
      fi
    done <<< "${running_containers}"
  else
    log_info "用户选择不暂停已有容器。"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 处理同名容器冲突
# ─────────────────────────────────────────────────────────────────────────────
handle_existing_container_name_conflict() {
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    return 0
  fi

  local exist_id exist_status
  exist_id=$(docker inspect --format='{{.Id}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
  exist_status=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

  log_warn "检测到同名容器冲突: ${CONTAINER_NAME}"
  log_warn "容器ID: ${exist_id}"
  log_warn "状态: ${exist_status}"
  log_warn "请选择处理方式:"
  log_warn "  1) 删除旧容器并继续"
  log_warn "  2) 重命名旧容器并继续"
  log_warn "  3) 退出安装"

  local conflict_choice
  if [[ "${NON_INTERACTIVE}" == "1" ]]; then
    conflict_choice="3"
    log_warn "非交互模式：检测到同名容器冲突，默认安全退出。"
  fi

  while true; do
    if [[ "${NON_INTERACTIVE}" != "1" ]]; then
      read -r -p "  请输入选项 [1/2/3]: " conflict_choice
    fi
    case "${conflict_choice}" in
      1)
        if docker rm -f "${CONTAINER_NAME}" >> "${SCRIPT_LOG}" 2>&1; then
          log_success "已删除旧容器: ${CONTAINER_NAME}"
          return 0
        else
          log_error "删除旧容器失败，请手动处理后重试。"
          exit 1
        fi
        ;;
      2)
        local backup_name
        backup_name="${CONTAINER_NAME}-bak-$(date +%Y%m%d%H%M%S)"
        if docker rename "${CONTAINER_NAME}" "${backup_name}" >> "${SCRIPT_LOG}" 2>&1; then
          log_success "已重命名旧容器: ${CONTAINER_NAME} -> ${backup_name}"
          return 0
        else
          log_error "重命名旧容器失败，请手动处理后重试。"
          exit 1
        fi
        ;;
      3)
        log_info "用户取消安装。"
        exit 0
        ;;
      *)
        log_warn "无效选项，请输入 1、2 或 3。"
        ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 启动容器
# ─────────────────────────────────────────────────────────────────────────────
start_container() {
  log_step "${ICON_RUN} 步骤 8/9 · 拉取镜像并启动容器"

  log_info "拉取 nginx:${NGINX_VERSION} 镜像..."
  # 避免在 set -o pipefail 下因 grep 无匹配而误判失败
  if docker pull "nginx:${NGINX_VERSION}" 2>&1 | tee -a "${SCRIPT_LOG}" | \
      grep -E 'Pull complete|Digest|Status|already' >/dev/null; then
    :
  fi

  log_info "预检 Nginx 配置（使用临时容器运行 nginx -t）..."
  local nginx_test_out
  # 直接捕获 docker run 退出码，同时保留完整输出供调试
  if nginx_test_out=$(docker run --rm \
      -v "${NGINX_CONF}:/etc/nginx/nginx.conf:ro" \
      -v "${CONF_DIR}:/etc/nginx/conf.d:ro" \
      "nginx:${NGINX_VERSION}" nginx -t 2>&1); then
    log_success "Nginx 配置语法检查通过"
    echo "${nginx_test_out}" >> "${SCRIPT_LOG}"
  else
    log_error "Nginx 配置语法检查失败！详细错误如下："
    echo "${nginx_test_out}" | while IFS= read -r line; do
      log_error "    ${line}"
    done
    echo "${nginx_test_out}" >> "${SCRIPT_LOG}"
    log_error "配置文件路径: ${NGINX_CONF}"
    log_error "站点配置目录: ${CONF_DIR}"
    exit 1
  fi

  handle_existing_container_name_conflict

  log_info "启动前二次端口复检（避免运行阶段端口被抢占）..."
  handle_port_conflict "HTTP" "${HTTP_PORT}"

  log_info "启动容器: ${CONTAINER_NAME}..."
  cd "${BASE_DIR}"
  if docker compose -f "${DOCKER_COMPOSE_FILE}" up -d 2>&1 | tee -a "${SCRIPT_LOG}"; then
    log_success "容器已成功启动"
  else
    log_warn "首次启动失败，收集诊断信息..."
    diagnose_port_occupier "${HTTP_PORT}"

    local recent_logs
    recent_logs=$(docker logs --tail 80 "${CONTAINER_NAME}" 2>&1 || true)
    echo "${recent_logs}" >> "${SCRIPT_LOG}"

    if echo "${recent_logs}" | grep -qE 'open\(\) "/var/log/nginx/error\.log" failed \(13: Permission denied\)'; then
      if try_recover_from_log_permission_issue; then
        log_success "已自动修复日志权限并完成容器启动"
      else
        log_error "容器启动失败，请查看日志: docker compose -f ${DOCKER_COMPOSE_FILE} logs"
        exit 1
      fi
    else
      log_error "容器启动失败，请查看日志: docker compose -f ${DOCKER_COMPOSE_FILE} logs"
      exit 1
    fi
  fi

  # 等待健康检查
  log_info "等待容器健康检查..."
  local retries=10 interval=3
  for ((i=1; i<=retries; i++)); do
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    if [[ "${status}" == "healthy" ]]; then
      log_success "容器健康状态: healthy ✅"
      break
    fi
    log_info "  (${i}/${retries}) 当前状态: ${status}，${interval}s 后重试..."
    sleep "${interval}"
    if [[ "${i}" == "${retries}" ]]; then
      log_warn "健康检查超时，容器可能仍在启动中，请手动确认: docker ps"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 日志轮转 & 辅助脚本
# ─────────────────────────────────────────────────────────────────────────────
resume_paused_containers() {
  if [[ ${#PAUSED_CONTAINERS[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "恢复之前暂停的容器..."
  local c
  for c in "${PAUSED_CONTAINERS[@]}"; do
    if docker unpause "${c}" >> "${SCRIPT_LOG}" 2>&1; then
      log_success "已恢复容器: ${c}"
    else
      log_warn "恢复容器失败，请手动检查: ${c}"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 日志轮转 & 辅助脚本
# ─────────────────────────────────────────────────────────────────────────────
setup_extras() {
  log_step "${ICON_LOG} 步骤 9/9 · 生成管理脚本"

  # 管理脚本
  cat > "${BASE_DIR}/nginx-ctl.sh" << MGMT_EOF
#!/usr/bin/env bash
# Nginx Docker 管理脚本
set -euo pipefail
COMPOSE="${DOCKER_COMPOSE_FILE}"
NAME="${CONTAINER_NAME}"

case "\${1:-help}" in
  start)   docker compose -f "\$COMPOSE" up -d ;;
  stop)    docker compose -f "\$COMPOSE" stop ;;
  restart) docker compose -f "\$COMPOSE" restart ;;
  reload)
    echo "🔄 重载 Nginx 配置..."
    docker exec "\$NAME" nginx -t && docker exec "\$NAME" nginx -s reload
    echo "✅ 配置重载成功"
    ;;
  status)  docker compose -f "\$COMPOSE" ps ;;
  logs)    docker compose -f "\$COMPOSE" logs -f --tail=100 ;;
  test)    docker exec "\$NAME" nginx -t ;;
  update)
    echo "⬆️  更新 Nginx 镜像..."
    docker compose -f "\$COMPOSE" pull
    docker compose -f "\$COMPOSE" up -d --force-recreate
    echo "✅ 更新完成"
    ;;
  shell)   docker exec -it "\$NAME" /bin/sh ;;
  backup)
    ts=\$(date +%Y%m%d_%H%M%S)
    backup_file="${BASE_DIR}_backup_\${ts}.tar.gz"
    tar -czf "\${backup_file}" "${BASE_DIR}"
    echo "✅ 备份完成: \${backup_file}"
    ;;
  *)
    echo "用法: \$0 {start|stop|restart|reload|status|logs|test|update|shell|backup}"
    ;;
esac
MGMT_EOF
  chmod +x "${BASE_DIR}/nginx-ctl.sh"

  # 符号链接到 /usr/local/bin
  ln -sf "${BASE_DIR}/nginx-ctl.sh" /usr/local/bin/nginx-ctl
  log_success "管理脚本: ${BASE_DIR}/nginx-ctl.sh (已链接至 nginx-ctl)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装摘要
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<your-server-ip>"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║        🎉  Nginx Docker 安装完成！                   ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${ICON_NGINX}  访问地址:"
  echo -e "     ${CYAN}http://${ip}${RESET}"
  echo -e "     ${CYAN}http://localhost${RESET}"
  echo ""
  echo -e "  ${ICON_FOLDER}  目录结构:"
  echo -e "     安装根目录  ${DIM}${BASE_DIR}${RESET}"
  echo -e "     主配置文件  ${DIM}${NGINX_CONF}${RESET}"
  echo -e "     站点配置    ${DIM}${CONF_DIR}/*.conf${RESET}"
  echo -e "     静态文件    ${DIM}${HTML_DIR}${RESET}"
  echo -e "     容器日志    ${DIM}docker logs -f ${CONTAINER_NAME}${RESET}"
  echo ""
  echo -e "  ${ICON_DOCKER}  管理命令:"
  echo -e "     ${YELLOW}nginx-ctl start${RESET}    启动容器"
  echo -e "     ${YELLOW}nginx-ctl stop${RESET}     停止容器"
  echo -e "     ${YELLOW}nginx-ctl reload${RESET}   热重载配置"
  echo -e "     ${YELLOW}nginx-ctl logs${RESET}     实时查看日志"
  echo -e "     ${YELLOW}nginx-ctl status${RESET}   查看状态"
  echo -e "     ${YELLOW}nginx-ctl update${RESET}   更新镜像"
  echo -e "     ${YELLOW}nginx-ctl backup${RESET}   备份配置"
  echo ""
  echo -e "  ${ICON_LOG}  安装日志: ${DIM}${SCRIPT_LOG}${RESET}"
  echo ""
  echo -e "${DIM}  提示: 添加新站点只需在 ${CONF_DIR}/ 中放入 *.conf 文件，"
  echo -e "  然后运行 nginx-ctl reload 即可生效。${RESET}"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  # 确保日志目录可写
  mkdir -p "$(dirname "${SCRIPT_LOG}")" 2>/dev/null || true
  touch "${SCRIPT_LOG}" 2>/dev/null || SCRIPT_LOG="/tmp/nginx-docker-install.log"

  show_banner
  log_info "安装日志保存至: ${SCRIPT_LOG}"

  check_root
  detect_os
  check_arch
  check_disk_space
  check_ports

  install_docker
  install_docker_compose_standalone
  configure_docker_mirrors
  create_directories
  generate_nginx_conf
  generate_default_site
  generate_compose
  check_existing_nginx_image_and_container
  start_container
  setup_extras

  print_summary
}

main "$@"