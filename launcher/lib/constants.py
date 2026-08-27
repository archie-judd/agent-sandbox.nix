"""Fixed values shared by the launcher and, by convention, by the stub.

The artifact filenames are part of the contract with stub.sh: the stub is
static, so it finds what it needs by name rather than being told.
"""

ARGV_BEFORE_ENV = "argv-before-env"
ARGV_AFTER_ENV = "argv-after-env"
# Written for reading, not for bubblewrap: it gets these as argv. Newline-
# separated for that reason, where the machine-read artifacts are NUL-separated.
# See write_launch_config.
BWRAP_ARGS = "bwrap.args"
# Everything the in-namespace entry point applies before exec: the nft
# ruleset, the /proc/sys writes a ruleset cannot express, and whether to
# drop the default route. JSON because it is a computed instruction set
# with a boolean in it, read the same way the launcher reads spec.json.
NETWORK = "network.json"
SEATBELT_PROFILE = "seatbelt.sb"
# The compiled BPF program denying socket(AF_UNIX, ...). Written only when
# allowUnixSockets is off; see launch_config/linux/seccomp.py.
SECCOMP_FILTER = "seccomp.bpf"
# Where apply_network_rules leaves the filter open for bubblewrap, and the
# number compute.py writes after --seccomp. A contract like the filenames
# above: the two sides never meet in one process, so they agree here. Fixed
# and low, but above stdio; the entry point owns no other descriptors.
SECCOMP_FD = 9
PASSWD = "passwd"
CA_BUNDLE = "ca-bundle.pem"
CA_CERT = "ca-cert.pem"
PROXY_PID = "proxy.pid"
PROXY_LOG = "proxy.log"
# What the launch recorded about itself. Separate from proxy.log, which is a
# different process's stderr held open for the whole session; see launch_log.
LAUNCH_LOG = "launch.log"
CLEANUP = "cleanup"
CLEANUP_IF_EMPTY = "cleanup-if-empty"
STUB_PID = "stub.pid"

PROXY_LISTEN_HOST = "127.0.0.1"
PROXY_STARTUP_TIMEOUT_SECONDS = 5.0
SESSION_RETENTION = 25

WARN_PREFIX = "[WARN][agent-sandbox.nix]"
ERROR_PREFIX = "[ERROR][agent-sandbox.nix]"
