# SPDX-License-Identifier: MIT
{ pkgs, olderRubySource }:
let
  native = import ./ruby18-sdk.nix {
    inherit pkgs olderRubySource;
    rubyPackage = import ./ruby184-runtime.nix { inherit pkgs olderRubySource; };
    rubyVersion = "1.8.4";
    runtimeName = "ruby184-bundler08";
    rubygemsVersion = "1.3.5";
    rubygemsHash = "sha256-Eg+xRFajOZGup2WwlQEPVm9lDPkU2drQ740SQe3Kv8U=";
    bundlerVersion = "0.8.1";
    bundlerHash = "sha256-jc2uxfV24e5YxeWypz3nv81SGDVnp/oW9jgWRlrJAe4=";
  };
  gemcutter = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/gemcutter-0.3.0.gem";
    hash = "sha256-M9KoAyPtFctNODq70vy8Ib8k588H8eDeSGDlIikBNR8=";
  };
  jsonPure = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/json_pure-1.8.6.gem";
    hash = "sha256-VdV1xK7JgklHOBGiVrPzp8EqlK0AgJMDL15fKOrNlO4=";
  };
  publisherGems =
    pkgs.runCommand "ruby184-bundler08-publisher-gems" { nativeBuildInputs = [ native.sdk ]; }
      ''
        export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
        gem install --local --no-rdoc --no-ri --install-dir "$out/gems" ${jsonPure} ${gemcutter}
      '';
  descriptor = pkgs.writeText "ruby184-bundler08-components.json" (
    builtins.toJSON {
      schemaVersion = 1;
      components = [
        {
          name = "ruby";
          version = "1.8.4";
          archive = native.ruby.src;
          library = native.ruby;
        }
        {
          name = "rubygems";
          version = "1.3.5";
          archive = native.rubygemsUpdate;
          library = native.rubygems;
        }
        {
          name = "bundler";
          version = "0.8.1";
          archive = native.bundlerGem;
          library = "${native.gems}/gems/gems/bundler-0.8.1";
        }
        {
          name = "json";
          version = "1.8.6";
          archive = native.jsonGem;
          library = "${native.gems}/gems/gems/json-1.8.6";
        }
        {
          name = "gemcutter";
          version = "0.3.0";
          archive = gemcutter;
          library = "${publisherGems}/gems/gems/gemcutter-0.3.0";
        }
        {
          name = "json_pure";
          version = "1.8.6";
          archive = jsonPure;
          library = "${publisherGems}/gems/gems/json_pure-1.8.6";
        }
      ];
    }
  );
  sdk =
    pkgs.runCommand "ruby184-bundler08-attested-sdk"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        version = "1.8.4";
        inherit (native.sdk) src;
        meta.mainProgram = "ruby";
      }
      ''
        mkdir -p "$out/bin" "$out/share/bundler-purifier"
        ln -s ${native.sdk}/bin/ruby "$out/bin/ruby"
        ln -s ${native.sdk}/bin/gem "$out/bin/gem"
        # Publication has its own genuine plugin/codec context. Cache/bundle
        # commands must not preload the publisher's json_pure before selection.
        makeWrapper ${native.sdk}/bin/gem "$out/bin/gem-publish" --suffix GEM_PATH : ${publisherGems}/gems
        ln -s ${descriptor} "$out/share/bundler-purifier/sdk-components.json"
      '';
in
native // { inherit sdk publisherGems; }
