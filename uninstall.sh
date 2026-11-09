#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — 卸载
#
#   sudo ./uninstall.sh              # 卸载服务，保留 /opt/oc-stack 里的数据
#   sudo ./uninstall.sh --purge      # 连数据一起删（不可恢复）
# =============================================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/oc-stack}"
PURGE="false"

for a in "$@"; do
  case "$a" in
    --purge) PURGE="true" ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数：$a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }

echo "==> 停止服务"
systemctl stop openchamber 2>/dev/null || true
systemctl disable openchamber 2>/dev/null || true
rm -f /etc/systemd/system/openchamber.service
systemctl daemon-reload

if [[ -f "$INSTALL_DIR/sub2api/docker-compose.yml" ]]; then
  echo "==> 停止容器"
  ( cd "$INSTALL_DIR/sub2api" && docker compose --env-file "$INSTALL_DIR/.env" down ) 2>/dev/null || true
fi

if [[ "$PURGE" == "true" ]]; then
  echo "==> 删除数据目录（不可恢复）"
  read -r -p "确认删除 $INSTALL_DIR 及全部数据库？输入 DELETE 继续: " ans
  if [[ "$ans" == "DELETE" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "已删除 $INSTALL_DIR"
    echo
    echo "以下内容未删除，如需清理请手动处理："
    echo "  - Docker 镜像 weishaw/sub2api / postgres / redis"
    echo "  - ~/.config/opencode/opencode.json"
    echo "  - /etc/caddy/Caddyfile 与 caddy 服务"
    echo "  - npm 全局包 @openchamber/web"
  else
    echo "已取消"
  fi
else
  echo "==> 服务已移除，数据保留在 $INSTALL_DIR"
  echo "    如需彻底删除：sudo ./uninstall.sh --purge"
fi
