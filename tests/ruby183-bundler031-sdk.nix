# SPDX-License-Identifier: MIT
{ pkgs, olderRubySource }:
let
  native = import ./ruby18-sdk.nix {
    inherit pkgs olderRubySource;
    rubyPackage = import ./ruby183-runtime.nix { inherit pkgs olderRubySource; };
    rubyVersion = "1.8.3";
    runtimeName = "ruby183-bundler031";
    rubygemsVersion = "1.0.1";
    rubygemsHash = "sha256-lO22YKAabsY6tw+mPFmE0UMat6Pg0f8WnxGWl8/wfac=";
    bundlerVersion = "0.3.1";
    bundlerHash = "sha256-Ru5Nqt2nlsHpQztFAV/0P2fqR8jPEObyJP9dhxJtMwI=";
    jsonVersion = "1.1.3";
    jsonHash = "sha256-N5hS1KiOaLWGBaP7rVxtfDKaTn6RsiGj1LB3xjzcZP4=";
  };
  descriptor = pkgs.writeText "ruby183-bundler031-components.json" (
    builtins.toJSON {
      schemaVersion = 1;
      components = [
        {
          name = "ruby";
          version = "1.8.3";
          archive = native.ruby.src;
          library = native.ruby;
        }
        {
          name = "rubygems";
          version = "1.0.1";
          archive = native.rubygemsUpdate;
          library = native.rubygems;
        }
        {
          name = "bundler";
          version = "0.3.1";
          archive = native.bundlerGem;
          library = "${native.gems}/gems/gems/bundler-0.3.1";
        }
        {
          name = "json";
          version = "1.1.3";
          archive = native.jsonGem;
          library = "${native.gems}/gems/gems/json-1.1.3";
        }
      ];
    }
  );
  sdk =
    pkgs.runCommand "ruby183-bundler031-attested-sdk"
      {
        version = "1.8.3";
        inherit (native.sdk) src;
        meta.mainProgram = "ruby";
      }
      ''
        mkdir -p "$out/bin" "$out/share/bundler-purifier"
        ln -s ${native.sdk}/bin/ruby "$out/bin/ruby"
        ln -s ${native.sdk}/bin/gem "$out/bin/gem"
        ln -s ${descriptor} "$out/share/bundler-purifier/sdk-components.json"
      '';
in
native // { inherit sdk; }
