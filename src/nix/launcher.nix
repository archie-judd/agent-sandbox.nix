{ pkgs }:
let
  # __pycache__ would otherwise change the store hash from one build to the
  # next depending on whether anything had imported the package in place.
  launcherSource = builtins.filterSource (path: type: baseNameOf path != "__pycache__") ../launcher;
in
pkgs.runCommand "agent-sandbox-launcher" { } ''
  mkdir -p $out
  cp -r ${launcherSource} $out/launcher
''
