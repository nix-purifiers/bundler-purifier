# SPDX-License-Identifier: MIT
{ pkgs, old }:
old.stdenv.mkDerivation {
  name = "openssl-0.9.7m";
  src = pkgs.fetchurl {
    url = "https://www.openssl.org/source/old/0.9.x/openssl-0.9.7m.tar.gz";
    hash = "sha256-yYuXA4h+LdpiF7kUBdDZSIP3xn4gX8TXqBu2kNLhBXI=";
  };
  buildInputs = [ old.perl ];
  configureScript = "./config";
  configureFlags = [
    "shared"
    "--openssldir=etc/ssl"
  ];
  enableParallelBuilding = false;
  installTargets = "install_sw";
}
