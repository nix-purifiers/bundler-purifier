# SPDX-License-Identifier: MIT
"""Resolve in a fresh arena while preserving the original project tree."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--ruby", required=True)
parser.add_argument("--sdk", required=True)
parser.add_argument("--archives", required=True, type=Path)
parser.add_argument("--bindings", required=True, type=Path)
parser.add_argument("--evidence", required=True, type=Path)
args = parser.parse_args()
args.evidence.mkdir()
helper = Path(__file__).resolve().parent.parent / "tools/native_environment_prepare.rb"
program = '''result=PurifierNativeEnvironmentPrepare.resolve(ARGV[0],ARGV[1],JSON.parse(File.binread(ARGV[2])),ARGV[3],bindings: JSON.parse(File.binread(ARGV[4])));puts JSON.generate(PurifierNativeEnvironment.canonical(result))'''
commands = []


def seal(root):
    return {str(path.relative_to(root)): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode)
            for path in root.rglob("*") if path.is_file()}


with tempfile.TemporaryDirectory(prefix="native-resolution-") as temporary:
    temporary = Path(temporary)
    project = temporary / "original project"
    project.mkdir()
    (project / "Gemfile").write_text('gem "incoming_consumer"\n')
    (project / "vendor").mkdir()
    (project / "vendor" / "unrelated").write_text("preserve original state\n")
    original = seal(project)
    for label in ["fresh-resolution", "conflicting-archives", "existing-arena"]:
        destination = temporary / (label + " arena")
        archive_file = args.archives
        if label == "conflicting-archives":
            entries = []
            for index in range(2):
                directory = temporary / ("conflict-" + str(index))
                directory.mkdir()
                path = directory / "same-name.gem"
                data = ("different bytes " + str(index)).encode()
                path.write_bytes(data)
                entries.append(dict(path=str(path), sha256="sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()))
            archive_file = temporary / "conflicts.json"
            archive_file.write_text(json.dumps(entries))
        if label == "existing-arena":
            destination.mkdir()
            (destination / "sentinel").write_text("preserve existing arena")
        argv = [args.ruby, "-r", str(helper), "-e", program, str(project), args.sdk,
                str(archive_file), str(destination), str(args.bindings)]
        result = subprocess.run(argv, capture_output=True, timeout=45)
        (args.evidence / (label + ".stdout")).write_bytes(result.stdout)
        (args.evidence / (label + ".stderr")).write_bytes(result.stderr)
        assert seal(project) == original, label
        if label == "fresh-resolution":
            assert result.returncode == 0, result.stderr.decode()
            captured = json.loads(result.stdout)
            assert len(captured["packages"]) == 3 and len(captured["bindings"]) == 3
            assert (destination / "Gemfile").read_bytes() == (project / "Gemfile").read_bytes()
            assert not (destination / "Gemfile.lock").exists()
        else:
            assert result.returncode != 0, label
            reason = "conflicting destinations" if label == "conflicting-archives" else "destination already exists"
            assert reason.encode() in result.stderr, result.stderr.decode()
            if label == "existing-arena":
                assert list(destination.iterdir()) == [destination / "sentinel"]
                assert (destination / "sentinel").read_text() == "preserve existing arena"
            else:
                assert not destination.exists()
        commands.append(dict(label=label, argv=argv, exit=result.returncode,
                             stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),
                             stderrSha256=hashlib.sha256(result.stderr).hexdigest(), originalProjectUnchanged=True))
print(json.dumps(dict(complete=True, commands=commands,
                      scope="Fresh native resolution controls, not full v4 compatibility"), indent=2))
