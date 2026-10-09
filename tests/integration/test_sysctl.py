import ctypes
import errno
import os
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch

pytestmark = pytest.mark.darwin

CTL_KERN = 1
KERN_PROC = 14
KERN_PROC_ALL = 0
KERN_PROCARGS = 38
KERN_PROCARGS2 = 49

PROBE = """
local ffi = require("ffi")
ffi.cdef[[
int sysctl(const int *name, unsigned int namelen, void *oldp,
           size_t *oldlenp, void *newp, size_t newlen);
]]
local pid = tonumber(arg[1])
local function probe(...)
  local count = select("#", ...)
  local mib = ffi.new("int[?]", count, ...)
  local length = ffi.new("size_t[1]", 0)
  if ffi.C.sysctl(mib, count, nil, length, nil, 0) ~= 0 then
    return tostring(ffi.errno())
  end
  length[0] = length[0] * 2 + 1
  local buffer = ffi.new("char[?]", length[0])
  if ffi.C.sysctl(mib, count, buffer, length, nil, 0) ~= 0 then
    return tostring(ffi.errno())
  end
  return "0"
end
print(probe(1, 14, 0), probe(1, 38, pid), probe(1, 49, pid))
"""


def _host_sysctl(*mib: int) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    names = (ctypes.c_int * len(mib))(*mib)
    length = ctypes.c_size_t(0)
    if libc.sysctl(names, len(mib), None, ctypes.byref(length), None, 0) != 0:
        return ctypes.get_errno()
    length.value = length.value * 2 + 1
    buffer = ctypes.create_string_buffer(length.value)
    if libc.sysctl(names, len(mib), buffer, ctypes.byref(length), None, 0) != 0:
        return ctypes.get_errno()
    return 0


# Seatbelt does not mediate KERN_PROCARGS(2): the reads succeed even with every
# sysctl-read denied. The kernel's only gate is a uid match with the target.
@pytest.mark.xfail(
    strict=True,
    reason="KERN_PROCARGS and KERN_PROCARGS2 are readable by integer MIB; fix pending",
)
def test_process_snooping_sysctls_are_denied(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path
) -> None:
    pid = os.getpid()
    assert [
        _host_sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL),
        _host_sysctl(CTL_KERN, KERN_PROCARGS, pid),
        _host_sysctl(CTL_KERN, KERN_PROCARGS2, pid),
    ] == [0, 0, 0]
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "probe.lua").write_text(PROBE)

    result = launch(
        build_sandbox("sysctl-narrowed-sandbox"), f"luajit probe.lua {pid}", cwd=workspace
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == [str(errno.EPERM)] * 3
