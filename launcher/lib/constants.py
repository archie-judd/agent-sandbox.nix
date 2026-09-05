# The artifact filenames are a contract with stub.sh, which finds what it
# needs by name.

ARGV_BEFORE_ENV = "argv-before-env"
ARGV_AFTER_ENV = "argv-after-env"
BWRAP_ARGS = "bwrap.args"
NETWORK = "network.json"
SEATBELT_PROFILE = "seatbelt.sb"
SECCOMP_FILTER = "seccomp.bpf"
# Where apply_network_rules leaves the filter open, and the number compute.py
# writes after --seccomp; the two sides never meet in one process.
SECCOMP_FD = 9
PASSWD = "passwd"
CA_BUNDLE = "ca-bundle.pem"
CA_CERT = "ca-cert.pem"
PROXY_PID = "proxy.pid"
PROXY_LOG = "proxy.log"
LAUNCH_LOG = "launch.log"
CLEANUP = "cleanup"
CLEANUP_IF_EMPTY = "cleanup-if-empty"
STUB_PID = "stub.pid"

PROXY_LISTEN_HOST = "127.0.0.1"
# The proxy runs on the host, so it refuses every loopback address: honouring
# one would reach host services allowedLocalPorts exists to gate. A client that
# obeys HTTP_PROXY would hand it those requests anyway and get a 403, never
# taking the direct path allowedLocalPorts opened. These send it there instead.
NO_PROXY_HOSTS = "localhost,127.0.0.1,::1"
PROXY_STARTUP_TIMEOUT_SECONDS = 5.0
SESSION_RETENTION = 25

WARN_PREFIX = "[WARN][agent-sandbox.nix]"
ERROR_PREFIX = "[ERROR][agent-sandbox.nix]"
