# oc-stack

一键在 VPS 上部署 **Sub2API + OpenCode + OpenChamber**，可选 Caddy 自动 HTTPS。

三条命令从裸机到能用的 Web AI 编程工作台。

```
浏览器 ──HTTPS──> Caddy ──┬──> OpenChamber :3000 ──> OpenCode ──┐
                          │                                     │
                          └──> Sub2API :8080 <───────────────────┘
                                  │
                                  └──> 上游模型 API
```

## 前提

| 项 | 要求 |
|---|---|
| 系统 | Debian 12 / Ubuntu 22.04 及以上 |
| 权限 | root（或 sudo） |
| 内存 | 2 GB 起，4 GB 推荐 |
| 磁盘 | 10 GB 空闲 |
| 网络 | 能访问 GitHub、Docker Hub、npm |
| 域名 | 可选，但要自动 HTTPS 就需要 |

## 快速开始

```bash
git clone https://github.com/<你的账号>/oc-stack.git
cd oc-stack

# 最小安装（只有 IP + 端口，不配 HTTPS）
sudo ./install.sh

# 推荐：带域名和自动 HTTPS
sudo ./install.sh --oc-domain oc.example.com --api-domain api.example.com --email you@example.com
```

装完终端会打印：

```
OpenChamber   http://<IP>:3000       密码: xxxxxxxx
Sub2API       http://<IP>:8080       管理员: admin@example.com
```

### 全部参数

```bash
sudo ./install.sh \
  --oc-domain oc.example.com \      # OpenChamber 域名，留空则只用 IP:3000
  --api-domain api.example.com \    # Sub2API 域名，留空则只用 IP:8080
  --email you@example.com \         # Let's Encrypt 通知邮箱（用域名时必填）
  --oc-port 3000 \                  # OpenChamber 本地端口
  --admin-email admin@example.com \ # Sub2API 管理员账号
  --skip-sub2api \                  # 跳过网关，只装 OpenCode + OpenChamber
  --no-caddy \                      # 不装反代
  --yes                             # 全自动，不问问题
```

## 装完要做的三件事

### 1. 登录 Sub2API 建分组和密钥

打开 `http://<IP>:8080`（或你的 api 域名），**顺序不能错**：

1. **分组** → 新建，平台选 **OpenAI**（建完不可改）
2. **账号** → 添加上游账号，类型 `API Key`，填上游 `base_url` + key + 模型映射，勾选所属分组
3. 点账号右侧 `...` → **测试连接**，必须通过
4. **API 密钥** → 创建，绑定刚建的分组，抄下 `sk-...`（只显示一次）

### 2. 把密钥填进 OpenCode

```bash
# 编辑运行时环境
sudo nano /opt/oc-stack/.env.runtime

# 把 SUB2API_API_KEY 改成你刚创建的 sk-...
# 然后重启
sudo systemctl restart openchamber
```

### 3. 验证

```bash
sudo /opt/oc-stack/scripts/verify.sh
```

四项全绿就通了：模型可见、能对话、能调工具、推理链正常。

## 日常运维

```bash
# 状态总览
sudo /opt/oc-stack/scripts/status.sh

# 日志
sudo journalctl -u openchamber -f
sudo docker compose -f /opt/oc-stack/sub2api/docker-compose.yml logs -f sub2api

# 重启
sudo systemctl restart openchamber
sudo docker compose -f /opt/oc-stack/sub2api/docker-compose.yml restart

# 升级
sudo ./install.sh --upgrade

# 卸载（保留数据需加 --keep-data）
sudo ./uninstall.sh
```

## 目录结构

```
/opt/oc-stack/
├── .env                 # Sub2API 的 compose 变量（数据库密码等），chmod 600
├── .env.runtime         # 运行时密钥（SUB2API_API_KEY / UI 密码），chmod 600
├── sub2api/
│   ├── docker-compose.yml
│   ├── data/            # 应用数据
│   ├── postgres_data/
│   └── redis_data/
└── scripts/

~/.config/opencode/opencode.json   # provider 配置（含 baseURL 和模型能力声明）
/etc/caddy/Caddyfile               # 反代配置（启用 Caddy 时）
```

## 已内置的坑规避

这些是实测踩出来的，脚本已经处理：

| 坑 | 处理方式 |
|---|---|
| `max_tokens` 有 200000 上限，超了直接 400 | 配置里显式写 `maxTokensField: max_completion_tokens` |
| `reasoning_content` 不被识别为思考块 | 写 `reasoningField: reasoning_content` |
| OpenChamber 要求 Node ≥ 24.14 | 安装前检查版本，不满足就报错退出 |
| Nginx 丢 `session_id` 下划线头 | 用 Caddy（没有这个限制）；Nginx 用户需加 `underscores_in_headers on` |
| OpenChamber 的 WebSocket/SSE 被缓冲 | Caddy 配 `flush_interval -1` + 长超时 |
| Sub2API 重启后所有人被登出 | `.env` 里固定 `JWT_SECRET`，不随机生成 |
| 服务起来找不到 API Key | 密钥写进 `EnvironmentFile`，不依赖 shell 环境 |

## 安全清单

部署完请逐条确认：

- [ ] `.env` 和 `.env.runtime` 权限是 `600`
- [ ] Sub2API 的 8080 和 OpenChamber 的 3000 **只绑 127.0.0.1**，公网只暴露 443
- [ ] OpenChamber 设了 UI 密码
- [ ] Sub2API 管理员密码不是弱口令
- [ ] 服务器开了防火墙，只放 22 / 80 / 443

最后一条最重要：OpenChamber 背后是一个**能执行任意 shell 命令**的 agent，没设密码等于把 root shell 挂在公网。

## 手动安装（不想用脚本）

见 [docs/manual.md](docs/manual.md)。

## 许可

MIT
