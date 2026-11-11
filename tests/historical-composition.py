# SPDX-License-Identifier: MIT
"""Offline native historical Bundler input binding, installation and ABI execution."""
import argparse
import base64
import hashlib
import io
import json
import os
import re
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
parser.add_argument('--ruby-requirement')
args = parser.parse_args()
tools, repository, catalog = args.tools, args.repository, args.catalog
expected_ruby, expected_bundler = args.expected_ruby, args.expected_bundler
extra_gem_path, versionless = args.extra_gem_path, args.versionless
patchlevel, default_gem_version = {'1.8.4': ('absent', '1.3.5'), '1.8.6': (420, '1.3.7'), '1.8.7': (374, '2.6.14'), '1.9.0': (0, '1.3.7'), '1.9.1': (431, '2.6.14'), '1.9.2': (330, '2.6.14'), '1.9.3': (547, '2.6.14'), '2.0.0': (481, '2.6.14'), '2.1.3': (242, '2.6.14'), '2.2.7': (470, '2.6.14'), '2.3.6': (384, '2.7.6'), '2.4.3': (205, '2.7.6'), '3.0.5': (211, '3.3.20'), '3.1.7': (261, '3.5.22'), '3.2.8': (263, '3.5.22'), '3.3.8': (144, '3.5.22'), '4.0.9': (0, '3.7.2'), '4.1.0': (-1, '4.1.0.beta2'), '2.6.6': (146, '3.1.2'), '2.7.1': (83, '3.1.2'), '2.5.8': (224, '3.1.2')}[expected_ruby]
gem_version = args.rubygems_version or default_gem_version
with tempfile.TemporaryDirectory(prefix='bundler117-composition-') as temporary:
    project = Path(temporary)
    ruby_declaration = '' if args.no_ruby_dsl else 'ruby "' + (args.ruby_requirement or expected_ruby) + '"\n'
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

    if expected_bundler == '0.9.9':
        # This native lock also writes an executable environment containing
        # installed gem paths, so follow its install-before-lock lifecycle.
        run('install', '--local')
    run('lock', '--local')
    lock = (project / 'Gemfile.lock').read_bytes()
    entries = json.loads(catalog.read_text())['packages']
    for entry in entries:
        assert entry['version'].encode() in lock
    if versionless:
        assert b'BUNDLED WITH' not in lock
    else:
        assert re.search(rb'(?m)^BUNDLED WITH\n[ \t]+' + re.escape(expected_bundler.encode()) + rb'\n', lock)
    run('lock', '--local')
    assert (project / 'Gemfile.lock').read_bytes() == lock
    run('install', '--local')
    # Require in the application body, after native Bundler's runtime setup.
    runtime = r'''require "historical_greeting"
require "digest/sha2"
abort "resolver scope leaked" if Thread.current[:purifier_definition_sources]
abort "wrong native parser" unless JSON.parser == JSON::Ext::Parser
requirement = Gem.loaded_specs.fetch("json").required_ruby_version
abort "current Ruby ABI rejected" unless requirement.satisfied_by?(Gem.ruby_version)
next_release = Gem::Version.new(RUBY_VERSION + ".0").bump
abort "next Ruby ABI accepted" if requirement.satisfied_by?(next_release)
puts "RUNTIME|#{RUBY_VERSION}|#{defined?(RUBY_PATCHLEVEL) ? RUBY_PATCHLEVEL : "absent"}|#{Gem::VERSION}|#{Bundler::VERSION}"
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
abort "wrong loaded gem" unless native.index(Gem.loaded_specs.fetch("json").full_gem_path + "/") == 0
puts "NATIVE|#{native}|#{File.open(native, "rb") { |file| Digest::SHA256.hexdigest(file.read) }}"
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
    checksum_lines = re.findall(rb'(?m)^[ \t]+([^ \n]+) \(([^)]+)\) sha256=([0-9a-f]{64})$', lock)
    if int(expected_bundler.split('.')[0]) >= 4:
        assert checksum_lines, 'native Bundler 4 must retain archive checksum coverage'
    if checksum_lines:
        by_archive = {Path(entry['archive']).name: entry for entry in entries}
        for name, version, digest in checksum_lines:
            archive_name = name.decode() + '-' + version.decode() + '.gem'
            assert archive_name in by_archive
            archive = repository / by_archive[archive_name]['archive']
            assert hashlib.sha256(archive.read_bytes()).hexdigest() == digest.decode()
        assert len(checksum_lines) == len(entries)
        tampered = re.sub(rb'sha256=[0-9a-f]{64}', b'sha256=' + b'0' * 64, lock, count=1)
        assert tampered != lock
        (project / 'Gemfile.lock').write_bytes(tampered)
        try:
            failure = run('install', '--local', succeeds=False).lower()
            assert 'checksum' in failure and ('mismatch' in failure or 'does not match' in failure), failure
        finally:
            (project / 'Gemfile.lock').write_bytes(lock)
        print('PASS native archive checksum bindings and tampered checksum rejection')

    if versionless and expected_bundler != '0.9.9':
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
    collection = r'''spec = Gem::Specification.new { |value| value.name="native_collection"; value.version="1.0" }
spec.add_dependency("historical_greeting", ">= 99")
values = spec.dependencies
spec.add_dependency("ordinary_collection_control", ">= 2")
abort "native dependency collection replaced" unless spec.dependencies.equal?(values)
abort "native dependency declaration dropped" unless spec.dependencies.map { |dependency| dependency.name } == ["historical_greeting", "ordinary_collection_control"]
abort "ordinary constraint changed" unless spec.dependencies.last.requirement.to_s == ">= 2"
abort "SDK specification class changed" unless spec.class == Gem::Specification
puts "NATIVE DEPENDENCY COLLECTION PASS"
'''
    if expected_bundler == '0.9.9':
        collection = 'require ' + json.dumps(str(root / 'tools/rubygems_inputs.rb')) + '\n' + collection
    assert run('exec', 'ruby', '-e', collection).strip() == 'NATIVE DEPENDENCY COLLECTION PASS'

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
