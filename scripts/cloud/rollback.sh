#!/usr/bin/env bash
# ============================================================
#  回滚到上一个版本（或指定版本）
#
#    bash scripts/cloud/rollback.sh              # 回到上一版
#    bash scripts/cloud/rollback.sh 20260101-120000   # 回到指定版本
#
#  原理：deploy.sh 每次部署前会把正在运行的镜像打成 :rollback，
#  回滚就是「用旧镜像重新起一遍容器」，几十秒完成，不用重新构建。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_DIR="${ROOT_DIR}/deploy/cloud"
COMPOSE_FILE="${CLOUD_DIR}/docker-compose.prod.yml"
ENV_FILE="${CLOUD_DIR}/.env"
TAG_FILE="${CLOUD_DIR}/runtime/.current-tag"
PREV_TAG_FILE="${CLOUD_DIR}/runtime/.previous-tag"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[失败] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "找不到 ${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export IMAGE_PREFIX="${IMAGE_PREFIX:-}"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    [[ -f "$PREV_TAG_FILE" ]] || die "没有上一版记录（${PREV_TAG_FILE} 不存在），请手动指定版本号"
    TARGET="$(cat "$PREV_TAG_FILE")"
fi

if ! docker image inspect "${IMAGE_PREFIX}fullstack-backend:${TARGET}" >/dev/null 2>&1; then
    echo "本地镜像列表："
    docker images "${IMAGE_PREFIX:-}fullstack-backend" --format '  {{.Tag}}  {{.CreatedSince}}'
    die "镜像 ${IMAGE_PREFIX}fullstack-backend:${TARGET} 不存在"
fi

log "回滚到 ${TARGET}"
TAG="$TARGET" compose up -d --remove-orphans

sleep 10
compose ps

log "回滚完成。确认无误后执行："
echo "    echo ${TARGET} > ${TAG_FILE}"
