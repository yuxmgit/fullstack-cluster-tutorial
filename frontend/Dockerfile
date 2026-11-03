# ---------- 阶段一：构建 ----------
FROM node:20-alpine AS build

WORKDIR /app

# 先复制依赖声明，充分利用镜像层缓存。
# 有 package-lock.json 时用 npm ci（严格按锁定版本安装，可复现）；
# 没有 lock 文件时自动回退到 npm install。
COPY package*.json ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

COPY . .
RUN npm run build

# ---------- 阶段二：运行 ----------
# 最终镜像只有 Nginx + 静态文件，不含 Node 和源码，体积小、攻击面小
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
