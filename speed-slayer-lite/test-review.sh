#!/usr/bin/env bash
# Run the unchanged original suites against install-review.sh, then the review regressions.
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/speed-lite-review.XXXXXX")
cleanup() {
  local resolved parent
  resolved=$(cd "$STAGE" && pwd -P)
  parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  [[ $resolved == "$parent"/speed-lite-review.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
# The original suites read "$TEST_DIR/install.sh", so stage them beside the review build.
cp "$TEST_DIR/install-review.sh" "$STAGE/install.sh"
cp "$TEST_DIR/test.sh" "$TEST_DIR/test-xhttp.sh" "$TEST_DIR/test-manage.sh" \
  "$TEST_DIR/test-anytls.sh" "$TEST_DIR/test-anytls-loopback.py" "$STAGE/"
bash "$STAGE/test.sh"
bash "$TEST_DIR/test-review-cases.sh"
printf 'speed-slayer-lite review build: original and review suites passed.\n'
