#!/usr/bin/env bash
# =============================================================================
# bootstrap-sub2api.sh — 首次启动后自动完成 Sub2API 后台配置
#
# 做四件事（网页上要手动点十几下的那些）：
#   1. 接受管理员合规确认
#   2. 创建 OpenAI 分组
#   3. 创建上游账号并归属分组
#   4. 创建 API Key 并写入 .env.runtime
#
# 用法：
#   sudo ./scripts/bootstrap-sub2api.sh \
#       --upstream-url https://api.deepseek.com \
#       --upstream-key sk-上游key \
#       --model deepseek/deepseek-v4.1-flash
#
# 可选：
#   --group-name oc-stack        分组名
#   --key-name oc-stack          密钥名
#   --balance 100                给管理员充的余额（默认 100，0 表示跳过）
#   --platform openai            必须和上游类型匹配
# =============================================================================
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/oc-stack}"
GATEWAY="http://127.0.0.1:8080"

UPSTREAM_URL=""
UPSTREAM_KEY=""
MODEL="deepseek/deepseek-v4.1-flash"
GROUP_NAME="oc-stack"
KEY_NAME="oc-stack"
BALANCE="100"
PLATFORM="openai"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_CYA=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_DIM=""
fi
info() { printf '%s==>%s %s\n' "$C_CYA" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '%s ERR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-url)  UPSTREAM_URL="${2:-}"; shift 2 ;;
    --upstream-key)  UPSTREAM_KEY="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --group-name)    GROUP_NAME="${2:-}"; shift 2 ;;
    --key-name)      KEY_NAME="${2:-}"; shift 2 ;;
    --balance)       BALANCE="${2:-}"; shift 2 ;;
    --platform)      PLATFORM="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "需要 root"

# ---- 前置 -------------------------------------------------------------------
envget() {
  local f="$1" k="$2"
  grep -E "^${k}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^["'\'']//; s/["'\'']$//'
}

ADMIN_EMAIL="$(envget "$INSTALL_DIR/.env" ADMIN_EMAIL)"
ADMIN_PASSWORD="$(envget "$INSTALL_DIR/.env" ADMIN_PASSWORD)"
[[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" ]] || die "读不到管理员账号，检查 $INSTALL_DIR/.env"

# 校验管理员密码规则（实测 Sub2API 要求 >= 8 位）
if (( ${#ADMIN_PASSWORD} < 8 )); then
  die "ADMIN_PASSWORD 少于 8 位，Sub2API 会拒绝启动。请修改 $INSTALL_DIR/.env 后重建容器"
fi

curl -fsS -m 5 "$GATEWAY/health" >/dev/null 2>&1 || die "网关未就绪：$GATEWAY/health"

# ---- 登录 -------------------------------------------------------------------
info "登录管理员账号"
LOGIN="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"
TOKEN="$(echo "$LOGIN" | jq -r '.data.access_token // empty' 2>/dev/null)"
[[ -n "$TOKEN" ]] || die "登录失败：$(echo "$LOGIN" | head -c 200)"
ok "已登录 $ADMIN_EMAIL"

AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')

# ---- 1. 合规确认 ------------------------------------------------------------
# 实测坑：不传 language 时按英文校验，中文短语会被拒
info "接受管理员合规确认"
ACK="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/admin/compliance/accept" "${AUTH[@]}" \
  -d '{"phrase":"我已阅读、理解并同意 Sub2API 部署与运营合规承诺","language":"zh"}')"
if echo "$ACK" | jq -e '.code == 0' >/dev/null 2>&1; then
  ok "合规确认已记录"
elif echo "$ACK" | grep -q "ADMIN_COMPLIANCE_INVALID_PHRASE"; then
  # 回退到英文短语
  ACK2="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/admin/compliance/accept" "${AUTH[@]}" \
    -d '{"phrase":"I have read, understood, and agree to the Sub2API Deployment and Operation Compliance Commitment","language":"en"}')"
  echo "$ACK2" | jq -e '.code == 0' >/dev/null 2>&1 && ok "合规确认已记录（英文）" \
    || die "合规确认失败：$(echo "$ACK2" | head -c 200)"
else
  warn "合规接口返回：$(echo "$ACK" | head -c 150)（可能已确认过，继续）"
fi

# ---- 2. 分组 ----------------------------------------------------------------
info "检查分组 $GROUP_NAME"
GRP_JSON="$(curl -sS -m 20 "$GATEWAY/api/v1/admin/groups?page=1&page_size=200" "${AUTH[@]}")"
# 两个 bash 陷阱，都会导致脚本"跑到一半静默退出"：
#   1) 变量名不要用 GROUPS —— 它是 bash 的特殊数组变量，赋值会被静默丢弃，取出来是数字 0
#   2) 不要写 `jq ... | head -1` —— pipefail 下 head 提前退出会让 jq 收到 SIGPIPE
GID="$(echo "$GRP_JSON" | jq -r --arg n "$GROUP_NAME" \
  '[.data.items[]? | select(.name==$n) | .id] | first // empty' 2>/dev/null)"

if [[ -n "$GID" ]]; then
  ok "分组已存在（id=$GID）"
  GP="$(echo "$GRP_JSON" | jq -r --arg n "$GROUP_NAME" \
    '[.data.items[]? | select(.name==$n) | .platform] | first // empty' 2>/dev/null)"
  [[ "$GP" == "$PLATFORM" ]] || die "分组 $GROUP_NAME 的平台是 $GP，与 --platform $PLATFORM 不一致（平台建后不可改，请换分组名）"
else
  info "创建分组 $GROUP_NAME（平台 $PLATFORM）"
  GR="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/admin/groups" "${AUTH[@]}" \
    -d "$(jq -nc --arg n "$GROUP_NAME" --arg p "$PLATFORM" \
      '{name:$n,description:"oc-stack 自动创建",platform:$p,rate_multiplier:1,subscription_type:"standard"}')")"
  GID="$(echo "$GR" | jq -r '.data.id // empty' 2>/dev/null)"
  [[ -n "$GID" ]] || die "创建分组失败：$(echo "$GR" | head -c 250)"
  ok "分组已创建（id=$GID）"
fi

# ---- 3. 上游账号 ------------------------------------------------------------
if [[ -n "$UPSTREAM_URL" && -n "$UPSTREAM_KEY" ]]; then
  info "检查上游账号"
  ACC_JSON="$(curl -sS -m 20 "$GATEWAY/api/v1/admin/accounts?page=1&page_size=100" "${AUTH[@]}" 2>/dev/null || echo '{}')"
  EXIST="$(echo "$ACC_JSON" | jq -r --arg u "$UPSTREAM_URL" \
    '[.data.items[]? | select(.credentials.base_url==$u) | .id] | first // empty' 2>/dev/null)"

  if [[ -n "$EXIST" ]]; then
    ok "上游账号已存在（id=$EXIST）"
    AID="$EXIST"
    # 关键：已有账号可能不属于本次的分组，必须并进去，否则密钥查不到模型
    CUR_GROUPS="$(echo "$ACC_JSON" | jq -r --argjson a "$AID" \
      '[(.data.items[]? | select(.id==$a) | .group_ids[]?)] | flatten | map(tostring) | join(",")' 2>/dev/null || echo "")"
    if echo ",${CUR_GROUPS:-}," | grep -q ",${GID},"; then
      ok "账号已归属分组 $GID"
    else
      info "把账号并入分组 $GID（原有：${CUR_GROUPS:-无}）"
      NEW_GROUPS="$(printf '%s\n' "${CUR_GROUPS:-}" "$GID" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
      UG="$(curl -sS -m 30 -X PUT "$GATEWAY/api/v1/admin/accounts/$AID" "${AUTH[@]}" \
        -d "$(jq -nc --argjson ids "[$(echo "$NEW_GROUPS" | sed 's/,/,/g')]" '{group_ids:$ids}')" 2>&1 || true)"
      if echo "$UG" | jq -e '.code == 0' >/dev/null 2>&1; then
        ok "已并入分组"
      else
        warn "并入分组失败：$(echo "$UG" | head -c 200)"
        warn "请到后台手动把账号 id=$AID 勾选到分组 $GROUP_NAME"
      fi
    fi
  else
    info "创建上游账号 → $UPSTREAM_URL"
    BODY="$(jq -nc \
      --arg name "upstream-$PLATFORM" \
      --arg p "$PLATFORM" \
      --arg k "$UPSTREAM_KEY" \
      --arg u "$UPSTREAM_URL" \
      --arg m "$MODEL" \
      --argjson gid "$GID" \
      '{name:$name,platform:$p,type:"apikey",
        credentials:{api_key:$k,base_url:$u,model_mapping:{($m):$m}},
        extra:{},group_ids:[$gid],concurrency:5,priority:1}')"
    AR="$(curl -sS -m 30 -X POST "$GATEWAY/api/v1/admin/accounts" "${AUTH[@]}" \
      -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" -d "$BODY")"
    AID="$(echo "$AR" | jq -r '.data.id // empty' 2>/dev/null)"
    [[ -n "$AID" ]] || die "创建上游账号失败：$(echo "$AR" | head -c 300)"
    ok "上游账号已创建（id=$AID）"
  fi

  info "测试上游连通性（这一步会真实调用一次上游）"
  TEST="$(curl -sS -m 90 -X POST "$GATEWAY/api/v1/admin/accounts/$AID/test" "${AUTH[@]}" \
    -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" \
    -d "$(jq -nc --arg m "$MODEL" '{model_id:$m}')" 2>&1 || true)"
  if echo "$TEST" | grep -q '"type":"test_complete"\|"success":true'; then
    ok "上游连通"
  elif echo "$TEST" | grep -qi "error"; then
    warn "上游测试未通过：$(echo "$TEST" | grep -o '"error":"[^"]*"' | head -1 | cut -c1-200)"
    warn "常见原因：上游 base_url 少了 /v1、key 无效、或 model 名字写错"
  else
    warn "上游测试返回：$(echo "$TEST" | head -c 150)"
  fi
else
  warn "未提供 --upstream-url/--upstream-key，跳过上游账号创建"
  warn "请到 $GATEWAY 后台手动添加账号并归属分组 $GROUP_NAME"
fi

# ---- 4. 余额 ----------------------------------------------------------------
# 实测坑：余额为 0 时所有请求返回 INSUFFICIENT_BALANCE
if [[ "$BALANCE" != "0" ]]; then
  info "设置管理员余额为 $BALANCE（否则所有请求会被余额拦截）"
  BAL="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/admin/users/1/balance" "${AUTH[@]}" \
    -d "$(jq -nc --argjson b "$BALANCE" '{balance:$b,operation:"add",remark:"oc-stack 初始化"}')")"
  if echo "$BAL" | jq -e '.code == 0' >/dev/null 2>&1; then
    ok "余额已设置"
  else
    warn "设置余额失败：$(echo "$BAL" | head -c 200)"
    warn "请到后台 用户管理 → 编辑 → 余额 手动设置"
  fi
fi

# ---- 5. API Key -------------------------------------------------------------
info "检查 API Key $KEY_NAME"
KEY_JSON="$(curl -sS -m 20 "$GATEWAY/api/v1/keys?page=1&page_size=200" "${AUTH[@]}" 2>/dev/null || echo '{}')"
# 注意：/api/v1/keys 返回的是 {data:{items:[]}}，不是 {data:[]}
EXIST_KEY="$(echo "$KEY_JSON" | jq -r --arg n "$KEY_NAME" \
  '[(.data.items // .data)[]? | select(.name==$n) | .key] | first // empty' 2>/dev/null)"

if [[ -n "$EXIST_KEY" && "$EXIST_KEY" != "null" ]]; then
  ok "密钥已存在"
  SK="$EXIST_KEY"
else
  info "创建 API Key（绑定分组 $GID）"
  KR="$(curl -sS -m 20 -X POST "$GATEWAY/api/v1/keys" "${AUTH[@]}" \
    -d "$(jq -nc --arg n "$KEY_NAME" --argjson gid "$GID" '{name:$n,group_id:$gid}')")"
  SK="$(echo "$KR" | jq -r '.data.key // empty' 2>/dev/null)"
  [[ -n "$SK" ]] || die "创建密钥失败：$(echo "$KR" | head -c 250)"
  ok "密钥已创建"
fi

# ---- 6. 写入 .env.runtime ---------------------------------------------------
ENVF="$INSTALL_DIR/.env.runtime"
[[ -f "$ENVF" ]] || { touch "$ENVF"; }
chmod 600 "$ENVF"
if grep -qE '^SUB2API_API_KEY=' "$ENVF"; then
  sed -i "s|^SUB2API_API_KEY=.*|SUB2API_API_KEY=${SK}|" "$ENVF"
else
  printf 'SUB2API_API_KEY=%s\n' "$SK" >> "$ENVF"
fi
ok "密钥已写入 $ENVF"

# ---- 7. 端到端自测 ---------------------------------------------------------
info "端到端自测"
MODELS="$(curl -sS -m 20 "$GATEWAY/v1/models" -H "Authorization: Bearer $SK")"
if echo "$MODELS" | grep -q '"id"'; then
  N="$(echo "$MODELS" | grep -o '"id"' | wc -l)"
  ok "GET /v1/models 返回 $N 个模型"
else
  die "GET /v1/models 失败：$(echo "$MODELS" | head -c 250)"
fi

CHAT="$(curl -sS -m 90 "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $SK" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg m "$MODEL" '{model:$m,messages:[{role:"user",content:"只回两个字：收到"}],max_tokens:100}')")"
if echo "$CHAT" | grep -q '"content"'; then
  ok "对话成功：$(echo "$CHAT" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 60)"
else
  die "对话失败：$(echo "$CHAT" | head -c 300)"
fi

printf '\n%s%s初始化完成%s\n\n' "$C_B" "$C_GRN" "$C_RESET"
printf '  API Key   %s\n' "${SK:0:16}..."
printf '  分组      %s (id=%s)\n' "$GROUP_NAME" "$GID"
printf '  模型      %s\n' "$MODEL"
printf '\n  下一步：sudo systemctl restart openchamber\n'
printf '  然后访问 OpenChamber 网页，选模型 sub2api/deepseek-v4.1-flash\n\n'
