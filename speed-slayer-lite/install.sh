#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP="speed-slayer-lite"
readonly APP_DIR="/etc/${APP}"
readonly XRAY_VERSION="26.3.27"
readonly CLOUDFLARED_VERSION="2026.7.3"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

validate_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

port_free() {
  ! ss -H -lntup "sport = :$1" 2>/dev/null | grep -q .
}

download_checked() {
  local url=$1 output=$2 expected=$3 actual
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$output" "$url"
  actual=$(sha256sum "$output" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "SHA-256 校验失败: $url"
}

detect_arch() {
  case $(uname -m) in
    x86_64|amd64)
      XRAY_ARCH="64"
      CF_ARCH="amd64"
      XRAY_SHA="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
      CF_SHA="9d71c677db00134c1bd4144b7783486b654ad281b1ea62b4972098d19f770f17"
      ;;
    aarch64|arm64)
      XRAY_ARCH="arm64-v8a"
      CF_ARCH="arm64"
      XRAY_SHA="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
      CF_SHA="65259e652a7bea08bf5df603233ab22b8bf3116af8df9f9206209af6a1b955c0"
      ;;
    *) die "仅支持 amd64 和 arm64" ;;
  esac
}

install_packages() {
  [[ -r /etc/os-release ]] || die "无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die "仅支持 Debian/Ubuntu"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip openssl iproute2
}

install_binaries() {
  local tmp xray_zip
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' RETURN
  xray_zip="$tmp/xray.zip"
  download_checked \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" \
    "$xray_zip" "$XRAY_SHA"
  unzip -q "$xray_zip" xray -d "$tmp"
  install -m 0755 "$tmp/xray" /usr/local/bin/xray

  download_checked \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}" \
    "$tmp/cloudflared" "$CF_SHA"
  install -m 0755 "$tmp/cloudflared" /usr/local/bin/cloudflared
  rm -rf -- "$tmp"
  trap - RETURN
}

create_users() {
  getent group xray >/dev/null || groupadd --system xray
  id xray >/dev/null 2>&1 || useradd --system --gid xray --home-dir /var/lib/xray --shell /usr/sbin/nologin xray
  getent group cloudflared >/dev/null || groupadd --system cloudflared
  id cloudflared >/dev/null 2>&1 || useradd --system --gid cloudflared --home-dir /var/lib/cloudflared --shell /usr/sbin/nologin cloudflared
  install -d -m 0750 -o root -g xray "$APP_DIR" /var/lib/xray
  install -d -m 0750 -o cloudflared -g cloudflared /var/lib/cloudflared
}

write_config() {
  local keys
  VMESS_UUID=$(xray uuid)
  WS_PATH="/$(openssl rand -hex 12)"
  SS_PASSWORD=$(openssl rand -base64 16 | tr -d '\n')
  keys=$(xray x25519)
  REALITY_PRIVATE=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keys")
  REALITY_PUBLIC=$(awk -F': ' '/Password|PublicKey/{print $2; exit}' <<<"$keys")
  REALITY_SHORT_ID=$(openssl rand -hex 8)
  [[ -n $REALITY_PRIVATE && -n $REALITY_PUBLIC ]] || die "无法生成 REALITY 密钥"

  cat >"$APP_DIR/xray.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vmess-ws-argo",
      "listen": "127.0.0.1",
      "port": $VMESS_PORT,
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "$VMESS_UUID" }] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    },
    {
      "tag": "ss2022",
      "port": $SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$SS_PASSWORD",
        "network": "tcp,udp"
      }
    },
    {
      "tag": "vless-reality",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$VMESS_UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_SERVER_NAME:443",
          "serverNames": ["$REALITY_SERVER_NAME"],
          "privateKey": "$REALITY_PRIVATE",
          "shortIds": ["$REALITY_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chown root:xray "$APP_DIR/xray.json"
  chmod 0640 "$APP_DIR/xray.json"

  cat >"$APP_DIR/state" <<EOF
VMESS_PORT=$VMESS_PORT
SS_PORT=$SS_PORT
REALITY_PORT=$REALITY_PORT
VMESS_ADDRESS=$VMESS_ADDRESS
VMESS_UUID=$VMESS_UUID
WS_PATH=$WS_PATH
SS_PASSWORD=$SS_PASSWORD
REALITY_SERVER_NAME=$REALITY_SERVER_NAME
REALITY_PUBLIC=$REALITY_PUBLIC
REALITY_SHORT_ID=$REALITY_SHORT_ID
ARGO_MODE=$ARGO_MODE
ARGO_DOMAIN=$ARGO_DOMAIN
EOF
  chmod 0600 "$APP_DIR/state"

  if [[ $ARGO_MODE == token ]]; then
    printf 'TUNNEL_TOKEN=%s\n' "$ARGO_TOKEN" >"$APP_DIR/cloudflared.env"
    chmod 0600 "$APP_DIR/cloudflared.env"
  else
    : >"$APP_DIR/cloudflared.env"
    chmod 0600 "$APP_DIR/cloudflared.env"
  fi
}

write_units() {
  cat >/etc/systemd/system/xray-lite.service <<EOF
[Unit]
Description=Xray for Speed Slayer Lite
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config $APP_DIR/xray.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

  local cf_exec cf_env=""
  if [[ $ARGO_MODE == token ]]; then
    cf_env="EnvironmentFile=$APP_DIR/cloudflared.env"
    cf_exec="/usr/local/bin/cloudflared --no-autoupdate tunnel run --token \${TUNNEL_TOKEN}"
  else
    cf_exec="/usr/local/bin/cloudflared --no-autoupdate tunnel --url http://127.0.0.1:$VMESS_PORT"
  fi
  cat >/etc/systemd/system/cloudflared-lite.service <<EOF
[Unit]
Description=Cloudflare Tunnel for Speed Slayer Lite
After=network-online.target xray-lite.service
Wants=network-online.target
Requires=xray-lite.service
PartOf=xray-lite.service

[Service]
User=cloudflared
Group=cloudflared
$cf_env
ExecStart=$cf_exec
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

public_ip() {
  curl --fail --silent --show-error --max-time 8 --proto '=https' https://api.ipify.org || printf 'YOUR_SERVER_IP'
}

quick_domain() {
  journalctl -u cloudflared-lite.service --no-pager -n 100 2>/dev/null |
    grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -n1 | sed 's#https://##'
}

quick_domain_since() {
  journalctl -u cloudflared-lite.service --since "$1" --no-pager 2>/dev/null |
    grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -n1 | sed 's#https://##'
}

write_client_info() {
  [[ -r $APP_DIR/state ]] || die "尚未安装"
  # State is generated internally and root-only; validate every field before use.
  local requested_address=${VMESS_ADDRESS:-} key value server domain vmess_json vmess_uri ss_user ss_uri reality_uri
  while IFS='=' read -r key value; do
    case $key in
      VMESS_PORT|SS_PORT|REALITY_PORT|VMESS_ADDRESS|VMESS_UUID|WS_PATH|SS_PASSWORD|REALITY_SERVER_NAME|REALITY_PUBLIC|REALITY_SHORT_ID|ARGO_MODE|ARGO_DOMAIN)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$APP_DIR/state"
  server=$(public_ip)
  domain=${ARGO_DOMAIN:-}
  if [[ ${ARGO_MODE:-} == quick ]]; then domain=$(quick_domain); fi
  domain=${domain:-QUICK_TUNNEL_STARTING}
  VMESS_ADDRESS=${requested_address:-${VMESS_ADDRESS:-www.wto.org}}
  validate_domain "$VMESS_ADDRESS" || die "VMESS_ADDRESS 无效"

  vmess_json=$(printf '{"v":"2","ps":"vmess-argo","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$VMESS_ADDRESS" "$VMESS_UUID" "$domain" "$WS_PATH" "$domain")
  vmess_uri="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
  ss_user=$(printf '2022-blake3-aes-128-gcm:%s' "$SS_PASSWORD" | base64 -w0)
  ss_uri="ss://${ss_user}@${server}:${SS_PORT}#ss2022"
  reality_uri="vless://${VMESS_UUID}@${server}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp#vless-reality"

  cat >"$APP_DIR/client-info.txt" <<EOF
VMess + WS + Argo
$vmess_uri

Shadowsocks 2022
$ss_uri

VLESS + REALITY
$reality_uri

提示：此文件包含全部访问凭据，仅保存在服务器本机。
EOF
  chmod 0600 "$APP_DIR/client-info.txt"
}

do_install() {
  need_root
  [[ ! -e $APP_DIR/state ]] || die "已安装；请先运行 $APP uninstall"
  VMESS_PORT=${VMESS_PORT:-30000}
  SS_PORT=${SS_PORT:-30001}
  REALITY_PORT=${REALITY_PORT:-30002}
  VMESS_ADDRESS=${VMESS_ADDRESS:-www.wto.org}
  REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-learn.microsoft.com}
  ARGO_MODE=${ARGO_MODE:-quick}
  ARGO_TOKEN=${ARGO_TOKEN:-}
  ARGO_DOMAIN=${ARGO_DOMAIN:-}

  valid_port "$VMESS_PORT" || die "VMESS_PORT 无效"
  valid_port "$SS_PORT" || die "SS_PORT 无效"
  valid_port "$REALITY_PORT" || die "REALITY_PORT 无效"
  validate_domain "$VMESS_ADDRESS" || die "VMESS_ADDRESS 无效"
  [[ $VMESS_PORT != "$SS_PORT" && $VMESS_PORT != "$REALITY_PORT" && $SS_PORT != "$REALITY_PORT" ]] || die "三个端口不能重复"
  validate_domain "$REALITY_SERVER_NAME" || die "REALITY_SERVER_NAME 无效"
  [[ $ARGO_MODE == quick || $ARGO_MODE == token ]] || die "ARGO_MODE 只能是 quick 或 token"
  if [[ $ARGO_MODE == token ]]; then
    [[ -n $ARGO_TOKEN ]] || die "token 模式必须设置 ARGO_TOKEN"
    [[ $ARGO_TOKEN =~ ^[A-Za-z0-9._-]+$ ]] || die "ARGO_TOKEN 包含非法字符"
    validate_domain "$ARGO_DOMAIN" || die "token 模式必须设置有效 ARGO_DOMAIN"
  else
    [[ -z $ARGO_TOKEN && -z $ARGO_DOMAIN ]] || die "quick 模式不要设置 ARGO_TOKEN/ARGO_DOMAIN"
  fi

  install_packages
  need_cmd ss; need_cmd sha256sum; need_cmd base64
  port_free "$VMESS_PORT" || die "端口 $VMESS_PORT 已占用"
  port_free "$SS_PORT" || die "端口 $SS_PORT 已占用"
  port_free "$REALITY_PORT" || die "端口 $REALITY_PORT 已占用"
  detect_arch
  install_binaries
  create_users
  write_config
  /usr/local/bin/xray run -test -config "$APP_DIR/xray.json"
  write_units
  ln -sf "$APP_DIR/install.sh" /usr/local/sbin/$APP
  install -m 0700 "$0" "$APP_DIR/install.sh"
  systemctl daemon-reload
  systemctl enable --now xray-lite.service cloudflared-lite.service
  sleep 3
  systemctl is-active --quiet xray-lite.service || die "Xray 启动失败，请运行 journalctl -u xray-lite"
  write_client_info
  cat "$APP_DIR/client-info.txt"
  log "完成。公网防火墙需开放 $SS_PORT/tcp+udp 和 $REALITY_PORT/tcp；不要开放 $VMESS_PORT。"
}

do_show() { need_root; write_client_info; cat "$APP_DIR/client-info.txt"; }

do_status() {
  need_root
  systemctl --no-pager --full status xray-lite.service cloudflared-lite.service || true
  ss -lntup | grep -E 'xray|cloudflared' || true
}

do_repair_argo() {
  need_root
  [[ -r $APP_DIR/state ]] || die "尚未安装"
  local started domain="" attempt
  install -d -m 0755 /etc/systemd/system/cloudflared-lite.service.d
  printf '[Unit]\nPartOf=xray-lite.service\n' > /etc/systemd/system/cloudflared-lite.service.d/10-xray-restart.conf
  systemctl daemon-reload
  started=$(date --iso-8601=seconds)
  systemctl restart xray-lite.service
  systemctl restart cloudflared-lite.service
  systemctl is-active --quiet xray-lite.service || die "Xray 启动失败，请检查 journalctl -u xray-lite"

  if grep -qx 'ARGO_MODE=quick' "$APP_DIR/state"; then
    attempt=1
    while (( attempt <= 15 )); do
      domain=$(quick_domain_since "$started")
      [[ -n $domain ]] && break
      sleep 2
      attempt=$((attempt + 1))
    done
    [[ -n $domain ]] || die "30 秒内未获取到 Quick Tunnel 域名，请检查 journalctl -u cloudflared-lite"
    log "新的 Quick Tunnel 域名: $domain"
  else
    attempt=1
    while (( attempt <= 15 )); do
      systemctl is-active --quiet cloudflared-lite.service && break
      sleep 2
      attempt=$((attempt + 1))
    done
    systemctl is-active --quiet cloudflared-lite.service || die "命名 Tunnel 启动失败，请检查 journalctl -u cloudflared-lite"
  fi

  write_client_info
  cat "$APP_DIR/client-info.txt"
}

do_uninstall() {
  need_root
  systemctl disable --now cloudflared-lite.service xray-lite.service 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared-lite.service /etc/systemd/system/xray-lite.service /usr/local/sbin/$APP
  rm -rf -- /etc/systemd/system/cloudflared-lite.service.d
  rm -rf -- "$APP_DIR"
  systemctl daemon-reload
  log "已删除配置和访问凭据。保留 /usr/local/bin/xray、cloudflared 及系统账户。"
}

case ${1:-install} in
  install) do_install ;;
  show) do_show ;;
  status) do_status ;;
  repair-argo) do_repair_argo ;;
  uninstall) do_uninstall ;;
  *) die "用法: $0 {install|show|status|repair-argo|uninstall}" ;;
esac
