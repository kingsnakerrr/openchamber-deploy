#!/usr/bin/env bash
# =============================================================================
# status.sh — 一屏看全状态
# =============================================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/oc-stack}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

hdr() { printf '\n%s%s%s%s\n' "$C_B" "$C_CYA" "$*" "$C_RESET"; }

# ---------- 系统 ----------
hdr "系统"
printf '  主机      %s\n' "$(hostname)"
printf '  运行时间  %s\n' "$(uptime -p 2>/dev/null | sed 's/^up //' || uptime)"
printf '  负载      %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
printf '  内存      %s\n' "$(free -h | awk '/Mem:/{printf "%s / %s", $3, $2}')"
printf '  磁盘      %s\n' "$(df -h / | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"

# ---------- 服务 ----------
hdr "服务"
for u in openchamber caddy; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}.service"; then
    st="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
    if [[ "$st" == "active" ]]; then
      printf '  %s%-12s%s %s● %s%s  %s\n' "$C_B" "$u" "$C_RESET" "$C_GRN" "$st" "$C_RESET" \
        "$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null | cut -d' ' -f2-3)"
    else
      printf '  %s%-12s%s %s● %s%s\n' "$C_B" "$u" "$C_RESET" "$C_RED" "$st" "$C_RESET"
    fi
  fi
done

# ---------- 容器 ----------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  hdr "容器"
  docker ps --filter name=sub2api --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    | column -t -s $'\t' 2>/dev/null || docker ps --filter name=sub2api
fi

# ---------- 端口 ----------
hdr "监听端口"
ss -tlnp 2>/dev/null | awk 'NR==1 || /:3000|:8080|:443|:80 /' | head -12

# ---------- 网关 ----------
hdr "网关健康"
if curl -fsS -m 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
  printf '  Sub2API   %s● 正常%s\n' "$C_GRN" "$C_RESET"
else
  printf '  Sub2API   %s● 不可达%s\n' "$C_RED" "$C_RESET"
fi
if curl -fsS -m 3 "http://127.0.0.1:${OC_PORT:-3000}/" >/dev/null 2>&1; then
  printf '  Chamber   %s● 正常%s\n' "$C_GRN" "$C_RESET"
elif curl -fsS -m 3 http://127.0.0.1:3000/ >/dev/null 2>&1; then
  printf '  Chamber   %s● 正常%s\n' "$C_GRN" "$C_RESET"
else
  printf '  Chamber   %s● 不可达%s\n' "$C_RED" "$C_RESET"
fi

# ---------- 用量 ----------
if [[ -f "$INSTALL_DIR/.env.runtime" ]]; then
  KEY="$(grep -E '^SUB2API_API_KEY=' "$INSTALL_DIR/.env.runtime" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -n "${KEY:-}" && "$KEY" != sk-在Sub2API* ]]; then
    hdr "密钥"
    printf '  前缀      %s...\n' "${KEY:0:12}"
    N="$(curl -sS -m 10 http://127.0.0.1:8080/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null | grep -o '"id"' | wc -l)"
    if [[ "${N:-0}" -gt 0 ]]; then
      printf '  可见模型  %s%s 个%s\n' "$C_GRN" "$N" "$C_RESET"
    else
      printf '  可见模型  %s0（密钥可能失效）%s\n' "$C_RED" "$C_RESET"
    fi
  fi
fi

# ---------- 证书 ----------
if [[ -f /etc/caddy/Caddyfile ]]; then
  hdr "反向代理"
  grep -oE '^[a-z0-9.-]+\.[a-z]{2,} \{' /etc/caddy/Caddyfile 2>/dev/null | sed 's/ {$//; s/^/  域名      /'
  if systemctl is-active --quiet caddy 2>/dev/null; then
    printf '  Caddy     %s● 运行中%s\n' "$C_GRN" "$C_RESET"
  else
    printf '  Caddy     %s● 未运行%s\n' "$C_RED" "$C_RESET"
  fi
fi

printf '\n'
