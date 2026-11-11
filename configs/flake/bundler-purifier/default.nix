# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;

  # The flake's `packages` output is the derivations of the scope
  # `pkgs.bundler-purifier`, which the shared library's module publishes.
  purifier.scope = "bundler-purifier";

  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # `nix run github:nix-purifiers/bundler-purifier -- lock` locks the
  # project in the current directory.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.bundler-purifier.cli;
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              historicalRubySource = inputs.historical-ruby;
              olderRubySource = inputs.older-ruby;
              ruby2017Source = inputs.ruby-2017;
              ruby2018Source = inputs.ruby-2018;
              ruby2022Source = inputs.ruby-2022;
              ruby2025Source = inputs.ruby-2025;
              sharedTools = closure-lib.purifier.projectInputsTool;
              purifier = closure-lib.purifier;
              overlay = self.overlays.default;
              inherit (self.packages.${system}) cli;
              inherit (inputs) lobsters;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
