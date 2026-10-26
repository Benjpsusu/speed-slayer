#!/usr/bin/env bash
# Exercise protocol selection and maintenance with isolated paths and fake services.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/speed-lite-manage.XXXXXX")
export SPEED_TEST_ROOT="$TEST_ROOT"
cleanup() {
  local status=$? resolved parent
  if (( status != 0 )); then
    for name in operation.log core.log; do [[ ! -f $TEST_ROOT/$name ]] || tail -n 15 "$TEST_ROOT/$name" >&2; done
  fi
  resolved=$(cd "$TEST_ROOT" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-lite-manage.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
awk -v root="$TEST_ROOT" '
  /^readonly APP_DIR=/ {print "readonly APP_DIR=\"" root "/app\""; next}
  /^readonly BIN_DIR=/ {print "readonly BIN_DIR=\"" root "/bin\""; next}
  /^readonly UNIT_DIR=/ {print "readonly UNIT_DIR=\"" root "/units\""; next}
  /^readonly SHORTCUT=/ {print "readonly SHORTCUT=\"" root "/shortcut\""; next}
  {print}
' "$TEST_DIR/install.sh" >"$TEST_ROOT/installer.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/installer.sh"
if [[ -n ${SPEED_TEST_PYTHON:-} ]]; then python3() { "$SPEED_TEST_PYTHON" "$@" | tr -d '\r'; }; fi
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
need_root() { :; }
flock() { [[ $* == '-n 9' ]] || fail 'unexpected lock'; }
chown() { [[ $1 == root:xray && $2 == "$TEST_ROOT/"* ]] || fail 'unexpected chown'; }
openssl() { command openssl "$@" | tr -d '\r'; }
apt-get() { fail 'package manager must not run'; }
public_ip() {
  [[ ! -f $TEST_ROOT/fail-info ]] || return 1
  printf '203.0.113.15\n'
}
xray() {
  if [[ -n ${SPEED_TEST_XRAY:-} ]]; then "$SPEED_TEST_XRAY" "$@" | tr -d '\r';
  else
    case $1 in
      uuid) python3 -c 'import uuid;print(uuid.uuid4())' ;;
      x25519) printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
      run) python3 -m json.tool "$4" >/dev/null ;;
      *) fail 'unexpected Xray command' ;;
    esac
  fi
}
systemctl() {
  printf '%s\n' "$*" >>"$TEST_ROOT/systemctl.log"
  case $1 in
    restart)
      if [[ -f $TEST_ROOT/fail-restart ]]; then rm "$TEST_ROOT/fail-restart"; return 42; fi
      if [[ -f $TEST_ROOT/fail-active ]]; then mv "$TEST_ROOT/fail-active" "$TEST_ROOT/inactive-once"; fi ;;
    is-active)
      if [[ -f $TEST_ROOT/inactive-once ]]; then rm "$TEST_ROOT/inactive-once"; return 3; fi
      [[ ! -f $TEST_ROOT/stopped-${*: -1} ]] || return 3 ;;
    enable) rm -f -- "$TEST_ROOT/stopped-${*: -1}" ;;
    disable) touch "$TEST_ROOT/stopped-${*: -1}" ;;
    daemon-reload) : ;;
    *) fail "unexpected systemctl: $*" ;;
  esac
}
quick_domain() { printf 'current-test.trycloudflare.com\n'; }
wait_for_quick_domain() { [[ ! -f $TEST_ROOT/fail-domain ]]; }

fixture() {
  [[ $APP_DIR == "$TEST_ROOT/app" ]] || fail 'invalid fixture root'
  rm -rf -- "$APP_DIR" "$UNIT_DIR" "$BIN_DIR" "$TEST_ROOT/golden"
  rm -f -- "$TEST_ROOT"/fail-* "$TEST_ROOT"/stopped-* "$TEST_ROOT/inactive-once" "$TEST_ROOT/systemctl.log" "$TEST_ROOT/download.log"
  mkdir -p "$APP_DIR" "$UNIT_DIR" "$BIN_DIR" "$TEST_ROOT/golden"
  PROTOCOLS=$1
  VMESS_PORT=30000 SS_PORT=30001 REALITY_PORT=443 REALITY_GUARD_PORT=30003
  VMESS_ADDRESS=www.wto.org REALITY_SERVER_NAME=learn.microsoft.com XHTTP_PATH=/test/path
  ARGO_MODE=token ARGO_DOMAIN=tunnel.example.com ARGO_TOKEN=test-token
  validate_install_options
  write_config
  write_units
  write_client_info
  cp "$TEST_ROOT/installer.sh" "$APP_DIR/install.sh"
  printf '\n# installed-release-fixture\n' >>"$APP_DIR/install.sh"
  printf '#!/usr/bin/env bash\nprintf "old-xray\\n"\n' >"$BIN_DIR/xray"
  printf '#!/usr/bin/env bash\nprintf "old-cloudflared\\n"\n' >"$BIN_DIR/cloudflared"
  chmod 0755 "$BIN_DIR/xray" "$BIN_DIR/cloudflared"
  ln -sf "$APP_DIR/install.sh" "$SHORTCUT"
  snapshot
}
snapshot() {
  cp "$APP_DIR/xray.json" "$APP_DIR/state" "$APP_DIR/install.sh" "$APP_DIR/client-info.txt" "$BIN_DIR/xray" "$BIN_DIR/cloudflared" "$TEST_ROOT/golden/"
}
assert_unchanged() {
  local name
  for name in xray.json state install.sh client-info.txt; do cmp "$APP_DIR/$name" "$TEST_ROOT/golden/$name" || fail "changed $name after failure"; done
  for name in xray cloudflared; do cmp "$BIN_DIR/$name" "$TEST_ROOT/golden/$name" || fail "changed $name after failure"; done
}
expect_failure() {
  local status
  set +e
  (set -e; "$@") >"$TEST_ROOT/operation.log" 2>&1
  status=$?
  set -e
  (( status != 0 )) || fail 'operation should have failed'
}

for selection in vmess ss2022 vless vmess,ss2022 vmess,vless ss2022,vless vmess,ss2022,vless; do
  fixture "$selection"
  python3 - "$APP_DIR" "$UNIT_DIR" "$selection" <<'PY'
import base64,json,pathlib,sys,urllib.parse
root,units=map(pathlib.Path,sys.argv[1:3]); wanted=set(sys.argv[3].split(','))
c=json.loads((root/'xray.json').read_text(encoding='utf-8'))
s=dict(l.split('=',1) for l in (root/'state').read_text(encoding='utf-8').splitlines())
expected=set()
if 'vmess' in wanted: expected.add('vmess-ws-argo')
if 'ss2022' in wanted: expected.add('ss2022')
if 'vless' in wanted: expected.update(['vless-reality','reality-guard'])
assert {x['tag'] for x in c['inbounds']}==expected
links=(root/'client-info.txt').read_text(encoding='utf-8').splitlines()
assert sum(l.startswith('vmess://') for l in links)==int('vmess' in wanted)
assert sum(l.startswith('ss://') for l in links)==int('ss2022' in wanted)
assert sum(l.startswith('vless://') for l in links)==int('vless' in wanted)
assert (units/'cloudflared-lite.service').exists()==('vmess' in wanted)
assert (root/'cloudflared.env').exists()==('vmess' in wanted)
assert ('AmbientCapabilities=CAP_NET_BIND_SERVICE' in (units/'xray-lite.service').read_text(encoding='utf-8'))==('vless' in wanted)
if 'vmess' not in wanted: assert s['VMESS_UUID']=='' and s['ARGO_MODE']=='disabled'
if 'ss2022' not in wanted: assert s['SS_PASSWORD']==''
if 'vless' not in wanted: assert s['VLESS_UUID']=='' and s['REALITY_PUBLIC']=='' and not c['routing']['rules']
if 'vless' in wanted:
    n=next(n for n in c['inbounds'] if n['tag']=='vless-reality')
    assert n['streamSettings']['realitySettings']['serverNames']==['learn.microsoft.com']
    assert 'flow' not in n['settings']['clients'][0]
PY
  xray run -test -config "$APP_DIR/xray.json" >"$TEST_ROOT/core.log" 2>&1
  pass "only selected inbounds, links, credentials and services: $selection"
done

PROTOCOLS=vless VMESS_PORT=bad SS_PORT=bad REALITY_PORT=443 REALITY_GUARD_PORT=30003 validate_install_options
[[ ${ACTIVE_PORTS[*]} == '443 30003' ]] || fail 'unused ports validated or selected'
PROTOCOLS=vmess,ss2022 VMESS_PORT=30001 SS_PORT=030001 expect_failure validate_install_options
PROTOCOLS='' expect_failure validate_install_options
PROTOCOLS='vless,unknown' expect_failure validate_install_options
pass 'selected ports only; duplicate numeric ports and invalid/empty protocols rejected'

unset REALITY_PORT
configure_install >"$TEST_ROOT/ui.log" <<< $'3\n\n\n\n'
[[ $PROTOCOLS == vless && $REALITY_SERVER_NAME == learn.microsoft.com && $REALITY_PORT == 443 ]] || fail 'default UI selection'
configure_install >"$TEST_ROOT/ui.log" <<< $'3\n\n2\nhttps://bad.example/path\n2\ncustom.example.com\n8443'
[[ $PROTOCOLS == vless && $REALITY_SERVER_NAME == custom.example.com && $REALITY_PORT == 8443 ]] || fail 'custom SNI UI'
validate_install_options
write_config
write_client_info
python3 - "$APP_DIR" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]);c=json.loads((p/'xray.json').read_text(encoding='utf-8'))
n=next(n for n in c['inbounds'] if n['tag']=='vless-reality')
g=next(n for n in c['inbounds'] if n['tag']=='reality-guard')
assert n['port']==8443 and n['streamSettings']['realitySettings']['serverNames']==['custom.example.com']
assert g['settings']['address']=='custom.example.com'
assert c['routing']['rules'][0]['domain']==['full:custom.example.com']
l=next(l for l in (p/'client-info.txt').read_text(encoding='utf-8').splitlines() if l.startswith('vless://'))
assert urllib.parse.parse_qs(urllib.parse.urlsplit(l).query)['sni']==['custom.example.com']
PY
configure_install >"$TEST_ROOT/ui.log" <<< $'2\n\n'
[[ $PROTOCOLS == ss2022 ]] || fail 'SS checkbox'
! grep -q 'VLESS SNI' "$TEST_ROOT/ui.log" || fail 'SNI question for SS-only'
pass 'checkbox UI, default/custom SNI, invalid SNI retry and SS-only prompt flow'

# Simulate release downloads; the real staging and update orchestration still run.
download_checked() {
  printf '%s\n' "$1" >>"$TEST_ROOT/download.log"
  [[ ! -f $TEST_ROOT/fail-download ]] || die 'simulated release checksum failure'
  if [[ $1 == *Xray-linux-* ]]; then printf 'mock zip\n' >"$2";
  else
    cat >"$2" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ ! -f $SPEED_TEST_ROOT/fail-cf ]] || exit 31
printf 'new-cloudflared\n'
MOCK
  fi
}
unzip() {
  local dest=${*: -1}
  cat >"$dest/xray" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ $1 == version ]]; then printf 'new-xray\n'; exit 0; fi
[[ $1 == run && $2 == -test && $3 == -config ]] || exit 32
[[ ! -f $SPEED_TEST_ROOT/fail-config ]] || exit 33
if [[ -n ${SPEED_TEST_XRAY:-} ]]; then exec "$SPEED_TEST_XRAY" "$@"; fi
exec "${SPEED_TEST_PYTHON:-python3}" -m json.tool "$4"
MOCK
}
for fault in download config cf restart active info; do
  fixture vmess,ss2022,vless
  touch "$TEST_ROOT/fail-$fault"
  expect_failure apply_update
  assert_unchanged
  if [[ $fault == download || $fault == config || $fault == cf ]]; then
    ! grep -q '^restart ' "$TEST_ROOT/systemctl.log" || fail 'restart before candidate checks passed'
  else
    grep -q '^restart ' "$TEST_ROOT/systemctl.log" || fail 'rollback must restart restored service'
  fi
  pass "update failure ($fault) leaves or restores original binaries, config, credentials and script"
done

fixture vmess,ss2022,vless
python3 - "$APP_DIR/state" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text(encoding='utf-8').splitlines()
lines=['ARGO_MODE=quick' if l.startswith('ARGO_MODE=') else 'ARGO_DOMAIN=' if l.startswith('ARGO_DOMAIN=') else l for l in lines]
p.write_bytes(('\n'.join(lines)+'\n').encode('utf-8'))
PY
write_client_info
snapshot
touch "$TEST_ROOT/fail-domain"
expect_failure apply_update
assert_unchanged
pass 'Quick Tunnel hostname timeout restores the old binaries and manager'
fixture vmess,ss2022,vless
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"
cmp "$APP_DIR/client-info.txt" "$TEST_ROOT/golden/client-info.txt"
! cmp -s "$BIN_DIR/xray" "$TEST_ROOT/golden/xray" || fail 'Xray not updated'
! cmp -s "$BIN_DIR/cloudflared" "$TEST_ROOT/golden/cloudflared" || fail 'cloudflared not updated'
! cmp -s "$APP_DIR/install.sh" "$TEST_ROOT/golden/install.sh" || fail 'manager not updated'
grep -q '^restart xray-lite.service cloudflared-lite.service$' "$TEST_ROOT/systemctl.log" || fail 'selected services not restarted'
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"
pass 'successful and repeated updates preserve installed configuration and credentials'

fixture vless
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$BIN_DIR/cloudflared" "$TEST_ROOT/golden/cloudflared"
! grep -q cloudflared "$TEST_ROOT/download.log" || fail 'downloaded unused Tunnel'
! grep -q cloudflared "$TEST_ROOT/systemctl.log" || fail 'touched unrelated Tunnel service'
pass 'VLESS-only update never downloads, replaces or restarts cloudflared'

fixture vmess,ss2022,vless
python3 - "$APP_DIR" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);c=json.loads((p/'xray.json').read_text(encoding='utf-8'))
n=next(n for n in c['inbounds'] if n['tag']=='vless-reality')
n['streamSettings']['network']='raw';n['streamSettings'].pop('xhttpSettings')
n['settings']['clients'][0]['flow']='xtls-rprx-vision'
(p/'xray.json').write_bytes(json.dumps(c).encode('utf-8'))
lines=(p/'state').read_text(encoding='utf-8').splitlines()
(p/'state').write_bytes(('\n'.join(l for l in lines if not l.startswith(('PROTOCOLS=','VLESS_TRANSPORT=','XHTTP_PATH=')))+'\n').encode('utf-8'))
PY
write_client_info
snapshot
apply_update >"$TEST_ROOT/operation.log" 2>&1
cmp "$APP_DIR/state" "$TEST_ROOT/golden/state"
cmp "$APP_DIR/xray.json" "$TEST_ROOT/golden/xray.json"
grep -q 'type=tcp&flow=xtls-rprx-vision' "$APP_DIR/client-info.txt" || fail 'legacy TCP was relabelled'
pass 'old all-protocol state remains compatible and update does not migrate TCP implicitly'

fixture ss2022
expect_failure do_repair_argo
expect_failure do_migrate_xhttp
assert_unchanged
pass 'unselected Argo repair and VLESS migration fail before changing services'

# Downloaded script must be validated, then run with its own update implementation.
curl() {
  local output=${*: -1}
  [[ ${1:-} == --fail ]] || fail 'unexpected network request'
  [[ ! -f $TEST_ROOT/fail-manager-download ]] || return 22
  cp "$TEST_ROOT/downloaded-installer.sh" "$output"
}
cat >"$TEST_ROOT/downloaded-installer.sh" <<'DOWNLOADED'
#!/usr/bin/env bash
set -eu
readonly APP="speed-slayer-lite"
apply_update() { printf 'downloaded updater\n' >"$SPEED_TEST_ROOT/updater-ran"; }
[[ $1 == apply-update ]]
apply_update
DOWNLOADED
do_update >"$TEST_ROOT/operation.log" 2>&1
[[ -f $TEST_ROOT/updater-ran ]] || fail 'downloaded updater not invoked'
rm "$TEST_ROOT/updater-ran"
printf '#!/usr/bin/env bash\nprintf wrong-script\n' >"$TEST_ROOT/downloaded-installer.sh"
expect_failure do_update
[[ ! -f $TEST_ROOT/updater-ran ]] || fail 'invalid updater ran'
touch "$TEST_ROOT/fail-manager-download"
expect_failure do_update
! grep -q 'unbound variable' "$TEST_ROOT/operation.log" || fail 'download-failure cleanup lost its path'
rm "$TEST_ROOT/fail-manager-download"
pass 'update downloads and validates manager before executing its update operation'

# Default menu and EOF must not install or uninstall anything.
menu </dev/null >"$TEST_ROOT/menu.log"
grep -q '创建节点' "$TEST_ROOT/menu.log"
grep -q '更新脚本和内核' "$TEST_ROOT/menu.log"
grep -q '卸载' "$TEST_ROOT/menu.log"
do_uninstall <<< '' >"$TEST_ROOT/operation.log"
assert_unchanged
printf 'unrelated data\n' >"$TEST_ROOT/keep.txt"
do_uninstall --yes >"$TEST_ROOT/operation.log" 2>&1
[[ ! -d $APP_DIR && ! -e $SHORTCUT && ! -f $UNIT_DIR/xray-lite.service ]] || fail 'uninstall left managed files'
[[ -f $TEST_ROOT/keep.txt && -x $BIN_DIR/xray && -x $BIN_DIR/cloudflared ]] || fail 'uninstall removed shared or unrelated files'
pass 'menu exits on EOF; uninstall defaults to cancel and only removes Lite-owned files'

# Exercise a whole fresh VLESS-only installation with the same staged binaries.
install_packages() { :; }
create_users() { mkdir -p "$APP_DIR"; }
need_cmd() { [[ $1 == ss ]] || command -v "$1" >/dev/null || fail "missing test command $1"; }
port_free() {
  printf '%s\n' "$1" >>"$TEST_ROOT/ports.log"
  [[ ! -f $TEST_ROOT/busy-port ]]
}
PROTOCOLS=vless REALITY_PORT=443 REALITY_GUARD_PORT=30003 REALITY_SERVER_NAME=learn.microsoft.com
touch "$TEST_ROOT/busy-port"
expect_failure do_install
[[ ! -e $APP_DIR/state ]] || fail 'busy-port installation changed state'
rm "$TEST_ROOT/busy-port"
rm -f -- "$TEST_ROOT/download.log" "$TEST_ROOT/systemctl.log" "$TEST_ROOT/ports.log"
do_install >"$TEST_ROOT/operation.log" 2>&1
trap cleanup EXIT
[[ -s $APP_DIR/state && -s $APP_DIR/install.sh && -s $SHORTCUT ]] || fail 'fresh installation incomplete'
[[ $(tr '\n' ' ' <"$TEST_ROOT/ports.log") == '443 30003 ' ]] || fail 'checked unselected ports'
! grep -q cloudflared "$TEST_ROOT/download.log" || fail 'fresh install downloaded unselected Tunnel'
! grep -q cloudflared "$TEST_ROOT/systemctl.log" || fail 'fresh install started unselected Tunnel'
[[ ! -e $UNIT_DIR/cloudflared-lite.service && ! -e $APP_DIR/cloudflared.env ]] || fail 'fresh install created unselected Tunnel'
pass 'fresh install refuses occupied port and installs/starts only the selected VLESS node'
printf 'Management: %s checks passed; downloads and system services mocked.\n' "$passed"
