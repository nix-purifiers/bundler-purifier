# SPDX-License-Identifier: MIT
# Ruby 1.8 predates bundled RubyGems: keep the interpreter, package codec,
# native manager and codec JSON extension as explicit immutable components.
{
  pkgs,
  olderRubySource,
  rubygemsVersion ? "2.6.14",
  rubygemsHash ? "sha256-7K7fd0g1Sec6M6Z3n0dpr/YZjH9Q3xJCVsyGnMkF/64=",
  bundlerVersion ? "1.17.3",
  bundlerHash ? "sha256-vEv3W1SLJ0UaqfRDsYxGpzndIq1596X5C0hTdqZ9w1I=",
  rubyPackage ? null,
  rubyVersion ? "1.8.7",
  runtimeName ? "ruby187",
}:
let
  old = import olderRubySource {
    system = "x86_64-linux";
    config = { };
  };
  ruby = if rubyPackage == null then old.ruby_1_8 else rubyPackage;
  gemId = pkgs.lib.replaceStrings [ "." ] [ "" ] rubygemsVersion;
  documentFlags =
    if pkgs.lib.versionOlder rubygemsVersion "2.0" then "--no-rdoc --no-ri" else "--no-document";
  rubygemsUpdate = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/rubygems-update-${rubygemsVersion}.gem";
    hash = rubygemsHash;
  };
  bundlerGem = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/bundler-${bundlerVersion}.gem";
    hash = bundlerHash;
  };
  jsonGem = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/json-1.8.6.gem";
    hash = "sha256-Za8nyphfcOsNCDqrD3VxLHcYcSIq8CHOUzutd707smI=";
  };
  rubygems =
    pkgs.runCommand "${runtimeName}-rubygems${gemId}" { nativeBuildInputs = [ pkgs.ruby ]; }
      ''
        export HOME=$TMPDIR LC_ALL=C
        ruby -rfileutils -rrubygems/package -e 'Gem::Package.new(ARGV[0]).extract_files("source")' ${rubygemsUpdate}
        cd source
        ${ruby}/bin/ruby setup.rb --prefix="$out" ${documentFlags}
      '';
  baseSdk =
    pkgs.runCommand "${runtimeName}-rubygems${gemId}-base" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${ruby}/bin/ruby "$out/bin/ruby" --prefix RUBYLIB : ${rubygems}/lib --set LC_ALL C \
          --set SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        makeWrapper "$out/bin/ruby" "$out/bin/gem" --add-flags ${rubygems}/bin/gem
      '';
  codecGems =
    pkgs.runCommand "${runtimeName}-bundler-${bundlerVersion}-json186"
      {
        nativeBuildInputs = [
          baseSdk
          (old.stdenv.cc or old.stdenv.gcc)
        ];
      }
      ''
        export HOME=$TMPDIR GEM_HOME=$out/gems GEM_PATH=$out/gems
        gem install --local ${documentFlags} --install-dir "$out/gems" ${bundlerGem} ${jsonGem}
        ruby -e 'require "rubygems"; gem "json", "= 1.8.6"; require "json"; abort unless RUBY_VERSION == "${rubyVersion}" && Gem::VERSION == "${rubygemsVersion}"; abort unless JSON::VERSION == "1.8.6" && JSON.parser == JSON::Ext::Parser; abort unless JSON.parse(%q({"answer":42}))["answer"] == 42'
      '';
  sdk =
    pkgs.runCommand "${runtimeName}-rubygems${gemId}-sdk"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        version = rubyVersion;
        src = ruby.src or (builtins.head ruby.srcs);
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
  inherit sdk rubygemsUpdate;
  gems = codecGems;
  compiler = (old.stdenv.cc or old.stdenv.gcc);
}
