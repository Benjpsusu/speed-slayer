#!/usr/bin/env bash
# Isolated lifecycle checks. Optional real sing-box validates TLS/AnyTLS locally.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/speed-anytls-test.XXXXXX")
export SPEED_ANYTLS_ROOT="$TEST_ROOT"
cleanup() {
  local status=$? resolved parent
  if (( status != 0 )); then tail -n 25 "$TEST_ROOT/operation.log" 2>/dev/null || true; fi
  resolved=$(cd "$TEST_ROOT" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-anytls-test.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
awk -v root="$TEST_ROOT" '
  /^readonly APP_DIR=/ {print "readonly APP_DIR=\"" root "/app\""; next}
  /^readonly BIN_DIR=/ {print "readonly BIN_DIR=\"" root "/shared\""; next}
  /^readonly UNIT_DIR=/ {print "readonly UNIT_DIR=\"" root "/units\""; next}
  /^readonly SHORTCUT=/ {print "readonly SHORTCUT=\"" root "/shortcut\""; next}
  {print}
' "$TEST_DIR/install.sh" >"$TEST_ROOT/installer.sh"
. "$TEST_ROOT/installer.sh"
if [[ -n ${SPEED_TEST_PYTHON:-} ]]; then python3() { "$SPEED_TEST_PYTHON" "$@" | tr -d '\r'; }; fi
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
need_root() { :; }
install_packages() { :; }
need_cmd() { [[ $1 == ss ]] || command -v "$1" >/dev/null; }
flock() { [[ ! -f $TEST_ROOT/locked ]]; }
uname() { case $1 in -m) printf '%s\n' "${TEST_ARCH:-x86_64}";; -s) printf '%s\n' "${TEST_OS:-Linux}";; -r) echo '6.1-test';; esac; }
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
  if [[ -n ${SPEED_TEST_XRAY:-} ]]; then "$SPEED_TEST_XRAY" "$@" | tr -d '\r'; else
    case $1 in uuid) python3 -c 'import uuid;print(uuid.uuid4())';; x25519) printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n';; esac
  fi
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
if [[ -n ${SPEED_TEST_SINGBOX:-} ]]; then exec "$SPEED_TEST_SINGBOX" "$@"; fi
exec "${SPEED_TEST_PYTHON:-python3}" -m json.tool "$3"
MOCK
  chmod 0755 "$1"
}
tar() {
  [[ $1 == -xzf && $3 == -C && $5 == --strip-components=1 ]] || fail 'unsafe extraction'
  [[ $6 == sing-box-1.14.4-linux-*/sing-box ]] || fail 'unexpected archive member'
  write_mock_binary "$4/sing-box"
}
unzip() { fail 'AnyTLS-only must not download Xray'; }

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
  ANYTLS_CERT_MODE=${2:-file} ANYTLS_EMAIL=test@example.com
  ANYTLS_ADDRESS=${TEST_ANYTLS_IP:-203.0.113.15}
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
  if [[ -f $APP_DIR/anytls.json ]]; then
    cp -p "$APP_DIR/anytls.json" "$APP_DIR/bin/sing-box" "$TEST_ROOT/golden/"
    cp -p "$APP_DIR/tls/"*.pem "$TEST_ROOT/golden/" 2>/dev/null || true
  fi
}
assert_saved() {
  local name
  for name in state client-info.txt install.sh; do cmp "$APP_DIR/$name" "$TEST_ROOT/golden/$name" || fail "changed $name"; done
  if [[ -f $TEST_ROOT/golden/xray.json ]]; then cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"; fi
  if [[ -f $TEST_ROOT/golden/anytls.json ]]; then
    cmp "$APP_DIR/anytls.json" "$TEST_ROOT/golden/anytls.json"
    cmp "$APP_DIR/bin/sing-box" "$TEST_ROOT/golden/sing-box"
  fi
}

set_protocols anytls
TEST_ARCH=aarch64 detect_arch >"$TEST_ROOT/operation.log"
[[ $SB_ARCH == arm64 && $SB_SHA == 436441* ]] || fail 'ARM release selection'
TEST_ARCH=x86_64 detect_arch >"$TEST_ROOT/operation.log"
[[ $SB_ARCH == amd64 && $SB_SHA == 699a1b* ]] || fail 'AMD release selection'
TEST_ARCH=riscv64 expect_failure detect_arch
TEST_OS=Darwin expect_failure detect_arch
pass 'Linux amd64/arm64 mapping; unsupported system and architecture rejected'

for selection in anytls vmess,anytls ss2022,anytls vless,anytls vmess,ss2022,anytls vmess,vless,anytls ss2022,vless,anytls vmess,ss2022,vless,anytls; do
  fixture "$selection"
  "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json" >"$TEST_ROOT/operation.log" 2>&1
  python3 - "$APP_DIR" "$UNIT_DIR" "$selection" <<'PY'
import json, pathlib, sys, urllib.parse
p,u=map(pathlib.Path,sys.argv[1:3]); selected=set(sys.argv[3].split(','))
s=dict(l.split('=',1) for l in (p/'state').read_text(encoding='utf-8').splitlines())
c=json.loads((p/'anytls.json').read_text(encoding='utf-8')); n=c['inbounds'][0]
link=next(l for l in (p/'client-info.txt').read_text(encoding='utf-8').splitlines() if l.startswith('anytls://'))
r=urllib.parse.urlsplit(link);q=urllib.parse.parse_qs(r.query)
assert r.username==n['users'][0]['password']==s['ANYTLS_PASSWORD'] and len(r.username)==64
assert r.port==n['listen_port']==18443 and r.hostname==q['sni'][0]=='at.example.test'
assert q['insecure']==['0'] and n['tls']['enabled']
assert (u/'anytls-lite.service').exists()
assert (u/'xray-lite.service').exists()==(len(selected)>1)
assert (u/'cloudflared-lite.service').exists()==('vmess' in selected)
assert (p/'xray.json').exists()==(len(selected)>1)
if len(selected)>1:
    x=json.loads((p/'xray.json').read_text(encoding='utf-8'))
    assert all(n['protocol']!='anytls' for n in x['inbounds'])
PY
  pass "selected services/config and verified URI: $selection"
done

fixture anytls acme
"$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json" >"$TEST_ROOT/operation.log" 2>&1
python3 - "$APP_DIR/anytls.json" "$UNIT_DIR/anytls-lite.service" <<'PY'
import json,pathlib,sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
a=c['inbounds'][0]['tls']['certificate_provider']
assert a['type']=='acme' and a['provider']=='letsencrypt'
assert a['disable_tls_alpn_challenge'] and 'dns01_challenge' not in a
assert a['domain']==['at.example.test'] and a['email']=='test@example.com'
assert 'CAP_NET_BIND_SERVICE' in pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
PY
pass 'ACME schema passes actual core check, HTTP-01 and renewal permissions configured'

fixture anytls
ANYTLS_SERVER_NAME=wrong.example.test expect_failure check_anytls_certificate "$ANYTLS_CERT_FILE" "$ANYTLS_KEY_FILE"
expect_failure check_anytls_certificate "$ANYTLS_CERT_FILE" "$ANYTLS_CERT_FILE"
ANYTLS_SERVER_NAME=at.example.test ANYTLS_EMAIL=bad ANYTLS_CERT_MODE=acme expect_failure validate_anytls_options
PROTOCOLS=vless,anytls REALITY_PORT=30002 ANYTLS_CERT_MODE=file ANYTLS_PORT=30002 expect_failure validate_install_options
ANYTLS_PASSWORD='bad&password' expect_failure validate_anytls_options
pass 'wrong SNI/key, invalid email/password and port collision rejected'

unset ANYTLS_PORT
BUSY_PORT=443 configure_install >"$TEST_ROOT/ui.log" <<< $'4\n\n2\nat.example.test\n\n'"$TEST_ROOT/certs/cert.pem"$'\n'"$TEST_ROOT/certs/key.pem"
[[ $PROTOCOLS == anytls && $ANYTLS_PORT == 8443 && $ANYTLS_CERT_MODE == file ]] || fail 'AnyTLS UI'
pass 'checkbox AnyTLS-only and occupied 443 default to 8443 with file-certificate input'

fixture anytls
expect_failure do_add_anytls
touch "$TEST_ROOT/locked"
expect_failure apply_update
expect_failure do_refresh_anytls_cert
expect_failure do_uninstall --yes
rm "$TEST_ROOT/locked"
assert_saved
pass 'duplicate addition and concurrent maintenance rejected without changing nodes'

for fault in download config start tls; do
  fixture anytls
  touch "$TEST_ROOT/fail-$fault"
  expect_failure apply_update
  assert_saved
  ! grep -qE 'Xray|cloudflared' "$TEST_ROOT/download.log" || fail 'unselected download'
  ! grep -qE 'xray-lite|cloudflared-lite' "$TEST_ROOT/services.log" || fail 'unselected restart'
  pass "AnyTLS update failure $fault leaves/restores binary, manager, config and credentials"
done
fixture anytls
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
cmp "$APP_DIR/anytls.json" "$TEST_ROOT/golden/anytls.json"
grep -q 'unrelated shared binary' "$BIN_DIR/sing-box"
pass 'successful AnyTLS-only update preserves state/config and shared sing-box'

for fault in none download config start tls info; do
  fixture vless
  ANYTLS_SERVER_NAME=at.example.test ANYTLS_CERT_MODE=file ANYTLS_PORT=18443
  ANYTLS_CERT_FILE="$TEST_ROOT/certs/cert.pem" ANYTLS_KEY_FILE="$TEST_ROOT/certs/key.pem"
  if [[ $fault == none ]]; then
    do_add_anytls >"$TEST_ROOT/operation.log" 2>&1
    cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"
    python3 - "$APP_DIR/state" "$TEST_ROOT/golden/state" <<'PY'
import pathlib,sys
a,b=[dict(l.split('=',1) for l in pathlib.Path(x).read_text(encoding='utf-8').splitlines()) for x in sys.argv[1:]]
assert a['PROTOCOLS']=='vless,anytls'
assert all(a[k]==v for k,v in b.items() if k!='PROTOCOLS' and not k.startswith('ANYTLS_'))
PY
  else
    touch "$TEST_ROOT/fail-$fault"
    expect_failure do_add_anytls
    assert_saved
    [[ ! -f $APP_DIR/anytls.json && ! -f $UNIT_DIR/anytls-lite.service ]] || fail 'failed addition left services'
  fi
  ! grep -qE '(restart|disable|enable).*xray-lite|cloudflared-lite' "$TEST_ROOT/services.log" 2>/dev/null || fail 'addition touched existing service'
  pass "add AnyTLS to existing VLESS ($fault) preserves original node and running services"
done

fixture anytls
touch "$TEST_ROOT/fail-tls"
expect_failure do_refresh_anytls_cert
cmp "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem"
cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
rm "$TEST_ROOT/fail-tls"
do_refresh_anytls_cert >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
pass 'external certificate refresh validates and restores on failure, preserves node password'

fixture anytls
do_uninstall <<< '' >"$TEST_ROOT/operation.log"
[[ -f $APP_DIR/state ]] || fail 'default uninstall should cancel'
do_uninstall --yes >"$TEST_ROOT/operation.log"
[[ ! -d $APP_DIR && ! -f $UNIT_DIR/anytls-lite.service && -s $BIN_DIR/sing-box && -s $TEST_ROOT/certs/key.pem ]] || fail 'uninstall ownership'
pass 'uninstall removes Lite AnyTLS only and keeps source certificates/shared binary'

PROTOCOLS=anytls ANYTLS_SERVER_NAME=at.example.test ANYTLS_PORT=18443 ANYTLS_CERT_MODE=file ANYTLS_PASSWORD=''
ANYTLS_CERT_FILE="$TEST_ROOT/certs/cert.pem" ANYTLS_KEY_FILE="$TEST_ROOT/certs/key.pem"
BUSY_PORT=18443 expect_failure do_install
[[ ! -e $APP_DIR/state ]] || fail 'busy-port install mutated state'
ANYTLS_CERT_MODE=acme ANYTLS_EMAIL=test@example.com BUSY_PORT=80 expect_failure do_install
[[ ! -e $APP_DIR/state ]] || fail 'busy ACME port mutated state'
touch "$TEST_ROOT/fail-tls"
expect_failure do_install
[[ ! -e $APP_DIR && ! -e $UNIT_DIR/anytls-lite.service && -s $BIN_DIR/sing-box && -s $TEST_ROOT/certs/key.pem ]] || fail 'failed fresh install cleanup'
rm "$TEST_ROOT/fail-tls"
pass 'ACME port 80 conflict rejected; failed fresh TLS validation cleans only Lite files'
do_install >"$TEST_ROOT/operation.log" 2>&1
trap cleanup EXIT
[[ -s $APP_DIR/anytls.json && ! -e $APP_DIR/xray.json ]] || fail 'fresh AnyTLS-only install'
pass 'fresh AnyTLS-only install and busy-port rejection'

if [[ -n ${SPEED_TEST_SINGBOX:-} ]]; then
  python3 "$TEST_DIR/test-anytls-loopback.py" "$SPEED_TEST_SINGBOX" "$APP_DIR" "$TEST_ROOT/certs/cert.pem"
  pass 'real AnyTLS loopback: verified TLS, proxy request, wrong password and wrong SNI rejection'
else
  printf 'SKIP real AnyTLS connection; set SPEED_TEST_SINGBOX to enable.\n'
fi

unset ANYTLS_PORT ANYTLS_ADDRESS
BUSY_PORT=80 configure_install >"$TEST_ROOT/ui.log" <<< $'4\n\n3\n\n8443\n'
validate_install_options
prepare_anytls_identity
[[ $ANYTLS_CERT_MODE == selfsigned && $ANYTLS_ADDRESS == 203.0.113.15 && -z $ANYTLS_SERVER_NAME && -z $ANYTLS_EMAIL ]] || fail 'self-signed UI'
[[ ${ACTIVE_PORTS[*]} == 8443 ]] || fail 'self-signed checked ACME port'
pass 'self-signed checkbox flow skips domain/SNI/email, auto-detects IP and does not reserve 80'

for address in 203.0.113.15 2001:db8::15; do
  TEST_ANYTLS_IP=$address fixture anytls selfsigned
  "$APP_DIR/bin/sing-box" check -c "$APP_DIR/anytls.json" >"$TEST_ROOT/operation.log" 2>&1
  do_export_anytls_client >"$TEST_ROOT/pinned-client.json"
  "$APP_DIR/bin/sing-box" check -c "$TEST_ROOT/pinned-client.json" >"$TEST_ROOT/operation.log" 2>&1
  python3 - "$APP_DIR" "$TEST_ROOT/pinned-client.json" "$address" <<'PY'
import base64, hashlib, ipaddress, json, pathlib, subprocess, sys, urllib.parse
p=pathlib.Path(sys.argv[1]); address=sys.argv[3]
c=json.loads((p/'anytls.json').read_text(encoding='utf-8'))['inbounds'][0]
client=json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')); out=client['outbounds'][0]
info=(p/'client-info.txt').read_text(encoding='utf-8')
link=next(l for l in info.splitlines() if l.startswith('anytls://'))
u=urllib.parse.urlsplit(link); q=urllib.parse.parse_qs(u.query)
assert u.hostname==address and 'sni' not in q and q['insecure']==['0']
assert 'server_name' not in c['tls'] and 'certificate_provider' not in c['tls']
assert out['server']==out['tls']['server_name']==address
assert out['password']==c['users'][0]['password']==u.username
assert out['tls']['insecure'] is False and client['inbounds'][0]['listen']=='127.0.0.1'
assert 'disable_sni' not in out['tls']
pub=subprocess.run(['openssl','x509','-in',str(p/'tls/fullchain.pem'),'-pubkey','-noout'],check=True,capture_output=True).stdout
der=subprocess.run(['openssl','pkey','-pubin','-outform','DER'],input=pub,check=True,capture_output=True).stdout
pin=base64.b64encode(hashlib.sha256(der).digest()).decode()
assert out['tls']['certificate_public_key_sha256']==[pin] and pin in info
assert 'BEGIN CERTIFICATE' in info and 'PRIVATE KEY' not in info
assert 'BEGIN CERTIFICATE' not in json.dumps(client) and 'PRIVATE KEY' not in json.dumps(client)
PY
  generate_anytls_certificate
  cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
  cmp "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem"
  ANYTLS_ADDRESS=203.0.113.99 expect_failure check_anytls_certificate "$APP_DIR/tls/fullchain.pem" "$APP_DIR/tls/privkey.pem"
  pass "self-signed $address: certificate SAN, URI, actual core configs and persistent key"
done

for address in 999.2.3.4 2001:::1 127.0.0.1 0.0.0.0 ff02::1 fe80::1; do
  ANYTLS_ADDRESS=$address expect_failure prepare_anytls_identity
done
ANYTLS_ADDRESS=example.com expect_failure validate_anytls_options
ANYTLS_ADDRESS='2001:db8::1%eth0' expect_failure validate_anytls_options
touch "$TEST_ROOT/fail-ip"
ANYTLS_ADDRESS='' expect_failure prepare_anytls_identity
rm "$TEST_ROOT/fail-ip"
pass 'invalid/scoped/unusable IP and failed auto-detection rejected'

fixture anytls selfsigned
for fault in config start tls; do
  touch "$TEST_ROOT/fail-$fault"
  expect_failure apply_update
  assert_saved
  cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
  cmp "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem"
  rm -f "$TEST_ROOT/fail-$fault"
done
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
cmp "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem"
pass 'self-signed update success/failures keep certificate, private key, pin and credentials'

fixture anytls selfsigned
for fault in config start tls; do
  touch "$TEST_ROOT/fail-$fault"
  expect_failure do_refresh_anytls_cert
  assert_saved
  cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
  cmp "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem"
  rm -f "$TEST_ROOT/fail-$fault"
done
before_pin=$(anytls_public_key_pin)
do_refresh_anytls_cert >"$TEST_ROOT/operation.log" 2>&1
[[ $(anytls_public_key_pin) == "$before_pin" ]] || fail 'renewal rotated pin'
cmp "$APP_DIR/tls/privkey.pem" "$TEST_ROOT/golden/privkey.pem"
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
! cmp -s "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/golden/fullchain.pem" || fail 'certificate not renewed'
pass 'self-signed renewal keeps key/pin/password, refreshes public certificate and rolls back failures'

for fault in none tls; do
  fixture vless
  ANYTLS_CERT_MODE=selfsigned ANYTLS_ADDRESS=203.0.113.15 ANYTLS_PORT=18443
  if [[ $fault == none ]]; then
    BUSY_PORT=80 do_add_anytls >"$TEST_ROOT/operation.log" 2>&1
    cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"
    grep -qx 'ANYTLS_CERT_MODE=selfsigned' "$APP_DIR/state"
    grep -qx 'ANYTLS_SERVER_NAME=' "$APP_DIR/state"
  else
    touch "$TEST_ROOT/fail-$fault"
    expect_failure do_add_anytls
    assert_saved
    [[ ! -e $APP_DIR/tls ]] || fail 'failed addition left private key'
  fi
  ! grep -qE '(restart|disable|enable).*xray-lite|cloudflared-lite' "$TEST_ROOT/services.log" || fail 'touched existing services'
done
pass 'self-signed addition works with busy 80; failure preserves VLESS and removes generated key'

fixture anytls selfsigned
do_export_anytls_client >"$TEST_ROOT/pinned-client.json"
if [[ -n ${SPEED_TEST_SINGBOX:-} ]]; then
  python3 "$TEST_DIR/test-anytls-loopback.py" "$SPEED_TEST_SINGBOX" "$APP_DIR" "$APP_DIR/tls/fullchain.pem" "$TEST_ROOT/pinned-client.json" "$TEST_ROOT/installer.sh"
  pass 'real self-signed IP TLS: pin/PEM trust, no SNI on wire, bad pin/password/untrusted rejection'
else
  printf 'SKIP real self-signed connections; set SPEED_TEST_SINGBOX to enable.\n'
fi
do_uninstall --yes >"$TEST_ROOT/operation.log"
[[ ! -e $APP_DIR && -s $BIN_DIR/sing-box ]] || fail 'self-signed uninstall'
pass 'self-signed uninstall removes generated certificate/key while keeping shared binaries'
PROTOCOLS=anytls ANYTLS_CERT_MODE=selfsigned ANYTLS_ADDRESS='' ANYTLS_PORT=18443 ANYTLS_PASSWORD=''
BUSY_PORT=80 do_install >"$TEST_ROOT/operation.log" 2>&1
trap cleanup EXIT
grep -qx 'ANYTLS_CERT_MODE=selfsigned' "$APP_DIR/state"
grep -qx 'ANYTLS_ADDRESS=203.0.113.15' "$APP_DIR/state"
[[ -s $APP_DIR/tls/privkey.pem && ! -e $APP_DIR/xray.json ]] || fail 'fresh self-signed install'
do_uninstall --yes >"$TEST_ROOT/operation.log"
pass 'fresh self-signed installation auto-detects IP and succeeds with occupied port 80'
printf 'AnyTLS: %s checks passed; package manager/systemd/downloads mocked.\n' "$passed"
