# SPDX-License-Identifier: MIT
#
# readLock: the lock of a Bundler project in memory, in the shape of the
# nix-purifiers contract, from its Gemfile.lock and the purifier lockfile
# that `bundler-purifier lock` writes:
#
#   purifier  "bundler-purifier"
#   entries   the download entries of the shared library: a file entry per
#             gem file and for Bundler's own gem, and a git entry per git
#             checkout; a gem built for one platform carries `systems`,
#             the Nix systems it installs on (none for x86_64 darwin or
#             musl)
#   outputs   the outputs the builder makes: `app`, `bundle`, and a gem per
#             gemspec of the project, with its version and executables
#   problems  why the lockfiles cannot be used, each naming the fix: a
#             stale, tampered, malformed or incomplete lockfile, or a
#             missing Gemfile.lock or external path source
#   bundlerLock
#             what the builder reads besides: the Ruby of the lock run,
#             Bundler's version, the project's gems and its external path
#             sources
#
# Gemfile.lock records most of what a build downloads, and gemfile-lock.nix
# reads it: each gem file's name and source, each gem's SHA-256 in its
# CHECKSUMS section when it has one, and each git source's URL, revision and
# submodules. The purifier lockfile holds only what Gemfile.lock lacks:
#
#   definitionHash  the hash of the Gemfile, Gemfile.lock and gemspecs it
#                   was made from, to tell a stale lock
#   ruby            the Ruby version the lock run used
#   bundlerVersion  the actual native SDK version, only when the native
#                   lock predates BUNDLED WITH
#   bundlerHash     the hash of the selected Bundler gem,
#                   which CHECKSUMS never lists
#   gemHashes       the hash of each gem file that CHECKSUMS does not list,
#                   by file name
#   gemSources      the remote of each gem file whose GEM section names
#                   several remotes, by file name
#   mirrors         the other URLs of a gem file, from Bundler's mirror
#                   configuration, by file name, for the files that have
#                   any
#   gitHashes       the hash nix-prefetch-git reports for each git
#                   checkout, by revision
#   executables     the executables each gemspec of the project declares,
#                   by gem name, since gemspecs are Ruby
#   contentHash     the hash of the lockfile itself
{ lib }:
{
  # The root of the Bundler project, where the Gemfile is.
  src,
  # The purifier lockfile; it may lie outside `src`.
  lockFile ? src + "/bundler-purifier.lock.json",
  # The project's Gemfile.lock; a copy outside `src` takes the place of the
  # one in `src`.
  gemfileLock ? src + "/Gemfile.lock",
  # The trees of the path sources outside the project, by the path
  # Gemfile.lock gives them.
  externalPaths ? { },
  providedGems ? [ ],
}:
let
  lockName = baseNameOf (toString lockFile);
  relock = "Run `bundler-purifier lock --force`.";

  # A file of the project, read without copying the whole project into the
  # store first.
  srcFile = rel: if builtins.isPath src then src + "/${rel}" else "${src}/${rel}";

  # The purifier lockfile, or null with a problem when it cannot be read.
  # Nix's JSON parser fails with a message that names neither the file nor
  # the fix, so a truncated or emptied file is told apart first.
  lockExists = builtins.pathExists lockFile;
  text = if lockExists then builtins.readFile lockFile else "";
  length = builtins.stringLength text;
  whole =
    builtins.match "[[:space:]]*\\{.*" (builtins.substring 0 64 text) != null
    && builtins.match ".*}[[:space:]]*" (builtins.substring (length - 64) 64 text) != null;
  parsed =
    if lockExists && whole then builtins.fromJSON (builtins.unsafeDiscardStringContext text) else null;

  supportedVersion = import ./lock-version.nix;
  # The hash `bundler-purifier lock` writes as contentHash: SHA-256 of the
  # JSON of the lock without contentHash, as builtins.toJSON writes it.
  contentHashOf =
    lock:
    builtins.convertHash {
      hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  lockProblems =
    if !lockExists then
      [
        "bundler-purifier: there is no ${toString lockFile}. Run `bundler-purifier lock` in the project root."
      ]
    else if parsed == null then
      [
        "bundler-purifier: ${lockName} is not a whole JSON object; it was cut short or overwritten. ${relock}"
      ]
    else if (parsed.version or null) != supportedVersion then
      [
        "bundler-purifier: ${lockName} has lock format version ${
          toString (parsed.version or "none")
        }; this library reads version ${toString supportedVersion}. ${relock}"
      ]
    else if (parsed.contentHash or null) != contentHashOf parsed then
      [
        "bundler-purifier: ${lockName} was changed by hand: its content does not match its contentHash. ${relock}"
      ]
    else
      [ ];
  purifierLock = if lockProblems == [ ] then parsed else { };

  gemfileLockPath = gemfileLock;
  hasGemfileLock = builtins.pathExists gemfileLockPath;
  gemfileLockProblems =
    lib.optional (!hasGemfileLock)
      "bundler-purifier: the project has no Gemfile.lock. Run `bundler-purifier lock` in the project root.";
  gemfileLockData = import ./gemfile-lock.nix {
    inherit lib;
    text = if hasGemfileLock then builtins.readFile gemfileLockPath else "";
  };

  # A path source is outside the project when its path climbs out of the
  # project root or is absolute.
  isOutside = remote: lib.hasPrefix "/" remote || remote == ".." || lib.hasPrefix "../" remote;
  externalPathList = lib.sort (a: b: a < b) (
    lib.unique (builtins.filter isOutside (map (s: lib.head s.remotes) gemfileLockData.pathSources))
  );
  missingExternal = lib.filter (p: !(externalPaths ? ${p})) externalPathList;
  externalProblems =
    lib.optional (missingExternal != [ ])
      "bundler-purifier: Gemfile.lock has path sources outside the project (${lib.concatStringsSep ", " missingExternal}); pass their trees as `externalPaths`.";

  # The definition hash of the project as it is now, computed as
  # `bundler-purifier lock` computes it (see definition_hash there): the
  # Gemfile, Gemfile.lock, every gemspec outside hidden directories and
  # vendor/, and the gemspecs at the top of each external path source.
  gemspecsIn =
    dir: rel:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        let
          path = if rel == "" then name else "${rel}/${name}";
        in
        if lib.hasPrefix "." name then
          [ ]
        else if type == "directory" then
          (if path == "vendor" then [ ] else gemspecsIn "${dir}/${name}" path)
        else if lib.hasSuffix ".gemspec" name then
          [ path ]
        else
          [ ]
      ) (builtins.readDir dir)
    );
  definitionFiles =
    map (rel: {
      inherit rel;
      file = srcFile rel;
    }) ([ "Gemfile" ] ++ gemspecsIn (srcFile "") "")
    ++ lib.optional hasGemfileLock {
      rel = "Gemfile.lock";
      file = gemfileLockPath;
    }
    ++ lib.concatMap (
      p:
      map
        (name: {
          rel = "${p}/${name}";
          file = "${externalPaths.${p}}/${name}";
        })
        (
          lib.attrNames (
            lib.filterAttrs (name: type: type != "directory" && lib.hasSuffix ".gemspec" name) (
              builtins.readDir externalPaths.${p}
            )
          )
        )
    ) (lib.filter (p: externalPaths ? ${p}) externalPathList);
  definitionHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (
      lib.concatMapStrings (
        f:
        let
          content = builtins.readFile f.file;
        in
        "${f.rel}\n${toString (builtins.stringLength content)}\n${content}\n"
      ) (lib.sort (a: b: a.rel < b.rel) (lib.unique definitionFiles))
    );
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
  staleProblems =
    lib.optional
      (lockProblems == [ ] && hasGemfileLock && purifierLock.definitionHash != definitionHash)
      "bundler-purifier: the Gemfile, Gemfile.lock or a gemspec changed since ${lockName} was made. Run `bundler-purifier lock` in the project root.";

  sri =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  withSlash = url: if lib.hasSuffix "/" url then url else "${url}/";

  # The Nix systems a gem built for a platform installs on: Linux on
  # x86_64 or aarch64 with glibc, and macOS on arm64. A gem for any other
  # platform (x86_64 darwin, a darwin of one macOS version, musl, 32-bit
  # ARM, Windows) installs on none of them.
  systemsOf =
    platform:
    if
      lib.elem platform [
        "x86_64-linux"
        "x86_64-linux-gnu"
      ]
    then
      [ "x86_64-linux" ]
    else if
      lib.elem platform [
        "aarch64-linux"
        "aarch64-linux-gnu"
      ]
    then
      [ "aarch64-linux" ]
    else if platform == "arm64-darwin" then
      [ "aarch64-darwin" ]
    else
      [ ];

  # Each gem file, with its hash or null when neither file holds one.
  gemFile =
    remotes: spec:
    let
      file = "${spec.name}-${spec.version}.gem";
      key = "${spec.name} (${spec.version})";
      # A gem version has no `-`, so what follows the first one is the
      # platform.
      platform = builtins.match "[^-]+-(.+)" spec.version;
      remote =
        if lib.length remotes == 1 then lib.head remotes else purifierLock.gemSources.${file} or null;
    in
    {
      path = file;
      url = if remote == null then null else "${withSlash remote}gems/${file}";
      mirrors = purifierLock.mirrors.${file} or [ ];
      hash =
        if gemfileLockData.checksums ? ${key} then
          sri gemfileLockData.checksums.${key}
        else
          purifierLock.gemHashes.${file} or null;
      missing =
        if remote == null then
          "a source for ${file}, whose GEM section names several remotes"
        else
          "a hash for ${file}";
    }
    // lib.optionalAttrs (platform != null) { systems = systemsOf (lib.head platform); };

  recordedBundler = purifierLock.bundlerVersion or null;
  validRecordedBundler =
    builtins.isString recordedBundler && builtins.match "[0-9][0-9A-Za-z.+-]*" recordedBundler != null;
  bundler =
    if gemfileLockData.bundledWith != null then
      gemfileLockData.bundledWith
    else if validRecordedBundler then
      recordedBundler
    else
      null;
  bundlerProblems = lib.optionals (lockProblems == [ ] && hasGemfileLock) (
    lib.optional (recordedBundler != null && !validRecordedBundler)
      "bundler-purifier: ${lockName} has an invalid bundlerVersion. Recapture with the intended native SDK: bundler-purifier lock --force."
    ++
      lib.optional
        (
          gemfileLockData.bundledWith != null
          && recordedBundler != null
          && recordedBundler != gemfileLockData.bundledWith
        )
        "bundler-purifier: ${lockName} bundlerVersion conflicts with native BUNDLED WITH. Recapture with the intended native SDK."
    ++
      lib.optional (bundler == null)
        "bundler-purifier: Gemfile.lock has no BUNDLED WITH and ${lockName} lacks bundlerVersion. Recapture with the intended native SDK: bundler-purifier lock --force."
  );
  bundlerFile = "bundler-${bundler}.gem";

  rawFiles =
    lib.concatMap (
      source:
      map (gemFile source.remotes) (
        builtins.filter (spec: !(lib.elem spec.name providedGems)) source.specs
      )
    ) gemfileLockData.gemSources
    ++ lib.optional (bundler != null) {
      path = bundlerFile;
      url = "https://rubygems.org/gems/${bundlerFile}";
      mirrors = purifierLock.mirrors.${bundlerFile} or [ ];
      hash = purifierLock.bundlerHash or null;
      missing = "a hash for Bundler's gem";
    };

  # A git source over SSH is fetched from the HTTPS URL of the same host and
  # path, since the Nix sandbox has no SSH keys, as the lock run records it.
  httpsGitUrl =
    url:
    let
      ssh = builtins.match "ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/(.+)" url;
      scp = builtins.match "([^@/]+@)?([^/:]+):([^/].*)" url;
    in
    if ssh != null then
      "https://${builtins.elemAt ssh 1}/${builtins.elemAt ssh 3}"
    else if scp != null && builtins.match "[a-z]+://.*" url == null then
      "https://${builtins.elemAt scp 1}/${builtins.elemAt scp 2}"
    else
      url;

  # The directory Bundler caches a git source in: the last component of its
  # URL without .git, and the first twelve characters of the revision.
  rawGitCheckouts = lib.unique (
    map
      (
        source:
        let
          remote = lib.head source.remotes;
          rev = source.fields.revision;
        in
        {
          path = "${lib.removeSuffix ".git" (baseNameOf (lib.removeSuffix "/" remote))}-${builtins.substring 0 12 rev}";
          git = {
            url = httpsGitUrl remote;
            inherit rev;
            submodules = (source.fields.submodules or "false") == "true";
            leaveDotGit = false;
            commitObject = null;
          };
          hash = purifierLock.gitHashes.${rev} or null;
          missing = "a hash for the git checkout ${remote} at ${rev}";
        }
      )
      (
        builtins.filter (
          source: lib.any (spec: !(lib.elem spec.name providedGems)) source.specs
        ) gemfileLockData.gitSources
      )
  );

  raw = rawFiles ++ rawGitCheckouts;
  incomplete = builtins.filter (e: e.hash == null || (e ? url && e.url == null)) raw;
  missingProblems =
    lib.optional (lockProblems == [ ] && incomplete != [ ])
      "bundler-purifier: ${lockName} lacks ${(lib.head incomplete).missing}, which Gemfile.lock needs. Run `bundler-purifier lock`.";

  problems =
    lockProblems
    ++ gemfileLockProblems
    ++ bundlerProblems
    ++ externalProblems
    ++ staleProblems
    ++ missingProblems;

  gems = lib.concatMap (
    source:
    let
      remote = lib.head source.remotes;
    in
    lib.optionals (!isOutside remote) (
      map (spec: {
        inherit (spec) name version;
        dir = if remote == "." || remote == "./" then "." else lib.removeSuffix "/" remote;
        executables = purifierLock.executables.${spec.name} or [ ];
      }) source.specs
    )
  ) gemfileLockData.pathSources;
in
{
  purifier = "bundler-purifier";

  entries = if problems == [ ] then map (e: builtins.removeAttrs e [ "missing" ]) raw else [ ];

  outputs = {
    app = {
      kind = "app";
    };
    bundle = {
      kind = "bundle";
    };
  }
  // builtins.listToAttrs (
    map (gem: {
      inherit (gem) name;
      value = {
        kind = "gem";
        inherit (gem) version executables;
      };
    }) gems
  );

  inherit problems;

  bundlerLock = {
    ruby = purifierLock.ruby or null;
    inherit bundler gems;
    externalPaths = externalPathList;
  };
}
