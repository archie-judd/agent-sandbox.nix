"""A classic-BPF program that makes socket(AF_UNIX, ...) fail with EPERM.
Classic BPF cannot dereference the sockaddr_un, so unlike seatbelt this
cannot scope by path: the only positions Linux can hold are "no AF_UNIX" and
"whatever the mounts expose".

EPERM rather than SECCOMP_RET_KILL, because callers probe for AF_UNIX
services and fall back (glibc treats an unreachable nscd socket as nscd
absent); killing would turn each probe into a crash. socketpair(2) is a
different syscall, so anonymous pairs, which reach nothing on the host, pass
untouched.
"""

import struct

# struct sock_filter { __u16 code; __u8 jt; __u8 jf; __u32 k; }, in the byte
# order of the machine the kernel reads it on, which is the machine this runs
# on. "=": native order, standard sizes, no padding.
_SOCK_FILTER = struct.Struct("=HBBI")

# BPF opcodes (linux/bpf_common.h) and seccomp return values (linux/seccomp.h).
_LD_W_ABS = 0x20  # BPF_LD | BPF_W | BPF_ABS
_JEQ_K = 0x15  # BPF_JMP | BPF_JEQ | BPF_K
_JGE_K = 0x35  # BPF_JMP | BPF_JGE | BPF_K
_RET_K = 0x06  # BPF_RET | BPF_K
_RET_ALLOW = 0x7FFF0000  # SECCOMP_RET_ALLOW
_RET_EPERM = 0x00050001  # SECCOMP_RET_ERRNO | EPERM

# struct seccomp_data field offsets: nr, arch, then args[6] of __u64 each.
# The low half of args[0] is at offset 16 on the little-endian machines below;
# an AF_* constant always fits in it.
_OFF_NR = 0
_OFF_ARCH = 4
_OFF_ARG0_LO = 16

_AF_UNIX = 1

# AUDIT_ARCH_* (linux/audit.h) and __NR_socket, per machine. Both supported
# machines are little-endian, which _OFF_ARG0_LO above relies on.
_MACHINES = {
    "x86_64": (0xC000003E, 41),
    "aarch64": (0xC00000B7, 198),
}
SUPPORTED_MACHINES = frozenset(_MACHINES)

# x86_64 kernels also accept x32-ABI syscalls, tagged by this bit in nr, with
# their own numbering. Rather than mirror the socket check for a second table,
# the filter refuses the whole ABI: nothing in a nix closure is x32.
_X32_SYSCALL_BIT = 0x40000000


def get_unix_deny_filter(machine: str) -> bytes:
    """The compiled program for `machine`, which must be in SUPPORTED_MACHINES
    (an unchecked caller gets a KeyError, which is the bug it would be).

    The shape, with jumps resolved against the two returns at the end:

        ld  arch
        jne AUDIT_ARCH        -> eperm   ; a compat ABI would bypass the
                                         ; check below, so no compat ABI
        ld  nr
        jge X32_SYSCALL_BIT   -> eperm   ; x86_64 only, see above
        jne __NR_socket       -> allow
        ld  args[0] (low half)
        jeq AF_UNIX           -> eperm
        allow: ret ALLOW
        eperm: ret ERRNO(EPERM)
    """
    audit_arch, nr_socket = _MACHINES[machine]

    # (code, jt, jf, k) with jump targets as "allow"/"eperm" labels; 0 falls
    # through. Resolved below against the label positions, so inserting or
    # removing an instruction cannot silently skew a hand-counted offset.
    labelled: list[tuple[int, int | str, int | str, int]] = [
        (_LD_W_ABS, 0, 0, _OFF_ARCH),
        (_JEQ_K, 0, "eperm", audit_arch),
        (_LD_W_ABS, 0, 0, _OFF_NR),
    ]
    if machine == "x86_64":
        labelled.append((_JGE_K, "eperm", 0, _X32_SYSCALL_BIT))
    labelled += [
        (_JEQ_K, 0, "allow", nr_socket),
        (_LD_W_ABS, 0, 0, _OFF_ARG0_LO),
        (_JEQ_K, "eperm", 0, _AF_UNIX),
    ]
    targets = {"allow": len(labelled), "eperm": len(labelled) + 1}

    def resolve(target: int | str, position: int) -> int:
        if isinstance(target, int):
            return target
        return targets[target] - (position + 1)

    program = [
        _SOCK_FILTER.pack(code, resolve(jt, i), resolve(jf, i), k)
        for i, (code, jt, jf, k) in enumerate(labelled)
    ]
    program.append(_SOCK_FILTER.pack(_RET_K, 0, 0, _RET_ALLOW))
    program.append(_SOCK_FILTER.pack(_RET_K, 0, 0, _RET_EPERM))
    return b"".join(program)
