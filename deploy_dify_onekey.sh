#!/usr/bin/env bash
# deploy_dify_onekey.sh
# 运行：sudo -i;bash deploy_dify_onekey.sh
# version: 0.01 2025-08-18

set -euo pipefail
IFS=$'\n\t'

WORKDIR=/opt
DIFY_DIR="$WORKDIR/dify"
NGINX_CONF_DIR=/etc/nginx/conf.d
CONTAINER_CMD="docker"
DOCKER_COMPOSE_CMD="docker compose"
MIN_DOCKER_VERSION="20.10.0"

log() { echo -e "[\e[32mINFO\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*" >&2; }
require_root() { [ "$EUID" -eq 0 ] || { err "请以 root 或使用 sudo 运行此脚本。"; exit 1; } }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}



get_docker_version() {
  if cmd_exists docker; then
    docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//'
  else
    echo ""
  fi
}

detect_os() {
  log "检测操作系统版本..."
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${ID}"
    OS_VERSION="${VERSION_ID}"
    log "检测到操作系统: ${OS_NAME} ${OS_VERSION}"
  else
    err "无法检测操作系统版本"
    return 1
  fi
}

uninstall_old_docker() {
  log "检查并卸载旧版本 Docker..."
  # 卸载旧版本
  for pkg in docker docker-engine docker.io containerd runc; do
    if dpkg -l | grep -q "^ii  $pkg"; then
      log "卸载旧包: $pkg"
      apt-get remove -y "$pkg"
    fi
  done
  if cmd_exists yum; then
    log "卸载旧版本 Docker..."
    yum remove -y docker \
      docker-client \
      docker-client-latest \
      docker-common \
      docker-latest \
      docker-latest-logrotate \
      docker-logrotate \
      docker-engine
  fi
  log "旧版本 Docker 处理完成"
}

install_docker_ubuntu() {
  log "开始在 Ubuntu 上安装 Docker..."
  
  # 更新 apt 包索引
  log "更新 apt 包索引..."
  apt-get update
  
  # 安装必要的依赖
  log "安装必要的依赖包..."
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  # 添加 Docker 官方 GPG 密钥
  log "添加 Docker 官方 GPG 密钥..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  
  # 设置 Docker 仓库
  log "设置 Docker 仓库..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  # 更新 apt 包索引
  log "更新包索引..."
  apt-get update
  
  # 安装 Docker Engine
  log "安装 Docker Engine、CLI、Containerd 和 Docker Compose..."
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin
  
  # 启动 Docker
  log "启动并启用 Docker 服务..."
  systemctl start docker
  systemctl enable docker
  
  # 验证安装
  log "验证 Docker 安装..."
  if docker --version; then
    log "Docker 安装成功！"
  else
    err "Docker 安装可能存在问题，请检查"
    return 1
  fi
}

install_docker_centos() {
  log "开始在 CentOS 上安装 Docker..."
  
  # 安装所需的包
  log "安装必要的依赖包..."
  yum install -y yum-utils
  
  # 设置 Docker 仓库
  log "设置 Docker 仓库..."
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  
  # 安装 Docker Engine
  log "安装 Docker Engine、CLI、Containerd 和 Docker Compose..."
  yum install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin
  
  # 启动 Docker
  log "启动并启用 Docker 服务..."
  systemctl start docker
  systemctl enable docker
  
  # 验证安装
  log "验证 Docker 安装..."
  if docker --version; then
    log "Docker 安装成功！"
  else
    err "Docker 安装可能存在问题，请检查"
    return 1
  fi
}

install_docker_from_official() {
  log "尝试使用 Docker 官方仓库安装 docker (official)..."
  
  # 检测系统类型
  detect_os || return 1
  
  # 卸载旧版本
  uninstall_old_docker
  
  # 根据系统类型安装
  case "${OS_NAME}" in
    ubuntu)
      install_docker_ubuntu
      ;;
    centos)
      install_docker_centos
      ;;
    *)
      err "不支持的操作系统: ${OS_NAME}"
      return 1
      ;;
  esac
  
  # 安装成功后的提示
  log "Docker 安装完成! 当前版本信息："
  docker --version
  docker compose version
  log "Containerd 版本："
  containerd --version
  
  # 显示 Docker 服务状态
  log "Docker 服务状态："
  systemctl is-active --quiet docker && log "Docker 运行中" || err "Docker 未运行"
  
  return 0
}

install_docker() {
  log "开始 Docker 安装流程..."
  
  # 检查是否已安装 Docker
  if cmd_exists docker; then
    local current_version
    current_version=$(get_docker_version)
    log "检测到已安装 Docker，版本: $current_version"
    
    if [ -n "$current_version" ] && ver_ge "$current_version" "$MIN_DOCKER_VERSION"; then
      log "当前 Docker 版本满足最低要求 ($MIN_DOCKER_VERSION)"
      return 0
    else
      log "当前 Docker 版本 ($current_version) 低于最低要求 ($MIN_DOCKER_VERSION)"
      log "将尝试安装新版本..."
    fi
  else
    log "系统中未检测到 Docker，开始安装流程..."
  fi
  
  # 总是使用官方安装方式
  log "使用 Docker 官方推荐的安装方式..."
  install_docker_from_official || {
    err "Docker 安装失败。请检查以下几点："
    err "1. 确保系统支持（Ubuntu 或 CentOS）"
    err "2. 检查网络连接是否正常"
    err "3. 确保有足够的磁盘空间"
    err "4. 查看系统日志获取详细错误信息：journalctl -xeu docker"
    exit 1
  }
  
  # 安装完成后进行简单的 Docker 测试
  log "执行 Docker 测试..."
  if docker run --rm hello-world; then
    log "✅ Docker 安装并运行正常！"
  else
    err "Docker 安装可能存在问题，hello-world 测试失败"
    exit 1
  fi
}

# 检测并设置容器运行时和 compose 命令
detect_container_runtime() {
  if cmd_exists docker; then
    CONTAINER_CMD="docker"
    if docker compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE_CMD="docker compose"
    elif cmd_exists docker-compose; then
      DOCKER_COMPOSE_CMD="docker-compose"
    else
      err "未检测到 docker compose，请安装 docker compose 插件或 docker-compose。"
      exit 1
    fi
    log "检测到 Docker，使用 $CONTAINER_CMD 和 $DOCKER_COMPOSE_CMD"
  elif cmd_exists podman; then
    CONTAINER_CMD="podman"
    if podman compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE_CMD="podman compose"
    elif cmd_exists podman-compose; then
      DOCKER_COMPOSE_CMD="podman-compose"
    else
      err "未检测到 podman compose，请安装 podman-compose。"
      exit 1
    fi
    log "检测到 Podman，使用 $CONTAINER_CMD 和 $DOCKER_COMPOSE_CMD"
  else
    log "未检测到 docker 或 podman，自动安装 docker..."
    install_docker
    # 安装后重新检测
    if cmd_exists docker; then
      CONTAINER_CMD="docker"
      if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
      elif cmd_exists docker-compose; then
        DOCKER_COMPOSE_CMD="docker-compose"
      else
        err "未检测到 docker compose，请安装 docker compose 插件或 docker-compose。"
        exit 1
      fi
      log "已安装 Docker，使用 $CONTAINER_CMD 和 $DOCKER_COMPOSE_CMD"
    else
      err "Docker 安装失败，请手动检查。"
      exit 1
    fi
  fi
}

check_system_requirements() {
  log "检查系统要求..."
  
  # 检查内存
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/{print $2}')
  log "系统总内存: ${total_mem}MB"
  if [ "${total_mem}" -lt 2048 ]; then
    err "系统内存不足。建议至少2GB内存"
    exit 1
  fi
  
  # 检查磁盘空间
  local free_space
  free_space=$(df -m /opt | awk 'NR==2 {print $4}')
  log "可用磁盘空间: ${free_space}MB"
  if [ "${free_space}" -lt 10240 ]; then
    err "磁盘空间不足。建议至少10GB可用空间"
    exit 1
  fi
  
  # 检查网络连接
  log "检查网络连接..."
  local urls=(
    "download.docker.com"
    "github.com"
    "raw.githubusercontent.com"
  )
  
  for url in "${urls[@]}"; do
    if ! ping -c 1 "$url" &>/dev/null; then
      err "无法连接到 $url，请检查网络连接"
      return 1
    fi
  done
  
  log "系统要求检查通过"
  return 0
}

check_ports() {
  log "检查必要端口..."
  local ports=(80 443 "${DIFY_PORT}")
  
  for port in "${ports[@]}"; do
    if lsof -i:"${port}" | grep -q LISTEN; then
      err "端口 ${port} 已被占用"
      lsof -i:"${port}"
      return 1
    fi
  done
  
  log "所需端口均可用"
  return 0
}

install_prereqs() {
  log "开始安装/检测依赖：docker / docker compose / nginx / git / curl / acme.sh ..."
  
  # 系统检查
  check_system_requirements || exit 1
  
  # 检查必要端口
  check_ports || exit 1
  
  # 检测并安装容器运行时
  detect_container_runtime
  
  # 设置 Docker 用户组
  if ! getent group docker >/dev/null; then
    log "创建 docker 用户组..."
    groupadd docker
  fi
  log "将当前用户添加到 docker 用户组..."
  usermod -aG docker "${SUDO_USER:-$USER}"
  
  if ! cmd_exists nginx; then
    log "安装 nginx..."
    if cmd_exists apt-get; then
      apt-get update
      apt-get install -y nginx
    elif cmd_exists dnf; then
      dnf install -y nginx
    elif cmd_exists yum; then
      yum install -y epel-release
      yum install -y nginx
    fi
    systemctl enable --now nginx || true
  else
    log "检测到 nginx 已安装"
  fi
  
  # 安装其他必要工具
  local packages=(git curl wget lsof)
  for pkg in "${packages[@]}"; do
    if ! cmd_exists "$pkg"; then
      log "安装 $pkg ..."
      if cmd_exists apt-get; then
        apt-get update && apt-get install -y "$pkg"
      elif cmd_exists dnf; then
        dnf install -y "$pkg"
      elif cmd_exists yum; then
        yum install -y "$pkg"
      fi || { err "$pkg 安装失败"; exit 1; }
    fi
  done
  
  log "所有依赖安装完成"
}

install_acme_sh() {
  if [ ! -f "$HOME/.acme.sh/acme.sh" ] && ! cmd_exists acme.sh; then
    log "安装 acme.sh..."
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
  else
    log "检测到 acme.sh 已安装。"
  fi
}

collect_input() {
  read -rp "主域名（例如 example.com）：" BASE_DOMAIN
  [ -n "$BASE_DOMAIN" ] || { err "必须提供主域名，例如 example.com"; exit 1; }

  # 输入子域名（可选）
  read -rp "Dify 子域名（默认 dify.$BASE_DOMAIN）: " DIFY
  
  # 如果用户有输入 DIFY，就拼接；否则用默认值
  if [ -n "$DIFY" ]; then
    DIFY_HOST="${DIFY}.${BASE_DOMAIN}"
  else
    DIFY_HOST="dify.${BASE_DOMAIN}"
  fi

  read -rp "用于 Let's Encrypt 的邮箱（可留空）：" LETSENCRYPT_EMAIL
  LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-}

  read -rp "Dify 对外 HTTP 端口（宿主机），回车默认 8080" DIFY_PORT
  DIFY_PORT=${DIFY_PORT:-8080}
    if lsof -i:"${DIFY_PORT}" | grep LISTEN; then
        err "端口 ${DIFY_PORT} 已被占用，请更换端口或停止相关服务。"
        exit 1
    fi
  log "配置总结：\n  Dify -> $DIFY_HOST -> localhost:$DIFY_PORT\n  email -> ${LETSENCRYPT_EMAIL:-(未提供)}"
}

deploy_dify() {
  log "开始部署 Dify..."
  if [ ! -d "$DIFY_DIR" ]; then
    git clone https://github.com/langgenius/dify.git "$DIFY_DIR"
  else
    log "$DIFY_DIR 已存在，尝试 pull 最新代码"
    (cd "$DIFY_DIR" && git pull --no-rebase) || true
  fi

  if [ ! -d "$DIFY_DIR/docker" ]; then
    err "未在 $DIFY_DIR 找到 docker 目录，请检查仓库结构。"
    return 1
  fi

  cd "$DIFY_DIR/docker"
  cp docker-compose.yaml docker-compose.yaml.bak.$(date +%s) || true

  # 优先使用官方推荐方式：修改 .env 中的 EXPOSE_NGINX_PORT / EXPOSE_NGINX_SSL_PORT
  if [ -f .env ]; then
    cp .env .env.bak.$(date +%s) || true
  elif [ -f .env.example ]; then
    cp .env.example .env
    log "已从 .env.example 复制 .env"
  else
    touch .env
  fi

  # 设置 EXPOSE_NGINX_PORT 为用户指定的 DIFY_PORT（确保后端绑定到回环或该端口）
  if grep -q "^EXPOSE_NGINX_PORT=" .env 2>/dev/null; then
    sed -i "s/^EXPOSE_NGINX_PORT=.*/EXPOSE_NGINX_PORT=${DIFY_PORT}/" .env
  else
    echo "EXPOSE_NGINX_PORT=${DIFY_PORT}" >> .env
  fi

  # 为避免占用宿主的 443 端口，默认将 EXPOSE_NGINX_SSL_PORT 设置为 0（不对外暴露）
  # 因为主机 nginx 会在 443 上终止 TLS 并反向代理到 EXPOSE_NGINX_PORT
  if grep -q "^EXPOSE_NGINX_SSL_PORT=" .env 2>/dev/null; then
    sed -i "s/^EXPOSE_NGINX_SSL_PORT=.*/EXPOSE_NGINX_SSL_PORT=0/" .env
  else
    echo "EXPOSE_NGINX_SSL_PORT=0" >> .env
  fi

  log "已更新 .env 中的 EXPOSE_NGINX_PORT 与 EXPOSE_NGINX_SSL_PORT（备份: .env.bak*）。"
  log "显示 .env 中相关行："
  grep -E "^EXPOSE_NGINX_PORT|^EXPOSE_NGINX_SSL_PORT" .env || true

  if ! systemctl is-active --quiet docker; then
  log "Docker 服务未运行，正在尝试启动..."
  if ! systemctl start docker; then
    err "无法启动 Docker 服务，请检查："
    err "1. Docker 是否已正确安装"
    err "2. systemctl 是否有权限访问"
    err "3. 查看详细日志: journalctl -u docker --no-pager -n 50"
    return 1
  fi
  log "Docker 服务已成功启动"
fi
  log "使用 Docker Compose 启动 Dify（使用修改后的 .env）..."
  docker compose up -d || { err "Dify 启动失败，请查看日志 (docker compose logs)"; return 1; }
  log "Dify 容器已启动。"
}

setup_nginx() {
  log "创建 nginx 的反向代理配置"
  mkdir -p "$NGINX_CONF_DIR"  || { err "无法创建 $NGINX_CONF_DIR"; return 1; }
  log "重定向所有的 HTTP 请求到 HTTPS"
  cat > "$NGINX_CONF_DIR/redirecthttp2https.conf" <<NGD
server {
    listen 80;
    server_name $DIFY_HOST;

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGD
  if [ -f "$NGINX_CONF_DIR/redirecthttp2https.conf" ]; then
    log "已生成 $NGINX_CONF_DIR/redirecthttp2https.conf"
    cat "$NGINX_CONF_DIR/redirecthttp2https.conf"
  else
    err "未能生成 $NGINX_CONF_DIR/redirecthttp2https.conf"
    return 1
  fi

  nginx -t && service nginx reload || { err "nginx 配置测试或重载失败，请检查 /var/log/nginx/error.log"; return 1; }
  # 检查 SELinux 状态
SELINUX_STATUS=$(getenforce)

if [[ "$SELINUX_STATUS" == "Enforcing" || "$SELINUX_STATUS" == "Permissive" ]]; then
    echo "SELinux 当前状态: $SELINUX_STATUS"
    echo "设置 httpd_can_network_connect..."
    setsebool -P httpd_can_network_connect 1
    if [[ $? -eq 0 ]]; then
        echo "✅ 成功允许 nginx/httpd 连接外部网络"
    else
        echo "❌ 设置失败，请检查权限"
    fi
else
    echo "SELinux 当前状态: $SELINUX_STATUS (未启用，无需设置)"
fi
}

issue_and_install_cert() {
  local domain="$1"
  log "为 $domain 申请证书（使用 acme.sh webroot 模式）..."
  export PATH="$HOME/.acme.sh:$PATH"

  if [ -n "$LETSENCRYPT_EMAIL" ]; then
    log "注册/更新 acme.sh ACME 账号的 contact email 为 $LETSENCRYPT_EMAIL ..."
    ~/.acme.sh/acme.sh --register-account -m "$LETSENCRYPT_EMAIL" || true
  else
    log "未提供邮箱，acme.sh 将以无 contact 的账号注册（默认）。"
  fi
  
  log "设置 acme.sh 使用 Let's Encrypt CA..."
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt || true
  log "申请证书..."
  ~/.acme.sh/acme.sh --issue --nginx -d "$domain"  || { err "acme.sh 为 $domain 申请证书失败"; return 1; }

  local cert_dir="/etc/letsencrypt/$domain"
  mkdir -p "$cert_dir"
  log "安装证书到 $cert_dir ..."
  ~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --cert-file "$cert_dir/fullchain.cer" \
    --key-file "$cert_dir/$domain.key" \
    --reloadcmd "service nginx reload" || { err "安装证书失败"; return 1; }

  log "$domain 的证书已安装到 $cert_dir"

  cat > "$NGINX_CONF_DIR/${domain}.ssl.conf" <<NGSSL
server {
    listen 443 ssl http2;
    server_name $domain;

    # SSL 证书配置
    ssl_certificate /etc/letsencrypt/$domain/fullchain.cer;
    ssl_certificate_key /etc/letsencrypt/$domain/$domain.key;

    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    # 日志配置
    access_log /var/log/nginx/\$host.access.log combined buffer=512k flush=1m;
    error_log /var/log/nginx/\$host.error.log warn;

    # 代理设置
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 代理缓冲设置
        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 8 32k;
        proxy_busy_buffers_size 64k;
        
        proxy_pass http://127.0.0.1:${DIFY_PORT};
    }

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
NGSSL

  nginx -t && service nginx reload || err "nginx 重载失败（证书安装后）。"
}

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log "检测到安装失败，开始清理..."
    
    # 停止并删除所有运行的容器
    if cmd_exists docker; then
      log "停止并删除相关Docker容器..."
      docker ps -a | grep "dify" | awk '{print $1}' | xargs -r docker rm -f
    fi
    
    # 删除创建的nginx配置
    if [ -f "$NGINX_CONF_DIR/redirecthttp2https.conf" ]; then
      log "删除Nginx配置..."
      rm -f "$NGINX_CONF_DIR/redirecthttp2https.conf"
      rm -f "$NGINX_CONF_DIR/${DIFY_HOST}.ssl.conf"
      systemctl reload nginx
    fi
    
    # 恢复备份的文件
    if [ -f "$DIFY_DIR/docker/docker-compose.yaml.bak" ]; then
      log "恢复备份文件..."
      mv "$DIFY_DIR/docker/docker-compose.yaml.bak" "$DIFY_DIR/docker/docker-compose.yaml"
    fi
    
    log "清理完成。请检查错误信息并重试安装。"
  fi
}

# 设置trap以在脚本退出时进行清理
trap cleanup EXIT

main() {
  usage() {
    cat <<'USAGE'
Usage: $0 <command>
Commands:
  all                 Run full end-to-end deployment (default interactive)
  prereqs             Install prerequisites (docker, compose, nginx, git, curl)
  acme                Install acme.sh only
  dify                Deploy or update Dify only
  nginx               Generate nginx config and reload
  certs               Issue Let's Encrypt certs for both hosts
  status              Show docker compose ps for Dify
  help                Show this help
USAGE
  }

  run_prereqs() {
    install_prereqs
    install_acme_sh
  }

  run_certs() {
    issue_and_install_cert "$DIFY_HOST" || return 1
  }

  if [ "$#" -gt 0 ]; then
    cmd="$1"
  else
    echo "请选择要执行的操作："
    echo " 1) 全部部署 (prereqs -> dify -> nginx -> certs)"
    echo " 2) 仅安装依赖 (docker / docker-compose / nginx / git / curl)"
    echo " 3) 仅安装 acme.sh"
    echo " 4) 仅部署 Dify"
    echo " 5) 仅创建 nginx 配置并 reload"
    echo " 6) 仅申请/安装证书"
    echo " 7) 查看 Dify 的 docker compose 状态"
    echo " 8) 退出"
    read -rp "输入数字 (默认 1): " sel
    sel=${sel:-1}
    case "$sel" in
      1) cmd=all ;;
      2) cmd=prereqs ;;
      3) cmd=acme ;;
      4) cmd=dify ;;
      5) cmd=nginx ;;
      6) cmd=certs ;;
      7) cmd=status ;;
      *) echo "退出"; exit 0 ;;
    esac
  fi

  case "$cmd" in
    all)
      require_root
      collect_input
      install_prereqs
      install_acme_sh

      deploy_dify || log "Dify 部署失败"
      setup_nginx || true
      run_certs || true
      ;;
    prereqs)
      require_root
      collect_input
      install_prereqs
      ;;
    acme)
      require_root
      install_acme_sh
      ;;
    dify)
      require_root
      collect_input
      deploy_dify
      ;;
    nginx)
      require_root
      collect_input
      setup_nginx
      ;;
    certs)
      require_root
      collect_input
      run_certs
      ;;
    status)
      echo "Dify (if present):"
      if [ -d "$DIFY_DIR/docker" ]; then
        (cd "$DIFY_DIR/docker" && $DOCKER_COMPOSE_CMD ps) || true
      else
        echo "Dify directory not found: $DIFY_DIR"
      fi
      echo
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      err "未知命令: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"