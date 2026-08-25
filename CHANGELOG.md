# Changelog

## [3.0.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.5.1...v3.0.0) (2026-08-25)


### ⚠ BREAKING CHANGES

* migrate to python

### Features

* migrate to python ([7695a5f](https://github.com/archie-judd/agent-sandbox.nix/commit/7695a5f6319275aa75a816787424f57fdd83bfae))

## [2.5.1](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.5.0...v2.5.1) (2026-08-23)


### Bug Fixes

* **darwin:** refuse binds nested inside another declared bind ([#87](https://github.com/archie-judd/agent-sandbox.nix/issues/87)) ([bd51a8b](https://github.com/archie-judd/agent-sandbox.nix/commit/bd51a8b030c796cbbdbab89c76fab79fe7c26e57))

## [2.5.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.4.1...v2.5.0) (2026-08-23)


### Features

* TODO.md ([8543e1e](https://github.com/archie-judd/agent-sandbox.nix/commit/8543e1eb37e446259cecc473f4f4ea9d8d0d4062))


### Bug Fixes

* **proxy:** disallow addresses resolving to loopback ([#86](https://github.com/archie-judd/agent-sandbox.nix/issues/86)) ([8265aa5](https://github.com/archie-judd/agent-sandbox.nix/commit/8265aa50592d5c3aa3559e7115702bcb8ac399a0))

## [2.4.1](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.4.0...v2.4.1) (2026-08-20)


### Bug Fixes

* protect the whole repo's gitdir from hook injection ([#79](https://github.com/archie-judd/agent-sandbox.nix/issues/79)) ([147d9af](https://github.com/archie-judd/agent-sandbox.nix/commit/147d9af8c8936c9937767f698d2774a5709ddbe7))

## [2.4.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.3.0...v2.4.0) (2026-08-20)


### Features

* allow launching from home ([#77](https://github.com/archie-judd/agent-sandbox.nix/issues/77)) ([d147b38](https://github.com/archie-judd/agent-sandbox.nix/commit/d147b38fe62a74f70036aa9203df3b7e8956375d))

## [2.3.0](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.2.1...v2.3.0) (2026-08-19)


### Features

* relicense under MIT ([1462f69](https://github.com/archie-judd/agent-sandbox.nix/commit/1462f69154f33efd6b809ed1a598dd405673128c))

## [2.2.1](https://github.com/archie-judd/agent-sandbox.nix/compare/v2.2.0...v2.2.1) (2026-07-13)


### Bug Fixes

* **Darwin:** fix whitespace string issue for allowedLocalPort seatbelt str ([637511e](https://github.com/archie-judd/agent-sandbox.nix/commit/637511e5fc7613804e6a4643eea9c73494e35c53))

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
