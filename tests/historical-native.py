# SPDX-License-Identifier: MIT
"""Ruby 2.5 / Bundler 1.17 CLI and exact publication, x86_64 Linux only."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
cli, tools, repository, release = map(Path, sys.argv[1:5])
expected_ruby = sys.argv[5] if len(sys.argv) > 5 else '2.5.8'
fixture = sys.argv[6] if len(sys.argv) > 6 else 'historical-ruby'

def run(command, cwd, env):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                            text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f'{command}: {result.returncode}\n{result.stdout[-4000:]}\n{result.stderr[-6000:]}')
    return result.stdout

with tempfile.TemporaryDirectory(prefix='bundler117-native-') as temporary:
    work = Path(temporary)
    project = work / 'project'
    shutil.copytree(ROOT / 'tests/fixtures' / fixture, project)
    original = {p.relative_to(project): p.read_bytes() for p in project.rglob('*') if p.is_file()}
    home = work / 'home'
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), LC_ALL="C", PATH=f'{tools}/bin:' + os.environ['PATH'],
                       BUNDLE_USER_HOME=str(work / 'bundle-home'))
    environment.pop('GEM_HOME', None)
    environment.pop('GEM_PATH', None)
    assert run([tools / 'bin/ruby', '-e', 'print RUBY_VERSION'], project, environment) == expected_ruby
    assert '1.17.3' in run([tools / 'bin/bundle', '--version'], project, environment)
    patchlevel = {'1.8.7': '374', '2.5.8': '224'}[expected_ruby]
    assert run([tools / 'bin/ruby', '-e', 'print RUBY_PATCHLEVEL'], project, environment) == patchlevel
    gem_version = {'1.8.7': '2.6.14', '2.5.8': '3.1.2'}[expected_ruby]
    assert run([tools / 'bin/ruby', '-e', 'require "rubygems"; print Gem::VERSION'], project, environment) == gem_version
    command = cli / 'bin/bundler-purifier'
    run([command, 'lock', '--force'], project, environment)
    assert (project / 'Gemfile.lock').read_bytes() == original[Path('Gemfile.lock')]
    captured = json.loads((project / 'bundler-purifier.lock.json').read_text())
    assert captured['ruby'] == expected_ruby
    assert captured['bundlerHash'] == json.loads(original[Path('bundler-purifier.lock.json')])['bundlerHash']
    run([command, 'prefetch'], project, environment)
    compiler = run([command, 'shell', 'gcc', '--version'], project, environment).splitlines()[0]
    assert {'1.8.7': '4.8.', '2.5.8': '9.2.'}[expected_ruby] in compiler, compiler
    print('Selected native compiler: ' + compiler, flush=True)
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-Ilib', 'exe/historical-greeting'], project, environment) == '42 on ' + expected_ruby + '\n'
    print('PASS native lock, SDK/compiler propagation, prefetch and wrapper execution', flush=True)
    archives = {p.name: p.read_bytes() for p in (repository / 'gems').glob('*.gem')}
    native_archives = {p.name: p.read_bytes() for p in release.glob("*.gem")}
    digests = {hashlib.sha512(data).digest(): name for name, data in native_archives.items()}
    stored = {}
    uploads = []

    class Registry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self.send_response(404)
            self.end_headers()

        def do_GET(self):
            relative = self.path.lstrip('/')
            path = repository / relative
            data = stored.get(relative[5:]) if relative.startswith('gems/') else (path.read_bytes() if path.is_file() else None)
            self.send_response(200 if data is not None else 404)
            self.send_header('Content-Length', str(len(data or b'')))
            self.end_headers()
            self.wfile.write(data or b'')

        def do_POST(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            name = digests.get(hashlib.sha512(data).digest())
            if self.path != '/api/v1/gems' or name is None:
                self.send_error(400)
                return
            stored[name] = data
            uploads.append(name)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Successfully registered gem')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Registry)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = f'http://127.0.0.1:{server.server_port}'
    try:
        credentials = home / '.gem' / 'credentials'
        credentials.parent.mkdir(exist_ok=True)
        credentials.write_text('---\n:rubygems_api_key: fixture-key\n')
        credentials.chmod(0o600)
        publication = dict(environment, GEM_HOST_API_KEY='fixture-key')
        run([command, 'publish', '--host', host], project, publication)
        assert stored == native_archives
        print("PASS native publication matches pure release bytes", flush=True)
        stored.update(archives)
        home = work / 'ordinary'
        ordinary = dict(environment, GEM_HOME=str(home), GEM_PATH=str(home))
        # Use native gem directly: no purifier, Bundler plugin or build tools.
        root_archive = next(name for name in archives if name.startswith('historical_greeting-'))
        version = root_archive[len('historical_greeting-'):].removesuffix('.gem')
        run([tools / 'bin/gem', 'install', '--no-document', '--clear-sources', '--prerelease',
             '--source', host, 'historical_greeting', '--version', version], work, ordinary)
        assert run([tools / 'bin/ruby', '-e', r'require "historical_greeting"; abort unless $LOADED_FEATURES.any? { |path| path =~ /json\/ext\/parser\.so$/ }; abort unless Gem.loaded_specs.fetch("json").full_gem_path.start_with?(ENV.fetch("GEM_HOME") + "/"); print HistoricalGreeting.answer'], work, ordinary) == '42'
        print('PASS ordinary registry-index resolution, install and execution of projected compiled extension', flush=True)
    finally:
        server.shutdown()
        server.server_close()
    for relative, content in original.items():
        assert (project / relative).read_bytes() == content, relative
