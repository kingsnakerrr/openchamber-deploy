# 手动部署（不想用一键脚本）

适合想完全掌控每一步的场景。全程假设 Debian 12 / Ubuntu 22.04，root 权限。

## 1. 基础环境

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg git jq openssl

# Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Node 24
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
node -v   # 必须 ≥ v24.14
```

## 2. Sub2API

```bash
mkdir -p /opt/oc-stack/sub2api/{data,postgres_data,redis_data}
cd /opt/oc-stack/sub2api

cp /path/to/repo/templates/docker-compose.yml .

# 生成配置
cat > /opt/oc-stack/.env <<EOF
BIND_HOST=127.0.0.1
SERVER_PORT=8080
SERVER_MODE=release
POSTGRES_USER=sub2api
POSTGRES_DB=sub2api
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=$(openssl rand -hex 16)
TZ=Asia/Shanghai
EOF
chmod 600 /opt/oc-stack/.env

docker compose --env-file /opt/oc-stack/.env up -d
curl http://127.0.0.1:8080/health   # 等到返回 ok
```

## 3. OpenCode

```bash
curl -fsSL https://opencode.ai/v2/install | bash
export PATH="$HOME/.opencode/bin:$PATH"

mkdir -p ~/.config/opencode
cat > ~/.config/opencode/opencode.json <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "sub2api/deepseek-v4.1-flash",
  "providers": {
    "sub2api": {
      "name": "Sub2API",
      "env": ["SUB2API_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "deepseek-v4.1-flash": {
          "modelID": "deepseek/deepseek-v4.1-flash",
          "name": "DeepSeek V4.1 Flash",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"],
            "reasoning": { "supported": true, "effort": ["low", "high", "max"] }
          },
          "limit": { "context": 1000000, "output": 384000 },
          "compatibility": {
            "reasoningField": "reasoning_content",
            "maxTokensField": "max_completion_tokens"
          }
        }
      }
    }
  }
}
JSON
```

## 4. 建分组和密钥

浏览器打开 `http://127.0.0.1:8080`（本机用，或先 SSH 隧道 `ssh -L 8080:127.0.0.1:8080 user@server`）。

**顺序不能错：**

1. 分组 → 新建，平台 **OpenAI**
2. 账号 → 添加，类型 `API Key`，填上游 `base_url` + key + 模型映射，勾选分组
3. 账号右侧 `...` → 测试连接
4. API 密钥 → 创建，绑分组，抄下 `sk-...`

## 5. OpenChamber

```bash
npm install -g @openchamber/web

mkdir -p /opt/oc-stack
cat > /opt/oc-stack/.env.runtime <<EOF
SUB2API_API_KEY=sk-你刚创建的
OPENCHAMBER_UI_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 /opt/oc-stack/.env.runtime
```

systemd 单元 `/etc/systemd/system/openchamber.service`：

```ini
[Unit]
Description=OpenChamber
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
EnvironmentFile=/opt/oc-stack/.env.runtime
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.opencode/bin
ExecStart=/usr/local/bin/openchamber serve --foreground --port 3000 --host 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now openchamber
systemctl status openchamber
```

## 6. Caddy

```bash
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

`/etc/caddy/Caddyfile`：

```caddy
{
    email you@example.com
}

oc.example.com {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1
        transport http {
            read_timeout 3600s
            write_timeout 3600s
        }
    }
}

api.example.com {
    encode gzip zstd
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
        transport http {
            read_timeout 900s
            write_timeout 900s
        }
    }
}
```

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl restart caddy
journalctl -u caddy -f      # 看证书申请过程
```

DNS 必须先把两个子域 A 记录指向服务器 IP，否则 ACME 会失败。

## 7. 防火墙

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

**不要**放行 3000 和 8080。

## 8. 验证

```bash
sudo /opt/oc-stack/scripts/verify.sh
```
