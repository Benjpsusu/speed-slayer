#!/usr/bin/env bash
# Review build of install.sh; changes are listed in README-review.md.
set -Eeuo pipefail
umask 077
export PYTHONIOENCODING=utf-8

readonly APP="speed-slayer-lite"
readonly APP_DIR="/etc/${APP}"
readonly BIN_DIR="/usr/local/bin"
readonly UNIT_DIR="/etc/systemd/system"
readonly SHORTCUT="/usr/local/sbin/${APP}"
# Self-updates and re-downloads stay on the review build; point back to install.sh when adopting it.
readonly SCRIPT_URL="https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install-review.sh"
# 26.10.31+ turns off the MPTCP listeners Go 1.24+ enables by default (kernel IPv4 MPTCP RCE).
readonly XRAY_VERSION="26.11.9"
readonly CLOUDFLARED_VERSION="2026.10.3"
readonly SINGBOX_VERSION="1.14.4"
readonly BACKUP_KEEP=3

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
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }
# Source certificates must stay outside the Lite directory so uninstall keeps them.
valid_cert_source() { [[ $1 == /* && $1 != *$'\n'* && $1 != *$'\r'* && -r $1 && $1 != "$APP_DIR/"* ]]; }
encode_ss2022_password() { printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'; }
port_free() { ! ss -H -lntup "sport = :$1" 2>/dev/null | grep -q .; }

# Backups hold old binaries and key copies: keep the current one plus the newest others.
# Names start with a fixed-width timestamp, so glob order is chronological.
prune_backups() {
  local kind=$1 current=$2 dir
  local -a older=()
  for dir in "$APP_DIR/$kind"-*/; do
    dir=${dir%/}
    if [[ -d $dir && $dir != "$current" ]]; then older+=("$dir"); fi
  done
  (( ${#older[@]} >= BACKUP_KEEP )) || return 0
  for dir in "${older[@]:0:${#older[@]}-BACKUP_KEEP+1}"; do rm -rf -- "$dir"; done
}

set_protocols() {
  local value=$1 item
  local -a items=()
  [[ -n $value && $value != ,* && $value != *, && $value != *,,* ]] || return 1
  ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0 ENABLE_XHTTPCDN=0
  IFS=',' read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    case $item in
      vmess) ENABLE_VMESS=1 ;;
      ss2022) ENABLE_SS2022=1 ;;
      vless) ENABLE_VLESS=1 ;;
      anytls) ENABLE_ANYTLS=1 ;;
      xhttpcdn) ENABLE_XHTTPCDN=1 ;;
      *) return 1 ;;
    esac
  done
  PROTOCOLS=''
  [[ $ENABLE_VMESS == 0 ]] || PROTOCOLS='vmess'
  [[ $ENABLE_SS2022 == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}ss2022"
  [[ $ENABLE_VLESS == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}vless"
  [[ $ENABLE_ANYTLS == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}anytls"
  [[ $ENABLE_XHTTPCDN == 0 ]] || PROTOCOLS="${PROTOCOLS:+$PROTOCOLS,}xhttpcdn"
  [[ -n $PROTOCOLS ]]
}

protocol_enabled() {
  case $1 in
    vmess) [[ ${ENABLE_VMESS:-1} == 1 ]] ;;
    ss2022) [[ ${ENABLE_SS2022:-1} == 1 ]] ;;
    vless) [[ ${ENABLE_VLESS:-1} == 1 ]] ;;
    anytls) [[ ${ENABLE_ANYTLS:-0} == 1 ]] ;;
    xhttpcdn) [[ ${ENABLE_XHTTPCDN:-0} == 1 ]] ;;
    *) return 1 ;;
  esac
}

xray_enabled() { protocol_enabled vmess || protocol_enabled ss2022 || protocol_enabled vless || protocol_enabled xhttpcdn; }
# Protocols served by the shared xray-lite process besides the CDN inbound itself.
xray_needed_without_cdn() { protocol_enabled vmess || protocol_enabled ss2022 || protocol_enabled vless; }
cloudflared_needed() { protocol_enabled vmess || protocol_enabled xhttpcdn; }
# Print $PROTOCOLS without $1; order-independent, unlike ${PROTOCOLS%,name}.
protocols_without() {
  local item out=''
  local -a items=()
  IFS=',' read -r -a items <<<"$PROTOCOLS"
  for item in "${items[@]}"; do [[ $item == "$1" ]] || out="${out:+$out,}$item"; done
  printf '%s' "$out"
}

load_state() {
  [[ -r $APP_DIR/state ]] || die '尚未安装，请先从菜单创建节点。'
  local key value stored_protocols='vmess,ss2022,vless'
  local -A seen=()
  VMESS_PORT='' SS_PORT='' REALITY_PORT='' REALITY_GUARD_PORT=''
  VMESS_ADDRESS='' VMESS_UUID='' VLESS_UUID='' WS_PATH='' SS_PASSWORD=''
  VLESS_TRANSPORT=tcp XHTTP_PATH='' REALITY_SERVER_NAME='' REALITY_PUBLIC='' REALITY_SHORT_ID=''
  ARGO_MODE='' ARGO_DOMAIN=''
  ANYTLS_PORT='' ANYTLS_SERVER_NAME='' ANYTLS_PASSWORD='' ANYTLS_CERT_MODE=''
  ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL='' ANYTLS_ADDRESS=''
  CDN_DOMAIN='' CDN_ADDRESS='' CDN_PORT='' CDN_UUID='' CDN_PATH=''
  while IFS='=' read -r key value; do
    [[ -n $key && ! ${seen[$key]+yes} ]] || die 'state 包含空字段或重复字段。'
    seen[$key]=1
    case $key in
      PROTOCOLS) stored_protocols=$value ;;
      VMESS_PORT|SS_PORT|REALITY_PORT|REALITY_GUARD_PORT|VMESS_ADDRESS|VMESS_UUID|VLESS_UUID|WS_PATH|VLESS_TRANSPORT|XHTTP_PATH|SS_PASSWORD|REALITY_SERVER_NAME|REALITY_PUBLIC|REALITY_SHORT_ID|ARGO_MODE|ARGO_DOMAIN|ANYTLS_PORT|ANYTLS_SERVER_NAME|ANYTLS_PASSWORD|ANYTLS_CERT_MODE|ANYTLS_CERT_FILE|ANYTLS_KEY_FILE|ANYTLS_EMAIL|ANYTLS_ADDRESS|CDN_DOMAIN|CDN_ADDRESS|CDN_PORT|CDN_UUID|CDN_PATH)
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
      XRAY_SHA=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
      CF_SHA=053b80b0a23031a038fdbf3c073f59f82b8f1f152aa67971d7383ffafc0dbab0 ;;
    aarch64|arm64)
      XRAY_ARCH=arm64-v8a CF_ARCH=arm64
      XRAY_SHA=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be
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
  if cloudflared_needed; then stage_cloudflared_binary "$stage"; fi
  if protocol_enabled anytls; then stage_anytls_binary "$stage"; fi
}

stage_cloudflared_binary() {
  mkdir -p "$1"
  download_checked "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}" "$1/cloudflared" "$CF_SHA"
  chmod 0755 "$1/cloudflared"
  "$1/cloudflared" --version
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
  if cloudflared_needed; then replace_binary "$stage/cloudflared" "$BIN_DIR/cloudflared"; fi
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
  if cloudflared_needed; then create_cloudflared_user; fi
}

create_cloudflared_user() {
  getent group cloudflared >/dev/null || groupadd --system cloudflared
  id cloudflared >/dev/null 2>&1 || useradd --system --gid cloudflared --home-dir /var/lib/cloudflared --shell /usr/sbin/nologin cloudflared
  install -d -m 0750 -o cloudflared -g cloudflared /var/lib/cloudflared
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
  local value default_port=443 default_mode=1 http_free=1
  if { protocol_enabled vless && [[ ${REALITY_PORT:-443} == 443 ]]; } || ! port_free 443; then default_port=8443; fi
  if ! port_free 80; then
    http_free=0 default_mode=3
    log 'TCP 80 已被占用：自动申请不可用，可选 2（已有证书）或 3（自签）。'
  fi
  while true; do
    printf '证书方式：1. 自动申请/续期（需空闲公网 TCP 80）  2. 已有可信证书  3. 自签证书（IP 直连，免域名/SNI/80）\n'
    read -r -p "请选择 [$default_mode]: " value || return 1
    case ${value:-$default_mode} in
      1)
        if [[ $http_free == 1 ]]; then ANYTLS_CERT_MODE=acme; break; fi
        log '80 已占用，请选择 2 或 3。' ;;
      2) ANYTLS_CERT_MODE=file; break ;;
      3) ANYTLS_CERT_MODE=selfsigned; break ;;
      *) log '请输入 1、2 或 3。' ;;
    esac
  done
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then
    ANYTLS_SERVER_NAME='' ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL=''
    log '自签模式不发送域名 SNI；客户端需导入本机公有证书或使用公钥指纹配置。'
    while true; do
      read -r -p "客户端连接的公网 IP [${ANYTLS_ADDRESS:-自动检测}]: " value || return 1
      value=${value:-${ANYTLS_ADDRESS:-}}
      if [[ -z $value || $value =~ ^[0-9a-fA-F:.]+$ ]]; then ANYTLS_ADDRESS=$value; break; fi
      log '请输入 IPv4/IPv6（不含方括号、端口或域名），或直接回车自动检测。'
    done
  else
    ANYTLS_ADDRESS=''
    log '填写自己的域名，SNI 与证书域名相同；域名使用仅 DNS 解析到本机。'
    while true; do
      read -r -p "AnyTLS 域名/SNI [${ANYTLS_SERVER_NAME:-}]: " value || return 1
      value=${value:-${ANYTLS_SERVER_NAME:-}}
      if validate_domain "$value"; then ANYTLS_SERVER_NAME=$value; break; fi
      log '请输入有效的域名，不含协议、路径或端口。'
    done
  fi
  while true; do
    read -r -p "AnyTLS TCP 端口 [${ANYTLS_PORT:-$default_port}]: " value || return 1
    value=${value:-${ANYTLS_PORT:-$default_port}}
    if ! valid_reality_port "$value"; then
      log '端口应为 443 或 1024–65535。'
    elif protocol_enabled vless && (( 10#$value == 10#${REALITY_PORT:-0} )); then
      log '该端口已分配给 VLESS，请换一个。'
    elif ! port_free "$value"; then
      log "端口 $value 已被占用，请换一个。"
    else
      ANYTLS_PORT=$value; break
    fi
  done
  case $ANYTLS_CERT_MODE in
    acme)
      ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE=''
      log "选择自动申请表示使用 Let's Encrypt 服务及其条款。"
      while true; do
        read -r -p "证书联系邮箱 [${ANYTLS_EMAIL:-}]: " value || return 1
        value=${value:-${ANYTLS_EMAIL:-}}
        if valid_email "$value"; then ANYTLS_EMAIL=$value; break; fi
        log '请输入有效邮箱，例如 admin@example.com。'
      done ;;
    file)
      ANYTLS_EMAIL=''
      while true; do
        read -r -p '完整证书链 PEM 的绝对路径: ' value || return 1
        if valid_cert_source "$value"; then ANYTLS_CERT_FILE=$value; break; fi
        log "请输入 $APP_DIR 之外可读文件的绝对路径。"
      done
      while true; do
        read -r -p '私钥 PEM 的绝对路径: ' value || return 1
        if valid_cert_source "$value"; then ANYTLS_KEY_FILE=$value; break; fi
        log "请输入 $APP_DIR 之外可读文件的绝对路径。"
      done ;;
  esac
}

validate_anytls_options() {
  ANYTLS_PORT=${ANYTLS_PORT:-8443}
  ANYTLS_CERT_MODE=${ANYTLS_CERT_MODE:-acme}
  if [[ $ANYTLS_CERT_MODE != selfsigned ]]; then
    validate_domain "${ANYTLS_SERVER_NAME:-}" || die 'AnyTLS 必须设置自己的 ANYTLS_SERVER_NAME 域名。'
    ANYTLS_ADDRESS=''
  fi
  valid_reality_port "$ANYTLS_PORT" || die 'ANYTLS_PORT 只能为 443 或 1024–65535'
  ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-}
  [[ -z $ANYTLS_PASSWORD || $ANYTLS_PASSWORD =~ ^[a-fA-F0-9]{64}$ ]] || die 'ANYTLS_PASSWORD 应为 64 位十六进制；留空自动生成。'
  case $ANYTLS_CERT_MODE in
    acme)
      valid_email "${ANYTLS_EMAIL:-}" || die '自动证书需设置有效 ANYTLS_EMAIL'
      ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ;;
    file)
      local file
      for file in "${ANYTLS_CERT_FILE:-}" "${ANYTLS_KEY_FILE:-}"; do
        valid_cert_source "$file" || die "证书和私钥必须是 $APP_DIR 之外可读文件的绝对路径（卸载后保留源证书）。"
      done
      ANYTLS_EMAIL='' ;;
    selfsigned)
      ANYTLS_SERVER_NAME='' ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL=''
      ANYTLS_ADDRESS=${ANYTLS_ADDRESS:-}
      [[ -z $ANYTLS_ADDRESS || $ANYTLS_ADDRESS =~ ^[0-9a-fA-F:.]+$ ]] || die 'ANYTLS_ADDRESS 应为 IPv4/IPv6，不含方括号、端口或域名。' ;;
    *) die 'ANYTLS_CERT_MODE 只接受 acme、file 或 selfsigned' ;;
  esac
}

detect_anytls_ip() {
  curl -4 --fail --silent --show-error --max-time 8 --proto '=https' https://api.ipify.org ||
    curl -6 --fail --silent --show-error --max-time 8 --proto '=https' https://api64.ipify.org
}

prepare_anytls_identity() {
  [[ $ANYTLS_CERT_MODE == selfsigned ]] || return 0
  if [[ -z ${ANYTLS_ADDRESS:-} ]]; then
    ANYTLS_ADDRESS=$(detect_anytls_ip) || die '无法检测公网 IP，请设置 ANYTLS_ADDRESS 或在交互提示中输入。'
  fi
  ANYTLS_ADDRESS=$(python3 - "$ANYTLS_ADDRESS" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit('ANYTLS_ADDRESS 不是有效 IP。')
if ip.is_unspecified or ip.is_loopback or ip.is_multicast or ip.is_link_local or '%' in str(ip):
    sys.exit('ANYTLS_ADDRESS 必须是客户端可达的服务器 IP。')
print(ip)
PY
  ) || die 'IP 检查失败，请填写客户端实际使用的服务器 IP。'
}

generate_anytls_certificate() (
  local renew=${1:-no} stage
  if [[ $renew != yes && ( -e $APP_DIR/tls/fullchain.pem || -e $APP_DIR/tls/privkey.pem ) ]]; then
    [[ -s $APP_DIR/tls/fullchain.pem && -s $APP_DIR/tls/privkey.pem ]] || die '自签证书文件不完整，拒绝自动更换密钥。'
    check_anytls_certificate "$APP_DIR/tls/fullchain.pem" "$APP_DIR/tls/privkey.pem"
    return
  fi
  stage=$(mktemp -d "$APP_DIR/tls/.selfsigned.XXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  python3 - "$stage" "$ANYTLS_ADDRESS" "$APP_DIR/tls/privkey.pem" "$renew" <<'PY'
import ipaddress, pathlib, subprocess, sys
p, ip, key, renew = pathlib.Path(sys.argv[1]), str(ipaddress.ip_address(sys.argv[2])), sys.argv[3], sys.argv[4]
# A private config keeps the system req defaults out. OpenSSL 1.1.1 appends -addext
# after its v3_ca section, and Go rejects the duplicate basicConstraints that results.
(p/'req.cnf').write_bytes((
    '[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = ext\n'
    '[dn]\nCN = speed-slayer-anytls\n'
    '[ext]\nsubjectAltName = IP:' + ip + '\nbasicConstraints = critical,CA:FALSE\n'
    'keyUsage = critical,digitalSignature\nextendedKeyUsage = serverAuth\n'
    'subjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n').encode('utf-8'))
args = ['openssl', 'req', '-x509', '-new', '-sha256', '-days', '3650',
        '-config', str(p/'req.cnf'), '-out', str(p/'fullchain.pem')]
if renew == 'yes':
    args += ['-key', key]
else:
    args += ['-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-keyout', str(p/'privkey.pem')]
subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
PY
  if [[ $renew == yes ]]; then
    check_anytls_certificate "$stage/fullchain.pem" "$APP_DIR/tls/privkey.pem"
  else
    check_anytls_certificate "$stage/fullchain.pem" "$stage/privkey.pem"
    install -m 0640 -o root -g speed-anytls "$stage/privkey.pem" "$APP_DIR/tls/privkey.pem"
  fi
  install -m 0640 -o root -g speed-anytls "$stage/fullchain.pem" "$APP_DIR/tls/fullchain.pem"
)

anytls_public_key_pin() {
  python3 - "$APP_DIR/tls/fullchain.pem" <<'PY'
import base64, hashlib, subprocess, sys
pub = subprocess.run(['openssl', 'x509', '-in', sys.argv[1], '-pubkey', '-noout'], check=True, capture_output=True).stdout
der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=pub, check=True, capture_output=True).stdout
print(base64.b64encode(hashlib.sha256(der).digest()).decode())
PY
}

check_anytls_certificate() {
  local certificate=$1 key=$2
  openssl x509 -in "$certificate" -noout -checkend 86400 >/dev/null || die '证书已过期或将在 24 小时内过期。'
  # Some OpenSSL versions return 0 even when -checkhost reports a mismatch.
  if [[ ${ANYTLS_CERT_MODE:-} == selfsigned ]]; then
    openssl x509 -in "$certificate" -noout -checkip "$ANYTLS_ADDRESS" |
      grep -Fx "IP $ANYTLS_ADDRESS does match certificate" >/dev/null || die '证书 IP 与 ANYTLS_ADDRESS 不匹配。'
  else
    openssl x509 -in "$certificate" -noout -checkhost "$ANYTLS_SERVER_NAME" |
      grep -Fx "Hostname $ANYTLS_SERVER_NAME does match certificate" >/dev/null || die '证书域名与 AnyTLS SNI 不匹配。'
  fi
  python3 - "$certificate" "$key" <<'PY'
import base64, re, ssl, sys

def items(der, pos, end):
    # Minimal DER walker: yields (tag, value_start, value_end).
    while pos < end:
        tag, size = der[pos], der[pos + 1]
        pos += 2
        if size & 0x80:
            count = size & 0x7f
            size, pos = int.from_bytes(der[pos:pos + count], 'big'), pos + count
        yield tag, pos, pos + size
        pos += size

# OpenSSL loads certificates that repeat an extension; Go (sing-box) refuses them.
pem = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for block in re.findall(r'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', pem, re.S):
    oids = []
    try:
        der = base64.b64decode(''.join(block.split()))
        _, start, end = next(items(der, 0, len(der)))   # Certificate
        _, start, end = next(items(der, start, end))    # TBSCertificate
        for tag, start, end in items(der, start, end):
            if tag != 0xA3:
                continue
            _, start, end = next(items(der, start, end))  # Extensions
            for _, ext_start, ext_end in items(der, start, end):
                _, oid_start, oid_end = next(items(der, ext_start, ext_end))
                oids.append(der[oid_start:oid_end])
    except (IndexError, StopIteration, ValueError):
        sys.exit('证书 DER 结构无效。')
    if len(oids) != len(set(oids)):
        sys.exit('证书包含重复扩展（常见于 OpenSSL 1.1.1 的 -addext），sing-box 无法加载。')
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
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then generate_anytls_certificate; fi
  python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
tls = {'enabled': True, 'min_version': '1.2'}
if s['ANYTLS_CERT_MODE'] != 'selfsigned':
    tls['server_name'] = s['ANYTLS_SERVER_NAME']
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

# sing-box 1.14.4 is built with Go 1.25, whose listeners use MPTCP unless told otherwise;
# GODEBUG keeps the public AnyTLS port on plain TCP (same mitigation as Xray 26.10.31+).
readonly ANYTLS_NO_MPTCP='Environment=GODEBUG=multipathtcp=0'
write_anytls_unit() {
  cat >"$UNIT_DIR/anytls-lite.service" <<EOF
[Unit]
Description=AnyTLS for Speed Slayer Lite (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
User=speed-anytls
Group=speed-anytls
$ANYTLS_NO_MPTCP
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
  python3 - "$ANYTLS_PORT" "${ANYTLS_ADDRESS:-$ANYTLS_SERVER_NAME}" "$ANYTLS_CERT_MODE" "$APP_DIR/tls/fullchain.pem" <<'PY'
import socket, ssl, sys, time
port, host, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
deadline = time.monotonic() + (120 if mode == 'acme' else 15)
context = ssl.create_default_context(cafile=sys.argv[4] if mode == 'selfsigned' else None)
last = ''
while time.monotonic() < deadline:
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
            with context.wrap_socket(sock, server_hostname=host):
                print('AnyTLS TLS certificate verified.')
                sys.exit(0)
    except (OSError, ssl.SSLError) as exc:
        last = str(exc)
        time.sleep(2)
sys.exit('AnyTLS TLS 验证失败；检查证书/IP/域名，自动签发模式另需检查公网 80；journalctl -u anytls-lite：' + last)
PY
}

start_anytls() {
  systemctl enable --now anytls-lite.service
  systemctl is-active --quiet anytls-lite.service || die 'AnyTLS 启动失败，请检查 journalctl -u anytls-lite'
  verify_anytls_tls
}

anytls_instructions() {
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then
    log "AnyTLS 自签模式：开放 $ANYTLS_PORT/tcp；连接 IP=$ANYTLS_ADDRESS，无需域名/SNI/80。"
    log "客户端须导入下方公有证书，或使用 $APP export-anytls-client 导出的公钥指纹配置。"
    log "自签证书有效期 3650 天；菜单 9 可沿用密钥续期。更新不会更换证书或密码。"
    return
  fi
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
  local address=${ANYTLS_ADDRESS:-}
  [[ -r $APP_DIR/state ]] || die '请先创建 Lite 节点。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled anytls && die '已安装 AnyTLS；更新请选择菜单 4，更换证书方式/域名/IP/端口请先用菜单 10 移除。'
  [[ ! -e $APP_DIR/anytls.json && ! -e $UNIT_DIR/anytls-lite.service && ! -e $APP_DIR/bin/sing-box && ! -e $APP_DIR/tls && ! -e $APP_DIR/acme ]] || die '存在未记录的 AnyTLS 文件，请先检查，拒绝覆盖。'
  ANYTLS_SERVER_NAME=$domain ANYTLS_PORT=$port ANYTLS_CERT_MODE=$mode
  ANYTLS_CERT_FILE=$cert ANYTLS_KEY_FILE=$key ANYTLS_EMAIL=$email ANYTLS_PASSWORD=$password
  ANYTLS_ADDRESS=$address
  if [[ -z $ANYTLS_SERVER_NAME && $ANYTLS_CERT_MODE != selfsigned && -t 0 ]]; then configure_anytls || return 0; fi
  set_protocols "$PROTOCOLS,anytls"
  validate_anytls_options
  install_packages
  prepare_anytls_identity
  ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(openssl rand -hex 32)}
  port_free "$ANYTLS_PORT" || die "端口 $ANYTLS_PORT 已占用。"
  if [[ $ANYTLS_CERT_MODE == acme ]]; then port_free 80 || die '80 已占用，请改用已有证书（file）或自签（selfsigned）方式。'; fi
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
  add_changed=0
  rollback_add_anytls() {
    local status=$?
    trap - EXIT INT TERM
    # The staged release is never needed for recovery; it only costs disk space.
    rm -rf -- "$add_backup/candidate"
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
  stage_anytls_binary "$add_backup/candidate"
  add_changed=1
  create_anytls_user
  install -d -m 0755 "$APP_DIR/bin"
  replace_binary "$add_backup/candidate/sing-box" "$APP_DIR/bin/sing-box"
  export PROTOCOLS ANYTLS_PORT ANYTLS_SERVER_NAME ANYTLS_PASSWORD ANYTLS_CERT_MODE ANYTLS_CERT_FILE ANYTLS_KEY_FILE ANYTLS_EMAIL ANYTLS_ADDRESS
  python3 - "$APP_DIR/state" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in p.read_text(encoding='utf-8').splitlines())
for k in ('PROTOCOLS', 'ANYTLS_PORT', 'ANYTLS_SERVER_NAME', 'ANYTLS_PASSWORD', 'ANYTLS_CERT_MODE', 'ANYTLS_CERT_FILE', 'ANYTLS_KEY_FILE', 'ANYTLS_EMAIL', 'ANYTLS_ADDRESS'):
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
  prune_backups backup-anytls "$add_backup"
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
  [[ $ANYTLS_CERT_MODE == file || $ANYTLS_CERT_MODE == selfsigned ]] || die 'ACME 模式由 sing-box 自动续期，无需此命令。'
  if [[ $ANYTLS_CERT_MODE == file ]]; then check_anytls_certificate "$ANYTLS_CERT_FILE" "$ANYTLS_KEY_FILE"; fi
  cert_backup=$(mktemp -d "$APP_DIR/backup-cert-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$cert_backup"
  cp -p "$APP_DIR/tls/fullchain.pem" "$APP_DIR/tls/privkey.pem" "$cert_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$cert_backup/"; fi
  rollback_cert() {
    local status=$?
    trap - EXIT INT TERM
    if (( status != 0 )); then
      cp -p "$cert_backup/fullchain.pem" "$cert_backup/privkey.pem" "$APP_DIR/tls/"
      if [[ -f $cert_backup/client-info.txt ]]; then cp -p "$cert_backup/client-info.txt" "$APP_DIR/"; else rm -f "$APP_DIR/client-info.txt"; fi
      systemctl restart anytls-lite.service || log "恢复证书后服务重启失败，请检查 $cert_backup。"
      log "刷新失败，已恢复旧证书：$cert_backup"
    fi
    prune_backups backup-cert "$cert_backup"
    exit "$status"
  }
  trap rollback_cert EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then generate_anytls_certificate yes; else copy_anytls_certificate; fi
  "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json"
  systemctl restart anytls-lite.service
  systemctl is-active --quiet anytls-lite.service
  verify_anytls_tls
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then write_client_info; fi
  trap - EXIT INT TERM
  prune_backups backup-cert "$cert_backup"
  log "证书已刷新并通过验证；旧证书备份：$cert_backup"
  if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then log "公钥指纹不变；使用 PEM 信任的客户端请重新复制 $APP show 中的新公有证书。"; fi
)

do_remove_anytls() (
  need_root
  [[ -r $APP_DIR/state ]] || die '尚未安装 Lite。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled anytls || die '未安装 AnyTLS。'
  xray_enabled || die '只安装了 AnyTLS；如需全部移除请选择卸载。'
  local answer
  if [[ ${1:-} != --yes ]]; then
    log '将停止 AnyTLS，删除其密码、证书副本/自签私钥和 ACME 数据；其他节点保持原样。'
    read -r -p '确认移除 AnyTLS？[y/N]: ' answer || answer=''
    [[ $answer == y || $answer == Y ]] || { log '已取消移除。'; return 0; }
  fi
  remove_backup=$(mktemp -d "$APP_DIR/backup-remove-anytls-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$remove_backup"
  cp -p "$APP_DIR/state" "$remove_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$remove_backup/"; fi
  remove_changed=0
  # AnyTLS files are deleted only after the new state is committed, so recovery
  # needs just the old state and a restart.
  rollback_remove_anytls() {
    local status=$?
    trap - EXIT INT TERM
    if (( status != 0 && remove_changed == 1 )); then
      log "移除 AnyTLS 失败，恢复原状态：$remove_backup"
      cp -p "$remove_backup/state" "$APP_DIR/"
      if [[ -f $remove_backup/client-info.txt ]]; then cp -p "$remove_backup/client-info.txt" "$APP_DIR/"; else rm -f -- "$APP_DIR/client-info.txt"; fi
      systemctl enable --now anytls-lite.service || log '恢复后 AnyTLS 未能启动，请检查 journalctl -u anytls-lite。'
    fi
    exit "$status"
  }
  trap rollback_remove_anytls EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  remove_changed=1
  systemctl disable --now anytls-lite.service || true
  if systemctl is-active --quiet anytls-lite.service; then die 'AnyTLS 未能停止，未删除任何文件。'; fi
  set_protocols "$(protocols_without anytls)"
  export PROTOCOLS
  python3 - "$APP_DIR/state" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in p.read_text(encoding='utf-8').splitlines())
s['PROTOCOLS'] = os.environ['PROTOCOLS']
for k in s:
    if k.startswith('ANYTLS_'):
        s[k] = ''
p.write_bytes(''.join(f'{k}={v}\n' for k, v in s.items()).encode('utf-8'))
PY
  write_client_info
  remove_changed=0
  trap - EXIT INT TERM
  rm -f -- "$UNIT_DIR/anytls-lite.service" "$APP_DIR/anytls.json" "$APP_DIR/bin/sing-box"
  rm -rf -- "$APP_DIR/tls" "$APP_DIR/acme"
  rmdir -- "$APP_DIR/bin" 2>/dev/null || true
  # Only the Xray account still needs to traverse the directory.
  chmod 0750 "$APP_DIR"
  systemctl daemon-reload
  prune_backups backup-remove-anytls "$remove_backup"
  log "已移除 AnyTLS；其他节点、凭据和服务保持原样。原 state 备份：$remove_backup"
  log '可用菜单 8 重新追加（例如改用自签、新 IP 或新端口）；传入 ANYTLS_PASSWORD 可沿用旧密码。'
  cat "$APP_DIR/client-info.txt"
)

# ---- VLESS + XHTTP behind a Cloudflare named tunnel ------------------------------
# The inbound listens on loopback only and Cloudflare reaches it through cloudflared,
# so the node keeps working when the server IP itself is blocked. Named tunnels are
# required: quick tunnels (trycloudflare) hold back streamed response bodies, which
# breaks XHTTP downlinks in every mode.
readonly CDN_DEFAULT_PORT=30004

# Tunnel tokens are base64 JSON {"a": account, "t": tunnel id, "s": secret}; print the id.
cdn_token_tunnel_id() {
  python3 - "$1" <<'PY'
import base64, binascii, json, re, sys, uuid
t = sys.argv[1].rstrip('=')
if not re.fullmatch(r'[A-Za-z0-9+/_-]{40,4096}', t):
    sys.exit(1)
try:
    d = json.loads(base64.b64decode(t.translate(str.maketrans('-_', '+/')) + '=' * (-len(t) % 4), validate=True))
    tunnel = uuid.UUID(str(d['t']))
    if not d.get('a') or not d.get('s'):
        sys.exit(1)
except (binascii.Error, ValueError, KeyError, TypeError, AttributeError):
    sys.exit(1)
print(tunnel)
PY
}
# Accept the bare token or the whole "cloudflared service install eyJ..." line.
cdn_extract_token() {
  local value=$1 re='(eyJ[A-Za-z0-9+/_=-]{20,})'
  if [[ $value =~ $re ]]; then value=${BASH_REMATCH[1]}; fi
  printf '%s' "${value//[[:space:]]/}"
}
valid_cdn_address() {
  validate_domain "$1" || python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null
}
cdn_route_hint() {
  log "Cloudflare 后台：Networking → Tunnels → 你的隧道 → Routes → Add route → Published application"
  log "  主机名 $CDN_DOMAIN  →  Service URL http://127.0.0.1:$CDN_PORT"
}

configure_xhttp_cdn() {
  local value tunnel
  printf '\nVLESS + XHTTP + Cloudflare 隧道：需要托管在 Cloudflare 的自有域名，本机无需开放端口，IP 被封也能用。\n'
  printf '先在 Cloudflare 后台 Networking → Tunnels 创建隧道，复制安装命令中 eyJ 开头的 token。\n'
  while true; do
    read -r -p "隧道主机名（例如 xhttp.example.com）[${CDN_DOMAIN:-}]: " value || return 1
    value=$(reality_target_normalize "${value:-${CDN_DOMAIN:-}}")
    if validate_domain "$value"; then CDN_DOMAIN=$value; break; fi
    log '主机名格式无效，请重新输入。'
  done
  while true; do
    read -r -s -p '隧道 token（可粘贴整条安装命令；输入时不显示）: ' value || { printf '\n'; return 1; }
    printf '\n'
    value=$(cdn_extract_token "$value")
    if tunnel=$(cdn_token_tunnel_id "$value"); then CDN_TOKEN=$value; log "token 有效，隧道 ID：$tunnel"; break; fi
    log 'token 无效：应为 Cloudflare 隧道安装命令中 eyJ 开头的那一长串。'
  done
  while true; do
    read -r -p "本机 XHTTP 端口（只监听 127.0.0.1）[${CDN_PORT:-$CDN_DEFAULT_PORT}]: " value || return 1
    value=${value:-${CDN_PORT:-$CDN_DEFAULT_PORT}}
    if ! valid_port "$value"; then log '端口应为 1024–65535。'
    elif ! port_free "$value"; then log "端口 $value 已占用，请换一个。"
    else CDN_PORT=$value; break; fi
  done
  while true; do
    read -r -p "客户端连接地址（Cloudflare 优选域名或 IP，回车使用 $CDN_DOMAIN）: " value || return 1
    value=${value:-$CDN_DOMAIN}
    if valid_cdn_address "$value"; then CDN_ADDRESS=$value; break; fi
    log '应为域名或 IP，不含端口或路径。'
  done
  cdn_route_hint
}

validate_cdn_options() {
  CDN_DOMAIN=$(reality_target_normalize "${CDN_DOMAIN:-}")
  validate_domain "$CDN_DOMAIN" || die 'XHTTP CDN 需要设置有效的 CDN_DOMAIN（隧道里配置的主机名）。'
  CDN_TOKEN=$(cdn_extract_token "${CDN_TOKEN:-}")
  cdn_token_tunnel_id "$CDN_TOKEN" >/dev/null || die 'CDN_TOKEN 无效：应为 Cloudflare 隧道安装命令中 eyJ 开头的 token。'
  CDN_PORT=${CDN_PORT:-$CDN_DEFAULT_PORT}
  valid_port "$CDN_PORT" || die 'CDN_PORT 只能为 1024–65535。'
  CDN_ADDRESS=${CDN_ADDRESS:-$CDN_DOMAIN}
  valid_cdn_address "$CDN_ADDRESS" || die 'CDN_ADDRESS 应为域名或 IP（优选地址），不含端口或路径。'
  [[ -z ${CDN_PATH:-} ]] || valid_xhttp_path "$CDN_PATH" || die 'CDN_PATH 格式无效。'
}

# Set state keys from KEY=VALUE lines on stdin. Values never travel through argv or the
# environment, so nothing rewrites path-like values on the way (e.g. Git Bash in tests).
state_update() {
  local code='
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = dict(line.split("=", 1) for line in p.read_text(encoding="utf-8").splitlines())
for line in sys.stdin.read().splitlines():
    key, _, value = line.partition("=")
    s[key] = value
p.write_bytes("".join(k + "=" + v + "\n" for k, v in s.items()).encode("utf-8"))
'
  python3 -c "$code" "$APP_DIR/state"
}

write_cdn_env() {
  (umask 077; printf 'TUNNEL_TOKEN=%s\n' "$CDN_TOKEN" >"$APP_DIR/cloudflared-cdn.env")
  chmod 0600 "$APP_DIR/cloudflared-cdn.env"
}

write_cdn_unit() {
  cat >"$UNIT_DIR/cloudflared-cdn-lite.service" <<EOF
[Unit]
Description=Cloudflare named tunnel for Speed Slayer Lite XHTTP
After=network-online.target xray-lite.service
Wants=network-online.target

[Service]
User=cloudflared
Group=cloudflared
EnvironmentFile=$APP_DIR/cloudflared-cdn.env
ExecStart=$BIN_DIR/cloudflared --no-autoupdate tunnel run
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

# add: (re)place the loopback XHTTP inbound described by state; remove: drop it.
# The SSE response header stays on: named tunnels stream text/event-stream bodies.
patch_cdn_inbound() {
  python3 - "$1" "$2" "$3" "$APP_DIR/state" <<'PY'
import json, pathlib, sys
mode, src, dst, state = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
config = json.loads(src.read_text(encoding='utf-8'))
s = dict(line.split('=', 1) for line in state.read_text(encoding='utf-8').splitlines())
inbounds = [n for n in config.get('inbounds', []) if n.get('tag') != 'vless-xhttp-cdn']
if mode == 'add':
    inbounds.append({'tag': 'vless-xhttp-cdn', 'listen': '127.0.0.1', 'port': int(s['CDN_PORT']), 'protocol': 'vless',
                     'settings': {'clients': [{'id': s['CDN_UUID']}], 'decryption': 'none'},
                     'streamSettings': {'network': 'xhttp', 'xhttpSettings': {'path': s['CDN_PATH'], 'mode': 'auto'}},
                     'sniffing': {'enabled': True, 'destOverride': ['http', 'tls', 'quic'], 'routeOnly': True}})
config['inbounds'] = inbounds
with dst.open('w', encoding='utf-8', newline='\n') as output:
    output.write(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
PY
}

# Print the service the remotely managed tunnel routes host $2 to, from connector log $1.
# Exit 2: no configuration received yet; exit 3: no route for the host.
cdn_ingress_service() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
host = sys.argv[2].lower()
configs = re.findall(r'Updated to new configuration config="(.*?)" version=', text)
if not configs:
    sys.exit(2)
try:
    config = json.loads(configs[-1].replace('\\"', '"'))
except ValueError:
    sys.exit(2)
for rule in config.get('ingress', []):
    if str(rule.get('hostname', '')).lower() == host:
        print(rule.get('service', ''))
        sys.exit(0)
sys.exit(3)
PY
}
cdn_connector_log() {
  local id
  id=$(systemctl show cloudflared-cdn-lite.service --property=InvocationID --value 2>/dev/null || true)
  journalctl -u cloudflared-cdn-lite.service ${id:+"_SYSTEMD_INVOCATION_ID=$id"} -o cat --no-pager 2>/dev/null || true
}
# Full proxy round trip through Cloudflare with a throwaway Xray client.
cdn_probe() (
  local dir port i code pid=''
  dir=$(mktemp -d)
  trap 'if [[ -n $pid ]]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi; rm -rf -- "$dir"' EXIT
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  python3 - "$dir/client.json" "$port" "$CDN_DOMAIN" "$CDN_UUID" "$CDN_PATH" <<'PY'
import json, sys
out, port, host, uuid, path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
json.dump({'log': {'loglevel': 'warning'},
           'inbounds': [{'listen': '127.0.0.1', 'port': port, 'protocol': 'socks', 'settings': {'udp': False}}],
           'outbounds': [{'protocol': 'vless',
                          'settings': {'vnext': [{'address': host, 'port': 443, 'users': [{'id': uuid, 'encryption': 'none'}]}]},
                          'streamSettings': {'network': 'xhttp', 'security': 'tls',
                                             'tlsSettings': {'serverName': host, 'fingerprint': 'chrome'},
                                             'xhttpSettings': {'host': host, 'path': path, 'mode': 'packet-up'}}}]},
          open(out, 'w', encoding='utf-8'))
PY
  "$BIN_DIR/xray" run -config "$dir/client.json" >"$dir/xray.log" 2>&1 &
  pid=$!
  for ((i = 0; i < 15; i++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "socks5h://127.0.0.1:$port" https://www.gstatic.com/generate_204 || true)
    [[ $code == 204 ]] && return 0
    sleep 2
  done
  return 1
)

verify_xhttp_cdn() {
  local file service='' status=2 i tries=${CDN_VERIFY_TRIES:-30}
  log '正在检查 Cloudflare 隧道路由和 XHTTP 连通性（通常数秒，最多约 3 分钟）...'
  file=$(mktemp)
  for ((i = 0; i < tries; i++)); do
    cdn_connector_log >"$file"
    if service=$(cdn_ingress_service "$file" "$CDN_DOMAIN"); then status=0; else status=$?; fi
    (( status == 2 )) || break
    sleep 2
  done
  rm -f -- "$file"
  case $status in
    0) [[ $service =~ ^http://(127\.0\.0\.1|localhost):${CDN_PORT}/?$ ]] ||
         die "隧道把 $CDN_DOMAIN 转发到 ${service:-（空）}，应为 http://127.0.0.1:$CDN_PORT；请在 Cloudflare 后台修改该路由的 Service URL 后重试。" ;;
    3) cdn_route_hint; die "隧道路由里没有 $CDN_DOMAIN，请按上面的提示添加后重试。" ;;
    *) die '没有读到隧道的远程路由配置；请确认 token 正确、隧道在 Cloudflare 后台管理，并查看 journalctl -u cloudflared-cdn-lite。' ;;
  esac
  cdn_probe || die "经 Cloudflare 访问 $CDN_DOMAIN 的 XHTTP 失败；请确认该主机名的 DNS 是指向此隧道的橙色云 CNAME，并查看 journalctl -u cloudflared-cdn-lite 与 xray-lite。"
  log "Cloudflare 隧道与 XHTTP 验证通过：$CDN_DOMAIN → 127.0.0.1:$CDN_PORT"
}

cdn_client_info() {
  local address=$CDN_ADDRESS link_address=$CDN_ADDRESS
  if [[ $address == *:* ]]; then link_address="[$address]"; fi
  printf 'VLESS + XHTTP + Cloudflare 隧道（%s，mode=packet-up）\n' "$CDN_DOMAIN"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%s&mode=packet-up#vless-xhttp-cdn\n' \
    "$CDN_UUID" "$link_address" "$CDN_DOMAIN" "$CDN_DOMAIN" "${CDN_PATH//\//%2F}"
  printf '\nmihomo（Clash Meta）配置片段：\n'
  printf -- '- name: vless-xhttp-cdn\n  type: vless\n  server: "%s"\n  port: 443\n  uuid: "%s"\n  network: xhttp\n' "$address" "$CDN_UUID"
  printf '  tls: true\n  udp: true\n  servername: "%s"\n  client-fingerprint: chrome\n' "$CDN_DOMAIN"
  printf '  xhttp-opts:\n    path: "%s"\n    host: "%s"\n    mode: packet-up\n' "$CDN_PATH" "$CDN_DOMAIN"
  printf '\n连接地址可换成 Cloudflare 优选域名或 IP；sni/servername 与 host 必须保持 %s。\n' "$CDN_DOMAIN"
}

cdn_instructions() {
  log "XHTTP + CF 隧道：$CDN_DOMAIN → 127.0.0.1:$CDN_PORT；本机无需开放任何入站端口，服务器 IP 被封也能使用。"
  log '同一个隧道 token 不要同时在两台机器上运行：Cloudflare 会把请求分给两台机器，XHTTP 会话会断开。'
}

do_add_xhttp_cdn() (
  need_root
  # Keep requested options across load_state; never re-generate existing protocols.
  local domain=${CDN_DOMAIN:-} token=${CDN_TOKEN:-} port=${CDN_PORT:-} address=${CDN_ADDRESS:-} path=${CDN_PATH:-} existing
  [[ -r $APP_DIR/state ]] || die '尚未安装 Lite；新装时直接勾选 5 即可。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled xhttpcdn && die '已安装 XHTTP + CF 隧道；更换主机名、token 或端口请先用菜单 14 移除。'
  xray_needed_without_cdn || die '当前只装了 AnyTLS，暂不支持追加；请卸载后在新装时勾选 5（可同时勾选 4）。'
  [[ ! -e $UNIT_DIR/cloudflared-cdn-lite.service && ! -e $APP_DIR/cloudflared-cdn.env ]] || die '存在未记录的 CF 隧道文件，请先检查，拒绝覆盖。'
  [[ -s $APP_DIR/xray.json ]] || die 'Xray 配置缺失，请先检查安装。'
  systemctl is-active --quiet xray-lite.service || die 'Xray 未运行；请先排查现有服务。'
  CDN_DOMAIN=$domain CDN_TOKEN=$token CDN_PORT=$port CDN_ADDRESS=$address CDN_PATH=$path
  if [[ ( -z $CDN_DOMAIN || -z $CDN_TOKEN ) && -t 0 ]]; then configure_xhttp_cdn || return 0; fi
  set_protocols "$PROTOCOLS,xhttpcdn"
  validate_cdn_options
  for existing in "$VMESS_PORT" "$SS_PORT" "$REALITY_PORT" "$REALITY_GUARD_PORT" "$ANYTLS_PORT"; do
    [[ -z $existing ]] || (( 10#$existing != 10#$CDN_PORT )) || die 'CDN_PORT 与已有节点端口重复。'
  done
  port_free "$CDN_PORT" || die "端口 $CDN_PORT 已占用。"
  install_packages
  need_cmd xray; need_cmd curl; need_cmd python3
  detect_arch
  cdn_backup=$(mktemp -d "$APP_DIR/backup-cdn-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$cdn_backup"
  cp -p "$APP_DIR/state" "$APP_DIR/xray.json" "$APP_DIR/install.sh" "$cdn_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$cdn_backup/"; fi
  cdn_changed=0 cdn_new_binary=0
  rollback_add_cdn() {
    local status=$? failed=0
    trap - EXIT INT TERM
    rm -rf -- "$cdn_backup/candidate" "$cdn_backup/next.json"
    if (( status != 0 && cdn_changed == 1 )); then
      log "追加 XHTTP + CF 隧道失败，恢复原节点：$cdn_backup"
      systemctl disable --now cloudflared-cdn-lite.service >/dev/null 2>&1 || true
      rm -f -- "$UNIT_DIR/cloudflared-cdn-lite.service" "$APP_DIR/cloudflared-cdn.env"
      if (( cdn_new_binary == 1 )); then rm -f -- "$BIN_DIR/cloudflared"; fi
      cp -p "$cdn_backup/state" "$cdn_backup/xray.json" "$cdn_backup/install.sh" "$APP_DIR/" || failed=1
      if [[ -f $cdn_backup/client-info.txt ]]; then
        cp -p "$cdn_backup/client-info.txt" "$APP_DIR/" || failed=1
      else
        rm -f -- "$APP_DIR/client-info.txt" || failed=1
      fi
      systemctl daemon-reload || failed=1
      systemctl restart xray-lite.service || failed=1
      systemctl is-active --quiet xray-lite.service || failed=1
      (( failed == 0 )) || log "自动恢复未完成，请检查 $cdn_backup 与 journalctl -u xray-lite。"
      if protocol_enabled vmess; then log "Quick Tunnel 域名可能已变化；运行 $APP show 刷新链接。"; fi
    elif (( status != 0 )) && [[ $cdn_backup == "$APP_DIR"/backup-cdn-* ]]; then
      rm -rf -- "$cdn_backup"   # nothing was changed, so this copy has no use
    fi
    exit "$status"
  }
  trap rollback_add_cdn EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ ! -x $BIN_DIR/cloudflared ]]; then stage_cloudflared_binary "$cdn_backup/candidate"; fi
  CDN_UUID=$(xray uuid)
  CDN_PATH=${CDN_PATH:-/$(openssl rand -hex 16)}
  cdn_changed=1
  if [[ -x $cdn_backup/candidate/cloudflared ]]; then
    cdn_new_binary=1
    replace_binary "$cdn_backup/candidate/cloudflared" "$BIN_DIR/cloudflared"
  fi
  create_cloudflared_user
  printf '%s\n' "PROTOCOLS=$PROTOCOLS" "CDN_DOMAIN=$CDN_DOMAIN" "CDN_ADDRESS=$CDN_ADDRESS" \
    "CDN_PORT=$CDN_PORT" "CDN_UUID=$CDN_UUID" "CDN_PATH=$CDN_PATH" | state_update
  write_cdn_env
  patch_cdn_inbound add "$APP_DIR/xray.json" "$cdn_backup/next.json"
  xray run -test -config "$cdn_backup/next.json"
  chown root:xray "$cdn_backup/next.json"
  chmod 0640 "$cdn_backup/next.json"
  mv -f "$cdn_backup/next.json" "$APP_DIR/xray.json"
  write_cdn_unit
  install_self
  systemctl daemon-reload
  systemctl restart xray-lite.service
  systemctl is-active --quiet xray-lite.service || die '追加后 Xray 未正常启动。'
  systemctl enable --now cloudflared-cdn-lite.service
  systemctl is-active --quiet cloudflared-cdn-lite.service || die 'CF 隧道启动失败，请检查 journalctl -u cloudflared-cdn-lite。'
  verify_xhttp_cdn
  # PartOf=xray-lite may have restarted the VMess Quick Tunnel with a new hostname.
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]] && ! wait_for_quick_domain; then
    log "尚未读到 Quick Tunnel 域名；稍后运行 $APP show。"
  fi
  write_client_info
  cdn_changed=0
  trap - EXIT INT TERM
  rm -rf -- "$cdn_backup/candidate"
  prune_backups backup-cdn "$cdn_backup"
  log '已追加 VLESS + XHTTP + Cloudflare 隧道；原有节点的凭据保持不变。'
  cdn_instructions
  cat "$APP_DIR/client-info.txt"
)

do_remove_xhttp_cdn() (
  need_root
  [[ -r $APP_DIR/state ]] || die '尚未安装 Lite。'
  need_cmd flock
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  load_state
  protocol_enabled xhttpcdn || die '未安装 XHTTP + CF 隧道。'
  local answer
  cdn_remaining=$(protocols_without xhttpcdn)
  [[ -n $cdn_remaining ]] || die '只安装了 XHTTP + CF 隧道；如需全部移除请选择卸载。'
  [[ ,$cdn_remaining, =~ ,(vmess|ss2022|vless), ]] || die '移除后只剩 AnyTLS，暂不支持；如需调整请卸载后重装。'
  if [[ ${1:-} != --yes ]]; then
    log '将停止 CF 隧道连接器，删除 XHTTP CDN 入站及其 UUID 和隧道 token；其他节点保持原样。'
    read -r -p '确认移除 XHTTP + CF 隧道？[y/N]: ' answer || answer=''
    [[ $answer == y || $answer == Y ]] || { log '已取消移除。'; return 0; }
  fi
  cdn_remove_backup=$(mktemp -d "$APP_DIR/backup-remove-cdn-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$cdn_remove_backup"
  cp -p "$APP_DIR/state" "$APP_DIR/xray.json" "$APP_DIR/cloudflared-cdn.env" "$UNIT_DIR/cloudflared-cdn-lite.service" "$cdn_remove_backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$cdn_remove_backup/"; fi
  cdn_remove_changed=0
  rollback_remove_cdn() {
    local status=$? failed=0
    trap - EXIT INT TERM
    rm -f -- "$cdn_remove_backup/next.json"
    if (( status != 0 && cdn_remove_changed == 1 )); then
      log "移除 XHTTP + CF 隧道失败，恢复原状态：$cdn_remove_backup"
      cp -p "$cdn_remove_backup/state" "$cdn_remove_backup/xray.json" "$cdn_remove_backup/cloudflared-cdn.env" "$APP_DIR/" || failed=1
      cp -p "$cdn_remove_backup/cloudflared-cdn-lite.service" "$UNIT_DIR/" || failed=1
      if [[ -f $cdn_remove_backup/client-info.txt ]]; then
        cp -p "$cdn_remove_backup/client-info.txt" "$APP_DIR/" || failed=1
      else
        rm -f -- "$APP_DIR/client-info.txt" || failed=1
      fi
      systemctl daemon-reload || failed=1
      systemctl restart xray-lite.service || failed=1
      systemctl enable --now cloudflared-cdn-lite.service || failed=1
      (( failed == 0 )) || log "自动恢复未完成，请检查 $cdn_remove_backup 与 journalctl -u xray-lite / cloudflared-cdn-lite。"
    fi
    exit "$status"
  }
  trap rollback_remove_cdn EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  patch_cdn_inbound remove "$APP_DIR/xray.json" "$cdn_remove_backup/next.json"
  xray run -test -config "$cdn_remove_backup/next.json"
  chown root:xray "$cdn_remove_backup/next.json"
  chmod 0640 "$cdn_remove_backup/next.json"
  cdn_remove_changed=1
  systemctl disable --now cloudflared-cdn-lite.service || true
  if systemctl is-active --quiet cloudflared-cdn-lite.service; then die 'CF 隧道连接器未能停止，未删除任何文件。'; fi
  mv -f "$cdn_remove_backup/next.json" "$APP_DIR/xray.json"
  printf '%s\n' "PROTOCOLS=$cdn_remaining" CDN_DOMAIN= CDN_ADDRESS= CDN_PORT= CDN_UUID= CDN_PATH= | state_update
  set_protocols "$cdn_remaining"
  systemctl restart xray-lite.service
  systemctl is-active --quiet xray-lite.service || die '移除后 Xray 未正常启动。'
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]] && ! wait_for_quick_domain; then
    log "尚未读到 Quick Tunnel 域名；稍后运行 $APP show。"
  fi
  write_client_info
  cdn_remove_changed=0
  trap - EXIT INT TERM
  rm -f -- "$UNIT_DIR/cloudflared-cdn-lite.service" "$APP_DIR/cloudflared-cdn.env"
  systemctl daemon-reload
  prune_backups backup-remove-cdn "$cdn_remove_backup"
  log "已移除 XHTTP + CF 隧道；其他节点、凭据和服务保持原样（cloudflared 程序保留）。原配置备份：$cdn_remove_backup"
  log '可用菜单 13 重新追加（例如换主机名、token 或端口）。'
  cat "$APP_DIR/client-info.txt"
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
  if protocol_enabled anytls; then
    prepare_anytls_identity
    ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(openssl rand -hex 32)}
  fi
  if protocol_enabled xhttpcdn; then
    CDN_UUID=$(xray uuid)
    CDN_PATH=${CDN_PATH:-/$(openssl rand -hex 16)}
  else
    CDN_DOMAIN='' CDN_ADDRESS='' CDN_PORT='' CDN_UUID='' CDN_PATH=''
  fi
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
ANYTLS_ADDRESS=${ANYTLS_ADDRESS:-}
CDN_DOMAIN=${CDN_DOMAIN:-}
CDN_ADDRESS=${CDN_ADDRESS:-}
CDN_PORT=${CDN_PORT:-}
CDN_UUID=${CDN_UUID:-}
CDN_PATH=${CDN_PATH:-}
EOF
  chmod 0600 "$APP_DIR/state"
  if protocol_enabled xhttpcdn; then write_cdn_env; fi
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
    # minClientVer stays unset: mihomo and sing-box report REALITY client version 1.8.2,
    # so a floor such as 1.8.3 would push them to the fallback site.
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
  if protocol_enabled xhttpcdn; then patch_cdn_inbound add "$APP_DIR/xray.json" "$APP_DIR/xray.json"; fi
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
  if protocol_enabled xhttpcdn; then write_cdn_unit; fi
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

anytls_selfsigned_info() {
  local pin
  pin=$(anytls_public_key_pin)
  python3 - "$APP_DIR" "$pin" <<'PY'
import ipaddress, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = dict(l.split('=', 1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
ip = ipaddress.ip_address(s['ANYTLS_ADDRESS'])
address = f'[{ip}]' if ip.version == 6 else str(ip)
password, port = s['ANYTLS_PASSWORD'], int(s['ANYTLS_PORT'])
if not re.fullmatch(r'[a-fA-F0-9]{64}', password) or not (port == 443 or 1024 <= port <= 65535):
    sys.exit('AnyTLS state 中的密码或端口无效。')
print('AnyTLS 自签 / IP 直连（无需填写 SNI；导入链接后还需信任下方公有证书）')
print(f'anytls://{password}@{address}:{port}/?security=tls&insecure=0#anytls-selfsigned')
print('\n公钥 SHA-256（Base64，供 sing-box 固定公钥校验）：' + sys.argv[2])
print('v2rayN：导入后编辑节点 → TLS 证书固定/证书，粘贴下面完整 PEM；不要填写私钥，不开启跳过验证。')
print((p/'tls/fullchain.pem').read_text(encoding='utf-8').strip())
print('\n标准 anytls:// 链接不携带证书信任；其他客户端需要单独配置。')
print('sing-box 1.13+ 完整客户端配置（含指纹）：speed-slayer-lite export-anytls-client')
PY
}

do_export_anytls_client() (
  need_root
  load_state
  protocol_enabled anytls && [[ $ANYTLS_CERT_MODE == selfsigned ]] || die '此命令用于导出自签 AnyTLS 的 sing-box 客户端配置。'
  pin=$(anytls_public_key_pin)
  python3 - "$APP_DIR/state" "$pin" <<'PY'
import ipaddress, json, pathlib, sys
s = dict(l.split('=', 1) for l in pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines())
ip = str(ipaddress.ip_address(s['ANYTLS_ADDRESS']))
c = {'log': {'level': 'warn'},
     'inbounds': [{'type': 'mixed', 'tag': 'local', 'listen': '127.0.0.1', 'listen_port': 10808}],
     'outbounds': [{'type': 'anytls', 'tag': 'proxy', 'server': ip, 'server_port': int(s['ANYTLS_PORT']),
                    'password': s['ANYTLS_PASSWORD'],
                    'tls': {'enabled': True, 'server_name': ip, 'insecure': False,
                            'certificate_public_key_sha256': [sys.argv[2]]}}]}
# An IP server_name suppresses wire SNI. Do not combine disable_sni with pinning:
# sing-box 1.14.4 would additionally enforce the system CA chain in that branch.
print(json.dumps(c, ensure_ascii=False, indent=2))
PY
)

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
    content+="$(mihomo_vless_yaml "$server")"$'\n\n'
  fi
  if protocol_enabled anytls; then
    if [[ $ANYTLS_CERT_MODE == selfsigned ]]; then
      content+="$(anytls_selfsigned_info)"$'\n\n'
    else
      validate_domain "$ANYTLS_SERVER_NAME" || die 'state 中的 ANYTLS_SERVER_NAME 无效'
      uri="anytls://${ANYTLS_PASSWORD}@${ANYTLS_SERVER_NAME}:${ANYTLS_PORT}/?sni=${ANYTLS_SERVER_NAME}&insecure=0#anytls"
      content+="AnyTLS + TLS（客户端使用 sing-box / mihomo；开启证书校验）"$'\n'"$uri"$'\n\n'
    fi
  fi
  if protocol_enabled xhttpcdn; then
    validate_domain "$CDN_DOMAIN" && valid_xhttp_path "$CDN_PATH" || die 'state 中的 CDN_DOMAIN / CDN_PATH 无效'
    content+="$(cdn_client_info)"$'\n\n'
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

# mihomo drops the X25519MLKEM768 key share unless told otherwise, and current REALITY
# servers treat such a Client Hello as unauthenticated, so the flag is mandatory.
mihomo_vless_yaml() {
  local server=${1#[} name=vless-xhttp-reality
  server=${server%]}
  [[ $VLESS_TRANSPORT == xhttp ]] || name=vless-reality
  printf 'mihomo（Clash Meta）配置片段（support-x25519mlkem768: true 不能删，否则服务端拒绝握手）：\n'
  printf -- '- name: %s\n  type: vless\n  server: "%s"\n  port: %s\n  uuid: "%s"\n' "$name" "$server" "$REALITY_PORT" "$VLESS_UUID"
  if [[ $VLESS_TRANSPORT == xhttp ]]; then
    printf '  network: xhttp\n  xhttp-opts:\n    path: "%s"\n' "$XHTTP_PATH"
  else
    printf '  network: tcp\n  flow: xtls-rprx-vision\n'
  fi
  printf '  tls: true\n  udp: true\n  servername: "%s"\n  client-fingerprint: chrome\n' "$REALITY_SERVER_NAME"
  printf '  reality-opts:\n    public-key: "%s"\n    short-id: "%s"\n    support-x25519mlkem768: true\n' "$REALITY_PUBLIC" "$REALITY_SHORT_ID"
}

configure_install() {
  local input item sni_mode value
  local -a choices=()
  ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0 ENABLE_XHTTPCDN=0
  while true; do
    printf '\n请选择需要创建的协议（输入编号切换勾选，可输入 1 3）：\n'
    printf '  [%s] 1. VMess + WebSocket + Argo\n' "$( [[ $ENABLE_VMESS == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 2. Shadowsocks 2022\n' "$( [[ $ENABLE_SS2022 == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 3. VLESS + XHTTP + REALITY\n' "$( [[ $ENABLE_VLESS == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 4. AnyTLS + TLS（域名证书 / 自签 IP 直连）\n' "$( [[ $ENABLE_ANYTLS == 1 ]] && printf x || printf ' ' )"
    printf '  [%s] 5. VLESS + XHTTP + Cloudflare 隧道（自有域名，IP 被封也能用）\n' "$( [[ $ENABLE_XHTTPCDN == 1 ]] && printf x || printf ' ' )"
    printf '  a. 全选 1–4（5 需要自有域名和隧道 token，请单独勾选）  n. 清空  0. 取消  回车：确认选择\n'
    read -r -p '请选择: ' input || return 1
    case $input in
      0) return 1 ;;
      a|A) ENABLE_VMESS=1 ENABLE_SS2022=1 ENABLE_VLESS=1 ENABLE_ANYTLS=1; continue ;;
      n|N) ENABLE_VMESS=0 ENABLE_SS2022=0 ENABLE_VLESS=0 ENABLE_ANYTLS=0 ENABLE_XHTTPCDN=0; continue ;;
      '')
        [[ $ENABLE_VMESS$ENABLE_SS2022$ENABLE_VLESS$ENABLE_ANYTLS$ENABLE_XHTTPCDN != 00000 ]] && break
        log '请至少勾选一个协议。'; continue ;;
    esac
    input=${input//,/ }
    [[ $input =~ ^[12345[:space:]]+$ ]] || { log '只接受编号 1、2、3、4、5。'; continue; }
    read -r -a choices <<<"$input"
    for item in "${choices[@]}"; do
      case $item in
        1) ENABLE_VMESS=$((1-ENABLE_VMESS)) ;;
        2) ENABLE_SS2022=$((1-ENABLE_SS2022)) ;;
        3) ENABLE_VLESS=$((1-ENABLE_VLESS)) ;;
        4) ENABLE_ANYTLS=$((1-ENABLE_ANYTLS)) ;;
        5) ENABLE_XHTTPCDN=$((1-ENABLE_XHTTPCDN)) ;;
        *) log '请用空格分隔编号，例如 1 3。' ;;
      esac
    done
  done
  value=''
  [[ $ENABLE_VMESS == 0 ]] || value=vmess
  [[ $ENABLE_SS2022 == 0 ]] || value="${value:+$value,}ss2022"
  [[ $ENABLE_VLESS == 0 ]] || value="${value:+$value,}vless"
  [[ $ENABLE_ANYTLS == 0 ]] || value="${value:+$value,}anytls"
  [[ $ENABLE_XHTTPCDN == 0 ]] || value="${value:+$value,}xhttpcdn"
  set_protocols "$value" || return 1
  if protocol_enabled vless; then
    while true; do
      printf '\nVLESS SNI：1. 默认 learn.microsoft.com  2. 自定义（可先用菜单 12 检查候选站）\n'
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
  if protocol_enabled xhttpcdn; then configure_xhttp_cdn || return 1; fi
  log "将创建：$PROTOCOLS"
}

validate_install_options() {
  set_protocols "${PROTOCOLS-vmess,ss2022,vless}" || die 'PROTOCOLS 只接受 vmess、ss2022、vless、anytls、xhttpcdn，用逗号分隔。'
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
    ANYTLS_CERT_FILE='' ANYTLS_KEY_FILE='' ANYTLS_EMAIL='' ANYTLS_ADDRESS=''
  fi
  if protocol_enabled xhttpcdn; then
    validate_cdn_options
    ACTIVE_PORTS+=("$CDN_PORT")
  else
    CDN_DOMAIN='' CDN_TOKEN='' CDN_ADDRESS='' CDN_PORT='' CDN_PATH=''
  fi
  for port in "${ACTIVE_PORTS[@]}"; do
    port=$((10#$port))
    [[ ! ${used[$port]+yes} ]] || die "已选协议的端口不能重复：$port"
    used[$port]=1
  done
}

remove_services_and_config() {
  local unit
  for unit in anytls-lite cloudflared-cdn-lite cloudflared-lite xray-lite; do
    if [[ -f $UNIT_DIR/$unit.service ]]; then
      systemctl disable --now "$unit.service" || true
      if systemctl is-active --quiet "$unit.service"; then die "$unit 仍在运行，未删除配置，请检查服务。"; fi
    fi
  done
  rm -f -- "$UNIT_DIR/anytls-lite.service" "$UNIT_DIR/cloudflared-cdn-lite.service" "$UNIT_DIR/cloudflared-lite.service" "$UNIT_DIR/xray-lite.service" "$SHORTCUT"
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
  # Resolve the self-signed IP before any download, so a bad address fails fast.
  if protocol_enabled anytls; then prepare_anytls_identity; fi
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
  if protocol_enabled xhttpcdn; then
    systemctl enable --now cloudflared-cdn-lite.service
    systemctl is-active --quiet cloudflared-cdn-lite.service || die 'CF 隧道启动失败，请运行 journalctl -u cloudflared-cdn-lite'
    verify_xhttp_cdn
  fi
  write_client_info
  trap - EXIT
  cat "$APP_DIR/client-info.txt"
  if protocol_enabled ss2022; then log "防火墙需开放 $SS_PORT/tcp+udp。"; fi
  if protocol_enabled vless; then log "防火墙需开放 $REALITY_PORT/tcp；无需开放内部守门端口。"; fi
  if protocol_enabled vmess; then log "VMess 使用 Argo，不要开放内部端口 $VMESS_PORT。请确保服务器和客户端自动对时正常。"; fi
  if protocol_enabled anytls; then anytls_instructions; fi
  if protocol_enabled xhttpcdn; then cdn_instructions; fi
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
  if protocol_enabled xhttpcdn; then services+=(cloudflared-cdn-lite.service); fi
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

# ---- REALITY target site checks -------------------------------------------------
# The probes are separate functions so tests can replace the network calls.
reality_probe_tls() {
  local -a groups=()
  # OpenSSL 3.5+ can offer X25519MLKEM768 like current browsers; older builds test X25519 only.
  if openssl list -kem-algorithms 2>/dev/null | grep -i X25519MLKEM768 >/dev/null; then
    groups=(-groups X25519MLKEM768:X25519)
  fi
  timeout 12 openssl s_client -connect "$1:443" -servername "$1" -verify_hostname "$1" \
    -alpn h2 "${groups[@]}" </dev/null 2>&1 | tr -d '\r\000' || true
}
reality_probe_http() {
  curl -sS -o /dev/null --max-time 12 -w '%{remote_ip}|%{time_connect}|%{http_code}|%{redirect_url}\n' \
    "https://$1/" 2>/dev/null || true
}
reality_target_normalize() {
  local d=${1#*://}
  d=${d%%[/:?#]*}
  printf '%s' "${d,,}"
}
reality_target_header() {
  printf '%-30s %-39s %7s %-7s %-4s %-15s %-9s %-4s %s\n' DOMAIN IP CONN_MS TLS ALPN GROUP CERT HTTP 结论
}
# Print one row for $1; succeed only when the site can serve as a REALITY target:
# TLS 1.3, h2, a certificate valid for the name, and a homepage that stays on it.
reality_target_check() {
  local d=$1 s re tls=- alpn=- group=- vcode='' cert ip='' tconn='' code='' redirect='' ms rhost verdict=可用
  local -a why=()
  s=$(reality_probe_tls "$d")
  re='New, (TLSv1\.[0-9])'; if [[ $s =~ $re ]]; then tls=${BASH_REMATCH[1]}; fi
  re='ALPN protocol: ([^[:space:]]+)'; if [[ $s =~ $re ]]; then alpn=${BASH_REMATCH[1]}; fi
  re='Negotiated TLS1\.3 group: ([^[:space:]]+)'
  if [[ $s =~ $re ]]; then
    group=${BASH_REMATCH[1]}
  else
    re='Server Temp Key: ([^,[:space:]]+)'; if [[ $s =~ $re ]]; then group=${BASH_REMATCH[1]}; fi
  fi
  [[ $group != '<NULL>' ]] || group=-
  re='Verify return code: ([0-9]+)'; if [[ $s =~ $re ]]; then vcode=${BASH_REMATCH[1]}; fi
  # s_client prints "Verify return code: 0" even when the handshake never completed.
  if [[ $tls == - ]]; then cert=-; elif [[ $vcode == 0 ]]; then cert=ok; else cert="bad(${vcode:-?})"; fi
  IFS='|' read -r ip tconn code redirect <<<"$(reality_probe_http "$d")" || true
  ms=$(awk -v t="${tconn:-0}" 'BEGIN { printf "%.1f", t * 1000 }')
  if [[ $tls == - ]]; then
    why+=('TLS握手失败')
  else
    [[ $tls == TLSv1.3 ]] || why+=('非TLS1.3')
    [[ $alpn == h2 ]] || why+=('无h2')
    [[ $cert == ok ]] || why+=('证书与域名不匹配或无效')
  fi
  case ${code:=000} in
    2??) ;;
    3??)
      rhost=${redirect#*://}; rhost=${rhost%%[/:?#]*}
      [[ -z $rhost || ${rhost,,} == "${d,,}" ]] || why+=("首页跳转到$rhost") ;;
    *) why+=("首页HTTP$code") ;;
  esac
  (( ${#why[@]} == 0 )) || verdict="不合格：${why[*]}"
  printf '%-30s %-39s %7s %-7s %-4s %-15s %-9s %-4s %s\n' "$d" "${ip:--}" "$ms" "$tls" "$alpn" "$group" "$cert" "$code" "$verdict"
  (( ${#why[@]} == 0 ))
}

# Check candidates from this server's own network; no arguments checks the current SNI.
do_check_reality_target() (
  local -a targets=()
  local d ok=0
  for d in "$@"; do targets+=("$(reality_target_normalize "$d")"); done
  if (( ${#targets[@]} == 0 )); then
    need_root
    [[ -r $APP_DIR/state ]] || die "用法: $APP check-reality-target 域名 [域名 ...]"
    load_state
    protocol_enabled vless || die '未安装 VLESS + REALITY；请在命令后写要检查的域名。'
    targets=("$REALITY_SERVER_NAME")
  fi
  need_cmd curl; need_cmd openssl; need_cmd timeout; need_cmd awk
  reality_target_header
  for d in "${targets[@]}"; do
    if ! validate_domain "$d"; then printf '%-30s %s\n' "$d" '不合格：域名格式无效'; continue; fi
    if reality_target_check "$d"; then ok=1; fi
  done
  log "本机公网 IP：$(public_ip)。IP 列最好与它同网段；CONN_MS 越小越近，同机房通常只有几毫秒。"
  (( ok == 1 )) || die '没有可用的目标站。'
)

prepare_reality_sni() {
  python3 - "$APP_DIR" "$1" "$2" <<'PY'
import json, pathlib, sys
root, stage, new = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
config = json.loads((root / 'xray.json').read_text(encoding='utf-8'))
state = {}
for line in (root / 'state').read_text(encoding='utf-8').splitlines():
    key, sep, value = line.partition('=')
    if not sep or key in state:
        sys.exit('state 格式错误或存在重复字段；未修改配置。')
    state[key] = value
old = state.get('REALITY_SERVER_NAME', '')
inbounds = config.get('inbounds', [])
guards = [n for n in inbounds if n.get('tag') == 'reality-guard']
nodes = [n for n in inbounds if n.get('tag') == 'vless-reality']
rules = [r for r in config.get('routing', {}).get('rules', [])
         if r.get('inboundTag') == ['reality-guard'] and 'domain' in r]
if len(guards) != 1 or len(nodes) != 1 or len(rules) != 1:
    sys.exit('未找到唯一的 Lite REALITY 守门入站、VLESS 入站和路由规则；未修改配置。')
guard = guards[0].setdefault('settings', {})
reality = nodes[0].get('streamSettings', {}).get('realitySettings', {})
if (not old or guard.get('address') != old or reality.get('serverNames') != [old]
        or rules[0]['domain'] != ['full:' + old]):
    sys.exit('xray.json 中的 SNI 与 state 不一致（可能手动改过）；拒绝覆盖，请手动维护。')
guard['address'] = new
reality['serverNames'] = [new]
rules[0]['domain'] = ['full:' + new]
state['REALITY_SERVER_NAME'] = new
with (stage / 'next.json').open('w', encoding='utf-8', newline='\n') as output:
    output.write(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
with (stage / 'next.state').open('w', encoding='utf-8', newline='\n') as output:
    output.write(''.join(f'{k}={v}\n' for k, v in state.items()))
PY
}

# Point REALITY (SNI, fallback guard and its routing rule) at another target site.
do_set_reality_sni() (
  need_root
  [[ -r $APP_DIR/state ]] || die '尚未安装 Lite。'
  load_state
  protocol_enabled vless || die '未安装 VLESS + REALITY，无需修改 SNI。'
  [[ -r $APP_DIR/xray.json ]] || die 'Xray 配置缺失，请先检查安装。'
  need_cmd xray; need_cmd systemctl; need_cmd flock; need_cmd python3
  local arg domain='' force=0 answer usage="用法: $APP set-reality-sni 域名 [--force]"
  for arg in "$@"; do
    case $arg in
      --force) force=1 ;;
      *) [[ -z $domain ]] || die "$usage"; domain=$(reality_target_normalize "$arg") ;;
    esac
  done
  if [[ -z $domain && -t 0 ]]; then
    read -r -p "新的 REALITY SNI（目标站域名）[当前 $REALITY_SERVER_NAME]: " domain || return 0
    domain=$(reality_target_normalize "$domain")
  fi
  [[ -n $domain ]] || die "$usage"
  validate_domain "$domain" || die "域名格式无效：$domain"
  if [[ $domain == "$REALITY_SERVER_NAME" ]]; then log "SNI 已经是 $domain，无需修改。"; return 0; fi
  exec 9>"$APP_DIR/manage.lock"
  flock -n 9 || die '另一项维护操作仍在运行。'
  systemctl is-active --quiet xray-lite.service || die 'Xray 未运行；请先排查现有服务。'
  need_cmd curl; need_cmd openssl; need_cmd timeout; need_cmd awk
  log "正在从本机检查目标站 $domain ..."
  reality_target_header
  if ! reality_target_check "$domain"; then
    if (( force == 0 )) && [[ -t 0 ]]; then
      read -r -p '该站点不满足 REALITY 目标站要求，仍要使用？[y/N]: ' answer || answer=''
      [[ $answer == y || $answer == Y ]] || { log '已取消，未修改配置。'; return 0; }
    elif (( force == 0 )); then
      die '目标站检查未通过，未修改配置；确认要用请加 --force。'
    fi
    log '目标站检查未通过，按要求继续修改。'
  fi
  # Subshell-scoped variables survive function unwinding for the EXIT trap.
  changed=0
  backup=$(mktemp -d "$APP_DIR/backup-sni-$(date +%Y%m%d%H%M%S).XXXXXX")
  chmod 0700 "$backup"
  cp -p "$APP_DIR/xray.json" "$APP_DIR/state" "$backup/"
  if [[ -f $APP_DIR/client-info.txt ]]; then cp -p "$APP_DIR/client-info.txt" "$backup/"; fi

  rollback_sni() {
    local status=$? failed=0
    trap - EXIT INT TERM
    if (( status != 0 && changed == 1 )); then
      log "修改 SNI 失败，正在恢复 $backup 中的配置"
      cp -p "$backup/xray.json" "$APP_DIR/xray.json" || failed=1
      cp -p "$backup/state" "$APP_DIR/state" || failed=1
      if [[ -f $backup/client-info.txt ]]; then
        cp -p "$backup/client-info.txt" "$APP_DIR/client-info.txt" || failed=1
      else
        rm -f -- "$APP_DIR/client-info.txt" || failed=1
      fi
      systemctl restart xray-lite.service || failed=1
      systemctl is-active --quiet xray-lite.service || failed=1
      (( failed == 0 )) || log "自动恢复未完成，请检查备份 $backup 与 journalctl -u xray-lite。"
      if protocol_enabled vmess; then log "Quick Tunnel 域名可能已变化；恢复后运行 $APP show 刷新链接。"; fi
    elif (( status != 0 )) && [[ $backup == "$APP_DIR"/backup-sni-* ]]; then
      rm -rf -- "$backup"   # nothing was changed, so this copy has no use
    fi
    exit "$status"
  }
  trap rollback_sni EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  prepare_reality_sni "$backup" "$domain"
  xray run -test -config "$backup/next.json"
  chown root:xray "$backup/next.json"
  chmod 0640 "$backup/next.json"
  chmod 0600 "$backup/next.state"
  changed=1
  mv -f "$backup/next.json" "$APP_DIR/xray.json"
  mv -f "$backup/next.state" "$APP_DIR/state"
  systemctl restart xray-lite.service
  systemctl is-active --quiet xray-lite.service || die '修改后 Xray 未正常启动。'
  # PartOf=xray-lite may restart the Tunnel and rotate its temporary hostname.
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]] && ! wait_for_quick_domain; then
    log "尚未读到 Quick Tunnel 域名；稍后运行 $APP show。"
  fi
  write_client_info
  changed=0
  trap - EXIT INT TERM
  prune_backups backup-sni "$backup"
  log "REALITY SNI 已从 $REALITY_SERVER_NAME 改为 $domain；端口、UUID、密钥、shortId 和路径不变。原配置备份：$backup"
  cat "$APP_DIR/client-info.txt"
  log '客户端需把 SNI / servername 改成新域名，或重新导入 VLESS 链接。'
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]]; then log '如 Quick Tunnel 域名变化，也请重新导入 VMess 链接。'; fi
)

restart_selected_services() {
  local -a services=()
  if xray_enabled; then services+=(xray-lite.service); fi
  if protocol_enabled vmess; then services+=(cloudflared-lite.service); fi
  if protocol_enabled anytls; then services+=(anytls-lite.service); fi
  if protocol_enabled xhttpcdn; then services+=(cloudflared-cdn-lite.service); fi
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
  if cloudflared_needed; then [[ -x $BIN_DIR/cloudflared ]] || die 'cloudflared 不存在，请先检查安装。'; fi
  if protocol_enabled vmess; then
    systemctl is-active --quiet cloudflared-lite.service || die 'Argo 未运行，请先修复隧道。'
  fi
  if protocol_enabled xhttpcdn; then
    systemctl is-active --quiet cloudflared-cdn-lite.service || die 'XHTTP 的 CF 隧道连接器未运行，请先检查 journalctl -u cloudflared-cdn-lite。'
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
  if cloudflared_needed; then cp -p "$BIN_DIR/cloudflared" "$update_backup/cloudflared"; fi
  if protocol_enabled anytls; then
    cp -p "$APP_DIR/bin/sing-box" "$update_backup/sing-box"
    cp -p "$APP_DIR/anytls.json" "$UNIT_DIR/anytls-lite.service" "$update_backup/"
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
      if cloudflared_needed; then replace_binary "$update_backup/cloudflared" "$BIN_DIR/cloudflared" || failed=1; fi
      if protocol_enabled anytls; then replace_binary "$update_backup/sing-box" "$APP_DIR/bin/sing-box" || failed=1; fi
      if [[ -f $update_backup/anytls-lite.service ]] && ! cmp -s "$update_backup/anytls-lite.service" "$UNIT_DIR/anytls-lite.service"; then
        cp -p "$update_backup/anytls-lite.service" "$UNIT_DIR/anytls-lite.service" || failed=1
        systemctl daemon-reload || failed=1
      fi
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
    # Recovery uses the old binaries in the backup root, never the staged release.
    rm -rf -- "$update_backup/candidate"
    prune_backups backup-update "$update_backup"
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
  if cloudflared_needed; then replace_binary "$update_backup/candidate/cloudflared" "$BIN_DIR/cloudflared"; fi
  if protocol_enabled anytls; then replace_binary "$update_backup/candidate/sing-box" "$APP_DIR/bin/sing-box"; fi
  # Units written by older releases lack the MPTCP opt-out; regenerate from state.
  if protocol_enabled anytls && ! grep -qxF "$ANYTLS_NO_MPTCP" "$UNIT_DIR/anytls-lite.service"; then
    write_anytls_unit
    systemctl daemon-reload
    log 'AnyTLS 服务单元已加入 GODEBUG=multipathtcp=0（关闭 MPTCP 监听）。'
  fi
  mv -f "$update_backup/next.install.sh" "$APP_DIR/install.sh"
  restart_selected_services
  if protocol_enabled anytls; then verify_anytls_tls; fi
  if protocol_enabled xhttpcdn; then verify_xhttp_cdn; fi
  if protocol_enabled vmess && [[ $ARGO_MODE == quick ]]; then
    wait_for_quick_domain || die '更新后未获取到 Quick Tunnel 域名，正在恢复旧版。'
  fi
  write_client_info
  update_changed=0
  trap - EXIT INT TERM
  rm -rf -- "$update_backup/candidate"
  prune_backups backup-update "$update_backup"
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

# Run one menu action in a subshell: a failure returns to the menu, and values an
# action generates (passwords, paths) cannot leak into a later reinstall. Not written
# as `action || ...`, because that context would switch off errexit inside the action.
menu_run() {
  local status
  set +e
  ( set -e; "$@" )
  status=$?
  set -e
  (( status == 0 )) || log "操作未完成（退出码 $status），已返回菜单。"
}

menu() {
  need_root
  local choice value
  local -a targets=()
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
9. 刷新 AnyTLS 证书（外部续期 / 自签续期）
10. 移除 AnyTLS（保留其他节点）
11. 修改 VLESS REALITY 的 SNI / 目标站
12. 检查 REALITY 目标站（TLS 1.3 / h2 / 证书 / 距离）
13. 追加 VLESS + XHTTP + Cloudflare 隧道（保留其他节点）
14. 移除 VLESS + XHTTP + Cloudflare 隧道（保留其他节点）
0. 退出
EOF
    read -r -p '请选择: ' choice || return 0
    case $choice in
      0) return 0 ;;
      1)
        if [[ -r $APP_DIR/state ]]; then log '已安装。更新请选 4；重新选择协议需先卸载，原节点凭据会被删除。'; continue; fi
        configure_install || continue
        menu_run do_install ;;
      12)
        # Works before installation too, so a custom SNI can be checked first.
        read -r -p '要检查的域名（空格分隔；已装 VLESS 时回车检查当前 SNI）: ' value || continue
        read -r -a targets <<<"$value"
        menu_run do_check_reality_target "${targets[@]}" ;;
      2|3|4|5|6|7|8|9|10|11|13|14)
        if [[ ! -r $APP_DIR/state ]]; then log '请先选择 1 创建节点。'; continue; fi
        case $choice in
          2) menu_run do_show ;;
          3) menu_run do_status ;;
          4) menu_run do_update; return ;;
          5) menu_run do_uninstall ;;
          6) menu_run do_repair_argo ;;
          7) menu_run do_migrate_xhttp ;;
          8) menu_run do_add_anytls ;;
          9) menu_run do_refresh_anytls_cert ;;
          10) menu_run do_remove_anytls ;;
          11)
            read -r -p '新的 REALITY SNI（目标站域名）: ' value || continue
            menu_run do_set_reality_sni ${value:+"$value"} ;;
          13) menu_run do_add_xhttp_cdn ;;
          14) menu_run do_remove_xhttp_cdn ;;
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
    remove-anytls) do_remove_anytls "${2:-}" ;;
    export-anytls-client) do_export_anytls_client ;;
    set-reality-sni) shift; do_set_reality_sni "$@" ;;
    check-reality-target) shift; do_check_reality_target "$@" ;;
    add-xhttp-cdn) do_add_xhttp_cdn ;;
    remove-xhttp-cdn) do_remove_xhttp_cdn "${2:-}" ;;
    uninstall) do_uninstall "${2:-}" ;;
    *) die "用法: $0 {menu|install|show|status|update|repair-argo|migrate-xhttp|add-anytls|refresh-anytls-cert|remove-anytls [--yes]|export-anytls-client|set-reality-sni 域名 [--force]|check-reality-target [域名 ...]|add-xhttp-cdn|remove-xhttp-cdn [--yes]|uninstall [--yes]}" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
