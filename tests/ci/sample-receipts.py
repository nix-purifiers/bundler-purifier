#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Force native sample execution and retain its source/derivation/output binding."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    args = parser.parse_args()
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    os.chdir(repo)
    commands = []
    report = {"status": "running", "commands": commands, "checks": {}}

    def save():
        (results / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, json_output=False):
        completed = subprocess.run(command, text=True, capture_output=True)
        stdout = results / (label + ".stdout")
        stderr = results / (label + ".stderr")
        stdout.write_text(completed.stdout)
        stderr.write_text(completed.stderr)
        commands.append({
            "command": command,
            "returncode": completed.returncode,
            "stdout": stdout.name,
            "stdoutSha256": hashlib.sha256(stdout.read_bytes()).hexdigest(),
            "stderr": stderr.name,
            "stderrSha256": hashlib.sha256(stderr.read_bytes()).hexdigest(),
        })
        save()
        if completed.returncode:
            print(completed.stderr, flush=True)
            raise RuntimeError(f"{label} failed ({completed.returncode})")
        return json.loads(completed.stdout) if json_output else completed.stdout.strip()

    save()
    try:
        report["revision"] = run("revision", ["git", "rev-parse", "HEAD"])
        report["worktreeStatus"] = run("status", ["git", "status", "--porcelain"])
        report["source"] = run("source", ["nix", "flake", "metadata", "--json"], True)
        system = run("system", ["nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])
        report["executedSystem"] = system
        report["sampleSource"] = run(
            "lobsters-source",
            ["nix", "flake", "metadata", "--json", "./tests/dependencies"], True,
        )["locks"]["nodes"]["lobsters"]["locked"]
        # Rebuilding the app itself proves the offline gem installation ran,
        # rather than only replaying an already-built Rails version wrapper.
        for name in ("fixture-app", "fixture-library-tests", "real-lobsters-app", "real-lobsters"):
            attr = f".#checks.{system}.{name}"
            print(f"== rebuilding {attr}", flush=True)
            base_drv = run(name + "-base-drv", ["nix", "eval", "--raw", attr + ".drvPath"])
            # Native extension installers can retain build-directory details.
            # Tier 2 needs actual successful execution, not byte reproducibility.
            # A fresh derivation executes the unchanged build phases without
            # comparing unrelated prior output bytes or accepting substitution.
            execution_id = uuid.uuid4().hex
            expression = (
                f'(builtins.getFlake {json.dumps(report["source"]["path"])}).checks.{system}.{name}'
                f'.overrideAttrs (_: {{ tier2ExecutionId = "{execution_id}"; }})'
            )
            drv = run(name + "-drv", ["nix", "eval", "--raw", "--impure", "--expr", f"({expression}).drvPath"])
            derivation = run(name + "-derivation", ["nix", "derivation", "show", drv], True)
            # Nix's versioned JSON uses store-relative keys; older releases
            # return an unwrapped map keyed by the absolute derivation path.
            if "derivations" in derivation:
                native_drv = derivation["derivations"][Path(drv).name]
            else:
                native_drv = derivation[drv]
            if native_drv["system"] != system:
                raise RuntimeError(f"{name}: derivation does not target the native host")
            built = run(name + "-build", ["nix", "build", "--no-link", "--impure", "--expr", expression, "--json", "-L"], True)
            if len(built) != 1 or built[0]["drvPath"] != drv:
                raise RuntimeError(f"{name}: built derivation differs from the evaluated one")
            paths = list(built[0]["outputs"].values())
            info = run(name + "-outputs", ["nix", "path-info", "--json", *paths], True)
            run(name + "-log", ["nix", "log", drv])
            report["checks"][name] = {
                "attribute": attr, "baseDrvPath": base_drv,
                "executionExpression": expression, "executionId": execution_id,
                "drvPath": drv, "build": built, "outputInfo": info,
            }
            if name == "real-lobsters":
                sample_output = Path(built[0]["outputs"]["out"]).read_text()
                (results / "lobsters-runtime.txt").write_text(sample_output)
                report["sampleSdk"] = json.loads(sample_output.splitlines()[0])
                if not any(line.startswith("Rails ") for line in sample_output.splitlines()):
                    raise RuntimeError("Lobsters did not report Rails")
                if not any(line.startswith("libvips ") for line in sample_output.splitlines()):
                    raise RuntimeError("Lobsters did not load libvips")
            save()
        report["status"] = "success"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        save()


if __name__ == "__main__":
    main()
