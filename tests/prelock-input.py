# SPDX-License-Identifier: MIT
"""Consume an unchanged Gemfile through an actual pinned native Nix input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--provider', required=True, type=Path)
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--work', required=True, type=Path)
parser.add_argument('--sdk-profile', choices=['bundler08', 'bundler031'], default='bundler08')
parser.add_argument('--core-reference')
args = parser.parse_args()
legacy = args.sdk_profile == 'bundler031'
root = Path(__file__).resolve().parent.parent
args.work.mkdir()
logs = args.work / 'logs'
logs.mkdir()
flake = args.work / 'input'
flake.mkdir()
shutil.copytree(args.provider, flake / 'provider', symlinks=True,
                ignore=shutil.ignore_patterns(*(['.bundler-purifier', '.git'] if legacy else ['.bundler-purifier', 'vendor', '.git'])))
# The v08 provider selects the compiled SDK JSON component. The v03 provider
# retains its verified vendored binary archive and original gemspec dependency.
(flake / 'flake.nix').write_text('''{
 inputs.adapter.url = %s;
 %s
 outputs = {self,adapter,...}: let
  f=adapter;
  pkgs=import f.inputs.nixpkgs {system="x86_64-linux";};
  deps=builtins.getFlake (builtins.unsafeDiscardStringContext ("path:"+f.outPath+"/tests/dependencies"));
  native=import (f.outPath+"/tests/%s") {inherit pkgs;olderRubySource=deps.inputs.older-ruby;};
  build=pkgs.callPackage (f.outPath+"/nix/lib/build-bundler-project.nix") {inherit(f.inputs.purifier.lib) purifier;readLock=import (f.outPath+"/nix/lib/read-lock.nix") {inherit(pkgs) lib;};};
  project=build {src=./provider;ruby=native.sdk;};
 in {packages.x86_64-linux.default=project.packages.app;};
}
''' % (json.dumps('path:' + str(root)), ('inputs.core.url = ' + json.dumps(args.core_reference) + '; inputs.adapter.inputs.purifier.follows = "core";') if args.core_reference else '', 'ruby183-bundler031-sdk.nix' if legacy else 'ruby184-bundler08-sdk.nix'))
project = args.work / 'project'
project.mkdir()
manifest = b'gem "historical_greeting"\n'
(project / 'Gemfile').write_bytes(manifest)
receipt = {'complete': False, 'commands': []}
for label, command in [
    ('lock-declared-input', ['lock', '--input', 'path:' + str(flake) + '#default']),
    ('prefetch-declared-input', ['prefetch']),
    ('runtime-declared-input', ['shell', 'ruby', '-e',
        'require "historical_greeting";raise unless HistoricalGreeting.answer==42;puts "DECLARED|42|#{RUBY_VERSION}"'])]:
    result = subprocess.run([str(args.cli)] + command, cwd=project,
                            env=os.environ, capture_output=True, timeout=900)
    for suffix, data in [('stdout', result.stdout), ('stderr', result.stderr)]:
        (logs / (label + '.' + suffix)).write_bytes(data)
    receipt['commands'].append({'label': label, 'argv': command, 'exit': result.returncode,
        'stdoutSha256': hashlib.sha256(result.stdout).hexdigest(),
        'stderrSha256': hashlib.sha256(result.stderr).hexdigest()})
    (args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert result.returncode == 0, (label, result.stderr.decode()[-6000:])
    if label == 'runtime-declared-input':
        assert (b'DECLARED|42|1.8.3' if legacy else b'DECLARED|42|1.8.4') in result.stdout
lock = json.loads((project / 'bundler-purifier.lock.json').read_text())
assert (project / 'Gemfile').read_bytes() == manifest
assert not (project / 'Gemfile.lock').exists()
assert len(lock['projectInputs']) == 1
assert {binding['name'] for binding in lock['nativeResolution']['bindings']} == {'historical_greeting', 'json'}
assert all(archive['transport']['kind'] == 'nix' for archive in lock['archives'])
receipt.update(complete=True, unchangedUnversionedManifest=True, nativeInputPins=lock['projectInputs'],
               selectedBindings=lock['nativeResolution']['bindings'])
(args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
