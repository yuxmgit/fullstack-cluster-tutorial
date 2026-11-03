#!/usr/bin/env bash
# ============================================================
#  备份 MySQL + Redis
#
#    bash scripts/cloud/backup.sh
#
#  自动清理超过 BACKUP_KEEP_DAYS 天的旧备份；
#  配置了 coscli 且 BACKUP_TO_COS=true 时，还会同步到腾讯云 COS。
#
#  加入定时任务（每天 3:10）：
#    sudo crontab -e
#    10 3 * * * /opt/fullstack-cluster-tutorial/scripts/cloud/backup.sh >> /var/log/app-backup.log 2>&1
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_DIR="${ROOT_DIR}/deploy/cloud"
COMPOSE_FILE="${CLOUD_DIR}/docker-compose.prod.yml"
ENV_FILE="${CLOUD_DIR}/.env"
BACKUP_DIR="${BACKUP_DIR:-${ROOT_DIR}/backups}"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[失败] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "找不到 ${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# ---------- MySQL ----------
log "备份 MySQL（${MYSQL_DATABASE}）"
# 用 MYSQL_PWD 环境变量传密码，而不是 -p 参数：
# -p 会出现在进程列表里，机器上任何用户都能看到。
compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql-master \
    mysqldump -uroot --single-transaction --quick --routines --events \
    --databases "${MYSQL_DATABASE}" \
    | gzip > "${BACKUP_DIR}/mysql-${STAMP}.sql.gz"

[[ -s "${BACKUP_DIR}/mysql-${STAMP}.sql.gz" ]] || die "MySQL 备份文件为空"
log "  → mysql-${STAMP}.sql.gz"

# ---------- Redis ----------
log "备份 Redis"
# REDISCLI_AUTH 同样是为了避免密码出现在命令行
compose exec -T -e REDISCLI_AUTH="${REDIS_PASSWORD}" redis redis-cli SAVE >/dev/null
compose cp redis:/data/dump.rdb "${BACKUP_DIR}/redis-${STAMP}.rdb" >/dev/null
log "  → redis-${STAMP}.rdb"

# ---------- 清理旧备份 ----------
KEEP="${BACKUP_KEEP_DAYS:-7}"
log "清理 ${KEEP} 天前的备份"
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.rdb' \) -mtime +"$KEEP" -delete

# ---------- 可选：同步到 COS ----------
if [[ "${BACKUP_TO_COS:-false}" == "true" ]]; then
    if command -v coscli >/dev/null 2>&1; then
        [[ -n "${COS_BUCKET:-}" ]] || die "BACKUP_TO_COS=true 但没有配置 COS_BUCKET"
        log "上传到 cos://${COS_BUCKET}/db-backup/"
        coscli cp "${BACKUP_DIR}" "cos://${COS_BUCKET}/db-backup/" -r
    else
        log "跳过 COS 上传：未安装 coscli"
    fi
fi

log "备份完成，目录：${BACKUP_DIR}"
du -sh "$BACKUP_DIR" 2>/dev/null || true
