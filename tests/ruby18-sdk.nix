# SPDX-License-Identifier: MIT
# Ruby 1.8 predates bundled RubyGems: keep the interpreter, package codec,
# native manager and codec JSON extension as explicit immutable components.
{ pkgs, olderRubySource }:
let
  old = import olderRubySource {
    system = "x86_64-linux";
    config = { };
  };
  rubygemsUpdate = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/rubygems-update-2.6.14.gem";
    sha256 = "1bpz0p4rr1ncar115pshgy61kxmgd53ryxx66cxffj9m91vxzbpc";
  };
  bundlerGem = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/bundler-1.17.3.gem";
    hash = "sha256-vEv3W1SLJ0UaqfRDsYxGpzndIq1596X5C0hTdqZ9w1I=";
  };
  jsonGem = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/json-1.8.6.gem";
    hash = "sha256-Za8nyphfcOsNCDqrD3VxLHcYcSIq8CHOUzutd707smI=";
  };
  rubygems = pkgs.runCommand "ruby187-rubygems2614" { nativeBuildInputs = [ pkgs.ruby ]; } ''
    export HOME=$TMPDIR LC_ALL=C
    ruby -rfileutils -rrubygems/package -e 'Gem::Package.new(ARGV[0]).extract_files("source")' ${rubygemsUpdate}
    cd source
    ${old.ruby_1_8}/bin/ruby setup.rb --prefix="$out" --no-document
  '';
  baseSdk =
    pkgs.runCommand "ruby187-rubygems2614-base" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${old.ruby_1_8}/bin/ruby "$out/bin/ruby" --prefix RUBYLIB : ${rubygems}/lib --set LC_ALL C \
          --set SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        makeWrapper "$out/bin/ruby" "$out/bin/gem" --add-flags ${rubygems}/bin/gem
      '';
  codecGems =
    pkgs.runCommand "ruby187-bundler117-json186"
      {
        nativeBuildInputs = [
          baseSdk
          old.stdenv.gcc
        ];
      }
      ''
        export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
        gem install --local --no-document --install-dir "$out/gems" ${bundlerGem} ${jsonGem}
        ruby -e 'require "rubygems"; require "json"; abort unless RUBY_VERSION == "1.8.7"; abort unless JSON.parser == JSON::Ext::Parser; abort unless JSON.parse(%q({"answer":42}))["answer"] == 42'
      '';
  sdk =
    pkgs.runCommand "ruby187-rubygems2614-sdk"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        version = "1.8.7";
        src = old.ruby_1_8.src;
        meta.mainProgram = "ruby";
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${baseSdk}/bin/ruby "$out/bin/ruby" \
          --suffix GEM_PATH : ${codecGems}/gems --prefix RUBYOPT ' ' -rrubygems
        makeWrapper "$out/bin/ruby" "$out/bin/gem" --add-flags ${rubygems}/bin/gem
        makeWrapper "$out/bin/ruby" "$out/bin/bundle" --add-flags ${codecGems}/gems/bin/bundle
      '';
in
{
  inherit sdk;
  compiler = old.stdenv.gcc;
}
