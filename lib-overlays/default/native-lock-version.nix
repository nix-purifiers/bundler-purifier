# SPDX-License-Identifier: MIT
# Keep truncated files on the ordinary reader's diagnostic path. Nix JSON
# parse failures cannot be caught by tryEval.
file:
let
  exists = builtins.pathExists file;
  text = if exists then builtins.readFile file else "";
  length = builtins.stringLength text;
  start = if length > 64 then length - 64 else 0;
  whole =
    builtins.match "[[:space:]]*\\{.*" (builtins.substring 0 64 text) != null
    && builtins.match ".*}[[:space:]]*" (builtins.substring start 64 text) != null;
  parsed = if exists && whole then builtins.fromJSON text else null;
in
if builtins.isAttrs parsed then parsed.version or null else null
