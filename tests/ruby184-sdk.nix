# SPDX-License-Identifier: MIT
{ pkgs, olderRubySource }:
let
  native = import ./ruby18-sdk.nix {
    inherit pkgs olderRubySource;
    rubyPackage = import ./ruby184-runtime.nix { inherit pkgs olderRubySource; };
    rubyVersion = "1.8.4";
    runtimeName = "ruby184";
    rubygemsVersion = "1.3.5";
    rubygemsHash = "sha256-Eg+xRFajOZGup2WwlQEPVm9lDPkU2drQ740SQe3Kv8U=";
    bundlerVersion = "0.9.9";
    bundlerHash = "sha256-A4vNaw2V7Muoyu3Pa8+sGRiON6CabdjctMhywiL6T0Q=";
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
    pkgs.runCommand "ruby184-native-gemcutter030" { nativeBuildInputs = [ native.sdk ]; }
      ''
        export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
        gem install --local --no-rdoc --no-ri --install-dir "$out/gems" ${jsonPure} ${gemcutter}
        ruby -e 'require "rubygems";abort unless Gem::VERSION=="1.3.5";abort unless Gem.source_index.find_name("gemcutter","=0.3.0").size==1 && Gem.source_index.find_name("json_pure","=1.8.6").size==1'
      '';
  sdk =
    pkgs.runCommand "ruby184-gems135-bundler099-gemcutter030-sdk"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        inherit (native.sdk) src version;
        meta.mainProgram = "ruby";
      }
      ''
        mkdir -p "$out/bin"
        # The native plugin belongs to gem commands. Ruby and Bundler retain
        # their original codec selection and immutable SDK components.
        ln -s ${native.sdk}/bin/ruby "$out/bin/ruby"
        ln -s ${native.sdk}/bin/bundle "$out/bin/bundle"
        makeWrapper ${native.sdk}/bin/gem "$out/bin/gem" --suffix GEM_PATH : ${publisherGems}/gems
        "$out/bin/ruby" -e 'require "rubygems";gem "bundler","=0.9.9";require "bundler";gem "json","=1.8.6";require "json";abort unless Gem::VERSION=="1.3.5" && JSON.parser==JSON::Ext::Parser;abort if defined?(RUBY_PATCHLEVEL) || defined?(RbConfig)'
        "$out/bin/gem" help push > "$TMPDIR/push-help"
        grep -q 'Push a gem up to Gemcutter' "$TMPDIR/push-help"
      '';
in
native // { inherit sdk publisherGems; }
