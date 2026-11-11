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
    ruby19-sdk = native19.sdk;
    ruby19-native-extension = project19.tests;
    ruby19-app = project19.packages.app;
    ruby19-repository = project19.release.projections.rubygems;
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
