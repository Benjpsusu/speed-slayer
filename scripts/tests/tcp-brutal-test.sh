#!/usr/bin/env bash
# Isolated tests: never call the host's ip, brutalctl, systemctl, modprobe or sysctl.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/speed-brutal-test.XXXXXX")
cleanup() {
  local resolved parent
  resolved=$(cd "$TEST_TMP" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-brutal-test.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
# On Windows, PowerShell can supply a managed Python executable.
if [[ -n ${BRUTAL_TEST_PYTHON:-} ]]; then
  python3() { "$BRUTAL_TEST_PYTHON" "$@" | tr -d '\r'; }
fi
# shellcheck source=../tcp-brutal.sh
. "$TEST_DIR/../tcp-brutal.sh"

BRUTAL_DIR=$TEST_TMP
BRUTAL_RULES=$TEST_TMP/rules.tsv
BRUTAL_PROC=$TEST_TMP/proc-rules
BRUTAL_MODULE_VERSION=$TEST_TMP/version
BRUTAL_MANAGER=$TEST_TMP/manager
BRUTAL_UNIT=$TEST_TMP/unit
MOCK_ROUTES=$TEST_TMP/routes
MOCK_CALLS=$TEST_TMP/calls
MOCK_POLICIES='[{"priority":0,"src":"all","table":"255"},{"priority":32766,"src":"all","table":"254"},{"priority":32767,"src":"all","table":"253"}]'
MOCK_ROUTE_MODE=normal
MOCK_ADD_FAIL_RATE=''
MOCK_DELETE_FAIL_HOST=''
MOCK_ENABLE_FAIL=0
MOCK_NO_ROUTE=0
TEST_COUNT=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
reject() { if "$@" > "$TEST_TMP/rejected.log" 2>&1; then fail "unexpected success: $*"; fi; }
pass() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'ok %s - %s\n' "$TEST_COUNT" "$*"; }

fixture_route() {
  awk -F '\t' -v host="$1" '$1 != host' "$MOCK_ROUTES" > "$MOCK_ROUTES.new"
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-brutal}" >> "$MOCK_ROUTES.new"
  mv "$MOCK_ROUTES.new" "$MOCK_ROUTES"
}

ip() {
  printf 'ip %s\n' "$*" >> "$MOCK_CALLS"
  local host=${*: -1} proto congestion
  case "$*" in
    *' rule show') printf '%s\n' "$MOCK_POLICIES" ;;
    *' route get '*)
      case $MOCK_ROUTE_MODE in
        fail) return 1 ;;
        local) printf '[{"type":"local","dev":"lo","table":"255"}]\n' ;;
        normal) printf '[{"dev":"eth0","gateway":"192.0.2.1","table":"254"}]\n' ;;
      esac ;;
    *' route show table '*' exact '*)
      proto=$(awk -F '\t' -v host="$host" '$1 == host {print $2}' "$MOCK_ROUTES")
      congestion=$(awk -F '\t' -v host="$host" '$1 == host {print $3}' "$MOCK_ROUTES")
      if [[ -z $proto ]]; then printf '[]\n'; else
        printf '[{"dst":"%s","table":"254","protocol":"%s","metrics":[{"congestion":"%s"}]}]\n' "$host" "$proto" "$congestion"
      fi ;;
    *' route del '*)
      [[ $5 == proto && $6 == 233 ]] || fail 'unexpected route deletion'
      awk -F '\t' -v host="$4" '!($1 == host && $2 == "233")' "$MOCK_ROUTES" > "$MOCK_ROUTES.new"
      mv "$MOCK_ROUTES.new" "$MOCK_ROUTES" ;;
    *) fail "unexpected ip invocation: $*" ;;
  esac
}

brutalctl() {
  printf 'brutalctl %s\n' "$*" >> "$MOCK_CALLS"
  local host=${2:-} rate=${3:-}
  case $1 in
    add)
      awk -v key="dst=$host" '$1 != key' "$BRUTAL_PROC" > "$BRUTAL_PROC.new"
      printf 'dst=%s rate=%s gain=20 lock=1 id=1 members=0 sent=0\n' "$host" "$((rate * 125000))" >> "$BRUTAL_PROC.new"
      mv "$BRUTAL_PROC.new" "$BRUTAL_PROC"
      [[ $rate != "$MOCK_ADD_FAIL_RATE" ]] || return 1
      if [[ $MOCK_NO_ROUTE == 0 ]]; then fixture_route "$host" 233; fi ;;
    del)
      [[ $host != "$MOCK_DELETE_FAIL_HOST" ]] || return 1
      awk -v key="dst=$host" '$1 != key' "$BRUTAL_PROC" > "$BRUTAL_PROC.new"
      mv "$BRUTAL_PROC.new" "$BRUTAL_PROC"
      ip "$(b_family "$host")" route del "$host" proto 233 ;;
    list) cat "$BRUTAL_PROC" ;;
    *) fail "must not call brutalctl $1" ;;
  esac
}

systemctl() {
  printf 'systemctl %s\n' "$*" >> "$MOCK_CALLS"
  case $1 in
    enable) [[ $MOCK_ENABLE_FAIL == 0 ]] || return 1; : > "$TEST_TMP/enabled" ;;
    disable) rm -f "$TEST_TMP/enabled" ;;
    is-enabled) [[ -f $TEST_TMP/enabled ]] && printf 'enabled\n' || { printf 'disabled\n'; return 1; } ;;
    *) fail "unexpected systemctl: $*" ;;
  esac
}
sysctl() { [[ $* == '-n net.ipv4.tcp_congestion_control' ]] || fail 'must not change sysctl'; printf 'bbr\n'; }
modprobe() { fail 'must not load a real kernel module'; }
uname() { case $1 in -r) printf '%s\n' "$MOCK_KERNEL";; *) fail 'unexpected uname';; esac; }

for file in "$BRUTAL_RULES" "$BRUTAL_PROC" "$BRUTAL_MANAGER" "$BRUTAL_UNIT" "$MOCK_ROUTES" "$MOCK_CALLS"; do : > "$file"; done
printf '%s\n' "$BRUTAL_VERSION" > "$BRUTAL_MODULE_VERSION"

eq "$(b_host 203.0.113.5)" '203.0.113.5/32'
eq "$(b_host 2001:db8::5)" '2001:db8::5/128'
pass 'IPv4 and IPv6 canonical host addresses'
for host in 0.0.0.0/0 ::/0 203.0.113.0/24 2001:db8::/64 127.0.0.1 ::1 fe80::1 fe80::1%eth0 224.0.0.1 ::ffff:192.0.2.1 255.255.255.255 'example.com' '1.2.3.4;id'; do reject b_host "$host"; done
pass 'reject subnets, local addresses, domains and injected text'
for rate in 0 -1 0.5 01 100001 999999999999999999 NaN '100;id'; do reject b_rate "$rate"; done
b_rate 1; b_rate 100000
pass 'bandwidth bounds and format'
for MOCK_KERNEL in 5.10.0 6.1.0 6.12.1-xanmod 7.0.0; do b_check_kernel; done
for MOCK_KERNEL in 4.19.0 5.4.0 nonsense; do reject b_check_kernel; done
pass 'minimum running kernel version'

b_add 203.0.113.5 100
eq "$(b_saved_rate 203.0.113.5/32)" 100
eq "$(b_live_rate 203.0.113.5/32)" 12500000
[[ -f $TEST_TMP/enabled ]] || fail 'boot restore must be enabled'
pass 'add activates and persists total Mbps'
b_add 203.0.113.5/32 80
eq "$(b_saved_rate 203.0.113.5/32)" 80
eq "$(awk 'END {print NR}' "$BRUTAL_RULES")" 1
pass 'update is idempotent and replaces the saved rate'
b_add 2001:db8::5 50
b_verify 2001:db8::5/128 50
pass 'IPv6 activation and JSON route verification'
b_status > "$TEST_TMP/status.log"
pass 'status validates saved rules against live module and route'

MOCK_ADD_FAIL_RATE=60
reject b_add 203.0.113.5 60
eq "$(b_saved_rate 203.0.113.5/32)" 80
b_verify 203.0.113.5/32 80
pass 'failed update restores old kernel rate and persistent rate'
reject b_add 203.0.113.6 60
eq "$(b_saved_rate 203.0.113.6/32)" ''
eq "$(b_live_rate 203.0.113.6/32)" ''
pass 'partial add failure cleans newly created kernel rule'
MOCK_ADD_FAIL_RATE=''
MOCK_NO_ROUTE=1
reject b_add 203.0.113.7 30
eq "$(b_saved_rate 203.0.113.7/32)" ''
eq "$(b_live_rate 203.0.113.7/32)" ''
MOCK_NO_ROUTE=0
pass 'a successful tool exit without a route is rejected and cleaned'
MOCK_ENABLE_FAIL=1
reject b_add 203.0.113.8 30
eq "$(b_saved_rate 203.0.113.8/32)" ''
MOCK_ENABLE_FAIL=0
pass 'persistence enable failure does not leave a new active rule'

fixture_route 203.0.113.9/32 4 cubic
reject b_add 203.0.113.9 20
eq "$(b_route_state 203.0.113.9/32)" foreign
pass 'existing administrator route is preserved'
brutalctl add 203.0.113.10/32 25
reject b_add 203.0.113.10 30
reject b_del 203.0.113.10
b_verify 203.0.113.10/32 25
pass 'external Brutal destination is neither adopted nor deleted'
MOCK_POLICIES='[{"priority":100,"src":"all","table":"100"}]'
reject b_add 203.0.113.11 20
MOCK_POLICIES='[{"priority":0,"src":"all","table":255},{"priority":32766,"src":"all","table":254}]'
b_preflight 203.0.113.11/32 0
pass 'custom policy rules rejected; numeric default table IDs accepted'
MOCK_ROUTE_MODE=local
reject b_add 203.0.113.11 20
MOCK_ROUTE_MODE=fail
reject b_add 203.0.113.11 20
MOCK_ROUTE_MODE=normal
pass 'local or unreachable destinations leave persistent state untouched'

# Simulate a reboot: runtime data disappears while persistent state remains.
: > "$BRUTAL_PROC"; : > "$MOCK_ROUTES"
b_restore
b_verify 203.0.113.5/32 80
b_verify 2001:db8::5/128 50
pass 'boot restoration recreates IPv4 and IPv6 rules'
fixture_route 203.0.113.5/32 233 cubic
reject b_status
fixture_route 203.0.113.5/32 233 brutal
pass 'status catches a route with the wrong congestion algorithm'

MOCK_DELETE_FAIL_HOST=203.0.113.5/32
reject b_del 203.0.113.5
eq "$(b_saved_rate 203.0.113.5/32)" 80
MOCK_DELETE_FAIL_HOST=''
pass 'failed deletion keeps ownership for retry'
b_del 203.0.113.5
b_add 203.0.113.5 70
b_verify 203.0.113.5/32 70
pass 'delete followed by re-add works'
brutalctl add 203.0.113.10/32 25
MOCK_DELETE_FAIL_HOST=203.0.113.5/32
reject b_disable
[[ ! -e $TEST_TMP/enabled ]] || fail 'disable must stop boot restoration even on failure'
eq "$(b_saved_rate 203.0.113.5/32)" 70
eq "$(b_saved_rate 2001:db8::5/128)" ''
pass 'partial disable keeps only failed records and disables boot restoration'
MOCK_DELETE_FAIL_HOST=''
b_disable
[[ ! -s $BRUTAL_RULES ]] || fail 'owned rules must be cleared'
b_verify 203.0.113.10/32 25
pass 'disable preserves external rules and routes'

# An interrupted add may leave a route with no proc rule; cleanup must handle it.
printf '203.0.113.12/32\t10\n' > "$BRUTAL_RULES"
fixture_route 203.0.113.12/32 233
b_del 203.0.113.12
eq "$(b_route_state 203.0.113.12/32)" none
pass 'orphaned owned route is removed even when the kernel rule is absent'
printf '203.0.113.5/32\t10\n203.0.113.5/32\t20\n' > "$BRUTAL_RULES"
reject b_restore
printf '$(touch bad)\t10\n' > "$BRUTAL_RULES"
reject b_disable
pass 'corrupt or duplicate persistent records fail before network mutation'

[[ $(bash "$TEST_DIR/../vps-argo-vmess-oneclick.sh" --brutal help) == *'TCP Brutal v2'* ]] || fail 'main entry did not reach shared manager'
[[ $(bash "$TEST_DIR/../../speed-slayer-lite/install.sh" brutal help) == *'TCP Brutal v2'* ]] || fail 'Lite entry did not reach shared manager'
pass 'main and Lite entries reach the same local manager without downloads'
printf 'TCP Brutal: %s checks passed (isolated mocks; no live kernel test).\n' "$TEST_COUNT"
