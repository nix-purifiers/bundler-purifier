# SPDX-License-Identifier: MIT
# Ruby-owned pre-lockfile record. No v3 reader/writer dispatch changes here.
{ lib }:
value:
let
  exact =
    keys: item: builtins.isAttrs item && builtins.attrNames item == lib.sort builtins.lessThan keys;
  scalar =
    item:
    builtins.isString item
    && item != ""
    && builtins.stringLength item <= 4096
    && builtins.match ".*[[:cntrl:]].*" item == null;
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
  snapshot =
    item:
    exact [ "path" "size" "sha256" "base64" ] item
    && relative item.path
    && digest item.sha256
    && (
      let
        result = builtins.tryEval (builtins.stringLength (import ./native-environment-bytes.nix item));
      in
      result.success
    );
  component =
    item:
    exact [ "name" "version" "archiveHash" "libraryHash" ] item
    && scalar item.name
    && scalar item.version
    && digest item.archiveHash
    && digest item.libraryHash;
  report = item: exact [ "name" "value" ] item && scalar item.value;
  sdk =
    item:
    exact [
      "ruby"
      "patchlevel"
      "abi"
      "platform"
      "interpreter"
      "components"
      "clientArtifact"
      "clientReport"
      "rubygemsReport"
    ] item
    && lib.all (key: scalar item.${key}) [
      "ruby"
      "abi"
      "platform"
    ]
    && (
      if item.ruby == "1.8.4" then
        item.patchlevel == null
      else
        builtins.isInt item.patchlevel && item.patchlevel >= -1 && item.patchlevel <= 1000000
    )
    && digest item.interpreter
    && list item.components
    && item.components != [ ]
    && lib.all component item.components
    && unique (map (entry: entry.name) item.components)
    && lib.all (name: lib.any (entry: entry.name == name) item.components) [
      "ruby"
      "rubygems"
      "bundler"
      "json"
    ]
    && component item.clientArtifact
    && item.clientArtifact.name == "bundler"
    && item.clientArtifact.version == "0.8.1"
    && lib.elem item.clientArtifact item.components
    && report item.clientReport
    &&
      item.clientReport == {
        name = "Bundler::VERSION";
        value = "0.8.1";
      }
    && report item.rubygemsReport
    &&
      item.rubygemsReport == {
        name = "Gem::VERSION";
        value = "1.3.5";
      }
    && lib.any (entry: entry.name == "rubygems" && entry.version == "1.3.5") item.components;
  clauses = items: list items && items != [ ] && lib.all scalar items && unique items;
  dependency =
    item:
    exact [ "name" "requirements" "type" ] item
    && scalar item.name
    && lib.elem item.type [
      "runtime"
      "development"
    ]
    && clauses item.requirements;
  package =
    item:
    exact [
      "name"
      "version"
      "platform"
      "dependencies"
      "archiveHash"
      "installedPath"
      "sourceKind"
    ] item
    && lib.all (key: scalar item.${key}) [
      "name"
      "version"
      "platform"
    ]
    && digest item.archiveHash
    && relative item.installedPath
    && item.sourceKind == "verified-cache"
    && list item.dependencies
    && lib.all dependency item.dependencies
    && unique (
      map (entry: [
        entry.name
        entry.type
      ]) item.dependencies
    );
  root = item: exact [ "name" "requirements" ] item && scalar item.name && clauses item.requirements;
  evidence = value.manifests ++ value.snapshots;
  aggregate =
    list value.manifests
    && list value.snapshots
    && lib.all (
      item:
      builtins.isAttrs item
      && builtins.isString (item.base64 or null)
      && builtins.isInt (item.size or null)
      && item.size >= 0
      && item.size <= 1048576
    ) evidence
    && lib.foldl' (sum: item: sum + builtins.stringLength item.base64) 0 evidence <= 8388608
    && lib.foldl' (sum: item: sum + item.size) 0 evidence <= 6291456;
  reachable = builtins.genericClosure {
    startSet = map (entry: { key = entry.name; }) value.rootRequirements;
    operator =
      item:
      let
        selected = lib.findFirst (entry: entry.name == item.key) null value.packages;
      in
      map (dep: { key = dep.name; }) (lib.filter (dep: dep.type == "runtime") selected.dependencies);
  };
  valid =
    exact [
      "format"
      "schemaVersion"
      "interface"
      "nativeLockFile"
      "contexts"
      "sdk"
      "manifests"
      "snapshots"
      "packages"
      "rootRequirements"
    ] value
    && aggregate
    && builtins.stringLength (builtins.toJSON value) <= 16777216
    && value.format == "bundler-native-environment"
    && builtins.isInt value.schemaVersion
    && value.schemaVersion == 1
    && value.interface == "environment-v08"
    && value.nativeLockFile == null
    && value.contexts == [ "default" ]
    && sdk value.sdk
    &&
      lib.all
        (
          key:
          list value.${key}
          && value.${key} != [ ]
          && lib.all snapshot value.${key}
          && unique (map (entry: entry.path) value.${key})
        )
        [
          "manifests"
          "snapshots"
        ]
    && lib.any (entry: entry.path == "Gemfile") value.manifests
    && list value.packages
    && lib.all package value.packages
    && unique (map (entry: entry.name) value.packages)
    && list value.rootRequirements
    && lib.all root value.rootRequirements
    && unique (map (entry: entry.name) value.rootRequirements)
    && lib.all (
      entry: lib.any (selected: selected.name == entry.name) value.packages
    ) value.rootRequirements
    && lib.all (
      entry:
      lib.all (
        dep: dep.type != "runtime" || lib.any (selected: selected.name == dep.name) value.packages
      ) entry.dependencies
    ) value.packages
    && builtins.length reachable == builtins.length value.packages;
in
{
  inherit valid;
  problems = lib.optional (
    !valid
  ) "bundler-purifier: invalid pre-lockfile native environment; recapture with the intended SDK";
}
