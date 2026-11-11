# SPDX-License-Identifier: MIT
# Build the original release source with its native compiler and SSL API.
{
  pkgs,
  olderRubySource,
  rubyVersion,
  patchlevel,
  sourceHash,
  legacySSL ? false,
}:
assert builtins.elem rubyVersion [
  "1.8.6"
  "1.9.1"
  "1.9.2"
];
let
  old = import olderRubySource {
    system = "x86_64-linux";
    config = { };
  };
  openssl = if legacySSL then import ./openssl098.nix { inherit pkgs old; } else old.openssl;
  abi = if pkgs.lib.versionOlder rubyVersion "1.9" then "1.8" else "1.9.1";
in
old.stdenv.mkDerivation (
  {
    name = "ruby-${rubyVersion}-p${toString patchlevel}";
    version = "${rubyVersion}-p${toString patchlevel}";
    src = pkgs.fetchurl {
      url = "https://cache.ruby-lang.org/pub/ruby/${
        if abi == "1.8" then "1.8" else "1.9"
      }/ruby-${rubyVersion}-p${toString patchlevel}.tar.gz";
      hash = sourceHash;
    };
    buildInputs = [
      old.zlib
      openssl
      old.ncurses
      old.readline
    ];
    configureFlags = [
      "--enable-shared"
      (if rubyVersion == "1.8.6" then "--disable-pthread" else "--enable-pthread")
    ];
    doInstallCheck = true;
    installCheckPhase = ''
      ${pkgs.lib.optionalString (rubyVersion == "1.8.6") ''
        "$out/bin/ruby" -rtimeout -e '10.times { Timeout.timeout(1) { sleep 0.01 } }'
      ''}
      "$out/bin/ruby" -e 'require "zlib";require "openssl";abort unless RUBY_VERSION=="${rubyVersion}" && RUBY_PATCHLEVEL==${toString patchlevel};puts [RUBY_VERSION,RUBY_PATCHLEVEL,OpenSSL::OPENSSL_VERSION].join("|")'
    '';
    passthru = {
      libPath = "lib/ruby/${abi}";
      gemPath = "lib/ruby/gems/${abi}";
    };
  }
  // pkgs.lib.optionalAttrs (rubyVersion == "1.8.6") {
    # This native stack-copying runtime crashes in Timeout with the default
    # compiler settings. Keep its original source and validate real switching.
    NIX_CFLAGS_COMPILE = "-O0 -fno-omit-frame-pointer -fno-strict-aliasing";
  }
)
