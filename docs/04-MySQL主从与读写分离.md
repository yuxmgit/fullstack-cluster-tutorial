# 04 · MySQL 主从与读写分离：写总账本，读复印件

> 对应代码：`backend/app/database.py`、`deploy/mysql/`、`deploy/docker-compose.yml`

---

## 4.1 为什么数据库不能像后端那样「多开几台」

后端副本好扩，是因为它们无状态。数据库恰恰相反：**数据就是状态**。

如果直接起 3 个各自写各自的 MySQL，用户 A 在库 1 建了留言，用户 B 在库 2 查不到 —— 数据分裂了。所以数据库的集群思路完全不同：

```
应用副本：      随便加，彼此不认识        → 靠「无状态」
数据库副本：    必须保持数据一致          → 靠「复制（replication）」
```

最经典、也是本教程采用的模式：**一主一从（Master / Slave，新术语叫 Source / Replica）**

- **主库**：负责所有写操作（`INSERT / UPDATE / DELETE`）；
- **从库**：主库把变更同步过来，负责读操作（`SELECT`）；
- 一主可以带多个从库，读能力可以横向扩展。

> 注意：它是**高可用 + 读扩展**方案，不是「写扩展」。写压力最终还得靠分库分表 / 分布式数据库，见 4.7。

## 4.2 主从复制到底怎么同步的（binlog + GTID）

MySQL 会把每一次数据变更记到一个日志里，叫 **binlog**（二进制日志）。从库就是「照着日志重放一遍」。

```
① 应用 → 主库：INSERT INTO note ...
② 主库：写数据 + 写 binlog（记下「我做了什么」）→ 返回成功
③ 从库的 IO 线程：连上主库，把 binlog 拉回来存成 relay log（中继日志）
④ 从库的 SQL 线程：读 relay log，在本库重放同样的 SQL
⑤ 从库数据 = 主库数据 ✅
```

三个角色（老名字，面试爱问）：

| 线程 | 位置 | 干什么 |
| --- | --- | --- |
| `Binlog Dump` | 主库 | 有人来拉日志时把 binlog 事件发出去 |
| `I/O Thread` | 从库 | 拉日志 → 写 relay log |
| `SQL Thread` | 从库 | 重放 relay log |

**GTID**（全局事务 ID）是给每个事务一个全局唯一编号 `server_uuid:序号`。有了它，从库只需说「我从 GTID 100 之后开始要」，不用再人工记「主库 binlog 文件第几行」，主库切换、故障恢复都简单得多。本项目配置：

```ini
# deploy/mysql/master.cnf
[mysqld]
server-id=1                # 每个实例必须唯一
log_bin=mysql-bin          # 开 binlog（主从的前提）
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW          # 按行记录，比 STATEMENT 更稳妥
```

```ini
# deploy/mysql/slave.cnf
[mysqld]
server-id=2
log_bin=mysql-bin
gtid_mode=ON
enforce_gtid_consistency=ON
relay_log=relay-bin
read_only=ON               # 普通账号只读，防止有人手滑写到从库
super_read_only=ON
```

> `read_only` 不会阻止复制线程写入（复制线程是特权线程），所以从库照样能同步，但应用账号写不进去，正好起到保护作用。

### 本项目的自动搭建脚本

`deploy/mysql/init-replica.sh` 是一个**一次性容器**，干三件事：

```bash
# 1. 等主库、从库都真正就绪（别用 sleep，要 ping）
until mysqladmin ping -h mysql-master -uroot -p"$MYSQL_ROOT_PASSWORD" --silent; do sleep 2; done

# 2. 在主库创建专用复制账号
mysql -h mysql-master -uroot -p... -e "
  CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'replpass';
  GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; FLUSH PRIVILEGES;"

# 3. 让从库以 GTID 自动定位开始复制
mysql -h mysql-slave -uroot -p... -e "
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='mysql-master', SOURCE_USER='repl', SOURCE_PASSWORD='replpass',
    SOURCE_AUTO_POSITION=1;     -- GTID 自动找位置，不用手工记 binlog 坐标
  START REPLICA;"
```

`SOURCE_AUTO_POSITION=1` 会从主库**第一条** binlog 开始同步，因此主库初始化时的建库语句、应用启动时的建表语句、seed 用户数据，全都会自动流到从库。这也是为什么本项目不需要在从库手动导数据。

> 生产环境主从不一定从零开始，通常用 `mysqldump --single-transaction --source-data=2` 先做一份一致性快照导入从库，再开复制。教学环境用 GTID 自动定位最省事。

## 4.3 读写分离：代码里怎么写

本项目 `backend/app/database.py` 建了**两个 Engine**：

```python
write_engine = create_engine(settings.DB_WRITE_URL, pool_pre_ping=True, pool_recycle=3600)
read_engine  = create_engine(settings.DB_READ_URL,  pool_pre_ping=True, pool_recycle=3600)

def get_write_db():
    """写操作：事务、INSERT/UPDATE/DELETE 用它"""
    with Session(write_engine) as db:
        yield db

def get_read_db():
    """读操作：纯 SELECT 用它；从库挂了自动降级到主库"""
    engine = read_engine if read_is_healthy() else write_engine
    with Session(engine) as db:
        yield db
```

路由里按语义选依赖：

```python
# backend/app/routers/notes.py
@router.get("")                      # 读 → 从库
def list_notes(db = Depends(get_read_db), ...):
    ...

@router.post("")                     # 写 → 主库
def create_note(db = Depends(get_write_db), ...):
    db.add(note); db.commit()
```

为了方便教学，每个响应都带上 `db_role` 字段（`replica` / `primary` / `primary(fallback)`），前端「架构实验室」页会显示出来 —— 你可以**亲眼看到**读走的是从库。

### 连接参数里藏着的两个经验

- `pool_pre_ping=True`：从池里取连接前先探一下，避免拿到被 MySQL 断掉的空闲连接（经典报错 `Lost connection to MySQL server during query`）；
- `pool_recycle=3600`：连接活过 1 小时主动重建，绕开 MySQL 的 `wait_timeout`。

### 故障降级很重要

从库挂了，不能让整个网站挂。本项目每 10 秒探一次从库，失败就自动把读请求路由回主库，前端会显示 `primary(fallback)`。这叫**读降级**，是读写分离必须配套的一环。

> 也可以用中间件（ProxySQL / MyCat / ShardingSphere）在数据库前面自动做读写分离，应用只连一个地址。教学阶段手写两个 Engine 更能看清本质。

## 4.4 最大的坑：写完立刻读，读不到

主从复制是**异步**的（默认），中间有延迟，通常几毫秒，但负载高时能到秒级：

```
① 用户提交留言 → 写主库 → 返回「成功」
② 页面立刻刷新 → 读从库 → 从库还没同步到 → 列表里没有刚发的内容
③ 用户：「我刚发的呢？？」再刷一次又有了
```

**四种对策**（按推荐度）：

| 对策 | 做法 | 适用 |
| --- | --- | --- |
| **前端乐观更新** | 提交成功后直接把新对象塞进本地列表，不依赖重新查询 | ✅ 最简单，本项目留言板可用这个思路 |
| 写后短时间内读主库 | 给用户打个「刚写过」标记，接下来 N 秒的读强制走主库 | 通用、可靠 |
| 半同步复制 | 主库等至少一个从库确认收到 binlog 才返回 | 一致性更强，写入变慢 |
| 等 GTID | 写后拿到 GTID，读时等从库追上这个 GTID | 强一致场景，实现复杂 |

**结论**：绝大多数业务接受「短暂最终一致」，用前端乐观更新 + 关键读走主库即可。不要为了「绝对立刻可见」把所有读都压回主库，那读写分离就白做了。

## 4.5 本项目的数据模型

```python
# backend/app/models.py
class User(Base):
    __tablename__ = "users"
    id            = Column(Integer, primary_key=True)
    username      = Column(String(64), unique=True, nullable=False)
    password_hash = Column(String(256), nullable=False)   # 绝不存明文
    nickname      = Column(String(64))
    created_at    = Column(DateTime, default=datetime.now)

class Note(Base):
    __tablename__ = "notes"
    id         = Column(Integer, primary_key=True)
    user_id    = Column(Integer, index=True)
    title      = Column(String(128))
    content    = Column(Text)
    created_at = Column(DateTime, default=datetime.now, index=True)
```

密码用标准库 `hashlib.pbkdf2_hmac('sha256', ...)` 加盐 + `hmac.compare_digest` 校验，不引入额外依赖，也不会出现明文密码。

初始账号由 `seed_users()` 插入：`alice / 123456`、`bob / 123456`（仅用于教学，生产务必改掉）。

## 4.6 验证主从真的在同步

```powershell
cd i:/work-body-dir/fullstack-cluster-tutorial

# ① 看从库复制状态（重点看这两行 YES）
docker compose -f deploy/docker-compose.yml exec mysql-slave `
  mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G"

# 关注：
#   Replica_IO_Running: Yes
#   Replica_SQL_Running: Yes
#   Seconds_Behind_Source: 0

# ② 在网页上新建一条留言，然后分别查主库、从库
docker compose -f deploy/docker-compose.yml exec mysql-master `
  mysql -uroot -prootpass fullstack_demo -e "SELECT COUNT(*) FROM notes;"
docker compose -f deploy/docker-compose.yml exec mysql-slave `
  mysql -uroot -prootpass fullstack_demo -e "SELECT COUNT(*) FROM notes;"

# ③ 看主库 binlog / GTID
docker compose -f deploy/docker-compose.yml exec mysql-master `
  mysql -uroot -prootpass -e "SHOW MASTER STATUS\G"

# ④ 试试从库是不是真的只读（应该报错）
docker compose -f deploy/docker-compose.yml exec mysql-slave `
  mysql -uroot -prootpass fullstack_demo -e "INSERT INTO notes(title,content,user_id) VALUES('x','x',1);"
```

> 第 ④ 步用 `root` 可能被 `super_read_only` 拦下也可能不拦（SUPER 权限例外，取决于版本与账号）。
> 更准确的验证是用应用账号 `demo` 去写，一定会被拒绝。

## 4.7 生产上还要补什么

| 需求 | 教学版 | 生产方案 |
| --- | --- | --- |
| 主库挂了自动切换 | ❌ 需人工 | MHA / Orchestrator / MySQL Group Replication (MGR) / InnoDB Cluster / 云 RDS 高可用版 |
| 从库挂了 | ✅ 应用自动降级读主库 | 多从库 + 负载均衡（ProxySQL） |
| 写能力扩展 | ❌ 单主 | 分库分表（ShardingSphere / Vitess）、分布式数据库（TiDB / OceanBase） |
| 备份恢复 | ❌ | 全量 + binlog 增量，定期演练恢复（**没演练过的备份等于没有**） |
| 数据一致性校验 | ❌ | pt-table-checksum 定期比对主从 |
| 连接数暴涨 | 每副本一个连接池 | 注意：3 副本 × 池大小 10 = 30 连接，副本越多越容易打满 `max_connections` ← 非常常见的坑 |
| Schema 变更 | `create_all` | Alembic 迁移，先加兼容列、再发应用、最后清旧列 |

> 最省心的建议：生产直接用**云厂商 RDS 高可用版**，主从、备份、切换、监控都托管好，把精力留给业务。自己搭一遍是为了懂原理，不是为了在生产重复造轮子。

---

## 4.8 小结与动手任务

- 数据库不能像应用一样随便多副本，靠 **binlog + GTID 复制**保持一致；
- 一主多从：**写主库、读从库**，代码里用两个 Engine；必须配套故障降级；
- 异步复制有延迟，「写完立刻读」要用前端乐观更新或关键读走主库；
- 主从解决读扩展与高可用，写扩展要靠分库分表 / 分布式数据库。

**动手任务**

1. 用 4.6 的命令确认 `Replica_IO_Running` / `Replica_SQL_Running` 都是 `Yes`；
2. 在网页新建留言，立刻查主库和从库的 `COUNT(*)`，比一比时间差；
3. `docker compose ... stop mysql-slave`，刷新页面，观察 `db_role` 变成 `primary(fallback)` 且功能仍正常；再 start 恢复；
4. 把 `DB_READ_URL` 改成和写库一样，体会读写分离「消失」后前端显示的变化；
5. 思考题：如果 3 个后端副本同时启动都去 `CREATE TABLE` 会怎样？看 `database.py` 里的 `init:schema:lock` 是怎么解决的（回顾 03 章）。

> 下一章：[05 · Redis 详解](05-Redis详解.md) —— 那块共享小黑板本身，怎么保证不丢、不炸、能扩展。
