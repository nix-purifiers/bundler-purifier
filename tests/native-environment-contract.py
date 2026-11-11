# SPDX-License-Identifier: MIT
"""Shared malformed-data corpus; identities here are synthetic contract data,
not SDK attestations. Native SDK execution has a separate acceptance workflow.
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
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent


def digest(raw):
    return "sha256-" + base64.b64encode(hashlib.sha256(raw).digest()).decode()


def snapshot(path, raw):
    return dict(path=path, size=len(raw), sha256=digest(raw), base64=base64.b64encode(raw).decode())


components = [dict(name=name, version=version, archiveHash=digest(b"synthetic artifact"),
                   libraryHash=digest(b"synthetic library"))
              for name, version in [("ruby", "1.8.4"), ("rubygems", "1.3.5"),
                                    ("bundler", "0.8.1"), ("json", "1.8.6")]]
valid = dict(format="bundler-native-environment", schemaVersion=1, interface="environment-v08",
             nativeLockFile=None, contexts=["default"],
             sdk=dict(ruby="1.8.4", patchlevel=None, abi="1.8", platform="x86_64-linux",
                      interpreter=digest(b"synthetic interpreter"), components=components,
                      clientArtifact=components[2],
                      clientReport=dict(name="Bundler::VERSION", value="0.8.1"),
                      rubygemsReport=dict(name="Gem::VERSION", value="1.3.5")),
             manifests=[snapshot("Gemfile", b'gem "leaf"\n')],
             snapshots=[snapshot("vendor/gems/environment.rb", b"# SDK text\n")],
             packages=[dict(name="leaf", version="1.0.0", platform="ruby", dependencies=[],
                            archiveHash=digest(b"synthetic package"),
                            installedPath="vendor/gems/ruby/1.8/gems/leaf-1.0.0",
                            sourceKind="verified-cache")],
             rootRequirements=[dict(name="leaf", requirements=[">= 0"])])
cases = [("valid", valid, True)]


def changed(label, transform):
    candidate = copy.deepcopy(valid)
    transform(candidate)
    cases.append((label, candidate, False))


changed("unknown-field", lambda v: v.update(unknown=True))
changed("unknown-interface", lambda v: v.update(interface="environment-v03"))
changed("float-schema", lambda v: v.update(schemaVersion=1.0))
changed("native-lockfile", lambda v: v.update(nativeLockFile="Gemfile.lock"))
changed("unknown-context", lambda v: v.update(contexts=["default", "test"]))
changed("duplicate-context", lambda v: v.update(contexts=["default", "default"]))
changed("duplicate-component", lambda v: v["sdk"]["components"].append(v["sdk"]["components"][0]))
changed("missing-codec", lambda v: v["sdk"].update(components=v["sdk"]["components"][:-1]))
changed("wrong-report", lambda v: v["sdk"]["clientReport"].update(value="0.3.1"))
changed("wrong-artifact", lambda v: v["sdk"]["clientArtifact"].update(version="0.9.9"))
changed("string-patch", lambda v: v["sdk"].update(patchlevel="0"))
changed("fabricated-zero-patch", lambda v: v["sdk"].update(patchlevel=0))
changed("missing-real-patch", lambda v: v["sdk"].update(ruby="1.8.5", patchlevel=None))
changed("missing-manifest", lambda v: v.update(manifests=[]))
changed("duplicate-snapshot", lambda v: v["snapshots"].append(v["snapshots"][0]))
changed("path-traversal", lambda v: v["snapshots"][0].update(path="vendor/../outside"))
changed("absolute-path", lambda v: v["snapshots"][0].update(path="/outside"))
changed("float-size", lambda v: v["snapshots"][0].update(size=11.0))
changed("negative-size", lambda v: v["snapshots"][0].update(size=-1))
changed("oversize", lambda v: v["snapshots"][0].update(size=1048577))
changed("truncated-base64", lambda v: v["snapshots"][0].update(base64="YWJ"))
changed("padding-alias", lambda v: v.update(snapshots=[dict(path="x", size=1, sha256=digest(b"a"), base64="YR==")]))
changed("base64-whitespace", lambda v: v["snapshots"][0].update(base64="YW Jj"))
changed("snapshot-hash", lambda v: v["snapshots"][0].update(sha256=digest(b"wrong")))
changed("encoded-NUL", lambda v: v.update(snapshots=[snapshot("x", b"\x00")]))
changed("duplicate-package", lambda v: v["packages"].append(v["packages"][0]))
changed("unknown-source", lambda v: v["packages"][0].update(sourceKind="git"))
changed("missing-root", lambda v: v["rootRequirements"][0].update(name="absent"))
changed("missing-runtime", lambda v: v["packages"][0].update(dependencies=[dict(name="absent", requirements=[">= 0"], type="runtime")]))
changed("duplicate-root", lambda v: v["rootRequirements"].append(v["rootRequirements"][0]))
changed("extra-unrelated-package", lambda v: v["packages"].append(dict(v["packages"][0], name="unrelated")))
changed("aggregate-overflow", lambda v: v.update(snapshots=[snapshot(f"file-{i}.rb", b"#" * 1048576) for i in range(7)]))

host = '''require ARGV.shift
begin
  PurifierNativeEnvironment.validate!(PurifierNativeEnvironment.parse(File.binread(ARGV.shift)))
rescue PurifierNativeEnvironment::Invalid
  exit 1
end
'''
with tempfile.TemporaryDirectory(prefix="native-environment-contract-") as temporary:
    temporary = Path(temporary)
    for label, value, expected in cases:
        document = temporary / (label + ".json")
        document.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        ruby = subprocess.run([args.ruby, "-e", host, str(root / "tools/native_environment.rb"), str(document)], capture_output=True)
        expression = ('let raw = builtins.readFile ' + str(document) + '; value = builtins.fromJSON raw; in '
                      'raw == builtins.toJSON value + "\\n" && (import ' + str(root / 'nix/lib/native-environment.nix')
                      + ' { lib = import ' + str(args.nix_lib) + '; } value).valid')
        nix = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expression], capture_output=True)
        assert ruby.returncode in (0, 1), (label, ruby.stderr.decode())
        assert nix.returncode == 0, (label, nix.stderr.decode())
        assert (ruby.returncode == 0) == json.loads(nix.stdout) == expected, (label, ruby.stderr, nix.stdout)
    baseline_file = temporary / "baseline.json"
    baseline_file.write_text(json.dumps(valid))
    comparison_host = '''require ARGV.shift
begin
  PurifierNativeEnvironment.compare_observation!(JSON.parse(File.binread(ARGV.shift)), JSON.parse(File.binread(ARGV.shift)))
rescue PurifierNativeEnvironment::Invalid
  exit 1
end
'''
    comparisons = []
    for label, mutate, expected in [
        ("unchanged", lambda v: None, True),
        ("ABI", lambda v: v["sdk"].update(abi="1.9"), False),
        ("platform", lambda v: v["sdk"].update(platform="aarch64-linux"), False),
        ("interpreter", lambda v: v["sdk"].update(interpreter=digest(b"competitor")), False),
        ("archive", lambda v: v["packages"][0].update(archiveHash=digest(b"competitor")), False),
        ("manifest", lambda v: v.update(manifests=[snapshot("Gemfile", b'gem "competitor"\n')]), False),
        ("regenerated-snapshot", lambda v: v.update(snapshots=[snapshot("vendor/gems/environment.rb", b"# current root\n")]), True),
        ("component-order", lambda v: v["sdk"]["components"].reverse(), True),
    ]:
        candidate = copy.deepcopy(valid)
        mutate(candidate)
        candidate_file = temporary / ("compare-" + label + ".json")
        candidate_file.write_text(json.dumps(candidate))
        result = subprocess.run([args.ruby, "-e", comparison_host, str(root / "tools/native_environment.rb"),
                                 str(baseline_file), str(candidate_file)], capture_output=True)
        assert result.returncode in (0, 1), (label, result.stderr.decode())
        assert (result.returncode == 0) == expected, (label, result.stderr.decode())
        comparisons.append(label)
    # Byte hashes must agree across hosts, including each non-NUL byte in
    # isolation and mixed invalid UTF-8. Never compare JSON-rendered bytes.
    records = [snapshot("x", bytes([byte])) for byte in range(1, 256)]
    records += [snapshot("x", b"\xff\xc0\x80\n"), snapshot("x", b"")]
    document = temporary / "byte-corpus.json"
    document.write_text(json.dumps(records))
    expression = 'map (v: builtins.stringLength (import ' + str(root / 'nix/lib/native-environment-bytes.nix') + ' v)) (builtins.fromJSON (builtins.readFile ' + str(document) + '))'
    nix = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expression], capture_output=True)
    assert nix.returncode == 0, nix.stderr.decode()
    assert json.loads(nix.stdout) == [record["size"] for record in records]
print(f"{len(cases)} host/Nix contract cases, {len(records)} exact byte hashes and {len(comparisons)} semantic comparisons passed")
