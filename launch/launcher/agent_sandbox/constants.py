"""Fixed values shared by the launcher and, by convention, by the stub.

The artifact filenames are part of the contract with stub.sh: the stub is
static, so it finds what it needs by name rather than being told.
"""

ARGV_BEFORE_ENV = "argv-before-env"
ARGV_AFTER_ENV = "argv-after-env"
BWRAP_ARGS = "bwrap.args"
NFT_RULES = "nft.rules"
SEATBELT_PROFILE = "seatbelt.sb"
PASSWD = "passwd"
CA_BUNDLE = "ca-bundle.pem"
CA_CERT = "ca-cert.pem"
PROXY_PID = "proxy.pid"
PROXY_LOG = "proxy.log"
CLEANUP = "cleanup"

PROXY_LISTEN_HOST = "127.0.0.1"
PROXY_STARTUP_TIMEOUT_SECONDS = 5.0

WARN_PREFIX = "[WARN][agent-sandbox.nix]"
ERROR_PREFIX = "[ERROR][agent-sandbox.nix]"
