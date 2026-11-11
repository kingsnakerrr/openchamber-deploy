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
# 只改目录本身，不递归（递归遇到大项目会卡很久）
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
        sudo chown "$(id -u):$(id -g)" "$d" 2>/dev/null || \
          log "警告：无法修正 $d 的权限，请在宿主机执行 chown 1000:1000 $d"
      else
        log "警告：$d 不可写且没有 sudo，挂载目录需要在宿主机 chown 1000:1000"
      fi
    fi
  done
}

fix_perm
mkdir -p "$CFG_DIR"

# ---- 生成 provider 配置 -----------------------------------------------------
# 只在配置文件不存在时生成，避免覆盖用户在界面上改过的设置。
# 用 Python 的 json.dump 生成，避免模型名 / URL 里的引号反斜杠破坏 JSON。
if [[ ! -f "$CFG" ]]; then
  BASE_URL="${SUB2API_BASE_URL:-http://sub2api:8080/v1}"
  MODEL_ID="${SUB2API_MODEL:-deepseek/deepseek-v4.1-flash}"
  MODEL_ALIAS="${SUB2API_MODEL_ALIAS:-deepseek-v4.1-flash}"
  MODEL_NAME="${SUB2API_MODEL_NAME:-DeepSeek V4.1 Flash}"
  MODEL_CONTEXT="${SUB2API_CONTEXT:-1000000}"
  MODEL_MAX_OUTPUT="${SUB2API_MAX_OUTPUT:-384000}"

  log "生成 provider 配置：$BASE_URL / $MODEL_ID"

  if python3 - "$CFG" "$BASE_URL" "$MODEL_ID" "$MODEL_ALIAS" "$MODEL_NAME" \
        "$MODEL_CONTEXT" "$MODEL_MAX_OUTPUT" <<'PY' 2>/dev/null
import json, sys

cfg_path, base_url, model_id, alias, name, ctx, max_out = sys.argv[1:8]

cfg = {
    "$schema": "https://opencode.ai/config.json",
    "model": f"sub2api/{alias}",
    "providers": {
        "sub2api": {
            "name": "Sub2API",
            "env": ["SUB2API_API_KEY"],
            "package": "@opencode/ai/providers/openai-compatible",
            "settings": {
                "baseURL": base_url,
                "headerTimeout": 300000,
                "chunkTimeout": 900000,
            },
            "models": {
                alias: {
                    "modelID": model_id,
                    "name": name,
                    "family": "deepseek-flash",
                    "capabilities": {
                        "tools": True,
                        "input": ["text", "image"],
                        "output": ["text"],
                        "temperature": True,
                        "reasoning": {
                            "supported": True,
                            "effort": ["low", "high", "max"],
                        },
                    },
                    "limit": {
                        "context": int(ctx),
                        "output": int(max_out),
                    },
                    "compatibility": {
                        "reasoningField": "reasoning_content",
                        "maxTokensField": "max_completion_tokens",
                    },
                }
            },
        }
    },
}

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  then
    # 生成后再校验一次，坏配置宁可报错也别让 OpenCode 起不来
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
      log "配置已生成：$CFG"
    else
      log "错误：生成的配置不是合法 JSON，请检查 SUB2API_* 环境变量"
      mv "$CFG" "$CFG.broken" 2>/dev/null || true
    fi
  else
    log "错误：无法写入 $CFG"
    log "请在宿主机执行：sudo chown 1000:1000 ./data/opencode/config"
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
