# SPDX-License-Identifier: MIT
"""Actual early Bundler frontend and explicit separate native publisher."""
import argparse
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import threading

p = argparse.ArgumentParser()
for name in ['sdk', 'publisher-sdk', 'core', 'nixpkgs', 'work']:
    p.add_argument('--' + name, required=True, type=Path)
p.add_argument("--ruby", type=Path)
p.add_argument("--cli", type=Path)
p.add_argument("--archive", type=Path)
p.add_argument("--core-identity", type=Path)
a = p.parse_args()
assert a.cli or a.ruby, "select --cli or --ruby"
root = Path(__file__).resolve().parent.parent
a.work.mkdir()
logs = a.work / 'logs'
logs.mkdir()
home = a.work / 'home'
home.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith(('GEM_', 'RUBY', 'BUNDLE_', 'BUNDLER_')) and k.lower() not in ['http_proxy', 'https_proxy', 'all_proxy']}
env.update(HOME=str(home), BUNDLER_PURIFIER_PROJECT_RUBY=str(a.sdk),
    BUNDLER_PURIFIER_LIB=str(root / 'pkgs/cli'), BUNDLER_PURIFIER_TOOLS=str(root / 'pkgs/cli/tools'),
    BUNDLER_PURIFIER_SHARED_FLAKE='path:' + str(a.core),
    BUNDLER_PURIFIER_NIXPKGS='builtins.storePath ' + json.dumps(str(a.nixpkgs)))
receipt = dict(complete=False, commands=[], scope='Local Ruby183/Gem101/Bundler artifact031 project, separately attested Gem135 publisher, ordinary Gem101 consumer.')
receipt['sourceFiles'] = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(list((root / 'pkgs/cli/tools').glob('*.rb')) + list((root / 'pkgs/cli').glob('*.nix')) + list((root / 'lib-overlays/default').glob('*.nix')) + list((root / 'pkgs/build-bundler-project').glob('*.nix')) + [root / 'bin/bundler-purifier', Path(__file__).resolve()])}
if a.core_identity:
    import re
    identity = json.loads(a.core_identity.read_text())
    assert set(identity) == {'revision', 'narHash'}
    assert re.fullmatch('[0-9a-f]{40}', identity['revision'])
    actual = subprocess.check_output(['nix', 'hash', 'path', str(a.core)], text=True).strip()
    assert actual == identity['narHash']
    receipt['coreRevision'] = identity['revision']
    receipt['coreSourceNar'] = actual
else:
    receipt['coreRevision'] = subprocess.check_output(['git', '-C', str(a.core), 'rev-parse', 'HEAD'], text=True).strip()


def run(label, argv, cwd, environment=None, success=True, reason=None):
    result = subprocess.run(list(map(str, argv)), cwd=cwd, env=environment or env, capture_output=True, timeout=1800)
    for stream, raw in [('stdout', result.stdout), ('stderr', result.stderr)]:
        (logs / (label + '.' + stream)).write_bytes(raw)
    receipt['commands'].append(dict(label=label, argv=list(map(str, argv)), exit=result.returncode,
        expectedSuccess=success, stdoutSha256=hashlib.sha256(result.stdout).hexdigest(), stderrSha256=hashlib.sha256(result.stderr).hexdigest()))
    (a.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert (result.returncode == 0) == success, (label, result.stderr.decode()[-7000:])
    if reason:
        assert reason.encode() in result.stderr, (label, result.stderr.decode())
    return result.stdout


if a.archive is None:
    # Capture the SDK's actual compiled JSON through a fresh genuine empty
    # environment; CI never needs a prebuilt developer-machine archive.
    arena = a.work / 'sdk-capture'
    arena.mkdir()
    bootstrap = arena / 'project'
    bootstrap.mkdir()
    (bootstrap / 'Gemfile').write_text('# SDK native payload capture\n')
    inputs = arena / 'native-input-archives'
    inputs.mkdir()
    (inputs / 'inventory.tsv').write_text('')
    run('bootstrap-native-empty-environment', [a.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_v03_install.rb', bootstrap, inputs], bootstrap)
    capture_env = dict(env, BUNDLER_PURIFIER_PROJECT_ROOTS='["json"]')
    run('capture-sdk-native-json', [a.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_exec.rb', bootstrap, a.sdk, '--', a.sdk / 'bin/ruby', '-r', a.core / 'tools/rubygems_codec.rb', root / 'pkgs/cli/tools/capture_gems.rb', arena / 'archives'], bootstrap, capture_env)
    a.archive = arena / 'archives/json-1.1.3-x86_64-linux.gem'
    assert a.archive.is_file()

project = a.work / 'project'
shutil.copytree(root / 'tests/fixtures/ruby183', project)
(project / 'Gemfile').write_text('gem "json", "= 1.1.3"\n')
(project / 'vendor/cache').mkdir(parents=True)
shutil.copyfile(a.archive, project / 'vendor/cache/json-1.1.3-x86_64-linux.gem')
cli = [a.cli] if a.cli else [a.ruby, root / 'bin/bundler-purifier']
run('capture', cli + ['lock'], project)
lock = project / 'bundler-purifier.lock.json'
original = lock.read_bytes()
document = json.loads(original)
assert document['nativeResolution']['interface'] == 'environment-v03'
assert document['nativeResolution']['sdk']['rubygemsReport'] == dict(name='Gem::RubyGemsVersion', value='1.0.1')
assert all(package['sourceKind'] == 'verified-input' for package in document['nativeResolution']['packages'])
assert not (project / 'Gemfile.lock').exists()
run('capture-noop', cli + ['lock'], project)
assert lock.read_bytes() == original
run('reject-missing-replay', cli + ['shell', 'ruby', '-e', 'raise "unexpected activation"'], project, success=False, reason='native working state is missing')
run('prefetch', cli + ['prefetch'], project)
assert b'42 on 1.8.3' in run('runtime', cli + ['shell', 'ruby', '-Ilib', 'exe/historical-greeting'], project)
assert b'ARGV-PASS' in run('runtime-argv', cli + ['shell', 'ruby', '-e', 'raise unless ARGV==["space value","$literal","--dash"];puts "ARGV-PASS"', 'space value', '$literal', '--dash'], project)
run('reject-consumer-as-publisher', cli + ['publish'], project, success=False, reason='native SDK has no identity-bound publisher launcher')
published = {}
requests = []
agents = []
repository = None


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        assert self.path == '/api/v1/gems'
        assert self.headers['Authorization'] == 'v03-fixture-key'
        size = int(self.headers['Content-Length'])
        assert 0 < size < 16 * 1024 * 1024
        raw = self.rfile.read(size)
        with tarfile.open(fileobj=io.BytesIO(raw)) as gem:
            assert gem.getmember('data.tar.gz').isfile()
        published[hashlib.sha256(raw).hexdigest()] = raw
        agents.append(self.headers.get('User-Agent'))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK')

    def do_GET(self):
        requests.append(dict(method='GET', path=self.path))
        if self.path.startswith('/gems/'):
            if repository is None:
                self.send_error(404)
                return
            candidate = repository / 'gems' / self.path.removeprefix('/gems/')
            raw = candidate.read_bytes() if candidate.is_file() else b''
            if hashlib.sha256(raw).hexdigest() not in published:
                self.send_error(404)
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(raw)
            return
        super().do_GET()

    def do_HEAD(self):
        requests.append(dict(method='HEAD', path=self.path))
        super().do_HEAD()


server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(a.work)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
host = 'http://127.0.0.1:' + str(server.server_port)
(home / '.gem').mkdir()
(home / '.gem/credentials').write_text('---\n:rubygems_api_key: v03-fixture-key\n')
(home / '.gem/credentials').chmod(0o600)
try:
    run('publish', cli + ['publish', '--publisher-sdk', a.publisher_sdk, '--host', host], project)
    publication = json.loads((project / '.bundler-purifier/native-publication.json').read_text())
    assert publication['complete'] and publication['publisherSDK']['rubygemsReport'] == dict(name='Gem::VERSION', value='1.3.5')
    repository = Path(publication['repository'])
    archives = sorted((repository / 'gems').glob('*.gem'))
    assert len(archives) == len(published) == 2 and agents == ['Gemcutter/0.2.0'] * 2
    assert all(published[hashlib.sha256(archive.read_bytes()).hexdigest()] == archive.read_bytes() for archive in archives)
    # Serve indexes from exactly the repository whose archives were published.
    # Directory selection is per new request, after publication has completed.
    server.RequestHandlerClass = functools.partial(Handler, directory=str(repository))
    consumer_home = a.work / 'consumer-home'
    consumer_home.mkdir()
    (consumer_home / '.gemrc').write_text('---\n:sources:\n- ' + host + '\n:update_sources: true\n')
    ordinary = dict(env, HOME=str(consumer_home), GEM_HOME=str(a.work / 'gems'), GEM_PATH=str(a.work / 'gems'))
    version = next(p for p in archives if p.name.startswith('historical_greeting-')).name.removeprefix('historical_greeting-').removesuffix('.gem')
    run('ordinary-install', [a.sdk / 'bin/gem', 'install', '--remote', '--no-rdoc', '--no-ri', '--include-dependencies', '--no-http-proxy', '--source', host, 'historical_greeting', '--version', version], a.work, ordinary)
    code = 'require "historical_greeting";raise unless HistoricalGreeting.answer==42;raise unless Gem.loaded_specs["historical_greeting"].full_gem_path.index(ENV["GEM_HOME"]+"/")==0;raise unless Gem.loaded_specs["json"].full_gem_path.index(ENV["GEM_HOME"]+"/")==0;puts "ORDINARY|#{RUBY_VERSION}|#{Gem::RubyGemsVersion}|42";puts File.read("/proc/self/maps").split("\\n").select{|line|line.include?("parser.so")}'
    output = run('ordinary-native-runtime', [a.sdk / 'bin/ruby', '-e', code], a.work, ordinary)
    assert b'ORDINARY|1.8.3|1.0.1|42' in output
    assert str(a.work / 'gems/gems/json-').encode() in output
    parser = next((a.work / 'gems/gems').glob('json-*/ext/json/ext/parser.so'))
    body = next(archive.read_bytes() for archive in archives if archive.name.startswith('json-'))
    with tarfile.open(fileobj=io.BytesIO(body)) as archive:
        with tarfile.open(fileobj=io.BytesIO(archive.extractfile('data.tar.gz').read()), mode='r:gz') as payload:
            assert payload.extractfile('ext/json/ext/parser.so').read() == parser.read_bytes()
    # A relocated lock replays from vendored inputs with its original root absent.
    relocated = a.work / 'relocated'
    shutil.copytree(project, relocated, symlinks=True, ignore=shutil.ignore_patterns('.bundler-purifier'))
    hidden = a.work / 'original.hidden'
    project.rename(hidden)
    try:
        run('relocated-reject-missing-replay', cli + ['shell', 'ruby', '-e', 'raise "unexpected activation"'], relocated, success=False, reason='native working state is missing')
        run('relocated-prefetch', cli + ['prefetch'], relocated)
        assert b'42 on 1.8.3' in run('relocated-original-unavailable-runtime', cli + ['shell', 'ruby', '-Ilib', 'exe/historical-greeting'], relocated)
    finally:
        hidden.rename(project)
    receipt.update(complete=True, nativeSDK=document['nativeResolution']['sdk'], publication=publication,
        publishedArchiveHashes=sorted(published), nativePublisherUserAgents=agents, requests=requests,
        parser=dict(path=str(parser), sha256=hashlib.sha256(parser.read_bytes()).hexdigest(), matchesPublishedPayload=True))
    (a.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
finally:
    server.shutdown()
    server.server_close()
