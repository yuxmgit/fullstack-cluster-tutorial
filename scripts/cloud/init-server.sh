#!/usr/bin/env bash
# ============================================================
#  腾讯云服务器一键初始化（Ubuntu 22.04 / 24.04）
#
#  在服务器上用 root 执行：
#    curl -fsSL https://你的仓库地址/scripts/cloud/init-server.sh | bash
#  或先把代码传上去再执行：
#    sudo bash scripts/cloud/init-server.sh
#
#  它做 8 件事（全部幂等，重复执行安全）：
#    1. 装基础工具
#    2. 设时区
#    3. 装 Docker + compose 插件（腾讯云内网镜像加速）
#    4. 建部署用户 deploy
#    5. 加 2G swap（1~2G 内存的小机器必备，否则编译前端会 OOM）
#    6. 开防火墙：只放行 22 / 80 / 443
#    7. 装 fail2ban 防 SSH 爆破
#    8. 调内核参数（Redis 的 overcommit、连接队列）
# ============================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 执行：sudo bash $0"
    exit 1
fi

APP_USER="${APP_USER:-deploy}"
APP_DIR="${APP_DIR:-/opt/fullstack-cluster-tutorial}"
TZ_NAME="${TZ_NAME:-Asia/Shanghai}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
# 腾讯云 CVM 内网镜像加速，非腾讯云机器请设 USE_TENCENT_MIRROR=0
USE_TENCENT_MIRROR="${USE_TENCENT_MIRROR:-1}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

# ---------- 1. 基础工具 ----------
log "更新软件源并安装基础工具"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git jq unzip rsync cron \
    gettext-base ufw fail2ban chrony openssl

# ---------- 2. 时区 ----------
log "设置时区为 ${TZ_NAME}"
timedatectl set-timezone "$TZ_NAME" 2>/dev/null || warn "时区设置失败，忽略"
systemctl enable --now chrony >/dev/null 2>&1 || true

# ---------- 3. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker（官方脚本）"
    curl -fsSL https://get.docker.com | sh
else
    log "Docker 已安装，跳过"
fi
systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    log "安装 docker compose 插件"
    apt-get install -y docker-compose-plugin
fi

# 镜像加速 + 日志轮转（在 daemon 层兜底，容器级别也配了一份）
mkdir -p /etc/docker
if [[ "$USE_TENCENT_MIRROR" == "1" ]]; then
    log "配置腾讯云内网镜像加速"
    cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
fi
systemctl restart docker
sleep 2
docker version --format '{{.Server.Version}}' >/dev/null && log "Docker 就绪"

# ---------- 4. 部署用户 ----------
if ! id "$APP_USER" >/dev/null 2>&1; then
    log "创建部署用户 ${APP_USER}"
    useradd -m -s /bin/bash "$APP_USER"
fi
usermod -aG docker "$APP_USER"
mkdir -p "$APP_DIR"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ---------- 5. swap ----------
if ! swapon --show | grep -q .; then
    log "创建 ${SWAP_SIZE} swap 文件"
    if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
else
    log "swap 已存在，跳过"
fi

# ---------- 6. 防火墙 ----------
# 顺序很重要：先放行 SSH，再 enable，否则会把自己关在门外
log "配置防火墙（只放行 22 / 80 / 443）"
ufw allow 22/tcp   >/dev/null
ufw allow 80/tcp   >/dev/null
ufw allow 443/tcp  >/dev/null
ufw --force enable >/dev/null
ufw status verbose

# ---------- 7. fail2ban ----------
log "启用 fail2ban（SSH 连续失败 5 次封 10 分钟）"
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 600
findtime = 600
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban 启动失败，可稍后手动检查"

# ---------- 8. 内核参数 ----------
log "调整内核参数"
cat > /etc/sysctl.d/99-app.conf <<'EOF'
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
# Redis 官方建议：允许内存超额分配，避免 fork 时 OOM
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null

# ---------- 完成 ----------
cat <<EOF

============================================================
 初始化完成 ✅

 下一步：
   1. 把代码放到 ${APP_DIR}（用 scripts/cloud/publish.ps1 或 git clone）
   2. cd ${APP_DIR}/deploy/cloud
      cp .env.production.example .env && chmod 600 .env
      vim .env          # 填域名 + 5 个密码，把所有 CHANGE_ME 换掉
   3. sudo -u ${APP_USER} bash ${APP_DIR}/scripts/cloud/deploy.sh

 检查防火墙：
   ufw status
 检查 Docker：
   docker ps
============================================================
EOF
