#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP="speed-slayer-lite"
readonly APP_DIR="/etc/${APP}"
readonly BIN_DIR="/usr/local/bin"
readonly UNIT_DIR="/etc/systemd/system"
readonly SHORTCUT="/usr/local/sbin/${APP}"
readonly SCRIPT_URL="https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh"
readonly XRAY_VERSION="26.10.21"
readonly CLOUDFLARED_VERSION="2026.10.3"
readonly SINGBOX_VERSION="1.14.4"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 执行'; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
valid_reality_port() { [[ $1 == 443 ]] || valid_port "$1"; }
valid_xhttp_path() { [[ $1 =~ ^/[A-Za-z0-9/_-]{1,128}$ ]]; }
validate_domain() {
  [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
encode_ss2022_password() { printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'; }
port_free() { ! ss -H -lntup "sport = :$1" 2>/dev/null | grep -q .; }

set_protocols() {
  local value=$1 item
  local -a items=()
  [[ -n $value && $value != ,* && $value != *, && $value != *,,* ]] || return 1
  ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0
  IFS=',' read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    case $item in
      vmess) ENABLE_VMESS=1 ;;
      ss2022) ENABLE_SS2022=1 ;;
      vless) ENABLE_VLESS=1 ;;
      anytls) ENABLE_ANYTLS=1 ;;
      *) return 1 ;;
    esac
  done
  PROTOCOLS=''
  [[ $ENABLE_VMESS == 0 ]] || PROTOCOLS='vmess'
  [[ $ENABLE_SS2022 == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}ss2022"
  [[ $ENABLE_VLESS == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}vless"
  [[ $ENABLE_ANYTLS == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}anytls"
  [[ -n $PROTOCOLS ]]
}

protocol_enabled() {
  case $1 in
    vmess) [[ ${ENABLE_VMESS:-1} == 1 ]] ;;
    ss2022) [[ ${ENABLE_SS2022:-1} == 1 ]] ;;
    vless) [[ ${ENABLE_VLESS:-1} == 1 ]] ;;
    anytls) [[ ${ENABLE_ANYTLS:-0} == 1 ]] ;;
    *) return 1 ;;
  esac
}

xray_enabled() { protocol_enabled vmess || protocol_enabled ss2022 || protocol_enabled vless; }

load_state() {
  [[ -r $APP_DIR/state ]] || die '尚未安装，请先从菜单创建节点。'
  local key value stored_protocols='vmess,ss2022,vless'
  local -A seen=()
  VMESS_PORT='' SS_PORT='' REALITY_PORT='' REALITY_GUARD_PORT=''
  VMESS_ADDRESS='' VMESS_UUID='' VLESS_UUID='' WS_PATH='' SS_PASSWORD=''
  VLESS_TRANSPORT=tcp XHTTP_PATH='' REALITY_SERVER_NAME='' REALITY_PUBLIC='' REALITY_SHORT_ID=''
  ARGO_MODE='' ARGO_DOMAIN=''
  ANYTLS_PORT='' ANYTLS_SERVER_NAME='' ANYTLS_PASSWORD='' ANYTLS_CERT_MODE=''
  ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL=''
  while IFS='=' read -r key value; do
    [[ -n $key && ! ${seen[$key]+yes} ]] || die 'state 包含空字段或重复字段。'
    seen[$key]=1
    case $key in
      PROTOCOLS) stored_protocols=$value ;;
      VMESS_PORT|SS_PORT|REALITY_PORT|REALITY_GUARD_PORT|VMESS_ADDRESS|VMESS_UUID|VLESS_UUID|WS_PATH|VLESS_TRANSPORT|XHTTP_PATH|SS_PASSWORD|REALITY_SERVER_NAME|REALITY_PUBLIC|REALITY_SHORT_ID|ARGO_MODE|ARGO_DOMAIN|ANYTLS_PORT|ANYTLS_SERVER_NAME|ANYTLS_PASSWORD|ANYTLS_CERT_MODE|ANYTLS_CERT_FILE|ANYTLS_KEY_FILE|ANYTLS_EMAIL)
        printf -v "$key" '%s' "$value" ;;
    esac
  done <"$APP_DIR/state"
  set_protocols "$stored_protocols" || die 'state 中的协议选择无效。'
  # Older releases installed all protocols and sometimes shared the VLESS UUID.
  VLESS_UUID=${VLESS_UUID:-$VMESS_UUID}
}

download_checked() {
  local url=$1 output=$2 expected=$3 actual
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 300 --output "$output" "$url"
  actual=$(sha256sum "$output" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "SHA-256 校验失败: $url"
}

detect_arch() {
  case $(uname -m) in
    x86_64|amd64)
      XRAY_ARCH=64 CF_ARCH=amd64
      XRAY_SHA=0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978
      CF_SHA=053b80b0a23031a038fdbf3c073f59f82b8f1f152aa67971d7383ffafc0dbab0 ;;
    aarch64|arm64)
      XRAY_ARCH=arm64-v8a CF_ARCH=arm64
      XRAY_SHA=d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c
      CF_SHA=89297ebfb9e8c99c0dc013a1140601453cf3798d8306c5591651f4a3f5210be8 ;;
    *) die '仅支持 amd64 和 arm64' ;;
  esac
  SB_ARCH=$CF_ARCH
  case $SB_ARCH in
    amd64) SB_SHA=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
    arm64) SB_SHA=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
  esac
  if protocol_enabled anytls; then
    [[ $(uname -s) == Linux ]] || die 'AnyTLS 服务端安装仅支持 Linux。'
    log "Linux $(uname -r) / $SB_ARCH：AnyTLS 使用独立 sing-box $SINGBOX_VERSION，不更换 Linux 内核。"
    if command -v sing-box >/dev/null 2>&1; then log '发现已有 sing-box；保留原程序，Lite 使用自己目录中的二进制。'; fi
  fi
}

install_packages() {
  local min_version
  [[ -r /etc/os-release ]] || die '无法识别系统'
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-} in
    debian) min_version=11 ;;
    ubuntu) min_version=20.04 ;;
    *) die '仅支持 Debian/Ubuntu' ;;
  esac
  need_cmd dpkg
  dpkg --compare-versions "${VERSION_ID:-0}" ge "$min_version" || die '仅支持 Debian 11+、Ubuntu 20.04+'
  need_cmd systemctl
  [[ -d /run/systemd/system ]] || die '当前环境未运行 systemd'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip openssl iproute2 python3 tar util-linux
}

stage_binaries() {
  local stage=$1
  mkdir -p "$stage"
  if xray_enabled; then
    download_checked "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" "$stage/xray.zip" "$XRAY_SHA"
    unzip -q "$stage/xray.zip" xray -d "$stage"
    chmod 0755 "$stage/xray"
    "$stage/xray" version
  fi
  if protocol_enabled vmess; then
    download_checked "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}" "$stage/cloudflared" "$CF_SHA"
    chmod 0755 "$stage/cloudflared"
    "$stage/cloudflared" --version
  fi
  if protocol_enabled anytls; then stage_anytls_binary "$stage"; fi
}

replace_binary() {
  local source=$1 destination=$2 staged
  staged=$(mktemp "${destination}.new.XXXXXX") || return 1
  if ! install -m 0755 "$source" "$staged" || ! mv -f "$staged" "$destination"; then
    rm -f -- "$staged"
    return 1
  fi
}

install_binaries() (
  stage=$(mktemp -d)
  trap 'rm -rf -- "$stage"' EXIT
  stage_binaries "$stage"
  if xray_enabled; then replace_binary "$stage/xray" "$BIN_DIR/xray"; fi
  if protocol_enabled vmess; then replace_binary "$stage/cloudflared" "$BIN_DIR/cloudflared"; fi
  if protocol_enabled anytls; then
    install -d -m 0755 "$APP_DIR/bin"
    replace_binary "$stage/sing-box" "$APP_DIR/bin/sing-box"
  fi
)

install_self() {
  local destination=${1:-$APP_DIR/install.sh} tmp
  tmp=$(mktemp "$APP_DIR/installer.XXXXXX")
  if [[ -f ${BASH_SOURCE[0]:-$0} ]]; then
    cp "${BASH_SOURCE[0]}" "$tmp"
  else
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  bash -n "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0700 "$tmp"
  mv -f "$tmp" "$destination"
}

create_users() {
  if xray_enabled; then
    getent group xray >/dev/null || groupadd --system xray
    id xray >/dev/null 2>&1 || useradd --system --gid xray --home-dir /var/lib/xray --shell /usr/sbin/nologin xray
    install -d -m 0750 -o root -g xray "$APP_DIR" /var/lib/xray
  fi
  if protocol_enabled anytls; then create_anytls_user; fi
  if protocol_enabled vmess; then
    getent group cloudflared >/dev/null || groupadd --system cloudflared
    id cloudflared >/dev/null 2>&1 || useradd --system --gid cloudflared --home-dir /var/lib/cloudflared --shell /usr/sbin/nologin cloudflared
    install -d -m 0750 -o cloudflared -g cloudflared /var/lib/cloudflared
  fi
}

stage_anytls_binary() {
  local stage=$1 archive="sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}"
  mkdir -p "$stage"
  download_checked "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive}.tar.gz" "$stage/sing-box.tar.gz" "$SB_SHA"
  # Extract only the known binary from the verified release, never arbitrary paths.
  tar -xzf "$stage/sing-box.tar.gz" -C "$stage" --strip-components=1 "$archive/sing-box"
  chmod 0755 "$stage/sing-box"
  "$stage/sing-box" version
}

create_anytls_user() {
  getent group speed-anytls >/dev/null || groupadd --system speed-anytls
  id speed-anytls >/dev/null 2>&1 || useradd --system --gid speed-anytls --home-dir /nonexistent --shell /usr/sbin/nologin speed-anytls
  # Both low-privilege service users may traverse; secrets remain 0600/0640.
  mkdir -p "$APP_DIR"
  chmod 0711 "$APP_DIR"
  install -d -m 0750 -o root -g speed-anytls "$APP_DIR/tls"
  install -d -m 0700 -o speed-anytls -g speed-anytls "$APP_DIR/acme"
}

configure_anytls() {
  local value default_port=443
  if { protocol_enabled vless && [[ ${REALITY_PORT:-443} == 443 ]]; } || ! port_free 443; then default_port=8443; fi
  log 'AnyTLS 需要自己的域名；SNI 与证书域名相同。域名请使用仅 DNS 解析到本机。'
  while true; do
    read -r -p "AnyTLS 域名/SNI [${ANYTLS_SERVER_NAME:-}]: " value || return 1
    value=${value:-${ANYTLS_SERVER_NAME:-}}
    if validate_domain "$value"; then ANYTLS_SERVER_NAME=$value; break; fi
    log '请输入有效的域名，不含协议、路径或端口。'
  done
  while true; do
    read -r -p "AnyTLS TCP 端口 [${ANYTLS_PORT:-$default_port}]: " value || return 1
    value=${value:-${ANYTLS_PORT:-$default_port}}
    if valid_reality_port "$value"; then ANYTLS_PORT=$value; break; fi
    log '端口应为 443 或 1024–65535。'
  done
  while true; do
    printf '证书方式：1. 自动申请/续期（需独占并开放 TCP 80）  2. 已有可信证书\n'
    log "选择自动申请表示使用 Let's Encrypt 服务及其条款；80 被网站占用时请选择已有证书。"
    read -r -p '请选择 [1]: ' value || return 1
    case ${value:-1} in
      1)
        ANYTLS_CERT_MODE=acme ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE=''
        read -r -p '证书联系邮箱: ' ANYTLS_EMAIL || return 1
        break ;;
      2)
        ANYTLS_CERT_MODE=file ANYTLS_EMAIL=''
        read -r -p '完整证书链 PEM 的绝对路径: ' ANYTLS_CERT_FILE || return 1
        read -r -p '私钥 PEM 的绝对路径: ' ANYTLS_KEY_FILE || return 1
        break ;;
      *) log '请输入 1 或 2。' ;;
    esac
  done
}

validate_anytls_options() {
  ANYTLS_PORT=${ANYTLS_PORT:-8443}
  ANYTLS_CERT_MODE=${ANYTLS_CERT_MODE:-acme}
  validate_domain "${ANYTLS_SERVER_NAME:-}" || die 'AnyTLS 必须设置自己的 ANYTLS_SERVER_NAME 域名。'
  valid_reality_port "$ANYTLS_PORT" || die 'ANYTLS_PORT 只能为 443 或 1024–65535'
  ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-}
  [[ -z $ANYTLS_PASSWORD || $ANYTLS_PASSWORD =~ ^[a-fA-F0-9]{64}$ ]] || die 'ANYTLS_PASSWORD 应为 64 位十六进制；留空自动生成。'
  case $ANYTLS_CERT_MODE in
    acme)
      [[ ${ANYTLS_EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die '自动证书需设置有效 ANYTLS_EMAIL'
      ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ;;
    file)
      local file
      for file in "${ANYTLS_CERT_FILE:-}" "${ANYTLS_KEY_FILE:-}"; do
        [[ $file == /* && $file != *$'\n'* && $file != *$'\r'* && -r $file ]] || die '证书和私钥必须是可读的绝对路径。'
        [[ $file != "$APP_DIR/"* ]] || die '源证书请保存在 Lite 目录外，以便卸载后保留。'
      done
      ANYTLS_EMAIL='' ;;
    *) die 'ANYTLS_CERT_MODE 只接受 acme 或 file' ;;
  esac
}

check_anytls_certificate() {
  local certificate=$1 key=$2
  openssl x509 -in "$certificate" -noout -checkend 86400 >/dev/null || die '证书已过期或将在 24 小时内过期。'
  # Some OpenSSL versions return 0 even when -checkhost reports a mismatch.
  openssl x509 -in "$certificate" -noout -checkhost "$ANYTLS_SERVER_NAME" |
    grep -Fx "Hostname $ANYTLS_SERVER_NAME does match certificate" >/dev/null || die '证书域名与 AnyTLS SNI 不匹配。'
  python3 - "$certificate" "$key" <<'PY'
import ssl, sys
# Validate PEM syntax, key pairing and server-side TLS suitability without a prompt.
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2], password=lambda: '')
PY
}

copy_anytls_certificate() {
  check_anytls_certificate "$ANYTLS_CERT_FILE" "$ANYTLS_KEY_FILE"
  install -m 0640 -o root -g speed-anytls "$ANYTLS_CERT_FILE" "$APP_DIR/tls/fullchain.pem"
  install -m 0640 -o root -g speed-anytls "$ANYTLS_KEY_FILE" "$APP_DIR/tls/privkey.pem"
}

write_anytls_config() {
  if [[ $ANYTLS_CERT_MODE == file ]]; then copy_anytls_certificate; fi
  python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
tls = {'enabled': True, 'server_name': s['ANYTLS_SERVER_NAME'], 'min_version': '1.2'}
if s['ANYTLS_CERT_MODE'] == 'acme':
    tls['certificate_provider'] = {
        'type': 'acme', 'domain': [s['ANYTLS_SERVER_NAME']],
        'data_directory': str(p/'acme'), 'email': s['ANYTLS_EMAIL'],
        'provider': 'letsencrypt', 'disable_tls_alpn_challenge': True,
    }
else:
    tls.update(certificate_path=str(p/'tls/fullchain.pem'), key_path=str(p/'tls/privkey.pem'))
c = {'log': {'level': 'warn'},
     'inbounds': [{'type': 'anytls', 'tag': 'anytls-in', 'listen': '::',
                   'listen_port': int(s['ANYTLS_PORT']),
                   'users': [{'name': 'lite', 'password': s['ANYTLS_PASSWORD']}], 'tls': tls}],
     'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
(p/'anytls.json').write_bytes((json.dumps(c, ensure_ascii=False, indent=2)+'\n').encode('utf-8'))
PY
  chown root:speed-anytls "$APP_DIR/anytls.json"
  chmod 0640 "$APP_DIR/anytls.json"
}

write_anytls_unit() {
  cat >"$UNIT_DIR/anytls-lite.service" <<EOF
[Unit]
Description=AnyTLS for Speed Slayer Lite (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
User=speed-anytls
Group=speed-anytls
$(if [[ $ANYTLS_PORT == 443 || $ANYTLS_CERT_MODE == acme ]]; then printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'; fi)
ExecStart=$APP_DIR/bin/sing-box run -c $APP_DIR/anytls.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR/acme
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

verify_anytls_tls() {
  log '正在检查 AnyTLS TLS 握手和证书信任（首次自动签发最多等待 120 秒）...'
  python3 - "$ANYTLS_PORT" "$ANYTLS_SERVER_NAME" "$ANYTLS_CERT_MODE" <<'PY'
import socket, ssl, sys, time
port, host, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
deadline = time.monotonic() + (120 if mode == 'acme' else 15)
last = ''
while time.monotonic() < deadline:
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
            with ssl.create_default_context().wrap_socket(sock, server_hostname=host):
                print('AnyTLS TLS certificate verified.')
                sys.exit(0)
    except (OSError, ssl.SSLError) as exc:
        last = str(exc)
        time.sleep(2)
sys.exit('AnyTLS TLS 验证失败；检查域名解析、公网 80、证书链及 journalctl -u anytls-lite：' + last)
PY
}

start_anytls() {
  systemctl enable --now anytls-lite.service
  systemctl is-active --quiet anytls-lite.service || die 'AnyTLS 启动失败，请检查 journalctl -u anytls-lite'
  verify_anytls_tls
}

anytls_instructions() {
  log "AnyTLS：开放 $ANYTLS_PORT/tcp；SNI=$ANYTLS_SERVER_NAME；客户端使用 sing-box/mihomo，开启证书校验。"
  if [[ $ANYTLS_CERT_MODE == acme ]]; then
    log '自动证书使用 HTTP-01：域名必须直指本机，公网 TCP 80 需持续可用供续期。'
  else
    log "已有证书已复制；外部续期后运行 $APP refresh-anytls-cert 安全刷新。"
  fi
}

do_add_anytls() (
  need_root
  # Keep requested options across load_state; never re-generate existing protocols.
  local domain=${ANYTLS_SERVER_NAME:-} port=${ANYTLS_PORT:-} mode=${ANYTLS_CERT_MODE:-}
  local cert=${ANYTLS_CERT_FILE:-} key=${ANYTLS_KEY_FILE:-} email=${ANYTLS_EMAIL:-} password=${ANYTLS_PASSWORD:-}
  [[ -r $APP_DIR/state ]] || die '请先创建 Lite 节点。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled anytls && die '已安装 AnyTLS；更新请选择菜单 4。'
  [[ ! -e $APP_DIR/anytls.json && ! -e $UNIT_DIR/anytls-lite.service && ! -e $APP_DIR/bin/sing-box && ! -e $APP_DIR/tls && ! -e $APP_DIR/acme ]] || die '存在未记录的 AnyTLS 文件，请先检查，拒绝覆盖。'
  ANYTLS_SERVER_NAME=$domain ANYTLS_PORT=$port ANYTLS_CERT_MODE=$mode
  ANYTLS_CERT_FILE=$cert ANYTLS_KEY_FILE=$key ANYTLS_EMAIL=$email ANYTLS_PASSWORD=$password
  if [[ -z $ANYTLS_SERVER_NAME && -t 0 ]]; then configure_anytls || return 0; fi
  set_protocols "$PROTOCOLS,anytls"
  validate_anytls_options
  install_packages
  ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(openssl rand -hex 32)}
  port_free "$ANYTLS_PORT" || die "端口 $ANYTLS_PORT 已占用。"
  if [[ $ANYTLS_CERT_MODE == acme ]]; then port_free 80 || die '80 已占用，请用已有证书方式。'; fi
  local existing
  for existing in "$VMESS_PORT" "$SS_PORT" "$REALITY_PORT" "$REALITY_GUARD_PORT"; do
    [[ -z $existing ]] || (( 10#$existing != 10#$ANYTLS_PORT )) || die 'AnyTLS 与已有节点端口重复。'
  done
  detect_arch
  add_backup=$(mktemp -d "$APP_DIR/backup-anytls-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$add_backup"
  cp -p "$APP_DIR/state" "$APP_DIR/install.sh" "$add_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$add_backup/"; fi
  add_old_mode=$(stat -c %a "$APP_DIR")
  stage_anytls_binary "$add_backup/candidate"
  add_changed=0
  rollback_add_anytls() {
    local status=$?
    trap - EXIT INT TERM
    if (( status != 0 && add_changed == 1 )); then
      log "追加 AnyTLS 失败，恢复已有节点状态：$add_backup"
      systemctl disable --now anytls-lite.service >/dev/null 2>&1 || true
      if systemctl is-active --quiet anytls-lite.service; then
        log "AnyTLS 未能停止，保留文件；请检查服务并从 $add_backup 手动恢复。"
        exit "$status"
      fi
      cp -p "$add_backup/state" "$add_backup/install.sh" "$APP_DIR/"
      if [[ -f $add_backup/client-info.txt ]]; then cp -p "$add_backup/client-info.txt" "$APP_DIR/"; else rm -f "$APP_DIR/client-info.txt"; fi
      rm -f -- "$APP_DIR/anytls.json" "$APP_DIR/bin/sing-box" "$UNIT_DIR/anytls-lite.service"
      rm -rf -- "$APP_DIR/tls" "$APP_DIR/acme"
      chmod "$add_old_mode" "$APP_DIR"
      systemctl daemon-reload
    fi
    exit "$status"
  }
  trap rollback_add_anytls EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  add_changed=1
  create_anytls_user
  install -d -m 0755 "$APP_DIR/bin"
  replace_binary "$add_backup/candidate/sing-box" "$APP_DIR/bin/sing-box"
  export PROTOCOLS ANYTLS_PORT ANYTLS_SERVER_NAME ANYTLS_PASSWORD ANYTLS_CERT_MODE ANYTLS_CERT_FILE ANYTLS_KEY_FILE ANYTLS_EMAIL
  python3 - "$APP_DIR/state" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in p.read_text(encoding='utf-8').splitlines())
for k in ('PROTOCOLS', 'ANYTLS_PORT', 'ANYTLS_SERVER_NAME', 'ANYTLS_PASSWORD', 'ANYTLS_CERT_MODE', 'ANYTLS_CERT_FILE', 'ANYTLS_KEY_FILE', 'ANYTLS_EMAIL'):
    s[k] = os.environ[k]
p.write_bytes(''.join(f'{k}={v}\n' for k,v in s.items()).encode('utf-8'))
PY
  write_anytls_config
  "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json"
  write_anytls_unit
  install_self
  systemctl daemon-reload
  start_anytls
  write_client_info
  add_changed=0
  log '已追加 AnyTLS，原 Xray/Argo 服务及节点凭据保持原样。'
  anytls_instructions
  cat "$APP_DIR/client-info.txt"
)

do_refresh_anytls_cert() (
  need_root
  [[ -r $APP_DIR/state ]] || die '尚未安装 Lite。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled anytls || die '未安装 AnyTLS。'
  [[ $ANYTLS_CERT_MODE == file ]] || die 'ACME 模式由 sing-box 自动续期，无需此命令。'
  check_anytls_certificate "$ANYTLS_CERT_FILE" "$ANYTLS_KEY_FILE"
  cert_backup=$(mktemp -d "$APP_DIR/backup-cert-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$cert_backup"
  cp -p "$APP_DIR/tls/fullchain.pem" "$APP_DIR/tls/privkey.pem" "$cert_backup/"
  rollback_cert() {
    local status=$?
    trap - EXIT INT TERM
    if (( status != 0 )); then
      cp -p "$cert_backup/fullchain.pem" "$cert_backup/privkey.pem" "$APP_DIR/tls/"
      systemctl restart anytls-lite.service || log "恢复证书后服务重启失败，请检查 $cert_backup。"
      log "刷新失败，已恢复旧证书：$cert_backup"
    fi
    exit "$status"
  }
  trap rollback_cert EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  copy_anytls_certificate
  "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json"
  systemctl restart anytls-lite.service
  systemctl is-active --quiet anytls-lite.service
  verify_anytls_tls
  trap - EXIT INT TERM
  log "证书已刷新并通过验证；旧证书备份：$cert_backup"
)

write_config() {
  local keys
  set_protocols "${PROTOCOLS-vmess,ss2022,vless}" || die '至少选择一个有效协议。'
  VMESS_UUID='' WS_PATH='' VLESS_UUID='' SS_PASSWORD='' REALITY_PRIVATE='' REALITY_PUBLIC='' REALITY_SHORT_ID=''
  if protocol_enabled vmess; then
    VMESS_UUID=$(xray uuid)
    WS_PATH="/$(openssl rand -hex 12)"
  fi
  if protocol_enabled ss2022; then SS_PASSWORD=$(openssl rand -base64 16 | tr -d '\n'); fi
  if protocol_enabled vless; then
    VLESS_UUID=$(xray uuid)
    XHTTP_PATH=${XHTTP_PATH:-/$(openssl rand -hex 16)}
    valid_xhttp_path "$XHTTP_PATH" || die 'XHTTP_PATH 无效'
    keys=$(xray x25519)
    REALITY_PRIVATE=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keys")
    REALITY_PUBLIC=$(awk -F': ' '/Password|PublicKey/{print $2; exit}' <<<"$keys")
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    [[ -n $REALITY_PRIVATE && -n $REALITY_PUBLIC ]] || die '无法生成 REALITY 密钥'
  else
    XHTTP_PATH=''
  fi
  if protocol_enabled anytls; then ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(openssl rand -hex 32)}; fi
  cat >"$APP_DIR/state" <<EOF
PROTOCOLS=$PROTOCOLS
VMESS_PORT=${VMESS_PORT:-}
SS_PORT=${SS_PORT:-}
REALITY_PORT=${REALITY_PORT:-}
REALITY_GUARD_PORT=${REALITY_GUARD_PORT:-}
VMESS_ADDRESS=${VMESS_ADDRESS:-}
VMESS_UUID=$VMESS_UUID
VLESS_UUID=$VLESS_UUID
WS_PATH=$WS_PATH
VLESS_TRANSPORT=xhttp
XHTTP_PATH=$XHTTP_PATH
SS_PASSWORD=$SS_PASSWORD
REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-}
REALITY_PUBLIC=$REALITY_PUBLIC
REALITY_SHORT_ID=$REALITY_SHORT_ID
ARGO_MODE=${ARGO_MODE:-}
ARGO_DOMAIN=${ARGO_DOMAIN:-}
ANYTLS_PORT=${ANYTLS_PORT:-}
ANYTLS_SERVER_NAME=${ANYTLS_SERVER_NAME:-}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-}
ANYTLS_CERT_MODE=${ANYTLS_CERT_MODE:-}
ANYTLS_CERT_FILE=${ANYTLS_CERT_FILE:-}
ANYTLS_KEY_FILE=${ANYTLS_KEY_FILE:-}
ANYTLS_EMAIL=${ANYTLS_EMAIL:-}
EOF
  chmod 0600 "$APP_DIR/state"
  if protocol_enabled anytls; then write_anytls_config; fi
  xray_enabled || return 0
  REALITY_PRIVATE="$REALITY_PRIVATE" python3 - "$APP_DIR" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
s = dict(line.split('=', 1) for line in (root/'state').read_text(encoding='utf-8').splitlines())
selected = s['PROTOCOLS'].split(',')
nodes, rules = [], []
if 'vmess' in selected:
    nodes.append({'tag': 'vmess-ws-argo', 'listen': '127.0.0.1', 'port': int(s['VMESS_PORT']), 'protocol': 'vmess',
                  'settings': {'clients': [{'id': s['VMESS_UUID']}]},
                  'streamSettings': {'network': 'ws', 'wsSettings': {'path': s['WS_PATH']}}})
if 'ss2022' in selected:
    nodes.append({'tag': 'ss2022', 'port': int(s['SS_PORT']), 'protocol': 'shadowsocks',
                  'settings': {'method': '2022-blake3-aes-128-gcm', 'password': s['SS_PASSWORD'], 'network': 'tcp,udp'}})
if 'vless' in selected:
    nodes.extend([
        {'tag': 'reality-guard', 'listen': '127.0.0.1', 'port': int(s['REALITY_GUARD_PORT']), 'protocol': 'dokodemo-door',
         'settings': {'address': s['REALITY_SERVER_NAME'], 'port': 443, 'network': 'tcp'},
         'sniffing': {'enabled': True, 'destOverride': ['tls'], 'routeOnly': True}},
        {'tag': 'vless-reality', 'port': int(s['REALITY_PORT']), 'protocol': 'vless',
         'settings': {'clients': [{'id': s['VLESS_UUID']}], 'decryption': 'none'},
         'streamSettings': {'network': 'xhttp', 'xhttpSettings': {'path': s['XHTTP_PATH'], 'mode': 'auto'},
                            'security': 'reality', 'realitySettings': {'show': False, 'target': '127.0.0.1:' + s['REALITY_GUARD_PORT'],
                            'serverNames': [s['REALITY_SERVER_NAME']], 'privateKey': os.environ['REALITY_PRIVATE'], 'shortIds': [s['REALITY_SHORT_ID']]}},
         'sniffing': {'enabled': True, 'destOverride': ['http', 'tls', 'quic'], 'routeOnly': True}}
    ])
    rules = [{'inboundTag': ['reality-guard'], 'domain': ['full:' + s['REALITY_SERVER_NAME']], 'outboundTag': 'direct'},
             {'inboundTag': ['reality-guard'], 'outboundTag': 'block'}]
config = {'log': {'loglevel': 'warning'}, 'inbounds': nodes,
          'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}, {'protocol': 'blackhole', 'tag': 'block'}],
          'routing': {'rules': rules}}
(root/'xray.json').write_bytes((json.dumps(config, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
PY
  chown root:xray "$APP_DIR/xray.json"
  chmod 0640 "$APP_DIR/xray.json"
  if protocol_enabled vmess; then
    if [[ $ARGO_MODE == token ]]; then printf 'TUNNEL_TOKEN=%s\n' "$ARGO_TOKEN" >"$APP_DIR/cloudflared.env";
    else : >"$APP_DIR/cloudflared.env"; fi
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
$(if protocol_enabled vless && [[ $REALITY_PORT == 443 ]]; then printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'; fi)
ExecStart=$BIN_DIR/xray run -config $APP_DIR/xray.json
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
  if xray_enabled; then render_xray_unit >"$UNIT_DIR/xray-lite.service"; fi
  if protocol_enabled anytls; then write_anytls_unit; fi
  protocol_enabled vmess || return 0
  local cf_exec cf_env=''
  if [[ $ARGO_MODE == token ]]; then
    cf_env="EnvironmentFile=$APP_DIR/cloudflared.env"
    cf_exec="$BIN_DIR/cloudflared --no-autoupdate tunnel run"
  else
    cf_exec="$BIN_DIR/cloudflared --no-autoupdate tunnel --url http://127.0.0.1:$VMESS_PORT"
  fi
  cat >"$UNIT_DIR/cloudflared-lite.service" <<EOF
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

public_ip() { curl --fail --silent --show-error --max-time 8 --proto '=https' https://api.ipify.org || printf 'YOUR_SERVER_IP'; }
quick_domain() {
  local invocation_id
  invocation_id=$(systemctl show cloudflared-lite.service --property=InvocationID --value 2>/dev/null || true)
  [[ -n $invocation_id ]] || return 0
  journalctl -u cloudflared-lite.service "_SYSTEMD_INVOCATION_ID=$invocation_id" --no-pager 2>/dev/null |
    sed -nE 's#.*https://([-a-z0-9]+\.trycloudflare\.com).*#\1#p' | tail -n1 || true
}
wait_for_quick_domain() {
  local attempt domain
  for ((attempt=0; attempt<15; attempt++)); do
    domain=$(quick_domain)
    [[ -n $domain ]] && return 0
    sleep 2
  done
  return 1
}

write_client_info() (
  local requested_address=${VMESS_ADDRESS:-} server='' domain vmess_json uri content='' label
  load_state
  if protocol_enabled ss2022 || protocol_enabled vless; then
    server=$(public_ip)
    if [[ $server == *:* && $server != \[*\] ]]; then server="[$server]"; fi
  fi
  if protocol_enabled vmess; then
    domain=$ARGO_DOMAIN
    if [[ $ARGO_MODE == quick ]]; then domain=$(quick_domain); fi
    VMESS_ADDRESS=${requested_address:-${VMESS_ADDRESS:-www.wto.org}}
    validate_domain "$VMESS_ADDRESS" || die 'VMESS_ADDRESS 无效'
    if [[ -n $domain ]]; then
      validate_domain "$domain" || die 'Argo 域名无效'
      vmess_json=$(printf '{"v":"2","ps":"vmess-argo","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$VMESS_ADDRESS" "$VMESS_UUID" "$domain" "$WS_PATH" "$domain")
      uri="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
      content+="VMess + WS + Argo"$'\n'"$uri"$'\n\n'
    else
      content+="VMess 隧道正在启动，稍后运行 $APP show 获取链接。"$'\n\n'
    fi
  fi
  if protocol_enabled ss2022; then
    uri="ss://2022-blake3-aes-128-gcm:$(encode_ss2022_password "$SS_PASSWORD")@${server}:${SS_PORT}#ss2022"
    content+="Shadowsocks 2022"$'\n'"$uri"$'\n\n'
  fi
  if protocol_enabled vless; then
    validate_domain "$REALITY_SERVER_NAME" || die 'state 中的 REALITY_SERVER_NAME 无效'
    uri=$(vless_uri "$server" "$VLESS_TRANSPORT" "$XHTTP_PATH")
    if [[ $VLESS_TRANSPORT == xhttp ]]; then label='VLESS + XHTTP + REALITY'; else label='VLESS + TCP + REALITY + Vision（尚未迁移）'; fi
    content+="$label"$'\n'"$uri"$'\n\n'
  fi
  if protocol_enabled anytls; then
    validate_domain "$ANYTLS_SERVER_NAME" || die 'state 中的 ANYTLS_SERVER_NAME 无效'
    uri="anytls://${ANYTLS_PASSWORD}@${ANYTLS_SERVER_NAME}:${ANYTLS_PORT}/?sni=${ANYTLS_SERVER_NAME}&insecure=0#anytls"
    content+="AnyTLS + TLS（客户端使用 sing-box / mihomo；开启证书校验）"$'\n'"$uri"$'\n\n'
  fi
  tmp=$(mktemp "$APP_DIR/client-info.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s提示：此文件包含节点访问凭据，仅保存在服务器本机。\n' "$content" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$APP_DIR/client-info.txt"
)

vless_uri() {
  local server=$1 transport=$2 path=${3:-} options label
  case $transport in
    xhttp)
      valid_xhttp_path "$path" || die 'XHTTP 路径无效；请检查 state 或执行 migrate-xhttp。'
      options="type=xhttp&mode=auto&path=${path//\//%2F}"; label=vless-xhttp-reality ;;
    tcp|raw) options='type=tcp&flow=xtls-rprx-vision'; label=vless-reality ;;
    *) die "不支持的 VLESS_TRANSPORT: $transport" ;;
  esac
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&%s#%s\n' \
    "$VLESS_UUID" "$server" "$REALITY_PORT" "$REALITY_SERVER_NAME" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$options" "$label"
}

configure_install() {
  local input item sni_mode value
  local -a choices=()
  ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0
  while true; do
    printf '\n请选择需要创建的协议（输入编号切换勾选，可输入 1 3）：\n'
    printf '  [%s] 1. VMess + WebSocket + Argo\n' "$( [[ $ENABLE_VMESS == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 2. Shadowsocks 2022\n' "$( [[ $ENABLE_SS2022 == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 3. VLESS + XHTTP + REALITY\n' "$( [[ $ENABLE_VLESS == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 4. AnyTLS + TLS（自己的域名和证书）\n' "$( [[ $ENABLE_ANYTLS == 1 ]] && printf x || printf ' ' )"
    printf '  a. 全选  n. 清空  0. 取消  回车：确认选择\n'
    read -r -p '请选择: ' input || return 1
    case $input in
      0) return 1 ;;
      a|A) ENABLE_VMESS=1 ENABLE_SS2022=1 ENABLE_VLESS=1 ENABLE_ANYTLS=1; continue ;;
      n|N) ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0; continue ;;
      '')
        [[ $ENABLE_VMESS$ENABLE_SS2022$ENABLE_VLESS$ENABLE_ANYTLS != 0000 ]] && break
        log '请至少勾选一个协议。'; continue ;;
    esac
    input=${input//,/ }
    [[ $input =~ ^[1234[:space:]]+$ ]] || { log '只接受编号 1、2、3、4。'; continue; }
    read -r -a choices <<<"$input"
    for item in "${choices[@]}"; do
      case $item in
        1) ENABLE_VMESS=$((1-ENABLE_VMESS)) ;;
        2) ENABLE_SS2022=$((1-ENABLE_SS2022)) ;;
        3) ENABLE_VLESS=$((1-ENABLE_VLESS)) ;;
        4) ENABLE_ANYTLS=$((1-ENABLE_ANYTLS)) ;;
        *) log '请用空格分隔编号，例如 1 3。' ;;
      esac
    done
  done
  value=''
  [[ $ENABLE_VMESS == 0 ]] || value=vmess
  [[ $ENABLE_SS2022 == 0 ]] || value="${value:+$value,}ss2022"
  [[ $ENABLE_VLESS == 0 ]] || value="${value:+$value,}vless"
  [[ $ENABLE_ANYTLS == 0 ]] || value="${value:+$value,}anytls"
  set_protocols "$value" || return 1
  if protocol_enabled vless; then
    while true; do
      printf '\nVLESS SNI：1. 默认 learn.microsoft.com  2. 自定义\n'
      read -r -p '请选择 [1]: ' sni_mode || return 1
      case ${sni_mode:-1} in
        1) REALITY_SERVER_NAME=learn.microsoft.com; break ;;
        2)
          read -r -p '请输入 SNI 域名（不含 https://、端口或路径）: ' value || return 1
          if validate_domain "$value"; then REALITY_SERVER_NAME=$value; break; fi
          log '域名格式无效，请重新选择。' ;;
        *) log '请输入 1 或 2。' ;;
      esac
    done
    while true; do
      read -r -p "VLESS TCP 端口 [${REALITY_PORT:-443}]: " value || return 1
      value=${value:-${REALITY_PORT:-443}}
      if valid_reality_port "$value"; then REALITY_PORT=$value; break; fi
      log '端口应为 443 或 1024–65535。'
    done
  fi
  if protocol_enabled anytls; then configure_anytls || return 1; fi
  log "将创建：$PROTOCOLS"
}

validate_install_options() {
  set_protocols "${PROTOCOLS-vmess,ss2022,vless}" || die 'PROTOCOLS 只接受 vmess、ss2022、vless、anytls，用逗号分隔。'
  local port
  local -A used=()
  ACTIVE_PORTS=()
  if protocol_enabled vmess; then
    VMESS_PORT=${VMESS_PORT:-30000} VMESS_ADDRESS=${VMESS_ADDRESS:-www.wto.org}
    ARGO_MODE=${ARGO_MODE:-quick} ARGO_TOKEN=${ARGO_TOKEN:-} ARGO_DOMAIN=${ARGO_DOMAIN:-}
    valid_port "$VMESS_PORT" || die 'VMESS_PORT 无效'
    validate_domain "$VMESS_ADDRESS" || die 'VMESS_ADDRESS 无效'
    [[ $ARGO_MODE == quick || $ARGO_MODE == token ]] || die 'ARGO_MODE 只能是 quick 或 token'
    if [[ $ARGO_MODE == token ]]; then
      [[ $ARGO_TOKEN =~ ^[A-Za-z0-9._-]+$ ]] || die 'token 模式必须设置有效 ARGO_TOKEN'
      validate_domain "$ARGO_DOMAIN" || die 'token 模式必须设置有效 ARGO_DOMAIN'
    else
      [[ -z $ARGO_TOKEN && -z $ARGO_DOMAIN ]] || die 'quick 模式不要设置 ARGO_TOKEN/ARGO_DOMAIN'
    fi
    ACTIVE_PORTS+=("$VMESS_PORT")
  else
    VMESS_PORT='' VMESS_ADDRESS='' ARGO_MODE=disabled ARGO_TOKEN='' ARGO_DOMAIN=''
  fi
  if protocol_enabled ss2022; then
    SS_PORT=${SS_PORT:-30001}
    valid_port "$SS_PORT" || die 'SS_PORT 无效'
    ACTIVE_PORTS+=("$SS_PORT")
  else SS_PORT=''; fi
  if protocol_enabled vless; then
    REALITY_PORT=${REALITY_PORT:-443} REALITY_GUARD_PORT=${REALITY_GUARD_PORT:-30003}
    REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-learn.microsoft.com}
    valid_reality_port "$REALITY_PORT" || die 'REALITY_PORT 只能为 443 或 1024–65535'
    valid_port "$REALITY_GUARD_PORT" || die 'REALITY_GUARD_PORT 无效'
    validate_domain "$REALITY_SERVER_NAME" || die 'REALITY_SERVER_NAME 无效'
    [[ -z ${XHTTP_PATH:-} ]] || valid_xhttp_path "$XHTTP_PATH" || die 'XHTTP_PATH 格式无效'
    ACTIVE_PORTS+=("$REALITY_PORT" "$REALITY_GUARD_PORT")
  else REALITY_PORT='' REALITY_GUARD_PORT='' REALITY_SERVER_NAME='' XHTTP_PATH=''; fi
  if protocol_enabled anytls; then
    validate_anytls_options
    ACTIVE_PORTS+=("$ANYTLS_PORT")
    if [[ $ANYTLS_CERT_MODE == acme ]]; then ACTIVE_PORTS+=(80); fi
  else
    ANYTLS_PORT='' ANYTLS_SERVER_NAME='' ANYTLS_PASSWORD='' ANYTLS_CERT_MODE=''
    ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL=''
  fi
  for port in "${ACTIVE_PORTS[@]}"; do
    port=$((10#$port))
    [[ ! ${used[$port]+yes} ]] || die "已选协议的端口不能重复：$port"
    used[$port]=1
  done
}

remove_services_and_config() {
  local unit
  for unit in anytls-lite cloudflared-lite xray-lite; do
    if [[ -f $UNIT_DIR/$unit.service ]]; then
      systemctl disable --now "$unit.service" || true
      if systemctl is-active --quiet "$unit.service"; then die "$unit 仍在运行，未删除配置，请检查服务。"; fi
    fi
  done
  rm -f -- "$UNIT_DIR/anytls-lite.service" "$UNIT_DIR/cloudflared-lite.service" "$UNIT_DIR/xray-lite.service" "$SHORTCUT"
  rm -rf -- "$UNIT_DIR/cloudflared-lite.service.d" "$APP_DIR"
  systemctl daemon-reload
}

rollback_install() {
  local status=$?
  trap - EXIT
  (( status != 0 )) || return 0
  log '安装失败，正在清理本次生成的服务、配置和访问凭据'
  remove_services_and_config || true
  exit "$status"
}

do_install() {
  need_root
  [[ ! -e $APP_DIR/state ]] || die '已安装；请从菜单选择更新。重新选择协议需先卸载，卸载会删除原节点凭据。'
  validate_install_options
  install_packages
  need_cmd ss; need_cmd sha256sum; need_cmd base64
  local port
  for port in "${ACTIVE_PORTS[@]}"; do port_free "$port" || die "端口 $port 已占用，请选择其他端口。"; done
  detect_arch
  trap rollback_install EXIT
  install_binaries
  create_users
  write_config
  if xray_enabled; then "$BIN_DIR/xray" run -test -config "$APP_DIR/xray.json"; fi
  if protocol_enabled anytls; then "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json"; fi
  write_units
  install_self
  ln -sf "$APP_DIR/install.sh" "$SHORTCUT"
  systemctl daemon-reload
  if xray_enabled; then
    systemctl enable --now xray-lite.service
    systemctl is-active --quiet xray-lite.service || die 'Xray 启动失败，请运行 journalctl -u xray-lite'
  fi
  if protocol_enabled anytls; then start_anytls; fi
  if protocol_enabled vmess; then
    systemctl enable --now cloudflared-lite.service
    systemctl is-active --quiet cloudflared-lite.service || die 'cloudflared 启动失败，请运行 journalctl -u cloudflared-lite'
    if [[ $ARGO_MODE == quick ]] && ! wait_for_quick_domain; then log "尚未读到 Quick Tunnel 域名，稍后运行 $APP show。"; fi
  fi
  write_client_info
  trap - EXIT
  cat "$APP_DIR/client-info.txt"
  if protocol_enabled ss2022; then log "防火墙需开放 $SS_PORT/tcp+udp。"; fi
  if protocol_enabled vless; then log "防火墙需开放 $REALITY_PORT/tcp；无需开放内部守门端口。"; fi
  if protocol_enabled vmess; then log "VMess 使用 Argo，不要开放内部端口 $VMESS_PORT。请确保服务器和客户端自动对时正常。"; fi
  if protocol_enabled anytls; then anytls_instructions; fi
  log "完成。运行 $APP 可再次打开管理菜单。"
}

do_show() { need_root; write_client_info; cat "$APP_DIR/client-info.txt"; }
do_status() (
  need_root
  load_state
  log "已安装协议：$PROTOCOLS"
  local -a services=()
  if xray_enabled; then services+=(xray-lite.service); fi
  if protocol_enabled vmess; then services+=(cloudflared-lite.service); fi
  if protocol_enabled anytls; then services+=(anytls-lite.service); fi
  systemctl --no-pager --full status "${services[@]}" || true
  ss -lntup | grep -E 'xray|cloudflared|sing-box' || true
)

do_repair_argo() (
  need_root
  load_state
  protocol_enabled vmess || die '未安装 VMess/Argo，无需修复隧道。'
  install -d -m 0755 "$UNIT_DIR/cloudflared-lite.service.d"
  printf '[Unit]\nPartOf=xray-lite.service\n' >"$UNIT_DIR/cloudflared-lite.service.d/10-xray-restart.conf"
  systemctl daemon-reload
  systemctl restart xray-lite.service cloudflared-lite.service
  systemctl is-active --quiet xray-lite.service || die 'Xray 启动失败，请检查 journalctl -u xray-lite'
  systemctl is-active --quiet cloudflared-lite.service || die '隧道启动失败，请检查 journalctl -u cloudflared-lite'
  if [[ $ARGO_MODE == quick ]]; then wait_for_quick_domain || die '30 秒内未获取到 Quick Tunnel 域名，请检查日志'; fi
  write_client_info
  cat "$APP_DIR/client-info.txt"
  log '请重新导入 VMess 链接。'
)

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
  load_state
  protocol_enabled vless || die '未安装 VLESS，无需迁移。'
  # Serialize installed-node maintenance.
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
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

restart_selected_services() {
  local -a services=()
  if xray_enabled; then services+=(xray-lite.service); fi
  if protocol_enabled vmess; then services+=(cloudflared-lite.service); fi
  if protocol_enabled anytls; then services+=(anytls-lite.service); fi
  systemctl restart "${services[@]}" || return 1
  local unit
  for unit in "${services[@]}"; do systemctl is-active --quiet "$unit" || return 1; done
}

apply_update() (
  need_root
  [[ -s $APP_DIR/install.sh ]] || die '尚未完整安装 Lite。'
  need_cmd curl; need_cmd unzip; need_cmd sha256sum; need_cmd systemctl; need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  if xray_enabled; then
    [[ -s $APP_DIR/xray.json && -x $BIN_DIR/xray ]] || die 'Xray 文件不完整。'
    systemctl is-active --quiet xray-lite.service || die 'Xray 未运行，请先检查服务。'
  fi
  if protocol_enabled anytls; then
    [[ -s $APP_DIR/anytls.json && -x $APP_DIR/bin/sing-box ]] || die 'AnyTLS 文件不完整。'
    systemctl is-active --quiet anytls-lite.service || die 'AnyTLS 未运行，请先检查服务。'
    need_cmd tar; need_cmd python3
  fi
  if protocol_enabled vmess; then
    [[ -x $BIN_DIR/cloudflared ]] || die 'cloudflared 不存在，请先检查安装。'
    systemctl is-active --quiet cloudflared-lite.service || die 'Argo 未运行，请先修复隧道。'
  fi
  detect_arch
  # EXIT traps must retain these values after function stack unwinding.
  update_changed=0
  update_backup=$(mktemp -d "$APP_DIR/backup-update-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$update_backup"
  if xray_enabled; then
    cp -p "$BIN_DIR/xray" "$update_backup/xray"
    cp -p "$APP_DIR/xray.json" "$update_backup/"
  fi
  if protocol_enabled vmess; then cp -p "$BIN_DIR/cloudflared" "$update_backup/cloudflared"; fi
  if protocol_enabled anytls; then
    cp -p "$APP_DIR/bin/sing-box" "$update_backup/sing-box"
    cp -p "$APP_DIR/anytls.json" "$update_backup/"
    cp -a "$APP_DIR/tls" "$APP_DIR/acme" "$update_backup/"
  fi
  cp -p "$APP_DIR/state" "$APP_DIR/install.sh" "$update_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$update_backup/client-info.txt"; fi
  printf 'Xray candidate=%s\ncloudflared candidate=%s\nprotocols=%s\n' "$XRAY_VERSION" "$CLOUDFLARED_VERSION" "$PROTOCOLS" >"$update_backup/update.txt"
  if protocol_enabled anytls; then printf 'sing-box candidate=%s\n' "$SINGBOX_VERSION" >>"$update_backup/update.txt"; fi

  rollback_update() {
    local status=$? failed=0
    trap - EXIT INT TERM
    if (( status != 0 && update_changed == 1 )); then
      log "更新失败，正在恢复旧版内核和脚本：$update_backup"
      if xray_enabled; then replace_binary "$update_backup/xray" "$BIN_DIR/xray" || failed=1; fi
      if protocol_enabled vmess; then replace_binary "$update_backup/cloudflared" "$BIN_DIR/cloudflared" || failed=1; fi
      if protocol_enabled anytls; then replace_binary "$update_backup/sing-box" "$APP_DIR/bin/sing-box" || failed=1; fi
      cp -p "$update_backup/install.sh" "$APP_DIR/install.sh" || failed=1
      if [[ -f $update_backup/client-info.txt ]]; then
        cp -p "$update_backup/client-info.txt" "$APP_DIR/client-info.txt" || failed=1
      else
        rm -f -- "$APP_DIR/client-info.txt" || failed=1
      fi
      restart_selected_services || failed=1
      if (( failed != 0 )); then log "自动恢复未完成，请通过服务器控制台检查 $update_backup 和服务日志。"; fi
      if protocol_enabled vmess; then log "Quick Tunnel 域名可能变化，恢复后运行 $APP show 刷新链接。"; fi
    fi
    exit "$status"
  }
  trap rollback_update EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  stage_binaries "$update_backup/candidate"
  if xray_enabled; then "$update_backup/candidate/xray" run -test -config "$APP_DIR/xray.json"; fi
  if protocol_enabled anytls; then "$update_backup/candidate/sing-box" check -c "$APP_DIR/anytls.json"; fi
  install_self "$update_backup/next.install.sh"
  update_changed=1
  if xray_enabled; then replace_binary "$update_backup/candidate/xray" "$BIN_DIR/xray"; fi
  if protocol_enabled vmess; then replace_binary "$update_backup/candidate/cloudflared" "$BIN_DIR/cloudflared"; fi
  if protocol_enabled anytls; then replace_binary "$update_backup/candidate/sing-box" "$APP_DIR/bin/sing-box"; fi
  mv -f "$update_backup/next.install.sh" "$APP_DIR/install.sh"
  restart_selected_services
  if protocol_enabled anytls; then verify_anytls_tls; fi
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]]; then
    wait_for_quick_domain || die '更新后未获取到 Quick Tunnel 域名，正在恢复旧版。'
  fi
  write_client_info
  update_changed=0
  trap - EXIT INT TERM
  log '更新完成；已保留协议、端口、SNI、路径和访问凭据。'
  if xray_enabled; then log "Xray $XRAY_VERSION"; fi
  if protocol_enabled anytls; then log "AnyTLS：sing-box $SINGBOX_VERSION，证书配置保留。"; fi
  if protocol_enabled vmess; then log "cloudflared $CLOUDFLARED_VERSION；Quick Tunnel 域名变化时，请重新导入 VMess 链接。"; fi
  log "旧版备份：$update_backup"
  cat "$APP_DIR/client-info.txt"
)

do_update() (
  need_root
  [[ -r $APP_DIR/state ]] || die '尚未安装，请先创建节点。'
  candidate=$(mktemp)
  trap 'rm -f -- "$candidate"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$candidate"
  bash -n "$candidate"
  grep -qx 'readonly APP="speed-slayer-lite"' "$candidate" || die '下载的文件不是 Lite 管理脚本。'
  grep -q '^apply_update()' "$candidate" || die '下载版本不含更新功能，请先把新版脚本上传到 GitHub。'
  # Run the downloaded updater so its pinned versions and hashes take effect now.
  bash "$candidate" apply-update
)

do_uninstall() (
  need_root
  [[ -d $APP_DIR ]] || { log '尚未安装。'; return 0; }
  local answer
  if [[ ${1:-} != --yes ]]; then
    log '卸载会停止 Lite 节点，删除配置、访问凭据和本目录内的更新/迁移备份。'
    read -r -p '确认卸载？[y/N]: ' answer || answer=''
    [[ $answer == y || $answer == Y ]] || { log '已取消卸载。'; return 0; }
  fi
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  remove_services_and_config
  log '已卸载 Lite 节点及自有 sing-box、证书副本/ACME 数据；保留外部源证书、共享二进制和系统账户。'
)

menu() {
  need_root
  local choice
  while true; do
    printf '\n=========== Speed Slayer Lite ===========\n'
    if [[ -r $APP_DIR/state ]]; then printf '状态：已安装\n'; else printf '状态：尚未安装\n'; fi
    cat <<'EOF'
1. 创建节点（勾选协议 / 选择 SNI）
2. 查看节点链接
3. 查看运行状态
4. 更新脚本和内核（保留节点配置）
5. 卸载 Lite 节点
6. 修复 VMess / Argo 隧道
7. 旧 VLESS TCP 节点迁移到 XHTTP
8. 为已有节点追加 AnyTLS（保留其他节点）
9. 刷新 AnyTLS 已有证书（外部续期后）
0. 退出
EOF
    read -r -p '请选择: ' choice || return 0
    case $choice in
      0) return 0 ;;
      1)
        if [[ -r $APP_DIR/state ]]; then log '已安装。更新请选 4；重新选择协议需先卸载，原节点凭据会被删除。'; continue; fi
        configure_install || continue
        do_install ;;
      2|3|4|5|6|7|8|9)
        if [[ ! -r $APP_DIR/state ]]; then log '请先选择 1 创建节点。'; continue; fi
        case $choice in
          2) do_show ;;
          3) do_status ;;
          4) do_update; return ;;
          5) do_uninstall ;;
          6) do_repair_argo ;;
          7) do_migrate_xhttp ;;
          8) do_add_anytls ;;
          9) do_refresh_anytls_cert ;;
        esac ;;
      *) log '请输入菜单中的编号。' ;;
    esac
  done
}

main() {
  case ${1:-menu} in
    menu) menu ;;
    install)
      if [[ -z ${PROTOCOLS+x} && -t 0 ]]; then configure_install || return 0; fi
      do_install ;;
    show) do_show ;;
    status) do_status ;;
    update) do_update ;;
    apply-update) apply_update ;;
    repair-argo) do_repair_argo ;;
    migrate-xhttp) do_migrate_xhttp ;;
    add-anytls) do_add_anytls ;;
    refresh-anytls-cert) do_refresh_anytls_cert ;;
    uninstall) do_uninstall "${2:-}" ;;
    *) die "用法: $0 {menu|install|show|status|update|repair-argo|migrate-xhttp|add-anytls|refresh-anytls-cert|uninstall [--yes]}" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
