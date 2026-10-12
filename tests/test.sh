#!/usr/bin/env bash

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
exit_code=0

echo "=== shellcheck ==="
shellcheck --severity=warning resources/scripts/*.sh tests/*.sh || exit_code=1

echo "=== library structure ==="
bash tests/lib-test.sh || exit_code=1

echo "=== deploy scripts ==="
bash tests/deploy-test.sh || exit_code=1

exit "$exit_code"