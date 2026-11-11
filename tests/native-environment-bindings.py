# SPDX-License-Identifier: MIT
"""Native bound-only requirements and genuine cached resolver competition."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--sdk", required=True, type=Path)
parser.add_argument("--capture", required=True, type=Path)
parser.add_argument("--archives", required=True, type=Path)
parser.add_argument("--evidence", required=True, type=Path)
args = parser.parse_args()
args.evidence.mkdir()
adapter = Path(__file__).resolve().parent.parent / "tools/native_environment_bindings.rb"
record = json.loads(args.capture.read_text())
archives = json.loads(args.archives.read_text())
commands = []
base = {key: value for key, value in os.environ.items() if key not in ("RUBYOPT", "RUBYLIB", "GEM_HOME", "GEM_PATH") and not key.startswith(("BUNDLE_", "BUNDLER_"))}


def run(label, argv, cwd, env, success=True, reason=None):
    result = subprocess.run([str(arg) for arg in argv], cwd=cwd, env=env,
                            capture_output=True, timeout=45)
    (args.evidence / (label + ".stdout")).write_bytes(result.stdout)
    (args.evidence / (label + ".stderr")).write_bytes(result.stderr)
    assert (result.returncode == 0) == success, (label, result.returncode, result.stderr.decode())
    if reason:
        assert reason.encode() in result.stderr, (label, result.stderr.decode())
    commands.append(dict(label=label, argv=[str(arg) for arg in argv], exit=result.returncode,
                         expectedSuccess=success, stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),
                         stderrSha256=hashlib.sha256(result.stderr).hexdigest()))
    return result.stdout.decode()


with tempfile.TemporaryDirectory(prefix="native-environment-bindings-") as temporary:
    temporary = Path(temporary)
    home = temporary / "home"
    home.mkdir()
    base["HOME"] = str(home)
    data = temporary / "declared bindings.tsv"
    data.write_text("provided\t1.0.0.1.nix.control\n")
    env = dict(base, BUNDLER_PURIFIER_NATIVE_BINDINGS=str(data), BUNDLER_PURIFIER_NATIVE_OPERATION="resolve", RUBYOPT="-r" + str(adapter))
    program = '''raise "codec activated before selection" if defined?(JSON)
a=Gem::Dependency.new("provided", ">= 0")
original=a.version_requirements
PurifierNativeEnvironmentBindings.normalize_dependency(a)
raise unless a.class==Gem::Dependency && a.version_requirements.class==Gem::Requirement
raise unless a.version_requirements.to_s=="= 1.0.0.1.nix.control" && a.version_requirements.prerelease?
raise if a.version_requirements.satisfied_by?(Gem::Version.new("99.0.0"))
raise unless original.to_s==">= 0"
b=Gem::Dependency.new("ordinary", ">= 9")
original=b.version_requirements
PurifierNativeEnvironmentBindings.normalize_dependency(b)
raise unless b.version_requirements.equal?(original)
d=Gem::Dependency.new("provided", ">= 9", :development)
original=d.version_requirements
PurifierNativeEnvironmentBindings.normalize_dependency(d)
raise unless d.version_requirements.equal?(original)
candidate=Gem::Dependency.new("provided", "= 99.0.0")
raise "native candidate matching changed" unless candidate.version_requirements.to_s=="= 99.0.0"
s=Gem::Specification.new
s.add_runtime_dependency("ordinary", ">= 9")
s.add_development_dependency("provided", ">= 9")
s.add_runtime_dependency("provided", ">= 0")
raw=s.purifier_environment_original_dependencies
original_ordinary=raw[0].version_requirements
original_development=raw[1].version_requirements
original_bound=raw[2].version_requirements
raise unless s.dependencies.equal?(raw) && raw[2].class==Gem::Dependency
raise unless raw[0].version_requirements.equal?(original_ordinary) && raw[1].version_requirements.equal?(original_development)
raise unless raw[2].version_requirements.to_s=="= 1.0.0.1.nix.control" && original_bound.to_s==">= 0"
[["ordinary","%%"],["provided","%%"]].each do |name, requirement|
  invalid=false
  begin; Gem::Dependency.new(name, requirement); rescue ArgumentError; invalid=true; end
  raise "SDK requirement guard bypassed" unless invalid
end
require "bundler"
c=Bundler::Dependency.new("provided", :version=>">= 0")
PurifierNativeEnvironmentBindings.normalize_dependency(c)
raise unless c.class==Bundler::Dependency && c.version.to_s=="= 1.0.0.1.nix.control"
raise unless Gem::Dependency.public_instance_methods.map{|m|m.to_s}.include?("version_requirements")
PurifierNativeEnvironmentBindings.load(ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"])
ENV["BUNDLER_PURIFIER_NATIVE_OPERATION"]="runtime"
rejected=false
begin;PurifierNativeEnvironmentBindings.load(ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"]);rescue RuntimeError;rejected=true;end
raise "binding operation changed" unless rejected
puts "GENUINE|#{RUBY_VERSION}|#{Gem::VERSION}|#{Bundler::VERSION}|bound-only"
'''
    run("native-bound-only-objects", [args.sdk / "bin/ruby", "-e", program], temporary, env)
    runtime_env = dict(env, BUNDLER_PURIFIER_NATIVE_OPERATION="runtime")
    run("runtime-without-tool-library-preload", [args.sdk / "bin/ruby", "-e", 'raise "tool library preloaded" if defined?(Bundler);raise "codec preloaded" if defined?(JSON);puts "RUNTIME|no-preload"'], temporary, runtime_env)
    run("unknown-binding-operation", [args.sdk / "bin/ruby", "-e", 'raise "accepted unknown operation"'], temporary,
        dict(env, BUNDLER_PURIFIER_NATIVE_OPERATION="unknown"), False, "unsupported native binding operation")
    for label, raw, reason in [
        ("duplicate", b"provided\t1\nprovided\t2\n", "duplicate native binding"),
        ("missing-newline", b"provided\t1", "lacks final newline"),
        ("blank-record", b"provided\t1\n\n", "malformed native binding"),
        ("extra-column", b"provided\t1\textra\n", "malformed native binding"),
        ("path-name", b"../provided\t1\n", "invalid native binding name"),
        ("NUL", b"provided\t1\x00\n", "invalid native binding version"),
        ("whitespace", b"provided\t1 2\n", "invalid native binding version"),
        ("code-injection", b'provided\t1\nraise "executed"\n', "malformed native binding"),
        ("oversized", b"x" * 1048577, "exceeds limit"),
    ]:
        bad = temporary / (label + ".tsv")
        bad.write_bytes(raw)
        bad_env = dict(env, BUNDLER_PURIFIER_NATIVE_BINDINGS=str(bad))
        run("reject-" + label, [args.sdk / "bin/ruby", "-e", 'raise "accepted malformed bindings"'],
            temporary, bad_env, False, reason)
    data.write_text("".join(package["name"] + "\t" + package["version"] + "\n"
                            for package in sorted(record["packages"], key=lambda package: package["name"])))
    built = []
    for name, version, value in [("incoming_consumer", "99.0.0", 99), ("ordinary_plain", "1.0.0", 1)]:
        source = temporary / (name + "-source")
        (source / "lib").mkdir(parents=True)
        (source / "lib" / (name + ".rb")).write_text("module " + ("IncomingConsumer" if name == "incoming_consumer" else "OrdinaryPlain") + "; def self.answer; " + str(value) + "; end; end\n")
        (source / "source.gemspec").write_text('Gem::Specification.new do |s|\n s.name=' + json.dumps(name) + '\n s.version=' + json.dumps(version) + '\n s.summary="native resolver control"\n s.authors=["fixture"]\n s.files=["lib/' + name + '.rb"]\nend\n')
        run("build-" + name, [args.sdk / "bin/gem", "build", "source.gemspec"], source, base)
        built.append(next(source.glob("*.gem")))
    for label, environment, manifest, succeeds in [
        ("ordinary-competitor", base, 'gem "incoming_consumer"\n', True),
        ("bound-prerelease", env, 'gem "incoming_consumer"\n', True),
        ("unbound-incompatible", env, 'gem "incoming_consumer"\ngem "ordinary_plain", ">= 2"\n', False),
        ("unbound-conflicting", env, 'gem "incoming_consumer"\ngem "ordinary_plain", "= 1"\ngem "ordinary_plain", "= 2"\n', False),
    ]:
        project = temporary / label
        project.mkdir()
        (project / "Gemfile").write_text(manifest)
        before = (project / "Gemfile").read_bytes()
        cache = project / "vendor/gems/ruby/1.8/cache"
        cache.mkdir(parents=True)
        for archive in [Path(path) for path in archives.values()] + built:
            shutil.copyfile(archive, cache / archive.name)
        run(label + "-resolve", [args.sdk / "bin/gem", "bundle", "--cached"], project, environment, succeeds)
        assert (project / "Gemfile").read_bytes() == before
        assert not (project / "Gemfile.lock").exists()
        if succeeds:
            expected = 99 if label == "ordinary-competitor" else 42
            runtime = 'require "incoming_consumer";raise unless IncomingConsumer.answer==' + str(expected) + ';puts "VALUE|' + str(expected) + '"'
            child_env = dict(environment, BUNDLER_PURIFIER_NATIVE_OPERATION="runtime") if label == "bound-prerelease" else environment
            run(label + "-runtime", [args.sdk / "bin/ruby", "-r", str(project / "vendor/gems/environment.rb"), "-e", runtime], project, child_env)
print(json.dumps(dict(complete=True, commands=commands,
                      adapterSha256=hashlib.sha256(adapter.read_bytes()).hexdigest(),
                      driverSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      scope="Native adapter controls only; not integrated v4 compatibility"), indent=2))
