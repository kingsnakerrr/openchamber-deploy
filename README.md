# oc-stack

一条命令在 VPS 上跑起 **Sub2API + OpenCode + OpenChamber**，全 Docker、自动 HTTPS、自动续期。

```
公网 443 ──> caddy ──┬──> openchamber:3000 ──> opencode
                     │
                     └──> sub2api:8080 ──> 上游模型 API
```

## 三分钟上手

```bash
git clone https://github.com/<你的账号>/oc-stack.git
cd oc-stack
./ocstack install
```

安装过程会问你：

```
OpenChamber 域名（留空跳过）: oc.example.com
Sub2API 域名（留空跳过）:     api.example.com
证书通知邮箱:                 you@example.com
现在就配置上游？               y
  上游 Base URL:              https://api.deepseek.com
  上游 API Key:               sk-xxxxx
  模型 ID:                    deepseek/deepseek-v4.1-flash
```

装完直接能用，终端会打印网址和密码。

## 关于「两个域名」

是的，**建议两个**，也可以只用一个或不用：

| 方案 | OpenChamber | Sub2API | 适用 |
|---|---|---|---|
| 两个域名（推荐） | `oc.example.com` | `api.example.com` | 界面和网关分开，各自独立证书；网关可以给别的客户端用 |
| 一个域名 | `oc.example.com` | 不填 | 网关只走容器内部网络，仅本机 OpenChamber 用 |
| 不用域名 | 空 | 空 | IP + HTTP 明文，只适合临时试用 |

两个域名都在同一个 DNS 服务商加 A 记录指向服务器 IP 即可，Caddy 会分别申请两张证书。

## 命令

```bash
./ocstack install        # 安装（交互式）
./ocstack status         # 状态、访问地址、证书、磁盘
./ocstack logs caddy     # 看证书申请过程
./ocstack bootstrap      # 补配置上游（安装时跳过了的话）
./ocstack verify         # 16 项自检
./ocstack upgrade        # 升级 OpenCode / OpenChamber / Sub2API
./ocstack cert           # 查看证书有效期
./ocstack restart        # 重启
./ocstack down           # 停止
./ocstack uninstall      # 卸载（数据保留）
./ocstack uninstall --purge  # 卸载并删除数据
```

## HTTPS 与续期

用 Caddy 内置的 ACME 客户端，**不需要 certbot，不需要 cron**：

- 首次启动自动申请，同时尝试 Let's Encrypt 和 ZeroSSL 两个 CA，一个失败自动换另一个
- 证书到期前 30 天自动续期
- 证书存在 Docker 卷 `oc-stack_caddy_data`，重建容器不丢

前提是 DNS 已生效。安装时会自动检查并提示：

```
  ok oc.example.com → 1.2.3.4
```

看到 `尚未解析` 就先去加 A 记录，等生效后 `./ocstack restart caddy`。

## 端口占用怎么办

如果 80/443 已被 nginx 占用，安装器会自动探测空闲端口（比如 8080/8180）并提示你：

```
  !! 端口被占用： 80 443
  !! 占用者：(nginx)
  改用 8080/8180（需你自己在前置反代里转发）？
```

选是之后，把所有流量转发给 Caddy 即可：

```nginx
server {
    listen 443 ssl;
    server_name oc.example.com;
    # ... 你的证书配置 ...

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
```

## 数据在哪

```
./data/openchamber/       OpenChamber 设置、登录状态
./data/opencode/config/   opencode.json（provider 配置）
./data/opencode/share/    会话、数据库
./data/opencode/state/
./data/sub2api/           Sub2API 应用数据
./data/postgres/          PostgreSQL 数据
./data/redis/             Redis 数据
./workspaces/             你的代码，容器内路径 /workspace
```

备份就是打包这整个目录：

```bash
tar czf oc-stack-backup-$(date +%F).tar.gz .env data workspaces
```

**`.env` 一定要备份**，里面有数据库密码和固定密钥。丢了 `JWT_SECRET` 所有人被登出，丢了 `POSTGRES_PASSWORD` 数据库连不上。

## 目录结构

```
.
├── ocstack                         主命令（安装/升级/卸载/验证）
├── docker-compose.yml              五个服务
├── docker/
│   ├── Dockerfile.openchamber      OpenChamber + OpenCode 镜像
│   └── entrypoint.sh               首次启动自动生成 provider 配置
├── caddy/Caddyfile                 由 ocstack 生成，不要直接改
├── .env                            由 ocstack 生成，权限 600
└── data/                           持久化数据
```

## 镜像说明

上游 OpenChamber 没有官方 Docker 镜像，所以这里基于官方 npm 包自建（比从源码构建快很多）：

```dockerfile
npm install -g @opencode/cli@2.2.6 @openchamber/web@2.7.0
```

版本号在 `.env` 里，升级时改这里或直接 `./ocstack upgrade`。

## 安全

安装完请确认：

- [ ] `.env` 权限是 600
- [ ] 只有 caddy 暴露 80/443，OpenChamber 和 Sub2API 都不映射到宿主机
- [ ] `OPENCHAMBER_UI_PASSWORD` 不是弱口令
- [ ] 防火墙只放 22/80/443

最后一条最重要：**OpenChamber 背后是一个能执行任意 shell 命令的 agent**，没设密码等于把 root shell 挂在公网。

`./ocstack verify` 会自动检查前两条。

## 已知取舍

这些是实测出来的，不是猜的：

| 情况 | 处理 |
|---|---|
| 上游 OpenChamber 无官方镜像 | 自建镜像，装 npm 包 |
| 挂载目录属主是 root，容器内 UID 1000 | `ocstack` 启动前自动 `chown 1000:1000` |
| Sub2API 要求管理员密码 ≥ 8 位 | 自动检测并重新生成 |
| Sub2API 要求 `JWT_SECRET` ≥ 32 字节 | `.env` 里生成 64 字符 |
| 余额为 0 时所有请求 402 | bootstrap 自动充 100 |
| 合规确认不传 language 会按英文校验 | bootstrap 带 `language:zh` |
| `max_tokens` 上限 200000 | 配置里用 `max_completion_tokens` |

## 许可

MIT
