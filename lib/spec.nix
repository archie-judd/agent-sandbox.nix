# Emits the JSON the launcher reads at startup. The spec is data, not code: it
# carries store paths as values, so nothing here interpolates a path into a
# string that a shell later re-splits.
#
# Keys are snake_case rather than the camelCase used elsewhere in the Nix,
# because this is a wire format read by Python and a per-field name mapping on
# the other side is one more thing that can drift.
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
  # Linux only.
  hostsFile ? null,
  emptyFile ? null,
}:
let
  # Host binaries the launcher executes, as opposed to store paths bound into
  # or referenced from inside the sandbox. Small because the port replaces
  # dirname, readlink, realpath and find with in-process calls.
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
        # sandbox-exec and env live in /usr/bin, so they are constants in the
        # launcher rather than store paths here.
        git = "${pkgs.git}/bin/git";
      };

  # Omitted entirely when allowedDomains is unset, so an unrestricted wrapper's
  # spec names the Go proxy nowhere and does not carry it in its closure.
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
    # Unexpanded, exactly as written in the caller's Nix. They carry $VAR and ~
    # and the launcher expands them, so they are not paths yet.
    rw_dirs = rwDirs;
    rw_files = rwFiles;
    ro_dirs = roDirs;
    ro_files = roFiles;
    # Keys only. The values are documented as runtime shell expressions, so Nix
    # emits them as a fragment the stub sources and they never reach Python.
    env_keys = builtins.attrNames env;
    # null means every host-local TCP port; [] means none.
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
