# SPDX-License-Identifier: MIT
#
# buildBundlerProject: the sandboxed builds of a Bundler project, from the
# lockfile `bundler-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# bundler-purifier overlay (`overlays.default`) adds it to the scope
# `pkgs.bundler-purifier` as `buildBundlerProject`, so a package written
# for callPackage takes the scope like any other dependency:
#
#   { bundler-purifier }:
#   (bundler-purifier.buildBundlerProject { src = ./.; }).packages.app
#
# `bundler-purifier.buildBundlerProject.override` replaces what the builder
# takes from the package set, and `bundler-purifier.overrideScope` replaces
# what the scope holds.
#
# The builder returns the attributes of the nix-purifiers contract:
#
#   packages.app      the project with its bundle installed in deployment
#                     mode under vendor/bundle; with external path
#                     sources, the project is at `app.projectDir` inside
#                     it, beside those sources
#   packages.bundle   `bin/bundle` for the app: the locked Bundler on the
#                     app's Gemfile, so `bundle exec` runs the app
#   packages.<gem>    the gem file built from each gemspec of the project,
#                     at <gem>-<version>.gem; `gemFile` names it
#   tests             the `app` build with `checkCommand` run after the
#                     install
#   release           what `bundler-purifier publish` pushes: the gem file
#                     of the project's gemspec, or all of them
#   fetches           the download entries of the lock, as the shared
#                     nix-purifiers library reads them
#
# and these of its own:
#
#   executables.<name>
#                     each executable the gemspecs declare, as `bin/<name>`
#                     running it with the app's bundle
#   devShell          a shell with the Ruby and libraries of the `app`
#                     build, which `bundler-purifier prefetch` keeps
#   gemCache          the gem cache of every locked download, as Bundler's
#                     `vendor/cache` holds it
#
# The lock names every one of these outputs, so Nix knows them when it
# evaluates, without building anything.
{
  lib,
  stdenv,
  gitMinimal,
  writeShellScriptBin,
  symlinkJoin,
  mkShell,
  defaultGemConfig,
  # nixpkgs' Rubies by minor version. A build runs on the one of the minor
  # version its lock was made with, unless it passes `ruby`.
  ruby_3_4 ? null,
  ruby_4_0 ? null,
  # The fetchers and the packages that the shared library's fetchEntry
  # builds with.
  fetchurl,
  fetchgit,
  runCommand,
  unzip,
  zstd,
  python3,
  writeText,
  # The `purifier` namespace of the shared nix-purifiers library, which the
  # bundler-purifier overlay passes.
  purifier,
  integrationTools ? ../../tools,
  # lib.bundler-purifier.readLock (read-lock.nix), which the overlay passes.
  readLock,
}:
{
  # The root of the Bundler project, where the Gemfile is.
  src,
  # The lockfile that `bundler-purifier lock` writes. It may lie outside
  # `src`, kept by the flake that calls the builder; a lockFile outside
  # `src` takes the place of any copy in it.
  lockFile ? src + "/bundler-purifier.lock.json",
  # The project's Gemfile.lock. A flake that keeps its own copy outside
  # `src` passes it here, and the builds use it in place of the copy in
  # `src`.
  gemfileLock ? src + "/Gemfile.lock",
  # Fetchers in place of nixpkgs' fetchers, passed to the shared library's
  # fetchEntry: `fetchurl` for a gem server that needs credentials or a
  # mirror, `fetchgit` for a private git repository.
  fetchers ? { },
  # The name of `packages.app`.
  name ? "bundler-app",
  # The Ruby that runs Bundler. The default is nixpkgs' Ruby of the minor
  # version the lock was made with.
  ruby ? null,
  # Keep index serialization independent of old native package codecs.
  indexRuby ? null,
  # The archive projector is a host helper. RubyGems 1.x consumers use
  # Gem::Package as a module and cannot run its modern archive API.
  projectionRuby ? null,
  # Build tools and libraries for gems with native extensions, which
  # compile in the `app` build, beyond the ones nixpkgs names for them
  # (`useGemConfig`). The libraries are on LD_LIBRARY_PATH in the shell
  # and the `bundle` wrapper, for gems that open one through FFI.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Adds the build inputs that nixpkgs' gem configuration
  # (defaultGemConfig) names for each locked gem, such as libyaml for
  # psych, so that common native extensions compile without arguments.
  useGemConfig ? true,
  # Bundler groups that `app` leaves out, as `bundle config set without`.
  without ? [ ],
  # The test run of `tests`.
  checkCommand ? "bundle exec rake",
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out version control,
  # Bundler's local state and build outputs.
  srcFilter ? null,
  # The trees of the path sources outside the project, by the path
  # Gemfile.lock gives them (relative to the project root), such as
  # { "../shared" = inputs.shared; }. The lock lists them as externalPaths.
  externalPaths ? { },
  dependencies ? purifier.lockedProjectInputs {
    inputs =
      (builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile lockFile))).projectInputs
        or [ ];
    system = stdenv.hostPlatform.system;
  },
}:
let
  readJson = file: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile file));
  selectedInputs = purifier.projectInputs {
    inherit dependencies;
    formats = [ "rubygems" ];
  };
  inputViews = map (input: {
    repository = toString input.repository;
    catalog = input.repository.catalog;
  }) selectedInputs;
  providedGems = lib.unique (
    lib.concatMap (
      view:
      let
        catalog = readJson view.catalog;
      in
      map (entry: entry.name) (catalog.packages ++ (catalog.intrinsics or [ ]))
    ) inputViews
  );
  sdkRequirements = lib.concatMap (view: (readJson view.catalog).intrinsics or [ ]) inputViews;
  sdkOrigins = lib.unique (map (entry: entry.sdk) sdkRequirements);
  sdkContext = builtins.getContext (
    lib.concatMapStrings (input: toString input.repository) selectedInputs
  );
  inputEnvironment = lib.escapeShellArg (builtins.toJSON inputViews);

  # A file of the project, read without copying the whole project into the
  # store first.
  srcFile = rel: if builtins.isPath src then src + "/${rel}" else "${src}/${rel}";

  # The lock in memory (read-lock.nix), checked by the shared library:
  # evaluation fails with its problems, each naming the fix.
  readResult = readLock {
    inherit
      src
      lockFile
      gemfileLock
      externalPaths
      providedGems
      ;
  };
  checkedLock = purifier.checkLock readResult;
  # What the builder reads besides the entries. Its names are known without
  # the check, so the attribute names of the result are too.
  lock = readResult.bundlerLock // {
    gemsByName = builtins.listToAttrs (
      map (gem: {
        inherit (gem) name;
        value = gem;
      }) readResult.bundlerLock.gems
    );
  };
  # The downloads of this system.
  downloads = purifier.entriesFor stdenv.hostPlatform.system checkedLock;
  files = builtins.filter (d: !(d ? git)) downloads;
  gitCheckouts = builtins.filter (d: d ? git) downloads;

  # The gemspec of a gem of the project: <name>.gemspec in its directory, or
  # the directory's only gemspec.
  gemspecOf =
    gem:
    let
      inDir = lib.attrNames (
        lib.filterAttrs (n: type: type != "directory" && lib.hasSuffix ".gemspec" n) (
          builtins.readDir (srcFile gem.dir)
        )
      );
      file =
        if lib.elem "${gem.name}.gemspec" inDir then
          "${gem.name}.gemspec"
        else if lib.length inDir == 1 then
          lib.head inDir
        else
          throw "bundler-purifier: ${gem.dir} has no gemspec named ${gem.name}.gemspec.";
    in
    if gem.dir == "." then file else "${gem.dir}/${file}";

  # The build lays the project and its external path sources out at the
  # same relative positions as in the checkout: the project goes below as
  # many placeholder directories as the deepest `../` climbs, so that each
  # external path resolves inside the build's tree.
  hasExternal = lock.externalPaths != [ ];
  # The number of leading `..` segments of a path.
  climbs =
    p:
    let
      count =
        segments: if segments != [ ] && lib.head segments == ".." then 1 + count (lib.tail segments) else 0;
    in
    count (lib.splitString "/" p);
  depth = lib.foldl' lib.max 0 (map climbs lock.externalPaths);
  # The project's directory in `app` (and in the build's tree).
  projectDir =
    if hasExternal then
      lib.concatMapStrings (i: "_parent${toString i}/") (lib.range 1 depth) + "project"
    else
      ".";
  placeExternalPaths = ''
    tree="$TMPDIR/tree"
    mkdir -p "$tree/${projectDir}"
    cp -r . "$tree/${projectDir}"
    ${lib.concatMapStrings (p: ''
      mkdir -p "$(dirname "$tree/${projectDir}/${p}")"
      cp -r --no-preserve=mode ${externalPaths.${p}} "$tree/${projectDir}/${p}"
    '') lock.externalPaths}
    cd "$tree/${projectDir}"
  '';

  # Version control, Bundler's local state and installs, the purifier
  # lockfile (the build reads `lockFile`) and the results of nix build never
  # take part in a build. The project's .bundle/config does, since it holds
  # settings such as compile flags for native extensions
  # (BUNDLE_BUILD__<gem>). vendor/cache is the gem cache this builder
  # supplies itself.
  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
      rel = lib.removePrefix (toString src + "/") (toString path);
    in
    !(
      base == ".git"
      || base == ".bundler-purifier"
      || lib.hasPrefix ".bundler-purifier-" base
      || lib.hasPrefix ".bundler-purifier.Gemfile" base
      || (lib.hasPrefix ".bundle/" rel && rel != ".bundle/config")
      || rel == "vendor/bundle"
      || rel == "vendor/cache"
      || rel == "bundler-purifier.lock.json"
      || lib.hasPrefix "result" base
    );

  filteredSrc = builtins.path {
    path = src;
    name = "bundler-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  rubyVersion = lib.versions.splitVersion (builtins.seq checkedLock lock.ruby);
  rubyAttr = "ruby_${builtins.elemAt rubyVersion 0}_${builtins.elemAt rubyVersion 1}";
  rubies = lib.filterAttrs (_: r: r != null) { inherit ruby_3_4 ruby_4_0; };
  # The start of the platform an SDK records (Gem::Platform.local) on this
  # system. RubyGems names Linux as Nix does, but aarch64-darwin is
  # arm64-darwin-<version> to it.
  gemPlatform =
    if stdenv.hostPlatform.system == "aarch64-darwin" then
      "arm64-darwin"
    else
      stdenv.hostPlatform.system;
  ruby' =
    if ruby != null then
      ruby
    else if sdkOrigins != [ ] then
      assert
        lib.length sdkOrigins == 1 || throw "bundler-purifier: Nix inputs require different Ruby SDKs";
      assert
        lib.all (entry: lib.hasPrefix gemPlatform entry.system) sdkRequirements
        || throw "bundler-purifier: Nix input Ruby SDK is for a different platform";
      builtins.appendContext (lib.head sdkOrigins) sdkContext
    else
      rubies.${rubyAttr}
        or (throw "bundler-purifier: the builder has no ${rubyAttr} for the Ruby ${lock.ruby} the lock was made with; pass `ruby`.");

  # The source as the builds see it: with `gemfileLock` in place of the
  # Gemfile.lock of `src` when the flake keeps its own copy.
  prepareSource = lib.optionalString (toString gemfileLock != toString (srcFile "Gemfile.lock")) ''
    cp --no-preserve=mode ${gemfileLock} Gemfile.lock
  '';

  downloadedGemCache = import ./gem-cache.nix {
    inherit
      lib
      purifier
      files
      gitCheckouts
      ;
    fetchers = {
      inherit
        fetchurl
        fetchgit
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers;
  };

  gemCache =
    if selectedInputs == [ ] then
      downloadedGemCache
    else
      runCommand "bundler-composed-gem-cache" { } ''
        mkdir -p "$out"
        cp -rs ${downloadedGemCache}/. "$out/"
        ${lib.concatMapStrings (view: ''
          for archive in ${view.repository}/gems/*.gem; do
            ln -s "$archive" "$out/$(basename "$archive")"
          done
        '') inputViews}
      '';

  # The environment shared by every build. Bundler's own configuration
  # goes to .bundle/config in the build directory, which `app` keeps.
  nativeYaml = (lock.nativeFormat or null) == "bundler-yaml";
  setupBundler = ''
    export HOME="$TMPDIR/home"
    export GEM_HOME="$TMPDIR/gems"
    export BUNDLER_PURIFIER_BUNDLER_VERSION=${lib.escapeShellArg lock.bundler}
    # The sandbox sets no locale, and Ruby would read gemspecs and file
    # lists as US-ASCII.
    export LC_ALL=C.UTF-8
    # The binstub that gem install writes starts with `#!ruby`, which the
    # sandbox cannot resolve, so `bundle` runs it through Ruby. The later
    # phases run in the same shell and keep the function.
    ${
      if selectedInputs == [ ] && !nativeYaml then
        ''
          bundle() { ruby "$GEM_HOME/bin/bundle" "$@"; }
        ''
      else
        ''
          export BUNDLER_PURIFIER_INPUT_VIEWS=${inputEnvironment}
          bundle() { ruby ${integrationTools}/native_bundle_command.rb "$@"; }
        ''
    }
    native_gem_install() {
      local install_help
      install_help=$(gem help install)
      case "$install_help" in
        *"--no-document"*|*"--[no-]document"*) gem install --local --no-document "$@" ;;
        *) gem install --local --no-rdoc --no-ri "$@" ;;
      esac
    }
    mkdir -p "$HOME" "$GEM_HOME" vendor
    rm -rf vendor/cache
    # Bundler copies what it installs from the cache and leaves marker
    # files in it, so the cache is a writable tree of links into the store.
    cp -r${lib.optionalString nativeYaml "L"} --no-preserve=mode ${gemCache} vendor/cache
    # Bundler loads the gemspec of a git source from its cached checkout,
    # and many of those gemspecs call `git ls-files`. Each checkout becomes
    # a repository of its files, submodule contents included.
    for checkout in vendor/cache/*/.bundlecache; do
      if [ -e "$checkout" ]; then
        (cd "$(dirname "$checkout")" && ${gitRepositoryForGemspecs})
      fi
    done
    # The locked Bundler, installed from the cache, so the build runs the
    # Bundler version of BUNDLED WITH and Bundler has nothing to fetch.
    native_gem_install --install-dir "$GEM_HOME" --bindir "$GEM_HOME/bin" \
      vendor/cache/bundler-${lock.bundler}.gem
    ${
      if nativeYaml then
        ''
          # Use this SDK's settings writer; this CLI predates `bundle config`.
          ruby -rrubygems -rrubygems/user_interaction -e ${lib.escapeShellArg ''
            gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION")
            require "bundler"
            Bundler.settings[:cache_path] = "vendor/cache"
            Bundler.settings[:path] = "vendor/bundle"
            Bundler.settings[:without] = ${builtins.toJSON (lib.concatStringsSep ":" without)}
          ''}
        ''
      else
        ''
          native_bundle_local_config() {
            # CLI flag metadata is incomplete in some older releases. Use
            # the SDK's actual local settings API and retain its own format.
            ruby -rrubygems -e ${lib.escapeShellArg ''
              gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION")
              require "bundler"
              settings = Bundler.settings
              if settings.respond_to?(:set_local)
                settings.set_local(ARGV.fetch(0), ARGV.fetch(1))
              else
                settings[ARGV.fetch(0)] = ARGV.fetch(1)
              end
            ''} "$@"
          }
          native_bundle_local_config cache_path vendor/cache
          ${lib.optionalString (selectedInputs != [ ]) ''
            BUNDLER_PURIFIER_PERSIST_LOCK=1 BUNDLE_FROZEN=false BUNDLE_DEPLOYMENT=false \
              bundle lock --local >&2
          ''}
          native_bundle_local_config deployment true
          native_bundle_local_config frozen true
          native_bundle_local_config path vendor/bundle
          ${lib.optionalString (without != [ ]) ''
            native_bundle_local_config without ${lib.escapeShellArg (lib.concatStringsSep ":" without)}
          ''}
        ''
    }

  '';

  # Many gemspecs list their files with `git ls-files`. The source of a
  # flake holds the tracked files, so a repository of all of them gives
  # `git ls-files` the same list.
  gitRepositoryForGemspecs = ''
    git init -q
    git add -A
  '';

  # The build inputs that nixpkgs' gem configuration names for the locked
  # gems. A gem file is named <name>-<version>[-<platform>].gem. An entry
  # that fails to evaluate for a gem adds nothing.
  gemConfigInputs = lib.concatMap (
    download:
    let
      parts = builtins.match "(.+)-([0-9][^-]*)(-.+)?\\.gem" (baseNameOf download.path);
      gemName = builtins.elemAt parts 0;
      config = defaultGemConfig.${gemName} or null;
      evaluated = builtins.tryEval (
        let
          attrs = config {
            inherit gemName;
            version = builtins.elemAt parts 1;
          };
          inputs = (attrs.buildInputs or [ ]) ++ (attrs.nativeBuildInputs or [ ]);
        in
        # Each input is forced to its outer value, so that an entry that
        # fails to evaluate fails here, inside tryEval.
        builtins.foldl' (forced: input: builtins.seq input forced) inputs inputs
      );
    in
    if parts == null || config == null || !evaluated.success then
      [ ]
    # The configuration supplies system libraries and tools. Its nixpkgs
    # gems and Rubies stay out: Bundler supplies the gems, and their setup
    # hooks would put other gem versions on RUBYLIB.
    else
      lib.filter (input: !(lib.isAttrs input && (input ? gemName || input ? rubyEngine))) evaluated.value
  ) files;

  # The libraries the gems may load at run time: gems such as ruby-vips
  # open a library through FFI by its name, so the shell and the `bundle`
  # wrapper put these on LD_LIBRARY_PATH.
  runtimeInputs = buildInputs ++ lib.optionals useGemConfig (lib.unique gemConfigInputs);
  runtimeLibraryPath = lib.makeLibraryPath runtimeInputs;

  # The project and its external path sources need a repository for their
  # gemspecs; git sources get one in setupBundler.
  usesGemspecs = lock.gems != [ ] || hasExternal;

  app = builtins.seq checkedLock (
    stdenv.mkDerivation {
      inherit name;
      src = filteredSrc;
      nativeBuildInputs = [
        ruby'
        gitMinimal
      ]
      ++ nativeBuildInputs;
      buildInputs = runtimeInputs;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${prepareSource}
        ${lib.optionalString hasExternal placeExternalPaths}
        ${lib.optionalString usesGemspecs ''
          # The repository covers the external path sources too, which sit
          # beside the project in the build's tree.
          (cd ${if hasExternal then ''"$tree"'' else "."} && ${gitRepositoryForGemspecs})
        ''}
        ${setupBundler}
        bundle install --local
        # RubyGems writes gem executables with `#! ruby`, which no kernel
        # resolves, so `bundle exec` could not start them. They get the
        # absolute path of this Ruby.
        for bin in vendor/bundle/ruby/*/bin/*; do
          if [ -f "$bin" ]; then
            sed -i -E '1s|^#! ?ruby( .*)?$|#!${ruby'}/bin/ruby\1|' "$bin"
          fi
        done
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        ${checkCommand}
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        # The locked Bundler, for the `bundle` wrapper to run the app with.
        # Native install may prune its writable cache, including Bundler's
        # own archive. The exact hashed SDK input remains in the Nix cache.
        native_gem_install --install-dir .bundle/purifier/bundler \
          ${gemCache}/bundler-${lock.bundler}.gem
        # Older Bundler gems mark ERB executable templates as executable.
        # They are generator data, not scripts for fixup to interpret.
        for template in .bundle/purifier/bundler/gems/bundler-*/lib/bundler/templates/Executable*; do
          if [ -f "$template" ]; then
            chmod a-x "$template"
          fi
        done
        # The gem cache served the install; the output keeps the installed
        # bundle under vendor/bundle. The repository for the gemspecs goes.
        rm -rf vendor/cache
        ${lib.optionalString (selectedInputs != [ ]) ''
          cat > .bundler-purifier.Gemfile <<'RUBY'
          require "${integrationTools}/rubygems_inputs.rb"
          eval_gemfile "Gemfile"
          RUBY
          cp Gemfile.lock .bundler-purifier.Gemfile.lock
        ''}
        mkdir -p "$out"
        ${
          if hasExternal then
            ''
              rm -rf "$tree/.git"
              cp -r "$tree/." "$out"
            ''
          else
            ''
              rm -rf .git
              cp -r . "$out"
            ''
        }
        ${lib.optionalString nativeYaml ''
          # This SDK's generated environment contains absolute install paths.
          # Relocate that cache alongside the installed bundle, keeping its
          # native lock, fingerprint and selected specifications intact.
          substituteInPlace "$out/${projectDir}/.bundle/environment.rb" \
            --replace-fail "$PWD" "$out/${projectDir}"
        ''}
        runHook postInstall
      '';
      passthru = {
        ruby = ruby';
        inherit gemCache projectDir;
      };
    }
  );

  # `bundle` for the app: the locked Bundler, on the app's Gemfile, so
  # `bundle exec` runs the app with its installed bundle.
  bundle = writeShellScriptBin "bundle" ''
    export GEM_HOME=${app}/${projectDir}/.bundle/purifier/bundler
    export GEM_PATH="$GEM_HOME"
    export BUNDLER_PURIFIER_BUNDLER_VERSION=${lib.escapeShellArg lock.bundler}
    export BUNDLE_GEMFILE=${app}/${projectDir}/${
      if selectedInputs == [ ] then "Gemfile" else ".bundler-purifier.Gemfile"
    }
    if [ -z "''${LC_ALL:-}''${LANG:-}" ]; then
      export LANG=C.UTF-8
    fi
    # Bundler evaluates the gemspecs of path sources on every run, and many
    # of them call `git ls-files`.
    export PATH=${ruby'}/bin:"$PATH":${gitMinimal}/bin
    export LD_LIBRARY_PATH=${runtimeLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    ${
      if nativeYaml then
        ''
          export BUNDLER_PURIFIER_INPUT_VIEWS=${inputEnvironment}
          export BUNDLER_PURIFIER_PERSISTENT_GEMFILE="$BUNDLE_GEMFILE"
          exec ruby ${integrationTools}/native_bundle_command.rb "$@"
        ''
      else if selectedInputs == [ ] then
        ''
          exec ruby "$GEM_HOME/bin/bundle" "$@"
        ''
      else
        ''
          export BUNDLER_PURIFIER_INPUT_VIEWS=${inputEnvironment}
          exec ruby "$GEM_HOME/bin/bundle" "$@"
        ''
    }
  '';

  mkGem =
    gem:
    let
      fileName = "${gem.name}-${gem.version}.gem";
      package = builtins.seq checkedLock stdenv.mkDerivation {
        pname = gem.name;
        inherit (gem) version;
        src = filteredSrc;
        nativeBuildInputs = [
          ruby'
          gitMinimal
        ];
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          ${prepareSource}
          ${gitRepositoryForGemspecs}
          cd ${lib.escapeShellArg gem.dir}
          ruby -r ${purifier.rubygemsCodecCompatibility} ${integrationTools}/build_gem.rb ${lib.escapeShellArg (baseNameOf (gemspecOf gem))} ${lib.escapeShellArg fileName}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp ${lib.escapeShellArg fileName} "$out/"
          runHook postInstall
        '';
        passthru = {
          gemFile = "${package}/${fileName}";
        };
      };
    in
    package;

  gems = lib.mapAttrs (_: mkGem) lock.gemsByName;
  capturedGems =
    runCommand "${name}-runtime-gems"
      {
        nativeBuildInputs = [
          ruby'
          gitMinimal
        ];
        ownArchives = builtins.toJSON (map (gem: gem.gemFile) (lib.attrValues gems));
        projectRoots = builtins.toJSON (map (gem: gem.name) (lib.filter (gem: gem.dir == ".") lock.gems));
      }
      ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" project
            cp -r --no-preserve=mode ${app}/. project/
            cd project/${projectDir}
            export GEM_HOME=${app}/${projectDir}/.bundle/purifier/bundler
            export GEM_PATH="$GEM_HOME"
            export BUNDLE_GEMFILE="$PWD/${
              if selectedInputs == [ ] then "Gemfile" else ".bundler-purifier.Gemfile"
            }"
            export BUNDLER_PURIFIER_INPUT_VIEWS=${inputEnvironment}
            export BUNDLER_PURIFIER_OWN_ARCHIVES="$ownArchives"
        export BUNDLER_PURIFIER_PROJECT_ROOTS="$projectRoots"
            ${
              if selectedInputs == [ ] then
                ''
                  ruby "$GEM_HOME/bin/bundle" exec ruby -r ${purifier.rubygemsCodecCompatibility} ${integrationTools}/capture_gems.rb "$out"
                ''
              else
                ''
                  export BUNDLER_PURIFIER_PERSISTENT_GEMFILE="$BUNDLE_GEMFILE"
                  ruby ${integrationTools}/native_bundle_command.rb exec ruby -r ${purifier.rubygemsCodecCompatibility} ${integrationTools}/capture_gems.rb "$out"
                ''
            }
      '';
  # Ruby 1.9's stdlib JSON rejects scalar serialization used by metadata
  # helpers. Keep those helpers separate from the genuine native consumer.
  indexRuby' =
    if indexRuby != null then
      indexRuby
    else if lib.versionOlder lock.ruby "2.0" then
      if ruby_3_4 != null then
        ruby_3_4
      else
        throw "bundler-purifier: this native codec needs an independent index helper; pass indexRuby."
    else
      ruby';
  projectionFor =
    roots:
    purifier.rubygemsProjections {
      archives = map (archive: "${capturedGems}/${archive}") (readJson "${capturedGems}/archives.json");
      producer = app;
      inherit dependencies runCommand roots;
      intrinsics = readJson "${capturedGems}/intrinsics.json";
      ruby =
        if projectionRuby != null then
          projectionRuby
        else if lib.versionOlder lock.ruby "2.0" then
          indexRuby'
        else
          ruby';
      indexRuby = indexRuby';
      name = "${name}-rubygems-repository";
    };
  projections = projectionFor (readJson "${capturedGems}/roots.json");
  releaseProjections = projectionFor (map (gem: gem.name) lock.gems);
  clashes = lib.filter (n: gems ? ${n}) [
    "app"
    "bundle"
  ];
in
assert
  clashes == [ ]
  || throw "bundler-purifier: a gemspec of the project builds a gem named ${lib.head clashes}, which clashes with packages.${lib.head clashes}.";
{
  inherit projections;
  packages = lib.mapAttrs (name: gem: gem // { projections = projectionFor [ name ]; }) gems // {
    app = app // {
      inherit projections;
    };
    bundle = bundle // {
      inherit projections;
    };
  };

  tests = app.overrideAttrs (_: {
    name = "${name}-tests";
    doCheck = true;
  });

  release =
    if lib.length (lib.attrNames gems) == 1 then
      (lib.head (lib.attrValues gems)) // { projections = releaseProjections; }
    else if gems != { } then
      symlinkJoin {
        name = "${name}-release";
        paths = lib.attrValues gems;
        passthru = {
          projections = releaseProjections;
        };
      }
    else
      throw "bundler-purifier: the project has no gemspec, so it has no release for `bundler-purifier publish` to push.";

  # Every download of the lock, for every system.
  fetches = checkedLock.entries;

  # Each executable that a gemspec of the project declares, run with the
  # app's bundle: `bin/<name>`.
  executables = lib.listToAttrs (
    lib.concatMap (
      gem:
      map (executable: {
        name = executable;
        value = writeShellScriptBin executable ''
          exec ${bundle}/bin/bundle exec ${lib.escapeShellArg executable} "$@"
        '';
      }) gem.executables
    ) lock.gems
  );

  # A shell with the Ruby, git, build tools and libraries of the `app`
  # build, for day-to-day work: native extensions compile in it as they do
  # in the sandbox, and gems that open a library through FFI find it.
  devShell = mkShell {
    packages = [
      ruby'
      gitMinimal
    ]
    ++ nativeBuildInputs
    ++ runtimeInputs;
    LD_LIBRARY_PATH = runtimeLibraryPath;
  };

  environment = {
    PATH = lib.makeBinPath (
      [
        ruby'
        gitMinimal
      ]
      ++ nativeBuildInputs
      ++ runtimeInputs
    );
    LD_LIBRARY_PATH = runtimeLibraryPath;
  };

  inherit gemCache;
}
