# SPDX-License-Identifier: MIT
#
# The setup that the CI scripts beside this file share, sourced by each. It
# builds the CLI and puts its Ruby and nixpkgs' C toolchain first on PATH,
# since native extensions compiled against that Ruby link only with that
# toolchain, and copies the tracked files of the fixtures into a scratch
# directory, $work/fixtures, since the app fixture reaches ../shared-gem.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
export system=$(nix eval --raw --impure --expr builtins.currentSystem)
cli="$(nix build --no-link --print-out-paths '.#cli')/bin/bundler-purifier"
ruby=$(grep -o '/nix/store/[^"]*-ruby-[^/"]*/bin' "$cli" | head -n 1)
nixpkgs=$(grep -o "BUNDLER_PURIFIER_NIXPKGS='[^']*'" "$cli" | cut -d"'" -f2)
toolchain=$(nix-build "$nixpkgs" -A stdenv.cc -A gnumake --no-out-link | sed 's|$|/bin|' | paste -sd: -)
export PATH="$ruby:$toolchain:$PATH"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export BUNDLE_USER_HOME="$work/bundle-home"

git -C "$repo" ls-files -z -- tests/fixtures | tar --null -T - -cf - | tar -xf - -C "$work"
mv "$work/tests/fixtures" "$work/fixtures"
