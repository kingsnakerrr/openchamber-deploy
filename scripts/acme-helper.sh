#!/usr/bin/env bash
# =============================================================================
# ACME 证书管理（acme.sh）
#
# 用于 80/443 已被其他服务占用、Caddy 无法自己申请证书的场景。
#
# 思路：用 acme.sh 的 standalone 模式在最前面抢一次 80 端口完成校验，
# 签好的证书交给 Caddy 使用（tls /path/cert.pem /path/key.pem）。
# 续期同样由 acme.sh 的 cron 完成，续期时短暂占用 80。
#
# 用法：
#   acme-helper.sh issue <域名> [邮箱]
#   acme-helper.sh status <域名>
#   acme-helper.sh renew
# =============================================================================

set -Eeuo pipefail

ACME_HOME="${ACME_HOME:-/opt/acme.sh}"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_ROOT="${CERT_ROOT:-/etc/oc-certs}"

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

# ---------------------------------------------------------------------------
# 安装 acme.sh（幂等）
# ---------------------------------------------------------------------------
ensure_acme() {
  if [[ -x "$ACME_BIN" ]]; then
    ok "acme.sh 已安装（$("$ACME_BIN" --version 2>/dev/null | head -1)）"
    return 0
  fi

  info "安装 acme.sh 到 $ACME_HOME"
  mkdir -p "$ACME_HOME"

  # 直接取 acme.sh 单文件脚本，避免 get.acme.sh 的参数拼接问题
  local ok_dl="false"
  for url in \
    "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
    "https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh"; do
    if curl -fsSL "$url" -o "$ACME_BIN" 2>/dev/null; then
      ok_dl="true"; break
    fi
  done

  if [[ "$ok_dl" != "true" ]]; then
    warn "无法下载 acme.sh，尝试 git clone"
    if command -v git >/dev/null 2>&1; then
      rm -rf /tmp/acme-src
      if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /tmp/acme-src >/dev/null 2>&1; then
        cp /tmp/acme-src/acme.sh "$ACME_BIN"
        mkdir -p "$ACME_HOME/dnsapi" "$ACME_HOME/deploy"
        cp -r /tmp/acme-src/dnsapi/. "$ACME_HOME/dnsapi/" 2>/dev/null || true
        cp -r /tmp/acme-src/deploy/. "$ACME_HOME/deploy/" 2>/dev/null || true
        rm -rf /tmp/acme-src
        ok_dl="true"
      fi
    fi
  fi

  [[ "$ok_dl" == "true" ]] || die "无法获取 acme.sh（网络问题？）"
  chmod +x "$ACME_BIN"
  [[ -x "$ACME_BIN" ]] || die "acme.sh 安装失败"
  ok "acme.sh 已安装：$("$ACME_BIN" --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# 临时让出 / 抢回 80 端口
#
# acme.sh standalone 需要独占 80。如果 nginx 占着，先停掉，
# 签完再启动。失败时也要保证 nginx 被拉起来，否则整台机器的网站全挂。
# ---------------------------------------------------------------------------
PORT80_HOLDER=""

release_port80() {
  command -v ss >/dev/null 2>&1 || return 0
  local pids
  pids="$(ss -tlnp 2>/dev/null | awk '/:80 /{print}' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | tr '\n' ' ')"
  [[ -z "$pids" ]] && return 0

  for pid in $pids; do
    local svc
    svc="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [[ -z "$svc" ]] && continue
    # 只处理已知的 web 服务，避免误停别的东西
    if [[ "$svc" =~ ^(nginx|apache2|httpd|caddy)$ ]]; then
      PORT80_HOLDER="$svc"
      # 记录原本的自启状态，恢复时还原（绝不能擅自 disable）
      if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo "$svc" > /etc/oc-certs/.was-enabled
      fi
      info "临时停止 $svc 以让出 80 端口（签完自动恢复）"
      systemctl stop "$svc" >/dev/null 2>&1 || true
      # nginx 编译版可能没有 systemd 单元名匹配，兜底用 pkill
      if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
        pkill -x "$svc" 2>/dev/null || true
      fi
    fi
  done

  sleep 1
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
    local who
    who="$(ss -tlnp 2>/dev/null | grep -E ':80 ' | grep -o 'users:(("[^"]*"' | head -1)"
    die "80 端口仍被占用：${who:-未知进程}。请手动停掉后重试"
  fi
  ok "80 端口已释放"
}

restore_port80() {
  [[ -z "$PORT80_HOLDER" ]] && return 0
  info "恢复 $PORT80_HOLDER"

  # 如果它原本是开机自启的，一定要重新 enable 回来
  if [[ -f /etc/oc-certs/.was-enabled ]] && grep -qx "$PORT80_HOLDER" /etc/oc-certs/.was-enabled 2>/dev/null; then
    systemctl enable "$PORT80_HOLDER" >/dev/null 2>&1 || true
    rm -f /etc/oc-certs/.was-enabled
  fi

  systemctl start "$PORT80_HOLDER" >/dev/null 2>&1 || true
  sleep 1
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
    ok "$PORT80_HOLDER 已恢复（$(systemctl is-enabled "$PORT80_HOLDER" 2>/dev/null || echo unknown)）"
  else
    warn "$PORT80_HOLDER 未能自动恢复，请手动：systemctl start $PORT80_HOLDER"
  fi
  PORT80_HOLDER=""
}

# ---------------------------------------------------------------------------
# 签发
# ---------------------------------------------------------------------------
do_issue() {
  local domain="$1" email="${2:-}"

  [[ -n "$domain" ]] || die "缺少域名"

  ensure_acme

  # 默认用 Let's Encrypt；指定邮箱则注册（更利于到期通知）
  if [[ -n "$email" ]]; then
    "$ACME_BIN" --register-account -m "$email" --server letsencrypt >/dev/null 2>&1 || true
  fi
  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  local out="$CERT_ROOT/$domain"
  mkdir -p "$out"

  local need_issue="true"
  if [[ -f "$out/fullchain.pem" ]]; then
    # 已有证书且剩余 >30 天就不重签，避免触发 Let's Encrypt 频率限制
    if openssl x509 -checkend $((30*86400)) -noout -in "$out/fullchain.pem" 2>/dev/null; then
      need_issue="false"
      ok "证书仍有效，跳过签发（$out）"
    fi
  fi

  if [[ "$need_issue" == "true" ]]; then
    release_port80

    # 无论如何都要把 80 还回去：失败、中断、被 kill 都要恢复，
    # 否则机器上原有的 nginx 站点会全部挂掉。
    trap 'restore_port80' EXIT INT TERM

    local issued="false"
    info "为 $domain 申请证书（standalone，临时占用 80 端口）"
    if "$ACME_BIN" --issue -d "$domain" --standalone --keylength ec-256 \
         --server letsencrypt >/tmp/acme-issue.log 2>&1; then
      issued="true"
    else
      tail -15 /tmp/acme-issue.log
      restore_port80
      trap - EXIT INT TERM
      die "证书申请失败，见上方 acme.sh 输出（完整日志 /tmp/acme-issue.log）"
    fi

    if [[ "$issued" == "true" ]]; then
      info "安装证书到 $out"
      mkdir -p "$CERT_ROOT"
      # 续期时也要让出 80：acme.sh 有一套 hook 机制
      local pre_hook="/etc/oc-certs/pre-hook.sh"
      local post_hook="/etc/oc-certs/post-hook.sh"
      cat > "$pre_hook" <<'EOS'
#!/bin/sh
# 续期前让出 80 端口（nginx 等），记下被停的服务
for svc in nginx apache2 httpd; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "$svc" > /etc/oc-certs/.stopped-svc
    systemctl stop "$svc" 2>/dev/null || true
  fi
done
sleep 1
EOS
      cat > "$post_hook" <<'EOS'
#!/bin/sh
# 续期后恢复 80 端口
if [ -f /etc/oc-certs/.stopped-svc ]; then
  while read -r svc; do
    [ -n "$svc" ] && systemctl start "$svc" 2>/dev/null || true
  done < /etc/oc-certs/.stopped-svc
  rm -f /etc/oc-certs/.stopped-svc
fi
docker exec oc-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
EOS
      chmod +x "$pre_hook" "$post_hook"

      if ! "$ACME_BIN" --install-cert -d "$domain" --ecc \
           --key-file       "$out/key.pem" \
           --fullchain-file "$out/fullchain.pem" \
           --reloadcmd      "docker exec oc-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true" \
           >/dev/null 2>&1; then
        restore_port80
        trap - EXIT INT TERM
        die "证书安装失败"
      fi
    fi

    restore_port80
    trap - EXIT INT TERM
  fi

  [[ -f "$out/fullchain.pem" ]] || die "证书文件不存在：$out/fullchain.pem"
  chmod 644 "$out/fullchain.pem"
  chmod 600 "$out/key.pem"

  # 续期钩子：续期后重载 Caddy
  local hook="/etc/oc-certs/reload-caddy.sh"
  cat > "$hook" <<'EOS'
#!/bin/sh
docker exec oc-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
EOS
  chmod +x "$hook"

  # acme.sh 自带 cron，这里确保它指向正确的 home
  local cron_line="17 3 * * * $ACME_HOME/acme.sh --cron --home $ACME_HOME --pre-hook /etc/oc-certs/pre-hook.sh --post-hook /etc/oc-certs/post-hook.sh > /tmp/acme-cron.log 2>&1"
  if ! crontab -l 2>/dev/null | grep -q "$ACME_HOME/acme.sh --cron"; then
    ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab - 2>/dev/null || \
      warn "无法写入 cron，续期需手动：$ACME_BIN --cron"
  fi

  ok "证书就绪：$out"
  ok "续期：acme.sh 每天 03:17 自动检查，到期前 30 天续期"
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
do_status() {
  local domain="${1:-}"
  if [[ -n "$domain" && -f "$CERT_ROOT/$domain/fullchain.pem" ]]; then
    printf '%s%s%s\n' "$B" "$domain" "$R"
    openssl x509 -in "$CERT_ROOT/$domain/fullchain.pem" -noout \
      -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
  else
    local found=0
    for d in "$CERT_ROOT"/*/; do
      [[ -f "$d/fullchain.pem" ]] || continue
      found=1
      printf '%s%s%s\n' "$B" "$(basename "$d")" "$R"
      openssl x509 -in "$d/fullchain.pem" -noout -subject -dates 2>/dev/null | sed 's/^/  /'
    done
    (( found == 0 )) && warn "还没有签发任何证书（$CERT_ROOT）"
  fi
  echo
  [[ -x "$ACME_BIN" ]] && info "acme.sh：$("$ACME_BIN" --version 2>/dev/null | head -1)"
  crontab -l 2>/dev/null | grep -q acme.sh && info "自动续期：已配置 cron" || warn "自动续期：未配置"
}

case "${1:-}" in
  issue)  do_issue "${2:-}" "${3:-}" ;;
  status) do_status "${2:-}" ;;
  renew)  ensure_acme; "$ACME_BIN" --cron --home "$ACME_HOME" ;;
  *)      die "用法：$0 issue <域名> [邮箱] | status [域名] | renew" ;;
esac
