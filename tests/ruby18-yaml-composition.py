# SPDX-License-Identifier: MIT
"""Native Bundler 0.9 input binding, YAML lock and compiled runtime boundaries."""
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('sdk', type=Path)
parser.add_argument('repository', type=Path)
parser.add_argument('catalog', type=Path)
parser.add_argument('--extra-gem-path', default='')
parser.add_argument('--results', type=Path)
parser.add_argument('--codec', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
work = args.results.resolve() if args.results else Path(tempfile.mkdtemp(prefix='bundler09-native-'))
work.mkdir(exist_ok=args.results is None)
logs = work / 'logs'
logs.mkdir()
project = work / 'project'
project.mkdir()
manifest = b'source "https://unreachable.invalid"\ngem "historical_greeting", ">= 99"\n'
(project / 'Gemfile').write_bytes(manifest)
cache = project / 'vendor/cache'
cache.mkdir(parents=True)
catalog = json.loads(args.catalog.read_text())
entries = {entry['name']: entry for entry in catalog['packages']}
assert set(entries) == {'json', 'historical_greeting'} and not catalog['intrinsics']
for entry in entries.values():
    archive = args.repository / entry['archive']
    assert 'sha512-' + base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() == entry['integrity']
    shutil.copyfile(archive, cache / archive.name)
env = {key: value for key, value in os.environ.items() if not key.startswith(('GEM_', 'RUBY', 'BUNDLE_', 'BUNDLER_PURIFIER_'))}
env.update(HOME=str(work / 'home'), GEM_HOME=str(work / 'gems'), GEM_PATH=args.extra_gem_path,
           PATH=str(args.sdk / 'bin') + ':' + os.environ['PATH'], BUNDLE_PATH=str(project / 'vendor/bundle'),
           BUNDLE_CACHE_PATH=str(cache), BUNDLER_PURIFIER_BUNDLER_VERSION='0.9.26',
           BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps([dict(repository=str(args.repository), catalog=str(args.catalog))]),
           BUNDLER_PURIFIER_PERSIST_LOCK='1')
Path(env['HOME']).mkdir()
receipt = dict(complete=False, scope='native helper composition only; no host capture/pure-build/publication support claim', commands=[])


def run(label, arguments, *, cwd=project, environment=None, success=True, native=True, executable=None):
    assert len(receipt['commands']) < 16
    argv = [str(executable or (args.sdk / 'bin/ruby'))]
    if native and executable is None:
        argv += [str(root / 'tools/native_bundle_command.rb')]
    argv += list(map(str, arguments))
    stdout, stderr = logs / (label + '.stdout'), logs / (label + '.stderr')
    with stdout.open('wb') as out, stderr.open('wb') as err:
        process = subprocess.Popen(argv, cwd=cwd, env=env if environment is None else environment,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait(timeout=90)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
    receipt['commands'].append(dict(label=label, argv=argv, exit=code, expectedSuccess=success,
        stdoutSha256=hashlib.sha256(stdout.read_bytes()).hexdigest(), stderrSha256=hashlib.sha256(stderr.read_bytes()).hexdigest()))
    (work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert (code == 0) == success, label + '\n' + stdout.read_text()[-1500:] + stderr.read_text()[-2500:]
    assert (project / 'Gemfile').read_bytes() == manifest
    return stdout.read_text() if success else stdout.read_text() + stderr.read_text()


identity = run('native-identity', ['-e', 'require "rubygems"; gem "bundler", "= 0.9.26"; require "bundler"; require "bundler/version"; puts [RUBY_VERSION,RUBY_PATCHLEVEL,Gem::VERSION,Bundler::VERSION,Gem.ruby].join("|")'], native=False).strip()
fields = identity.split('|')
assert fields[:4] == ['1.8.7', '374', '1.8.30', '0.9.26']
receipt['nativeTuple'] = identity
receipt['actualRubySha256'] = hashlib.sha256(Path(fields[4]).read_bytes()).hexdigest()
if args.extra_gem_path:
    higher_env = dict(env)
    higher_env.pop('BUNDLER_PURIFIER_BUNDLER_VERSION')
    assert run('higher-sdk-visible', ['-e', 'require "bundler"; puts Bundler::VERSION'], environment=higher_env, native=False).strip() == '1.17.3'
run('install', ['install'])
run('native-lock', ['lock'])
lock = project / 'Gemfile.lock'
assert lock.read_bytes().startswith(b'---') and b'BUNDLED WITH' not in lock.read_bytes()


def read_lock(label):
    data = json.loads(run(label, ['-e', 'require "yaml"; require "json"; puts JSON.generate(YAML.load_file(ARGV.fetch(0)))', lock], native=False))
    assert data['hash'] == hashlib.sha1(manifest).hexdigest()
    sources = data['sources']
    managed = [i for i, source in enumerate(sources) if str(args.repository) in source.get('Rubygems', {}).get('uri', '')]
    assert len(managed) == 1
    selected = {}
    for record in data['specs']:
        name, details = next(iter(record.items()))
        selected[name] = details['version']
        assert details['source'] == managed[0]
    assert selected == {name: entry['version'] for name, entry in entries.items()}
    return data


first = read_lock('read-native-yaml')
runtime = r'''require "historical_greeting"
require "bundler/version"
require "digest/sha2"
abort unless RUBY_VERSION == "1.8.7" && RUBY_PATCHLEVEL == 374 && Gem::VERSION == "1.8.30"
abort unless Bundler::VERSION == "0.9.26" && Bundler::LOCKED_BY == "0.9.26"
abort unless HistoricalGreeting.answer == 42 && JSON.parser == JSON::Ext::Parser
abort "resolver scope leaked" if Thread.current[:purifier_definition_sources]
puts "RUNTIME|#{RUBY_VERSION}|#{Gem::VERSION}|#{Bundler::VERSION}|42"
["json", "historical_greeting"].each do |name|
  spec = Gem.loaded_specs.fetch(name)
  puts "GEM|#{name}|#{spec.version}|#{spec.full_gem_path}"
end
paths = File.readlines("/proc/self/maps").map { |line| line.split.last }.uniq.select { |path| path =~ /json\/ext\/parser\.so$/ }
abort "ambiguous parser" unless paths.size == 1
puts "NATIVE|#{paths.first}|#{Digest::SHA256.file(paths.first).hexdigest}"
'''
output = run('runtime', ['exec', 'ruby', '-e', runtime])
for name, entry in entries.items():
    observed = next(line.split('|')[2:] for line in output.splitlines() if line.startswith('GEM|' + name + '|'))
    assert observed[0] == entry['version'] and observed[1].startswith(str(project / 'vendor/bundle') + '/')
native, digest = next(line.split('|')[1:] for line in output.splitlines() if line.startswith('NATIVE|'))
assert native.startswith(str(project / 'vendor/bundle') + '/')
assert hashlib.sha256(Path(native).read_bytes()).hexdigest() == digest
with tarfile.open(args.repository / entries['json']['archive']) as outer:
    payload = outer.extractfile('data.tar.gz').read()
with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as inner:
    parsers = [member for member in inner if member.isfile() and member.name.endswith('json/ext/parser.so')]
    assert len(parsers) == 1 and hashlib.sha256(inner.extractfile(parsers[0]).read()).hexdigest() == digest
if args.codec:
    captured = work / 'captured'
    capture_env = dict(env, BUNDLER_PURIFIER_INPUT_VIEWS='[]', SOURCE_DATE_EPOCH='1')
    run('capture-runtime-archives', ['exec', 'ruby', '-r', args.codec,
        root / 'tools/capture_gems.rb', captured], environment=capture_env)
    archives = list(captured.glob('*.gem'))
    assert len(archives) == 2
    destination = work / 'recaptured-ordinary'
    destination.mkdir()
    ordinary_env = {key: value for key, value in env.items()
                    if not key.startswith(('BUNDLE_', 'BUNDLER_PURIFIER_'))}
    ordinary_env.update(GEM_HOME=str(destination / 'gems'), GEM_PATH=str(destination / 'gems'))
    for name in ['json', 'historical_greeting']:
        archive = next(path for path in archives if path.name.startswith(name + '-'))
        run('recaptured-install-' + name, ['install', '--local', '--no-rdoc', '--no-ri', archive],
            cwd=destination, environment=ordinary_env, executable=args.sdk / 'bin/gem')
    ordinary_code = r'''require "historical_greeting"; require "digest/sha2"
abort if defined?(Bundler) || defined?(PurifierGemInputs)
abort unless HistoricalGreeting.answer == 42 && Gem::VERSION == "1.8.30"
paths = File.readlines("/proc/self/maps").map { |line| line.split.last }.uniq.select { |path| path =~ /json\/ext\/parser\.so$/ }
abort unless paths.size == 1 && paths.first.index(ENV["GEM_HOME"] + "/") == 0
puts Digest::SHA256.file(paths.first).hexdigest
'''
    assert run('recaptured-ordinary-runtime', ['-e', ordinary_code], cwd=destination,
               environment=ordinary_env, native=False).strip() == digest
    receipt['recapturedArchives'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in archives}
run('repeat-native-lock', ['lock'])
assert read_lock('read-repeated-yaml') == first
view = dict(repository=str(args.repository), catalog=str(args.catalog))
duplicate_env = dict(env, BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps([view, view]))
run('duplicate-view-lock', ['lock'], environment=duplicate_env)
assert read_lock('read-duplicate-yaml') == first
ordinary = work / 'ordinary'
ordinary.mkdir()
registries = [work / 'ordinary-first', work / 'ordinary-second']
for directory in registries:
    directory.mkdir()
    for kind in ['specs', 'latest_specs', 'prerelease_specs']:
        (directory / (kind + '.4.8.gz')).write_bytes(gzip.compress(b'\x04\x08[\x00', mtime=0))
(ordinary / 'Gemfile').write_text(''.join('source "' + directory.as_uri() + '/"\n' for directory in registries) + 'gem "missing_ordinary", ">= 1.0.0"\n')
failure = run('ordinary-fallback-order', ['install'], cwd=ordinary, success=False)
assert failure.index(str(registries[0])) < failure.index(str(registries[1]))
assert 'missing_ordinary' in failure
receipt.update(complete=True, nativeLockFormat='upstream YAML', nativeLockSha256=hashlib.sha256(lock.read_bytes()).hexdigest(),
               nativeParserSha256=digest, manifestSha256=hashlib.sha256(manifest).hexdigest(),
               nativeRelockSemanticsUnchanged=True, duplicateViewsUnchanged=True, ordinarySourceOrderRetained=True)
(work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('PASS native Ruby1.8/Gems1.8.30/Bundler0.9.26 input binding, YAML lock, compiled origin, duplicate views and ordinary-source fallback')
