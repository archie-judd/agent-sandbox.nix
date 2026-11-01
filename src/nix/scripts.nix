{ pkgs }:
{
  preEntryScript = pkgs.writeShellScript "pre-entry-script" (builtins.readFile ../pre-entry-script.sh);

  jobControlScript = pkgs.writeShellScript "job-control-script" (
    builtins.readFile ../job-control-script.sh
  );
}
