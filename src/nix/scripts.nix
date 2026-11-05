{ pkgs }:
{
  preEntryScript = pkgs.writeShellScript "pre-entry-script" (builtins.readFile ../pre-entry-script.sh);
}
