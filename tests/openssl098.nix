# SPDX-License-Identifier: MIT
# The 0.9.8 API used by these unmodified historical Ruby sources.
{ pkgs, old }:
old.stdenv.mkDerivation {
  name = "openssl-0.9.8zh";
  src = pkgs.fetchurl {
    url = "https://github.com/openssl/openssl/releases/download/OpenSSL_0_9_8zh/openssl-0.9.8zh.tar.gz";
    sha256 = "f1d9f3ed1b85a82ecf80d0e2d389e1fda3fca9a4dba0bf07adbf231e1a5e2fd6";
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
