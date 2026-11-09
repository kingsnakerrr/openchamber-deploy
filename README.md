# oc-stack

一条命令部署 **Sub2API + OpenCode + OpenChamber**，全 Docker，自动 HTTPS。

```
公网 443 ──> caddy ──┬──> openchamber:3000 ──> opencode
                     │
                     └──> sub2api:8080 ──> 上游模型 API
```

## 安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kingsnakerrr/openchamber-deploy/main/install.sh)
```

只问一件事：**域名**。不想现在填就回车跳过，用 IP 访问。

装完直接打印地址和密码，全部自动生成：

```
【OpenChamber】  —— 平时用这个
   地址    http://1.2.3.4:8080
   密码    7pHIQk7plwwiixmQ2HSg

【Sub2API 后台】  —— 填上游地址和 Key 的地方
   地址    http://127.0.0.1:8081  （需 SSH 隧道）
   隧道    ssh -L 8081:127.0.0.1:8081 root@1.2.3.4
   账号    admin@oc.local
   密码    36GRFEDXDuScLSNskidz
```

依赖自动检查，已装的跳过、缺的才装：`curl` `git` `jq` `openssl` `tar` `gzip` `ca-certificates` `Docker` `compose`。

支持 Debian 12/13、Ubuntu 22.04+、x86_64 / arm64。

## 装完三步

**1. 进 Sub2API 后台，加上游账号**

分组 → 新建，平台选 OpenAI → 账号 → 添加，类型 API Key，填商家的 Base URL 和 Key → 点「测试连接」→ API 密钥 → 创建，复制 `sk-...`

**2. 把密钥填进 OpenChamber**

设置 → 提供商 → Sub2API，基础 URL 填 `你的 Sub2API 地址 + /v1`，API 密钥填上一步的 `sk-...`

**3. 验证**

```bash
./ocstack verify
```

## 地址别填错

三层关系，每层填的不一样：

| 位置 | 填什么 | 例子 |
|---|---|---|
| Sub2API 后台的「上游账号」 | **商家**的地址和 Key | `https://api.deepseek.com` |
| OpenChamber 的「基础 URL」 | **你自己**的 Sub2API | `https://api.你的域名/v1` |
| OpenChamber 的「API 密钥」 | Sub2API **签发**的 Key | `sk-30db821c4c...` |

**不要**把商家的 Key 填进 OpenChamber。商家 Key 只存在 Sub2API 里，客户端永远用二次签发的。

## 域名

两个域名最好，各自独立证书：

| OpenChamber | Sub2API | 结果 |
|---|---|---|
| `oc.example.com` | `api.example.com` | 都走 HTTPS，网关可以给其他客户端用 |
| `oc.example.com` | 空 | 网关只走内部网络，后台用 SSH 隧道进 |
| 空 | 空 | IP + HTTP，仅适合试用 |

DNS 加 A 记录指向服务器 IP。装完想加域名，重跑 `./ocstack install` 即可，数据不动。

## 命令

```bash
./ocstack status        状态、地址、证书
./ocstack verify        16 项自检
./ocstack upgrade       升级
./ocstack uninstall     卸载（数据保留）
./ocstack uninstall --purge   连数据删
./ocstack bootstrap     补配置上游
./ocstack logs caddy    证书日志
```

## 常见情况

**80/443 被 nginx 占用** → 自动改用空闲端口并提示，前置反代转发过去即可。

**没有域名也要进后台** → 用输出的 SSH 隧道命令，Sub2API 只绑 `127.0.0.1`，不暴露公网。

**HTTPS 证书** → Caddy 内置 ACME，同时向 Let's Encrypt 和 ZeroSSL 申请，一个失败自动换另一个，到期前 30 天自动续期，不需要 certbot 也不需要 cron。

## 数据

```
./data/openchamber/     OpenChamber 设置
./data/opencode/        OpenCode 配置和会话
./data/sub2api/         Sub2API 应用数据
./data/postgres/        数据库
./data/redis/
./workspaces/           你的代码（容器内 /workspace）
.env                    所有密码和密钥（600）
```

备份打包 `.env` + `data/` + `workspaces/` 就行。

## Command Code 订阅（可选）

Command Code 普通订阅只能走私有接口 `/alpha/generate`，标准 OpenAI 接口要 Provider 付费档。本项目内置 `cc-proxy` 容器做协议翻译：

```bash
./ocstack install --cc-key sk-你的CommandCode订阅key
```

`cc-proxy` 和 sub2api 在同一个 Docker 网络，不需要额外网桥。只有填了 `CC_API_KEY` 才启动。

## 已知限制

| 情况 | 说明 |
|---|---|
| OpenChamber 无官方镜像 | 基于 npm 包自建，版本在 `.env` 里 |
| Sub2API 本身没有 Telegram | 截图那种面板是第三方项目，需单独部署 |
| 上游 401 会禁用账号 | 修好 Key 后要在后台手动恢复状态 |
| `max_tokens` 上限 200000 | 配置里用 `max_completion_tokens` 规避 |

## 安全

- `.env` 权限 600，只有 caddy 暴露 80/443
- OpenChamber 必须设密码：它背后能执行任意 shell 命令
- 防火墙只放 22/80/443

`./ocstack verify` 会检查前两项。

## 许可

MIT
