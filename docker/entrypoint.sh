#!/bin/bash
# =============================================================================
# OpenChamber 容器入口
#
# 首次启动时自动生成 opencode.json provider 配置。
#
# 关于权限：compose 把宿主目录挂进容器，宿主目录通常是 root:root，
# 而容器内以 UID 1000 运行，直接写会 Permission denied。
# 这里用 sudo（镜像内已授权）修正一次挂载点所有权，之后就一直正常。
# =============================================================================
set -euo pipefail

CFG_DIR="${HOME}/.config/opencode"
CFG="${CFG_DIR}/opencode.json"

log() { echo "[oc-entrypoint] $*"; }

# ---- 修正挂载点所有权 -------------------------------------------------------
# 只在不可写时才动，避免每次启动都 chown
fix_perm() {
  local d
  for d in \
    "${HOME}/.config/opencode" \
    "${HOME}/.config/openchamber" \
    "${HOME}/.local/share/opencode" \
    "${HOME}/.local/state/opencode" \
    /workspace; do
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || continue
    if [[ ! -w "$d" ]]; then
      if command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$(id -u):$(id -g)" "$d" 2>/dev/null || \
          log "警告：无法修正 $d 的权限，请在宿主机执行 chown -R 1000:1000"
      else
        log "警告：$d 不可写且没有 sudo，挂载目录需要在宿主机 chown 1000:1000"
      fi
    fi
  done
}

fix_perm
mkdir -p "$CFG_DIR"

# ---- 生成 provider 配置 -----------------------------------------------------
# 只在配置文件不存在时生成，避免覆盖用户在界面上改过的设置
if [[ ! -f "$CFG" ]]; then
  BASE_URL="${SUB2API_BASE_URL:-http://sub2api:8080/v1}"
  MODEL_ID="${SUB2API_MODEL:-deepseek/deepseek-v4.1-flash}"
  MODEL_ALIAS="${SUB2API_MODEL_ALIAS:-deepseek-v4.1-flash}"
  MODEL_NAME="${SUB2API_MODEL_NAME:-DeepSeek V4.1 Flash}"

  log "生成 provider 配置：$BASE_URL / $MODEL_ID"

  if cat > "$CFG" <<JSON 2>/dev/null
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "sub2api/${MODEL_ALIAS}",
  "providers": {
    "sub2api": {
      "name": "Sub2API",
      "env": ["SUB2API_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "${BASE_URL}",
        "headerTimeout": 300000,
        "chunkTimeout": 900000
      },
      "models": {
        "${MODEL_ALIAS}": {
          "modelID": "${MODEL_ID}",
          "name": "${MODEL_NAME}",
          "family": "deepseek-flash",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"],
            "temperature": true,
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
  then
    log "配置已生成：$CFG"
  else
    log "错误：无法写入 $CFG"
    log "请在宿主机执行：sudo chown -R 1000:1000 ./data"
  fi
else
  log "已存在配置，跳过生成：$CFG"
fi

# ---- 提交前的安全检查 -------------------------------------------------------
if [[ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]]; then
  log "警告：未设置 OPENCHAMBER_UI_PASSWORD，任何能访问 3000 端口的人都可执行任意命令"
fi

log "启动 OpenChamber $(openchamber --version 2>/dev/null || echo '?') / OpenCode $(opencode --version 2>/dev/null || echo '?')"

exec openchamber serve --foreground --port 3000 --host 0.0.0.0
