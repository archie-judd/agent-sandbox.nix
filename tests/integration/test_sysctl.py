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

JOIN_PROBE = (
    """
local ffi = require("ffi")
ffi.cdef[[
int getpgid(int pid);
int setpgid(int pid, int pgid);
]]
if ffi.C.setpgid(0, ffi.C.getpgid(tonumber(arg[1]))) ~= 0 then
  io.write(tostring(ffi.errno()), " ")
else
  io.write("0 ")
end
"""
    + PROBE
)


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
        build_sandbox("sysctl-narrowed-sandbox"),
        f"luajit probe.lua {pid}",
        cwd=workspace,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == [str(errno.EPERM)] * 3


def test_a_sandbox_launched_in_the_callers_session_cannot_read_or_join_it(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "probe.lua").write_text(JOIN_PROBE)

    result = launch(
        build_sandbox("sysctl-narrowed-sandbox"),
        f"luajit probe.lua {os.getpid()}",
        cwd=workspace,
        new_session=False,
    )

    assert result.returncode == 0, result.stderr
    joined, *reads = result.stdout.split()
    assert joined != "0"
    assert reads == [str(errno.EPERM)] * 3


def test_a_sandbox_on_a_terminal_cannot_join_the_launchers_group(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "probe.lua").write_text(JOIN_PROBE)

    result = launch(
        build_sandbox("sysctl-narrowed-sandbox"),
        "luajit probe.lua $PPID",
        cwd=workspace,
        tty_reply="",
    )

    assert result.returncode == 0, result.stdout
    joined, *reads = result.stdout.split()[-4:]
    assert joined != "0"
    assert reads == [str(errno.EPERM)] * 3
