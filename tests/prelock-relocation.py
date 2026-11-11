# SPDX-License-Identifier: MIT
"""Move a captured native project and reject a receipt bound to its old root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--project', required=True, type=Path)
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--work', required=True, type=Path)
args = parser.parse_args()
args.work.mkdir()
original = args.project.resolve()
hidden = args.work / 'unavailable-original'
relocated = args.work / 'relocated'
shutil.copytree(original, relocated, symlinks=True)
lock = 'bundler-purifier.lock.json'
expected_lock = (original / lock).read_bytes()
receipt = {'complete': False, 'commands': []}

def run(label, command, success=True):
    result = subprocess.run([str(args.cli)] + command, cwd=relocated,
                            env=os.environ, capture_output=True, timeout=900)
    for suffix, data in [('stdout', result.stdout), ('stderr', result.stderr)]:
        (args.work / (label + '.' + suffix)).write_bytes(data)
    receipt['commands'].append({'label': label, 'argv': command,
        'exit': result.returncode, 'expectedSuccess': success,
        'stdoutSha256': hashlib.sha256(result.stdout).hexdigest(),
        'stderrSha256': hashlib.sha256(result.stderr).hexdigest()})
    (args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert (result.returncode == 0) == success, (label, result.stderr.decode()[-6000:])
    return result.stdout

# Restore the caller's source even if a negative control or native command fails.
original.rename(hidden)
try:
    assert not original.exists()
    run('reject-old-root-receipt', ['shell', 'ruby', '-e', 'raise "stale receipt activated"'], False)
    run('lock-no-op-relocated', ['lock'])
    assert (relocated / lock).read_bytes() == expected_lock
    run('prefetch-relocated', ['prefetch'])
    output = run('native-relocated', ['shell', 'ruby', '-Ilib', '-e',
        'require "historical_greeting";raise unless HistoricalGreeting.answer==42;puts "RELOCATED|42|#{RUBY_VERSION}"'])
    assert b'RELOCATED|42|1.8.4' in output
    assert not original.exists()
    receipt['complete'] = True
    receipt['originalRootUnavailableDuringCommands'] = True
    receipt['lockBytesUnchanged'] = True
    (args.work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
finally:
    hidden.rename(original)
