#!/usr/bin/env bash
# deploy_dify_onekey.sh
# 运行：sudo -i;bash deploy_dify_onekey.sh
# version: 0.01 2025-08-18

set -euo pipefail
IFS=$'\n\t'

WORKDIR=/opt
DIFY_DIR="$WORKDIR/dify"
NGINX_CONF_DIR=/etc/nginx/conf.d
DOCKER_SOURCE="auto"   # 可通过环境变量覆盖为 'distro' 或 'official'
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

install_docker_from_distro() {
  log "尝试从发行版仓库安装 docker (distro)..."
  if cmd_exists apt-get; then
    apt-get update
    apt-get install -y docker.io || return 1
  elif cmd_exists dnf; then
    dnf install -y docker || return 1
    systemctl enable --now docker || true
  elif cmd_exists yum; then
    yum install -y docker || return 1
    systemctl enable --now docker || true
  else
    return 1
  fi
  return 0
}

install_docker_from_official() {
  log "尝试使用 Docker 官方仓库安装 docker (official)..."
  if cmd_exists apt-get; then
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    DIST_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"') || DIST_ID="ubuntu"
    curl -fsSL "https://download.docker.com/linux/${DIST_ID}/gpg" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${DIST_ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin|| return 1
  elif cmd_exists yum || cmd_exists dnf; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin|| return 1
    systemctl enable --now docker || true
  else
    return 1
  fi
  return 0
}

install_docker() {
  log "决定 Docker 安装来源（DOCKER_SOURCE=${DOCKER_SOURCE})..."
  if [ "$DOCKER_SOURCE" = "distro" ]; then
    install_docker_from_distro || { err "从发行版仓库安装 Docker 失败"; exit 1; }
  elif [ "$DOCKER_SOURCE" = "official" ]; then
    install_docker_from_official || { err "从官方仓库安装 Docker 失败"; exit 1; }
  else
    if install_docker_from_distro; then
      ver=$(get_docker_version)
      if [ -n "$ver" ] && ver_ge "$ver" "$MIN_DOCKER_VERSION"; then
        log "检测到发行版 Docker 版本 $ver，满足最小要求，使用 distro 包。"
      else
        log "发行版 Docker 版本 ($ver) 不满足最小要求，尝试官方源安装。"
        install_docker_from_official || { err "官方源安装失败"; exit 1; }
      fi
    else
      log "发行版仓库无法安装 Docker，尝试官方源安装。"
      install_docker_from_official || { err "官方源安装失败"; exit 1; }
    fi
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

install_prereqs() {
  log "开始安装/检测依赖：docker / docker compose / nginx / git / curl / acme.sh ..."
  detect_container_runtime

  if ! cmd_exists nginx; then
    log "安装 nginx..."
    if cmd_exists apt-get; then
      apt-get update && apt-get install -y nginx
    elif cmd_exists dnf; then
      dnf install -y nginx
    elif cmd_exists yum; then
      yum install -y epel-release && yum install -y nginx
    fi
    systemctl enable --now nginx || true
  else
    log "检测到 nginx 已安装。"
  fi

  for pkg in git curl; do
    if ! cmd_exists $pkg; then
      log "安装 $pkg ..."
      if cmd_exists apt-get; then apt-get update && apt-get install -y $pkg; elif cmd_exists dnf; then dnf install -y $pkg; elif cmd_exists yum; then yum install -y $pkg; fi
    fi
  done
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
    listen 443 ssl;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/$domain/fullchain.cer;
    ssl_certificate_key /etc/letsencrypt/$domain/$domain.key;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${DIFY_PORT};
    }
}
NGSSL

  nginx -t && service nginx reload || err "nginx 重载失败（证书安装后）。"
}

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
      install_prereqs
      install_acme_sh
      collect_input
      deploy_dify || log "Dify 部署失败"
      setup_nginx || true
      run_certs || true
      ;;
    prereqs)
      require_root
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
