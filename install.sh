#!/usr/bin/env bash
# =============================================================================
# oc-stack 一键安装
#
#   bash <(curl -Ls https://raw.githubusercontent.com/kingsnakerrr/openchamber-deploy/main/install.sh)
#
# 做的事：
#   1. 检查系统（Debian 12/13、Ubuntu 22.04+）
#   2. 逐个检查依赖，缺什么装什么，已装的跳过
#   3. 拉取项目到 /opt/oc-stack（已存在则更新）
#   4. 执行 ./ocstack install（只问域名，密码全部自动生成）
#
# 可重复运行：所有步骤都是幂等的。
# =============================================================================
set -Eeuo pipefail

REPO="${OCSTACK_REPO:-kingsnakerrr/openchamber-deploy}"
BRANCH="${OCSTACK_BRANCH:-main}"
INSTALL_DIR="${OCSTACK_DIR:-/opt/oc-stack}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

if [[ -t 1 ]]; then
  R=$'\033[0m'; DIM=$'\033[2m'; B=$'\033[1m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'
else
  R=""; DIM=""; B=""; RED=""; GRN=""; YEL=""; CYA=""
fi
info() { printf '%s==>%s %s\n' "$CYA" "$R" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$R" "$*"; }
skip() { printf '%s  --%s %s%s\n' "$DIM" "$R" "$*" "$R"; }
warn() { printf '%s  !!%s %s\n' "$YEL" "$R" "$*" >&2; }
die()  { printf '%s ERR%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
head1(){ printf '\n%s%s▸ %s%s\n' "$B" "$CYA" "$*" "$R"; }

trap 'die "第 ${LINENO} 行失败：${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# 0. 权限与系统
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "需要 root：sudo bash <(curl -Ls ${RAW_BASE}/install.sh)"

[[ -f /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"

case "$OS_ID" in
  debian|ubuntu) ;;
  *) die "只支持 Debian / Ubuntu，当前：${OS_ID:-未知}" ;;
esac

case "$(uname -m)" in
  x86_64|aarch64|arm64) ARCH="$(uname -m)" ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac

printf '\n%s%s oc-stack 一键安装 %s\n' "$B" "$CYA" "$R"
printf '%s Sub2API + OpenCode + OpenChamber + Caddy（全 Docker）%s\n\n' "$DIM" "$R"
ok "系统 ${PRETTY_NAME:-$OS_ID $OS_VER} (${ARCH})"

# ---------------------------------------------------------------------------
# 1. 依赖：缺什么装什么
# ---------------------------------------------------------------------------
head1 "1/4 检查依赖"

APT_UPDATED="false"
apt_refresh() {
  [[ "$APT_UPDATED" == "true" ]] && return 0
  info "apt-get update"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  APT_UPDATED="true"
}

# 需要哪些命令、由哪个包提供
need_pkg() {
  # need_pkg <命令> <包名> [检测用的额外参数]
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    skip "$cmd 已安装（$(command -v "$cmd")）"
    return 0
  fi
  info "安装 $pkg（提供 $cmd）"
  apt_refresh
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$pkg" >/dev/null
  command -v "$cmd" >/dev/null 2>&1 || die "$pkg 安装后仍找不到 $cmd"
  ok "$cmd 已就绪"
}

need_pkg curl curl
need_pkg git git
need_pkg jq jq
need_pkg openssl openssl
need_pkg tar tar
need_pkg gzip gzip

# ca-certificates 没有命令形态，单独判断
if dpkg -s ca-certificates >/dev/null 2>&1; then
  skip "ca-certificates 已安装"
else
  info "安装 ca-certificates"
  apt_refresh
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates >/dev/null
  ok "ca-certificates 已就绪"
fi

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------
head1 "2/4 检查 Docker"

docker_ready() {
  command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1
}

if docker_ready; then
  skip "Docker 已安装并运行（$(docker --version | cut -d, -f1)）"
  skip "Compose $(docker compose version --short 2>/dev/null || echo 已安装)"
else
  if ! command -v docker >/dev/null 2>&1; then
    info "安装 Docker（官方脚本）"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || die "Docker 安装失败，查看 /tmp/get-docker.sh 手动执行"
    rm -f /tmp/get-docker.sh
    ok "Docker $(docker --version | cut -d, -f1)"
  else
    skip "Docker 二进制已存在（$(docker --version | cut -d, -f1)）"
  fi

  # 守护进程没跑就拉起来
  if ! docker info >/dev/null 2>&1; then
    info "启动 Docker 服务"
    systemctl enable --now docker >/dev/null 2>&1 || true
    sleep 3
    docker info >/dev/null 2>&1 || die "Docker 守护进程无法启动：systemctl status docker"
    ok "Docker 服务已启动"
  fi

  # compose 插件
  if ! docker compose version >/dev/null 2>&1; then
    info "安装 docker compose 插件"
    apt_refresh
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null
    ok "Compose $(docker compose version --short)"
  else
    skip "Compose 已安装（$(docker compose version --short)）"
  fi
fi

# ---------------------------------------------------------------------------
# 3. 获取项目文件
# ---------------------------------------------------------------------------
head1 "3/4 获取项目文件"

if [[ -f "$INSTALL_DIR/ocstack" ]]; then
  skip "已存在于 $INSTALL_DIR"
  info "从 GitHub 更新到最新版"
  TMP="$(mktemp -d)"
  if curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}" \
       | tar xz -C "$TMP" --strip-components=1 2>/dev/null; then
    # 只覆盖代码，保留 .env / data / workspaces
    for f in ocstack docker-compose.yml install.sh README.md .env.example; do
      [[ -f "$TMP/$f" ]] && cp -f "$TMP/$f" "$INSTALL_DIR/$f"
    done
    [[ -d "$TMP/docker" ]] && cp -rf "$TMP/docker/." "$INSTALL_DIR/docker/"
    [[ -d "$TMP/caddy" ]] && cp -rf "$TMP/caddy/." "$INSTALL_DIR/caddy/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/ocstack"
    ok "已更新"
  else
    warn "更新失败，继续使用现有版本"
  fi
  rm -rf "$TMP"
else
  info "下载到 $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  TMP="$(mktemp -d)"
  if curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}" \
       | tar xz -C "$TMP" --strip-components=1; then
    cp -a "$TMP/." "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/ocstack" 2>/dev/null || true
    rm -rf "$TMP"
    ok "已下载"
  else
    rm -rf "$TMP"
    warn "tarball 下载失败，改用 git clone"
    git clone --depth 1 -b "$BRANCH" "https://github.com/${REPO}.git" "$INSTALL_DIR" >/dev/null 2>&1 \
      || die "拉取项目失败，检查网络或仓库地址"
    ok "已克隆"
  fi
fi

[[ -f "$INSTALL_DIR/ocstack" ]] || die "缺少 ocstack，目录内容异常"
chmod +x "$INSTALL_DIR/ocstack"

# ---------------------------------------------------------------------------
# 4. 交给 ocstack install
# ---------------------------------------------------------------------------
head1 "4/4 启动安装程序"

cd "$INSTALL_DIR"
exec ./ocstack install "$@"
