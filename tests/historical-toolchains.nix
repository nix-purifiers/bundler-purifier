# SPDX-License-Identifier: MIT
{
  pkgs,
  historicalRubySource,
  build,
  cli,
}:
let
  old = import historicalRubySource { system = "x86_64-linux"; };
  project = build {
    src = ./fixtures/historical-ruby;
    ruby = old.ruby_2_5;
    nativeBuildInputs = [ old.stdenv.cc ];
    checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
  };
  bundlerGem = pkgs.fetchurl {
    url = "https://rubygems.org/downloads/bundler-1.17.3.gem";
    hash = "sha256-vEv3W1SLJ0UaqfRDsYxGpzndIq1596X5C0hTdqZ9w1I=";
  };
  nativeBundler =
    pkgs.runCommand "ruby25-bundler117-tools"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      }
      ''
        export HOME=$TMPDIR
        ${old.ruby_2_5}/bin/gem install --local --no-document --install-dir "$out/gems" ${bundlerGem}
        mkdir -p "$out/bin"
        makeWrapper ${old.ruby_2_5}/bin/ruby "$out/bin/bundle" \
          --add-flags "$out/gems/bin/bundle" --set GEM_PATH "$out/gems"
        ln -s ${old.ruby_2_5}/bin/ruby "$out/bin/ruby"
        ln -s ${old.ruby_2_5}/bin/gem "$out/bin/gem"
      '';
  selectedCli = cli.override {
    projectRuby = old.ruby_2_5;
    projectNativeBuildInputs = [ old.stdenv.cc ];
  };
in
{
  historical-ruby-tools = nativeBundler;
  historical-ruby-app = project.packages.app;
  historical-ruby-native-extension = project.tests;
  historical-ruby-cli = selectedCli;
  historical-ruby-release = project.release;
  historical-ruby-repository = project.release.projections.rubygems;
  historical-ruby-ordinary-consumer =
    pkgs.runCommand "ruby25-ordinary-projected-consumer"
      {
        nativeBuildInputs = [
          old.ruby_2_5
          old.stdenv.cc
        ];
      }
      ''
        export HOME=$TMPDIR GEM_HOME=$TMPDIR/gems
        export GEM_PATH=$GEM_HOME
        repository=${project.release.projections.rubygems}
        gem install --local --no-document "$repository"/gems/json-*.gem
        gem install --local --no-document "$repository"/gems/historical_greeting-*.gem
        ruby -rhistorical_greeting -e 'abort "wrong ABI" unless RUBY_VERSION == "2.5.8"; abort "wrong answer" unless HistoricalGreeting.answer == 42' 
        touch $out
      '';
}
