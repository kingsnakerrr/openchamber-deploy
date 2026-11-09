#!/usr/bin/env bash
# =============================================================================
# verify.sh — 逐层验证整条链路
#
# 用 sudo 运行，会依次检查：
#   1. 服务与容器状态
#   2. Sub2API 网关可达
#   3. API Key 有效且模型可见
#   4. OpenCode 配置正确
#   5. 真实对话
#   6. 工具调用（最关键）
# =============================================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/oc-stack}"
ENV_RUNTIME="$INSTALL_DIR/.env.runtime"
ENV_SUB2API="$INSTALL_DIR/.env"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

PASS=0; FAIL=0; SKIP=0
pass() { printf '%s  PASS%s %s\n' "$C_GRN" "$C_RESET" "$*"; PASS=$((PASS+1)); }
fail() { printf '%s  FAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; FAIL=$((FAIL+1)); }
skip() { printf '%s  SKIP%s %s\n' "$C_YEL" "$C_RESET" "$*"; SKIP=$((SKIP+1)); }
item() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_RESET"; }

# 从 env 文件读某个键
envget() {
  local f="$1" k="$2"
  [[ -f "$f" ]] || { echo ""; return; }
  grep -E "^${k}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^["'\'']//; s/["'\'']$//'
}

# ---- 1. 服务状态 ------------------------------------------------------------
item "1. 服务状态"

if command -v openchamber >/dev/null 2>&1; then
  pass "openchamber 已安装 $(openchamber --version 2>/dev/null)"
else
  fail "openchamber 未安装"
fi

if command -v opencode >/dev/null 2>&1 || [[ -x /root/.opencode/bin/opencode ]]; then
  OC_BIN="$(command -v opencode 2>/dev/null || echo /root/.opencode/bin/opencode)"
  pass "opencode 已安装 $("$OC_BIN" --version 2>/dev/null)"
else
  fail "opencode 未安装"
  OC_BIN=""
fi

if systemctl is-active --quiet openchamber 2>/dev/null; then
  pass "openchamber 服务运行中"
else
  fail "openchamber 服务未运行（journalctl -u openchamber -n 50）"
fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sub2api; then
    local_health="$(docker inspect -f '{{.State.Health.Status}}' sub2api 2>/dev/null || echo unknown)"
    if [[ "$local_health" == "healthy" ]]; then
      pass "sub2api 容器 healthy"
    else
      fail "sub2api 容器状态：$local_health"
    fi
    # 确认没暴露端口
    ports="$(docker port sub2api 2>/dev/null || true)"
    if echo "$ports" | grep -q '0.0.0.0:8080'; then
      fail "sub2api 端口绑定到 0.0.0.0，应只绑 127.0.0.1"
    else
      pass "sub2api 端口未暴露到公网"
    fi
  else
    skip "sub2api 容器未运行（可能是 --skip-sub2api 安装）"
  fi
fi

# ---- 2. 网关可达 ------------------------------------------------------------
item "2. Sub2API 网关"

GATEWAY="http://127.0.0.1:8080"
if curl -fsS -m 5 "$GATEWAY/health" >/dev/null 2>&1; then
  pass "网关健康检查通过 $GATEWAY/health"
else
  fail "网关不可达 $GATEWAY/health"
fi

# ---- 3. API Key -------------------------------------------------------------
item "3. API Key 与模型列表"

API_KEY="$(envget "$ENV_RUNTIME" SUB2API_API_KEY)"
if [[ -z "$API_KEY" || "$API_KEY" == sk-在Sub2API* ]]; then
  fail "SUB2API_API_KEY 尚未填写（编辑 $ENV_RUNTIME）"
  API_KEY=""
else
  pass "SUB2API_API_KEY 已配置（${API_KEY:0:8}...）"
fi

if [[ -n "$API_KEY" ]]; then
  RESP="$(curl -sS -m 20 "$GATEWAY/v1/models" -H "Authorization: Bearer $API_KEY" 2>&1)"
  # 余额为 0 时网关会返回 INSUFFICIENT_BALANCE，先单独识别，避免误报成"模型不可用"
  if echo "$RESP" | grep -q 'INSUFFICIENT_BALANCE'; then
    fail "网关余额为 0，所有请求被拦截（后台 用户管理 → 充值，或运行 bootstrap 时加 --balance 100）"
  fi
  if echo "$RESP" | grep -q '"id"'; then
    N="$(echo "$RESP" | grep -o '"id"' | wc -l)"
    pass "模型列表可读（$N 个模型）"
    if echo "$RESP" | grep -q 'deepseek-v4.1-flash'; then
      pass "找到 deepseek/deepseek-v4.1-flash"
    else
      fail "模型列表里没有 deepseek-v4.1-flash，检查分组和模型映射"
      printf '%s      可用模型：%s%s\n' "$C_DIM" "$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -8 | tr '\n' ' ')" "$C_RESET"
    fi
  else
    fail "模型列表请求失败：$(echo "$RESP" | head -c 200)"
  fi
fi

# ---- 4. OpenCode 配置 -------------------------------------------------------
item "4. OpenCode 配置"

CFG="/root/.config/opencode/opencode.json"
if [[ -f "$CFG" ]]; then
  pass "配置文件存在 $CFG"
  if grep -q '"sub2api"' "$CFG"; then
    pass "包含 sub2api provider"
  else
    fail "配置里没有 sub2api provider"
  fi
  if grep -q 'max_completion_tokens' "$CFG"; then
    pass "maxTokensField 已设为 max_completion_tokens"
  else
    fail "缺少 maxTokensField，长回答会 400"
  fi
  if grep -q 'reasoning_content' "$CFG"; then
    pass "reasoningField 已配置"
  else
    fail "缺少 reasoningField，思考块不显示"
  fi
else
  fail "配置文件不存在 $CFG"
fi

# ---- 5. 真实对话 ------------------------------------------------------------
item "5. 真实对话"

if [[ -n "$API_KEY" && -n "$OC_BIN" && -f "$CFG" ]]; then
  set -a; . "$ENV_RUNTIME" 2>/dev/null || true; set +a
  OUT="$(cd /tmp && timeout 90 "$OC_BIN" run --standalone --model sub2api/deepseek-v4.1-flash \
    "只回答两个字：收到" 2>&1 | tail -5)"
  if echo "$OUT" | grep -qE '收到|OK|好的|是的'; then
    pass "对话成功"
  elif echo "$OUT" | grep -qiE 'invalid api key|401'; then
    fail "对话 401：API Key 无效（可能是密钥过期或分组不匹配）"
  elif echo "$OUT" | grep -qiE 'model unavailable|not found'; then
    fail "对话失败：模型不可用"
  else
    fail "对话异常输出：$(echo "$OUT" | tail -3 | tr '\n' ' ' | head -c 200)"
  fi
else
  skip "缺少前置条件，跳过对话测试"
fi

# ---- 6. 工具调用 ------------------------------------------------------------
item "6. 工具调用"

if [[ -n "$API_KEY" && -n "$OC_BIN" && -f "$CFG" ]]; then
  WORK="$(mktemp -d)"
  printf 'def add(a,b):\n    return a+b\n' > "$WORK/m.py"
  OUT="$(cd "$WORK" && timeout 120 "$OC_BIN" run --standalone --auto \
    --model sub2api/deepseek-v4.1-flash \
    "读 m.py，然后运行 python3 -c 'import m;print(m.add(2,3))'，告诉我结果" 2>&1 | tail -15)"
  if echo "$OUT" | grep -q '5'; then
    pass "工具调用正常（读到 5）"
  else
    fail "工具调用失败：$(echo "$OUT" | tail -3 | tr '\n' ' ' | head -c 200)"
  fi
  rm -rf "$WORK"
else
  skip "缺少前置条件，跳过工具测试"
fi

# ---- 总结 -------------------------------------------------------------------
printf '\n%s────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
printf '  通过 %s%d%s   失败 %s%d%s   跳过 %s%d%s\n' \
  "$C_GRN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$C_YEL" "$SKIP" "$C_RESET"

if (( FAIL == 0 )); then
  printf '\n%s  全部通过，可以开始用了。%s\n\n' "$C_GRN" "$C_RESET"
  exit 0
else
  printf '\n%s  有 %d 项失败，按上面的提示逐项处理。%s\n\n' "$C_RED" "$FAIL" "$C_RESET"
  exit 1
fi
