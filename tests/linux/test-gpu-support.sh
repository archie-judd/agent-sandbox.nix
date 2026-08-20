#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

GPU_ALLOWED=$(nix-build --no-out-link -A withGpu "$SCRIPT_DIR/../fixtures/gpu-support.nix")
GPU_ALLOWED_SHELL="$GPU_ALLOWED/bin/sandboxed-bash-gpu-allowed"

GPU_DENIED=$(nix-build --no-out-link -A withoutGpu "$SCRIPT_DIR/../fixtures/gpu-support.nix")
GPU_DENIED_SHELL="$GPU_DENIED/bin/sandboxed-bash-gpu-denied"

echo "=== GPU support tests (Linux) ==="
echo

run() { "$GPU_ALLOWED_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_ok "sandbox launches with allowGpu, whether or not the host has a GPU" \
    'true'

if [ -e /dev/dri ]; then
    expect_ok "/dev/dri is visible inside the sandbox with allowGpu" \
        '[ -e /dev/dri ]'

    run() { "$GPU_DENIED_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
    expect_fail "/dev/dri is not visible inside the sandbox without allowGpu" \
        '[ -e /dev/dri ]'
else
    echo "SKIP: host has no /dev/dri — skipping device-visibility assertions"
fi

print_results
exit_status
