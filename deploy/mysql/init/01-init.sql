-- ============================================================
--  只在「主库首次初始化」时执行一次（mysql 镜像机制：
--  /docker-entrypoint-initdb.d/*.sql 仅在数据目录为空时运行）。
--
--  这些语句也会通过 binlog 自动复制到从库，
--  所以从库不需要单独初始化数据 —— 这正是 GTID 自动定位的好处。
-- ============================================================

CREATE DATABASE IF NOT EXISTS fullstack_demo
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- 应用账号：只给它业务库的权限，不给全局权限（最小权限原则）
CREATE USER IF NOT EXISTS 'demo'@'%' IDENTIFIED WITH mysql_native_password BY 'demo123';
GRANT ALL PRIVILEGES ON fullstack_demo.* TO 'demo'@'%';

-- ProxySQL 监控账号：代理用它探测后端存活和 read_only 状态
-- （见 deploy/proxysql/proxysql.cnf 的 monitor_username）。
-- USAGE = 不授权任何操作，只允许登录；REPLICATION CLIENT 允许查看复制状态。
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY 'monitor123';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

-- 复制账号由 replica-init 容器创建，这里不重复写，
-- 便于你对照教程 04 章看「谁负责创建什么」。

FLUSH PRIVILEGES;
