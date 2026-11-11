# SPDX-License-Identifier: MIT
#
# The checks: sandboxed builds of the fixtures under fixtures/, from their
# committed lockfiles, and a run of what each build produced; the
# conformance checks of the nix-purifiers contract that the sandbox can
# run; the unit tests; and Lobsters, a real-world project. Each fixture's
# lockfile is written by `bundler-purifier lock`. The conformance checks
# that need the network or Nix itself (relock, rebuild, offline) run in CI
# as jobs of the same names, from tests/ci.
{
  pkgs,
  # The flake's default package overlay, which adds the scope
  # bundler-purifier with buildBundlerProject.
  overlay,
  cli,
  sharedTools,
  purifier,
  # The source of Lobsters at its pinned commit (tests/dependencies).
  lobsters,
  historicalRubySource,
  olderRubySource,
  ruby2017Source,
  ruby2018Source,
  ruby2022Source,
  ruby2025Source,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a user's package does: through
  # buildBundlerProject of a package set the overlay applies to.
  build = (pkgs.extend overlay).bundler-purifier.buildBundlerProject;

  # Runs `bundle exec ruby main.rb` in the project of a build and checks
  # its output.
  runsMain =
    name: project: expected:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ project.packages.bundle ];
      }
      ''
        export HOME="$TMPDIR"
        cd ${project.packages.app}/${project.packages.app.projectDir}
        output=$(bundle exec ruby main.rb)
        echo "$output"
        case "$output" in
          *${lib.escapeShellArg expected}*) ;;
          *) echo "${name}: expected ${expected}" >&2; exit 1 ;;
        esac
        touch "$out"
      '';

  app = build {
    src = ./fixtures/app;
    name = "fixture-app";
    externalPaths."../shared-gem" = ./fixtures/shared-gem;
  };

  library = build {
    src = ./fixtures/library;
    name = "fixture-library";
  };

  submodules = build {
    src = ./fixtures/submodules;
    name = "fixture-submodules";
  };

  # A fixture kept external: its source holds only Bundler's files and
  # main.rb, and the flake that builds it keeps the purifier lockfile
  # outside it.
  external = build {
    src = ./fixtures/external/project;
    name = "fixture-external";
    lockFile = ./fixtures/external/bundler-purifier.lock.json;
  };

  # The same project with its Gemfile.lock replaced from outside `src`: the
  # replacement pins rainbow 3.0.0, and its purifier lockfile was written
  # by `bundler-purifier --tool-lockfile ... lock`.
  externalReplaced = build {
    src = ./fixtures/external/project;
    name = "fixture-external-replaced";
    lockFile = ./fixtures/external/replaced/bundler-purifier.lock.json;
    gemfileLock = ./fixtures/external/replaced/Gemfile.lock;
  };

  # A real-world project: Lobsters, built from its own Gemfile.lock and the
  # lockfile that `bundler-purifier lock` wrote for it, which lives here
  # rather than in the Lobsters tree.
  lobstersBuild = build {
    src = lobsters;
    lockFile = ./real/lobsters/bundler-purifier.lock.json;
    name = "lobsters";
    # ruby-vips opens libvips through FFI when the app loads.
    buildInputs = [ pkgs.vips ];
  };

  # The library fixture with one of its lockfiles damaged, for the
  # conformance checks of a lockfile that must fail.
  libraryLock = builtins.fromJSON (builtins.readFile ./fixtures/library/bundler-purifier.lock.json);
  # The contentHash `bundler-purifier lock` would write for a lock.
  withContentHash =
    lock:
    lock
    // {
      contentHash = builtins.convertHash {
        hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    };
  damaged = {
    bundlerMismatch = {
      lockFile = builtins.toFile "bundler-purifier.lock.json" (
        builtins.toJSON (withContentHash (libraryLock // { bundlerVersion = "1.3.6"; }))
      );
    };
    # A lock made from another Gemfile.lock: its definition hash differs,
    # with a contentHash that matches it. The CLI side changes the copied
    # Gemfile.lock instead.
    stale = {
      lockFile = builtins.toFile "bundler-purifier.lock.json" (
        builtins.toJSON (
          withContentHash (libraryLock // { definitionHash = "sha256-${lib.fixedWidthString 43 "A" ""}="; })
        )
      );
      changeProject = "echo >> project/Gemfile.lock";
    };
    # A hash changed by hand.
    tampered = {
      lockFile = builtins.toFile "bundler-purifier.lock.json" (
        builtins.toJSON (libraryLock // { bundlerHash = "sha256-${lib.fixedWidthString 43 "A" ""}="; })
      );
    };
    # A gem's hash removed, with a contentHash that matches what is left.
    missing = {
      lockFile = builtins.toFile "bundler-purifier.lock.json" (
        builtins.toJSON (withContentHash (libraryLock // { gemHashes = { }; }))
      );
    };
    # The lockfile cut short.
    malformed = {
      lockFile = builtins.toFile "bundler-purifier.lock.json" (
        builtins.substring 0 120 (builtins.readFile ./fixtures/library/bundler-purifier.lock.json)
      );
    };
  };

  # A conformance check of a damaged lockfile: Nix fails to evaluate the
  # build, and the CLI fails before it builds anything, with a message that
  # names `expected`.
  failsWith =
    kind: expected:
    let
      args = damaged.${kind};
      evaluated =
        builtins.tryEval
          (build {
            src = ./fixtures/library;
            inherit (args) lockFile;
          }).packages.app.drvPath;
    in
    assert
      !evaluated.success || throw "conformance-${kind}: Nix evaluated a build from a ${kind} lockfile";
    pkgs.runCommand "conformance-${kind}"
      {
        nativeBuildInputs = [ cli ];
      }
      ''
        export HOME="$TMPDIR" LC_ALL=C.UTF-8
        cp -r ${./fixtures/library} project
        chmod -R u+w project
        ${
          if args ? changeProject then
            args.changeProject
          else
            "cp ${args.lockFile} project/bundler-purifier.lock.json"
        }
        cd project
        if output=$(bundler-purifier prefetch 2>&1); then
          echo "conformance-${kind}: the CLI accepted a ${kind} lockfile" >&2
          exit 1
        fi
        echo "$output"
        case "$output" in
          *${lib.escapeShellArg expected}*) ;;
          *) echo "conformance-${kind}: expected the message to name: ${expected}" >&2; exit 1 ;;
        esac
        touch "$out"
      '';
in
{
  composition-default-json =
    pkgs.runCommand "bundler-default-json-composition"
      {
        nativeBuildInputs = [ pkgs.ruby ];
        BUNDLER_PURIFIER_RUBYGEMS_TOOL = "${sharedTools}/rubygems_repository.rb";
      }
      ''
            mkdir -p tools tests
            cp -r ${../tools}/. tools/
            cp ${./native-json.rb} tests/native-json.rb
            export HOME="$TMPDIR"
            for library in json psych pathname stringio; do
          ruby tests/native-json.rb "$library"
        done
            touch "$out"
      '';

  composition-native = import ./composition.nix {
    inherit pkgs build;
    producer = app;
    inherit purifier;
  };
  inherit cli;

  conformance-bundler-mismatch = failsWith "bundlerMismatch" "bundlerVersion conflicts with native BUNDLED WITH";
  conformance-stale = failsWith "stale" "run bundler-purifier lock";
  conformance-tampered = failsWith "tampered" "was changed by hand";
  conformance-missing = failsWith "missing" "run bundler-purifier lock";
  conformance-malformed = failsWith "malformed" "run bundler-purifier lock --force";

  # The fixture kept external builds from the purifier lockfile outside its
  # source, and with its Gemfile.lock replaced from outside too.
  conformance-external =
    pkgs.runCommand "conformance-external"
      {
        committed =
          runsMain "conformance-external-committed" external
            "external purified with rainbow 3.1.1";
        replaced =
          runsMain "conformance-external-replaced" externalReplaced
            "external purified with rainbow 3.0.0";
      }
      ''
        touch "$out"
      '';

  # The unit tests of the lock run's logic (tests/unit).
  unit =
    pkgs.runCommand "bundler-purifier-unit-tests"
      {
        nativeBuildInputs = [ pkgs.ruby ];
      }
      ''
        export HOME="$TMPDIR" LC_ALL=C.UTF-8
        ruby ${./unit/bundler_purifier_test.rb} ${../bin/bundler-purifier}
        touch "$out"
      '';

  # The app's bundle compiles msgpack, takes nokogiri precompiled for this
  # platform, rainbow from its git source, helper from a path inside the
  # project and shared from a path outside it, all without a network.
  fixture-app = runsMain "fixture-app-runs" app "app purified";

  # The gem file of the path gem inside the app.
  fixture-app-helper-gem =
    pkgs.runCommand "fixture-app-helper-gem"
      {
        nativeBuildInputs = [ app.packages.app.ruby ];
        gem = app.packages.helper.gemFile;
      }
      ''
        export HOME="$TMPDIR"
        gem specification "$gem" version | grep -q 1.0.0
        touch "$out"
      '';

  # The library's test run, its `tests`.
  fixture-library-tests = library.tests;

  # The library's gem file and installed app as they are, which CI's
  # conformance-rebuild and publish build again and compare.
  fixture-library-gem = library.packages.greeting;
  fixture-library-app = library.packages.app;

  # The library's package is the gem file its gemspec builds, with the
  # files `git ls-files` lists, and it is the release.
  fixture-library =
    pkgs.runCommand "fixture-library-gem"
      {
        nativeBuildInputs = [ library.packages.app.ruby ];
        gem = library.packages.greeting.gemFile;
        release = library.release;
      }
      ''
        export HOME="$TMPDIR"
        gem specification "$gem" version | grep -q 0.2.0
        files=$(gem specification "$gem" files)
        echo "$files"
        echo "$files" | grep -q lib/greeting.rb
        echo "$files" | grep -q lib/greeting/version.rb
        echo "$files" | grep -q exe/greet
        test -f "$release/greeting-0.2.0.gem"
        touch "$out"
      '';

  # The executable that the library's gemspec declares, which the lock
  # names, runs with the library's bundle.
  fixture-library-executable =
    pkgs.runCommand "fixture-library-executable"
      {
        nativeBuildInputs = [ library.executables.greet ];
      }
      ''
        export HOME="$TMPDIR"
        output=$(greet nix)
        echo "$output"
        case "$output" in
          *"hello, nix"*) ;;
          *) echo "unexpected output from greet" >&2; exit 1 ;;
        esac
        touch "$out"
      '';

  # The shell for working on Lobsters, which CI's walkthrough uses.
  real-lobsters-shell = lobstersBuild.devShell;

  # Lobsters installs its bundle of 180 gems offline in the sandbox, with
  # Ruby 4.0 and Bundler 4.0, and Rails loads with it.
  real-lobsters =
    pkgs.runCommand "real-lobsters"
      {
        nativeBuildInputs = [ lobstersBuild.packages.bundle ];
      }
      ''
        export HOME="$TMPDIR"
        cd ${lobstersBuild.packages.app}
        bundle exec rails --version | tee "$out"
        grep -q '^Rails ' "$out"
        # A gem that opens its library at run time finds it.
        bundle exec ruby -e 'require "vips"; puts "libvips #{Vips.version_string}"' | tee -a "$out"
        grep -q '^libvips ' "$out"
      '';
}
# sassc comes from a git source whose libsass is a submodule; its native
# extension compiles libsass from the submodule's checkout. Not on darwin:
# libsass has two test directories whose names differ only in Unicode
# normalization, which APFS takes for one name, so a checkout there lacks
# two files and never matches the locked hash.
// lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isDarwin) {
  fixture-submodules = runsMain "fixture-submodules-runs" submodules ".purified{width:3px}";
}

// lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
  import ./historical-toolchains.nix {
    inherit
      pkgs
      historicalRubySource
      build
      cli
      ;
  }
)

// lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
  let
    native = import ./ruby18-sdk.nix { inherit pkgs olderRubySource; };
    native116 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      bundlerVersion = "1.16.6";
      bundlerHash = "sha256-B7RF6pjTkDLSVwFqlxoMCUdVbup4Vc5klw2iqC4JhgU=";
    };
    native110 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      bundlerVersion = "1.10.6";
      bundlerHash = "sha256-+ykz0SMEzsddrHW5OhywRdoCaykebGWwl0TOuQB2n+4=";
    };
    native136 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      bundlerVersion = "1.3.6";
      bundlerHash = "sha256-K6aoziNnsuOCuWkeb7qAidtAu0u4gFTe0a3yYWy6El8=";
    };
    native10 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubygemsVersion = "1.8.30";
      rubygemsHash = "sha256-6fXjBSxduNG/d8KmUEftW9mXe3PA7ZCMQGYQIQWRhUw=";
      bundlerVersion = "1.0.22";
      bundlerHash = "sha256-wOcoWqMSJAdHs6Ox3ll4agSVCkJA7GyWudDv3VjU7EM=";
    };
    native09 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubygemsVersion = "1.8.30";
      rubygemsHash = "sha256-6fXjBSxduNG/d8KmUEftW9mXe3PA7ZCMQGYQIQWRhUw=";
      bundlerVersion = "0.9.26";
      bundlerHash = "sha256-z6SzCdAFdRtD3P7HtWmCn6o44bXjMnR6d+uX/3wca0E=";
    };
    native19 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubyPackage =
        (import olderRubySource {
          system = "x86_64-linux";
          config = { };
        }).ruby_1_9;
      rubyVersion = "1.9.3";
      runtimeName = "ruby193";
    };
    native20 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubyPackage =
        (import olderRubySource {
          system = "x86_64-linux";
          config = { };
        }).ruby_2_0;
      rubyVersion = "2.0.0";
      runtimeName = "ruby200";
    };
    project20 = build {
      src = ./fixtures/ruby20;
      ruby = native20.sdk;
      nativeBuildInputs = [ native20.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    native21 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubyPackage =
        (import olderRubySource {
          system = "x86_64-linux";
          config = { };
        }).ruby_2_1;
      rubyVersion = "2.1.3";
      runtimeName = "ruby213";
    };
    project21 = build {
      src = ./fixtures/ruby21;
      ruby = native21.sdk;
      nativeBuildInputs = [ native21.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    ruby2022 = import ruby2022Source {
      system = "x86_64-linux";
      config = { };
    };
    ruby2025 = import ruby2025Source {
      system = "x86_64-linux";
      config.permittedInsecurePackages = [
        "ruby-3.1.7"
        "ruby-3.2.8"
        "ruby-3.3.8"
      ];
    };
    project30 = build {
      src = ./fixtures/ruby30;
      ruby = ruby2022.ruby_3_0;
      nativeBuildInputs = [ ruby2022.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project31 = build {
      src = ./fixtures/ruby31;
      ruby = ruby2025.ruby_3_1;
      nativeBuildInputs = [ ruby2025.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project32 = build {
      src = ./fixtures/ruby32;
      ruby = ruby2025.ruby_3_2;
      nativeBuildInputs = [ ruby2025.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project33 = build {
      src = ./fixtures/ruby33;
      ruby = ruby2025.ruby_3_3;
      nativeBuildInputs = [ ruby2025.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    rubies2017 = import ruby2017Source {
      system = "x86_64-linux";
      config = { };
    };
    rubies2018 = import ruby2018Source {
      system = "x86_64-linux";
      config = { };
    };
    native22 = import ./ruby18-sdk.nix {
      inherit pkgs;
      olderRubySource = ruby2017Source;
      rubyPackage = rubies2017.ruby_2_2;
      rubyVersion = "2.2.7";
      runtimeName = "ruby227";
    };
    rubygems276Update = pkgs.fetchurl {
      url = "https://rubygems.org/downloads/rubygems-update-2.7.6.gem";
      hash = "sha256-7l7yGayX9UmcMeYHHq5CTDJlYg7OM7XMZuCfow8iCGo=";
    };
    project22 = build {
      src = ./fixtures/ruby22;
      ruby = native22.sdk;
      nativeBuildInputs = [ native22.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project23 = build {
      src = ./fixtures/ruby23;
      ruby = rubies2018.ruby_2_3;
      nativeBuildInputs = [ rubies2018.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    native23Bundler20 = import ./ruby23-bundler20-sdk.nix { inherit pkgs ruby2018Source; };
    project23Bundler20 = build {
      src = ./fixtures/ruby23-bundler20;
      ruby = native23Bundler20.sdk;
      nativeBuildInputs = [ native23Bundler20.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project24 = build {
      src = ./fixtures/ruby24;
      ruby = rubies2018.ruby_2_4;
      nativeBuildInputs = [ rubies2018.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    # Keep RubyGems and Bundler from the official preview together. Nixpkgs'
    # stable RubyGems replacement lacks APIs used by the bundled beta.
    native41 =
      (pkgs.mkRuby {
        version = pkgs.mkRubyVersion "4" "1" "0" "preview1";
        hash = "sha256-+1MLuI6Q3jrpHBMQonrgkOa9mJuHJt5Q7xKokKhbiO8=";
      }).override
        {
          rubygemsSupport = false;
          yjitSupport = false;
          jitSupport = false;
          docSupport = false;
        };
    project41 = build {
      src = ./fixtures/ruby41;
      ruby = native41;
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    rubygems312Update = pkgs.fetchurl {
      url = "https://rubygems.org/downloads/rubygems-update-3.1.2.gem";
      hash = "sha256-e/5OXidBkeVtqNEnx53xDZEg/rhlDkutKSOPSydzpmE=";
    };
    historicalRubies = import historicalRubySource {
      system = "x86_64-linux";
      config = { };
    };
    native25 = import ./ruby25-sdk.nix { inherit pkgs historicalRubySource; };
    project25 = build {
      src = ./fixtures/ruby25;
      ruby = native25.sdk;
      nativeBuildInputs = [ native25.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project26 = build {
      src = ./fixtures/ruby26;
      ruby = historicalRubies.ruby_2_6;
      nativeBuildInputs = [ historicalRubies.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project27 = build {
      src = ./fixtures/ruby27;
      ruby = historicalRubies.ruby_2_7;
      nativeBuildInputs = [ historicalRubies.stdenv.cc ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    runtime191 = import ./early-ruby-runtime.nix {
      inherit pkgs olderRubySource;
      rubyVersion = "1.9.1";
      patchlevel = 431;
      sourceHash = "sha256-65GbkcT45/BACuNKu6z5O8qHAV9US5zx87TGEoNyonE=";
      legacySSL = true;
    };
    native191 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubyPackage = runtime191;
      rubyVersion = "1.9.1";
      runtimeName = "ruby191-native";
      disableBuiltinGemPrelude = true;
    };
    project191 = build {
      src = ./fixtures/ruby191;
      ruby = native191.sdk;
      nativeBuildInputs = [ native191.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    runtime192 = import ./early-ruby-runtime.nix {
      inherit pkgs olderRubySource;
      rubyVersion = "1.9.2";
      patchlevel = 330;
      sourceHash = "sha256-I+9F/a7MXWx7Tp4tUbI4F/xqqCJaIPEj9/qYdg6LXKk=";
      legacySSL = false;
    };
    native192 = import ./ruby18-sdk.nix {
      inherit pkgs olderRubySource;
      rubyPackage = runtime192;
      rubyVersion = "1.9.2";
      runtimeName = "ruby192-native";
    };
    project192 = build {
      src = ./fixtures/ruby192;
      ruby = native192.sdk;
      nativeBuildInputs = [ native192.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project40 = build {
      src = ./fixtures/ruby40;
      ruby = pkgs.ruby_4_0;
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project19 = build {
      src = ./fixtures/ruby19;
      ruby = native19.sdk;
      nativeBuildInputs = [ native19.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
    project = build {
      src = ./fixtures/ruby18;
      ruby = native.sdk;
      nativeBuildInputs = [ native.compiler ];
      checkCommand = "bundle exec ruby -Ilib exe/historical-greeting";
    };
  in
  {
    ruby18-sdk = native.sdk;
    ruby20-sdk = native20.sdk;
    ruby20-native-extension = project20.tests;
    ruby20-app = project20.packages.app;
    ruby20-repository = project20.release.projections.rubygems;
    ruby20-input-composition =
      pkgs.runCommand "ruby200-bundler117-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native20.sdk} ${project20.release.projections.rubygems} ${project20.release.projections.rubygems.catalog} 2.0.0
          ${native20.sdk}/bin/ruby ${./ruby19-method-hooks.rb} ${../tools/rubygems_inputs.rb}
          touch $out
        '';
    ruby20-cli = cli.override {
      projectRuby = native20.sdk;
      projectNativeBuildInputs = [ native20.compiler ];
    };
    ruby21-sdk = native21.sdk;
    ruby21-native-extension = project21.tests;
    ruby21-app = project21.packages.app;
    ruby21-repository = project21.release.projections.rubygems;
    ruby21-input-composition =
      pkgs.runCommand "ruby210-bundler117-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native21.sdk} ${project21.release.projections.rubygems} ${project21.release.projections.rubygems.catalog} 2.1.3
          ${native21.sdk}/bin/ruby ${./ruby19-method-hooks.rb} ${../tools/rubygems_inputs.rb}
          touch $out
        '';
    ruby21-cli = cli.override {
      projectRuby = native21.sdk;
      projectNativeBuildInputs = [ native21.compiler ];
    };
    ruby30-sdk = ruby2022.ruby_3_0;
    ruby30-native-extension = project30.tests;
    ruby30-app = project30.packages.app;
    ruby30-repository = project30.release.projections.rubygems;
    ruby30-cli = cli.override {
      projectRuby = ruby2022.ruby_3_0;
      projectNativeBuildInputs = [ ruby2022.stdenv.cc ];
    };
    ruby30-input-composition =
      pkgs.runCommand "ruby30-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${ruby2022.ruby_3_0} ${project30.release.projections.rubygems} ${project30.release.projections.rubygems.catalog} 3.0.5 2.2.33
          touch "$out"
        '';
    ruby31-sdk = ruby2025.ruby_3_1;
    ruby31-native-extension = project31.tests;
    ruby31-app = project31.packages.app;
    ruby31-repository = project31.release.projections.rubygems;
    ruby31-cli = cli.override {
      projectRuby = ruby2025.ruby_3_1;
      projectNativeBuildInputs = [ ruby2025.stdenv.cc ];
    };
    ruby31-input-composition =
      pkgs.runCommand "ruby31-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${ruby2025.ruby_3_1} ${project31.release.projections.rubygems} ${project31.release.projections.rubygems.catalog} 3.1.7 2.3.27
          touch "$out"
        '';
    ruby32-sdk = ruby2025.ruby_3_2;
    ruby32-native-extension = project32.tests;
    ruby32-app = project32.packages.app;
    ruby32-repository = project32.release.projections.rubygems;
    ruby32-cli = cli.override {
      projectRuby = ruby2025.ruby_3_2;
      projectNativeBuildInputs = [ ruby2025.stdenv.cc ];
    };
    ruby32-input-composition =
      pkgs.runCommand "ruby32-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${ruby2025.ruby_3_2} ${project32.release.projections.rubygems} ${project32.release.projections.rubygems.catalog} 3.2.8 2.4.19
          touch "$out"
        '';
    ruby33-sdk = ruby2025.ruby_3_3;
    ruby33-native-extension = project33.tests;
    ruby33-app = project33.packages.app;
    ruby33-repository = project33.release.projections.rubygems;
    ruby33-cli = cli.override {
      projectRuby = ruby2025.ruby_3_3;
      projectNativeBuildInputs = [ ruby2025.stdenv.cc ];
    };
    ruby33-input-composition =
      pkgs.runCommand "ruby33-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${ruby2025.ruby_3_3} ${project33.release.projections.rubygems} ${project33.release.projections.rubygems.catalog} 3.3.8 2.5.22
          touch "$out"
        '';
    rubygems276-update = rubygems276Update;
    ruby22-sdk = native22.sdk;
    ruby22-app = project22.packages.app;
    ruby22-native-extension = project22.tests;
    ruby22-repository = project22.release.projections.rubygems;
    ruby22-cli = cli.override {
      projectRuby = native22.sdk;
      projectNativeBuildInputs = [ native22.compiler ];
    };
    ruby23-bundler20-sdk = native23Bundler20.sdk;
    ruby23-bundler20-app = project23Bundler20.packages.app;
    ruby23-bundler20-native-extension = project23Bundler20.tests;
    ruby23-bundler20-repository = project23Bundler20.release.projections.rubygems;
    ruby23-bundler20-cli = cli.override {
      projectRuby = native23Bundler20.sdk;
      projectNativeBuildInputs = [ native23Bundler20.compiler ];
    };
    ruby23-bundler20-input-composition =
      pkgs.runCommand "ruby23-bundler20-native-input-composition"
        { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native23Bundler20.sdk} ${project23Bundler20.release.projections.rubygems} ${project23Bundler20.release.projections.rubygems.catalog} 2.3.6 2.0.2
          touch $out
        '';
    ruby23-sdk = rubies2018.ruby_2_3;
    ruby23-app = project23.packages.app;
    ruby23-native-extension = project23.tests;
    ruby23-repository = project23.release.projections.rubygems;
    ruby23-cli = cli.override {
      projectRuby = rubies2018.ruby_2_3;
      projectNativeBuildInputs = [ rubies2018.stdenv.cc ];
    };
    ruby24-sdk = rubies2018.ruby_2_4;
    ruby24-app = project24.packages.app;
    ruby24-native-extension = project24.tests;
    ruby24-repository = project24.release.projections.rubygems;
    ruby24-cli = cli.override {
      projectRuby = rubies2018.ruby_2_4;
      projectNativeBuildInputs = [ rubies2018.stdenv.cc ];
    };
    ruby22-input-composition =
      pkgs.runCommand "ruby22-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${native22.sdk} ${project22.release.projections.rubygems} ${project22.release.projections.rubygems.catalog} 2.2.7 1.17.3
          touch "$out"
        '';
    ruby23-input-composition =
      pkgs.runCommand "ruby23-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${rubies2018.ruby_2_3} ${project23.release.projections.rubygems} ${project23.release.projections.rubygems.catalog} 2.3.6 1.16.1
          touch "$out"
        '';
    ruby24-input-composition =
      pkgs.runCommand "ruby24-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${rubies2018.ruby_2_4} ${project24.release.projections.rubygems} ${project24.release.projections.rubygems.catalog} 2.4.3 1.16.1
          touch "$out"
        '';
    ruby41-sdk = native41;
    ruby41-app = project41.packages.app;
    ruby41-native-extension = project41.tests;
    ruby41-repository = project41.release.projections.rubygems;
    ruby41-cli = cli.override { projectRuby = native41; };
    ruby41-input-composition =
      pkgs.runCommand "ruby41-preview-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${native41} ${project41.release.projections.rubygems} ${project41.release.projections.rubygems.catalog} 4.1.0 4.1.0.beta2 --ruby-requirement 4.1.0.preview1
          touch "$out"
        '';
    rubygems312-update = rubygems312Update;
    ruby25-sdk = native25.sdk;
    ruby25-native-extension = project25.tests;
    ruby25-app = project25.packages.app;
    ruby25-repository = project25.release.projections.rubygems;
    ruby25-cli = cli.override {
      projectRuby = native25.sdk;
      projectNativeBuildInputs = [ native25.compiler ];
    };
    ruby25-input-composition =
      pkgs.runCommand "ruby25-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native25.sdk} ${project25.release.projections.rubygems} ${project25.release.projections.rubygems.catalog} 2.5.8 2.0.2
          touch $out
        '';
    ruby26-sdk = historicalRubies.ruby_2_6;
    ruby26-native-extension = project26.tests;
    ruby26-app = project26.packages.app;
    ruby26-repository = project26.release.projections.rubygems;
    ruby26-cli = cli.override {
      projectRuby = historicalRubies.ruby_2_6;
      projectNativeBuildInputs = [ historicalRubies.stdenv.cc ];
    };
    ruby26-input-composition =
      pkgs.runCommand "ruby26-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${historicalRubies.ruby_2_6} ${project26.release.projections.rubygems} ${project26.release.projections.rubygems.catalog} 2.6.6 1.17.2
          touch $out
        '';
    ruby27-sdk = historicalRubies.ruby_2_7;
    ruby27-native-extension = project27.tests;
    ruby27-app = project27.packages.app;
    ruby27-repository = project27.release.projections.rubygems;
    ruby27-cli = cli.override {
      projectRuby = historicalRubies.ruby_2_7;
      projectNativeBuildInputs = [ historicalRubies.stdenv.cc ];
    };
    ruby27-input-composition =
      pkgs.runCommand "ruby27-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${historicalRubies.ruby_2_7} ${project27.release.projections.rubygems} ${project27.release.projections.rubygems.catalog} 2.7.1 2.1.4
          touch $out
        '';
    ruby191-sdk = native191.sdk;
    ruby191-app = project191.packages.app;
    ruby191-native-extension = project191.tests;
    ruby191-repository = project191.release.projections.rubygems;
    ruby191-cli = cli.override {
      projectRuby = native191.sdk;
      projectNativeBuildInputs = [ native191.compiler ];
    };
    ruby191-input-composition =
      pkgs.runCommand "ruby191-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${native191.sdk} ${project191.release.projections.rubygems} ${project191.release.projections.rubygems.catalog} 1.9.1 1.17.3
          touch "$out"
        '';
    ruby192-sdk = native192.sdk;
    ruby192-app = project192.packages.app;
    ruby192-native-extension = project192.tests;
    ruby192-repository = project192.release.projections.rubygems;
    ruby192-cli = cli.override {
      projectRuby = native192.sdk;
      projectNativeBuildInputs = [ native192.compiler ];
    };
    ruby192-input-composition =
      pkgs.runCommand "ruby192-native-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME="$TMPDIR"
          python3 ${../.}/tests/historical-composition.py ${native192.sdk} ${project192.release.projections.rubygems} ${project192.release.projections.rubygems.catalog} 1.9.2 1.17.3
          touch "$out"
        '';
    ruby40-sdk = pkgs.ruby_4_0;
    ruby40-native-extension = project40.tests;
    ruby40-app = project40.packages.app;
    ruby40-repository = project40.release.projections.rubygems;
    ruby40-input-composition =
      pkgs.runCommand "ruby409-bundler4-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${pkgs.ruby_4_0} ${project40.release.projections.rubygems} ${project40.release.projections.rubygems.catalog} 4.0.9 4.0.20
          touch $out
        '';
    ruby40-cli = cli.override { projectRuby = pkgs.ruby_4_0; };
    ruby19-sdk = native19.sdk;
    ruby19-native-extension = project19.tests;
    ruby19-app = project19.packages.app;
    ruby19-repository = project19.release.projections.rubygems;
    ruby19-input-composition =
      pkgs.runCommand "ruby193-bundler117-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native19.sdk} ${project19.release.projections.rubygems} ${project19.release.projections.rubygems.catalog} 1.9.3
          ${native19.sdk}/bin/ruby ${./ruby19-method-hooks.rb} ${../tools/rubygems_inputs.rb}
          touch $out
        '';
    ruby19-cli = cli.override {
      projectRuby = native19.sdk;
      projectNativeBuildInputs = [ native19.compiler ];
    };
    ruby18-rubygems-update = native.rubygemsUpdate;
    ruby18-bundler10-sdk = native10.sdk;
    ruby18-bundler09-sdk = native09.sdk;
    ruby18-git-prefetch = pkgs.nix-prefetch-git;
    ruby18-bundler09-cli = cli.override {
      projectRuby = native09.sdk;
      projectNativeBuildInputs = [ native09.compiler ];
    };
    ruby18-bundler10-rubygems-update = native10.rubygemsUpdate;
    ruby18-bundler10-cli = cli.override {
      projectRuby = native10.sdk;
      projectNativeBuildInputs = [ native10.compiler ];
    };
    ruby18-bundler117-gems = native.gems;
    ruby18-bundler116-sdk = native116.sdk;
    ruby18-bundler110-sdk = native110.sdk;
    ruby18-bundler136-sdk = native136.sdk;
    ruby18-bundler136-cli = cli.override {
      projectRuby = native136.sdk;
      projectNativeBuildInputs = [ native136.compiler ];
    };
    ruby18-bundler116-cli = cli.override {
      projectRuby = native116.sdk;
      projectNativeBuildInputs = [ native116.compiler ];
    };
    ruby18-bundler110-cli = cli.override {
      projectRuby = native110.sdk;
      projectNativeBuildInputs = [ native110.compiler ];
    };
    ruby18-cli = cli.override {
      projectRuby = native.sdk;
      projectNativeBuildInputs = [ native.compiler ];
    };
    ruby18-release = project.release;
    ruby18-ordinary-consumer =
      pkgs.runCommand "ruby187-ordinary-compiled-consumer"
        {
          nativeBuildInputs = [ native.sdk ];
        }
        ''
          export HOME=$TMPDIR GEM_HOME=$TMPDIR/gems GEM_PATH=$TMPDIR/gems
          repository=${project.release.projections.rubygems}
          gem install --local --no-document "$repository"/gems/json-*.gem
          gem install --local --no-document "$repository"/gems/historical_greeting-*.gem
          ruby -e 'require "historical_greeting"; abort unless RUBY_VERSION == "1.8.7"; abort unless HistoricalGreeting.answer == 42; abort unless $LOADED_FEATURES.any? { |path| path =~ /json\/ext\/parser\.so$/ }; abort unless Gem.loaded_specs.fetch("json").full_gem_path.start_with?(ENV.fetch("GEM_HOME") + "/")'
          touch $out
        '';
    ruby18-app = project.packages.app;
    ruby18-native-extension = project.tests;
    ruby18-repository = project.release.projections.rubygems;
    ruby18-bundler10-input-composition =
      pkgs.runCommand "ruby187-gems1830-bundler10-input-composition"
        { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native10.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} 1.8.7 1.0.22 ${native.gems}/gems --versionless --rubygems-version 1.8.30 --no-ruby-dsl
          touch $out
        '';
    ruby18-bundler09-native-yaml-composition =
      pkgs.runCommand "ruby187-bundler09-native-yaml-composition"
        { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/ruby18-yaml-composition.py ${native09.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} --extra-gem-path ${native.gems}/gems --codec ${purifier.rubygemsCodecCompatibility}
          touch $out
        '';
    ruby18-bundler09-native-yaml-sources =
      pkgs.runCommand "ruby187-bundler09-native-yaml-sources"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.gitMinimal
          ];
        }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/ruby18-yaml-sources.py ${native09.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog}
          touch $out
        '';
    ruby18-bundler136-input-composition =
      pkgs.runCommand "ruby187-bundler136-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native136.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} 1.8.7 1.3.6 ${native.gems}/gems --versionless
          touch $out
        '';
    ruby18-bundler110-input-composition =
      pkgs.runCommand "ruby187-bundler110-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native110.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} 1.8.7 1.10.6 ${native.gems}/gems
          touch $out
        '';
    ruby18-bundler116-input-composition =
      pkgs.runCommand "ruby187-bundler116-input-composition" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native116.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} 1.8.7 1.16.6 ${native.gems}/gems
          touch $out
        '';
    ruby18-input-composition =
      pkgs.runCommand "ruby187-bundler117-input-composition"
        {
          nativeBuildInputs = [ pkgs.python3 ];
        }
        ''
          export HOME=$TMPDIR
          python3 ${../.}/tests/historical-composition.py ${native.sdk} ${project.release.projections.rubygems} ${project.release.projections.rubygems.catalog} 1.8.7
          touch $out
        '';
  }
)
