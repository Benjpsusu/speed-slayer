#!/usr/bin/env bash
# Isolated install/migration checks; no real system services or network changes.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/speed-lite-xhttp.XXXXXX")
cleanup() {
  local result=$?
  if (( result != 0 )) && [[ -f $TEST_ROOT/migration.log ]]; then tail -n 12 "$TEST_ROOT/migration.log" >&2; fi
  local resolved parent
  resolved=$(cd "$TEST_ROOT" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-lite-xhttp.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
if [[ -n ${SPEED_TEST_PYTHON:-} ]]; then
  python3() { "$SPEED_TEST_PYTHON" "$@" | tr -d '\r'; }
fi
mkdir "$TEST_ROOT/app"
# Replace the single fixed application directory in a private test copy.
awk -v root="$TEST_ROOT" '/^readonly APP_DIR=/ {print "readonly APP_DIR=\"" root "/app\""; next} {print}' \
  "$TEST_DIR/install.sh" > "$TEST_ROOT/installer.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/installer.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }
need_root() { :; }
openssl() { command openssl "$@" | tr -d '\r'; }
chown() { [[ $1 == root:xray && $2 == "$TEST_ROOT/"* ]] || fail 'unexpected chown'; }
flock() { [[ $* == '-n 9' ]] || fail 'unexpected flock'; }
apt-get() { fail 'must not invoke the package manager'; }
public_ip() {
  [[ ! -f $TEST_ROOT/fail-client-info ]] || return 1
  printf '203.0.113.15\n'
}
systemctl() {
  printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.log"
  case "$*" in
    'is-active --quiet xray-lite.service') return 0 ;;
    'restart xray-lite.service')
      if [[ -f $TEST_ROOT/fail-restart ]]; then rm "$TEST_ROOT/fail-restart"; return 1; fi ;;
    *) fail "unexpected systemctl: $*" ;;
  esac
}
xray() {
  if [[ $1 == run && -f $TEST_ROOT/fail-validation ]]; then return 37; fi
  if [[ -n ${SPEED_TEST_XRAY:-} ]]; then
    "$SPEED_TEST_XRAY" "$@" | tr -d '\r'
  else
    case $1 in
      uuid) printf 'b0dd64e4-0fbd-4038-9139-d1f32a68a0dc\n' ;;
      x25519) printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
      run) python3 -m json.tool "$4" >/dev/null ;;
      *) fail "unexpected xray: $*" ;;
    esac
  fi
}

valid_reality_port 443 || fail '443 must be accepted for REALITY'
valid_reality_port 30002 || fail '30002 must remain supported'
! valid_reality_port 80 || fail 'other privileged ports should not be accepted'
! valid_port 443 || fail 'internal/SS port policy must stay unchanged'
for path in '/safe_path-123' '/nested/path'; do valid_xhttp_path "$path" || fail 'valid path rejected'; done
for path in '' '/' 'foo' '/a?b=c' '/a&b' '/a"b' '/a b' '/中文'; do
  ! valid_xhttp_path "$path" || fail 'unsafe path accepted'
done
pass '443 and custom port policy; XHTTP path input validation'

VMESS_PORT=30000 SS_PORT=30001 REALITY_PORT=30002 REALITY_GUARD_PORT=30003
VMESS_ADDRESS=www.wto.org REALITY_SERVER_NAME=learn.microsoft.com
ARGO_MODE=token ARGO_DOMAIN=tunnel.example.com ARGO_TOKEN=test-token
XHTTP_PATH=/test/random_path
write_config
cp "$TEST_ROOT/installer.sh" "$APP_DIR/install.sh"
write_client_info
python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys, urllib.parse
root = pathlib.Path(sys.argv[1])
c = json.loads((root/'xray.json').read_text(encoding='utf-8'))
n = next(n for n in c['inbounds'] if n['tag'] == 'vless-reality')
assert n['streamSettings']['network'] == 'xhttp'
assert n['streamSettings']['xhttpSettings'] == {'path': '/test/random_path', 'mode': 'auto'}
assert 'flow' not in n['settings']['clients'][0]
assert n['streamSettings']['realitySettings']['target'] == '127.0.0.1:30003'
link = next(l for l in (root/'client-info.txt').read_text(encoding='utf-8').splitlines() if l.startswith('vless://'))
uri = urllib.parse.urlsplit(link)
q = urllib.parse.parse_qs(uri.query)
assert uri.port == 30002 and q['type'] == ['xhttp'] and q['mode'] == ['auto']
assert q['path'] == ['/test/random_path'] and 'flow' not in q
assert q['pbk'] and q['sid'] and q['sni'] == ['learn.microsoft.com']
assert 'path=%2Ftest%2Frandom_path' in link
client = {'outbounds': [{
    'protocol': 'vless',
    'settings': {'vnext': [{'address': uri.hostname, 'port': uri.port,
                          'users': [{'id': uri.username, 'encryption': 'none'}]}]},
    'streamSettings': {'network': q['type'][0], 'security': 'reality',
        'xhttpSettings': {'mode': q['mode'][0], 'path': q['path'][0]},
        'realitySettings': {'serverName': q['sni'][0], 'password': q['pbk'][0],
                           'shortId': q['sid'][0], 'fingerprint': q['fp'][0]}}
}]}
(root/'test-client.json').write_bytes(json.dumps(client).encode('utf-8'))
PY
pass 'fresh config and URL agree on XHTTP, encoded path, credentials and no Vision flow'
xray run -test -config "$APP_DIR/xray.json" > "$TEST_ROOT/config-test.log" 2>&1
xray run -test -config "$APP_DIR/test-client.json" >> "$TEST_ROOT/config-test.log" 2>&1
pass 'generated server and URL-derived client configuration validation'
unset XHTTP_PATH
write_config
[[ $XHTTP_PATH =~ ^/[a-f0-9]{32}$ ]] || fail 'missing random XHTTP path'
pass 'default path is randomly generated'
REALITY_PORT=443 render_xray_unit > "$TEST_ROOT/unit443"
REALITY_PORT=30002 render_xray_unit > "$TEST_ROOT/unit30002"
grep -qx 'User=xray' "$TEST_ROOT/unit443" || fail 'must keep unprivileged account'
grep -qx 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$TEST_ROOT/unit443" || fail '443 requires bind capability'
! grep -q 'AmbientCapabilities' "$TEST_ROOT/unit30002" || fail 'high ports need no extra capability'
pass '443 grants bind capability while retaining xray user; high ports do not'

# Make a previously installed TCP/Vision fixture, without new state markers.
python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
c = json.loads((root/'xray.json').read_text(encoding='utf-8'))
n = next(n for n in c['inbounds'] if n['tag'] == 'vless-reality')
n['streamSettings']['network'] = 'raw'
n['streamSettings'].pop('xhttpSettings')
n['settings']['clients'][0]['flow'] = 'xtls-rprx-vision'
(root/'xray.json').write_text(json.dumps(c), encoding='utf-8')
lines = (root/'state').read_text(encoding='utf-8').splitlines()
(root/'state').write_bytes(('\n'.join(l for l in lines if not l.startswith(('VLESS_TRANSPORT=', 'XHTTP_PATH=')))+'\n').encode('utf-8'))
PY
VLESS_TRANSPORT=xhttp XHTTP_PATH=/environment-must-not-override-state write_client_info
grep -q 'type=tcp&flow=xtls-rprx-vision' "$APP_DIR/client-info.txt" || fail 'legacy show must not claim XHTTP'
pass 'old install still exports TCP until explicit migration, ignoring environment overrides'
mkdir "$TEST_ROOT/original"
cp "$APP_DIR/xray.json" "$APP_DIR/state" "$APP_DIR/install.sh" "$APP_DIR/client-info.txt" "$TEST_ROOT/original/"

expect_migration_failure() {
  local status
  # Avoid a conditional function call: it would disable errexit inside migration.
  set +e
  (set -e; do_migrate_xhttp) > "$TEST_ROOT/migration.log" 2>&1
  status=$?
  set -e
  (( status != 0 )) || fail 'migration unexpectedly succeeded'
  for name in xray.json state install.sh client-info.txt; do
    cmp "$APP_DIR/$name" "$TEST_ROOT/original/$name" || fail "rollback mismatch: $name"
  done
}
: > "$TEST_ROOT/fail-validation"
expect_migration_failure
[[ ! -f $TEST_ROOT/systemctl.log ]] || ! grep -q '^restart' "$TEST_ROOT/systemctl.log" || fail 'invalid candidate must not restart service'
rm "$TEST_ROOT/fail-validation"
pass 'configuration rejection leaves old configuration and links untouched'
: > "$TEST_ROOT/fail-restart"
expect_migration_failure
[[ $(grep -c '^restart' "$TEST_ROOT/systemctl.log") == 2 ]] || fail 'failed restart should restore then restart old service'
pass 'service restart failure restores config, state, installer and client info'
: > "$TEST_ROOT/fail-client-info"
expect_migration_failure
rm "$TEST_ROOT/fail-client-info"
pass 'failure after service restart also restores all saved files'

do_migrate_xhttp > "$TEST_ROOT/migration.log" 2>&1
python3 - "$APP_DIR" "$TEST_ROOT/original" <<'PY'
import json, pathlib, sys
root, old = map(pathlib.Path, sys.argv[1:])
c = json.loads((root/'xray.json').read_text(encoding='utf-8'))
before = json.loads((old/'xray.json').read_text(encoding='utf-8'))
for prev, now in zip(before['inbounds'], c['inbounds']):
    if prev['tag'] != 'vless-reality':
        assert prev == now
        continue
    assert prev['port'] == now['port']
    assert prev['streamSettings']['realitySettings'] == now['streamSettings']['realitySettings']
    assert now['streamSettings']['network'] == 'xhttp'
    assert prev['settings']['clients'][0]['id'] == now['settings']['clients'][0]['id']
    assert 'flow' not in now['settings']['clients'][0]
assert before['outbounds'] == c['outbounds'] and before['routing'] == c['routing']
state = dict(l.split('=', 1) for l in (root/'state').read_text(encoding='utf-8').splitlines())
old_state = dict(l.split('=', 1) for l in (old/'state').read_text(encoding='utf-8').splitlines())
assert all(state[k] == v for k,v in old_state.items())
assert state['XHTTP_PATH'] == c['inbounds'][-1]['streamSettings']['xhttpSettings']['path']
assert state['VLESS_TRANSPORT'] == 'xhttp'
assert 'type=xhttp' in (root/'client-info.txt').read_text(encoding='utf-8')
assert list(root.glob('backup-xhttp-*'))
PY
pass 'migration preserves other nodes, guard, credentials and port; exports new link and saves backups'
cp "$APP_DIR/xray.json" "$TEST_ROOT/once.json"
cp "$APP_DIR/state" "$TEST_ROOT/once.state"
do_migrate_xhttp > "$TEST_ROOT/migration.log" 2>&1
cmp "$APP_DIR/xray.json" "$TEST_ROOT/once.json"
cmp "$APP_DIR/state" "$TEST_ROOT/once.state"
pass 'repeat migration keeps the existing XHTTP path and credentials'

# Refuse state mismatches and custom XHTTP modes before any persistent changes.
python3 - "$APP_DIR" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])/'state'
p.write_bytes(p.read_text(encoding='utf-8').replace('REALITY_PORT=30002', 'REALITY_PORT=30004').encode('utf-8'))
PY
mkdir "$TEST_ROOT/rejected"
if prepare_xhttp_migration "$TEST_ROOT/rejected" > "$TEST_ROOT/rejected.log" 2>&1; then fail 'mismatched state accepted'; fi
[[ ! -e $TEST_ROOT/rejected/next.json ]] || fail 'must not write candidates for unsupported state'
pass 'mismatched installed state rejected before mutation'
cp "$TEST_ROOT/once.state" "$APP_DIR/state"
python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])/'xray.json'
c = json.loads(p.read_text(encoding='utf-8'))
c['inbounds'][-1]['streamSettings']['xhttpSettings']['mode'] = 'packet-up'
p.write_bytes(json.dumps(c).encode('utf-8'))
PY
if prepare_xhttp_migration "$TEST_ROOT/rejected" > "$TEST_ROOT/rejected.log" 2>&1; then fail 'custom XHTTP mode overwritten'; fi
pass 'custom existing XHTTP mode is protected from automatic overwrite'

if [[ -n ${SPEED_TEST_XRAY:-} ]]; then
  printf 'XHTTP: %s checks passed, using real Xray for config validation; systemd mocked.\n' "$passed"
else
  printf 'XHTTP: %s checks passed (mock Xray; set SPEED_TEST_XRAY for real core validation).\n' "$passed"
fi
