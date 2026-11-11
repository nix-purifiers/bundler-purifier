# SPDX-License-Identifier: MIT
"""Offline native historical Bundler input binding, installation and ABI execution."""
import argparse
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
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tools', type=Path)
parser.add_argument('repository', type=Path)
parser.add_argument('catalog', type=Path)
parser.add_argument('expected_ruby', nargs='?', default='2.5.8')
parser.add_argument('expected_bundler', nargs='?', default='1.17.3')
parser.add_argument('extra_gem_path', nargs='?', default='')
parser.add_argument('--versionless', action='store_true')
parser.add_argument('--rubygems-version')
parser.add_argument('--no-ruby-dsl', action='store_true')
args = parser.parse_args()
tools, repository, catalog = args.tools, args.repository, args.catalog
expected_ruby, expected_bundler = args.expected_ruby, args.expected_bundler
extra_gem_path, versionless = args.extra_gem_path, args.versionless
patchlevel, default_gem_version = {'1.8.7': (374, '2.6.14'), '1.9.3': (547, '2.6.14'), '2.0.0': (481, '2.6.14'), '2.5.8': (224, '3.1.2')}[expected_ruby]
gem_version = args.rubygems_version or default_gem_version
with tempfile.TemporaryDirectory(prefix='bundler117-composition-') as temporary:
    project = Path(temporary)
    ruby_declaration = '' if args.no_ruby_dsl else 'ruby "' + expected_ruby + '"\n'
    manifest = 'source "https://unreachable.invalid"\n' + ruby_declaration + 'gem "historical_greeting", ">= 99"\n'
    if args.no_ruby_dsl:
        (project / '.ruby-version').write_text(expected_ruby + '\n')
    (project / 'Gemfile').write_text(manifest)
    environment = dict(os.environ, HOME=str(project),
        PATH=str(tools / 'bin') + ':' + os.environ['PATH'],
        GEM_HOME=str(project / 'gems'), GEM_PATH=str(tools / 'gems') + (':' + extra_gem_path if extra_gem_path else ''),
        BUNDLE_PATH=str(project / 'vendor/bundle'), BUNDLE_USER_HOME=str(project / 'bundle-home'),
        BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps([dict(repository=str(repository), catalog=str(catalog))]),
        BUNDLER_PURIFIER_BUNDLER_VERSION=expected_bundler, BUNDLER_PURIFIER_PERSIST_LOCK='1')

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
    if versionless:
        assert b'BUNDLED WITH' not in lock
    else:
        assert ('BUNDLED WITH\n   ' + expected_bundler).encode() in lock
    run('lock', '--local')
    assert (project / 'Gemfile.lock').read_bytes() == lock
    run('install', '--local')
    # Require in the application body, after native Bundler's runtime setup.
    runtime = r'''require "historical_greeting"
require "digest/sha2"
abort "resolver scope leaked" if Thread.current[:purifier_definition_sources]
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
    assert f'RUNTIME|{expected_ruby}|{patchlevel}|{gem_version}|{expected_bundler}' in lines, output
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
    if versionless:
        identity = r'''klass = Bundler::Source::Rubygems
repository = PurifierGemInputs::PACKAGES.values.find { |package| !package["intrinsic"] }.fetch("repository")
nix = klass.new("remotes" => [repository])
copy = klass.new("remotes" => [repository])
ordinary = klass.new("remotes" => ["https://ordinary-one.invalid/"])
other = klass.new("remotes" => ["https://ordinary-two.invalid/"])
abort "ordinary source merge changed" unless ordinary == other && ordinary.hash == other.hash
abort "Nix source collapsed" if nix == ordinary || ordinary == nix
abort "same Nix source split" unless nix == copy && nix.hash == copy.hash
forward = klass.new("remotes" => [repository, "https://ordinary-one.invalid/"])
reverse = klass.new("remotes" => ["https://ordinary-one.invalid/", repository])
abort "Nix remote priority discarded" if forward == reverse
abort "hash identity mismatch" unless [nix,copy,ordinary,other,forward,reverse].uniq.size == 4
intrinsic = klass.new("remotes" => []).extend(PurifierGemInputs::IntrinsicSpecs)
intrinsic_copy = klass.new("remotes" => []).extend(PurifierGemInputs::IntrinsicSpecs)
ordinary_empty = klass.new("remotes" => [])
abort "intrinsic source collapsed" if intrinsic == ordinary_empty || ordinary_empty == intrinsic
abort "intrinsic copy split" unless intrinsic == intrinsic_copy && intrinsic.hash == intrinsic_copy.hash
abort "ordinary empty source merge changed" unless ordinary_empty == ordinary && ordinary_empty.hash == ordinary.hash
sources = [ordinary_empty]
added = PurifierGemInputs.add_rubygems_source(sources, [], true)
abort "ordinary source reused for intrinsic" unless sources.size == 2 && !added.equal?(ordinary_empty)

puts "SOURCE IDENTITY PASS"
'''
        assert run('exec', 'ruby', '-e', identity).strip() == 'SOURCE IDENTITY PASS'
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
    print(f'PASS Ruby{expected_ruby}/Bundler{expected_bundler}: native input binding, installed projected versions, live compiled origin/archive SHA, unchanged manifest/lock and negative controls')
