# SPDX-License-Identifier: MIT
# Validate the native SDK's observation without parsing or rewriting its YAML.
{
  lib,
  text,
  snapshot,
  bundlerVersion,
  ruby,
}:
let
  exact =
    keys: value: builtins.isAttrs value && builtins.attrNames value == lib.sort builtins.lessThan keys;
  scalar = value: builtins.isString value && value != "" && builtins.match ".*[\r\n].*" value == null;
  spec =
    value:
    exact [ "name" "version" ] value
    && scalar value.name
    && scalar value.version
    && builtins.match ".*[[:space:]].*" value.name == null
    && builtins.match ".*[[:space:]].*" value.version == null;
  source =
    value:
    exact [ "fields" "remotes" "specs" ] value
    && builtins.isAttrs value.fields
    && lib.all scalar (builtins.attrNames value.fields)
    && lib.all scalar (builtins.attrValues value.fields)
    && builtins.isList value.remotes
    && value.remotes != [ ]
    && lib.all scalar value.remotes
    && (value.fields.remote or null) == lib.last value.remotes
    && builtins.isList value.specs
    && lib.all spec value.specs;
  valid =
    exact [ "format" "nativeHash" "observed" "parsed" ] snapshot
    && snapshot.format == "bundler-yaml"
    &&
      snapshot.nativeHash == builtins.convertHash {
        hash = builtins.hashString "sha256" text;
        hashAlgo = "sha256";
        toHashFormat = "sri";
      }
    && exact [ "ruby" "patchlevel" "rubygems" "bundler" "platform" ] snapshot.observed
    && lib.all (key: scalar snapshot.observed.${key}) [
      "ruby"
      "rubygems"
      "bundler"
      "platform"
    ]
    && (
      if snapshot.observed.ruby == "1.8.4" then
        snapshot.observed.patchlevel == null
      else
        builtins.isInt snapshot.observed.patchlevel
    )
    && snapshot.observed.bundler == bundlerVersion
    && snapshot.observed.ruby == ruby
    && exact [
      "gemSources"
      "gitSources"
      "pathSources"
      "checksums"
      "bundledWith"
      "rubyVersion"
    ] snapshot.parsed
    && snapshot.parsed.checksums == { }
    && snapshot.parsed.bundledWith == null
    && snapshot.parsed.rubyVersion == null
    && lib.all (key: builtins.isList snapshot.parsed.${key} && lib.all source snapshot.parsed.${key}) [
      "gemSources"
      "gitSources"
      "pathSources"
    ]
    && lib.all (node: scalar (node.fields.revision or null)) snapshot.parsed.gitSources;
in
{
  problems =
    lib.optional (!valid)
      "bundler-purifier: native YAML snapshot is missing, malformed, stale or conflicts with the recorded SDK. Recapture with the intended native SDK using bundler-purifier lock --force.";
  parsed =
    if valid then
      snapshot.parsed
    else
      {
        gemSources = [ ];
        gitSources = [ ];
        pathSources = [ ];
        checksums = { };
        bundledWith = null;
        rubyVersion = null;
      };
}
