# SPDX-License-Identifier: MIT
#
# The gem cache of a lock: the directory Bundler reads with
# `bundle install --local` (its `vendor/cache`).
#
# The shared nix-purifiers library (`purifier`, its `lib.purifier`)
# fetches each download: a gem file is a file entry, and a git source is a
# git entry. `fetchers` replace nixpkgs' fetchers, as the builder's
# `fetchers` argument gives them. Each gem file is a link into the store.
# Each git checkout is a copy with the `.bundlecache` marker that Bundler
# leaves in a cached git source, which the library's `tree` does not write.
{
  lib,
  purifier,
  # The file entries and the git entries to cache.
  files,
  gitCheckouts,
  # The arguments of fetchEntry: the fetchers, and the packages its steps
  # after a fetch build with, `runCommand` among them.
  fetchers,
}:
let
  fetch = purifier.fetchEntry fetchers;
in
# The manifests go to the builder as files, since a large bundle locks
# hundreds of gems and the list would not fit in an environment variable.
fetchers.runCommand "bundler-gem-cache"
  {
    files = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") files;
    gitCheckouts = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") gitCheckouts;
    passAsFile = [
      "files"
      "gitCheckouts"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      ln -s "$target" "$out/$rel"
    done < "$filesPath"
    while IFS=$'\t' read -r rel target; do
      cp -r "$target" "$out/$rel"
      chmod -R u+w "$out/$rel"
      touch "$out/$rel/.bundlecache"
    done < "$gitCheckoutsPath"
  ''
