# SPDX-License-Identifier: MIT
# Original Ruby 1.8.3 source; this release has no RUBY_PATCHLEVEL constant.
{ pkgs, olderRubySource }:
let
  old = import olderRubySource {
    system = "x86_64-linux";
    config = { };
  };
in
old.stdenv.mkDerivation {
  name = "ruby-1.8.3";
  version = "1.8.3";
  src = pkgs.fetchurl {
    url = "https://cache.ruby-lang.org/pub/ruby/1.8/ruby-1.8.3.tar.gz";
    hash = "sha256-4HEciq8DwAgQ6EZ5oGCiDW4mLmT9h/432bA6i4orbpA=";
  };
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
    "$out/bin/ruby" -e 'require "zlib"; require "openssl"; require "timeout"; 10.times { Timeout.timeout(1) { sleep 0.01 } }; abort unless RUBY_VERSION == "1.8.3"; abort if defined?(RUBY_PATCHLEVEL); puts [RUBY_VERSION, RUBY_RELEASE_DATE, OpenSSL::OPENSSL_VERSION].join("|")'
  '';
  passthru = {
    libPath = "lib/ruby/1.8";
    gemPath = "lib/ruby/gems/1.8";
  };
}
