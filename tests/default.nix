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
