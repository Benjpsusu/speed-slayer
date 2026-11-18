#!/usr/bin/env bash
# Regression checks for the review fixes; package manager, downloads and systemd are mocked.
# SPEED_REVIEW_INSTALLER may point at another installer to show these checks catch the old bugs.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER=${SPEED_REVIEW_INSTALLER:-$TEST_DIR/install-review.sh}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/speed-review-test.XXXXXX")
export SPEED_ANYTLS_ROOT="$TEST_ROOT"
cleanup() {
  local status=$? resolved parent
  if (( status != 0 )); then tail -n 25 "$TEST_ROOT/operation.log" 2>/dev/null || true; fi
  resolved=$(cd "$TEST_ROOT" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-review-test.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
awk -v root="$TEST_ROOT" '
  /^readonly APP_DIR=/ {print "readonly APP_DIR=\"" root "/app\""; next}
  /^readonly BIN_DIR=/ {print "readonly BIN_DIR=\"" root "/shared\""; next}
  /^readonly UNIT_DIR=/ {print "readonly UNIT_DIR=\"" root "/units\""; next}
  /^readonly SHORTCUT=/ {print "readonly SHORTCUT=\"" root "/shortcut\""; next}
  {print}
' "$INSTALLER" >"$TEST_ROOT/installer.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/installer.sh"
if [[ -n ${SPEED_TEST_PYTHON:-} ]]; then python3() { "$SPEED_TEST_PYTHON" "$@" | tr -d '\r'; }; fi
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
need_root() { :; }
install_packages() { :; }
need_cmd() { [[ $1 == ss ]] || command -v "$1" >/dev/null; }
flock() { [[ ! -f $TEST_ROOT/locked ]]; }
uname() { case $1 in -m) echo x86_64;; -s) echo Linux;; -r) echo '6.1-test';; esac; }
chown() { [[ ${*: -1} == "$TEST_ROOT/"* ]] || fail 'unexpected chown'; }
install() {
  local -a args=()
  while (( $# )); do
    case $1 in -o|-g) shift 2;; *) args+=("$1"); shift;; esac
  done
  command install "${args[@]}"
}
create_anytls_user() { mkdir -p "$APP_DIR/tls" "$APP_DIR/acme"; chmod 0711 "$APP_DIR"; }
create_users() { mkdir -p "$APP_DIR"; if protocol_enabled anytls; then create_anytls_user; fi; }
port_free() { [[ $1 != "${BUSY_PORT:-none}" ]]; }
public_ip() { [[ ! -f $TEST_ROOT/fail-info ]] || return 1; echo 203.0.113.15; }
detect_anytls_ip() { [[ ! -f $TEST_ROOT/fail-ip ]] || return 1; echo 203.0.113.15; }
quick_domain() { echo fixture.trycloudflare.com; }
wait_for_quick_domain() { :; }
verify_anytls_tls() { [[ ! -f $TEST_ROOT/fail-tls ]]; }
openssl() { command openssl "$@" | tr -d '\r'; }
xray() {
  case $1 in
    uuid) python3 -c 'import uuid;print(uuid.uuid4())' ;;
    x25519) printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
    run) [[ ! -f $TEST_ROOT/fail-xray ]] ;;
  esac
}
systemctl() {
  printf '%s\n' "$*" >>"$TEST_ROOT/services.log"
  case $1 in
    restart|enable)
      if [[ -f $TEST_ROOT/fail-start ]]; then rm "$TEST_ROOT/fail-start"; return 42; fi
      rm -f "$TEST_ROOT/stopped" ;;
    is-active) [[ ! -f $TEST_ROOT/stopped ]] ;;
    disable) touch "$TEST_ROOT/stopped" ;;
    daemon-reload|--no-pager) : ;;
    *) fail "unexpected systemctl $*" ;;
  esac
}
expect_failure() {
  local status
  set +e
  (set -e; "$@") >"$TEST_ROOT/operation.log" 2>&1
  status=$?
  set -e
  (( status != 0 )) || fail "expected failure: $*"
}
download_checked() {
  printf '%s\n' "$1" >>"$TEST_ROOT/download.log"
  [[ ! -f $TEST_ROOT/fail-download ]] || die 'simulated checksum failure'
  printf 'mock release\n' >"$2"
}
write_mock_binary() {
  cat >"$1" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ $1 == version ]]; then echo 'sing-box version 1.14.4'; exit; fi
[[ ! -f $SPEED_ANYTLS_ROOT/fail-config ]] || exit 42
exec "${SPEED_TEST_PYTHON:-python3}" -m json.tool "$3"
MOCK
  chmod 0755 "$1"
}
tar() { write_mock_binary "$4/sing-box"; }
unzip() { fail 'review checks must not download Xray'; }

mkdir -p "$TEST_ROOT/certs"
python3 - "$TEST_ROOT/certs" <<'PY'
import pathlib, subprocess, sys
p=pathlib.Path(sys.argv[1])
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3',
                '-subj','/CN=at.example.test','-addext','subjectAltName=DNS:at.example.test',
                '-keyout',str(p/'key.pem'),'-out',str(p/'cert.pem')],check=True,capture_output=True)
PY

fixture() {
  rm -rf -- "$APP_DIR" "$UNIT_DIR" "$BIN_DIR" "$TEST_ROOT/golden"
  rm -f -- "$TEST_ROOT"/fail-* "$TEST_ROOT/services.log" "$TEST_ROOT/download.log" "$TEST_ROOT/stopped"
  mkdir -p "$APP_DIR" "$UNIT_DIR" "$BIN_DIR" "$TEST_ROOT/golden"
  PROTOCOLS=$1
  VMESS_PORT=30000 SS_PORT=30001 REALITY_PORT=30002 REALITY_GUARD_PORT=30003
  VMESS_ADDRESS=www.wto.org REALITY_SERVER_NAME=learn.microsoft.com XHTTP_PATH=/fixture
  ARGO_MODE=token ARGO_DOMAIN=tunnel.example.com ARGO_TOKEN=test-token
  ANYTLS_PORT=18443 ANYTLS_SERVER_NAME=at.example.test ANYTLS_PASSWORD=''
  ANYTLS_CERT_MODE=${2:-file} ANYTLS_EMAIL=test@example.com ANYTLS_ADDRESS=203.0.113.15
  ANYTLS_CERT_FILE="$TEST_ROOT/certs/cert.pem" ANYTLS_KEY_FILE="$TEST_ROOT/certs/key.pem"
  validate_install_options
  create_users
  write_config
  write_units
  write_client_info
  cp "$TEST_ROOT/installer.sh" "$APP_DIR/install.sh"
  printf '\n# previous-release\n' >>"$APP_DIR/install.sh"
  printf 'unrelated shared binary\n' >"$BIN_DIR/sing-box"
  if protocol_enabled anytls; then mkdir -p "$APP_DIR/bin"; write_mock_binary "$APP_DIR/bin/sing-box"; fi
  cp -p "$APP_DIR/state" "$APP_DIR/client-info.txt" "$APP_DIR/install.sh" "$TEST_ROOT/golden/"
  if [[ -f $APP_DIR/xray.json ]]; then cp -p "$APP_DIR/xray.json" "$TEST_ROOT/golden/"; fi
  if [[ -f $APP_DIR/anytls.json ]]; then cp -p "$APP_DIR/anytls.json" "$TEST_ROOT/golden/"; fi
}
assert_saved() {
  local name
  for name in state client-info.txt install.sh; do cmp "$APP_DIR/$name" "$TEST_ROOT/golden/$name" || fail "changed $name"; done
  if [[ -f $TEST_ROOT/golden/xray.json ]]; then cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"; fi
  if [[ -f $TEST_ROOT/golden/anytls.json ]]; then cmp "$APP_DIR/anytls.json" "$TEST_ROOT/golden/anytls.json"; fi
}
count_dirs() { local n=0 dir; for dir in "$@"; do [[ ! -d $dir ]] || n=$((n+1)); done; echo "$n"; }
assert_cert_clean() {
  openssl x509 -in "$1" -noout -text >"$TEST_ROOT/cert.txt"
  [[ $(grep -c 'X509v3 Basic Constraints' "$TEST_ROOT/cert.txt") == 1 ]] || fail 'basicConstraints must appear once'
  grep -q 'CA:FALSE' "$TEST_ROOT/cert.txt" || fail 'self-signed leaf must be CA:FALSE'
  ! grep -q 'from-system-config' "$TEST_ROOT/cert.txt" || fail 'system OpenSSL req defaults leaked into the certificate'
  grep -q "IP Address:$2" "$TEST_ROOT/cert.txt" || fail 'IP SAN missing'
}

# 1. Self-signed certificates must not inherit the system req section. On OpenSSL 1.1.1
# that section's v3_ca is appended before -addext, which produced duplicate extensions.
system_conf="$TEST_ROOT/system-openssl.cnf"
printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = v3_ca' '[dn]' '[v3_ca]' \
  'basicConstraints = critical,CA:true' 'nsComment = "from-system-config"' >"$system_conf"
if command -v cygpath >/dev/null 2>&1; then system_conf=$(cygpath -m "$system_conf"); fi
export OPENSSL_CONF=$system_conf
fixture anytls selfsigned
assert_cert_clean "$APP_DIR/tls/fullchain.pem" 203.0.113.15
cp -p "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
do_refresh_anytls_cert >"$TEST_ROOT/operation.log" 2>&1
assert_cert_clean "$APP_DIR/tls/fullchain.pem" 203.0.113.15
cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem" || fail 'renewal rotated the key'
unset OPENSSL_CONF
pass 'self-signed issue/renewal ignore system OpenSSL req defaults: one CA:FALSE basicConstraints'

# 2. Certificates repeating an extension are rejected before sing-box sees them.
python3 - "$TEST_ROOT/certs/cert.pem" "$TEST_ROOT/certs/dup.pem" <<'PY'
import base64, pathlib, re, sys
pem = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
der = base64.b64decode(''.join(re.search(r'-----BEGIN CERTIFICATE-----(.*?)-----END', pem, re.S).group(1).split()))
def read(buf, pos):
    tag, size = buf[pos], buf[pos+1]; pos += 2
    if size & 0x80:
        n = size & 0x7f; size = int.from_bytes(buf[pos:pos+n], 'big'); pos += n
    return tag, pos, pos + size
def children(buf):
    _, pos, end = read(buf, 0); out = []
    while pos < end:
        _, _, nxt = read(buf, pos); out.append(buf[pos:nxt]); pos = nxt
    return out
def enc(tag, body):
    n = len(body)
    if n < 0x80:
        return bytes([tag, n]) + body
    size = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([tag, 0x80 | len(size)]) + size + body
cert = children(der); tbs = children(cert[0])
i = next(i for i, part in enumerate(tbs) if part[0] == 0xA3)
exts = children(children(tbs[i])[0])
exts.append(next(x for x in exts if b'\x06\x03\x55\x1d\x0e' in x[:12]))  # repeat subjectKeyIdentifier
tbs[i] = enc(0xA3, enc(0x30, b''.join(exts)))
cert[0] = enc(0x30, b''.join(tbs))
b64 = base64.b64encode(enc(0x30, b''.join(cert))).decode()
lines = '\n'.join(b64[k:k+64] for k in range(0, len(b64), 64))
pathlib.Path(sys.argv[2]).write_bytes(f'-----BEGIN CERTIFICATE-----\n{lines}\n-----END CERTIFICATE-----\n'.encode())
PY
openssl x509 -in "$TEST_ROOT/certs/dup.pem" -noout -subject >/dev/null || fail 'fixture must remain parseable by OpenSSL'
fixture vless,anytls
check_anytls_certificate "$TEST_ROOT/certs/cert.pem" "$TEST_ROOT/certs/key.pem" >/dev/null
expect_failure check_anytls_certificate "$TEST_ROOT/certs/dup.pem" "$TEST_ROOT/certs/key.pem"
grep -q '重复扩展' "$TEST_ROOT/operation.log" || fail 'duplicate extension not reported'
pass 'certificate with a repeated extension is rejected with a clear message; normal certificate passes'

# 3. Updates and refreshes drop staged releases and keep a bounded number of backups.
fixture anytls
for _ in 1 2 3 4 5; do apply_update >"$TEST_ROOT/operation.log" 2>&1; done
latest=$(sed -n 's/.*旧版备份：//p' "$TEST_ROOT/operation.log")
[[ -s $latest/sing-box && -s $latest/state ]] || fail 'current update backup lost its recovery files'
[[ $(count_dirs "$APP_DIR"/backup-update-*) == 3 ]] || fail 'update backups not pruned to 3'
[[ $(count_dirs "$APP_DIR"/backup-update-*/candidate) == 0 ]] || fail 'staged release left after update'
touch "$TEST_ROOT/fail-config"
expect_failure apply_update
[[ $(count_dirs "$APP_DIR"/backup-update-*) == 3 && $(count_dirs "$APP_DIR"/backup-update-*/candidate) == 0 ]] || fail 'failed update left staged release or extra backups'
rm "$TEST_ROOT/fail-config"
fixture anytls selfsigned
for _ in 1 2 3 4; do do_refresh_anytls_cert >"$TEST_ROOT/operation.log" 2>&1; done
[[ $(count_dirs "$APP_DIR"/backup-cert-*) == 3 ]] || fail 'certificate backups not pruned to 3'
pass 'update/refresh remove staged releases (success and failure) and keep the newest 3 backups'

# 4. remove-anytls keeps other nodes, restores on failure, and allows a different re-add.
fixture vless,anytls
do_remove_anytls <<< '' >"$TEST_ROOT/operation.log" 2>&1
assert_saved
[[ -f $APP_DIR/anytls.json ]] || fail 'default answer must cancel removal'
touch "$TEST_ROOT/locked"
expect_failure do_remove_anytls --yes
rm "$TEST_ROOT/locked"
assert_saved
touch "$TEST_ROOT/fail-info"
expect_failure do_remove_anytls --yes
assert_saved
[[ -f $APP_DIR/anytls.json && -d $APP_DIR/tls && -f $UNIT_DIR/anytls-lite.service && -x $APP_DIR/bin/sing-box ]] || fail 'failed removal deleted AnyTLS files'
grep -qx 'enable --now anytls-lite.service' "$TEST_ROOT/services.log" || fail 'failed removal did not restart AnyTLS'
[[ ! -f $TEST_ROOT/stopped ]] || fail 'AnyTLS left stopped after failed removal'
rm -f "$TEST_ROOT/fail-info" "$TEST_ROOT/services.log"
do_remove_anytls --yes >"$TEST_ROOT/operation.log" 2>&1
python3 - "$APP_DIR" "$TEST_ROOT/golden/state" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
read = lambda f: dict(l.split('=', 1) for l in pathlib.Path(f).read_text(encoding='utf-8').splitlines())
now, old = read(p/'state'), read(sys.argv[2])
assert now['PROTOCOLS'] == 'vless'
assert all(v == '' for k, v in now.items() if k.startswith('ANYTLS_'))
assert all(now[k] == v for k, v in old.items() if k != 'PROTOCOLS' and not k.startswith('ANYTLS_'))
info = (p/'client-info.txt').read_text(encoding='utf-8')
assert 'vless://' in info and 'anytls://' not in info
PY
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json" || fail 'removal changed Xray config'
[[ ! -e $APP_DIR/anytls.json && ! -e $UNIT_DIR/anytls-lite.service && ! -e $APP_DIR/tls && ! -e $APP_DIR/acme && ! -e $APP_DIR/bin ]] || fail 'AnyTLS files left'
[[ -s $BIN_DIR/sing-box && -s $TEST_ROOT/certs/key.pem ]] || fail 'removal touched shared binary or source certificate'
! grep -qE 'xray-lite|cloudflared-lite' "$TEST_ROOT/services.log" || fail 'removal touched other services'
ANYTLS_CERT_MODE=selfsigned ANYTLS_ADDRESS=203.0.113.20 ANYTLS_PORT=18444 ANYTLS_SERVER_NAME='' ANYTLS_PASSWORD=''
do_add_anytls >"$TEST_ROOT/operation.log" 2>&1
grep -qx 'ANYTLS_CERT_MODE=selfsigned' "$APP_DIR/state" && grep -qx 'ANYTLS_ADDRESS=203.0.113.20' "$APP_DIR/state" || fail 'mode/IP change via re-add'
[[ $(count_dirs "$APP_DIR"/backup-anytls-*/candidate) == 0 ]] || fail 'add left staged release'
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json" || fail 're-add changed Xray config'
fixture anytls
expect_failure do_remove_anytls --yes
grep -q '卸载' "$TEST_ROOT/operation.log" || fail 'AnyTLS-only removal should point to uninstall'
assert_saved
pass 'remove-anytls: cancel/lock/failure restore, keeps VLESS, then re-add with new mode and IP'

# 5. The menu survives failed actions and a reinstall gets fresh credentials.
rm -rf -- "$APP_DIR" "$UNIT_DIR" "$BIN_DIR"
rm -f -- "$TEST_ROOT/stopped"
mkdir -p "$UNIT_DIR" "$BIN_DIR"
unset PROTOCOLS ANYTLS_PORT ANYTLS_SERVER_NAME ANYTLS_PASSWORD ANYTLS_CERT_MODE ANYTLS_CERT_FILE ANYTLS_KEY_FILE ANYTLS_EMAIL ANYTLS_ADDRESS XHTTP_PATH
# Install AnyTLS, fail "add AnyTLS" (8) and "repair Argo" (6), uninstall, then install again.
menu >"$TEST_ROOT/menu.log" 2>&1 <<< $'1\n4\n\n3\n\n18443\n8\n6\n5\ny\n1\n4\n\n3\n\n18443\n0'
trap cleanup EXIT
mapfile -t links < <(grep '^anytls://' "$TEST_ROOT/menu.log")
(( ${#links[@]} == 2 )) || fail "expected two installs, got ${#links[@]}"
first=${links[0]#anytls://} second=${links[1]#anytls://}
[[ ${first%%@*} != "${second%%@*}" ]] || fail 'reinstall in the same menu session reused the AnyTLS password'
[[ $(grep -c '已返回菜单' "$TEST_ROOT/menu.log") == 2 ]] || fail 'failed actions (8, 6) should return to the menu'
[[ -s $APP_DIR/state ]] || fail 'second install missing'
pass 'menu returns after failed add/Argo repair; reinstall in one session generates a new password'

# 6. Interactive AnyTLS input is validated where it is entered.
reset_anytls() { unset ANYTLS_PORT ANYTLS_SERVER_NAME ANYTLS_CERT_MODE ANYTLS_CERT_FILE ANYTLS_KEY_FILE ANYTLS_EMAIL ANYTLS_ADDRESS REALITY_PORT; }
cert=$TEST_ROOT/certs/cert.pem key=$TEST_ROOT/certs/key.pem
mkdir -p "$APP_DIR"
printf 'inside\n' >"$APP_DIR/inside.pem"
reset_anytls
configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'4\n\n2\nat.example.test\n\nrelative.pem\n/nonexistent/cert.pem\n'"$cert"$'\n'"$APP_DIR/inside.pem"$'\n'"$key"
[[ $ANYTLS_CERT_MODE == file && $ANYTLS_CERT_FILE == "$cert" && $ANYTLS_KEY_FILE == "$key" && $ANYTLS_PORT == 443 ]] || fail 'certificate path retry'
[[ $(grep -c '之外可读文件的绝对路径' "$TEST_ROOT/ui.log") == 3 ]] || fail 'invalid paths not reported'
reset_anytls
configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'4\n\n1\nat.example.test\n18443\nbad-email\nadmin@example.com'
[[ $ANYTLS_CERT_MODE == acme && $ANYTLS_EMAIL == admin@example.com ]] || fail 'email retry'
reset_anytls
BUSY_PORT=80 configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'4\n\n1\n\n\n'
[[ $ANYTLS_CERT_MODE == selfsigned && $ANYTLS_PORT == 443 ]] || fail 'busy 80 must refuse ACME and default to self-signed'
grep -q '80 已占用' "$TEST_ROOT/ui.log" || fail 'busy 80 not explained'
reset_anytls
BUSY_PORT=18443 configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'4\n\n3\nexample.com\n203.0.113.20\n18443\n18444'
[[ $ANYTLS_ADDRESS == 203.0.113.20 && $ANYTLS_PORT == 18444 ]] || fail 'IP/busy port retry'
reset_anytls
configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'3 4\n\n\n443\n3\n\n443\n8443'
[[ $REALITY_PORT == 443 && $ANYTLS_PORT == 8443 ]] || fail 'AnyTLS port equal to VLESS accepted'
reset_anytls
! configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'4\n\n2\nat.example.test\n\nrelative.pem' || fail 'EOF during retry must cancel'
pass 'interactive certificate path, email, busy 80/port, VLESS port clash and IP retried in place'

# 7. A fresh self-signed install resolves its IP before downloading anything.
rm -rf -- "$APP_DIR" "$UNIT_DIR"
mkdir -p "$UNIT_DIR"
rm -f -- "$TEST_ROOT/download.log"
touch "$TEST_ROOT/fail-ip"
PROTOCOLS=anytls ANYTLS_CERT_MODE=selfsigned ANYTLS_ADDRESS='' ANYTLS_PORT=18443 ANYTLS_PASSWORD='' expect_failure do_install
[[ ! -s $TEST_ROOT/download.log && ! -e $APP_DIR/state ]] || fail 'IP detection failure must stop before downloads'
rm "$TEST_ROOT/fail-ip"
pass 'self-signed IP detection failure stops a fresh install before any download'

# Offline stand-ins for the REALITY target probes (s_client / curl output per domain).
mkdir -p "$TEST_ROOT/probe"
reality_probe_tls() {
  cat "$TEST_ROOT/probe/$1.tls" 2>/dev/null ||
    printf '%s\n' 'CONNECTED(00000003)' 'no peer certificate available' 'Server Temp Key: <NULL>' \
      'New, (NONE), Cipher is (NONE)' 'Verify return code: 0 (ok)'
}
reality_probe_http() { cat "$TEST_ROOT/probe/$1.http" 2>/dev/null || printf '|0.000000|000|\n'; }
probe() {
  local domain=$1 style=$2
  case $style in
    ok35) printf '%s\n' 'CONNECTED(00000003)' '---' 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' \
            'Protocol: TLSv1.3' 'ALPN protocol: h2' 'Verify return code: 0 (ok)' 'Negotiated TLS1.3 group: X25519MLKEM768' ;;
    ok111) printf '%s\n' 'CONNECTED(00000003)' 'Server Temp Key: X25519, 253 bits' '---' \
            'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' 'Server public key is 256 bit' 'ALPN protocol: h2' \
            'Early data was not sent' 'Verify return code: 0 (ok)' ;;
    tls12) printf '%s\n' 'CONNECTED(00000003)' 'Server Temp Key: X25519, 253 bits' \
            'New, TLSv1.2, Cipher is ECDHE-RSA-AES128-GCM-SHA256' 'No ALPN negotiated' 'Verify return code: 0 (ok)' ;;
    mismatch) printf '%s\n' 'CONNECTED(00000003)' 'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
            'ALPN protocol: h2' 'Verify return code: 62 (hostname mismatch)' 'Negotiated TLS1.3 group: X25519' ;;
  esac >"$TEST_ROOT/probe/$domain.tls"
  printf '%s\n' "$3" >"$TEST_ROOT/probe/$domain.http"
}
probe speedtest.wobcom.de ok35 '198.51.100.7|0.004213|200|'
probe learn.microsoft.com ok35 '198.51.100.8|0.001500|302|https://learn.microsoft.com/en-us/'

# 8. Xray is pinned at or above 26.10.31 (MPTCP listeners off) with verified hashes, and
# AnyTLS sing-box gets the same opt-out: new units carry it, updates add it to older units.
[[ $(printf '%s\n' 26.10.31 "$XRAY_VERSION" | sort -V | head -n1) == 26.10.31 ]] || fail "Xray $XRAY_VERSION predates the MPTCP fix"
for arch in x86_64 aarch64; do
  uname() { case $1 in -m) echo "$arch";; -s) echo Linux;; -r) echo '6.1-test';; esac; }
  detect_arch >/dev/null
  case $arch in
    x86_64) [[ $XRAY_SHA == b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82 ]] ;;
    aarch64) [[ $XRAY_SHA == 64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be ]] ;;
  esac || fail "Xray $arch hash differs from the published 26.11.9 digest"
done
uname() { case $1 in -m) echo x86_64;; -s) echo Linux;; -r) echo '6.1-test';; esac; }
no_mptcp='Environment=GODEBUG=multipathtcp=0'
fixture anytls
grep -qxF "$no_mptcp" "$UNIT_DIR/anytls-lite.service" || fail 'new AnyTLS unit leaves MPTCP on'
sed -i "/^${no_mptcp}\$/d" "$UNIT_DIR/anytls-lite.service"
cp -p "$UNIT_DIR/anytls-lite.service" "$TEST_ROOT/old-unit"
rm -f "$TEST_ROOT/services.log"
touch "$TEST_ROOT/fail-start"
expect_failure apply_update
cmp "$UNIT_DIR/anytls-lite.service" "$TEST_ROOT/old-unit" || fail 'failed update did not restore the AnyTLS unit'
[[ $(grep -cx 'daemon-reload' "$TEST_ROOT/services.log") == 2 ]] || fail 'unit rewrite/restore must reload systemd'
rm -f "$TEST_ROOT/services.log"
apply_update >"$TEST_ROOT/operation.log" 2>&1
grep -qxF "$no_mptcp" "$UNIT_DIR/anytls-lite.service" || fail 'update did not add the MPTCP opt-out'
diff <(grep -vxF "$no_mptcp" "$UNIT_DIR/anytls-lite.service") "$TEST_ROOT/old-unit" >/dev/null || fail 'update changed other unit lines'
grep -qx 'daemon-reload' "$TEST_ROOT/services.log" || fail 'rewritten unit not reloaded'
rm -f "$TEST_ROOT/services.log"
apply_update >"$TEST_ROOT/operation.log" 2>&1
! grep -qx 'daemon-reload' "$TEST_ROOT/services.log" || fail 'up-to-date unit rewritten again'
pass 'Xray >= 26.10.31 with published hashes; AnyTLS unit disables MPTCP, update adds it and restores on failure'

# 9. set-reality-sni changes only the three SNI fields, checks the target first and rolls back.
fixture vmess,ss2022,vless,anytls
expect_failure do_set_reality_sni 'not a domain'
assert_saved
expect_failure do_set_reality_sni untested.example.test
grep -q -- '--force' "$TEST_ROOT/operation.log" || fail 'failed target check must mention --force'
assert_saved
touch "$TEST_ROOT/locked"
expect_failure do_set_reality_sni speedtest.wobcom.de
rm "$TEST_ROOT/locked"
assert_saved
touch "$TEST_ROOT/fail-xray"
expect_failure do_set_reality_sni speedtest.wobcom.de
rm "$TEST_ROOT/fail-xray"
assert_saved
[[ $(count_dirs "$APP_DIR"/backup-sni-*) == 0 ]] || fail 'unchanged failure left a backup'
rm -f "$TEST_ROOT/services.log"
touch "$TEST_ROOT/fail-start"
expect_failure do_set_reality_sni speedtest.wobcom.de
assert_saved
[[ $(grep -cx 'restart xray-lite.service' "$TEST_ROOT/services.log") == 2 ]] || fail 'failed restart was not rolled back and restarted'
rm -f "$TEST_ROOT/services.log"
do_set_reality_sni 'https://Speedtest.Wobcom.de/some/path' >"$TEST_ROOT/operation.log" 2>&1
python3 - "$APP_DIR" "$TEST_ROOT/golden" <<'PY'
import json, pathlib, sys
p, g = map(pathlib.Path, sys.argv[1:])
read = lambda f: dict(l.split('=', 1) for l in f.read_text(encoding='utf-8').splitlines())
now, old = read(p/'state'), read(g/'state')
new = 'speedtest.wobcom.de'
assert now.pop('REALITY_SERVER_NAME') == new and old.pop('REALITY_SERVER_NAME') == 'learn.microsoft.com'
assert now == old, 'other state fields changed'
c, o = (json.loads(f.read_text(encoding='utf-8')) for f in (p/'xray.json', g/'xray.json'))
for n in o['inbounds']:
    if n['tag'] == 'reality-guard': n['settings']['address'] = new
    if n['tag'] == 'vless-reality': n['streamSettings']['realitySettings']['serverNames'] = [new]
for r in o['routing']['rules']:
    if 'domain' in r: r['domain'] = ['full:' + new]
assert c == o, 'xray.json changed beyond the three SNI fields'
info, before = ((d/'client-info.txt').read_text(encoding='utf-8').splitlines() for d in (p, g))
keep = lambda lines: [l for l in lines if l.startswith(('vmess://', 'ss://', 'anytls://'))]
assert keep(info) == keep(before) and len(keep(info)) == 3, 'other links changed'
assert f'sni={new}&' in next(l for l in info if l.startswith('vless://'))
assert f'  servername: "{new}"' in info
PY
cmp "$APP_DIR/anytls.json" "$TEST_ROOT/golden/anytls.json" || fail 'SNI change touched AnyTLS'
[[ $(cat "$TEST_ROOT/services.log") == $'is-active --quiet xray-lite.service\nrestart xray-lite.service\nis-active --quiet xray-lite.service' ]] ||
  fail "SNI change should restart only Xray: $(tr '\n' ';' <"$TEST_ROOT/services.log")"
do_set_reality_sni speedtest.wobcom.de >"$TEST_ROOT/operation.log" 2>&1
grep -q '无需修改' "$TEST_ROOT/operation.log" || fail 'same SNI should be a no-op'
do_set_reality_sni untested.example.test --force >"$TEST_ROOT/operation.log" 2>&1
grep -qx 'REALITY_SERVER_NAME=untested.example.test' "$APP_DIR/state" || fail '--force must accept a failing target'
for name in learn.microsoft.com speedtest.wobcom.de learn.microsoft.com; do do_set_reality_sni "$name" >"$TEST_ROOT/operation.log" 2>&1; done
[[ $(count_dirs "$APP_DIR"/backup-sni-*) == 3 ]] || fail 'SNI backups not pruned to 3'
menu >"$TEST_ROOT/menu.log" 2>&1 <<< $'11\nspeedtest.wobcom.de\n0'
trap cleanup EXIT
grep -qx 'REALITY_SERVER_NAME=speedtest.wobcom.de' "$APP_DIR/state" || fail 'menu 11 did not change the SNI'
python3 - "$APP_DIR/xray.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text(encoding='utf-8'))
next(n for n in c['inbounds'] if n['tag'] == 'vless-reality')['streamSettings']['realitySettings']['serverNames'].append('extra.example.test')
p.write_text(json.dumps(c, indent=2) + '\n', encoding='utf-8')
PY
cp -p "$APP_DIR/xray.json" "$APP_DIR/state" "$TEST_ROOT/golden/"
expect_failure do_set_reality_sni learn.microsoft.com
grep -q '手动改过' "$TEST_ROOT/operation.log" || fail 'hand-edited serverNames must be refused'
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json" && cmp "$APP_DIR/state" "$TEST_ROOT/golden/state" || fail 'refusal changed files'
fixture anytls
expect_failure do_set_reality_sni speedtest.wobcom.de
grep -q '未安装 VLESS' "$TEST_ROOT/operation.log" || fail 'AnyTLS-only install must be refused'
pass 'set-reality-sni: validation/target check/lock/xray-test/restart failures restore; success edits only SNI fields'

# 10. check-reality-target judges TLS 1.3, h2, certificate and homepage redirects.
probe good.example.test ok35 '198.51.100.9|0.002100|200|'
probe old.example.test ok111 '198.51.100.10|0.003000|302|https://old.example.test/en/'
probe hop.example.test ok35 '198.51.100.11|0.002000|301|https://www.hop.example.test/'
probe tls12.example.test tls12 '198.51.100.12|0.002000|200|'
probe wrong.example.test mismatch '198.51.100.13|0.002000|000|'
probe 404.example.test ok35 '198.51.100.14|0.002000|404|'
do_check_reality_target good.example.test https://Old.Example.Test/x hop.example.test tls12.example.test \
  wrong.example.test 404.example.test down.example.test 'not a domain' >"$TEST_ROOT/check.log" 2>&1
row() { grep -E "^$1 " "$TEST_ROOT/check.log" || fail "no row for $1"; }
[[ $(row 'good\.example\.test') =~ 198\.51\.100\.9\ +2\.1\ TLSv1\.3\ h2\ +X25519MLKEM768\ +ok\ +200\ +可用$ ]] || fail 'good target row'
[[ $(row 'old\.example\.test') =~ \ X25519\ .*\ 302\ +可用$ ]] || fail 'OpenSSL 1.1.1 output / same-host redirect'
[[ $(row 'hop\.example\.test') == *'首页跳转到www.hop.example.test' ]] || fail 'cross-host redirect accepted'
[[ $(row 'tls12\.example\.test') == *'非TLS1.3 无h2' ]] || fail 'TLS 1.2 accepted'
[[ $(row 'wrong\.example\.test') =~ bad\(62\).*证书与域名不匹配或无效 ]] || fail 'hostname mismatch accepted'
[[ $(row '404\.example\.test') == *'首页HTTP404' ]] || fail '404 homepage accepted'
[[ $(row 'down\.example\.test') =~ ^down\.example\.test\ +-\ .*\ -\ +000\ +不合格：TLS握手失败\ 首页HTTP000$ ]] || fail 'failed handshake must not count as a valid certificate'
grep -q '^not a domain .*域名格式无效' "$TEST_ROOT/check.log" || fail 'invalid name not reported'
grep -q '本机公网 IP：203.0.113.15' "$TEST_ROOT/check.log" || fail 'server IP hint missing'
expect_failure do_check_reality_target hop.example.test down.example.test
grep -q '没有可用的目标站' "$TEST_ROOT/operation.log" || fail 'no usable target must fail'
fixture vless
do_check_reality_target >"$TEST_ROOT/check.log" 2>&1
row 'learn\.microsoft\.com' >/dev/null
rm -rf -- "$APP_DIR"
menu >"$TEST_ROOT/menu.log" 2>&1 <<< $'12\ngood.example.test hop.example.test\n0'
trap cleanup EXIT
grep -q '^good\.example\.test .*可用$' "$TEST_ROOT/menu.log" && grep -q '^hop\.example\.test .*不合格' "$TEST_ROOT/menu.log" || fail 'menu 12 before install'
pass 'check-reality-target: verdicts for TLS/h2/cert/redirect/404/handshake failure, current SNI and menu 12'

# 11. show prints a mihomo block with support-x25519mlkem768 for XHTTP and legacy TCP nodes.
fixture vless
mihomo_check() {
  python3 - "$APP_DIR" "$1" "$2" <<'PY'
import pathlib, sys
p, transport, host = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
s = dict(l.split('=', 1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
info = (p/'client-info.txt').read_text(encoding='utf-8')
block = info.split('mihomo（Clash Meta）配置片段', 1)[1].split('\n\n', 1)[0].splitlines()[1:]
want = ['- name: ' + ('vless-xhttp-reality' if transport == 'xhttp' else 'vless-reality'), '  type: vless',
        f'  server: "{host}"', f"  port: {s['REALITY_PORT']}", f"  uuid: \"{s['VLESS_UUID']}\""]
want += (['  network: xhttp', '  xhttp-opts:', f"    path: \"{s['XHTTP_PATH']}\""] if transport == 'xhttp'
         else ['  network: tcp', '  flow: xtls-rprx-vision'])
want += ['  tls: true', '  udp: true', f"  servername: \"{s['REALITY_SERVER_NAME']}\"", '  client-fingerprint: chrome',
         '  reality-opts:', f"    public-key: \"{s['REALITY_PUBLIC']}\"", f"    short-id: \"{s['REALITY_SHORT_ID']}\"",
         '    support-x25519mlkem768: true']
assert block == want, '\n'.join(block)
PY
}
mihomo_check xhttp 203.0.113.15
public_ip() { echo 2001:db8::15; }
write_client_info
grep -q '^vless://[^@]*@\[2001:db8::15\]:' "$APP_DIR/client-info.txt" || fail 'IPv6 link must keep brackets'
mihomo_check xhttp 2001:db8::15
public_ip() { [[ ! -f $TEST_ROOT/fail-info ]] || return 1; echo 203.0.113.15; }
sed -i 's/^VLESS_TRANSPORT=.*/VLESS_TRANSPORT=tcp/' "$APP_DIR/state"
write_client_info
mihomo_check tcp 203.0.113.15
pass 'show: mihomo block (quoted values, IPv6 without brackets, XHTTP/TCP) always sets support-x25519mlkem768'

# Shared stand-ins for the Cloudflare tunnel cases; keep the real verifier for case 14.
eval "$(declare -f verify_xhttp_cdn | sed '1s/^verify_xhttp_cdn/real_verify_xhttp_cdn/')"
verify_xhttp_cdn() { printf 'verify %s %s\n' "$CDN_DOMAIN" "$CDN_PORT" >>"$TEST_ROOT/cdn-verify.log"; [[ ! -f $TEST_ROOT/fail-cdn ]]; }
stage_cloudflared_binary() {
  [[ ! -f $TEST_ROOT/fail-download ]] || die 'simulated download failure'
  mkdir -p "$1"; printf '#!/usr/bin/env bash\necho cloudflared-mock\n' >"$1/cloudflared"; chmod 0755 "$1/cloudflared"
}
create_cloudflared_user() { :; }
synthetic_token() {  # $1 = JSON body; never a real credential
  python3 -c 'import base64, sys; print(base64.b64encode(sys.argv[1].encode()).decode().rstrip("="))' "$1" | tr -d '\r'
}
TOK=$(synthetic_token '{"a":"0123456789abcdef0123456789abcdef","t":"11111111-2222-3333-4444-555555555555","s":"c2VjcmV0LWZvci10ZXN0cw=="}')
NOT_TUNNEL=$(synthetic_token '{"a":"0123456789abcdef0123456789abcdef","s":"c2VjcmV0LWZvci10ZXN0cw=="}')
cdn_env() { CDN_DOMAIN=cdn.example.test CDN_TOKEN=$TOK CDN_PORT=18090; unset CDN_ADDRESS CDN_PATH; }

# 12. VLESS + XHTTP behind a Cloudflare named tunnel: token parsing, config, client info, prompts.
[[ $(cdn_token_tunnel_id "$TOK" | tr -d '\r') == 11111111-2222-3333-4444-555555555555 ]] || fail 'tunnel id not read from token'
[[ $(cdn_extract_token "sudo cloudflared service install $TOK") == "$TOK" ]] || fail 'token not extracted from the install command'
! cdn_token_tunnel_id "$NOT_TUNNEL" >/dev/null || fail 'token without tunnel id accepted'
! cdn_token_tunnel_id 'not-a-token' >/dev/null || fail 'garbage token accepted'
PROTOCOLS=xhttpcdn CDN_DOMAIN=cdn.example.test CDN_TOKEN=bad expect_failure validate_install_options
grep -q 'CDN_TOKEN 无效' "$TEST_ROOT/operation.log" || fail 'bad token message'
PROTOCOLS=xhttpcdn CDN_DOMAIN='bad host' CDN_TOKEN=$TOK expect_failure validate_install_options
PROTOCOLS=vless,xhttpcdn REALITY_PORT=30002 CDN_PORT=30002 CDN_DOMAIN=cdn.example.test CDN_TOKEN=$TOK expect_failure validate_install_options
PROTOCOLS=xhttpcdn CDN_DOMAIN=cdn.example.test CDN_TOKEN=$TOK CDN_ADDRESS='104.16.0.1:443' expect_failure validate_install_options
cdn_env; CDN_TOKEN="sudo cloudflared service install $TOK" CDN_ADDRESS=104.16.0.1
fixture vless,xhttpcdn
python3 - "$APP_DIR" "$UNIT_DIR" "$TOK" <<'PY'
import json, pathlib, re, sys, urllib.parse
p, units, tok = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
s = dict(l.split('=', 1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
assert s['PROTOCOLS'] == 'vless,xhttpcdn' and s['CDN_DOMAIN'] == 'cdn.example.test' and s['CDN_PORT'] == '18090'
assert s['CDN_ADDRESS'] == '104.16.0.1' and re.fullmatch(r'[0-9a-f-]{36}', s['CDN_UUID']) and re.fullmatch(r'/[0-9a-f]{32}', s['CDN_PATH'])
assert tok not in (p/'state').read_text(encoding='utf-8'), 'token must not be stored in state'
assert (p/'cloudflared-cdn.env').read_text(encoding='utf-8') == f'TUNNEL_TOKEN={tok}\n'
c = json.loads((p/'xray.json').read_text(encoding='utf-8'))
assert [n['tag'] for n in c['inbounds']] == ['reality-guard', 'vless-reality', 'vless-xhttp-cdn']
n = c['inbounds'][-1]
assert n['listen'] == '127.0.0.1' and n['port'] == 18090 and n['protocol'] == 'vless'
assert n['settings'] == {'clients': [{'id': s['CDN_UUID']}], 'decryption': 'none'}
assert n['streamSettings'] == {'network': 'xhttp', 'xhttpSettings': {'path': s['CDN_PATH'], 'mode': 'auto'}}, 'no TLS / no noSSEHeader on the loopback inbound'
unit = (units/'cloudflared-cdn-lite.service').read_text(encoding='utf-8')
assert re.search(r'^EnvironmentFile=\S+/cloudflared-cdn\.env$', unit, re.M) and 'tunnel run' in unit and '--no-autoupdate' in unit
assert 'User=cloudflared' in unit and tok not in unit
info = (p/'client-info.txt').read_text(encoding='utf-8')
link = next(l for l in info.splitlines() if l.startswith('vless://') and 'type=xhttp&host=' in l)
u = urllib.parse.urlsplit(link); q = urllib.parse.parse_qs(u.query)
assert u.username == s['CDN_UUID'] and u.hostname == '104.16.0.1' and u.port == 443 and u.fragment == 'vless-xhttp-cdn'
assert q == {'encryption': ['none'], 'security': ['tls'], 'sni': ['cdn.example.test'], 'fp': ['chrome'], 'type': ['xhttp'],
             'host': ['cdn.example.test'], 'path': [s['CDN_PATH']], 'mode': ['packet-up']}, q
block = info.split('- name: vless-xhttp-cdn', 1)[1].split('\n\n', 1)[0].splitlines()[1:]
assert block == ['  type: vless', '  server: "104.16.0.1"', '  port: 443', f'  uuid: "{s["CDN_UUID"]}"', '  network: xhttp',
                 '  tls: true', '  udp: true', '  servername: "cdn.example.test"', '  client-fingerprint: chrome',
                 '  xhttp-opts:', f'    path: "{s["CDN_PATH"]}"', '    host: "cdn.example.test"', '    mode: packet-up'], block
assert any(l.startswith('vless://') and 'security=reality' in l for l in info.splitlines()), 'REALITY node kept'
PY
sed -i 's/^CDN_ADDRESS=.*/CDN_ADDRESS=2606:4700::1/' "$APP_DIR/state"
write_client_info
grep -q '^vless://[^@]*@\[2606:4700::1\]:443?' "$APP_DIR/client-info.txt" && grep -qx '  server: "2606:4700::1"' "$APP_DIR/client-info.txt" || fail 'IPv6 preferred address formatting'
unset CDN_DOMAIN CDN_TOKEN CDN_PORT CDN_ADDRESS CDN_PATH
configure_install >"$TEST_ROOT/ui.log" 2>&1 <<< $'5\n\nHTTPS://CDN.Example.Test/x\nbad-token\nsudo cloudflared service install '"$TOK"$'\n70000\n\n1.2.3.4:5\n\n'
[[ $PROTOCOLS == xhttpcdn && $CDN_DOMAIN == cdn.example.test && $CDN_TOKEN == "$TOK" && $CDN_PORT == 30004 && $CDN_ADDRESS == cdn.example.test ]] ||
  fail "interactive CDN input: $PROTOCOLS $CDN_DOMAIN $CDN_PORT $CDN_ADDRESS"
for msg in 'token 无效' '端口应为' '应为域名或 IP' 'Service URL http://127.0.0.1:30004' '隧道 ID：11111111-2222-3333-4444-555555555555'; do
  grep -q "$msg" "$TEST_ROOT/ui.log" || fail "prompt output missing: $msg"
done
! grep -q "$TOK" "$TEST_ROOT/ui.log" || fail 'token echoed to the terminal'
pass 'xhttpcdn: token parsing/extraction, loopback inbound, env-only token, unit, link + mihomo, IPv6 address, prompts'

# 13. add-xhttp-cdn / remove-xhttp-cdn keep other nodes; failures roll back; update covers the connector.
fixture anytls
cdn_env
expect_failure do_add_xhttp_cdn
grep -q '只装了 AnyTLS' "$TEST_ROOT/operation.log" || fail 'AnyTLS-only add must be refused'
fixture vless
cp -p "$APP_DIR/xray.json" "$TEST_ROOT/pre-cdn-xray.json"
cdn_env
touch "$TEST_ROOT/locked"; expect_failure do_add_xhttp_cdn; rm "$TEST_ROOT/locked"; assert_saved
CDN_PORT=30002 expect_failure do_add_xhttp_cdn
grep -q 'CDN_PORT 与已有节点端口重复' "$TEST_ROOT/operation.log" || fail 'port clash with REALITY not reported'
BUSY_PORT=18090 expect_failure do_add_xhttp_cdn; assert_saved
for fault in fail-xray fail-cdn fail-download; do
  rm -f "$TEST_ROOT/services.log"; touch "$TEST_ROOT/$fault"
  expect_failure do_add_xhttp_cdn
  rm -f "$TEST_ROOT/$fault"
  assert_saved
  [[ ! -e $UNIT_DIR/cloudflared-cdn-lite.service && ! -e $APP_DIR/cloudflared-cdn.env && ! -e $BIN_DIR/cloudflared ]] || fail "$fault left tunnel files or a newly staged binary"
  if [[ $fault != fail-download ]]; then grep -qx 'restart xray-lite.service' "$TEST_ROOT/services.log" || fail "$fault: Xray not restarted on rollback"; fi
done
rm -f "$TEST_ROOT/services.log" "$TEST_ROOT/cdn-verify.log"
do_add_xhttp_cdn >"$TEST_ROOT/operation.log" 2>&1
python3 - "$APP_DIR" "$TEST_ROOT/golden" "$TEST_ROOT/pre-cdn-xray.json" <<'PY'
import json, pathlib, sys
p, g, pre = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
read = lambda f: dict(l.split('=', 1) for l in f.read_text(encoding='utf-8').splitlines())
now, old = read(p/'state'), read(g/'state')
assert now['PROTOCOLS'] == 'vless,xhttpcdn' and now['CDN_DOMAIN'] == 'cdn.example.test' and now['CDN_ADDRESS'] == 'cdn.example.test'
assert all(now[k] == v for k, v in old.items() if k != 'PROTOCOLS' and not k.startswith('CDN_')), 'existing credentials changed'
c, o = json.loads((p/'xray.json').read_text(encoding='utf-8')), json.loads(pre.read_text(encoding='utf-8'))
assert c['inbounds'][:-1] == o['inbounds'] and c['inbounds'][-1]['tag'] == 'vless-xhttp-cdn' and c['routing'] == o['routing']
info, before = (p/'client-info.txt').read_text(encoding='utf-8'), (g/'client-info.txt').read_text(encoding='utf-8')
reality = lambda t: [l for l in t.splitlines() if l.startswith('vless://') and 'security=reality' in l]
assert reality(info) == reality(before) and '#vless-xhttp-cdn' in info
PY
[[ -s $UNIT_DIR/cloudflared-cdn-lite.service && -s $APP_DIR/cloudflared-cdn.env && -x $BIN_DIR/cloudflared ]] || fail 'add did not install connector files'
grep -qx 'verify cdn.example.test 18090' "$TEST_ROOT/cdn-verify.log" || fail 'add did not verify the tunnel'
grep -qx 'enable --now cloudflared-cdn-lite.service' "$TEST_ROOT/services.log" || fail 'connector not enabled'
# Kept: the two failures that changed files and the success; the download failure changed nothing.
[[ $(count_dirs "$APP_DIR"/backup-cdn-*) == 3 && $(count_dirs "$APP_DIR"/backup-cdn-*/candidate) == 0 ]] || fail 'add backup handling'
expect_failure do_add_xhttp_cdn
grep -q '已安装 XHTTP + CF 隧道' "$TEST_ROOT/operation.log" || fail 'second add must be refused'
cp -p "$APP_DIR/state" "$APP_DIR/xray.json" "$APP_DIR/client-info.txt" "$APP_DIR/install.sh" "$TEST_ROOT/golden/"
do_remove_xhttp_cdn <<< '' >"$TEST_ROOT/operation.log" 2>&1
assert_saved
touch "$TEST_ROOT/fail-xray"; expect_failure do_remove_xhttp_cdn --yes; rm "$TEST_ROOT/fail-xray"
assert_saved
[[ -e $UNIT_DIR/cloudflared-cdn-lite.service && -e $APP_DIR/cloudflared-cdn.env ]] || fail 'failed removal deleted tunnel files'
rm -f "$TEST_ROOT/services.log"; touch "$TEST_ROOT/fail-start"
expect_failure do_remove_xhttp_cdn --yes
assert_saved
grep -qx 'enable --now cloudflared-cdn-lite.service' "$TEST_ROOT/services.log" || fail 'failed removal did not restart the connector'
do_remove_xhttp_cdn --yes >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/xray.json" "$TEST_ROOT/pre-cdn-xray.json" || fail 'removal did not restore the original Xray config'
grep -qx 'PROTOCOLS=vless' "$APP_DIR/state" && ! grep -qE '^CDN_[A-Z]+=.+' "$APP_DIR/state" || fail 'removal left CDN state'
[[ ! -e $UNIT_DIR/cloudflared-cdn-lite.service && ! -e $APP_DIR/cloudflared-cdn.env && -x $BIN_DIR/cloudflared ]] || fail 'removal files (binary must stay)'
! grep -q 'vless-xhttp-cdn' "$APP_DIR/client-info.txt" || fail 'removed node still shown'
cdn_env
menu >"$TEST_ROOT/menu.log" 2>&1 <<< $'13\n0'
grep -q '^PROTOCOLS=vless,xhttpcdn$' "$APP_DIR/state" || fail 'menu 13 did not add'
menu >"$TEST_ROOT/menu.log" 2>&1 <<< $'14\ny\n0'
trap cleanup EXIT
grep -q '^PROTOCOLS=vless$' "$APP_DIR/state" || fail 'menu 14 did not remove'
cdn_env; fixture xhttpcdn
expect_failure do_remove_xhttp_cdn --yes
grep -q '只安装了 XHTTP' "$TEST_ROOT/operation.log" || fail 'CDN-only removal must point to uninstall'
cdn_env; fixture vless,anytls,xhttpcdn
do_remove_anytls --yes >"$TEST_ROOT/operation.log" 2>&1
grep -qx 'PROTOCOLS=vless,xhttpcdn' "$APP_DIR/state" || fail 'remove-anytls broke when another protocol follows anytls'
(
  cdn_env; fixture vless,xhttpcdn
  stage_binaries() { mkdir -p "$1"; for b in xray cloudflared; do printf '#!/usr/bin/env bash\nexit 0\n# candidate\n' >"$1/$b"; chmod 0755 "$1/$b"; done; }
  for b in xray cloudflared; do printf '#!/usr/bin/env bash\nexit 0\n# installed\n' >"$BIN_DIR/$b"; chmod 0755 "$BIN_DIR/$b"; cp -p "$BIN_DIR/$b" "$TEST_ROOT/old-$b"; done
  rm -f "$TEST_ROOT/services.log" "$TEST_ROOT/cdn-verify.log"; touch "$TEST_ROOT/fail-cdn"
  expect_failure apply_update
  rm "$TEST_ROOT/fail-cdn"
  cmp "$BIN_DIR/cloudflared" "$TEST_ROOT/old-cloudflared" && cmp "$BIN_DIR/xray" "$TEST_ROOT/old-xray" || fail 'failed update did not restore binaries'
  rm -f "$TEST_ROOT/services.log"
  apply_update >"$TEST_ROOT/operation.log" 2>&1
  grep -qx 'restart xray-lite.service cloudflared-cdn-lite.service' "$TEST_ROOT/services.log" || fail "update restart list: $(tr '\n' ';' <"$TEST_ROOT/services.log")"
  grep -q '# candidate' "$BIN_DIR/cloudflared" || fail 'update did not replace cloudflared for the CDN node'
  [[ $(grep -c '^verify ' "$TEST_ROOT/cdn-verify.log") == 2 ]] || fail 'update did not re-verify the tunnel'
)
pass 'add/remove xhttpcdn: refusals, lock, port clash, xray/verify/download/restart failures restore; menu 13/14; update'

# 14. The post-start check reads the tunnel route from the connector log and proxies through it.
CDN_DOMAIN=cdn.example.test CDN_PORT=18090 CDN_VERIFY_TRIES=1
cdn_probe() { [[ ! -f $TEST_ROOT/fail-probe ]]; }
cdn_connector_log() { cat "$TEST_ROOT/connector.log" 2>/dev/null || true; }
route() {  # $1 = service for cdn.example.test ('' = no rule for the host)
  local rules='{\"service\":\"http_status:404\"}'
  [[ -z $1 ]] || rules='{\"hostname\":\"cdn.example.test\",\"service\":\"'"$1"'\"},'"$rules"
  printf '%s\n' '2026-11-18T05:20:00Z INF Starting tunnel tunnelID=11111111-2222-3333-4444-555555555555' \
    '2026-11-18T05:20:01Z INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"old.example.test\",\"service\":\"http://127.0.0.1:1\"}],\"warp-routing\":{\"enabled\":false}}" version=1' \
    '2026-11-18T05:20:02Z INF Updated to new configuration config="{\"ingress\":['"$rules"'],\"warp-routing\":{\"enabled\":false}}" version=2' \
    >"$TEST_ROOT/connector.log"
}
route http://127.0.0.1:18090; real_verify_xhttp_cdn >"$TEST_ROOT/operation.log" 2>&1 || fail 'matching route rejected'
route http://localhost:18090/; real_verify_xhttp_cdn >"$TEST_ROOT/operation.log" 2>&1 || fail 'localhost route rejected'
route http://127.0.0.1:8080; expect_failure real_verify_xhttp_cdn
grep -q 'http://127.0.0.1:8080，应为 http://127.0.0.1:18090' "$TEST_ROOT/operation.log" || fail 'wrong port not explained'
route https://127.0.0.1:18090; expect_failure real_verify_xhttp_cdn
route ''; expect_failure real_verify_xhttp_cdn
grep -q 'Service URL http://127.0.0.1:18090' "$TEST_ROOT/operation.log" || fail 'missing route hint'
rm -f "$TEST_ROOT/connector.log"; expect_failure real_verify_xhttp_cdn
grep -q '没有读到隧道的远程路由配置' "$TEST_ROOT/operation.log" || fail 'missing remote configuration not explained'
route http://127.0.0.1:18090; touch "$TEST_ROOT/fail-probe"; expect_failure real_verify_xhttp_cdn; rm "$TEST_ROOT/fail-probe"
grep -q 'CNAME' "$TEST_ROOT/operation.log" || fail 'proxy failure not explained'
unset CDN_VERIFY_TRIES
pass 'tunnel check: latest remote route must be http://127.0.0.1|localhost:port; mismatch/missing/no-config/probe failures explained'
printf 'Review fixes: %s checks passed; package manager/systemd/downloads mocked.\n' "$passed"
