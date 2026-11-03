# 生产部署速查卡

> 完整讲解见 [`docs/08-腾讯云自动化部署.md`](../../docs/08-腾讯云自动化部署.md)

## 一次部署的完整流程

```bash
# ① 服务器初始化（只做一次，root 执行）
sudo bash scripts/cloud/init-server.sh

# ② 配置环境变量（只做一次）
cd deploy/cloud
cp .env.production.example .env
chmod 600 .env
vim .env                 # 填域名 + 5 个密码，替换所有 CHANGE_ME

# ③ 部署（每次发布都执行）
bash scripts/cloud/deploy.sh
```

## 目录里都有什么

| 文件 | 作用 |
| --- | --- |
| `.env.production.example` | 环境变量模板，复制成 `.env` 后填写 |
| `docker-compose.prod.yml` | 生产编排：不暴露数据库端口、限资源、日志轮转 |
| `nginx-lb.prod.conf.template` | HTTPS + 轮询 + 限流 + 安全响应头 |
| `redis.prod.conf.template` | Redis 配置模板，密码由部署脚本注入 |
| `init/01-init.sql.template` | MySQL 初始化 SQL 模板 |
| `runtime/` | **自动生成**，含明文密码，已 gitignore，权限 600 |
| `certs/` | HTTPS 证书，`deploy.sh` 没有时会生成自签证书 |
| `certbot-webroot/` | acme.sh / certbot 的 HTTP-01 校验目录 |

## 常用运维命令

```bash
cd deploy/cloud
set -a; source .env; set +a      # 让命令里能直接引用 $REDIS_PASSWORD 等变量
alias dc='docker compose --env-file .env -f docker-compose.prod.yml'

dc ps                        # 看状态
dc logs -f backend-1         # 看某个副本日志
dc logs --tail=100 mysql-master
dc restart lb                # 换证书后重载入口
dc exec redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning KEYS 'sess:*'
dc exec mysql-master mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e 'SHOW REPLICA STATUS\G'
```

## 回滚

```bash
bash scripts/cloud/rollback.sh                    # 回到上一版
bash scripts/cloud/rollback.sh 20260101-120000    # 回到指定版本
```

## 备份

```bash
bash scripts/cloud/backup.sh
```
