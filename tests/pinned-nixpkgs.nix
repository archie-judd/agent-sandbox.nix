# The nixpkgs the flake locks, so the test suite does not build against
# whatever channel happens to be on the machine. Fixtures default to this
# rather than taking it from the harness, so building a fixture by hand is
# pinned too.
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = lock.nodes.nixpkgs.locked;
in import (builtins.fetchTarball {
  url = "https://github.com/${nixpkgs.owner}/${nixpkgs.repo}/archive/${nixpkgs.rev}.tar.gz";
  sha256 = nixpkgs.narHash;
})
