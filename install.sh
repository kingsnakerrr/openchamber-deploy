#!/usr/bin/env bash
# =============================================================================
# oc-stack installer
# 一键部署 Sub2API + OpenCode + OpenChamber（可选 Caddy 自动 HTTPS）
#
# 用法：
#   sudo ./install.sh
#   sudo ./install.sh --oc-domain oc.example.com --api-domain api.example.com --email you@example.com
#   sudo ./install.sh --upgrade
# =============================================================================
set -Eeuo pipefail

OC_STACK_VERSION="1.0.0"
INSTALL_DIR="/opt/oc-stack"
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
NODE_MIN_MAJOR=24
NODE_MIN_MINOR=14

# ---- 参数默认值 -------------------------------------------------------------
OC_DOMAIN=""
API_DOMAIN=""
ACME_EMAIL=""
OC_PORT="3000"
ADMIN_EMAIL="admin@example.com"
SKIP_SUB2API="false"
SKIP_CADDY="false"
UPSTREAM_URL=""
UPSTREAM_KEY=""
MODEL_ID="deepseek/deepseek-v4.1-flash"
ASSUME_YES="false"
UPGRADE="false"

# ---- 输出 -------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

log()   { printf '%s==>%s %s\n' "$C_CYA" "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()   { printf '%s ERR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step()  { printf '\n%s%s▸ %s%s\n' "$C_B" "$C_CYA" "$*" "$C_RESET"; }

trap 'die "第 ${LINENO} 行失败：${BASH_COMMAND}"' ERR

usage() {
  cat <<'EOF'
oc-stack 安装器

  --oc-domain <域名>      OpenChamber 域名（留空则只用 IP:端口）
  --api-domain <域名>     Sub2API 域名（留空则只用 IP:端口）
  --email <邮箱>          Let's Encrypt 通知邮箱（用域名时必填）
  --oc-port <端口>        OpenChamber 端口，默认 3000
  --admin-email <邮箱>    Sub2API 管理员登录名
  --upstream-url <URL>    上游 API 地址，给了就自动建分组/账号/密钥
  --upstream-key <Key>    上游 API Key
  --model <模型ID>        上游模型 ID，默认 deepseek/deepseek-v4.1-flash
  --skip-sub2api          只装 OpenCode + OpenChamber，跳过网关
  --no-caddy              不安装反代，直接用端口访问
  --upgrade               只升级组件，保留全部配置和数据
  --yes                   全自动，不询问
  -h, --help              显示本帮助

示例：
  sudo ./install.sh
  sudo ./install.sh --oc-domain oc.example.com --api-domain api.example.com --email me@example.com
  sudo ./install.sh --skip-sub2api --no-caddy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oc-domain)    OC_DOMAIN="${2:-}"; shift 2 ;;
    --api-domain)   API_DOMAIN="${2:-}"; shift 2 ;;
    --email)        ACME_EMAIL="${2:-}"; shift 2 ;;
    --oc-port)      OC_PORT="${2:-}"; shift 2 ;;
    --admin-email)  ADMIN_EMAIL="${2:-}"; shift 2 ;;
    --upstream-url)  UPSTREAM_URL="${2:-}"; shift 2 ;;
    --upstream-key)  UPSTREAM_KEY="${2:-}"; shift 2 ;;
    --model)         MODEL_ID="${2:-}"; shift 2 ;;
    --skip-sub2api) SKIP_SUB2API="true"; shift ;;
    --no-caddy)     SKIP_CADDY="true"; shift ;;
    --upgrade)      UPGRADE="true"; shift ;;
    --yes|-y)       ASSUME_YES="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

# ---- 前置检查 ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "需要 root 权限，请用 sudo 运行"

if [[ -n "$OC_DOMAIN" || -n "$API_DOMAIN" ]]; then
  [[ -n "$ACME_EMAIL" ]] || die "使用域名时必须提供 --email（Let's Encrypt 通知邮箱）"
fi

if [[ -n "$OC_DOMAIN" && -z "$API_DOMAIN" && "$SKIP_SUB2API" == "false" ]]; then
  warn "只给了 --oc-domain，Sub2API 将只监听本机，不对外提供"
fi

TARGET_USER="root"
TARGET_HOME="/root"

# ---- 系统检测 ---------------------------------------------------------------
detect_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "只支持 Debian / Ubuntu，当前是：${OS_ID:-未知}" ;;
  esac

  case "$(uname -m)" in
    x86_64|aarch64) ARCH="$(uname -m)" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  ok "${OS_ID} ${OS_VER} (${ARCH})"
}

check_memory() {
  local mem_mb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  if (( mem_mb < 1800 )); then
    warn "内存仅 ${mem_mb}MB，建议 2GB 以上，否则 PostgreSQL + Node 可能 OOM"
  else
    ok "内存 ${mem_mb}MB"
  fi
}

# ---- 依赖安装 ---------------------------------------------------------------
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

install_base_deps() {
  step "安装基础依赖"
  apt-get update -qq
  apt_install ca-certificates curl gnupg git jq openssl tar gzip iproute2
  ok "基础依赖就绪"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version | cut -d, -f1)"
    return
  fi
  step "安装 Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable
EOF
  apt-get update -qq
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker >/dev/null 2>&1 || true
  ok "Docker $(docker --version | cut -d, -f1)"
}

node_version_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v major minor
  v="$(node -v | sed 's/^v//')"
  major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
  (( major > NODE_MIN_MAJOR )) && return 0
  (( major == NODE_MIN_MAJOR && minor >= NODE_MIN_MINOR )) && return 0
  return 1
}

install_node() {
  if node_version_ok; then
    ok "Node $(node -v)（满足 ≥ ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}）"
    return
  fi
  step "安装 Node.js ${NODE_MIN_MAJOR}.x"
  if command -v node >/dev/null 2>&1; then
    warn "当前 Node $(node -v) 版本过低，将替换为 NodeSource ${NODE_MIN_MAJOR}.x"
    apt-get remove -y -qq nodejs libnode-dev >/dev/null 2>&1 || true
  fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN_MAJOR}.x" -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh >/dev/null 2>&1
  rm -f /tmp/nodesource_setup.sh
  apt_install nodejs
  node_version_ok || die "Node 安装后版本仍不满足要求：$(node -v 2>/dev/null || echo 无)"
  ok "Node $(node -v)"
}

install_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    ok "OpenCode 已安装：$(opencode --version 2>/dev/null || echo 未知)"
    if [[ "$UPGRADE" == "true" ]]; then
      step "升级 OpenCode"
      curl -fsSL https://opencode.ai/v2/install | bash >/dev/null 2>&1 || warn "OpenCode 升级失败，继续"
      ok "OpenCode $(opencode --version 2>/dev/null || echo 未知)"
    fi
    return
  fi
  step "安装 OpenCode"
  curl -fsSL https://opencode.ai/v2/install | bash
  export PATH="/root/.opencode/bin:$PATH"
  grep -q '.opencode/bin' /root/.bashrc 2>/dev/null || \
    echo 'export PATH="/root/.opencode/bin:$PATH"' >> /root/.bashrc
  command -v opencode >/dev/null 2>&1 || die "OpenCode 安装后仍找不到，请检查 PATH"
  ok "OpenCode $(opencode --version 2>/dev/null || echo 未知)"
}

install_openchamber() {
  if command -v openchamber >/dev/null 2>&1; then
    ok "OpenChamber 已安装：$(openchamber --version 2>/dev/null || echo 未知)"
    if [[ "$UPGRADE" == "true" ]]; then
      step "升级 OpenChamber"
      npm install -g @openchamber/web@latest >/dev/null 2>&1 || warn "OpenChamber 升级失败，继续"
    fi
    return
  fi
  step "安装 OpenChamber"
  npm install -g @openchamber/web >/dev/null 2>&1
  command -v openchamber >/dev/null 2>&1 || die "OpenChamber 安装失败"
  ok "OpenChamber $(openchamber --version 2>/dev/null || echo 未知)"
}

# ---- 密钥管理 ---------------------------------------------------------------
rand_hex() { openssl rand -hex 32; }

# 读取 .env 中的值，不存在则生成并写回
# 用法: ensure_env <文件> <键> [生成命令]
ensure_env() {
  local file="$1" key="$2" gen="${3:-rand_hex}"
  local cur
  cur="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  if [[ -z "$cur" ]]; then
    cur="$($gen)"
    printf '%s=%s\n' "$key" "$cur" >> "$file"
  fi
  printf '%s' "$cur"
}

# ---- Sub2API ----------------------------------------------------------------
setup_sub2api() {
  step "部署 Sub2API 网关"

  local dir="$INSTALL_DIR/sub2api"
  local envf="$INSTALL_DIR/.env"
  mkdir -p "$dir"/{data,postgres_data,redis_data}

  cp "$INSTALL_DIR/templates/docker-compose.yml" "$dir/docker-compose.yml"

  if [[ ! -f "$envf" ]]; then
    touch "$envf"
    chmod 600 "$envf"
    {
      echo "# oc-stack 生成的 Sub2API 配置 — $(date -Iseconds)"
      echo "# 修改后执行: docker compose -f $dir/docker-compose.yml up -d"
      echo
    } >> "$envf"
  fi
  chmod 600 "$envf"

  local pg_pw jwt totp admin_pw
  pg_pw="$(ensure_env "$envf" POSTGRES_PASSWORD)"
  jwt="$(ensure_env "$envf" JWT_SECRET)"
  totp="$(ensure_env "$envf" TOTP_ENCRYPTION_KEY)"
  admin_pw="$(ensure_env "$envf" ADMIN_PASSWORD)"

  # 这些每次覆盖写入，保持和安装参数一致
  set_env "$envf" BIND_HOST "127.0.0.1"
  set_env "$envf" SERVER_PORT "8080"
  set_env "$envf" SERVER_MODE "release"
  set_env "$envf" ADMIN_EMAIL "$ADMIN_EMAIL"
  set_env "$envf" TZ "Asia/Shanghai"
  set_env "$envf" POSTGRES_USER "sub2api"
  set_env "$envf" POSTGRES_DB "sub2api"

  chmod 600 "$envf"

  # 实测要求：管理员密码 >= 8 位，JWT_SECRET >= 32 字节，否则容器会反复重启
  if (( ${#admin_pw} < 8 )); then
    warn "ADMIN_PASSWORD 少于 8 位（当前 ${#admin_pw} 位），Sub2API 会拒绝启动，正在重新生成"
    admin_pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    set_env "$envf" ADMIN_PASSWORD "$admin_pw"
  fi
  if (( ${#jwt} < 32 )); then
    die "JWT_SECRET 少于 32 字节，Sub2API 会拒绝启动。请删除 $envf 里的 JWT_SECRET 行后重跑"
  fi

  log "启动容器（首次拉镜像可能较慢）"
  ( cd "$dir" && docker compose --env-file "$envf" up -d ) >/dev/null 2>&1 \
    || die "Sub2API 容器启动失败，查看：cd $dir && docker compose --env-file $envf logs"

  log "等待 Sub2API 就绪"
  local i
  for i in $(seq 1 60); do
    if curl -fsS -m 2 http://127.0.0.1:8080/health >/dev/null 2>&1; then
      ok "Sub2API 已就绪（127.0.0.1:8080）"
      # 记录管理员密码供最终输出
      printf '%s' "$admin_pw" > "$INSTALL_DIR/.admin_password"
      chmod 600 "$INSTALL_DIR/.admin_password"
      return
    fi
    sleep 2
  done
  warn "Sub2API 60 秒内未通过健康检查，可能仍在迁移数据库"
  warn "查看日志：docker compose -f $dir/docker-compose.yml --env-file $envf logs -f sub2api"
}

set_env() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    # 用 | 作分隔符避免值里的 / 出问题
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# ---- 运行时环境（systemd 用） -----------------------------------------------
setup_runtime_env() {
  step "配置运行时密钥"

  local envf="$INSTALL_DIR/.env.runtime"
  [[ -f "$envf" ]] || { touch "$envf"; }
  chmod 600 "$envf"

  local ui_pw api_key
  ui_pw="$(ensure_env "$envf" OPENCHAMBER_UI_PASSWORD)"
  api_key="$(grep -E '^SUB2API_API_KEY=' "$envf" 2>/dev/null | cut -d= -f2- || true)"

  if [[ -z "$api_key" ]]; then
    set_env "$envf" SUB2API_API_KEY "sk-在Sub2API后台创建后填入"
    warn "SUB2API_API_KEY 尚未填写，装完后需要手动补上"
  fi

  printf '%s' "$ui_pw" > "$INSTALL_DIR/.ui_password"
  chmod 600 "$INSTALL_DIR/.ui_password"
  ok "运行时密钥就绪"
}

# ---- OpenCode provider 配置 -------------------------------------------------
write_opencode_config() {
  step "写入 OpenCode provider 配置"
  mkdir -p "$OPENCODE_CONFIG_DIR"
  local cfg="$OPENCODE_CONFIG_DIR/opencode.json"

  # 已有配置就备份，不破坏用户原有 provider
  if [[ -f "$cfg" ]] && ! grep -q '"oc-stack"' "$cfg" 2>/dev/null; then
    local bak="$cfg.bak.$(date +%s)"
    cp "$cfg" "$bak"
    warn "检测到已有配置，已备份到 $bak"
    log "将把 sub2api provider 合并进现有配置（保留其他 provider）"
    merge_opencode_config "$cfg"
  else
    generate_opencode_config "$cfg"
  fi
  chmod 600 "$cfg"
  ok "配置已写入 $cfg"
}

generate_opencode_config() {
  local cfg="$1"
  local base_url="http://127.0.0.1:8080/v1"
  [[ "$SKIP_SUB2API" == "true" ]] && base_url="https://api.example.com/v1"

  cat > "$cfg" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "sub2api/deepseek-v4.1-flash",
  "providers": {
    "sub2api": {
      "name": "Sub2API",
      "env": ["SUB2API_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "${base_url}",
        "headerTimeout": 300000,
        "chunkTimeout": 900000
      },
      "models": {
        "deepseek-v4.1-flash": {
          "modelID": "deepseek/deepseek-v4.1-flash",
          "name": "DeepSeek V4.1 Flash",
          "family": "deepseek-flash",
          "releaseDate": "2026-09-10",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"],
            "temperature": true,
            "reasoning": {
              "supported": true,
              "effort": ["low", "high", "max"]
            }
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
}

merge_opencode_config() {
  local cfg="$1"
  command -v jq >/dev/null 2>&1 || die "合并配置需要 jq"
  local base_url="http://127.0.0.1:8080/v1"
  [[ "$SKIP_SUB2API" == "true" ]] && base_url="https://api.example.com/v1"

  local tmp
  tmp="$(mktemp)"
  jq --arg url "$base_url" '
    .providers = (.providers // {}) |
    .providers.sub2api = {
      "name": "Sub2API",
      "env": ["SUB2API_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": $url,
        "headerTimeout": 300000,
        "chunkTimeout": 900000
      },
      "models": {
        "deepseek-v4.1-flash": {
          "modelID": "deepseek/deepseek-v4.1-flash",
          "name": "DeepSeek V4.1 Flash",
          "family": "deepseek-flash",
          "releaseDate": "2026-09-10",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"],
            "temperature": true,
            "reasoning": {"supported": true, "effort": ["low","high","max"]}
          },
          "limit": {"context": 1000000, "output": 384000},
          "compatibility": {
            "reasoningField": "reasoning_content",
            "maxTokensField": "max_completion_tokens"
          }
        }
      }
    }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# ---- systemd ----------------------------------------------------------------
install_systemd_unit() {
  step "配置 OpenChamber 开机自启"

  local unit=/etc/systemd/system/openchamber.service
  cat > "$unit" <<UNIT
[Unit]
Description=OpenChamber - Web UI for OpenCode
Documentation=https://openchamber.dev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
WorkingDirectory=${TARGET_HOME}
EnvironmentFile=${INSTALL_DIR}/.env.runtime
Environment=HOME=${TARGET_HOME}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${TARGET_HOME}/.opencode/bin
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/openchamber serve --foreground --port ${OC_PORT} --host 127.0.0.1
Restart=always
RestartSec=5
TimeoutStopSec=30
KillMode=mixed

# 加固
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=false

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable openchamber >/dev/null 2>&1
  systemctl restart openchamber
  sleep 3

  if systemctl is-active --quiet openchamber; then
    ok "OpenChamber 服务运行中（127.0.0.1:${OC_PORT}）"
  else
    warn "OpenChamber 启动失败，查看：journalctl -u openchamber -n 50 --no-pager"
  fi
}

# ---- Caddy ------------------------------------------------------------------
install_caddy() {
  local has_domain="false"
  [[ -n "$OC_DOMAIN" || -n "$API_DOMAIN" ]] && has_domain="true"

  if [[ "$SKIP_CADDY" == "true" || "$has_domain" == "false" ]]; then
    log "跳过 Caddy（未提供域名或指定了 --no-caddy）"
    return
  fi

  step "安装 Caddy 并配置 HTTPS"
  if ! command -v caddy >/dev/null 2>&1; then
    apt_install debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt_install caddy
  fi

  local cf=/etc/caddy/Caddyfile
  [[ -f "$cf" ]] && cp "$cf" "${cf}.bak.$(date +%s)"

  {
    echo "# oc-stack 生成 — $(date -Iseconds)"
    echo "{"
    echo "    email ${ACME_EMAIL}"
    echo "}"
    echo

    if [[ -n "$OC_DOMAIN" ]]; then
      cat <<EOF
${OC_DOMAIN} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:${OC_PORT} {
        flush_interval -1
        transport http {
            read_timeout 3600s
            write_timeout 3600s
        }
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        -Server
    }
}

EOF
    fi

    if [[ -n "$API_DOMAIN" && "$SKIP_SUB2API" == "false" ]]; then
      cat <<EOF
${API_DOMAIN} {
    encode gzip zstd
    # Sub2API 依赖带下划线的请求头（session_id），Caddy 默认不丢，无需特殊配置
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
        transport http {
            read_timeout 900s
            write_timeout 900s
        }
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        -Server
    }
}

EOF
    fi
  } > "$cf"

  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy
  sleep 2
  if systemctl is-active --quiet caddy; then
    ok "Caddy 运行中，证书将在首次访问时自动申请"
  else
    warn "Caddy 启动失败，查看：journalctl -u caddy -n 50 --no-pager"
  fi
}

# ---- 防火墙 ----------------------------------------------------------------
configure_firewall() {
  step "配置防火墙"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    if [[ "$SKIP_CADDY" == "false" ]]; then
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    else
      ufw allow "${OC_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    ok "ufw 规则已更新"
    return
  fi

  warn "未检测到活跃的 ufw，请自行确认云厂商安全组："
  warn "  只放行 22 / 80 / 443，不要放行 3000 和 8080"
}

# ---- 汇总 -------------------------------------------------------------------
print_summary() {
  local ip ui_pw admin_pw
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  ip="${ip:-<服务器IP>}"
  ui_pw="$(cat "$INSTALL_DIR/.ui_password" 2>/dev/null || echo '见 .env.runtime')"
  admin_pw="$(cat "$INSTALL_DIR/.admin_password" 2>/dev/null || echo '见 install 日志')"

  printf '\n%s%s╭──────────────────────────────────────────────────────────────╮%s\n' "$C_B" "$C_GRN" "$C_RESET"
  printf '%s%s│  安装完成                                                    │%s\n' "$C_B" "$C_GRN" "$C_RESET"
  printf '%s%s╰──────────────────────────────────────────────────────────────╯%s\n\n' "$C_B" "$C_GRN" "$C_RESET"

  if [[ -n "$OC_DOMAIN" ]]; then
    printf '  %sOpenChamber%s  https://%s\n' "$C_B" "$C_RESET" "$OC_DOMAIN"
  else
    printf '  %sOpenChamber%s  http://%s:%s\n' "$C_B" "$C_RESET" "$ip" "$OC_PORT"
    printf '  %s              仅绑定 127.0.0.1，外网需自建隧道或加反代%s\n' "$C_DIM" "$C_RESET"
  fi
  printf '  %sUI 密码%s      %s\n' "$C_B" "$C_RESET" "$ui_pw"

  if [[ "$SKIP_SUB2API" == "false" ]]; then
    echo
    if [[ -n "$API_DOMAIN" ]]; then
      printf '  %sSub2API%s      https://%s\n' "$C_B" "$C_RESET" "$API_DOMAIN"
    else
      printf '  %sSub2API%s      http://127.0.0.1:8080\n' "$C_B" "$C_RESET"
    fi
    printf '  %s管理员%s       %s\n' "$C_B" "$C_RESET" "$ADMIN_EMAIL"
    printf '  %s密码%s         %s\n' "$C_B" "$C_RESET" "$admin_pw"
  fi

  cat <<EOF

  ${C_B}接下来三步：${C_RESET}

  1) 登录 Sub2API 后台创建「分组(OpenAI) → 上游账号 → 测试连接 → API 密钥」
     把拿到的 sk-... 填进：
       sudo nano ${INSTALL_DIR}/.env.runtime
     找到 SUB2API_API_KEY= 这一行，替换后：
       sudo systemctl restart openchamber

  2) 验证链路：
       sudo ${INSTALL_DIR}/scripts/verify.sh

  3) 打开 OpenChamber 网页，模型选择器里选 Sub2API / DeepSeek V4.1 Flash

  ${C_DIM}日志：journalctl -u openchamber -f
  状态：sudo ${INSTALL_DIR}/scripts/status.sh${C_RESET}

EOF

  printf '%s  凭据文件（600 权限）：%s/.env.runtime  %s/.env%s\n\n' "$C_DIM" "$INSTALL_DIR" "$INSTALL_DIR" "$C_RESET"
}

# ---- 主流程 -----------------------------------------------------------------
main() {
  printf '\n%soc-stack v%s%s — Sub2API + OpenCode + OpenChamber\n\n' "$C_B" "$OC_STACK_VERSION" "$C_RESET"

  detect_os
  check_memory
  install_base_deps

  if [[ "$SKIP_SUB2API" == "false" ]]; then
    install_docker
  fi

  install_node
  install_opencode
  install_openchamber

  step "准备目录"
  mkdir -p "$INSTALL_DIR"/{scripts,templates}
  # 从仓库目录同步脚本和模板
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ "$src_dir" != "$INSTALL_DIR" ]]; then
    cp -f "$src_dir/scripts/"*.sh "$INSTALL_DIR/scripts/" 2>/dev/null || true
    cp -f "$src_dir/templates/"* "$INSTALL_DIR/templates/" 2>/dev/null || true
    cp -f "$src_dir/uninstall.sh" "$INSTALL_DIR/" 2>/dev/null || true
  fi
  chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
  ok "$INSTALL_DIR"

  if [[ "$SKIP_SUB2API" == "false" ]]; then
    setup_sub2api
  fi

  setup_runtime_env
  write_opencode_config
  install_systemd_unit
  install_caddy
  configure_firewall

  # 提供了上游参数就自动完成后台配置，省掉手动点十几下
  if [[ "$SKIP_SUB2API" == "false" && -n "$UPSTREAM_URL" && -n "$UPSTREAM_KEY" ]]; then
    step "自动配置 Sub2API（分组 / 账号 / 密钥）"
    INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/bootstrap-sub2api.sh" \
      --upstream-url "$UPSTREAM_URL" \
      --upstream-key "$UPSTREAM_KEY" \
      --model "$MODEL_ID" || warn "自动配置未完全成功，可稍后手动重跑 scripts/bootstrap-sub2api.sh"
    # 拿到密钥后重启一次，让服务读到
    systemctl restart openchamber || true
  fi

  print_summary
}

# 允许被 source 用于测试（不执行主流程）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
