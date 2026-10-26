#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
# shellcheck source=install.sh
. "$TEST_DIR/install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }

valid_port 1024 || fail "1024 should be valid"
valid_port 65535 || fail "65535 should be valid"
! valid_port 1023 || fail "1023 should be invalid"
! valid_port 65536 || fail "65536 should be invalid"
validate_domain example.com || fail "example.com should be valid"
! validate_domain localhost || fail "localhost should be invalid"

assert_eq "$(encode_ss2022_password 'abc+/=')" 'abc%2B%2F%3D'

systemctl() {
  [[ $* == *'--property=InvocationID'* ]] && printf 'test-invocation\n'
}

TEST_LOG_MODE=domain
journalctl() {
  [[ $* == *'_SYSTEMD_INVOCATION_ID=test-invocation'* ]] || return 1
  if [[ $TEST_LOG_MODE == domain ]]; then
    printf 'old https://old-name.trycloudflare.com\nnew https://new-name.trycloudflare.com\n'
  fi
}

assert_eq "$(quick_domain)" 'new-name.trycloudflare.com'
TEST_LOG_MODE=empty
assert_eq "$(quick_domain)" ''

printf 'speed-slayer-lite self-check passed\n'
bash "$TEST_DIR/test-xhttp.sh"
