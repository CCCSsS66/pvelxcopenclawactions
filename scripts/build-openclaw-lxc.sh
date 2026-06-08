#!/usr/bin/env bash
set -Eeuo pipefail

trap 'on_error $LINENO' ERR

TEMPLATE_NAME="${TEMPLATE_NAME:-openclaw-lxc}"
VERSION="${VERSION:-dev}"

DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
ARCH="${ARCH:-amd64}"

BUILD_MIRROR="${BUILD_MIRROR:-http://deb.debian.org/debian}"

CN_APT_MIRROR="${CN_APT_MIRROR:-https://mirrors.aliyun.com/debian}"
CN_SECURITY_MIRROR="${CN_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"

NPM_INSTALL_REGISTRY="${NPM_INSTALL_REGISTRY:-https://registry.npmmirror.com}"
NPM_FINAL_REGISTRY="${NPM_FINAL_REGISTRY:-https://registry.npmmirror.com}"

OPENCLAW_NPM_SPEC="${OPENCLAW_NPM_SPEC:-openclaw}"
OPENCLAW_RUN_CMD="${OPENCLAW_RUN_CMD:-openclaw onboard}"

BIND_HOST="${BIND_HOST:-0.0.0.0}"
IPV6_POLICY="${IPV6_POLICY:-ask}"

PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-65000}"

BASE_DIR="$(pwd)"
WORK_DIR="${BASE_DIR}/work"
ROOTFS="${WORK_DIR}/rootfs"
DIST_DIR="${BASE_DIR}/dist"

OUT_FILE="${TEMPLATE_NAME}-debian12-${VERSION}.tar.gz"
IMAGE_PATH="${DIST_DIR}/${OUT_FILE}"
LIST_FILE="${DIST_DIR}/${OUT_FILE}.list"
SHA_FILE="${IMAGE_PATH}.sha256"
BUILD_INFO="${DIST_DIR}/build-info.txt"

log() {
  echo "[$(date '+%F %T')] $*"
}

die() {
  echo "错误：$*" >&2
  exit 1
}

q() {
  printf '%q' "$1"
}

require_root() {
  if [ "$(id -u)" != "0" ]; then
    die "构建脚本必须以 root 运行"
  fi
}

validate_inputs() {
  if ! [[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "VERSION 不合法：$VERSION"
  fi

  if ! [[ "$PORT_MIN" =~ ^[0-9]+$ ]]; then
    die "PORT_MIN 必须是数字：$PORT_MIN"
  fi

  if ! [[ "$PORT_MAX" =~ ^[0-9]+$ ]]; then
    die "PORT_MAX 必须是数字：$PORT_MAX"
  fi

  PORT_MIN="$((10#$PORT_MIN))"
  PORT_MAX="$((10#$PORT_MAX))"

  if (( PORT_MIN < 1 || PORT_MAX > 65535 || PORT_MIN > PORT_MAX )); then
    die "端口范围无效：${PORT_MIN}-${PORT_MAX}"
  fi

  if [ "$BIND_HOST" != "0.0.0.0" ] && [ "$BIND_HOST" != "::" ]; then
    die "BIND_HOST 只能是 0.0.0.0 或 ::"
  fi

  if [ "$IPV6_POLICY" != "ask" ] && [ "$IPV6_POLICY" != "0" ] && [ "$IPV6_POLICY" != "1" ]; then
    die "IPV6_POLICY 只能是 ask、0、1"
  fi

  if [ "$BIND_HOST" = "::" ] && [ "$IPV6_POLICY" != "1" ]; then
    die "BIND_HOST=:: 时必须设置 IPV6_POLICY=1，否则 IPv6 被关闭后服务可能无法监听"
  fi
}

cleanup_mounts() {
  set +e

  if [ -n "${ROOTFS:-}" ] && [ -d "$ROOTFS" ]; then
    mountpoint -q "$ROOTFS/proc" && umount -lf "$ROOTFS/proc"
    mountpoint -q "$ROOTFS/sys" && umount -lf "$ROOTFS/sys"
    mountpoint -q "$ROOTFS/dev/pts" && umount -lf "$ROOTFS/dev/pts"
    mountpoint -q "$ROOTFS/dev" && umount -lf "$ROOTFS/dev"
  fi

  set -e
}

on_error() {
  local line="$1"

  echo
  echo "=================================================="
  echo "构建失败，出错行：${line}"
  echo "正在清理挂载点..."
  echo "=================================================="

  cleanup_mounts || true

  echo
  echo "挂载点状态："
  mount | grep "$ROOTFS" || true

  exit 1
}

install_build_deps() {
  log "[1/12] 安装构建依赖"

  apt-get update
  apt-get install -y \
    debootstrap \
    tar \
    gzip \
    xz-utils \
    curl \
    ca-certificates \
    gnupg \
    openssl \
    findutils \
    coreutils
}

create_rootfs() {
  log "[2/12] 创建 Debian rootfs"

  cleanup_mounts || true

  rm -rf "$WORK_DIR"
  mkdir -p "$ROOTFS" "$DIST_DIR"

  debootstrap \
    --arch="$ARCH" \
    "$DEBIAN_RELEASE" \
    "$ROOTFS" \
    "$BUILD_MIRROR"

  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

  mkdir -p "$ROOTFS/dev" "$ROOTFS/dev/pts" "$ROOTFS/proc" "$ROOTFS/sys"

  mount --bind /dev "$ROOTFS/dev"
  mount --bind /dev/pts "$ROOTFS/dev/pts"
  mount -t proc proc "$ROOTFS/proc"
  mount -t sysfs sys "$ROOTFS/sys"
}

write_base_system() {
  log "[3/12] 写入基础系统配置"

  cat > "$ROOTFS/etc/hostname" <<'EOF'
openclaw
EOF

  cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 openclaw
EOF

  cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

  mkdir -p "$ROOTFS/etc/openclaw"
}

install_openclaw() {
  log "[4/12] 在镜像内预装 Node.js / pnpm / OpenClaw"
  log "OpenClaw npm spec: ${OPENCLAW_NPM_SPEC}"

  cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    TERM=xterm \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DEBIAN_FRONTEND=noninteractive \
    OPENCLAW_NPM_SPEC="$OPENCLAW_NPM_SPEC" \
    NPM_INSTALL_REGISTRY="$NPM_INSTALL_REGISTRY" \
    /bin/bash --noprofile --norc -s <<'CHROOT'
set -Eeuo pipefail

apt-get update

apt-get install -y \
  systemd \
  systemd-sysv \
  dbus \
  curl \
  git \
  sudo \
  nano \
  vim \
  less \
  ca-certificates \
  gnupg \
  openssl \
  iproute2 \
  iputils-ping \
  net-tools \
  procps \
  psmisc \
  openssh-server \
  ufw \
  locales \
  lsof

sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen || true
sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen || true
locale-gen || true

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

npm config set registry "$NPM_INSTALL_REGISTRY"
npm config set fund false
npm config set audit false

npm install -g pnpm
npm install -g "$OPENCLAW_NPM_SPEC"

useradd -m -s /bin/bash openclaw || true

mkdir -p /var/lib/openclaw
mkdir -p /home/openclaw/.openclaw
mkdir -p /etc/openclaw

chown -R openclaw:openclaw /var/lib/openclaw
chown -R openclaw:openclaw /home/openclaw

ssh-keygen -A || true

echo "Node: $(node -v)"
echo "npm: $(npm -v)"
echo "pnpm: $(pnpm -v)"
echo "openclaw path: $(command -v openclaw || true)"

if ! command -v openclaw >/dev/null 2>&1; then
  echo "没有找到 openclaw 命令"
  exit 1
fi

if [ ! -d /usr/lib/node_modules/openclaw ] && [ ! -d /usr/local/lib/node_modules/openclaw ]; then
  echo "没有找到 openclaw node_modules 目录"
  echo "当前全局 node_modules："
  find /usr/lib/node_modules /usr/local/lib/node_modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true
  exit 1
fi
CHROOT
}

switch_sources() {
  log "[5/12] 切换模板内国内源"

  cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb ${CN_APT_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${CN_APT_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb ${CN_SECURITY_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    TERM=xterm \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NPM_FINAL_REGISTRY="$NPM_FINAL_REGISTRY" \
    /bin/bash --noprofile --norc -s <<'CHROOT'
set -Eeuo pipefail

npm config set registry "$NPM_FINAL_REGISTRY"
pnpm config set registry "$NPM_FINAL_REGISTRY" || true

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT
}

write_template_config() {
  log "[6/12] 写入模板配置"

  {
    echo "# OpenClaw LXC 模板配置"
    echo "PORT_MIN=$(q "$PORT_MIN")"
    echo "PORT_MAX=$(q "$PORT_MAX")"
    echo "OPENCLAW_RUN_CMD=$(q "$OPENCLAW_RUN_CMD")"
    echo "ENABLE_IPV6_DEFAULT=$(q "$IPV6_POLICY")"
    echo "OPENCLAW_BIND_HOST=$(q "$BIND_HOST")"
  } > "$ROOTFS/etc/openclaw/template.conf"

  chmod 644 "$ROOTFS/etc/openclaw/template.conf"
}

write_ipv6_control() {
  log "[7/12] 写入 IPv6 控制脚本"

  cat > "$ROOTFS/usr/local/bin/openclaw-ipv6-control" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-status}"

get_main_ifaces() {
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | cut -d'@' -f1 \
    | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)' \
    || true
}

disable_ipv6() {
  echo "[IPv6] 正在强制关闭 IPv6..."

  cat > /etc/sysctl.d/99-openclaw-disable-ipv6.conf <<'EOT'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOT

  rm -f /etc/sysctl.d/99-openclaw-enable-ipv6.conf

  sysctl --system >/dev/null 2>&1 || true

  for dev in $(get_main_ifaces); do
    ip -6 addr flush dev "$dev" || true
    ip -6 route flush dev "$dev" || true
    sysctl -w "net.ipv6.conf.${dev}.disable_ipv6=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.accept_ra=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.autoconf=0" >/dev/null 2>&1 || true
  done

  mkdir -p /etc/systemd/network

  cat > /etc/systemd/network/99-openclaw-no-ipv6.network <<'EOT'
[Match]
Name=*

[Network]
IPv6AcceptRA=no
LinkLocalAddressing=ipv4
EOT

  systemctl restart systemd-sysctl >/dev/null 2>&1 || true

  echo "[IPv6] 已关闭。"
}

enable_ipv6() {
  echo "[IPv6] 正在开启 IPv6..."

  rm -f /etc/sysctl.d/99-openclaw-disable-ipv6.conf
  rm -f /etc/systemd/network/99-openclaw-no-ipv6.network

  cat > /etc/sysctl.d/99-openclaw-enable-ipv6.conf <<'EOT'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
EOT

  sysctl --system >/dev/null 2>&1 || true

  for dev in $(get_main_ifaces); do
    sysctl -w "net.ipv6.conf.${dev}.disable_ipv6=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.accept_ra=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.autoconf=1" >/dev/null 2>&1 || true
  done

  echo "[IPv6] 已开启。"
}

status_ipv6() {
  echo "IPv6 全局地址："
  ip -6 addr show scope global || true
  echo
  echo "IPv6 路由："
  ip -6 route show || true
}

case "$ACTION" in
  enable) enable_ipv6 ;;
  disable) disable_ipv6 ;;
  status) status_ipv6 ;;
  *)
    echo "用法：openclaw-ipv6-control enable|disable|status"
    exit 1
    ;;
esac
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-ipv6-control"
}

write_runtime_scripts() {
  log "[8/12] 写入运行期脚本"

  cat > "$ROOTFS/usr/local/bin/openclaw-get-addresses" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${1:-}"

get_ipv4_list() {
  ip -o -4 addr show scope global \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | grep -v '^127\.' \
    || true
}

get_ipv6_list() {
  ip -o -6 addr show scope global \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | grep -v '^fe80' \
    || true
}

echo "网卡 IPv4 访问地址："
found4=0

while read -r ip4; do
  [ -z "$ip4" ] && continue
  found4=1
  if [ -n "$PORT" ]; then
    echo "http://${ip4}:${PORT}"
  else
    echo "$ip4"
  fi
done < <(get_ipv4_list)

if [ "$found4" = "0" ]; then
  echo "未检测到 IPv4 地址"
fi

echo
echo "网卡 IPv6 访问地址："
found6=0

while read -r ip6; do
  [ -z "$ip6" ] && continue
  found6=1
  if [ -n "$PORT" ]; then
    echo "http://[${ip6}]:${PORT}"
  else
    echo "$ip6"
  fi
done < <(get_ipv6_list)

if [ "$found6" = "0" ]; then
  echo "未检测到 IPv6 地址"
fi
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-get-addresses"

  cat > "$ROOTFS/usr/local/bin/openclaw-wait-network" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

for _ in $(seq 1 20); do
  if ip -o -4 addr show scope global | grep -q .; then
    exit 0
  fi

  if ip -o -6 addr show scope global | grep -q .; then
    exit 0
  fi

  sleep 1
done

exit 0
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-wait-network"

  cat > "$ROOTFS/usr/local/bin/openclaw-set-api" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/openclaw/openclaw.env"
RUNTIME="/etc/openclaw/runtime.env"
INFO="/root/openclaw-info.txt"

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 执行：openclaw-set-api"
  exit 1
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "openclaw-set-api 需要交互式终端。"
  exit 1
fi

env_quote() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\\$}"
  s="${s//\`/\\\`}"
  printf '"%s"' "$s"
}

if [ ! -f "$RUNTIME" ]; then
  echo "运行时配置不存在，请先执行：openclaw-firstboot"
  exit 1
fi

source /etc/openclaw/template.conf
source "$RUNTIME"

echo
echo "=================================================="
echo " OpenClaw 自定义 API 配置"
echo "=================================================="
echo

read -rp "API base_url，例如 https://api.openai.com/v1 或 https://api.deepseek.com/v1: " BASE_URL
BASE_URL="${BASE_URL:-https://api.openai.com/v1}"

read -rp "默认模型，例如 gpt-4.1 / deepseek-chat / deepseek-v4-flash: " MODEL
MODEL="${MODEL:-gpt-4.1}"

read -rsp "请输入 API Key: " API_KEY
echo

if [ -z "$API_KEY" ]; then
  echo "API Key 不能为空。"
  exit 1
fi

{
  printf 'HOST=%s\n' "$(env_quote "$OPENCLAW_BIND_HOST")"
  printf 'OPENCLAW_HOST=%s\n' "$(env_quote "$OPENCLAW_BIND_HOST")"

  printf 'PORT=%s\n' "$(env_quote "$OPENCLAW_PORT")"
  printf 'OPENCLAW_PORT=%s\n' "$(env_quote "$OPENCLAW_PORT")"

  printf 'OPENCLAW_ADMIN_USER=%s\n' "$(env_quote "admin")"
  printf 'OPENCLAW_ADMIN_PASSWORD=%s\n' "$(env_quote "$OPENCLAW_ADMIN_PASSWORD")"

  printf 'OPENAI_BASE_URL=%s\n' "$(env_quote "$BASE_URL")"
  printf 'OPENAI_API_KEY=%s\n' "$(env_quote "$API_KEY")"
  printf 'OPENAI_MODEL=%s\n' "$(env_quote "$MODEL")"

  printf 'ANTHROPIC_BASE_URL=%s\n' "$(env_quote "$BASE_URL")"
  printf 'ANTHROPIC_API_KEY=%s\n' "$(env_quote "$API_KEY")"

  printf 'DEEPSEEK_BASE_URL=%s\n' "$(env_quote "$BASE_URL")"
  printf 'DEEPSEEK_API_KEY=%s\n' "$(env_quote "$API_KEY")"
  printf 'DEEPSEEK_MODEL=%s\n' "$(env_quote "$MODEL")"
} > "$CONF"

chown root:openclaw "$CONF"
chmod 640 "$CONF"

touch /etc/openclaw/api_configured

systemctl restart openclaw || true

{
  echo
  echo "=================================================="
  echo " OpenClaw 云主机信息"
  echo "=================================================="
  echo
  openclaw-get-addresses "${OPENCLAW_PORT}"
  echo
  echo "端口：${OPENCLAW_PORT}"
  echo "用户名：admin"
  echo "密码：${OPENCLAW_ADMIN_PASSWORD}"
  echo "监听地址：${OPENCLAW_BIND_HOST}"
  echo
  echo "模型接口：${BASE_URL}"
  echo "默认模型：${MODEL}"
  echo
  echo "重新配置 API：openclaw-set-api"
  echo "查看服务：systemctl status openclaw --no-pager -l"
  echo
  echo "=================================================="
} > "$INFO"

cat "$INFO"
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-set-api"

  cat > "$ROOTFS/usr/local/bin/openclaw-firstboot" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

FLAG="/etc/openclaw/firstboot.done"
RUNTIME="/etc/openclaw/runtime.env"
INFO="/root/openclaw-info.txt"

source /etc/openclaw/template.conf

if [ -f "$FLAG" ]; then
  exit 0
fi

echo "[OpenClaw] 首次启动初始化..."

openclaw-wait-network || true

ssh-keygen -A || true
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || true

ENABLE_IPV6="${ENABLE_IPV6_DEFAULT}"

if [ "$ENABLE_IPV6" = "ask" ]; then
  ENABLE_IPV6="0"
  touch /etc/openclaw/ipv6_need_ask
fi

if [ "$ENABLE_IPV6" = "1" ]; then
  openclaw-ipv6-control enable || true
else
  openclaw-ipv6-control disable || true
fi

PORT="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"
ADMIN_PASS="$(openssl rand -hex 9)"

cat > "$RUNTIME" <<EOT
OPENCLAW_PORT=${PORT}
OPENCLAW_ADMIN_PASSWORD=${ADMIN_PASS}
ENABLE_IPV6=${ENABLE_IPV6}
EOT

chown root:openclaw "$RUNTIME"
chmod 640 "$RUNTIME"

cat > /etc/openclaw/openclaw.env <<EOT
HOST=${OPENCLAW_BIND_HOST}
OPENCLAW_HOST=${OPENCLAW_BIND_HOST}

PORT=${PORT}
OPENCLAW_PORT=${PORT}

OPENCLAW_ADMIN_USER=admin
OPENCLAW_ADMIN_PASSWORD=${ADMIN_PASS}
EOT

chown root:openclaw /etc/openclaw/openclaw.env
chmod 640 /etc/openclaw/openclaw.env

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

if command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
fi

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable openclaw >/dev/null 2>&1 || true
systemctl restart openclaw --no-block >/dev/null 2>&1 || true

{
  echo
  echo "=================================================="
  echo " OpenClaw LXC 已初始化"
  echo "=================================================="
  echo
  openclaw-get-addresses "${PORT}"
  echo
  echo "端口：${PORT}"
  echo "用户名：admin"
  echo "密码：${ADMIN_PASS}"
  echo "监听地址：${OPENCLAW_BIND_HOST}"
  echo
  if [ "$ENABLE_IPV6" = "1" ]; then
    echo "IPv6 状态：已开启"
  else
    echo "IPv6 状态：已关闭"
  fi
  echo
  echo "下一步：进入容器后执行 openclaw-set-api"
  echo "查看服务：systemctl status openclaw --no-pager -l"
  echo
  echo "=================================================="
} > "$INFO"

touch "$FLAG"
cat "$INFO"
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-firstboot"

  cat > "$ROOTFS/usr/local/bin/openclaw-ipv6-ask" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ASK_FLAG="/etc/openclaw/ipv6_need_ask"
RUNTIME="/etc/openclaw/runtime.env"
INFO="/root/openclaw-info.txt"

if [ ! -f "$ASK_FLAG" ]; then
  exit 0
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  exit 0
fi

echo
echo "=================================================="
echo " IPv6 配置"
echo "=================================================="
echo
echo "1) 关闭 IPv6，推荐国内 NAT / 路由器疯狂下发 IPv6 的环境"
echo "2) 开启 IPv6"
echo
read -rp "请选择 [1]: " ip6_choice
ip6_choice="${ip6_choice:-1}"

if [ "$ip6_choice" = "2" ]; then
  openclaw-ipv6-control enable || true
  NEW_IPV6="1"
else
  openclaw-ipv6-control disable || true
  NEW_IPV6="0"
fi

if [ -f "$RUNTIME" ]; then
  sed -i '/^ENABLE_IPV6=/d' "$RUNTIME"
  echo "ENABLE_IPV6=${NEW_IPV6}" >> "$RUNTIME"
  chown root:openclaw "$RUNTIME" || true
  chmod 640 "$RUNTIME" || true
fi

rm -f "$ASK_FLAG"

if [ -f "$RUNTIME" ]; then
  source /etc/openclaw/template.conf
  source "$RUNTIME"

  {
    echo
    echo "=================================================="
    echo " OpenClaw LXC 已初始化"
    echo "=================================================="
    echo
    openclaw-get-addresses "${OPENCLAW_PORT}"
    echo
    echo "端口：${OPENCLAW_PORT}"
    echo "用户名：admin"
    echo "密码：${OPENCLAW_ADMIN_PASSWORD}"
    echo "监听地址：${OPENCLAW_BIND_HOST}"
    echo
    if [ "$NEW_IPV6" = "1" ]; then
      echo "IPv6 状态：已开启"
    else
      echo "IPv6 状态：已关闭"
    fi
    echo
    echo "下一步：进入容器后执行 openclaw-set-api"
    echo "查看服务：systemctl status openclaw --no-pager -l"
    echo
    echo "=================================================="
  } > "$INFO"

  cat "$INFO"
fi
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-ipv6-ask"

  cat > "$ROOTFS/usr/local/bin/openclaw-launcher" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/openclaw/template.conf
source /etc/openclaw/openclaw.env 2>/dev/null || true

export HOME=/home/openclaw

export HOST="${OPENCLAW_HOST:-${HOST:-${OPENCLAW_BIND_HOST:-0.0.0.0}}}"
export OPENCLAW_HOST="${OPENCLAW_HOST:-${HOST:-${OPENCLAW_BIND_HOST:-0.0.0.0}}}"

export PORT="${OPENCLAW_PORT:-${PORT:-18789}}"
export OPENCLAW_PORT="${OPENCLAW_PORT:-${PORT:-18789}}"

cd /var/lib/openclaw

exec bash -lc "$OPENCLAW_RUN_CMD"
EOF

  chmod +x "$ROOTFS/usr/local/bin/openclaw-launcher"
}

write_systemd() {
  log "[9/12] 写入 systemd 服务"

  cat > "$ROOTFS/etc/systemd/system/openclaw.service" <<'EOF'
[Unit]
Description=OpenClaw Service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/openclaw/openclaw.env

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
EnvironmentFile=-/etc/openclaw/openclaw.env
WorkingDirectory=/var/lib/openclaw
ExecStart=/usr/local/bin/openclaw-launcher
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > "$ROOTFS/etc/systemd/system/openclaw-firstboot.service" <<'EOF'
[Unit]
Description=OpenClaw First Boot Init
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"

  ln -sf /etc/systemd/system/openclaw-firstboot.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/openclaw-firstboot.service"

  cat > "$ROOTFS/etc/profile.d/openclaw-info.sh" <<'EOF'
# OpenClaw login helper

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ -t 0 ] && [ -t 1 ] || return 0 2>/dev/null || exit 0

if [ "$(id -u)" = "0" ]; then
  echo

  if [ -f /etc/openclaw/ipv6_need_ask ]; then
    openclaw-ipv6-ask
  fi

  if [ -f /root/openclaw-info.txt ]; then
    cat /root/openclaw-info.txt
  else
    echo "OpenClaw 信息文件不存在。"
    echo "如果首次启动没有完成，可以手动执行：openclaw-firstboot"
  fi

  if [ -f /etc/openclaw/firstboot.done ] && [ ! -f /etc/openclaw/api_configured ]; then
    echo
    echo "检测到还没有配置自定义 API。"
    printf "是否现在配置？[Y/n]: "
    IFS= read -r answer
    answer="${answer:-Y}"

    case "$answer" in
      Y|y|YES|yes|Yes)
        openclaw-set-api
        ;;
    esac
  fi
fi
EOF

  chmod +x "$ROOTFS/etc/profile.d/openclaw-info.sh"
}

self_check() {
  log "[10/12] rootfs 自检"

  bash -n "$ROOTFS/usr/local/bin/openclaw-ipv6-control"
  bash -n "$ROOTFS/usr/local/bin/openclaw-get-addresses"
  bash -n "$ROOTFS/usr/local/bin/openclaw-wait-network"
  bash -n "$ROOTFS/usr/local/bin/openclaw-set-api"
  bash -n "$ROOTFS/usr/local/bin/openclaw-firstboot"
  bash -n "$ROOTFS/usr/local/bin/openclaw-ipv6-ask"
  bash -n "$ROOTFS/usr/local/bin/openclaw-launcher"
  bash -n "$ROOTFS/etc/profile.d/openclaw-info.sh"

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash --noprofile --norc -c 'command -v node >/dev/null && command -v npm >/dev/null && command -v pnpm >/dev/null && command -v openclaw >/dev/null'

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash --noprofile --norc -c '[ -d /usr/lib/node_modules/openclaw ] || [ -d /usr/local/lib/node_modules/openclaw ]'

  test -f "$ROOTFS/etc/systemd/system/openclaw.service"
  test -f "$ROOTFS/etc/systemd/system/openclaw-firstboot.service"
  test -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/openclaw-firstboot.service"

  log "rootfs 自检通过"
}

pack_image() {
  log "[11/12] 清理 rootfs 并打包"

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash --noprofile --norc -s <<'CHROOT'
set +e

apt-get clean
rm -rf /var/lib/apt/lists/*

rm -rf /tmp/*
rm -rf /var/tmp/*

rm -f /root/.bash_history
rm -f /home/openclaw/.bash_history

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

rm -f /etc/ssh/ssh_host_*

rm -f /usr/sbin/policy-rc.d

history -c
CHROOT

  cleanup_mounts

  rm -f "$IMAGE_PATH" "$LIST_FILE" "$SHA_FILE"

  tar --numeric-owner \
    --xattrs \
    --acls \
    -czf "$IMAGE_PATH" \
    -C "$ROOTFS" .

  gzip -t "$IMAGE_PATH"

  sha256sum "$IMAGE_PATH" > "$SHA_FILE"

  tar -tzf "$IMAGE_PATH" > "$LIST_FILE"

  if ! grep -Eq '^\./usr/bin/openclaw$|^\./usr/local/bin/openclaw$' "$LIST_FILE"; then
    grep -i 'openclaw' "$LIST_FILE" | sed -n '1,100p' || true
    die "镜像中没有 openclaw 命令"
  fi

  if ! grep -Eq '^\./usr/lib/node_modules/openclaw/|^\./usr/local/lib/node_modules/openclaw/' "$LIST_FILE"; then
    grep 'node_modules' "$LIST_FILE" | sed -n '1,100p' || true
    die "镜像中没有 openclaw node_modules 目录"
  fi

  if ! grep -q '^\./etc/systemd/system/openclaw.service$' "$LIST_FILE"; then
    die "镜像中没有 openclaw.service"
  fi

  if ! grep -q '^\./usr/local/bin/openclaw-firstboot$' "$LIST_FILE"; then
    die "镜像中没有 openclaw-firstboot"
  fi

  log "镜像验证通过"
}

write_build_info() {
  log "[12/12] 写入构建信息"

  {
    echo "OpenClaw LXC Template"
    echo
    echo "Version: ${VERSION}"
    echo "Template: ${TEMPLATE_NAME}"
    echo "Debian: ${DEBIAN_RELEASE}"
    echo "Arch: ${ARCH}"
    echo "OpenClaw npm spec: ${OPENCLAW_NPM_SPEC}"
    echo "OpenClaw run command: ${OPENCLAW_RUN_CMD}"
    echo "Bind host: ${BIND_HOST}"
    echo "IPv6 policy: ${IPV6_POLICY}"
    echo "Port range: ${PORT_MIN}-${PORT_MAX}"
    echo "Image: ${OUT_FILE}"
    echo
    echo "SHA256:"
    cat "$SHA_FILE"
    echo
    echo "Created at: $(date -u '+%F %T UTC')"
  } > "$BUILD_INFO"
}

final_cleanup() {
  log "清理构建垃圾，只保留 dist 产物"
  cleanup_mounts || true
  rm -rf "$WORK_DIR"
}

main() {
  require_root
  validate_inputs

  log "=================================================="
  log "OpenClaw LXC CI 构建开始"
  log "=================================================="

  install_build_deps
  create_rootfs
  write_base_system
  install_openclaw
  switch_sources
  write_template_config
  write_ipv6_control
  write_runtime_scripts
  write_systemd
  self_check
  pack_image
  write_build_info
  final_cleanup

  log "=================================================="
  log "构建成功"
  log "=================================================="
  log "镜像：${IMAGE_PATH}"
  log "校验：${SHA_FILE}"
}

main "$@"
