#!/usr/bin/env bash
# ============================================================
#  一键部署（在服务器上执行）
#
#    bash scripts/cloud/deploy.sh
#
#  流程（任何一步失败都会中止并说明原因）：
#    1. 检查 .env 是否填好、权限是否 600
#    2. 用 envsubst 生成带密码的 runtime 配置（不进仓库）
#    3. 没证书就生成自签证书，保证第一次一定能起来
#    4. 记录当前版本并把镜像打成 :rollback（回滚用）
#    5. 构建镜像 → 启动 → 等健康检查
#    6. 健康检查失败 → 自动切回上一版
#    7. 成功 → 记录版本号并清理旧镜像
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_DIR="${ROOT_DIR}/deploy/cloud"
COMPOSE_FILE="${CLOUD_DIR}/docker-compose.prod.yml"
ENV_FILE="${CLOUD_DIR}/.env"
RUNTIME_DIR="${CLOUD_DIR}/runtime"
TAG_FILE="${RUNTIME_DIR}/.current-tag"
PREV_TAG_FILE="${RUNTIME_DIR}/.previous-tag"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[失败] %s\033[0m\n' "$*" >&2; exit 1; }

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# ---------- 0. 前置检查 ----------
command -v docker >/dev/null 2>&1 || die "未安装 Docker，请先执行 scripts/cloud/init-server.sh"
command -v envsubst >/dev/null 2>&1 || die "缺少 envsubst，请执行：apt-get install -y gettext-base"
[[ -f "$ENV_FILE" ]] || die "找不到 ${ENV_FILE}。请先执行：
    cd ${CLOUD_DIR}
    cp .env.production.example .env && chmod 600 .env
    vim .env"

if grep -q "CHANGE_ME" "$ENV_FILE"; then
    die ".env 里还有 CHANGE_ME 未替换，请把所有占位值改成真实值"
fi

if [[ "$(stat -c %a "$ENV_FILE")" != "600" ]]; then
    chmod 600 "$ENV_FILE"
    warn ".env 权限已自动修正为 600"
fi

# ---------- 1. 载入变量 ----------
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for var in DOMAIN MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD MYSQL_REPL_PASSWORD REDIS_PASSWORD; do
    [[ -n "${!var:-}" ]] || die "环境变量 ${var} 未设置"
done

# envsubst 不支持 ${VAR:-default} 语法，这里在 shell 层补默认值
export REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-200mb}"
export TAG="${TAG_OVERRIDE:-$(date +%Y%m%d-%H%M%S)}"
export IMAGE_PREFIX="${IMAGE_PREFIX:-}"

log "部署版本 TAG = ${TAG}"
log "域名 DOMAIN = ${DOMAIN}"

# 提前校验 compose 语法，别等到拉完镜像才报错
compose config -q || die "docker-compose.prod.yml 配置有误"
ok "compose 配置校验通过"

# ---------- 2. 生成运行时配置 ----------
log "生成 runtime 配置（含密码，权限 600）"
mkdir -p "${RUNTIME_DIR}/init" "${CLOUD_DIR}/certs" "${CLOUD_DIR}/certbot-webroot"

# 只替换指定变量，避免误伤配置里其它 $ 符号
envsubst '$REDIS_PASSWORD $REDIS_MAXMEMORY' \
    < "${CLOUD_DIR}/redis.prod.conf.template" \
    > "${RUNTIME_DIR}/redis.conf"
chmod 600 "${RUNTIME_DIR}/redis.conf"

envsubst '$MYSQL_DATABASE $MYSQL_USER $MYSQL_PASSWORD' \
    < "${CLOUD_DIR}/init/01-init.sql.template" \
    > "${RUNTIME_DIR}/init/01-init.sql"
chmod 600 "${RUNTIME_DIR}/init/01-init.sql"

# Redis 配置变了（比如改了密码）必须重启 redis，否则容器还在用旧配置。
# compose up -d 只在「服务定义变化」时重建容器，不会因为挂载的文件内容变了就重启。
REDIS_CONF_CHANGED=0
CONF_HASH_FILE="${RUNTIME_DIR}/.redis-conf.sha256"
NEW_HASH="$(sha256sum "${RUNTIME_DIR}/redis.conf" | awk '{print $1}')"
OLD_HASH="$(cat "$CONF_HASH_FILE" 2>/dev/null || true)"
if [[ -n "$OLD_HASH" && "$NEW_HASH" != "$OLD_HASH" ]]; then
    REDIS_CONF_CHANGED=1
    warn "检测到 Redis 配置变化，稍后会重启 redis 容器"
fi
echo "$NEW_HASH" > "$CONF_HASH_FILE"

ok "redis.conf / 01-init.sql 已生成"

# ---------- 3. HTTPS 证书 ----------
if [[ ! -f "${CLOUD_DIR}/certs/fullchain.pem" || ! -f "${CLOUD_DIR}/certs/privkey.pem" ]]; then
    warn "未找到证书，先生成 30 天自签证书（浏览器会提示不安全，仅用于首次跑通）"
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout "${CLOUD_DIR}/certs/privkey.pem" \
        -out "${CLOUD_DIR}/certs/fullchain.pem" \
        -subj "/CN=${DOMAIN}" >/dev/null 2>&1
    chmod 600 "${CLOUD_DIR}/certs/privkey.pem"
    warn "拿到正式证书后，替换 certs/ 下两个文件并执行：compose restart lb"
else
    ok "使用已有证书"
fi

# ---------- 4. 记录上一版（用于自动回滚） ----------
PREV_TAG=""
if [[ -f "$TAG_FILE" ]]; then
    PREV_TAG="$(cat "$TAG_FILE")"
    echo "$PREV_TAG" > "$PREV_TAG_FILE"
    for img in fullstack-backend fullstack-frontend; do
        docker tag "${IMAGE_PREFIX}${img}:${PREV_TAG}" "${IMAGE_PREFIX}${img}:rollback" 2>/dev/null || true
    done
    ok "已把上一版 ${PREV_TAG} 标记为 :rollback"
fi

# ---------- 5. 构建并启动 ----------
if [[ "${USE_PREBUILT_IMAGE:-false}" == "true" ]]; then
    log "使用预构建镜像（从镜像仓库拉取）"
    compose pull
else
    log "构建镜像（首次约 3~8 分钟，取决于机器和网速）"
    compose build --pull backend-1 frontend
fi

if [[ "$REDIS_CONF_CHANGED" == "1" && -n "$(compose ps -q redis 2>/dev/null || true)" ]]; then
    compose restart redis
    ok "redis 已按新配置重启"
fi

log "启动 / 更新容器"
compose up -d --remove-orphans

# ---------- 6. 健康检查 ----------
wait_healthy() {
    local deadline=$(( SECONDS + 240 ))
    while (( SECONDS < deadline )); do
        local all_ok=1
        for svc in backend-1 backend-2 backend-3; do
            local cid status
            cid="$(compose ps -q "$svc" 2>/dev/null || true)"
            [[ -n "$cid" ]] || { all_ok=0; break; }
            status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)"
            [[ "$status" == "healthy" ]] || { all_ok=0; break; }
        done

        # Nginx + TLS 是否真的在服务（-k 忽略自签证书）
        if (( all_ok == 1 )) && curl -fsSk --max-time 5 https://127.0.0.1/healthz >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

log "等待服务健康（最多 4 分钟）"
if wait_healthy; then
    ok "全部副本健康，TLS 入口正常"
    echo "$TAG" > "$TAG_FILE"
else
    warn "健康检查超时，开始回滚"
    compose ps
    if docker image inspect "${IMAGE_PREFIX}fullstack-backend:rollback" >/dev/null 2>&1; then
        TAG=rollback compose up -d --remove-orphans || true
        die "已回滚到上一版本。请查看日志：
    docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs --tail=120 backend-1"
    fi
    die "没有可回滚的版本。请查看日志：
    docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs --tail=120 backend-1
    docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs --tail=80 mysql-master"
fi

# ---------- 7. 收尾 ----------
docker image prune -f >/dev/null 2>&1 || true

cat <<EOF

============================================================
 部署完成 ✅  版本 ${TAG}

 访问地址 : https://${DOMAIN}
 健康检查 : https://${DOMAIN}/api/system/health
 接口文档 : 生产默认关闭（需要时改 nginx 模板里的 /docs 注释）

 常用命令：
   cd ${CLOUD_DIR}
   docker compose --env-file .env -f docker-compose.prod.yml ps
   docker compose --env-file .env -f docker-compose.prod.yml logs -f backend-1
   bash ${SCRIPT_DIR}/backup.sh          # 手动备份
   bash ${SCRIPT_DIR}/rollback.sh        # 回滚上一版
============================================================
EOF
