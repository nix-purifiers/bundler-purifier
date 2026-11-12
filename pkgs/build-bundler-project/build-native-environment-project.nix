# SPDX-License-Identifier: MIT
{
  lib,
  stdenv,
  runCommand,
  writeText,
  writeShellScriptBin,
  mkShell,
  fetchurl,
  gitMinimal,
  ruby_3_4,
  nix,
  purifier,
  closureInfo,
  symlinkJoin,
  integrationTools ? ../cli/tools,
}:
{
  src,
  lockFile ? src + "/bundler-purifier.lock.json",
  ruby,
  dependencies ? purifier.lockedProjectInputs {
    inputs = (builtins.fromJSON (builtins.readFile lockFile)).projectInputs;
    system = stdenv.hostPlatform.system;
  },
  name ? "bundler-app",
  checkCommand ? "true",
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  indexRuby ? ruby_3_4,
  projectionRuby ? ruby_3_4,
  fetchers ? { },
  srcFilter ? null,
}:
let
  lock =
    (import ../../lib-overlays/default/read-native-environment-lock.nix { inherit lib; } {
      inherit src lockFile;
    }).lock;
  resolution = lock.nativeResolution;
  legacy = resolution.interface == "environment-v03";
  normalizedSdk = resolution.sdk // {
    components = lib.sort (a: b: a.name < b.name) resolution.sdk.components;
    closure = lib.sort (a: b: a.path < b.path) resolution.sdk.closure;
  };
  nativeSdkIdentity = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON normalizedSdk);
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
  lockedDependencies = purifier.lockedProjectInputs {
    inputs = lock.projectInputs;
    system = stdenv.hostPlatform.system;
  };
  selected = purifier.projectInputs {
    inherit dependencies;
    formats = [ "rubygems" ];
    system = stdenv.hostPlatform.system;
  };
  expected = purifier.projectInputs {
    dependencies = lockedDependencies;
    formats = [ "rubygems" ];
    system = stdenv.hostPlatform.system;
  };
  references = builtins.listToAttrs (
    lib.imap0 (index: input: {
      name = input.reference;
      value = (builtins.elemAt selected index).repository;
    }) lock.projectInputs
  );
  readJson = file: builtins.fromJSON (builtins.readFile file);
  archiveFor =
    archive:
    let
      transport = archive.transport;
    in
    if transport.kind == "vendored" then
      builtins.path {
        path = src + "/${transport.path}";
        name = builtins.baseNameOf transport.path;
      }
    else if transport.kind == "url" then
      (fetchers.fetchurl or fetchurl) {
        url = transport.url;
        hash = archive.sha256;
        name =
          builtins.baseNameOf
            (lib.findFirst (package: package.name == archive.name) null resolution.packages).installedPath
          + ".gem";
      }
    else
      let
        repository = references.${transport.reference};
        catalog = readJson repository.catalog;
        entries = lib.filter (
          entry:
          entry.name == archive.name
          && entry.version == archive.version
          && entry.platform == archive.platform
          && entry.archive == transport.file
        ) catalog.packages;
      in
      assert builtins.length entries == 1;
      "${repository}/${transport.file}";
  archives = builtins.listToAttrs (
    map (archive: {
      name = archive.name;
      value = archiveFor archive;
    }) lock.archives
  );
  available = lib.concatMap (
    input:
    let
      catalog = readJson input.repository.catalog;
    in
    catalog.packages ++ (catalog.intrinsics or [ ])
  ) selected;
  bindingValid =
    binding: lib.any (entry: entry.name == binding.name && entry.version == binding.version) available;
  record = writeText "native-resolution.json" (builtins.toJSON resolution + "\n");
  archiveMap = writeText "native-archives.json" (builtins.toJSON archives);
  closure = closureInfo { rootPaths = [ ruby ]; };
  filteredSrc = builtins.path {
    path = src;
    name = "${name}-source";
    filter =
      path: type:
      let
        relative = lib.removePrefix (toString src + "/") (toString path);
      in
      !(
        lib.hasPrefix ".git/" relative
        || relative == ".git"
        || lib.hasPrefix ".bundler-purifier/" relative
        || relative == ".bundler-purifier"
        || lib.hasPrefix ".bundle/" relative
        || relative == ".bundle"
        || lib.hasPrefix "vendor/gems/" relative
        || relative == "vendor/gems"
      )
      && (srcFilter == null || srcFilter path type);
  };
  app = stdenv.mkDerivation {
    inherit name;
    src = filteredSrc;
    nativeBuildInputs = [
      ruby_3_4
      nix
      gitMinimal
    ]
    ++ nativeBuildInputs;
    inherit buildInputs;
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      export HOME=$TMPDIR NIX_CONFIG='experimental-features = nix-command'
      mkdir -p "$out"
      ${ruby_3_4}/bin/ruby ${integrationTools}/native_environment_prepare.rb regenerate \
        ${record} ${ruby} ${archiveMap} "$out/project" ${closure}/store-paths > "$out/native-resolution.json"
      cp -r --no-preserve=mode ./. "$out/project/"
    '';
    doCheck = false;
    checkPhase = ''
      cd "$out/project"
      ${ruby}/bin/ruby ${integrationTools}/native_environment_exec.rb "$PWD" ${ruby} -- ${stdenv.shell} -c ${lib.escapeShellArg checkCommand}
    '';
    installPhase = "true";
    passthru = {
      inherit ruby;
      projectDir = "project";
    };
  };
  executor = writeShellScriptBin "bundler-purifier-exec" ''
    exec ${ruby}/bin/ruby ${integrationTools}/native_environment_exec.rb ${app}/project ${ruby} -- "$@"
  '';
  gems = builtins.listToAttrs (
    map (
      spec:
      let
        filename = spec.fullName + ".gem";
        package = stdenv.mkDerivation {
          pname = spec.name;
          inherit (spec) version;
          src = filteredSrc;
          nativeBuildInputs = [
            ruby
            gitMinimal
          ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            git init -q
            git add -A
            cd ${lib.escapeShellArg (dirOf spec.path)}
            ${ruby}/bin/ruby ${integrationTools}/native_environment_exec.rb ${app}/project ${ruby} -- \
              ${ruby}/bin/ruby -r ${purifier.rubygemsCodecCompatibility} ${integrationTools}/build_gem.rb \
              ${lib.escapeShellArg (baseNameOf spec.path)} ${lib.escapeShellArg filename}
          '';
          installPhase = ''mkdir -p "$out"; cp ${lib.escapeShellArg filename} "$out/"'';
          passthru.gemFile = "${package}/${filename}";
        };
      in
      {
        name = spec.name;
        value = package;
      }
    ) lock.projectSpecs
  );
  views = map (input: {
    repository = toString input.repository;
    catalog = input.repository.catalog;
  }) selected;
  capturedGems =
    runCommand "${name}-runtime-gems"
      {
        nativeBuildInputs = [
          ruby
          gitMinimal
        ];
        ownArchives = builtins.toJSON (map (gem: gem.gemFile) (builtins.attrValues gems));
        projectRoots = builtins.toJSON (map (spec: spec.name) lock.projectSpecs);
        projectDirectories = builtins.toJSON (
          builtins.listToAttrs (
            map (spec: {
              name = spec.name;
              value = dirOf spec.path;
            }) lock.projectSpecs
          )
        );
        inputViews = builtins.toJSON views;
      }
      ''
        export HOME=$TMPDIR
        ${
          if legacy then
            "cd ${app}/project"
          else
            ''
              mkdir project
              cp -r --no-preserve=mode ${app}/project/. project/
              cd project
            ''
        }
        export BUNDLER_PURIFIER_OWN_ARCHIVES="$ownArchives"
        export BUNDLER_PURIFIER_PROJECT_ROOTS="$projectRoots"
        export BUNDLER_PURIFIER_PROJECT_DIRECTORIES="$projectDirectories"
        export BUNDLER_PURIFIER_INPUT_VIEWS="$inputViews"
        ${ruby}/bin/ruby ${integrationTools}/native_environment_exec.rb "$PWD" ${ruby} -- \
          ${ruby}/bin/ruby -r ${purifier.rubygemsCodecCompatibility} ${integrationTools}/capture_gems.rb "$out"
      '';
  projectionFor =
    roots:
    purifier.rubygemsProjections (
      {
        archives = map (archive: "${capturedGems}/${archive}") (readJson "${capturedGems}/archives.json");
        producer = app;
        inherit dependencies runCommand roots;
        intrinsics = readJson "${capturedGems}/intrinsics.json";
        ruby = projectionRuby;
        inherit indexRuby;
        name = "${name}-rubygems-repository";
      }
      // lib.optionalAttrs legacy {
        versionScheme = "legacy-numeric-v1";
        inherit nativeSdkIdentity;
        legacyIndexRuby = ruby;
      }
    );
  projections = projectionFor (map (spec: spec.name) lock.projectSpecs);
  release =
    if builtins.length lock.projectSpecs == 1 then
      (builtins.head (builtins.attrValues gems)) // { inherit projections; }
    else if lock.projectSpecs != [ ] then
      symlinkJoin {
        name = "${name}-release";
        paths = builtins.attrValues gems;
        passthru = { inherit projections; };
      }
    else
      throw "bundler-purifier: this project has no gemspec to publish";
  executables = builtins.listToAttrs (
    lib.concatMap (
      spec:
      map (executable: {
        name = executable;
        value = writeShellScriptBin executable ''
          exec ${ruby}/bin/ruby ${integrationTools}/native_environment_exec.rb ${app}/project ${ruby} -- \
            ${ruby}/bin/ruby -I${app}/project/${dirOf spec.path}/lib ${app}/project/${dirOf spec.path}/${spec.bindir}/${executable} "$@"
        '';
      }) spec.executables
    ) lock.projectSpecs
  );
in
assert map (input: input.identity) selected == map (input: input.identity) expected;
assert lib.all bindingValid resolution.bindings;
{
  inherit projections release executables;
  packages = lib.mapAttrs (name: gem: gem // { projections = projectionFor [ name ]; }) gems // {
    app = app // {
      inherit projections;
    };
    bundle = executor // {
      inherit projections;
    };
  };
  tests = app.overrideAttrs (_: {
    name = "${name}-tests";
    doCheck = true;
  });
  devShell = mkShell {
    packages = [
      ruby
      gitMinimal
      executor
    ]
    ++ nativeBuildInputs
    ++ buildInputs;
  };
  environment = {
    PATH = lib.makeBinPath (
      [
        ruby
        gitMinimal
        executor
      ]
      ++ nativeBuildInputs
    );
  };
  gemCache = runCommand "${name}-native-cache" { } ''
    mkdir -p "$out"
    ${lib.concatMapStringsSep "\n" (
      archive:
      "cp ${lib.escapeShellArg (toString (archiveFor archive))} \"$out/${
        builtins.baseNameOf
          (lib.findFirst (package: package.name == archive.name) null resolution.packages).installedPath
      }.gem\""
    ) lock.archives}
  '';
  inherit indexRuby projectionRuby;
}
