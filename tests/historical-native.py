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
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
cli, tools, repository, release = map(Path, sys.argv[1:])

def run(command, cwd, env):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                            text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f'{command}: {result.returncode}\n{result.stdout[-4000:]}\n{result.stderr[-6000:]}')
    return result.stdout

with tempfile.TemporaryDirectory(prefix='bundler117-native-') as temporary:
    work = Path(temporary)
    project = work / 'project'
    shutil.copytree(ROOT / 'tests/fixtures/historical-ruby', project)
    original = {p.relative_to(project): p.read_bytes() for p in project.rglob('*') if p.is_file()}
    environment = dict(os.environ, PATH=f'{tools}/bin:' + os.environ['PATH'],
                       BUNDLE_USER_HOME=str(work / 'bundle-home'))
    environment.pop('GEM_HOME', None)
    environment.pop('GEM_PATH', None)
    assert run([tools / 'bin/ruby', '-e', 'print RUBY_VERSION'], project, environment) == '2.5.8'
    assert '1.17.3' in run([tools / 'bin/bundle', '--version'], project, environment)
    command = cli / 'bin/bundler-purifier'
    run([command, 'lock', '--force'], project, environment)
    assert (project / 'Gemfile.lock').read_bytes() == original[Path('Gemfile.lock')]
    captured = json.loads((project / 'bundler-purifier.lock.json').read_text())
    assert captured['ruby'] == '2.5.8'
    assert captured['bundlerHash'] == json.loads(original[Path('bundler-purifier.lock.json')])['bundlerHash']
    run([command, 'prefetch'], project, environment)
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-Ilib', 'exe/historical-greeting'], project, environment) == '42 on 2.5.8\n'
    print('PASS native lock, SDK/compiler propagation, prefetch and wrapper execution', flush=True)
    archives = {p.name: p.read_bytes() for p in (repository / 'gems').glob('*.gem')}
    native_archives = {p.name: p.read_bytes() for p in release.glob("*.gem")}
    digests = {hashlib.sha512(data).digest(): name for name, data in native_archives.items()}
    stored = {}
    uploads = []

    class Registry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

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
        publication = dict(environment, GEM_HOST_API_KEY='fixture-key')
        run([command, 'publish', '--host', host], project, publication)
        assert stored == native_archives
        print("PASS native publication matches pure release bytes", flush=True)
        stored.update(archives)
        home = work / 'ordinary'
        ordinary = dict(environment, GEM_HOME=str(home), GEM_PATH=str(home))
        # Use native gem directly: no purifier, Bundler plugin or build tools.
        for name in ('json', 'historical_greeting'):
            archive = next(key for key in archives if key.startswith(name + '-'))
            with urllib.request.urlopen(host + '/gems/' + archive) as response:
                downloaded = response.read()
            assert downloaded == archives[archive]
            target = work / archive
            target.write_bytes(downloaded)
            run([tools / 'bin/gem', 'install', '--local', '--no-document', target], work, ordinary)
        assert run([tools / 'bin/ruby', '-rhistorical_greeting', '-e', 'print HistoricalGreeting.answer'], work, ordinary) == '42'
        print('PASS ordinary HTTP consumer of projected compiled extension', flush=True)
    finally:
        server.shutdown()
        server.server_close()
    for relative, content in original.items():
        assert (project / relative).read_bytes() == content, relative
