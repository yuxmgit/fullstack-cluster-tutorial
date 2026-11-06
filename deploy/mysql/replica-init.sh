#!/bin/bash
# ============================================================
#  一次性容器：自动把 MySQL 主从复制配好
#
#  它做三件事：
#    1. 等主库、从库都真正就绪（用 ping 探测，不用盲等）
#    2. 在主库创建专用复制账号 repl
#    3. 让从库以 GTID 自动定位（SOURCE_AUTO_POSITION=1）开始复制
#
#  为什么用 GTID 自动定位？
#    不需要人工记录「主库 binlog 文件名 + 偏移量」，
#    从库从主库第一条 binlog 开始拉，主库的历史变更（建库、建表、初始数据）
#    会全部自动同步过去。
# ============================================================
set -euo pipefail

MASTER_HOST="${MASTER_HOST:-mysql-master}"
SLAVE_HOST="${SLAVE_HOST:-mysql-slave}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-rootpass}"
REPL_USER="${REPL_USER:-repl}"
REPL_PASS="${REPL_PASS:-replpass}"

wait_for() {
  local host="$1"
  local name="$2"
  echo "[replica-init] 等待 ${name} (${host}) 就绪 ..."
  for _ in $(seq 1 60); do
    if mysqladmin ping -h "$host" -uroot -p"$ROOT_PASS" --silent >/dev/null 2>&1; then
      echo "[replica-init] ${name} 已就绪"
      sleep 2
      return 0
    fi
    sleep 2
  done
  echo "[replica-init] 等待 ${name} 超时" >&2
  return 1
}

wait_for "$MASTER_HOST" "主库"
wait_for "$SLAVE_HOST" "从库"

echo "[replica-init] 在主库创建复制账号 ${REPL_USER} ..."
mysql -h "$MASTER_HOST" -uroot -p"$ROOT_PASS" <<SQL
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "[replica-init] 配置从库复制关系 ..."
# 复制尚未启动时 STOP 会报错，用 || true 忽略
mysql -h "$SLAVE_HOST" -uroot -p"$ROOT_PASS" -e "STOP REPLICA;" >/dev/null 2>&1 || true

mysql -h "$SLAVE_HOST" -uroot -p"$ROOT_PASS" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_USER='${REPL_USER}',
  SOURCE_PASSWORD='${REPL_PASS}',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
# 只读：防止业务代码或人肉操作误写到从库。
# 不能写进启动参数（会阻塞首次初始化），用 SET PERSIST 持久化到数据目录，
# 重启后依然生效，等效于写在配置文件里。
# （复制线程是特权线程，不受此限制，所以同步照常进行）
SET PERSIST read_only=ON;
SET PERSIST super_read_only=ON;
START REPLICA;
SQL

sleep 3
echo "[replica-init] 当前复制状态："
mysql -h "$SLAVE_HOST" -uroot -p"$ROOT_PASS" -e "SHOW REPLICA STATUS\G" \
  | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error|Last_SQL_Error" || true

echo "[replica-init] 完成 ✅"
