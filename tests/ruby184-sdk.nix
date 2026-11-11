# SPDX-License-Identifier: MIT
{ pkgs, olderRubySource }:
import ./ruby18-sdk.nix {
  inherit pkgs olderRubySource;
  rubyPackage = import ./ruby184-runtime.nix { inherit pkgs olderRubySource; };
  rubyVersion = "1.8.4";
  runtimeName = "ruby184";
  rubygemsVersion = "1.3.5";
  rubygemsHash = "sha256-Eg+xRFajOZGup2WwlQEPVm9lDPkU2drQ740SQe3Kv8U=";
  bundlerVersion = "0.9.9";
  bundlerHash = "sha256-A4vNaw2V7Muoyu3Pa8+sGRiON6CabdjctMhywiL6T0Q=";
}
