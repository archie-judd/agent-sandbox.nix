#!/usr/bin/env bash
# Test: the narrowed sysctl-read profile blocks per-process snooping.
# Regression for the pentest finding that the previous blanket
# (allow sysctl-read) exposed:
#   - kern.proc.all (enumerate every host-UID process)
#   - kern.procargs / kern.procargs2 via sysctl({1,49,pid}) — the
#     argv+envp of every host-UID process, including any secrets in
#     env vars (CLAUDE_CODE_OAUTH_TOKEN, GITHUB_TOKEN, AWS_*, ...).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/sysctl-narrowed-sandbox.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/sysctl-narrowed.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== sysctl-read narrowed (Darwin) ==="
echo

# --- Process snooping: must fail ---
expect_fail "kern.proc.all denied (process enumeration)" "sysctl -n kern.proc.all"
expect_fail "kern.procargs denied (argv reader)" "sysctl -n kern.procargs"
expect_fail "kern.procargs2 denied (argv+envp extraction)" "sysctl -n kern.procargs2"

# Integer-MIB form via FFI — this is the actual KERN_PROCARGS2 attack
# primitive ({CTL_KERN=1, KERN_PROCARGS2=49, pid}). The named deny above
# catches it because seatbelt resolves integer MIBs to their canonical
# names before applying rules.
PROCARGS_SCRIPT=$(cat <<'LUA'
local ffi = require("ffi")
ffi.cdef[[
int sysctl(const int *name, unsigned int namelen, void *oldp,
           size_t *oldlenp, void *newp, size_t newlen);
]]
local mib = ffi.new("int[3]", 1, 49, 1)         -- KERN_PROCARGS2 for PID 1
local outlen = ffi.new("size_t[1]", 4096)
local buf = ffi.new("char[?]", 4096)
local r = ffi.C.sysctl(mib, 3, buf, outlen, nil, 0)
os.exit(r == 0 and 0 or 1)
LUA
)
expect_fail "sysctl({1,49,pid}) KERN_PROCARGS2 denied via FFI" \
  "luajit -e '$PROCARGS_SCRIPT'"

print_results
exit_status
