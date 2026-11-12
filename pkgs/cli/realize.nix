# SPDX-License-Identifier: MIT
#
# The builder's result for the project the CLI runs in, as the CLI builds
# it outside the flake: `bundler-purifier prefetch` keeps `gemCache` with an
# out-link and `devShell` as a shell profile, and `bundler-purifier
# publish` builds `release`.
{
  # The root of the project, as an absolute path in a string.
  root,
  # The purifier lockfile, as an absolute path in a string.
  lockFile,
  # Gemfile.lock, as an absolute path in a string.
  gemfileLock,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared nix-purifiers library as a locked flake reference.
  purifierFlake,
  integrationTools ? ./tools,
  rubyExpression ? "",
  nativeBuildInputsExpression ? "[ ]",
}:
let
  pkgs = import nixpkgs { };
  readLock = import ../../lib-overlays/default/read-lock.nix { inherit (pkgs) lib; };
  buildBundlerProject = pkgs.callPackage ../build-bundler-project {
    inherit readLock;
    integrationTools = /. + (toString integrationTools);
    inherit ((builtins.getFlake purifierFlake).lib) purifier;
  };
  src = /. + root;
  lockFile' = /. + lockFile;
  gemfileLock' = /. + gemfileLock;
  projectRuby =
    if rubyExpression == "" then
      { }
    else
      {
        ruby = import (builtins.toFile "bundler-project-ruby.nix" rubyExpression);
      };
  # The path sources outside the project are on disk beside it, at the
  # paths Gemfile.lock gives them.
  externalPaths =
    if (import ../../lib-overlays/default/native-lock-version.nix lockFile') == 4 then
      { }
    else
      builtins.listToAttrs (
        map
          (p: {
            name = p;
            value = /. + "${root}/${p}";
          })
          (readLock {
            inherit src;
            lockFile = lockFile';
            gemfileLock = gemfileLock';
          }).bundlerLock.externalPaths
      );
in
buildBundlerProject (
  projectRuby
  // {
    nativeBuildInputs = import (
      builtins.toFile "bundler-native-build-inputs.nix" nativeBuildInputsExpression
    );
    inherit src externalPaths;
    lockFile = lockFile';
    gemfileLock = gemfileLock';
  }
)
