#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise local adoption with an existing, non-store Linux Ruby."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--helper-ruby", type=Path)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--fixture", default="library")
    parser.add_argument("--native-json", action="store_true")
    parser.add_argument("--incompatible-extension", type=Path)
    parser.add_argument("--nixpkgs", default=os.environ.get("BUNDLER_PURIFIER_NIXPKGS"))
    parser.add_argument("--purifier", default=os.environ.get("BUNDLER_PURIFIER_SHARED_FLAKE"))
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    if str(runtime).startswith("/nix/store/") or not Path("/proc/self/exe").exists():
        parser.error("this Linux proof requires an actual non-store Ruby executable")
    if not args.nixpkgs or not args.purifier:
        parser.error("provide --nixpkgs and --purifier, or their BUNDLER_PURIFIER environment settings")
    if not args.cli and not args.helper_ruby:
        parser.error("provide --cli or --helper-ruby")
    if args.cli and not args.bundle:
        parser.error("the installed CLI proof requires --bundle from the same package")
    repo = Path(__file__).resolve().parents[2]
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=False)
    project = results / "project"
    shutil.copytree(repo / "tests/fixtures" / args.fixture, project)
    inputs = {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in project.rglob("*") if p.is_file() and p.name != "bundler-purifier.lock.json"}
    environment = dict(os.environ)
    environment.pop("BUNDLER_PURIFIER_PROJECT_RUBY", None)
    environment.pop("BUNDLER_PURIFIER_RUBY_EXPRESSION", None)
    if not args.cli:
        environment.update(BUNDLER_PURIFIER_TOOLS=str(repo / "tools"),
                           BUNDLER_PURIFIER_LIB=str(repo / "nix/lib"))
    environment.update(BUNDLER_PURIFIER_NIXPKGS=args.nixpkgs,
                       BUNDLER_PURIFIER_SHARED_FLAKE=args.purifier)
    guards = results / "guards"
    guards.mkdir()
    # Fetching locked artifacts is allowed; selecting/building an SDK or
    # entering a Nix development environment is not local adoption.
    for name in ("nix", "nix-build"):
        executable = shutil.which(name)
        if not executable:
            parser.error(f"missing artifact-fetching tool {name}")
        guard = guards / name
        guard.write_text(f"#!{sys.executable}\n" +
                         "import json,os,sys\n" +
                         f"name={name!r}\nlog={str(results / 'nix-commands.jsonl')!r}\n" +
                         "with open(log,'a') as f: f.write(json.dumps([name]+sys.argv[1:])+'\\n')\n" +
                         "if name=='nix-build':\n" +
                         " assert '-A' in sys.argv and sys.argv[sys.argv.index('-A')+1]=='gemCache', 'local workflow requested an SDK/project build'\n" +
                         "else:\n assert len(sys.argv)>1 and sys.argv[1]=='hash', 'local workflow requested a Nix environment'\n" +
                         f"os.execv({executable!r},[{executable!r}]+sys.argv[1:])\n")
        guard.chmod(0o755)
    environment["PATH"] = os.pathsep.join([str(guards), str(runtime.parent), environment["PATH"]])
    report = {"runtime": str(runtime), "inputs": inputs, "steps": []}
    deadline = time.monotonic() + 600

    def run(name, command, succeeds=True):
        process = subprocess.Popen(command, cwd=project, env=environment, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
            report["timedOut"] = True
        (results / (name + ".stdout")).write_text(stdout)
        (results / (name + ".stderr")).write_text(stderr)
        report["steps"].append({"name": name, "command": command, "returncode": process.returncode})
        (results / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        assert not report.get("timedOut"), "local workflow exceeded its 600 second deadline"
        assert (process.returncode == 0) == succeeds, stdout + stderr
        return stdout

    helper = str(args.helper_ruby.resolve()) if args.helper_ruby else None
    cli = [str(args.cli.resolve())] if args.cli else [helper, str(repo / "bin/bundler-purifier")]
    bundle = [str(args.bundle.resolve())] if args.cli else [helper, str(repo / "bin/bundle")]
    run("capture", [*cli, "lock", "--force"])
    run("prefetch", [*cli, "prefetch"])
    probe = 'require "json"; puts JSON.generate({"version"=>RUBY_VERSION,"executable"=>File.readlink("/proc/self/exe")})'
    if args.native_json:
        probe = ('require "json"; require "digest"; '
                 'paths=File.readlines("/proc/self/maps").map{|line| line.split.last}.uniq.select{|path| path.end_with?("/json/ext/parser.so")}; '
                 'abort "ambiguous native parser" unless paths.size==1; '
                 'puts JSON.generate({"version"=>RUBY_VERSION,"executable"=>File.readlink("/proc/self/exe"),'
                 '"json"=>JSON::VERSION,"parser"=>paths.first,"parserHash"=>Digest::SHA256.file(paths.first).hexdigest})')
    observed = json.loads(run("wrapper", [*bundle, "exec", "ruby", "-e", probe]))
    assert observed["executable"] == str(runtime), observed
    if args.native_json:
        assert Path(observed["parser"]).is_relative_to(project / "vendor/bundle"), observed
        assert observed["json"] == "2.9.1", observed
        report["nativeParser"] = observed
    if args.incompatible_extension:
        assert args.native_json, "the ABI negative requires the native parser proof"
        extension = Path(observed["parser"])
        original = extension.read_bytes()
        try:
            shutil.copyfile(args.incompatible_extension, extension)
            output = run("incompatible-extension", [*bundle, "exec", "ruby", "-rjson", "-e", "puts 'unexpected ABI acceptance'"], succeeds=False)
            error = (results / "incompatible-extension.stderr").read_text()
            assert "LoadError" in error and "unexpected ABI acceptance" not in output, error
            report["incompatibleExtensionHash"] = hashlib.sha256(args.incompatible_extension.read_bytes()).hexdigest()
        finally:
            extension.write_bytes(original)
    shell = json.loads(run("shell", [*cli, "shell", "--", "bundle", "exec", "ruby", "-e", probe]))
    assert shell == observed, shell
    # A project constraint is an error, never a request to install Ruby.
    version_file = project / ".ruby-version"
    original_version = version_file.read_bytes() if version_file.exists() else None
    try:
        version_file.write_text("999.999.0\n")
        run("incompatible", [*cli, "lock", "--force"], succeeds=False)
        assert "conflicts with project Ruby" in (results / "incompatible.stderr").read_text()
    finally:
        if original_version is None:
            version_file.unlink()
        else:
            version_file.write_bytes(original_version)
    after = {name: hashlib.sha256((project / name).read_bytes()).hexdigest() for name in inputs}
    assert after == inputs, "local adoption changed user inputs"
    report.update(status="passed", observed=observed, unchangedInputs=True)
    (results / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
