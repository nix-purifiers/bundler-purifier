# SPDX-License-Identifier: MIT
"""Exercise genuine native state; never patch SDK classes or constants."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--ruby", required=True)
parser.add_argument("--workspace", type=Path, required=True)
parser.add_argument("--evidence", type=Path)
args = parser.parse_args()
observer = Path(__file__).resolve().parent.parent / "tools/native_environment_observe.rb"
results = []
if args.evidence:
    args.evidence.mkdir()


def run(label, workspace, expected):
    argv = [args.ruby, str(observer), str(workspace)]
    result = subprocess.run(argv,
                            cwd=workspace, capture_output=True, timeout=45)
    assert (result.returncode == 0) == expected, (label, result.returncode, result.stderr.decode())
    if args.evidence:
        (args.evidence / (label + ".stdout")).write_bytes(result.stdout)
        (args.evidence / (label + ".stderr")).write_bytes(result.stderr)
    results.append(dict(label=label, argv=argv, exit=result.returncode, expectedSuccess=expected,
                        stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),
                        stderrSha256=hashlib.sha256(result.stderr).hexdigest()))
    return json.loads(result.stdout) if expected else None


with tempfile.TemporaryDirectory(prefix="native-environment-observer-") as temporary:
    temporary = Path(temporary)
    original = temporary / "original"
    shutil.copytree(args.workspace, original, symlinks=True)
    baseline = run("native-selection", original, True)
    relocated = temporary / "relocated"
    shutil.copytree(original, relocated, symlinks=True)
    original.rename(temporary / "original.hidden")
    assert run("relocated-original-unavailable", relocated, True) == baseline
    for label, mutate in [
        ("ambiguous-native-lock", lambda project: (project / "Gemfile.lock").write_text("")),
        ("missing-cache-archive", lambda project: next(project.glob("vendor/gems/ruby/1.8/cache/*.gem")).unlink()),
        ("ordinary-constraint", lambda project: (project / "Gemfile").write_text('gem "incoming_consumer", ">= 999"\n')),
        ("unknown-context", lambda project: (project / "Gemfile").write_text('only :test do\n' + (project / "Gemfile").read_text() + 'end\n')),
    ]:
        project = temporary / label
        shutil.copytree(relocated, project, symlinks=True)
        mutate(project)
        run(label, project, False)
    # Reject an escaping gemspec before its first byte can be evaluated.
    project = temporary / "escaping-specification"
    shutil.copytree(relocated, project, symlinks=True)
    tripwire = temporary / "executed-outside"
    outside = temporary / "outside.gemspec"
    outside.write_text('File.open(' + json.dumps(str(tripwire)) + ', "w") {|f| f.write("executed")}\n')
    specification = next(project.glob("vendor/gems/ruby/1.8/specifications/*.gemspec"))
    specification.unlink()
    specification.symlink_to(outside)
    run("escaping-specification-before-evaluation", project, False)
    assert not tripwire.exists()
print(json.dumps(dict(complete=True, commands=results,
                      observerSha256=hashlib.sha256(observer.read_bytes()).hexdigest(),
                      driverSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      scope="Native observer controls only; not a complete purifier workflow"), indent=2))
