# SPDX-License-Identifier: MIT
"""Ruby 1.8 incoming Nix gems, pure build and exact projected CLI publication."""
import argparse
import base64
import hashlib
import gzip
import http.server
import json
import io
import tarfile
import os
import re
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import sys
# Helper imports must not mutate the committed source used by this proof.
sys.dont_write_bytecode = True
from rubygems_dns_fixture import RegistryDNS

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cli', type=Path)
parser.add_argument('sdk', type=Path)
parser.add_argument('--results', type=Path)
parser.add_argument('--bundler-version', default='1.17.3')
parser.add_argument('--bundler-hash', default='sha256-vEv3W1SLJ0UaqfRDsYxGpzndIq1596X5C0hTdqZ9w1I=')
parser.add_argument('--sdk-check', default='ruby18-sdk')
parser.add_argument('--provider-check', default='ruby18-app')
parser.add_argument('--ruby-version', default='1.8.7')
parser.add_argument('--ruby-requirement')
parser.add_argument('--ruby-patchlevel', type=int, default=374)
parser.add_argument('--versionless', action='store_true')
parser.add_argument('--extra-gem-path', type=Path)
parser.add_argument('--rubygems-version', default='2.6.14')
parser.add_argument('--no-ruby-dsl', action='store_true')
parser.add_argument('--yaml-sdk', action='store_true')
parser.add_argument('--git-source', action='store_true')
parser.add_argument('--prefetch-git', type=Path)
parser.add_argument('--rubygems-update-archive', type=Path)
args = parser.parse_args()
assert not args.git_source or (args.yaml_sdk and args.prefetch_git and args.prefetch_git.is_file())
work = args.results.resolve() if args.results else Path(tempfile.mkdtemp(prefix='ruby18-incoming-'))
work.mkdir(parents=True, exist_ok=args.results is None)
logs = work / 'logs'
logs.mkdir()
receipt = dict(complete=False, commands=[], driverSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               scope='host CLI capture/publication plus separately sandboxed consumer build')
deadline = time.monotonic() + 1800
capture_server = None
home = work / 'home'
home.mkdir()
temporary = work / 'tmp'
temporary.mkdir()
env = {key: value for key, value in os.environ.items() if not key.startswith(('BUNDLE_', 'GEM_', 'RUBY'))}
env.update(HOME=str(home), TMPDIR=str(temporary), XDG_CACHE_HOME=str(work / 'cache'), XDG_DATA_HOME=str(work / 'data'), XDG_CONFIG_HOME=str(work / 'config'), LC_ALL='C', PATH=f'{args.sdk}/bin:{args.cli}/bin:' + os.environ['PATH'],
           BUNDLE_USER_HOME=str(work / 'bundle-home'))
if args.versionless:
    env['BUNDLER_PURIFIER_BUNDLER_VERSION'] = args.bundler_version
if args.extra_gem_path:
    env['GEM_PATH'] = str(args.extra_gem_path)


def save():
    (work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def run(label, command, cwd=ROOT, environment=None, success=True):
    if len(receipt['commands']) >= 32:
        raise AssertionError('bounded command budget exhausted')
    argv = list(map(str, command))
    stdout, stderr = logs / (label + '.stdout'), logs / (label + '.stderr')
    start = time.monotonic()
    entry = dict(label=label, argv=argv, cwd=str(cwd), expectedSuccess=success)
    receipt['commands'].append(entry)
    save()
    try:
        with stdout.open('w') as out, stderr.open('w') as err:
            process = subprocess.Popen(argv, cwd=cwd, env=env if environment is None else environment,
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                code = process.wait(timeout=min(600, max(1, deadline - time.monotonic())))
                entry['exit'] = code
            except BaseException:
                import signal
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
    except BaseException as error:
        entry['error'] = repr(error)
        raise
    finally:
        entry.update(seconds=time.monotonic() - start,
            stdoutSha256=hashlib.sha256(stdout.read_bytes()).hexdigest(),
            stderrSha256=hashlib.sha256(stderr.read_bytes()).hexdigest())
        save()
    assert (code == 0) == success, f'{label}: {code}\n{stdout.read_text()[-2000:]}\n{stderr.read_text()[-4000:]}'
    print('PASS ' + label, flush=True)
    return stdout.read_text() if success else stdout.read_text() + stderr.read_text()


try:
    versions = run('native-versions', [args.sdk / 'bin/ruby', '-e',
        'require "rubygems"; gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0"); require "bundler"; puts [RUBY_VERSION,RUBY_PATCHLEVEL,Gem::VERSION,Bundler::VERSION,Gem.ruby,RbConfig::CONFIG.fetch("prefix")].join("|")'])
    version_fields = versions.strip().split('|')
    assert version_fields[:4] == [args.ruby_version, str(args.ruby_patchlevel), args.rubygems_version, args.bundler_version], versions
    actual_ruby, actual_prefix = version_fields[4:]
    assert Path(actual_ruby).is_file()
    receipt['actualRubyExecutableSha256'] = hashlib.sha256(Path(actual_ruby).read_bytes()).hexdigest()
    revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    assert not subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']), 'native proof requires a clean committed source'
    archive = json.loads(run('source-archive', ['nix', 'flake', 'archive', '--json', '--no-update-lock-file',
        'git+file://' + str(ROOT) + '?rev=' + revision]))
    source = archive['path']
    assert not (Path(source) / '.git').exists(), 'archive must contain source bytes, not Git administration'
    receipt.update(sourceRevision=revision, sourceArchive=archive, nativeVersions=versions.strip(),
                   sourceNar=run('source-nar', ['nix', 'hash', 'path', source]).strip())
    project = work / 'consumer'
    (project / 'lib').mkdir(parents=True)
    capture_requests = []
    # Normal native capture may inspect ordinary sources even when all
    # dependencies are provided. Supply a real empty RubyGems index, then
    # shut it down before offline wrapper execution and pure builds.
    empty_index = gzip.compress(b'\x04\x08[\x00', mtime=0)

    class EmptyRegistry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            name = self.path.lstrip('/')
            data = empty_index if name in ('specs.4.8.gz', 'latest_specs.4.8.gz', 'prerelease_specs.4.8.gz') else None
            capture_requests.append(dict(path=self.path, status=200 if data else 404))
            if len(capture_requests) > 64:
                self.send_error(429)
                return
            self.send_response(200 if data else 404)
            self.send_header('Content-Length', str(len(data or b'')))
            self.end_headers()
            self.wfile.write(data or b'')

    capture_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), EmptyRegistry)
    threading.Thread(target=capture_server.serve_forever, daemon=True).start()
    capture_host = f'http://127.0.0.1:{capture_server.server_port}'
    if args.git_source:
        git_repo = work / 'git-leaf'
        (git_repo / 'lib').mkdir(parents=True)
        (git_repo / 'lib/git_leaf.rb').write_text('module GitLeaf; def self.answer; 17; end; end\n')
        (git_repo / 'git_leaf.gemspec').write_text('Gem::Specification.new {|s| s.name="git_leaf"; s.version="1.0.0"; s.authors=["fixture"]; s.summary="native Git"; s.files=["lib/git_leaf.rb"] }\n')
        run('git-init', ['git', 'init', '-q', '-b', 'main'], git_repo)
        run('git-add', ['git', 'add', '.'], git_repo)
        run('git-commit', ['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], git_repo)
    ruby_declaration = '' if args.no_ruby_dsl else 'ruby ' + json.dumps(args.ruby_requirement or args.ruby_version) + '\n'
    manifest = f'source "{capture_host}"\n' + ruby_declaration + ('path "." do\n  gem "incoming_consumer", "= 1.0.0"\nend\n' if args.yaml_sdk else 'gemspec\n')
    if args.git_source:
        manifest += 'git ' + json.dumps(git_repo.as_uri()) + ', :branch => "main" do\n gem "git_leaf", "= 1.0.0"\nend\n'
    if args.no_ruby_dsl:
        (project / '.ruby-version').write_text(args.ruby_version + '\n')
    gemspec = '''Gem::Specification.new do |s|
  s.name="incoming_consumer"; s.version="1.0.0"; s.authors=["fixture"]
  s.summary="Ruby 1.8 incoming Nix dependency proof"; s.license="MIT"
  s.files=["lib/incoming_consumer.rb"]
  s.add_runtime_dependency "historical_greeting", ">= 99"
end
'''
    if args.git_source:
        gemspec = gemspec.replace('end\n', '  s.add_runtime_dependency "git_leaf", "= 1.0.0"\nend\n')
    (project / 'Gemfile').write_text(manifest)
    (project / 'incoming_consumer.gemspec').write_text(gemspec)
    (project / 'lib/incoming_consumer.rb').write_text('''require "historical_greeting"
module IncomingConsumer
  def self.answer
    raise "wrong Ruby" unless RUBY_VERSION == "1.8.7" && RUBY_PATCHLEVEL == 374
    HistoricalGreeting.answer
  end
end
''')
    if args.git_source:
        consumer = project / 'lib/incoming_consumer.rb'
        consumer.write_text(consumer.read_text().replace('    HistoricalGreeting.answer', '    require "git_leaf"\n    abort unless GitLeaf.answer == 17\n    HistoricalGreeting.answer'))
    consumer_file = project / 'lib/incoming_consumer.rb'
    consumer_file.write_text(consumer_file.read_text().replace('RUBY_VERSION == "1.8.7"', 'RUBY_VERSION == ' + json.dumps(args.ruby_version)).replace('RUBY_PATCHLEVEL == 374', 'RUBY_PATCHLEVEL == ' + str(args.ruby_patchlevel)))
    reference = f'path:{source}#checks.x86_64-linux.{args.provider_check}'
    command = args.cli / 'bin/bundler-purifier'
    run('capture-input', [command, 'lock', '--input', reference], project)
    native_lock = (project / 'Gemfile.lock').read_bytes()
    lock_bytes = (project / 'bundler-purifier.lock.json').read_bytes()
    captured = json.loads(lock_bytes)
    assert captured['ruby'] == args.ruby_version
    if args.versionless:
        assert b'BUNDLED WITH' not in native_lock
        assert captured['bundlerVersion'] == args.bundler_version
    else:
        assert re.search(rb'(?m)^BUNDLED WITH\n[ \t]+' + re.escape(args.bundler_version.encode()) + rb'\n', native_lock)
        assert 'bundlerVersion' not in captured
    assert captured['bundlerHash'] == args.bundler_hash
    assert len(captured['projectInputs']) == 1 and not captured.get('gemHashes')
    assert 'narHash' in json.dumps(captured['projectInputs'])
    run('no-op-capture', [command, 'lock'], project)
    assert (project / 'bundler-purifier.lock.json').read_bytes() == lock_bytes
    run('relock', [command, 'lock', '--force'], project)
    if args.yaml_sdk:
        # Ruby 1.8 YAML emits hash entries in native iteration order.
        # Preserve and bind those real bytes; require the same SDK graph.
        refreshed = json.loads((project / 'bundler-purifier.lock.json').read_bytes())
        old_snapshot = captured['bundlerNativeLock']
        new_snapshot = refreshed['bundlerNativeLock']
        assert old_snapshot['observed'] == new_snapshot['observed']
        assert old_snapshot['parsed'] == new_snapshot['parsed']
        assert new_snapshot['nativeHash'] == 'sha256-' + base64.b64encode(hashlib.sha256((project / 'Gemfile.lock').read_bytes()).digest()).decode()
        omitted = {'definitionHash', 'contentHash', 'bundlerNativeLock'}
        assert {k: v for k, v in captured.items() if k not in omitted} == {k: v for k, v in refreshed.items() if k not in omitted}
        receipt['nativeRelockContract'] = 'unchanged selected graph and SDK; exact fresh native YAML hash, no upstream byte-order claim'
    else:
        assert (project / 'bundler-purifier.lock.json').read_bytes() == lock_bytes
    if args.yaml_sdk:
        captured = json.loads((project / 'bundler-purifier.lock.json').read_bytes())
        lock_bytes = (project / 'bundler-purifier.lock.json').read_bytes()
        native_lock = (project / 'Gemfile.lock').read_bytes()
    if args.git_source:
        git_rev = subprocess.check_output(['git', '-C', str(git_repo), 'rev-parse', 'HEAD'], text=True).strip()
        seeded = json.loads(run('preseed-git', [args.prefetch_git, '--quiet', '--name', 'git-leaf-' + git_rev[:12], '--url', git_repo.as_uri(), '--rev', git_rev]))
        assert seeded['hash'] == captured['gitHashes'][git_rev]
        import shutil
        shutil.rmtree(git_repo)
        receipt['originalGitSourceRemovedBeforeOfflineExecution'] = True
    run('prefetch', [command, 'prefetch'], project)
    capture_server.shutdown()
    capture_server.server_close()
    capture_server = None
    receipt['captureRegistryRequests'] = capture_requests
    receipt['captureRegistryStoppedBeforeOfflineExecution'] = True
    code = 'require "incoming_consumer"; require "bundler/version"; abort unless IncomingConsumer.answer==42; puts "INCOMING|#{RUBY_VERSION}|#{Gem::VERSION}|#{Bundler::VERSION}|42"'
    output = run('wrapper-runtime', [args.cli / 'bin/bundle', 'exec', 'ruby', '-Ilib', '-e', code], project)
    assert output == f'INCOMING|{args.ruby_version}|{args.rubygems_version}|{args.bundler_version}|42\n', output
    expression = work / 'consumer.nix'
    expression.write_text('''let
  f = builtins.getFlake "path:''' + source + '''";
  pkgs = import f.inputs.nixpkgs {};
  readLock = import (f.outPath + "/nix/lib/read-lock.nix") { inherit (pkgs) lib; };
  build = pkgs.callPackage (f.outPath + "/nix/lib/build-bundler-project.nix") {
    inherit readLock; inherit (f.inputs.purifier.lib) purifier;
  };
in build {
  src = builtins.toPath ''' + json.dumps(str(project)) + ''';
  ruby = f.checks.x86_64-linux.''' + args.sdk_check + ''';
  checkCommand = "bundle exec ruby -Ilib -e 'require %q(incoming_consumer); abort unless IncomingConsumer.answer == 42'";
}
''')
    tests = run('pure-tests', ['nix-build', expression, '-A', 'tests', '--no-out-link', '--option', 'sandbox', 'true']).strip()
    repository = Path(run('pure-projection', ['nix-build', expression, '-A', 'release.projections.rubygems', '--no-out-link']).strip())
    output_info = json.loads(run('output-info', ['nix', 'path-info', '--json', tests, repository, args.cli, args.sdk, actual_prefix]))
    receipt['outputInfo'] = output_info
    # A cache's historical deriver may be absent; verify a currently valid
    # derivation still produces the exact native interpreter output.
    native_derivers = run('native-valid-derivers', ['nix-store', '--query', '--valid-derivers', actual_prefix]).splitlines()
    assert native_derivers, 'native interpreter has no available derivation'
    receipt['nativeInterpreterDerivers'] = native_derivers
    derivations = sorted({info['deriver'] for path, info in output_info.items() if path != actual_prefix} | set(native_derivers))
    derivation_data = json.loads(run('derivations', ['nix', 'derivation', 'show', *derivations]))
    rows = derivation_data.get('derivations', derivation_data)
    assert any(row['system'] == 'x86_64-linux' and any(
        output.get('path') in (actual_prefix, actual_prefix.removeprefix('/nix/store/'))
        for output in row['outputs'].values()) for row in rows.values()), 'derivation must produce the actual interpreter'
    if args.versionless and not args.yaml_sdk:
        if args.extra_gem_path:
            higher_env = dict(env)
            higher_env.pop('BUNDLER_PURIFIER_BUNDLER_VERSION', None)
            higher = run('higher-sdk-visible', [args.sdk / 'bin/ruby', '-e',
                'require "bundler"; puts Bundler::VERSION'], project, higher_env)
            assert higher.strip() == '1.17.3', higher
            wrong_sdk = dict(env, BUNDLER_PURIFIER_BUNDLER_VERSION='1.17.3')
            failure = run('reject-actual-higher-sdk', [command, 'prefetch'], project, wrong_sdk, success=False)
            assert 'selected native Bundler SDK 1.17.3 conflicts with recorded bundlerVersion' in failure

        def write_variant(value):
            value.pop('contentHash', None)
            canonical = json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
            value['contentHash'] = 'sha256-' + base64.b64encode(hashlib.sha256(canonical).digest()).decode()
            (project / 'bundler-purifier.lock.json').write_text(json.dumps(value, indent=2) + '\n')

        for label, version, expected in [
                ('missing-fallback', None, 'lacks bundlerVersion'),
                ('wrong-metadata', '1.17.3', 'conflicts with recorded bundlerVersion')]:
            variant = dict(captured)
            if version is None:
                variant.pop('bundlerVersion')
            else:
                variant['bundlerVersion'] = version
            try:
                write_variant(variant)
                failure = run('reject-' + label, [command, 'prefetch'], project, success=False)
                assert expected in failure, failure
                failure = run('pure-reject-' + label, ['nix-build', expression, '-A', 'tests', '--no-out-link'], success=False)
                assert ('lacks bundlerVersion' in failure if version is None else 'hash mismatch' in failure), failure
            finally:
                (project / 'bundler-purifier.lock.json').write_bytes(lock_bytes)

        # Deliberate corruption negative: both independently readable SDK
        # identities must agree. The positive native lock has no marker.
        try:
            (project / 'Gemfile.lock').write_bytes(native_lock + b'\nBUNDLED WITH\n   1.17.3\n')
            variant = dict(captured)
            definitions = sorted(['Gemfile', 'Gemfile.lock', 'incoming_consumer.gemspec'])
            digest = hashlib.sha256()
            for name in definitions:
                data = (project / name).read_bytes()
                digest.update(f'{name}\n{len(data)}\n'.encode() + data + b'\n')
            variant['definitionHash'] = 'sha256-' + base64.b64encode(digest.digest()).decode()
            write_variant(variant)
            failure = run('reject-marker-conflict', [command, 'prefetch'], project, success=False)
            assert 'bundlerVersion conflicts with native BUNDLED WITH' in failure, failure
            failure = run('pure-reject-marker-conflict', ['nix-build', expression, '-A', 'tests', '--no-out-link'], success=False)
            assert 'bundlerVersion conflicts with native BUNDLED WITH' in failure, failure
        finally:
            (project / 'Gemfile.lock').write_bytes(native_lock)
            (project / 'bundler-purifier.lock.json').write_bytes(lock_bytes)
        receipt['versionlessIdentityNegatives'] = ['missing-fallback', 'wrong-metadata', 'marker-conflict']

    if args.yaml_sdk:
        import copy
        for label in ('missing-snapshot', 'wrong-hash', 'wrong-sdk', 'stale-native-bytes'):
            variant = copy.deepcopy(captured)
            if label == 'missing-snapshot':
                variant.pop('bundlerNativeLock')
            elif label == 'wrong-hash':
                variant['bundlerNativeLock']['nativeHash'] = 'sha256-invalid'
            elif label == 'wrong-sdk':
                variant['bundlerNativeLock']['observed']['bundler'] = '0.9.25'
            else:
                (project / 'Gemfile.lock').write_bytes(native_lock + b'\n')
            variant.pop('contentHash')
            canonical = json.dumps(variant, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
            variant['contentHash'] = 'sha256-' + base64.b64encode(hashlib.sha256(canonical).digest()).decode()
            try:
                (project / 'bundler-purifier.lock.json').write_text(json.dumps(variant) + '\n')
                failure = run('reject-' + label, [command, 'prefetch'], project, success=False)
                assert 'native' in failure and 'recapture' in failure.lower(), failure
                failure = run('pure-reject-' + label, ['nix-build', expression, '-A', 'tests', '--no-out-link'], success=False)
                assert 'native YAML snapshot' in failure and 'Recapture' in failure, failure
            finally:
                (project / 'Gemfile.lock').write_bytes(native_lock)
                (project / 'bundler-purifier.lock.json').write_bytes(lock_bytes)
        receipt['nativeYamlNegatives'] = ['missing-snapshot', 'wrong-hash', 'wrong-sdk', 'stale-native-bytes']

    archives = {path.name: path.read_bytes() for path in (repository / 'gems').glob('*.gem')}
    assert len(archives) == 3 + int(args.git_source)
    by_digest = {hashlib.sha512(data).digest(): name for name, data in archives.items()}
    stored, uploads = {}, []
    publication_agents = []
    indexes = {str(path.relative_to(repository)): path.read_bytes() for path in repository.rglob('*')
               if path.is_file() and 'gems' not in path.relative_to(repository).parts}
    registry_sdk_archives = {}
    if args.rubygems_update_archive is not None or int(args.rubygems_version.split('.')[0]) < 2:
        # Native historical RubyGems push first queries the configured source for
        # rubygems-update. Serve its genuine SDK archive in this private
        # registry; retain the client's upstream check without network access.
        update = args.rubygems_update_archive
        assert update is not None and update.is_file()
        update_bytes = update.read_bytes()
        update_hashes = {
            '1.8.30': 'e9f5e3052c5db8d1bf77c2a65047ed5bd9977b73c0ed908c406610210591854c',
            '2.7.6': 'ee5ef219ac97f5499c31e6071eae424c3265620ece33b5cc66e09fa30f22086a',
            '3.1.2': '7bfe4e5e274191e56da8d127c79df10d9120feb8650e4bad29238f4b2773a661',
            '2.6.14': 'ecaedf77483549e73a33a6779f4769aff6198c7f50df124256cc869cc905ffae',
        }
        assert hashlib.sha256(update_bytes).hexdigest() == update_hashes[args.rubygems_version]
        registry_sdk_archives['rubygems-update-' + args.rubygems_version + '.gem'] = update_bytes
        index_directory = work / 'publication-index'
        index_directory.mkdir()
        index_output = run('native-publication-index', [args.sdk / 'bin/ruby', ROOT / 'tests/rubygems-registry-index.rb',
            index_directory, update, repository])
        assert index_output == f'NATIVE_INDEX|{args.ruby_version}|{args.rubygems_version}|{4 + int(args.git_source)}\n', index_output
        indexes.update({str(path.relative_to(index_directory)): path.read_bytes()
                       for path in index_directory.rglob('*') if path.is_file()})
        receipt['publicationSdkArchiveSha256'] = hashlib.sha256(update_bytes).hexdigest()

    class Registry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            name = self.path.lstrip('/')
            data = (stored.get(name[5:]) or registry_sdk_archives.get(name[5:])) if name.startswith('gems/') else indexes.get(name)
            self.send_response(200 if data is not None else 404)
            self.send_header('Content-Length', str(len(data or b'')))
            self.end_headers()
            self.wfile.write(data or b'')

        def do_POST(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            name = by_digest.get(hashlib.sha512(data).digest())
            if self.headers.get('Authorization') != 'fixture-key':
                self.send_error(403)
                return
            publication_agents.append(self.headers.get('User-Agent'))
            if self.path != '/api/v1/gems' or name is None:
                self.send_error(400)
                return
            stored[name] = data
            uploads.append(name)
            body = b'Successfully registered gem'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Registry)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = f'http://127.0.0.1:{server.server_port}'
    dns_fixture = RegistryDNS()
    receipt['fixtureDnsRequests'] = dns_fixture.requests
    receipt['fixtureDnsHelperSha256'] = hashlib.sha256((ROOT / 'tests/rubygems_fixture_dns.rb').read_bytes()).hexdigest()
    try:
        # RubyGems 2.6 predates GEM_HOST_API_KEY. Give the native client its
        # own private fixture credentials file, never the user's home.
        credentials = home / '.gem/credentials'
        credentials.parent.mkdir(exist_ok=True)
        credentials.write_text('---\n:rubygems_api_key: fixture-key\n')
        credentials.chmod(0o600)
        if registry_sdk_archives:
            (home / '.gemrc').write_text('---\n:sources:\n- ' + host + '\n')
        local_registry_env = {key: value for key, value in env.items()
                              if key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
        local_registry_env.update(PURIFIER_FIXTURE_DNS_PORT=str(dns_fixture.port),
                                  RUBYOPT='-r' + str(ROOT / 'tests/rubygems_fixture_dns.rb'))
        publication = dict(local_registry_env, GEM_HOST_API_KEY='fixture-key')
        proxy_flags = ['--no-http-proxy'] if registry_sdk_archives else []
        publish = [command, 'publish', '--host', host, *proxy_flags]
        run('publish-projected', publish, project, publication)
        assert stored == archives
        assert publication_agents and all(agent.removeprefix('Ruby, ').startswith('RubyGems/' + args.rubygems_version + ' ') for agent in publication_agents), publication_agents
        receipt['publicationNativeUserAgents'] = publication_agents
        count = len(uploads)
        run('publish-dedup', publish, project, publication)
        assert len(uploads) == count
        ordinary = work / 'ordinary'
        ordinary.mkdir()
        ordinary_env = dict(local_registry_env, GEM_HOME=str(ordinary / 'gems'), GEM_PATH=str(ordinary / 'gems'))
        root_archive = next(name for name in archives if name.startswith('incoming_consumer-'))
        version = root_archive[len('incoming_consumer-'):-len('.gem')]
        gem_help = run('native-gem-install-help', [args.sdk / 'bin/gem', 'help', 'install'], ordinary, ordinary_env)
        doc_flags = ['--no-document'] if '--no-document' in gem_help or '--[no-]document' in gem_help else ['--no-rdoc', '--no-ri']
        run('ordinary-install', [args.sdk / 'bin/gem', 'install', *doc_flags, *proxy_flags, '--clear-sources', '--prerelease',
            '--source', host, 'incoming_consumer', '--version', version], ordinary, ordinary_env)
        ordinary_code = r'''require "incoming_consumer"
require "digest/sha2"
abort "purifier leaked into ordinary consumer" if defined?(PurifierGemInputs)
abort unless IncomingConsumer.answer == 42 && JSON.parser == JSON::Ext::Parser
puts "ORDINARY|#{RUBY_VERSION}|#{RUBY_PATCHLEVEL}|#{Gem::VERSION}|42"
paths = File.readlines("/proc/self/maps").map { |line| line.split.last }.uniq.select { |path| path =~ /json\/ext\/parser\.so$/ }
abort "ambiguous parser" unless paths.size == 1
native = paths.first
abort "not installed ordinary gem" unless native.start_with?(ENV.fetch("GEM_HOME") + "/")
puts "NATIVE|#{native}|#{Digest::SHA256.file(native).hexdigest}"
'''
        ordinary_output = run('ordinary-runtime', [args.sdk / 'bin/ruby', '-e', ordinary_code], ordinary, ordinary_env)
        assert f'ORDINARY|{args.ruby_version}|{args.ruby_patchlevel}|{args.rubygems_version}|42' in ordinary_output.splitlines()
        observed = [line.split('|')[1:] for line in ordinary_output.splitlines() if line.startswith('NATIVE|')]
        assert len(observed) == 1
        native_path, native_hash = observed[0]
        assert hashlib.sha256(Path(native_path).read_bytes()).hexdigest() == native_hash
        json_archive = next(data for name, data in archives.items() if name.startswith('json-'))
        with tarfile.open(fileobj=io.BytesIO(json_archive)) as archive:
            payload = archive.extractfile('data.tar.gz').read()
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as payload:
            parsers = [member for member in payload if member.isfile() and member.name.endswith('json/ext/parser.so')]
            assert len(parsers) == 1
            assert hashlib.sha256(payload.extractfile(parsers[0]).read()).hexdigest() == native_hash
        receipt['ordinaryLoadedNativeSha256'] = native_hash
        stored[root_archive] = b'wrong publication bytes'
        rejected = run('reject-wrong-existing-bytes', publish, project, publication, success=False)
        assert 'published gem has different bytes' in rejected and len(uploads) == count
    finally:
        server.shutdown()
        server.server_close()
        dns_fixture.close()
    assert (project / 'Gemfile').read_text() == manifest
    assert (project / 'incoming_consumer.gemspec').read_text() == gemspec
    assert (project / 'Gemfile.lock').read_bytes() == native_lock
    assert (project / 'bundler-purifier.lock.json').read_bytes() == lock_bytes
    receipt.update(complete=True, providerReference=reference, projectInputs=captured['projectInputs'],
        nativeLockSha256=hashlib.sha256(native_lock).hexdigest(), lockSha256=hashlib.sha256(lock_bytes).hexdigest(),
        pureRepository=str(repository), publishedArchives={name: hashlib.sha256(data).hexdigest() for name, data in archives.items()})
finally:
    if capture_server is not None:
        capture_server.shutdown()
        capture_server.server_close()
    save()
print(f'PASS Ruby{args.ruby_version} incoming CLI composition, pure build, projected publication and ordinary consumer', flush=True)
