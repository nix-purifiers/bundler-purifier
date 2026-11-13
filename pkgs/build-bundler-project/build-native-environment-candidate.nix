# SPDX-License-Identifier: MIT
# Standalone candidate generator while the v4 frontend integration is built.
# Output is validated regenerated native state, not an activation receipt.
{ pkgs }:
{
  sdk,
  resolution,
  archives,
  name ? "bundler-native-environment-candidate",
}:
let
  validation = import ../../lib-overlays/default/native-environment.nix {
    inherit (pkgs) lib;
  } resolution;
  record = pkgs.writeText "native-resolution.json" (builtins.toJSON resolution + "\n");
  archiveMap = pkgs.writeText "native-archives.json" (builtins.toJSON archives);
  closure = pkgs.closureInfo { rootPaths = [ sdk ]; };
in
assert validation.valid;
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.ruby
      pkgs.nix
    ];
  }
  ''
    export HOME=$TMPDIR NIX_CONFIG='experimental-features = nix-command'
    mkdir -p "$out"
    ruby ${../cli/tools}/native_environment_prepare.rb regenerate \
      ${record} ${sdk} ${archiveMap} "$out/project" ${closure}/store-paths \
      > "$out/native-resolution.json"
  ''
