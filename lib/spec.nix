# Emits the JSON the launcher reads at startup. Keys are snake_case so the
# Python side needs no per-field name mapping.
{ pkgs, shared }:
{
  platform,
  outName,
  pkg,
  binName,
  sandboxPath,
  allowNix,
  allowUnixSockets,
  rwDirs,
  rwFiles,
  roDirs,
  roFiles,
  env,
  allowedLocalPorts,
  closurePathsFile,
  preEntryScript,
  allowedDomains,
  _proxyRedirects ? { },
}:
let
  emptyFile = pkgs.writeText "sandbox-empty" "";

  hostsFile = pkgs.writeText "sandbox-hosts" ''
    127.0.0.1 localhost
    ::1       localhost
  '';

  dependencies =
    if platform == "linux" then
      {
        git = "${pkgs.git}/bin/git";
        bwrap = "${pkgs.bubblewrap}/bin/bwrap";
        pasta = "${pkgs.passt}/bin/pasta";
        nft = "${pkgs.nftables}/bin/nft";
        ip = "${pkgs.iproute2}/bin/ip";
        env = "${pkgs.coreutils}/bin/env";
        python = "${pkgs.python3}/bin/python3";
      }
    else
      {
        git = "${pkgs.git}/bin/git";
      };

  # Omitted when allowedDomains is unset, so an unrestricted wrapper does
  # not carry the Go proxy in its closure.
  proxy =
    if allowedDomains == null then
      null
    else
      {
        binary = "${shared.sandboxProxy}/bin/sandbox-proxy";
        allowlist_file = "${shared.mkAllowlistFile allowedDomains}";
        redirects = _proxyRedirects;
      };

  platformFields =
    if platform == "linux" then
      {
        hosts_file = "${hostsFile}";
        empty_file = "${emptyFile}";
      }
    else
      { };

  spec = {
    # Read here rather than passed in, like the cacert paths below: it is a
    # constant of this source tree, not something a caller chooses. It is the
    # last release the tree descends from, so a wrapper built from an
    # unreleased or modified checkout reports that release rather than what it
    # actually contains.
    version = pkgs.lib.fileContents ../version.txt;
    platform = platform;
    out_name = outName;
    sandbox_path = sandboxPath;
    allow_nix = allowNix;
    allow_unix_sockets = allowUnixSockets;
    rw_dirs = rwDirs;
    rw_files = rwFiles;
    ro_dirs = roDirs;
    ro_files = roFiles;
    # Keys only. The values are runtime shell expressions, emitted as a
    # fragment the stub sources; they never reach Python.
    env_keys = builtins.attrNames env;
    allowed_local_ports = allowedLocalPorts;
    closure_paths_file = "${closurePathsFile}";
    cacert_dir = "${pkgs.cacert}/etc/ssl/certs";
    cacert_bundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    shell = "${shared.bashWrapper}/bin/bash";
    pre_entry_script = "${preEntryScript}";
    sandboxed_binary = "${pkg}/bin/${binName}";
    proxy = proxy;
    dependencies = dependencies;
  }
  // platformFields;
in
pkgs.writeText "${outName}-spec.json" (builtins.toJSON spec)
