# SPDX-License-Identifier: MIT
# Keep the stock interpreter and RubyGems; select a genuine older Bundler.
{ pkgs, historicalRubySource }:
let
  old = import historicalRubySource { system = "x86_64-linux"; };
  ruby = old.ruby_2_5;
  bundler = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/bundler-2.0.2.gem";
    hash = "sha256-TCrh/OigcrgyrHGI8eUwp8/48KadipYhsy0UB9sAotA=";
  };
  sdk =
    pkgs.runCommand "ruby25-bundler202-stock-sdk"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        inherit (ruby) src version;
        meta.mainProgram = "ruby";
      }
      ''
        export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
        ${ruby}/bin/ruby -rrubygems -e 'abort unless RUBY_VERSION=="2.5.8" && RUBY_PATCHLEVEL==224 && Gem::VERSION=="3.1.2"'
        ${ruby}/bin/gem install --local --no-document --install-dir "$out/gems" ${bundler}
        mkdir -p "$out/bin"
        makeWrapper ${ruby}/bin/ruby "$out/bin/ruby" --suffix GEM_PATH : "$out/gems" --prefix RUBYOPT ' ' -rrubygems
        makeWrapper ${ruby}/bin/gem "$out/bin/gem" --suffix GEM_PATH : "$out/gems" --prefix RUBYOPT ' ' -rrubygems
        makeWrapper "$out/bin/ruby" "$out/bin/bundle" --add-flags "$out/gems/bin/bundle _2.0.2_"
        "$out/bin/ruby" -e 'gem "bundler","=2.0.2";require "bundler";require "json";abort unless Bundler::VERSION=="2.0.2" && JSON::VERSION=="2.1.0" && JSON.parser==JSON::Ext::Parser'
      '';
in
{
  inherit sdk;
  compiler = old.stdenv.cc;
}
