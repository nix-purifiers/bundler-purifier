# SPDX-License-Identifier: MIT
"""Negative replay controls must reject before creating working state."""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--ruby", required=True)
parser.add_argument("--sdk", required=True)
parser.add_argument("--capture", type=Path, required=True)
parser.add_argument("--archives", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
args.evidence.mkdir()
helper = Path(__file__).resolve().parent.parent / "tools/native_environment_prepare.rb"
captured = json.loads(args.capture.read_text())
archives = json.loads(args.archives.read_text())
checks = []
with tempfile.TemporaryDirectory(prefix="native-environment-prepare-") as temporary:
    temporary = Path(temporary)
    for label, change in [
        ("wrong-ABI", lambda v: v["sdk"].update(abi="competitor")),
        ("wrong-interpreter", lambda v: v["sdk"].update(interpreter="sha256-" + base64.b64encode(hashlib.sha256(b"competitor").digest()).decode())),
        ("wrong-report", lambda v: v["sdk"]["clientReport"].update(value="0.3.1")),
        ("wrong-archive", lambda v: v["packages"][0].update(archiveHash="sha256-" + base64.b64encode(hashlib.sha256(b"competitor").digest()).decode())),
        ("changed-manifest", lambda v: v["manifests"][0].update(base64="")),
        ("missing-transport", lambda v: None),
        ("conflicting-destination", lambda v: None),
    ]:
        record = copy.deepcopy(captured)
        change(record)
        record_file = temporary / (label + ".json")
        record_file.write_text(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        mapping = copy.deepcopy(archives)
        if label == "missing-transport":
            mapping.pop(next(iter(mapping)))
        archive_file = temporary / (label + "-archives.json")
        archive_file.write_text(json.dumps(mapping))
        destination = temporary / (label + "-working")
        if label == "conflicting-destination":
            destination.mkdir()
            (destination / "sentinel").write_bytes(b"preserve existing bytes")
        argv = [args.ruby, str(helper), "regenerate", str(record_file), args.sdk, str(archive_file), str(destination)]
        result = subprocess.run(argv, capture_output=True, timeout=45)
        (args.evidence / (label + ".stdout")).write_bytes(result.stdout)
        (args.evidence / (label + ".stderr")).write_bytes(result.stderr)
        assert result.returncode != 0, label
        reason = {
            "wrong-ABI": "native installed role conflicts with SDK layout",
            "wrong-interpreter": "native replay SDK differs from capture",
            "wrong-report": "unsupported native interface identity",
            "wrong-archive": "native replay archive bytes differ from capture",
            "changed-manifest": "invalid bounded native snapshot encoding",
            "missing-transport": "native replay archive set differs from capture",
            "conflicting-destination": "native regeneration destination already exists",
        }[label]
        assert reason.encode() in result.stderr, (label, result.stderr.decode())
        if label == "conflicting-destination":
            assert list(destination.iterdir()) == [destination / "sentinel"]
            assert (destination / "sentinel").read_bytes() == b"preserve existing bytes"
        else:
            assert not destination.exists(), label
        checks.append(dict(label=label, argv=argv, exit=result.returncode,
                           stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),
                           stderrSha256=hashlib.sha256(result.stderr).hexdigest(),
                           rejectedBeforeWorkingState=True))
print(json.dumps(dict(complete=True, commands=checks,
                      helperSha256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                      scope="Replay rejection controls; no activation or whole workflow claim"), indent=2))
