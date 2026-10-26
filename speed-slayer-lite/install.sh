#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP="speed-slayer-lite"
readonly APP_DIR="/etc/${APP}"
readonly SCRIPT_URL="https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh"
readonly XRAY_VERSION="26.3.27"
readonly CLOUDFLARED_VERSION="2026.7.3"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

valid_reality_port() { [[ $1 == 443 ]] || valid_port "$1"; }

valid_xhttp_path() { [[ $1 =~ ^/[A-Za-z0-9/_-]{1,128}$ ]]; }

validate_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

encode_ss2022_password() {
  printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'
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
  local min_version
  [[ -r /etc/os-release ]] || die "无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-} in
    debian) min_version=11 ;;
    ubuntu) min_version=20.04 ;;
    *) die "仅支持 Debian/Ubuntu" ;;
  esac
  need_cmd dpkg
  dpkg --compare-versions "${VERSION_ID:-0}" ge "$min_version" || die "仅支持 Debian 11+、Ubuntu 20.04+"
  need_cmd systemctl
  [[ -d /run/systemd/system ]] || die "当前环境未运行 systemd"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip openssl iproute2
}

install_binaries() (
  local tmp xray_zip
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
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
)

install_self() {
  local destination=${1:-$APP_DIR/install.sh} tmp
  tmp=$(mktemp "$APP_DIR/installer.XXXXXX")
  if [[ -f ${BASH_SOURCE[0]:-$0} ]]; then
    cp "${BASH_SOURCE[0]:-$0}" "$tmp"
  else
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      "$SCRIPT_URL" -o "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  bash -n "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0700 "$tmp"
  mv -f "$tmp" "$destination"
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
  VLESS_UUID=$(xray uuid)
  WS_PATH="/$(openssl rand -hex 12)"
  XHTTP_PATH=${XHTTP_PATH:-/$(openssl rand -hex 16)}
  valid_xhttp_path "$XHTTP_PATH" || die "XHTTP_PATH 无效"
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
      "tag": "reality-guard",
      "listen": "127.0.0.1",
      "port": $REALITY_GUARD_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "$REALITY_SERVER_NAME",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
    {
      "tag": "vless-reality",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$VLESS_UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XHTTP_PATH", "mode": "auto" },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:$REALITY_GUARD_PORT",
          "serverNames": ["$REALITY_SERVER_NAME"],
          "privateKey": "$REALITY_PRIVATE",
          "shortIds": ["$REALITY_SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["reality-guard"],
        "domain": ["full:$REALITY_SERVER_NAME"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["reality-guard"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
  chown root:xray "$APP_DIR/xray.json"
  chmod 0640 "$APP_DIR/xray.json"

  cat >"$APP_DIR/state" <<EOF
VMESS_PORT=$VMESS_PORT
SS_PORT=$SS_PORT
REALITY_PORT=$REALITY_PORT
REALITY_GUARD_PORT=$REALITY_GUARD_PORT
VMESS_ADDRESS=$VMESS_ADDRESS
VMESS_UUID=$VMESS_UUID
VLESS_UUID=$VLESS_UUID
WS_PATH=$WS_PATH
VLESS_TRANSPORT=xhttp
XHTTP_PATH=$XHTTP_PATH
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

render_xray_unit() {
  cat <<EOF
[Unit]
Description=Xray for Speed Slayer Lite
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
$(if [[ $REALITY_PORT == 443 ]]; then printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'; fi)
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
}

write_units() {
  render_xray_unit >/etc/systemd/system/xray-lite.service

  local cf_exec cf_env=""
  if [[ $ARGO_MODE == token ]]; then
    cf_env="EnvironmentFile=$APP_DIR/cloudflared.env"
    cf_exec="/usr/local/bin/cloudflared --no-autoupdate tunnel run"
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
  local invocation_id
  invocation_id=$(systemctl show cloudflared-lite.service --property=InvocationID --value 2>/dev/null || true)
  [[ -n $invocation_id ]] || return 0
  journalctl -u cloudflared-lite.service "_SYSTEMD_INVOCATION_ID=$invocation_id" --no-pager 2>/dev/null |
    sed -nE 's#.*https://([-a-z0-9]+\.trycloudflare\.com).*#\1#p' | tail -n1 || true
}

wait_for_quick_domain() {
  local attempt=1 domain
  while (( attempt <= 15 )); do
    domain=$(quick_domain)
    [[ -n $domain ]] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

write_client_info() {
  [[ -r $APP_DIR/state ]] || die "尚未安装"
  # State is generated internally and root-only; validate every field before use.
  local requested_address=${VMESS_ADDRESS:-} key value server domain vmess_json vmess_uri ss_password_uri ss_uri reality_uri reality_label
  # Old installed state still represents a TCP/Vision node until explicit migration.
  local VLESS_TRANSPORT=tcp XHTTP_PATH=''
  while IFS='=' read -r key value; do
    case $key in
      VMESS_PORT|SS_PORT|REALITY_PORT|REALITY_GUARD_PORT|VMESS_ADDRESS|VMESS_UUID|VLESS_UUID|WS_PATH|VLESS_TRANSPORT|XHTTP_PATH|SS_PASSWORD|REALITY_SERVER_NAME|REALITY_PUBLIC|REALITY_SHORT_ID|ARGO_MODE|ARGO_DOMAIN)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$APP_DIR/state"
  server=$(public_ip)
  if [[ $server == *:* && $server != \[*\] ]]; then server="[$server]"; fi
  domain=${ARGO_DOMAIN:-}
  if [[ ${ARGO_MODE:-} == quick ]]; then domain=$(quick_domain); fi
  domain=${domain:-QUICK_TUNNEL_STARTING}
  VMESS_ADDRESS=${requested_address:-${VMESS_ADDRESS:-www.wto.org}}
  VLESS_UUID=${VLESS_UUID:-$VMESS_UUID}
  validate_domain "$VMESS_ADDRESS" || die "VMESS_ADDRESS 无效"

  vmess_json=$(printf '{"v":"2","ps":"vmess-argo","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$VMESS_ADDRESS" "$VMESS_UUID" "$domain" "$WS_PATH" "$domain")
  vmess_uri="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
  ss_password_uri=$(encode_ss2022_password "$SS_PASSWORD")
  ss_uri="ss://2022-blake3-aes-128-gcm:${ss_password_uri}@${server}:${SS_PORT}#ss2022"
  reality_uri=$(vless_uri "$server" "$VLESS_TRANSPORT" "$XHTTP_PATH")
  if [[ $VLESS_TRANSPORT == xhttp ]]; then reality_label='VLESS + XHTTP + REALITY'; else reality_label='VLESS + TCP + REALITY + Vision（尚未迁移）'; fi

  cat >"$APP_DIR/client-info.txt" <<EOF
VMess + WS + Argo
$vmess_uri

Shadowsocks 2022
$ss_uri

$reality_label
$reality_uri

提示：此文件包含全部访问凭据，仅保存在服务器本机。
EOF
  chmod 0600 "$APP_DIR/client-info.txt"
}

vless_uri() {
  local server=$1 transport=$2 path=${3:-} options label
  case $transport in
    xhttp)
      valid_xhttp_path "$path" || die 'XHTTP 路径无效；请检查 state 或执行 migrate-xhttp。'
      options="type=xhttp&mode=auto&path=${path//\//%2F}"
      label=vless-xhttp-reality ;;
    tcp|raw)
      options='type=tcp&flow=xtls-rprx-vision'
      label=vless-reality ;;
    *) die "不支持的 VLESS_TRANSPORT: $transport" ;;
  esac
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&%s#%s\n' \
    "$VLESS_UUID" "$server" "$REALITY_PORT" "$REALITY_SERVER_NAME" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$options" "$label"
}

remove_services_and_config() {
  systemctl disable --now cloudflared-lite.service xray-lite.service 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared-lite.service /etc/systemd/system/xray-lite.service /usr/local/sbin/$APP
  rm -rf -- /etc/systemd/system/cloudflared-lite.service.d "$APP_DIR"
  systemctl daemon-reload
}

rollback_install() {
  local status=$?
  trap - EXIT
  (( status != 0 )) || return 0
  log "安装失败，正在清理本次生成的服务、配置和访问凭据"
  remove_services_and_config || true
  exit "$status"
}

do_install() {
  need_root
  [[ ! -e $APP_DIR/state ]] || die "已安装；切换为 XHTTP 请用 $APP migrate-xhttp；全新重装请先 uninstall。"
  VMESS_PORT=${VMESS_PORT:-30000}
  SS_PORT=${SS_PORT:-30001}
  REALITY_PORT=${REALITY_PORT:-30002}
  REALITY_GUARD_PORT=${REALITY_GUARD_PORT:-30003}
  VMESS_ADDRESS=${VMESS_ADDRESS:-www.wto.org}
  REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-learn.microsoft.com}
  ARGO_MODE=${ARGO_MODE:-quick}
  ARGO_TOKEN=${ARGO_TOKEN:-}
  ARGO_DOMAIN=${ARGO_DOMAIN:-}

  valid_port "$VMESS_PORT" || die "VMESS_PORT 无效"
  valid_port "$SS_PORT" || die "SS_PORT 无效"
  valid_reality_port "$REALITY_PORT" || die "REALITY_PORT 只能为 443 或 1024–65535"
  [[ -z ${XHTTP_PATH:-} ]] || valid_xhttp_path "$XHTTP_PATH" || die "XHTTP_PATH 必须以 / 开头，后接 1–128 个字母、数字、/、_ 或 -"
  valid_port "$REALITY_GUARD_PORT" || die "REALITY_GUARD_PORT 无效"
  validate_domain "$VMESS_ADDRESS" || die "VMESS_ADDRESS 无效"
  [[ $VMESS_PORT != "$SS_PORT" && $VMESS_PORT != "$REALITY_PORT" && $VMESS_PORT != "$REALITY_GUARD_PORT" && $SS_PORT != "$REALITY_PORT" && $SS_PORT != "$REALITY_GUARD_PORT" && $REALITY_PORT != "$REALITY_GUARD_PORT" ]] || die "端口不能重复"
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
  port_free "$REALITY_GUARD_PORT" || die "端口 $REALITY_GUARD_PORT 已占用"
  detect_arch
  install_binaries
  trap rollback_install EXIT
  create_users
  write_config
  /usr/local/bin/xray run -test -config "$APP_DIR/xray.json"
  write_units
  install_self
  ln -sf "$APP_DIR/install.sh" /usr/local/sbin/$APP
  systemctl daemon-reload
  systemctl enable --now xray-lite.service cloudflared-lite.service
  systemctl is-active --quiet xray-lite.service || die "Xray 启动失败，请运行 journalctl -u xray-lite"
  systemctl is-active --quiet cloudflared-lite.service || die "cloudflared 启动失败，请运行 journalctl -u cloudflared-lite"
  if [[ $ARGO_MODE == quick ]] && ! wait_for_quick_domain; then
    log "警告：尚未读取到 Quick Tunnel 域名，可稍后运行 speed-slayer-lite show"
  fi
  write_client_info
  trap - EXIT
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
  local domain="" attempt
  install -d -m 0755 /etc/systemd/system/cloudflared-lite.service.d
  printf '[Unit]\nPartOf=xray-lite.service\n' > /etc/systemd/system/cloudflared-lite.service.d/10-xray-restart.conf
  systemctl daemon-reload
  systemctl restart xray-lite.service
  systemctl restart cloudflared-lite.service
  systemctl is-active --quiet xray-lite.service || die "Xray 启动失败，请检查 journalctl -u xray-lite"
  systemctl is-active --quiet cloudflared-lite.service || die "cloudflared 启动失败，请检查 journalctl -u cloudflared-lite"

  if grep -qx 'ARGO_MODE=quick' "$APP_DIR/state"; then
    attempt=1
    while (( attempt <= 15 )); do
      domain=$(quick_domain)
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

prepare_xhttp_migration() {
  python3 - "$APP_DIR" "$1" <<'PY'
import json, pathlib, re, secrets, sys
root, stage = map(pathlib.Path, sys.argv[1:])
config = json.loads((root / 'xray.json').read_text(encoding='utf-8'))
lines = (root / 'state').read_text(encoding='utf-8').splitlines()
state = {}
for line in lines:
    key, sep, value = line.partition('=')
    if not sep or key in state:
        sys.exit('state 格式错误或存在重复字段；未修改配置。')
    state[key] = value
nodes = [n for n in config.get('inbounds', []) if n.get('tag') == 'vless-reality']
if len(nodes) != 1:
    sys.exit('未找到唯一的 Lite vless-reality 入站；未修改配置。')
node = nodes[0]
stream = node.get('streamSettings', {})
settings = node.get('settings', {})
if (node.get('protocol') != 'vless' or stream.get('security') != 'reality' or
    stream.get('network', 'raw') not in ('raw', 'tcp', 'xhttp') or
    settings.get('decryption', 'none') != 'none'):
    sys.exit('仅支持普通 VLESS TCP/XHTTP + REALITY 入站迁移。')
clients = settings.get('clients', [])
if not clients or any(c.get('flow', '') not in ('', 'xtls-rprx-vision') for c in clients):
    sys.exit('入站客户端或 flow 配置不受支持。')
uuid = state.get('VLESS_UUID', state.get('VMESS_UUID'))
if (not uuid or uuid not in [c.get('id') for c in clients] or
    str(node.get('port')) != state.get('REALITY_PORT')):
    sys.exit('state 与 Xray UUID/端口不一致，拒绝生成错误的节点链接。')
if stream.get('network') == 'xhttp':
    xhttp = stream.get('xhttpSettings', {})
    if set(xhttp) - {'path', 'mode'} or xhttp.get('mode', 'auto') != 'auto':
        sys.exit('已有自定义 XHTTP 参数，拒绝覆盖；请手动维护。')
    path = xhttp.get('path', '')
else:
    path = '/' + secrets.token_hex(16)
if not re.fullmatch(r'/[A-Za-z0-9/_-]{1,128}', path):
    sys.exit('XHTTP 路径不受支持。')
for client in clients:
    client.pop('flow', None)
stream['network'] = 'xhttp'
stream['xhttpSettings'] = {'path': path, 'mode': 'auto'}
stream.pop('tcpSettings', None)
stream.pop('rawSettings', None)
state['VLESS_TRANSPORT'] = 'xhttp'
state['XHTTP_PATH'] = path
state['VLESS_UUID'] = uuid
with (stage / 'next.json').open('w', encoding='utf-8', newline='\n') as output:
    output.write(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
with (stage / 'next.state').open('w', encoding='utf-8', newline='\n') as output:
    output.write(''.join(f'{k}={v}\n' for k, v in state.items()))
PY
}

do_migrate_xhttp() (
  need_root
  [[ -r $APP_DIR/state && -r $APP_DIR/xray.json && -r $APP_DIR/install.sh ]] || die '尚未完整安装 Lite。'
  need_cmd xray; need_cmd systemctl; need_cmd flock
  # Keep simultaneous migrations from restoring each other's snapshots.
  exec 9>"$APP_DIR/migrate-xhttp.lock"
  flock -n 9 || die '另一项 XHTTP 迁移仍在运行。'
  if ! command -v python3 >/dev/null 2>&1; then
    need_cmd apt-get
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3
  fi
  systemctl is-active --quiet xray-lite.service || die 'Xray 未运行；请先排查现有服务。'
  # Subshell-scoped variables survive function unwinding for the EXIT trap.
  backup=''
  changed=0
  backup=$(mktemp -d "$APP_DIR/backup-xhttp-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$backup"
  cp -p "$APP_DIR/xray.json" "$backup/xray.json"
  cp -p "$APP_DIR/state" "$backup/state"
  cp -p "$APP_DIR/install.sh" "$backup/install.sh"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$backup/client-info.txt"; fi

  rollback_xhttp() {
    local status=$? rollback_failed=0
    trap - EXIT INT TERM
    if (( status != 0 && changed == 1 )); then
      log "迁移失败，正在恢复 $backup 中的配置与脚本"
      cp -p "$backup/xray.json" "$APP_DIR/xray.json" || rollback_failed=1
      cp -p "$backup/state" "$APP_DIR/state" || rollback_failed=1
      cp -p "$backup/install.sh" "$APP_DIR/install.sh" || rollback_failed=1
      if [[ -f $backup/client-info.txt ]]; then
        cp -p "$backup/client-info.txt" "$APP_DIR/client-info.txt" || rollback_failed=1
      else
        rm -f "$APP_DIR/client-info.txt" || rollback_failed=1
      fi
      systemctl restart xray-lite.service || rollback_failed=1
      systemctl is-active --quiet xray-lite.service || rollback_failed=1
      (( rollback_failed == 0 )) || log "自动恢复未完成，请通过控制台检查备份 $backup 与 journalctl -u xray-lite。"
      log "Quick Tunnel 域名可能已变化；恢复后运行 $APP show 刷新链接。"
    fi
    exit "$status"
  }
  trap rollback_xhttp EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  prepare_xhttp_migration "$backup"
  xray run -test -config "$backup/next.json"
  install_self "$backup/next.install.sh"
  chown root:xray "$backup/next.json"
  chmod 0640 "$backup/next.json"
  chmod 0600 "$backup/next.state"
  changed=1
  mv -f "$backup/next.json" "$APP_DIR/xray.json"
  mv -f "$backup/next.state" "$APP_DIR/state"
  mv -f "$backup/next.install.sh" "$APP_DIR/install.sh"
  systemctl restart xray-lite.service
  systemctl is-active --quiet xray-lite.service || die '迁移后 Xray 未正常启动。'
  # PartOf=xray-lite may restart the Tunnel and rotate its temporary hostname.
  if grep -qx 'ARGO_MODE=quick' "$APP_DIR/state" && ! wait_for_quick_domain; then
    log "尚未读到 Quick Tunnel 域名；稍后运行 $APP show。"
  fi
  write_client_info
  changed=0
  trap - EXIT INT TERM
  log "已切换为 XHTTP + REALITY；端口和凭据保留，原配置备份：$backup"
  cat "$APP_DIR/client-info.txt"
  log '请重新导入 VLESS 链接；如 Quick Tunnel 域名变化，也重新导入 VMess 链接。'
)

run_brutal() (
  local source_path local_manager tmp
  source_path="$(readlink -f "${BASH_SOURCE[0]}")"
  local_manager="$(dirname "$source_path")/../scripts/tcp-brutal.sh"
  if [ -s "$local_manager" ]; then
    bash "$local_manager" "$@"
  elif [ "${1:-menu}" != install ] && [ -s /usr/local/lib/speed-slayer/tcp-brutal.sh ]; then
    bash /usr/local/lib/speed-slayer/tcp-brutal.sh "$@"
  else
    tmp="$(mktemp)" || return 1
    trap 'rm -f -- "$tmp"' EXIT
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
      'https://raw.githubusercontent.com/Benjpsusu/speed-slayer/main/scripts/tcp-brutal.sh' -o "$tmp" || return 1
    printf '%s  %s\n' 'f2a0feea7767f2059dd5d9474b22f69fe8e21a4d145a92ba65e356925783ee5c' "$tmp" | sha256sum -c - || return 1
    bash -n "$tmp" && bash "$tmp" "$@"
  fi
)

do_uninstall() {
  need_root
  remove_services_and_config
  log "已删除配置和访问凭据。保留 /usr/local/bin/xray、cloudflared 及系统账户。"
  log "共享 Brutal 独立保留；停用用 speed-brutal disable，移除管理器用 speed-brutal uninstall。"
}

main() {
  case ${1:-install} in
    install) do_install ;;
    show) do_show ;;
    status) do_status ;;
    repair-argo) do_repair_argo ;;
    migrate-xhttp) do_migrate_xhttp ;;
    brutal) shift; run_brutal "$@" ;;
    uninstall) do_uninstall ;;
    *) die "用法: $0 {install|show|status|repair-argo|migrate-xhttp|brutal [command]|uninstall}" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
