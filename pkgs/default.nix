# SPDX-License-Identifier: MIT
{ callPackage, lib, ... }:
let
  # The shared nix-purifiers library as this flake pins it, as a locked flake
  # reference: the CLI builds outside the flake and loads the library's
  # published `lib` with builtins.getFlake.
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  pinned = lock.nodes.${lock.nodes.root.inputs.purifier}.locked;
  escape = builtins.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ];
  purifierRef = "github:${pinned.owner}/${pinned.repo}/${pinned.rev}?narHash=${escape pinned.narHash}";
in
{
  # The builder (nix/lib/build-bundler-project.nix), with the shared
  # library's `purifier` namespace and readLock from this flake's library.
  buildBundlerProject = callPackage ../nix/lib/build-bundler-project.nix {
    inherit (lib) purifier;
    inherit (lib.bundler-purifier) readLock;
  };

  # The bundler-purifier command.
  cli = callPackage ./cli {
    version = import ./version.nix;
    inherit purifierRef;
    inherit (lib) purifier;
  };
}
