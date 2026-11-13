# SPDX-License-Identifier: MIT
"""Genuine SDK regeneration for every layout/control case; no copied stale env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--sdk', required=True, type=Path)
parser.add_argument('--archive', required=True, type=Path)
parser.add_argument('--work', required=True, type=Path)
parser.add_argument('--pure-archive', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
args.work.mkdir()
logs = args.work / 'logs'
logs.mkdir()
env = {key: value for key, value in os.environ.items() if not key.startswith(('GEM_', 'RUBY', 'BUNDLE_', 'BUNDLER_'))}
home = args.work / 'home'
home.mkdir()
env['HOME'] = str(home)
receipt = {'complete': False, 'commands': []}


def run(label, argv, cwd, success=True, reason=None):
    result = subprocess.run([str(arg) for arg in argv], cwd=cwd, env=env, capture_output=True, timeout=90)
    for stream, data in [('stdout', result.stdout), ('stderr', result.stderr)]:
        (logs / (label + '.' + stream)).write_bytes(data)
    receipt['commands'].append({'label': label, 'argv': [str(arg) for arg in argv],
        'exit': result.returncode, 'expectedSuccess': success,
        'stdoutSha256': hashlib.sha256(result.stdout).hexdigest(),
        'stderrSha256': hashlib.sha256(result.stderr).hexdigest()})
    (args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert (result.returncode == 0) == success, (label, result.stderr.decode()[-6000:])
    if reason:
        assert reason.encode() in result.stderr, (label, result.stderr.decode())
    assert b'BAD-ACTIVATED' not in result.stdout
    return result.stdout


for label in ['baseline', 'extra-directory', 'altered-wrapper', 'wrapper-mode',
              'foreign-wrapper', 'wrapper-symlink', 'bad-constraint', 'bad-context',
              'bad-system-policy', 'systemless']:
    arena = args.work / label
    project = arena / 'project'
    project.mkdir(parents=True)
    manifest = 'gem "json", "= 1.1.3"\n'
    if label == 'systemless':
        manifest += 'disable_system_gems\n'
    (project / 'Gemfile').write_text(manifest)
    archives = arena / 'native-input-archives'
    archives.mkdir()
    shutil.copyfile(args.archive, archives / '0.gem')
    (archives / 'inventory.tsv').write_text(hashlib.sha256(args.archive.read_bytes()).hexdigest() + '\t0.gem\n')
    run(label + '-install', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_v03_install.rb', project, archives], project)
    repository = project / 'vendor/gems'
    wrapper = repository / 'bin/edit_json.rb'
    assert wrapper.is_file()
    if label == 'extra-directory':
        (repository / 'extra').mkdir()
    elif label == 'altered-wrapper':
        wrapper.write_bytes(wrapper.read_bytes() + b'\n# changed native wrapper\n')
    elif label == 'wrapper-mode':
        wrapper.chmod(0o644)
    elif label == 'foreign-wrapper':
        (repository / 'bin/foreign').write_text('foreign\n')
    elif label == 'wrapper-symlink':
        outside = arena / 'outside'
        outside.write_text('preserve outside sentinel\n')
        wrapper.unlink()
        wrapper.symlink_to(outside)
    elif label == 'bad-constraint':
        (project / 'Gemfile').write_text('gem "json", ">= 99"\n')
    elif label == 'bad-context':
        (project / 'Gemfile').write_text('gem "json", "= 1.1.3", :only => :test\n')
    elif label == 'bad-system-policy':
        (project / 'Gemfile').write_text(manifest + '@manifest_file.system_gems = :foreign\n')
    success = label in ['baseline', 'systemless']
    reasons = {'extra-directory': 'extra v03 repository entry',
        'altered-wrapper': 'wrapper bytes differ', 'wrapper-mode': 'wrapper mode differs',
        'foreign-wrapper': 'wrapper inventory differs', 'wrapper-symlink': 'repository symlink',
        'bad-constraint': 'activation constraints do not resolve', 'bad-context': 'unsupported v03 contexts',
        'bad-system-policy': 'invalid v03 system-gems policy'}
    code = 'require "json";raise unless JSON.parse(%q({"answer":42}))["answer"]==42;puts "LAYOUT|#{RUBY_VERSION}|#{Gem::RubyGemsVersion}|42"' if success else 'puts "BAD-ACTIVATED"'
    output = run(label + '-activation', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_exec.rb', project, args.sdk, '--', 'ruby', '-e', code], project, success, reasons.get(label))
    if success:
        assert b'LAYOUT|1.8.3|1.0.1|42' in output
    if label == 'wrapper-symlink':
        assert outside.read_text() == 'preserve outside sentinel\n'
# Observer checks immutable archive joins before any selected codec is loaded.
for label, reason in [('changed-payload', 'installed payload differs'),
                      ('extra-shadow', 'payload file set differs'),
                      ('payload-executable-mode', 'executable mode differs'),
                      ('changed-input-archive', 'archive bytes changed'),
                      ('escaping-specification', 'escapes owned workspace')]:
    arena = args.work / label
    project = arena / 'project'
    project.mkdir(parents=True)
    (project / 'Gemfile').write_text('gem "json", "= 1.1.3"\n')
    archives = arena / 'native-input-archives'
    archives.mkdir()
    shutil.copyfile(args.archive, archives / '0.gem')
    (archives / 'inventory.tsv').write_text(hashlib.sha256(args.archive.read_bytes()).hexdigest() + '\t0.gem\n')
    run(label + '-install', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_v03_install.rb', project, archives], project)
    package = next(project.glob('vendor/gems/gems/json-*'))
    if label == 'changed-payload':
        payload = package / 'lib/json.rb'
        payload.write_bytes(payload.read_bytes() + b'\n# changed installed bytes\n')
    elif label == 'extra-shadow':
        (package / 'lib/openssl.rb').write_text('raise "unarchived shadow executed"\n')
    elif label == 'payload-executable-mode':
        (package / 'bin/edit_json.rb').chmod(0o644)
    elif label == 'changed-input-archive':
        with (archives / '0.gem').open('ab') as stream:
            stream.write(b'changed original input')
    else:
        tripwire = arena / 'outside-executed'
        outside = arena / 'outside.gemspec'
        outside.write_text('File.open(' + json.dumps(str(tripwire)) + ', "w") {|f| f.write("unexpected evaluation")}\n')
        specification = next(project.glob('vendor/gems/specifications/*.gemspec'))
        specification.unlink()
        specification.symlink_to(outside)
    run(label + '-observation', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_observe.rb', project], project, False, reason)
    if label == 'escaping-specification':
        assert not tripwire.exists()
        run(label + '-activation', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_exec.rb', project, args.sdk, '--', 'ruby', '-e', 'puts "BAD-ACTIVATED"'], project, False, 'repository symlink')
        assert not tripwire.exists()

# A package without executables must preserve the original SDK guard exactly.
for label in ['no-bin', 'foreign-empty-bin']:
    arena = args.work / label
    project = arena / 'project'
    project.mkdir(parents=True)
    (project / 'Gemfile').write_text('gem "numeric_leaf", "= 1.0.0"\n')
    archives = arena / 'native-input-archives'
    archives.mkdir()
    shutil.copyfile(args.pure_archive, archives / '0.gem')
    (archives / 'inventory.tsv').write_text(hashlib.sha256(args.pure_archive.read_bytes()).hexdigest() + '\t0.gem\n')
    run(label + '-install', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_v03_install.rb', project, archives], project)
    repository = project / 'vendor/gems'
    assert not (repository / 'bin').exists()
    guard = 'require "rubygems";gem "bundler", "= 0.3.1";require "bundler";raise unless Bundler::Repository.new(ARGV[0]).valid?;puts "ORIGINAL-GUARD-PASS"'
    assert b'ORIGINAL-GUARD-PASS' in run(label + '-original-guard', [args.sdk / 'bin/ruby', '-e', guard, repository], project)
    if label == 'foreign-empty-bin':
        (repository / 'bin').mkdir()
    code = 'require "numeric_leaf";puts "PURE-ACTIVATED"' if label == 'no-bin' else 'puts "BAD-ACTIVATED"'
    output = run(label + '-activation', [args.sdk / 'bin/ruby', root / 'pkgs/cli/tools/native_environment_exec.rb', project, args.sdk, '--', 'ruby', '-e', code], project, label == 'no-bin', 'foreign v03 bin directory' if label == 'foreign-empty-bin' else None)
    if label == 'no-bin':
        assert b'PURE-ACTIVATED' in output
receipt['complete'] = True
receipt['scope'] = 'Native v03 layout adapter controls; original gem-exec equivalence not claimed.'
(args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
