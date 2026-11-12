# SPDX-License-Identifier: MIT
"""Shared host/Nix v4 envelope corpus using an actual native observation.
Transport URLs here are validation fixtures, not verified fetch receipts.
"""
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
parser.add_argument("--nix-lib", required=True, type=Path)
parser.add_argument("--resolution", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
resolution = json.loads(args.resolution.read_text())
assert resolution["bindings"] == []
archives = [dict(name=package["name"], version=package["version"], platform=package["platform"],
                 sha256=package["archiveHash"], transport=dict(kind="vendored", path="vendor/cache/" + Path(package["installedPath"]).name + ".gem"))
            for package in resolution["packages"]]
assert archives and not any(record["path"].endswith(".gemspec") for record in resolution["manifests"])


def sri(raw):
    return "sha256-" + base64.b64encode(hashlib.sha256(raw).digest()).decode()


def content_hash(value):
    return sri(json.dumps({key: item for key, item in value.items() if key != "contentHash"},
                          sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())


definition = b"".join(record["path"].encode() + b"\n" + str(record["size"]).encode() + b"\n" +
                      base64.b64decode(record["base64"]) + b"\n"
                      for record in sorted(resolution["manifests"], key=lambda record: record["path"]))
baseline = dict(version=4, nativeResolution=resolution, archives=archives, projectInputs=[], projectSpecs=[],
                definitionHash=sri(definition))
baseline["contentHash"] = content_hash(baseline)
cases = [("valid", baseline, True, None)]


def changed(label, mutate, expected=False, project_change=None):
    candidate = copy.deepcopy(baseline)
    mutate(candidate)
    candidate["contentHash"] = content_hash(candidate)
    cases.append((label, candidate, expected, project_change))


changed("unknown-field", lambda v: v.update(unknown=True))
changed("legacy-version", lambda v: v.update(version=3))
changed("float-version", lambda v: v.update(version=4.0))
changed("stale-definition", lambda v: v.update(definitionHash=sri(b"different source")))
changed("missing-archive", lambda v: v["archives"].pop())
changed("duplicate-archive", lambda v: v["archives"].append(v["archives"][0]))
changed("wrong-archive-bytes", lambda v: v["archives"][0].update(sha256=sri(b"other bytes")))
changed("unknown-transport", lambda v: v["archives"][0].update(transport=dict(kind="git")))
changed("vendored-traversal", lambda v: v["archives"][0].update(transport=dict(kind="vendored", path="../outside.gem")))
changed("undeclared-Nix-input", lambda v: v["archives"][0].update(transport=dict(kind="nix", reference="missing#app", file="gems/a.gem")))
changed("bindings-without-input", lambda v: v["nativeResolution"].update(bindings=[dict(name=v["archives"][0]["name"], version=v["archives"][0]["version"])]))
for label, url in [("valid-url", "https://example.test/archive.gem?download=1"),
                   ("ftp", "ftp://example.test/archive.gem"),
                   ("missing-host", "https://?download=1"),
                   ("URL-space", "https://example.test/a gem"),
                   ("URL-fragment", "https://example.test/a.gem#fragment"),
                   ("URL-unescaped-Unicode", "https://example.test/caf\u00e9.gem")]:
    changed(label, lambda v, url=url: v["archives"][0].update(transport=dict(kind="url", url=url)), label == "valid-url")
changed("stale-current-manifest", lambda v: None, project_change="manifest")
changed("new-root-gemspec", lambda v: None, project_change="gemspec")
changed("ambiguous-native-lock", lambda v: None, project_change="native-lock")

host = '''require ARGV.shift
begin
  document=PurifierNativeEnvironmentLock.parse(File.binread(ARGV.shift))
  PurifierNativeEnvironmentLock.check_project!(document,ARGV.shift)
rescue PurifierNativeEnvironment::Invalid
  exit 1
end
'''
with tempfile.TemporaryDirectory(prefix="native-v4-envelope-") as temporary:
    temporary = Path(temporary)
    for label, value, expected, project_change in cases:
        project = temporary / label
        project.mkdir()
        for record in value["nativeResolution"]["manifests"]:
            path = project / record["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(record["base64"]))
        if project_change == "manifest":
            (project / "Gemfile").write_bytes(b"# changed original bytes\n")
        elif project_change == "gemspec":
            (project / "new.gemspec").write_bytes(b"# newly added root specification\n")
        elif project_change == "native-lock":
            (project / "Gemfile.lock").write_bytes(b"")
        lock = project / "bundler-purifier.lock.json"
        lock.write_text(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
        ruby = subprocess.run([args.ruby, "-e", host, str(root / "pkgs/cli/tools/native_environment_lock.rb"), str(lock), str(project)], capture_output=True)
        expression = '((import ' + str(root / 'lib-overlays/default/read-native-environment-lock.nix') + ' { lib = import ' + str(args.nix_lib) + '; }) { src = ' + str(project) + '; }).lock.version'
        nix = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expression], capture_output=True)
        assert ruby.returncode in (0, 1), (label, ruby.stderr.decode())
        assert (ruby.returncode == 0) == (nix.returncode == 0) == expected, (label, ruby.stderr.decode(), nix.stderr.decode())
print(f"{len(cases)} shared host/Nix v4 envelope/project checks passed")
