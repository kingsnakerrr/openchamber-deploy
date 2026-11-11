#!/usr/bin/env bash
# =============================================================================
# 在已有 nginx 前面挂 OpenChamber / Sub2API 的 SNI 分流
#
# 适用场景：
#   443 被别的程序占用（mmw-agent / 前置 TLS 终结器），
#   它把流量以 proxy_protocol 转给 nginx 的 127.0.0.1:8001，
#   nginx 按 server_name 分流。
#
# 做法：给我们的域名各加一个 server 块，指向 Caddy 的内网端口。
# =============================================================================
set -Eeuo pipefail

NGINX_PREFIX="${NGINX_PREFIX:-/usr/local/nginx}"
SERVERS_DIR="${SERVERS_DIR:-$NGINX_PREFIX/servers}"
CERT_DIR="${CERT_DIR:-$NGINX_PREFIX/cert}"
CERT_NAME="${CERT_NAME:-_.222321.xyz}"
CADDY_PORT="${CADDY_PORT:-}"
OC_DOMAIN="${OC_DOMAIN:-}"
API_DOMAIN="${API_DOMAIN:-}"

if [[ -t 1 ]]; then
  R=$'\033[0m'; DIM=$'\033[2m'; B=$'\033[1m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'
else
  R=""; DIM=""; B=""; RED=""; GRN=""; YEL=""; CYA=""
fi
info() { printf '%s==>%s %s\n' "$CYA" "$R" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s  !!%s %s\n' "$YEL" "$R" "$*" >&2; }
die()  { printf '%s ERR%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

[[ -d "$SERVERS_DIR" ]] || die "找不到 nginx servers 目录：$SERVERS_DIR"
[[ -n "$CADDY_PORT" ]] || die "缺少 CADDY_PORT"

write_server_block() {
  local dom="$1" kind="$2"
  local f="$SERVERS_DIR/oc-stack-${kind}.conf"

  cat > "$f" <<EOF
# 由 ocstack 自动生成 — $(date -Iseconds)
# 让 ${dom} 走 OpenChamber/Sub2API（后端 Caddy 在 127.0.0.1:${CADDY_PORT}）
# 不要手改，重跑 ./ocstack proxy-nginx 会重新生成
server {
    listen                     127.0.0.1:8001 ssl proxy_protocol;
    client_max_body_size       512m;

    set_real_ip_from           127.0.0.1;
    real_ip_header             proxy_protocol;

    server_name                ${dom};

    ssl_certificate            cert/${CERT_NAME}.pem;
    ssl_certificate_key        cert/${CERT_NAME}.key;

    ssl_protocols              TLSv1.2 TLSv1.3;
    ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers  on;

    ssl_stapling               on;
    ssl_stapling_verify        on;
    resolver                   1.1.1.1 valid=60s;
    resolver_timeout           2s;

    location / {
        # Caddy 只接受 TLS，必须用 https + 正确 SNI，否则 400
        proxy_pass                            https://127.0.0.1:${CADDY_PORT};
        proxy_ssl_server_name                 on;
        proxy_ssl_name                        ${dom};
        proxy_ssl_verify                      off;

        proxy_http_version                    1.1;
        proxy_set_header Host                 \$host;
        proxy_set_header X-Real-IP            \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For      \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto    \$scheme;
        proxy_set_header X-Forwarded-Host     \$host;
        proxy_set_header X-Forwarded-Port     \$server_port;

        # WebSocket / SSE 必需
        proxy_set_header Upgrade              \$http_upgrade;
        proxy_set_header Connection           "upgrade";
        proxy_buffering                       off;
        proxy_cache_bypass                    \$http_upgrade;

        # 长连接：OpenChamber 的 SSE 会持续很久
        proxy_connect_timeout                 60s;
        proxy_send_timeout                    3600s;
        proxy_read_timeout                    3600s;

        add_header 'X-Content-Type-Options' nosniff;
    }
}
EOF
  chmod 644 "$f"
  ok "已生成 $f"
}

# ---- 生成 ----
[[ -n "$OC_DOMAIN" ]] && write_server_block "$OC_DOMAIN" "chamber"
[[ -n "$API_DOMAIN" ]] && write_server_block "$API_DOMAIN" "sub2api"

# ---- 校验并重载 ----
info "校验 nginx 配置"
if "$NGINX_PREFIX/sbin/nginx" -t 2>&1 | tail -3; then
  ok "配置合法"
else
  warn "配置有误，已回滚"
  rm -f "$SERVERS_DIR/oc-stack-chamber.conf" "$SERVERS_DIR/oc-stack-sub2api.conf"
  die "nginx -t 失败，请检查上面的错误"
fi

info "重载 nginx"
"$NGINX_PREFIX/sbin/nginx" -s reload 2>&1 | tail -2 || die "reload 失败"
ok "nginx 已重载"
