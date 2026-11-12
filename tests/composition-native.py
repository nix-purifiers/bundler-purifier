# SPDX-License-Identifier: MIT
"""Native CLI, wrapper, publication, and ordinary consumer composition proof."""
import hashlib
import contextlib
import http.server
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=ROOT, env=None, status=0):
    result = subprocess.run([str(part) for part in command], cwd=cwd,
                            env=env, text=True, capture_output=True)
    if result.returncode != status:
        raise AssertionError(f'{command}: {result.returncode}\n{result.stdout[-3000:]}\n{result.stderr[-6000:]}')
    return result.stdout


system = run(['nix', 'eval', '--raw', '--impure', '--expr', 'builtins.currentSystem']).strip()
cli = Path(run(['nix', 'build', '.#cli', '--no-link', '--print-out-paths']).strip())
ruby = Path(run(['nix', 'eval', '--raw', '.#cli.ruby.outPath']).strip())
source = Path(json.loads(run(['nix', 'flake', 'archive', '--json', '.']))['path'])
reference = f'path:{source}#checks.{system}.fixture-library-app'
run(['nix', 'eval', '--raw', '--impure', '--expr',
     f'let family = builtins.getFlake "path:{source}"; pkgs = import family.inputs.nixpkgs {{ overlays = [ family.overlays.default ]; }}; in pkgs.bundler-purifier.cli.drvPath'])
nixpkgs = run(['nix', 'eval', '--raw', '--impure', '--expr',
               f'(builtins.getFlake "path:{source}").inputs.nixpkgs.outPath']).strip()
lock = json.loads((source / 'flake.lock').read_text())
pinned = lock['nodes'][lock['nodes']['root']['inputs']['purifier']]['locked']
shared = f"github:{pinned['owner']}/{pinned['repo']}/{pinned['rev']}"

context = contextlib.nullcontext(tempfile.mkdtemp(prefix='bundler-composition-debug-')) if os.environ.get('PURIFIER_COMPOSITION_KEEP') else tempfile.TemporaryDirectory(prefix='bundler-composition-')
with context as temporary:
    work = Path(temporary)
    print(f"Composition workspace: {work}", flush=True)
    project = work / 'consumer'
    project.mkdir()
    manifest = 'source "https://rubygems.org"\ngemspec\n'
    gemspec = 'Gem::Specification.new do |s|\n  s.name="composed-consumer"; s.version="1.0.0"; s.authors=["fixture"]; s.summary="Composed native publication"; s.license="MIT"\n  s.files=["lib/composed_consumer.rb"]\n  s.add_runtime_dependency "greeting", ">= 99"\nend\n'
    (project / 'composed-consumer.gemspec').write_text(gemspec)
    (project / 'lib').mkdir()
    (project / 'lib/composed_consumer.rb').write_text('require "greeting"\nComposedConsumer = Greeting.hello("nix")\n')
    (project / 'Gemfile').write_text(manifest)
    env = dict(os.environ, PATH=f'{ruby}/bin:{cli}/bin:' + os.environ['PATH'],
               BUNDLE_USER_HOME=str(work / 'bundle-home'))
    run([cli / 'bin/bundler-purifier', 'lock', '--input', reference], project, env)
    print("Native lock captured", flush=True)
    captured = json.loads((project / 'bundler-purifier.lock.json').read_text())
    assert len(captured['projectInputs']) == 1
    assert not captured.get('gemHashes')
    assert (project / 'Gemfile').read_text() == manifest
    assert (project / 'composed-consumer.gemspec').read_text() == gemspec
    stable = (project / 'bundler-purifier.lock.json').read_bytes()
    run([cli / 'bin/bundler-purifier', 'lock', '--force'], project, env)
    assert (project / 'bundler-purifier.lock.json').read_bytes() == stable
    code = 'require "greeting"; raise unless Greeting.hello("nix").include?("hello, nix"); puts "PURIFIED"'
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-e', code], project, env) == 'PURIFIED\n'
    subdir = project / 'subdir'
    subdir.mkdir()
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-e',
                code + '; raise unless File.basename(Dir.pwd)=="subdir"'], subdir, env) == 'PURIFIED\n'
    run([cli / 'bin/bundle', 'add', 'rainbow', '--version', '>= 99'], project, env)
    assert 'rainbow' in (project / 'Gemfile').read_text()
    run([cli / 'bin/bundle', 'remove', 'rainbow'], project, env)
    assert 'rainbow' not in (project / 'Gemfile').read_text()

    print("Wrapper runtime and mutations passed", flush=True)
    outside = work / 'outside-consumer'
    outside.mkdir()
    locks = work / 'locks'
    locks.mkdir()
    (outside / 'Gemfile').write_bytes((project / 'Gemfile').read_bytes())
    (outside / 'composed-consumer.gemspec').write_text(gemspec)
    shutil.copytree(project / 'lib', outside / 'lib')
    for name in ('Gemfile.lock', 'bundler-purifier.lock.json'):
        (locks / name).write_bytes((project / name).read_bytes())
    external_env = dict(env, BUNDLER_PURIFIER_LOCKFILE=str(locks / 'bundler-purifier.lock.json'),
                        BUNDLER_PURIFIER_TOOL_LOCKFILE=str(locks / 'Gemfile.lock'))
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-e', code], outside, external_env) == 'PURIFIED\n'
    assert not (outside / 'Gemfile.lock').exists()
    assert not (outside / 'bundler-purifier.lock.json').exists()

    print("External native and purifier locks passed", flush=True)
    git_project = work / 'provided-git'
    git_project.mkdir()
    (git_project / 'Gemfile').write_text('source "https://rubygems.org"\ngem "greeting", ">= 99", git: "https://unreachable.invalid/library"\n')
    (git_project / 'Gemfile.lock').write_text("GIT\n  remote: https://unreachable.invalid/library\n  revision: " + "a" * 40 + "\n  specs:\n    greeting (99.0.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  greeting (>= 99)!\n\nBUNDLED WITH\n   2.6.9\n")
    bootstrap = work / 'provided-git-lock.rb'
    bootstrap.write_text('load ARGV.fetch(0); bp=BundlerPurifier; lock=JSON.parse(File.read(ARGV.fetch(1))); lock["definitionHash"]=bp.definition_hash; lock["contentHash"]=bp.content_hash(lock); File.open("bundler-purifier.lock.json","w") { |file| file.puts(JSON.pretty_generate(lock)) }')
    run([ruby / 'bin/ruby', bootstrap, source / 'bin/bundler-purifier', project / 'bundler-purifier.lock.json'], git_project, env)
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-e', code], git_project, env) == 'PURIFIED\n'
    assert 'https://unreachable.invalid/library' in (git_project / 'Gemfile').read_text()
    print("Ordinary Git lock binds to Nix without fetching Git", flush=True)

    sdk_project = work / 'sdk-consumer'
    sdk_project.mkdir()
    (sdk_project / 'Gemfile').write_text('source "https://rubygems.org"\ngem "pathname", ">= 99"\n')
    sdk_reference = f'path:{source}#checks.{system}.composition-native.sdkInput'
    run([cli / 'bin/bundler-purifier', 'lock', '--input', sdk_reference], sdk_project, env)
    sdk_lock = json.loads((sdk_project / 'bundler-purifier.lock.json').read_text())
    assert not sdk_lock.get('gemHashes')
    assert run([cli / 'bin/bundle', 'exec', 'ruby', '-e',
                'require "pathname"; raise unless Pathname.new("a").join("b").to_s=="a/b"; puts "SDK"'], sdk_project, env) == 'SDK\n'
    print("Nix SDK dependency selects Ruby automatically without artifact hashes", flush=True)

    unlocked = work / 'unlocked'
    unlocked.mkdir()
    (unlocked / 'Gemfile').write_text('source "https://rubygems.org"\n')
    result = subprocess.run([str(cli / 'bin/bundle'), 'exec', 'ruby', '-e', 'puts "IMPURE"; exit 37'],
                            cwd=unlocked, env=env, text=True, capture_output=True)
    assert result.returncode == 37 and result.stdout == 'IMPURE\n'
    assert 'no lockfile; using ordinary, impure Bundler resolution' in result.stderr

    args = work / 'arguments.json'
    args.write_text(json.dumps(dict(family=str(source), consumer=str(project), nixpkgs=nixpkgs, shared=shared)))
    expression = work / 'consumer.nix'
    expression.write_text('''let
      args = builtins.fromJSON (builtins.readFile "''' + str(args) + '''");
      pkgs = import args.nixpkgs {};
      readLock = import (args.family + "/lib-overlays/default/read-lock.nix") { inherit (pkgs) lib; };
      build = pkgs.callPackage (args.family + "/pkgs/build-bundler-project/default.nix") {
        inherit readLock;
        inherit ((builtins.getFlake args.shared).lib) purifier;
      };
    in build {
      src = builtins.toPath args.consumer;
      checkCommand = "bundle exec ruby -e 'require \\\"greeting\\\"'";
    }
    ''')
    run(['nix-build', expression, '-A', 'tests', '--no-out-link'], env=env)
    print("Pure consumer build passed", flush=True)
    repository = Path(run(['nix-build', expression, '-A', 'projections.rubygems', '--no-out-link'], env=env).strip())
    archives = {path.name: path.read_bytes() for path in (repository / 'gems').glob('*.gem')}
    by_digest = {hashlib.sha512(data).digest(): name for name, data in archives.items()}
    stored = {}
    uploads = []

    class Registry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            relative = self.path.lstrip('/')
            if relative.startswith('gems/'):
                data = stored.get(relative.removeprefix('gems/'))
            else:
                path = repository / relative
                data = path.read_bytes() if path.is_file() else None
            self.send_response(200 if data is not None else 404)
            self.send_header('Content-Length', str(len(data or b'')))
            self.end_headers()
            self.wfile.write(data or b'')

        def do_POST(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            name = by_digest.get(hashlib.sha512(data).digest())
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
    publication_env = dict(env, GEM_HOST_API_KEY='fixture-key')
    try:
        command = [cli / 'bin/bundler-purifier', 'publish', '--host', host]
        run(command, project, publication_env)
        assert stored == archives
        count = len(uploads)
        run(command, project, publication_env)
        assert len(uploads) == count
        ordinary = work / 'ordinary'
        ordinary.mkdir()
        catalog = json.loads(run(['nix-instantiate', expression, '-A', 'projections.rubygems.catalog', '--eval', '--json'], env=env))
        packages = json.loads(Path(catalog).read_text())['packages']
        version = next(entry['version'] for entry in packages if entry['name'] == 'composed-consumer')
        (ordinary / 'Gemfile').write_text(f'source "{host}"\ngem "composed-consumer", "= {version}"\n')
        native_env = dict(env, PATH=f'{ruby}/bin:' + os.environ['PATH'], BUNDLE_PATH=str(ordinary / 'vendor/bundle'))
        run([ruby / 'bin/bundle', 'install', '--full-index'], ordinary, native_env)
        assert run([ruby / 'bin/bundle', 'exec', 'ruby', '-e',
                    'require "composed_consumer"; raise unless ComposedConsumer.include?("hello, nix"); puts "PURIFIED"'], ordinary, native_env) == 'PURIFIED\n'
        stored[next(iter(stored))] = b'conflicting publication'
        rejected = subprocess.run([str(part) for part in command], cwd=project,
                                  env=publication_env, text=True, capture_output=True)
        assert rejected.returncode != 0 and 'published gem has different bytes' in rejected.stderr
        assert len(uploads) == count
    finally:
        server.shutdown()
        server.server_close()
print('Native Bundler composition, external locks, wrapper fallback and exact publication passed')
