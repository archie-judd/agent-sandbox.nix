# Changelog

## [2.2.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.1.0...v2.2.0) (2026-07-10)


### Features

* **allowLocalPorts:** Add cross-platform localNetworkAccess targets ([#68](https://github.com/archie-judd/agent-sandbox.nix/issues/68)) ([3a0930a](https://github.com/archie-judd/agent-sandbox.nix/commit/3a0930a2dc9e24d9f93d4c7998f36b1a0a5d272d))

## [2.1.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.0.1...v2.1.0) (2026-06-18)


### Features

* add claude-nix shell.nix ([76dae03](https://github.com/archie-judd/agent-sandbox.nix/commit/76dae037721b1e9fc83f483631fa84af60acc34d))
* **darwin:** allowNix ([6cea43e](https://github.com/archie-judd/agent-sandbox.nix/commit/6cea43e701186fd8d636bf39f871f06a1f5af0bc))
* **linux:** allowNix ([9f0219d](https://github.com/archie-judd/agent-sandbox.nix/commit/9f0219da1156a206573dcf5ddd117bf10c43aee5))
* **README:** allowNix ([bcea1b2](https://github.com/archie-judd/agent-sandbox.nix/commit/bcea1b28f4ed2c4aff2d2672152d6963f0e5604d))


### Bug Fixes

* **darwin:** resolve real nix daemon socket path ([2e9dd51](https://github.com/archie-judd/agent-sandbox.nix/commit/2e9dd5171b70bb0c727b16f21bdf2351fd285f6c))

## [2.0.1](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.0.0...v2.0.1) (2026-06-16)


### Bug Fixes

* **linux:** bind roFile/rwFile symlinks at their declared paths ([4c9cac0](https://github.com/archie-judd/agent-sandbox.nix/commit/4c9cac00437dbfcdf26cf013e434da53a7954fa2))
* **linux:** don't follow symlinks when binding files ([67e7018](https://github.com/archie-judd/agent-sandbox.nix/commit/67e70185e91eb98983a2dbeea73d870d57ef5477))

## [2.0.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v1.0.0...v2.0.0) (2026-06-13)


### ⚠ BREAKING CHANGES

* declared rwDirs/rwFiles must exist before launch
* fail closed on git identity instead of fabricating one

### Features

* declared rwDirs/rwFiles must exist before launch ([1342f80](https://github.com/archie-judd/agent-sandbox.nix/commit/1342f808651dd3fe71b28a033158dd76b1df0117))
* fail closed on git identity instead of fabricating one ([f1122d1](https://github.com/archie-judd/agent-sandbox.nix/commit/f1122d1b920831ee6463420eefd8b8206f46a14e))
* roDirs and roFiles read-only bind primitives ([54066d0](https://github.com/archie-judd/agent-sandbox.nix/commit/54066d013545451f1bda2974497ef000c4ae2608))
* roDirs and roFiles read-only bind primitives ([5f8ce44](https://github.com/archie-judd/agent-sandbox.nix/commit/5f8ce44c26c0cfca299f9ac9c534dfe9d1be4773))


### Bug Fixes

* resolve resolv.conf on ubuntu ([cc2d145](https://github.com/archie-judd/agent-sandbox.nix/commit/cc2d1453b43269dc8c3869e4cee160cb7a1d385c))

## [1.0.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v0.1.1...v1.0.0) (2026-06-12)


### ⚠ BREAKING CHANGES

* Renamed extraEnv → env. Pure rename; semantics unchanged.

### Features

* rename API args and replace restrictNetwork with allowedDomains ([a2ee921](https://github.com/archie-judd/agent-sandbox.nix/commit/a2ee921d1ff2b158d8391fb5f22ca5774d5955f8))

## [0.1.1](https://github.com/archie-judd/agent-sandbox.nix/compare/v0.1.0...v0.1.1) (2026-06-10)


### Bug Fixes

* disable .git discovery when $HOME==$REPO_ROOT ([72ac65c](https://github.com/archie-judd/agent-sandbox.nix/commit/72ac65c108761af326e8403c40a736ae755a6b92))
