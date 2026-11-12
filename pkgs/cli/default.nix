# SPDX-License-Identifier: MIT
#
# The bundler-purifier command: bin/bundler-purifier on nixpkgs' Ruby,
# with the Nix library it realizes lockfiles with, the shared nix-purifiers
# library that library fetches with, and the nixpkgs that `install` and
# `push` build with. The lock run uses the Ruby the project asks for, and
# this Ruby when the project asks for none.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  ruby,
  # Keep the CLI on its helper Ruby while selecting a project SDK separately.
  projectRuby ? null,
  projectNativeBuildInputs ? [ ],
  python3,
  purifier,
  gitMinimal,
  nix-prefetch-git,
  path,
  version,
  # The shared nix-purifiers library as a locked flake reference, which
  # pkgs/default.nix reads from flake.lock.
  purifierRef ? null,
}:
let
  runtimeSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib-overlays/default
      ../build-bundler-project
      ./realize.nix
      ./tools
    ];
  };
  nixpkgsSource = builtins.path {
    inherit path;
    name = "source";
  };
  projectRubyExpression =
    if projectRuby == null then "" else (import ./sdk-expression.nix projectRuby).expression;
  nativeBuildInputsExpression = "[ ${
    lib.concatMapStringsSep " " (
      input: "(${(import ./sdk-expression.nix input).expression})"
    ) projectNativeBuildInputs
  } ]";
in
assert
  purifierRef != null
  || throw "bundler-purifier: the CLI needs the shared nix-purifiers library; pass purifierRef, as pkgs/default.nix does.";
stdenvNoCC.mkDerivation {
  pname = "bundler-purifier";
  inherit version;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 bundler-purifier "$out/libexec/bundler-purifier.rb"
    install -Dm644 bundle "$out/libexec/bundle-wrapper.rb"
    # The user's PATH comes first, for the user's nix. git serves Bundler's
    # git sources, and nix-prefetch-git hashes them for the lock.
    makeWrapper ${ruby}/bin/ruby "$out/bin/bundler-purifier" \
      --add-flags "$out/libexec/bundler-purifier.rb" \
      --set BUNDLER_PURIFIER_BUNDLE "$out/bin/bundle" \
      --set BUNDLER_PURIFIER_TOOLS ${./tools} \
      --set BUNDLER_PURIFIER_PROJECT_RUBY ${if projectRuby == null then "''" else projectRuby} \
      --set BUNDLER_PURIFIER_RUBY_EXPRESSION ${lib.escapeShellArg projectRubyExpression} \
      --set BUNDLER_PURIFIER_NATIVE_BUILD_INPUTS_EXPRESSION ${lib.escapeShellArg nativeBuildInputsExpression} \
      --prefix PYTHONPATH : ${purifier.projectInputsTool} \
      --set BUNDLER_PURIFIER_LIB ${runtimeSource}/pkgs/cli \
      --set BUNDLER_PURIFIER_SHARED_FLAKE ${lib.escapeShellArg purifierRef} \
      --set BUNDLER_PURIFIER_NIXPKGS ${nixpkgsSource} \
      --suffix PATH : ${
        lib.makeBinPath [
          gitMinimal
          python3
          nix-prefetch-git
        ]
      }
    makeWrapper ${ruby}/bin/ruby "$out/bin/bundle" \
      --add-flags "$out/libexec/bundle-wrapper.rb" \
      --set BUNDLER_PURIFIER_COMMAND "$out/libexec/bundler-purifier.rb" \
      --set BUNDLER_PURIFIER_BUNDLE "$out/bin/bundle" \
      --set BUNDLER_PURIFIER_TOOLS ${./tools} \
      --set BUNDLER_PURIFIER_PROJECT_RUBY ${if projectRuby == null then "''" else projectRuby} \
      --set BUNDLER_PURIFIER_RUBY_EXPRESSION ${lib.escapeShellArg projectRubyExpression} \
      --set BUNDLER_PURIFIER_NATIVE_BUILD_INPUTS_EXPRESSION ${lib.escapeShellArg nativeBuildInputsExpression} \
      --prefix PYTHONPATH : ${purifier.projectInputsTool} \
      --set BUNDLER_PURIFIER_LIB ${runtimeSource}/pkgs/cli \
      --set BUNDLER_PURIFIER_SHARED_FLAKE ${lib.escapeShellArg purifierRef} \
      --set BUNDLER_PURIFIER_NIXPKGS ${nixpkgsSource} \
      --suffix PATH : ${
        lib.makeBinPath [
          gitMinimal
          python3
          nix-prefetch-git
        ]
      }
    runHook postInstall
  '';
  passthru = { inherit ruby; };
  meta = {
    description = "Locks the gems a Bundler project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "bundler-purifier";
  };
}
