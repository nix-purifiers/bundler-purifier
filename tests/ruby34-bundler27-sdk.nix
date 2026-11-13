# SPDX-License-Identifier: MIT
# Stock maintained Ruby and RubyGems with the original Bundler release.
{ pkgs }:
let
  ruby = pkgs.ruby_3_4;
  bundler = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/bundler-2.7.2.gem";
    sha256 = "1decaf9e2e1acb91b6586a2925c8f3f6da2334a82731a62ff2ded1b83c283871";
  };
in
pkgs.runCommand "ruby34-bundler272-stock-sdk"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    inherit (ruby) version;
    src = ruby.src;
    meta.mainProgram = "ruby";
  }
  ''
    export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
    ${ruby}/bin/ruby -rrubygems -e 'abort unless RUBY_VERSION == "3.4.11" && Gem::VERSION == "3.7.2"'
    ${ruby}/bin/gem install --local --no-document --install-dir "$out/gems" ${bundler}
    mkdir -p "$out/bin"
    makeWrapper ${ruby}/bin/ruby "$out/bin/ruby" --suffix GEM_PATH : "$out/gems" --prefix RUBYOPT ' ' -rrubygems
    makeWrapper ${ruby}/bin/gem "$out/bin/gem" --suffix GEM_PATH : "$out/gems" --prefix RUBYOPT ' ' -rrubygems
    makeWrapper "$out/bin/ruby" "$out/bin/bundle" --add-flags "$out/gems/bin/bundle _2.7.2_"
    "$out/bin/ruby" -e 'gem "bundler", "=2.7.2"; require "bundler"; puts [RUBY_VERSION, Gem::VERSION, Bundler::VERSION].join("/"); abort unless Bundler::VERSION == "2.7.2"'
  ''
