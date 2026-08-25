"""Fixed values shared by the launcher and, by convention, by the stub.

The artifact filenames are part of the contract with stub.sh: the stub is
static, so it finds what it needs by name rather than being told.
"""

ARGV_BEFORE_ENV = "argv-before-env"
ARGV_AFTER_ENV = "argv-after-env"
# Written for reading, not for bubblewrap: it gets these as argv. See
# write_launch_config.
BWRAP_ARGS = "bwrap.args"
# Everything the in-namespace entry point applies before exec: the nft
# ruleset, the /proc/sys writes a ruleset cannot express, and whether to
# drop the default route. JSON because it is a computed instruction set
# with a boolean in it, read the same way the launcher reads spec.json.
NETWORK = "network.json"
SEATBELT_PROFILE = "seatbelt.sb"
PASSWD = "passwd"
CA_BUNDLE = "ca-bundle.pem"
CA_CERT = "ca-cert.pem"
PROXY_PID = "proxy.pid"
PROXY_LOG = "proxy.log"
CLEANUP = "cleanup"
CLEANUP_IF_EMPTY = "cleanup-if-empty"
STUB_PID = "stub.pid"

PROXY_LISTEN_HOST = "127.0.0.1"
PROXY_STARTUP_TIMEOUT_SECONDS = 5.0
SESSION_RETENTION = 25

WARN_PREFIX = "[WARN][agent-sandbox.nix]"
ERROR_PREFIX = "[ERROR][agent-sandbox.nix]"
