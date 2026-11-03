# 05 · Redis 详解：共享小黑板本身怎么保得住

> 对应代码：`backend/app/session_store.py`、`deploy/redis/redis.conf`、`deploy/docker-compose.yml`

第 02 章我们把 Session 放进了 Redis，第 03 章发现「定时任务只跑一次」的锁也在 Redis。现在把这块小黑板本身讲清楚。

---

## 5.1 Redis 是什么，为什么 Session 都爱用它

一句话：**一个把数据放在内存里、通过网络访问的键值数据库**。

对比一下「档案」放在不同地方：

| 存法 | 一次读取耗时（量级） | 多机共享 | 自动过期 | 重启后 |
| --- | --- | --- | --- | --- |
| 进程内存 | ~0.0001 ms | ❌ | 要自己写 | 全丢 |
| MySQL | ~1–10 ms | ✅ | 要自己写定时任务 | 还在 |
| 本地文件 | ~0.1 ms | ❌ | 要自己写 | 还在 |
| **Redis** | **~0.1–0.5 ms** | ✅ | ✅ `EXPIRE` 原生支持 | 可配置持久化 |

Session 的特点恰好全是 Redis 的强项：**读写极频繁、数据量小、需要自动过期、要被所有副本共享、丢了顶多让用户重新登录（不是致命数据）**。

### 为什么 Redis 这么快

1. **全内存操作**，没有磁盘随机 IO（持久化是异步另做）；
2. **单线程执行命令**，没有锁竞争和上下文切换（Redis 6 起网络 IO 用多线程，命令执行仍是单线程）；
3. **I/O 多路复用**（epoll），一个线程管几万连接；
4. **精简的协议 + 高效数据结构**（跳表、压缩列表、哈希表）。

> 单线程带来一条重要纪律：**别在 Redis 里跑慢命令**（`KEYS *`、`大范围 SMEMBERS`、大 key 删除），会阻塞所有其它请求。用 `SCAN` 代替 `KEYS`。

## 5.2 五大数据结构，以及 Session 用哪个

| 结构 | 例子 | 典型用途 |
| --- | --- | --- |
| String | `SET sess:abc "{...}" EX 1800` | ✅ **Session**、计数器、分布式锁、缓存对象 |
| Hash | `HSET user:1 name alice age 20` | 对象字段（比 JSON 字符串更省、可单字段改） |
| List | `LPUSH queue:mail ...` | 简单消息队列、最新列表 |
| Set | `SADD user:1:roles admin` | 去重、交集（共同好友） |
| Sorted Set | `ZADD rank 100 alice` | 排行榜、延迟队列 |

本项目 Session 用最朴素的 **String + JSON**：

```python
# backend/app/session_store.py
self.r.setex(f"sess:{sid}", ttl, json.dumps(data, ensure_ascii=False))
raw = self.r.get(f"sess:{sid}")
return json.loads(raw) if raw else None
```

为什么不用 Hash？因为我们的档案是整体读写、字段少、还要整体设 TTL，String 最简单。Hash 的字段级过期 Redis 本身也不支持，别为了「看起来高级」绕远路。

完整 API：

```python
create(data, ttl)  → SETEX           新建档案，带过期
get(sid)           → GET + JSON 解析  查档案
save(sid, data)    → SET + EXPIRE    改档案（如 hits +1）并续期
touch(sid)         → EXPIRE          滑动续期
delete(sid)        → DEL             登出 / 踢人
inspect(sid)       → GET + TTL + PTLL  教学透视
```

## 5.3 过期与内存淘汰：两个容易混的概念

### 过期（Expiration）：这个 key 到点就该消失

Redis 用**惰性删除 + 定期抽样删除**组合：

- 惰性：有人来 `GET` 这个 key 时发现过期，顺手删掉；
- 定期：每 100ms 抽查一批设置了 TTL 的 key，删掉已过期的。

所以过期 key 不会「精确在第 1800 秒那一刻消失」，可能晚几秒，对 Session 完全无所谓。

```bash
SET sess:abc "{...}" EX 1800     # 设值时带过期
EXPIRE sess:abc 1800             # 续期（滑动过期）
TTL sess:abc                     # 查剩余秒数；-2 表示已不存在，-1 表示没设过期
```

> **必须给每个 Session 设 TTL**。忘了设 = 内存里堆满永不清理的僵尸会话，迟早 OOM。这是最常见的 Redis 事故之一。

### 内存淘汰（Eviction）：内存满了，删谁

`deploy/redis/redis.conf` 关键配置：

```conf
maxmemory 256mb
maxmemory-policy allkeys-lru      # 内存满时，在所有 key 里淘汰最近最少使用的
appendonly yes                    # 开 AOF 持久化
appendfsync everysec
```

| 策略 | 含义 | 适用 |
| --- | --- | --- |
| `noeviction` | 不删，写命令直接报错（默认值） | 纯持久化场景 |
| `allkeys-lru` | 所有 key 里淘汰最久没用的 | ✅ 纯缓存 / **Session 专用实例** |
| `volatile-lru` | 只淘汰设了 TTL 的 key | 缓存 + 重要数据混存 |
| `allkeys-random` / `volatile-ttl` | 随机 / 优先淘汰剩余寿命短的 | 特殊场景 |

**重要建议**：给 Session 单独一个 Redis 实例/数据库，用 `allkeys-lru`。别和业务缓存、消息队列混在一个实例里 —— 缓存被 LRU 淘汰无所谓，Session 被批量淘汰就是「全站集体掉登录」。

## 5.4 持久化：Redis 不是「重启就没了」

| 方式 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| RDB | 定时把内存快照写成 `dump.rdb` | 文件小、恢复快、适合备份 | 两次快照之间的数据会丢 |
| AOF | 把每条写命令追加到日志 | 最多丢 1 秒（`everysec`） | 文件大、恢复慢 |
| 混合（推荐） | RDB 全量 + 之后的 AOF 增量 | 兼顾两者 | Redis 4+ 支持 |

本项目开 `appendonly yes` + `appendfsync everysec`。

> 但对 **Session 场景**，其实**可以不持久化**：重启后大家重新登录一次，业务完全能接受，反而省事。
> 是否持久化取决于「这份数据丢了会怎样」：
> - 丢了只是重新登录 → 可不持久化，换更高性能；
> - 丢了会影响交易、幂等、分布式锁状态 → 必须持久化 + 高可用。
> 这也是为什么架构决策要先问「业务能接受什么」，而不是一律「全开最稳」。

## 5.5 高可用三级跳（重点：区别在哪）

| 级别 | 结构 | 解决什么 | 不解决什么 | 适用 |
| --- | --- | --- | --- | --- |
| **单机** | 1 个 Redis | —— | 挂了全站掉登录 | ✅ 本项目教学版 |
| **主从 + 哨兵 Sentinel** | 1 主 N 从 + 3 个哨兵进程 | 主库挂了自动选新主，应用自动切换；读写可分离 | **内存容量受单机限制**，无法横向扩容量 | ✅ 绝大多数公司的 Session/缓存场景 |
| **Redis Cluster** | 16384 个槽分散到多组分片 | 容量和吞吐都能横向扩；自带故障转移 | 不支持跨槽多 key 事务；客户端要支持集群协议；运维复杂 | 数据量超单机内存、超大规模 |

```
单机           主从 + 哨兵                    Cluster
 ┌────┐        ┌──────┐  ┌──────┐          ┌─────┐ ┌─────┐ ┌─────┐
 │ R  │        │  M   │──│  S   │          │ A主 │ │ B主 │ │ C主 │
 └────┘        └──┬───┘  └──────┘          └─┬───┘ └─┬───┘ └─┬───┘
                  │ 哨兵监控、自动切主         │ A从   │ B从   │ C从
              [Sentinel ×3]              槽 0-5460 / 5461-10922 / 10923-16383
```

**选型直觉**：

- Session 数据量很小（几万用户也就几十 MB），**单机或主从+哨兵足够**，别一上来上 Cluster；
- 只有「数据量超过单机内存」或「写 QPS 单主扛不住」才需要 Cluster；
- 客户端要相应换：`redis.Redis(...)` → `redis.sentinel.Sentinel(...)` / `RedisCluster(...)`。本项目把连接封装在 `session_store.py` 一处，**将来换高可用只需改这一个文件**，上层业务代码不动 —— 这就是第 02 章说的「把决策收敛到一处」的价值。

> 云上更省事：直接用云 Redis 高可用版/集群版，哨兵和切换都由厂商托管。

## 5.6 缓存三大经典问题（面试高频，顺便讲清）

虽然本项目只用 Redis 存 Session，但只要做缓存就会遇到：

| 问题 | 场景 | 对策 |
| --- | --- | --- |
| **缓存穿透** | 查一个根本不存在的 key，每次都打到数据库 | 布隆过滤器；把「空结果」也缓存一小段时间（如 60s）；参数校验 |
| **缓存击穿** | 一个热点 key 恰好过期，瞬间几万请求同时打库 | 互斥锁只放一个线程去重建；热点 key 逻辑上永不过期 + 后台异步刷新 |
| **缓存雪崩** | 大批 key 同一时刻集体过期 / Redis 整体挂了 | 过期时间加随机抖动；多级缓存；Redis 高可用 + 限流降级 |

对照 Session：**所有 Session 都在登录时创建，TTL 相同，理论上可能出现「同时批量过期」**。不过登录时间是分散的，实际风险低；真要防，给 TTL 加个随机抖动即可（`ttl + random(0, 300)`）。

## 5.7 Redis 在本项目里干的 3 件事

| 用途 | Key | 代码位置 |
| --- | --- | --- |
| 集中式 Session | `sess:{sid}` | `session_store.py` `create/get/save/touch/delete` |
| 集群启动锁 | `init:schema:lock` | `database.py` `init_schema_and_seed()` |
| 全局请求计数器 | `stats:requests` | `routers/system.py`（`INCR`，演示所有副本共享同一计数） |

第 3 个很有意思：3 个后端副本各自处理请求，但计数是全局累加的。你在页面上刷新一次，数字 +1，且不管落到哪台副本都一样 —— 无状态 + 共享存储的最小示例。

## 5.8 亲手玩一玩 Redis CLI

```powershell
cd i:/work-body-dir/fullstack-cluster-tutorial
$compose = "docker compose -f deploy/docker-compose.yml"

# 进 Redis（完整集群版）
docker compose -f deploy/docker-compose.yml exec redis redis-cli -a redispass

# 常用命令（在 redis-cli 里）
# > PING
# > KEYS sess:*                  ← 生产禁用，教学用；生产用 SCAN
# > GET sess:<贴一个sid>
# > TTL  sess:<sid>
# > INCR stats:requests
# > INFO memory
# > CONFIG GET maxmemory-policy
```

**推荐实验**：登录后在「架构实验室」页复制自己的 `session_id`，在 CLI 里 `DEL sess:<sid>`，回网页刷新 → 立刻被踢回登录页。这一秒你会真正理解「集中式 = 单点控制」。

---

## 5.9 小结与动手任务

- Redis 快在内存 + 单线程 + IO 多路复用；Session 用 `String + TTL` 最合适；
- 过期靠惰性+定期删除；内存满靠 `maxmemory-policy`，Session 建议独立实例 + `allkeys-lru`；
- 持久化是否开启取决于「丢了能不能接受」，Session 场景可以不持久化；
- 高可用：单机 → 主从+哨兵 → Cluster，按**容量需求**选，不要过度设计；
- 缓存穿透/击穿/雪崩三件套要能对号入座。

**动手任务**

1. 登录后 `TTL sess:<sid>`，等 5 秒再看，观察变化；然后刷新网页，看 TTL 是否被 `touch()` 重置回 1800（滑动续期）；
2. `DEL` 掉自己的 Session，验证被踢下线；
3. 把 `SESSION_TTL_SECONDS` 改成 15，静置 20 秒，观察自动掉线；
4. 用 `MONITOR` 命令（教学用）观察刷新页面时 Redis 到底收到了哪些命令：`GET / EXPIRE / SET / INCR`；
5. 思考题：如果 Redis 挂了，网站应该「全部报 500」还是「允许用户重新登录」？看 `session_store.py` 的连接异常处理，想想生产该怎么降级。

> 下一章：[06 · 部署实战与验证](06-部署实战与验证.md) —— 把前面所有东西一次跑起来，一条条命令解释清楚。
