# SPDX-License-Identifier: MIT
# Dedicated Ruby v4 reader; the v3 reader retains its existing contract.
{ lib }:
{
  src,
  lockFile ? src + "/bundler-purifier.lock.json",
}:
let
  text = builtins.readFile lockFile;
  bounded = builtins.stringLength text <= 16777216;
  value =
    if bounded then
      builtins.fromJSON text
    else
      throw "bundler-purifier: native lock exceeds size limit";
  exact =
    keys: item: builtins.isAttrs item && builtins.attrNames item == lib.sort builtins.lessThan keys;
  scalar =
    item:
    builtins.isString item
    && item != ""
    && builtins.stringLength item <= 4096
    && builtins.match ".*[[:cntrl:]].*" item == null;
  filename =
    item:
    scalar item
    && builtins.match ".*[[:space:]/\\].*" item == null
    && !(lib.elem item [
      "."
      ".."
    ]);
  digest =
    item:
    builtins.isString item && builtins.match "sha256-[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=" item != null;
  list = item: builtins.isList item && builtins.length item <= 4096;
  unique = items: builtins.length (lib.unique items) == builtins.length items;
  relative =
    item:
    scalar item
    && !(lib.hasPrefix "/" item)
    && !(lib.hasInfix "\\" item)
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" item);
  hash =
    bytes:
    builtins.convertHash {
      hash = builtins.hashString "sha256" bytes;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  resolution = value.nativeResolution;
  native = import ./native-environment.nix { inherit lib; } resolution;
  definition = hash (
    lib.concatMapStrings (
      record:
      "${record.path}\n${toString record.size}\n" + import ./native-environment-bytes.nix record + "\n"
    ) (lib.sort (a: b: a.path < b.path) resolution.manifests)
  );
  input =
    item:
    exact [ "reference" "url" "narHash" "attribute" ] item
    && lib.all (key: scalar item.${key}) [
      "reference"
      "url"
      "attribute"
    ]
    && digest item.narHash;
  transport =
    item:
    builtins.isAttrs item
    && (
      if (item.kind or null) == "vendored" then
        exact [ "kind" "path" ] item && relative item.path
      else if (item.kind or null) == "nix" then
        exact [ "kind" "reference" "file" ] item
        && relative item.file
        && lib.any (entry: entry.reference == item.reference) value.projectInputs
      else if (item.kind or null) == "url" then
        exact [ "kind" "url" ] item
        && scalar item.url
        && builtins.match "[ -~]*" item.url != null
        && builtins.match "https?://[^/?#[:space:]]+(/[^#[:space:]]*)?(\\?[^#[:space:]]*)?" item.url != null
      else
        false
    );
  archive =
    item:
    exact [ "name" "version" "platform" "sha256" "transport" ] item
    && transport item.transport
    && lib.any (
      package:
      lib.all (key: package.${key} == item.${key}) [
        "name"
        "version"
        "platform"
      ]
      && package.archiveHash == item.sha256
    ) resolution.packages;
  dependency =
    item:
    exact [ "name" "type" "requirements" ] item
    && filename item.name
    && lib.elem item.type [
      "runtime"
      "development"
    ]
    && list item.requirements
    && item.requirements != [ ]
    && lib.all scalar item.requirements
    && unique item.requirements;
  projectSpec =
    item:
    exact [
      "path"
      "name"
      "version"
      "platform"
      "fullName"
      "executables"
      "bindir"
      "requirePaths"
      "dependencies"
    ] item
    && relative item.path
    && lib.hasSuffix ".gemspec" item.path
    && lib.all (key: filename item.${key}) [
      "name"
      "version"
      "platform"
      "fullName"
    ]
    && list item.executables
    && lib.all filename item.executables
    && unique item.executables
    && list item.requirePaths
    && lib.all (path: path == "." || relative path) item.requirePaths
    && (item.bindir == null || item.bindir == "." || relative item.bindir)
    && list item.dependencies
    && lib.all dependency item.dependencies
    && unique (
      map (entry: [
        entry.name
        entry.type
      ]) item.dependencies
    );
  currentManifest =
    record:
    let
      path = src + "/${record.path}";
    in
    builtins.pathExists path && hash (builtins.readFile path) == record.sha256;
  gemspecs =
    prefix: directory:
    let
      entries = builtins.readDir directory;
    in
    lib.concatMap (
      name:
      let
        kind = entries.${name};
        relativeName = prefix + name;
      in
      if lib.hasPrefix "." name || (prefix == "" && name == "vendor") then
        [ ]
      else if kind == "directory" then
        gemspecs (relativeName + "/") (directory + "/${name}")
      else
        lib.optional (lib.hasSuffix ".gemspec" name) relativeName
    ) (builtins.attrNames entries);
  currentManifests = [
    "Gemfile"
  ]
  ++ gemspecs "" src
  ++ lib.optional (builtins.pathExists (src + "/.ruby-version")) ".ruby-version";
  valid =
    exact [
      "version"
      "contentHash"
      "definitionHash"
      "nativeResolution"
      "projectInputs"
      "archives"
      "projectSpecs"
    ] value
    && text == builtins.toJSON value + "\n"
    && builtins.isInt value.version
    && value.version == 4
    && digest value.contentHash
    && value.contentHash == hash (builtins.toJSON (builtins.removeAttrs value [ "contentHash" ]))
    && native.valid
    && value.definitionHash == definition
    && !(builtins.hasAttr "Gemfile.lock" (builtins.readDir src))
    && lib.all currentManifest resolution.manifests
    &&
      lib.sort builtins.lessThan currentManifests
      == lib.sort builtins.lessThan (map (entry: entry.path) resolution.manifests)
    && list value.projectInputs
    && lib.all input value.projectInputs
    && unique (map (entry: entry.reference) value.projectInputs)
    && (resolution.bindings == [ ] || value.projectInputs != [ ])
    && list value.archives
    && lib.all archive value.archives
    && unique (map (entry: entry.name) value.archives)
    &&
      lib.sort builtins.lessThan (map (entry: entry.name) value.archives)
      == lib.sort builtins.lessThan (map (entry: entry.name) resolution.packages)
    && lib.all (
      binding: lib.all (entry: entry.name != binding.name || entry.transport.kind == "nix") value.archives
    ) resolution.bindings
    && list value.projectSpecs
    && lib.all projectSpec value.projectSpecs
    && unique (map (entry: entry.name) value.projectSpecs)
    && unique (map (entry: entry.path) value.projectSpecs)
    &&
      lib.sort builtins.lessThan (map (entry: entry.path) value.projectSpecs)
      == lib.sort builtins.lessThan (
        map (entry: entry.path) (
          lib.filter (entry: lib.hasSuffix ".gemspec" entry.path) resolution.manifests
        )
      );
in
if valid then
  {
    lock = value;
    problems = [ ];
  }
else
  throw "bundler-purifier: malformed or stale pre-lockfile v4 lock; recapture with the intended native SDK"
