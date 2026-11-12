# SPDX-License-Identifier: MIT
# Decode bounded native Ruby text evidence for its byte hash. The resulting
# string is evidence only; it is never imported or evaluated as Nix/Ruby code.
snapshot:
let
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  mod = a: b: a - (builtins.div a b) * b;
  # This table contains bytes 1..255 in numeric order. JSON Unicode escapes
  # cannot represent arbitrary single bytes; native Ruby 1.8 source can.
  bytesTable = builtins.readFile ./native-environment-byte-table;
  byte =
    n:
    if n == 0 then throw "native Ruby text contains NUL" else builtins.substring (n - 1) 1 bytesTable;
  positions = builtins.listToAttrs (
    builtins.genList (n: {
      name = builtins.substring n 1 alphabet;
      value = n;
    }) 64
  );
  encoded = snapshot.base64 or null;
  size = snapshot.size or null;
  shape =
    builtins.isAttrs snapshot
    &&
      builtins.attrNames snapshot == [
        "base64"
        "path"
        "sha256"
        "size"
      ]
    && builtins.isInt size
    && size >= 0
    && size <= 1048576
    && builtins.isString encoded
    && builtins.stringLength encoded == 4 * (builtins.div (size + 2) 3)
    && builtins.match "([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?" encoded != null;
  group =
    n:
    let
      at = offset: builtins.substring (4 * n + offset) 1 encoded;
      a = positions.${at 0};
      b = positions.${at 1};
      c = if at 2 == "=" then 0 else positions.${at 2};
      d = if at 3 == "=" then 0 else positions.${at 3};
      first = byte (4 * a + builtins.div b 16);
      second = byte (16 * (mod b 16) + builtins.div c 4);
      third = byte (64 * (mod c 4) + d);
      canonical =
        if at 2 == "=" then
          mod b 16 == 0
        else if at 3 == "=" then
          mod c 4 == 0
        else
          true;
    in
    if !canonical then
      throw "noncanonical native snapshot base64"
    else
      first + (if at 2 == "=" then "" else second) + (if at 3 == "=" then "" else third);
  bytes =
    if shape then
      builtins.concatStringsSep "" (
        builtins.genList group (builtins.div (builtins.stringLength encoded) 4)
      )
    else
      throw "invalid bounded native snapshot";
  digest = builtins.convertHash {
    hash = builtins.hashString "sha256" bytes;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
in
if builtins.stringLength bytes == size && digest == snapshot.sha256 then
  bytes
else
  throw "native snapshot bytes conflict with identity"
