# oc-stack

一条命令部署 **OpenChamber + OpenCode**，可选自带 Sub2API 网关，全 Docker，自动 HTTPS。

```
公网 443 ──> caddy ──┬──> openchamber:3000 ──> opencode
                     │
                     └──> （可选）sub2api ──> 上游模型 API
```

## 安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kingsnakerrr/openchamber-deploy/main/install.sh)
```

只问两件事，都能直接回车：

1. **网关**：要不要在本机装一套 Sub2API（默认装）
2. **域名**：没有就用 IP + HTTP

密码全部自动生成，装完直接打印。

### 端口

默认全在高位段，避开 qbittorrent / nginx 这些常用端口：

| 用途 | 默认端口 |
|---|---|
| Caddy HTTP / HTTPS | 80 / 443（被占用时自动换 18100 / 18200） |
| OpenChamber | 18102 |
| Sub2API 网关入口 | 18103 |
| Sub2API 后台（仅本机） | 18104 |

全部自动探测空闲端口，冲突了就往下挪。

**HTTPS 用的是高位端口时，访问地址要带端口号**，例如 `https://oc.example.com:18200`。装完会直接打印完整地址。

## 80/443 被占用怎么办

安装时会检测并让你选：

| 选项 | 适用 | 结果 |
|---|---|---|
| **1. 停掉占用者** | 那台机器上没别的网站 | 自动停用 nginx，Caddy 接管 80/443，URL 不带端口 |
| **2. 用 acme.sh 签证书** | 你要保留现有 nginx 或别的程序占着 443 | acme.sh 临时借 80 几秒签证书，Caddy 跑在高位端口，URL 带端口 |
| **3. 不上 HTTPS** | 临时试用 | IP + HTTP 明文 |
| **4. 只生成反代配置** | 你自己懂 nginx | 生成配置片段给你，自己套用 |

选项 2 的工作方式：

```
acme.sh --issue --standalone -d 你的域名
   ↓ 临时停 nginx 几秒，独占 80 完成校验
   ↓ 签完立刻把 nginx 拉回来（并还原开机自启）
证书存到 /etc/oc-certs/<域名>/
   ↓
Caddy 用 tls 指令加载这些证书，监听高位端口
   ↓
你访问 https://你的域名:18200
```

续期由 acme.sh 的 cron 每天 03:17 检查，到期前 30 天自动续，续期时的 `--pre-hook` / `--post-hook` 会自动让出并归还 80 端口。**不需要 certbot。**

邮箱可以不填——证书照样签发，只是收不到到期提醒。

## 控制台

装完直接输入 `oc`：

```
╭──────────────────────────────────────────────────────────╮
│           oc-stack 控制台                                │
╰──────────────────────────────────────────────────────────╯
  域名     oc.example.com
  模式     local
  端口     HTTPS 18200 / HTTP 18100

  1  查看状态          服务、端口、地址
  2  自检              12 项健康检查
  3  查看地址密码      所有访问地址和凭据

  4  443 端口共享      让域名不带端口访问
  5  更换域名          改域名并重新签证书

  6  证书状态          有效期与剩余天数
  7  查看日志          实时日志
  8  配置上游          自动建分组和密钥

  9  重启容器
  10 升级版本
  11 备份数据          打包 .env + data
  12 开机自启
  13 卸载

  0  退出
```

也可以直接用命令：

```bash
oc status      oc verify      oc urls       oc cert
oc 443         oc domain      oc logs       oc bootstrap
oc restart     oc upgrade     oc backup     oc autostart
```

### 443 端口共享

如果 443 已被别的程序占用（Cloudflare Tunnel、mmw-agent、前置反代等），
但那个程序会把流量转给本机 nginx，就可以用 SNI 分流让多个域名共用 443：

```bash
oc 443        # 选 1 启用
```

之后：

```
https://oc.example.com          ← 不带端口
https://api.example.com         ← 不带端口
```

原理：

```
公网 :443 → 前置 TLS 终结器 → nginx:8001
                                    ↓ 按 SNI/server_name 分流
                              Caddy:18200 → 各自的容器
```

前提条件（脚本会自动检测）：

| 条件 | 说明 |
|---|---|
| 有 `/usr/local/nginx/servers` | 该功能依赖前置 nginx 做分流 |
| nginx 有通配符证书 | 例如 `*.example.com`，覆盖你要加的域名 |
| 443 的占用者会转发给 nginx | 不是所有程序都这么做，`oc 443` 会提示 |

不满足这些条件时，退回用高位端口访问（`https://域名:18200`），同样能用。

## 两种网关模式

### 本地部署（默认，推荐）

```
  要不要在这台机器上装一套 Sub2API 网关？

    [1] 装（推荐）  自带 PostgreSQL + Redis，装完就是完整独立的一套
    [2] 不装        你已经有一个能用的，暂时先连过去
```

选 1 直接回车就是。五个容器，自己的一套，上游账号、密钥、额度、日志全在你手上。

### 外接已有

只有当你在别处**已经有一台自己搭好、能用的** Sub2API 时，才选 2。

这时只起 caddy + openchamber 两个容器，安装过程会让你填那个网关的 Base URL。

选错了也不要紧：重跑 `./ocstack install` 选 1 即可切换到本地部署，数据不会丢。

## 装完三步

**1. 网关里加上游账号**（外接模式跳过这步）

分组 → 新建，平台选 OpenAI → 账号 → 添加，类型 API Key，填商家的 Base URL 和 Key → 点「测试连接」→ API 密钥 → 创建，复制 `sk-...`

**2. 把密钥填进 OpenChamber**

设置 → 提供商 → Sub2API

- 基础 URL：`你的网关地址 + /v1`
- API 密钥：上一步的 `sk-...`

**3. 验证**

```bash
./ocstack verify
```

## 地址别填错

这是最容易混的一步：

| 位置 | 填什么 | 例子 |
|---|---|---|
| 网关后台的「上游账号」 | **商家**地址和 Key | `https://api.deepseek.com` |
| OpenChamber 的「基础 URL」 | **网关**地址 | `你的网关地址/v1` |
| OpenChamber 的「API 密钥」 | 网关**签发**的 Key | `sk-30db821c4c...` |

**不要**把商家的 Key 填进 OpenChamber。商家 Key 只存在网关里，客户端永远用网关二次签发的。

## 域名

| OpenChamber | Sub2API | 结果 |
|---|---|---|
| `oc.example.com` | `api.example.com` | 都走 HTTPS |
| `oc.example.com` | 空 | 后台走 SSH 隧道 |
| 空 | 空 | IP + HTTP，仅适合试用 |

DNS 加 A 记录指向服务器 IP。装完想加域名，重跑 `./ocstack install`，数据不动。

没有域名时进网关后台：

```bash
ssh -L 18104:127.0.0.1:18104 root@服务器
# 然后浏览器打开 http://127.0.0.1:18104
```

## 命令

```bash
./ocstack status             状态、地址、证书
./ocstack verify             自检（失败返回非零退出码）
./ocstack autostart enable   开机自启
./ocstack autostart status   查看自启状态
./ocstack upgrade            升级
./ocstack uninstall          卸载（数据保留）
./ocstack uninstall --purge  连数据删
./ocstack bootstrap          补配置网关
./ocstack logs caddy         证书日志
./ocstack cert               证书有效期与剩余天数
```

## 开机自启

`./ocstack install` 会自动启用。VPS 重启后容器会自己起来，不用手动干预。

```bash
./ocstack autostart status    # 看是否启用
./ocstack autostart enable    # 手动开启
./ocstack autostart disable   # 关闭
```

实现方式：一个 systemd oneshot 单元 `oc-stack.service`，依赖 `docker.service`，开机后先等 Docker 真正可用（最多 120 秒），再执行 `docker compose up -d`。这比容器的 `restart: unless-stopped` 更可靠——后者在 Docker 起得比网络晚、或容器停在异常状态时不管用。

`uninstall` 会连带移除这个单元，避免重启后 systemd 去找已经不存在的目录。

## 常见情况

**80/443 被占用** → 自动改用空闲高位端口，前置反代转发过去即可。

**HTTPS 证书** → Caddy 内置 ACME，同时向 Let's Encrypt 和 ZeroSSL 申请，一个失败自动换另一个，到期前 30 天自动续期。不需要 certbot，不需要 cron。

**依赖缺失** → 安装脚本逐项检查 `curl` `git` `jq` `openssl` `tar` `gzip` `ca-certificates` `Docker` `compose`，已装的跳过，缺的才装。支持 Debian 12/13、Ubuntu 22.04+、x86_64 / arm64。

## 数据

```
./data/openchamber/     OpenChamber 设置
./data/opencode/        OpenCode 配置和会话
./data/sub2api/         网关数据（本地模式）
./data/postgres/        数据库（本地模式）
./workspaces/           你的代码（容器内 /workspace）
.env                    所有密码和密钥（600）
```

备份打包 `.env` + `data/` + `workspaces/`。

## Command Code 订阅（可选）

普通订阅只能走私有接口 `/alpha/generate`，标准 OpenAI 接口要付费档。内置 `cc-proxy` 容器做协议翻译：

```bash
bash <(curl -Ls .../install.sh) --cc-key sk-你的订阅key
```

只有填了 key 才启动。

## 已知限制

| 情况 | 说明 |
|---|---|
| OpenChamber 无官方镜像 | 基于 npm 包自建，版本在 `.env` 里 |
| Sub2API 本身没有 Telegram | 截图那种面板是第三方项目，需单独部署 |
| 上游 401 会禁用账号 | 修好 Key 后要在后台手动恢复状态 |
| `max_tokens` 上限 200000 | 配置里用 `max_completion_tokens` 规避 |
| 重装会保留所有密钥 | 想重新生成就删掉 `.env` 里对应的行 |
| 端口也持久化 | 重装不会换端口，反代和隧道不会失效 |

## 安全

- `.env` 权限 600，只有 caddy 暴露公网端口
- OpenChamber 必须设密码：它背后能执行任意 shell 命令
- 防火墙只放 22 和 Caddy 的端口

`./ocstack verify` 会检查前两项。

## 许可

MIT
