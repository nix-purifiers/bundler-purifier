#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-relock: relocking each fixture reproduces its Gemfile.lock and
# its purifier lockfile byte for byte. The external fixture is relocked
# from its Gemfile.lock and with --lockfile, as a project kept outside
# its source is.
source "$(dirname "$0")/common.sh"

for fixture in app library submodules update; do
  # A darwin relock writes another hash for the submodules fixture's git
  # checkout (see fixture-submodules in tests/default.nix).
  if [[ "$fixture" == submodules && "$system" == *-darwin ]]; then
    echo "== relock of $fixture skipped on darwin"
    continue
  fi
  echo "== relock of $fixture"
  (cd "$work/fixtures/$fixture" && "$cli" lock --force)
  diff -u "$repo/tests/fixtures/$fixture/Gemfile.lock" "$work/fixtures/$fixture/Gemfile.lock"
  diff -u "$repo/tests/fixtures/$fixture/bundler-purifier.lock.json" \
    "$work/fixtures/$fixture/bundler-purifier.lock.json"
done

echo "== relock of external"
(cd "$work/fixtures/external/project" && "$cli" --lockfile ../bundler-purifier.lock.json lock --force)
diff -u "$repo/tests/fixtures/external/project/Gemfile.lock" "$work/fixtures/external/project/Gemfile.lock"
diff -u "$repo/tests/fixtures/external/bundler-purifier.lock.json" \
  "$work/fixtures/external/bundler-purifier.lock.json"
echo "== relock of external with its Gemfile.lock outside the tree"
(cd "$work/fixtures/external/project" && "$cli" --lockfile ../replaced/bundler-purifier.lock.json \
  --tool-lockfile ../replaced/Gemfile.lock lock --force)
diff -u "$repo/tests/fixtures/external/replaced/Gemfile.lock" "$work/fixtures/external/replaced/Gemfile.lock"
diff -u "$repo/tests/fixtures/external/replaced/bundler-purifier.lock.json" \
  "$work/fixtures/external/replaced/bundler-purifier.lock.json"
diff -u "$repo/tests/fixtures/external/project/Gemfile.lock" "$work/fixtures/external/project/Gemfile.lock"

echo "== relock of external from the tree's Gemfile.lock to a new outside path"
(cd "$work/fixtures/external/project" && "$cli" --lockfile ../fresh/bundler-purifier.lock.json \
  --tool-lockfile ../fresh/Gemfile.lock lock)
diff -u "$repo/tests/fixtures/external/project/Gemfile.lock" "$work/fixtures/external/fresh/Gemfile.lock"
diff -u "$repo/tests/fixtures/external/project/Gemfile.lock" "$work/fixtures/external/project/Gemfile.lock"
echo "conformance-relock passed"
