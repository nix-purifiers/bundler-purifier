# SPDX-License-Identifier: MIT
"""Offline native Bundler 1.17 input binding, installation and ABI execution."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
tools, repository, catalog = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='bundler117-composition-') as temporary:
    project = Path(temporary)
    manifest = 'source "https://unreachable.invalid"\nruby "2.5.8"\ngem "historical_greeting", ">= 99"\n'
    (project / 'Gemfile').write_text(manifest)
    environment = dict(os.environ, HOME=str(project),
        PATH=str(tools / 'bin') + ':' + os.environ['PATH'],
        GEM_HOME=str(project / 'gems'), GEM_PATH=str(tools / 'gems'),
        BUNDLE_PATH=str(project / 'vendor/bundle'), BUNDLE_USER_HOME=str(project / 'bundle-home'),
        BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps([dict(repository=str(repository), catalog=str(catalog))]),
        BUNDLER_PURIFIER_BUNDLER_VERSION='1.17.3', BUNDLER_PURIFIER_PERSIST_LOCK='1')

    def run(*arguments):
        result = subprocess.run([str(tools / 'bin/ruby'), str(root / 'tools/native_bundle_command.rb'), *arguments],
                                cwd=project, env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (project / 'Gemfile').read_text() == manifest
        return result.stdout

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
    output = run('exec', 'ruby', '-e', 'require "historical_greeting"; abort unless RUBY_VERSION == "2.5.8"; puts HistoricalGreeting.answer')
    assert output == '42\n', output
    assert (project / 'Gemfile.lock').read_bytes() == lock
    print('PASS Bundler1.17: native offline input binding, exact dependency graph, unchanged manifest/lock, install and compiled JSON execution')
