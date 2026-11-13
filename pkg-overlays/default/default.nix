# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute, the scope
# `pkgs.bundler-purifier` of pkgs/: the builder `buildBundlerProject`
# (pkgs/build-bundler-project/default.nix) and the command `cli`. A consumer
# that lists this flake in `projects` holds it as `bundler-purifier/default`,
# which its package sets apply by default; the flake also exports it as
# `overlays.default`.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bundler-purifier";
}
