# SPDX-License-Identifier: MIT
#
# Reads a Gemfile.lock with Nix's string functions, at evaluation and
# without building anything. Gemfile.lock is Bundler's own text format, a
# sequence of blocks separated by blank lines, each opened by a header
# line:
#
#   GEM / GIT / PATH  a source: `  key: value` lines, then `  specs:` and a
#                     line `    name (version[-platform])` per gem, with
#                     its dependencies indented further
#   CHECKSUMS         `  name (version[-platform]) sha256=<hex>` per gem
#                     (Bundler 2.5 and later, with --add-checksums or by
#                     default from Bundler 4)
#   RUBY VERSION      `   ruby <version>`
#   BUNDLED WITH      `   <version>`
#
# The result has `gemSources`, `gitSources` and `pathSources` (each
# { fields, remotes, specs }), `checksums` (the hex SHA-256 by
# "name (version)"), `bundledWith` and `rubyVersion`.
{ lib, text }:
let
  blocks = builtins.filter (b: builtins.isString b && b != "") (
    builtins.split "\n[[:space:]]*\n" text
  );
  linesOf = block: builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" block);
  headerOf = block: lib.head (linesOf block);
  bodyOf = block: lib.tail (linesOf block);
  blocksNamed = header: builtins.filter (b: headerOf b == header) blocks;

  source =
    block:
    let
      body = bodyOf block;
      fieldLines = builtins.filter (m: m != null) (map (builtins.match "  ([a-z_]+): (.*)") body);
      specLines = builtins.filter (m: m != null) (map (builtins.match "    ([^ ]+) \\(([^)]+)\\)") body);
    in
    {
      fields = builtins.listToAttrs (
        map (m: {
          name = builtins.elemAt m 0;
          value = builtins.elemAt m 1;
        }) fieldLines
      );
      remotes = map (m: builtins.elemAt m 1) (
        builtins.filter (m: builtins.elemAt m 0 == "remote") fieldLines
      );
      specs = map (m: {
        name = builtins.elemAt m 0;
        version = builtins.elemAt m 1;
      }) specLines;
    };

  checksumLines = lib.concatMap (
    block:
    builtins.filter (m: m != null && builtins.elemAt m 2 != null) (
      map (builtins.match "  ([^ ]+ \\([^)]+\\))( sha256=([0-9a-f]+))?.*") (bodyOf block)
    )
  ) (blocksNamed "CHECKSUMS");

  single =
    header: pattern:
    let
      found = lib.concatMap (
        block: builtins.filter (m: m != null) (map (builtins.match pattern) (bodyOf block))
      ) (blocksNamed header);
    in
    if found == [ ] then null else lib.head (lib.head found);
in
{
  gemSources = map source (blocksNamed "GEM");
  gitSources = map source (blocksNamed "GIT");
  pathSources = map source (blocksNamed "PATH");
  checksums = builtins.listToAttrs (
    map (m: {
      name = builtins.elemAt m 0;
      value = builtins.elemAt m 2;
    }) checksumLines
  );
  bundledWith = single "BUNDLED WITH" " *([0-9][^ ]*) *";
  rubyVersion = single "RUBY VERSION" " *ruby ([0-9]+\\.[0-9]+(\\.[0-9]+)?).*";
}
