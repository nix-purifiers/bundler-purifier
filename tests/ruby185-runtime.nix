# SPDX-License-Identifier: MIT
# Original Ruby 1.8.5-p231 with its errno preprocessor directive corrected.
{ pkgs, olderRubySource }:
let
  old = import olderRubySource {
    system = "x86_64-linux";
    config = { };
  };
in
old.stdenv.mkDerivation {
  name = "ruby-1.8.5-p231";
  version = "1.8.5";
  src = pkgs.fetchurl {
    url = "https://cache.ruby-lang.org/pub/ruby/1.8/ruby-1.8.5-p231.tar.gz";
    hash = "sha256-kJHuYGyJ69lLPO2abBu6jlao5YBwkcFOgXmGkMt+dso=";
  };
  patches = [ ./ruby185-errno.patch ];
  buildInputs = [
    old.zlib
    (import ./openssl097.nix { inherit pkgs old; })
    old.ncurses
    old.readline
  ];
  NIX_CFLAGS_COMPILE = "-O0 -fno-omit-frame-pointer -fno-strict-aliasing";
  configureFlags = [
    "--enable-shared"
    "--disable-pthread"
  ];
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/ruby" -e 'require "zlib"; require "openssl"; require "timeout"; 10.times { Timeout.timeout(1) { sleep 0.01 } }; abort unless RUBY_VERSION == "1.8.5"; abort unless RUBY_PATCHLEVEL == 231; require "rbconfig"; abort unless defined?(RbConfig); puts [RUBY_VERSION, RUBY_RELEASE_DATE, OpenSSL::OPENSSL_VERSION].join("|")'
  '';
  passthru = {
    libPath = "lib/ruby/1.8";
    gemPath = "lib/ruby/gems/1.8";
  };
}
