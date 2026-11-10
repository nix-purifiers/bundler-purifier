# SPDX-License-Identifier: MIT
"""Offline native Bundler 1.17 input binding, installation and ABI execution."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
tools, repository, catalog = map(Path, sys.argv[1:4])
expected_ruby = sys.argv[4] if len(sys.argv) > 4 else '2.5.8'
patchlevel, gem_version = {'1.8.7': (374, '2.6.14'), '2.5.8': (224, '3.1.2')}[expected_ruby]
with tempfile.TemporaryDirectory(prefix='bundler117-composition-') as temporary:
    project = Path(temporary)
    manifest = 'source "https://unreachable.invalid"\nruby "' + expected_ruby + '"\ngem "historical_greeting", ">= 99"\n'
    (project / 'Gemfile').write_text(manifest)
    environment = dict(os.environ, HOME=str(project),
        PATH=str(tools / 'bin') + ':' + os.environ['PATH'],
        GEM_HOME=str(project / 'gems'), GEM_PATH=str(tools / 'gems'),
        BUNDLE_PATH=str(project / 'vendor/bundle'), BUNDLE_USER_HOME=str(project / 'bundle-home'),
        BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps([dict(repository=str(repository), catalog=str(catalog))]),
        BUNDLER_PURIFIER_BUNDLER_VERSION='1.17.3', BUNDLER_PURIFIER_PERSIST_LOCK='1')

    def run(*arguments, views=None, succeeds=True):
        env = dict(environment)
        if views is not None:
            env['BUNDLER_PURIFIER_INPUT_VIEWS'] = json.dumps(views)
        result = subprocess.run([str(tools / 'bin/ruby'), str(root / 'tools/native_bundle_command.rb'), *arguments],
                                cwd=project, env=env, text=True, capture_output=True, timeout=90)
        assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
        assert (project / 'Gemfile').read_text() == manifest
        return result.stdout if succeeds else result.stdout + result.stderr

    run('lock', '--local')
    lock = (project / 'Gemfile.lock').read_bytes()
    entries = json.loads(catalog.read_text())['packages']
    for entry in entries:
        assert entry['version'].encode() in lock
    assert b'1.17.3' in lock
    run('lock', '--local')
    assert (project / 'Gemfile.lock').read_bytes() == lock
    run('install', '--local')
    # Require in the application body, after native Bundler's runtime setup.
    runtime = r'''require "historical_greeting"
require "digest/sha2"
abort "wrong native parser" unless JSON.parser == JSON::Ext::Parser
puts "RUNTIME|#{RUBY_VERSION}|#{RUBY_PATCHLEVEL}|#{Gem::VERSION}|#{Bundler::VERSION}"
puts "VALUE|#{HistoricalGreeting.answer}"
Gem.loaded_specs.values.each do |spec|
  if ["json", "historical_greeting"].include?(spec.name)
    puts "GEM|#{spec.name}|#{spec.version}|#{spec.full_gem_path}"
  end
end
# Ruby 1.8 records relative loaded-feature names. Join the one live native
# parser mapping to the selected installed gem, rather than guessing a path.
paths = File.readlines("/proc/self/maps").map { |line| line.split.last }.uniq.select { |path| path =~ /json\/ext\/parser\.so$/ }
abort "ambiguous loaded parser" unless paths.size == 1
native = paths.first
abort "wrong loaded gem" unless native.start_with?(Gem.loaded_specs.fetch("json").full_gem_path + "/")
puts "NATIVE|#{native}|#{Digest::SHA256.file(native).hexdigest}"
'''
    output = run('exec', 'ruby', '-e', runtime)
    lines = output.splitlines()
    assert f'RUNTIME|{expected_ruby}|{patchlevel}|{gem_version}|1.17.3' in lines, output
    assert 'VALUE|42' in lines, output
    selected = {line.split('|')[1]: line.split('|')[2:] for line in lines if line.startswith('GEM|')}
    for entry in entries:
        version, installed = selected[entry['name']]
        assert version == entry['version'] and installed.startswith(str(project / 'vendor/bundle') + '/'), output
        archive = repository / entry['archive']
        assert 'sha512-' + base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() == entry['integrity']
    native_lines = [line.split('|')[1:] for line in lines if line.startswith('NATIVE|')]
    assert len(native_lines) == 1
    native_path, native_hash = native_lines[0]
    assert hashlib.sha256(Path(native_path).read_bytes()).hexdigest() == native_hash
    json_entry = next(entry for entry in entries if entry['name'] == 'json')
    with tarfile.open(repository / json_entry['archive']) as archive:
        payload = archive.extractfile('data.tar.gz').read()
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as payload:
        parsers = [member for member in payload if member.isfile() and member.name.endswith('json/ext/parser.so')]
        assert len(parsers) == 1
        assert hashlib.sha256(payload.extractfile(parsers[0]).read()).hexdigest() == native_hash
    run('lock', '--local')
    assert (project / 'Gemfile.lock').read_bytes() == lock

    # The original >=99 request has no ordinary local candidate. Without
    # declared inputs the native resolver must fail and retain both files.
    failure = run('lock', '--local', views=[], succeeds=False)
    assert 'historical_greeting' in failure
    assert (project / 'Gemfile.lock').read_bytes() == lock
    conflicting = json.loads(catalog.read_text())
    conflicting['packages'][0]['integrity'] = 'sha512-conflicting-input'
    wrong = project / 'conflicting-catalog.json'
    wrong.write_text(json.dumps(conflicting))
    failure = run('lock', '--local', views=[dict(repository=str(repository), catalog=str(catalog)),
                                          dict(repository=str(repository), catalog=str(wrong))], succeeds=False)
    assert 'conflicting Nix inputs' in failure
    assert (project / 'Gemfile.lock').read_bytes() == lock
    assert not list(project.glob('.bundler-purifier-*.Gemfile*'))
    print(f'PASS Ruby{expected_ruby}/Bundler1.17: native input binding, installed projected versions, live compiled origin/archive SHA, unchanged manifest/lock and negative controls')
