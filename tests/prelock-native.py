# SPDX-License-Identifier: MIT
"""Actual pre-lockfile frontend, native publisher and ordinary consumer."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import tarfile
import io

parser = argparse.ArgumentParser()
parser.add_argument("--sdk", required=True, type=Path)
parser.add_argument("--cli", required=True, type=Path)
parser.add_argument("--work", required=True, type=Path)
args = parser.parse_args()
ROOT = Path(__file__).resolve().parent.parent
args.work.mkdir()
logs = args.work / "logs"
logs.mkdir()
home = args.work / "home"
home.mkdir()
env = {key: value for key, value in os.environ.items() if key not in ("RUBYOPT", "RUBYLIB", "GEM_HOME", "GEM_PATH") and not key.startswith(("BUNDLE_", "BUNDLER_"))}
env.update(HOME=str(home), BUNDLER_PURIFIER_PROJECT_RUBY=str(args.sdk))
# The built CLI supplies its own immutable library, tools and shared sources.
for key in ["BUNDLER_PURIFIER_LIB", "BUNDLER_PURIFIER_TOOLS", "BUNDLER_PURIFIER_SHARED_FLAKE", "BUNDLER_PURIFIER_NIXPKGS", "BUNDLER_PURIFIER_RUBY_EXPRESSION", "BUNDLER_PURIFIER_NATIVE_BUILD_INPUTS_EXPRESSION", "PYTHONPATH"]:
    if key in os.environ:
        env[key] = os.environ[key]
receipt = dict(complete=False, commands=[], scope="Genuine Ruby184/Gem135/Bundler08 native frontend")


def save():
    (args.work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


def run(label, argv, cwd, environment=None, success=True):
    result = subprocess.run([str(arg) for arg in argv], cwd=cwd, env=environment or env,
                            capture_output=True, timeout=900)
    (logs / (label + ".stdout")).write_bytes(result.stdout)
    (logs / (label + ".stderr")).write_bytes(result.stderr)
    receipt["commands"].append(dict(label=label, argv=[str(arg) for arg in argv], exit=result.returncode,
                                     expectedSuccess=success, stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),
                                     stderrSha256=hashlib.sha256(result.stderr).hexdigest()))
    save()
    assert (result.returncode == 0) == success, (label, result.returncode, result.stderr.decode()[-6000:])
    return result.stdout.decode()


project = args.work / "project"
project.mkdir()
fixture = ROOT / "tests/fixtures/ruby184"
for name in ["historical_greeting.gemspec", "lib", "exe"]:
    source = fixture / name
    if source.is_dir():
        shutil.copytree(source, project / name)
    else:
        shutil.copyfile(source, project / name)
(project / "Gemfile").write_text("# genuine pre-lockfile provider\n")
run("capture", [args.cli, "lock"], project)
lock = project / "bundler-purifier.lock.json"
original = lock.read_bytes()
document = json.loads(original)
assert document["version"] == 4 and document["nativeResolution"]["nativeLockFile"] is None
assert not (project / "Gemfile.lock").exists()
receipt["nativeSDK"] = document["nativeResolution"]["sdk"]
receipt["lockSha256"] = hashlib.sha256(original).hexdigest()
run("lock-no-op-without-state", [args.cli, "lock"], project)
assert lock.read_bytes() == original
run("reject-missing-working-state", [args.cli, "shell", "ruby", "-e", 'raise "activated missing state"'], project, success=False)
run("prefetch", [args.cli, "prefetch"], project)
value = run("wrapper-runtime", [args.cli, "shell", "ruby", "-Ilib", "exe/historical-greeting"], project)
assert "42 on 1.8.4" in value
run("wrapper-argv", [args.cli, "shell", "ruby", "-e", 'raise unless ARGV==["space value","$literal","--dash"];puts "ARGV|exact"', "space value", "$literal", "--dash"], project)
state = project / ".bundler-purifier/native-replay.json"
assert state.is_file()
state_bytes = state.read_bytes()
state.unlink()
run("reject-removed-receipt", [args.cli, "shell", "ruby", "-e", 'raise "activated missing receipt"'], project, success=False)
state.write_bytes(state_bytes)
(project / "Gemfile").write_text("# changed original manifest\n")
run("reject-stale-manifest", [args.cli, "prefetch"], project, success=False)
(project / "Gemfile").write_bytes(b"# genuine pre-lockfile provider\n")
(project / "Gemfile.lock").write_text("")
run("reject-ambiguous-native-lock", [args.cli, "prefetch"], project, success=False)
(project / "Gemfile.lock").unlink()

stored = {}
uploads = []
agents = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def do_GET(self):
        name = self.path.removeprefix("/gems/")
        if self.path.startswith("/gems/") and name in stored:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(stored[name])
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        assert self.path == "/api/v1/gems" and self.headers["Authorization"] == "fixture-key"
        uploads.append(body)
        agents.append(self.headers.get("User-Agent"))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")


credentials = home / ".gem/credentials"
credentials.parent.mkdir()
credentials.write_text("---\n:rubygems_api_key: fixture-key\n")
credentials.chmod(0o600)
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
host = "http://127.0.0.1:" + str(server.server_port)
local = {key: value for key, value in env.items() if key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
try:
    run("publish-projected", [args.cli, "publish", "--host", host, "--no-http-proxy"], project, local)
    assert len(uploads) == 2 and all(agent == "Gemcutter/0.2.0" for agent in agents)
    # Join bodies against genuine native archive metadata without substituting
    # an SDK specification class in the server process.
    payloads = args.work / "published"
    payloads.mkdir()
    for index, body in enumerate(uploads):
        archive = payloads / (str(index) + ".gem")
        archive.write_bytes(body)
        name = run("published-name-" + str(index), [args.sdk / "bin/ruby", "-rrubygems/format", "-e", 'puts Gem::Format.from_file_by_path(ARGV[0]).spec.full_name+".gem"', archive], payloads).strip()
        stored[name] = body
        archive.rename(payloads / name)
    receipt["publishedArchives"] = {name: hashlib.sha256(body).hexdigest() for name, body in stored.items()}
    receipt["publicationNativeUserAgents"] = agents
    before = len(uploads)
    run("publish-dedup", [args.cli, "publish", "--host", host, "--no-http-proxy"], project, local)
    assert len(uploads) == before
finally:
    server.shutdown()
    server.server_close()

consumer = args.work / "ordinary"
consumer.mkdir()
ordinary = dict(local, GEM_HOME=str(consumer / "gems"), GEM_PATH=str(consumer / "gems"))
native_json = next(path for path in payloads.glob("json-*.gem"))
native_project = next(path for path in payloads.glob("historical_greeting-*.gem"))
run("ordinary-install", [args.sdk / "bin/gem", "install", "--local", "--no-rdoc", "--no-ri", native_json, native_project], consumer, ordinary)
output = run("ordinary-runtime", [args.sdk / "bin/ruby", "-e", 'require "historical_greeting";require "digest/sha2";raise unless HistoricalGreeting.answer==42 && JSON.parser==JSON::Ext::Parser;puts "ORDINARY|#{RUBY_VERSION}|#{Gem::VERSION}|42";File.readlines("/proc/self/maps").map{|line|line.split.last}.uniq.each{|path|puts "NATIVE|#{path}|#{File.open(path,"rb"){|file|Digest::SHA256.hexdigest(file.read)}}" if path =~ /json\\/ext\\/parser.so$/}'], consumer, ordinary)
assert "ORDINARY|1.8.4|1.3.5|42" in output
native = next(line for line in output.splitlines() if line.startswith("NATIVE|"))
_, native_path, native_sha = native.split("|")
assert Path(native_path).is_relative_to(consumer)
assert hashlib.sha256(Path(native_path).read_bytes()).hexdigest() == native_sha
with tarfile.open(native_json) as gem:
    with tarfile.open(fileobj=io.BytesIO(gem.extractfile("data.tar.gz").read()), mode="r:gz") as payload:
        parsers = [member for member in payload.getmembers() if member.name.endswith("json/ext/parser.so")]
        assert len(parsers) == 1
        assert hashlib.sha256(payload.extractfile(parsers[0]).read()).hexdigest() == native_sha
receipt["ordinaryLoadedParser"] = native_path
receipt["ordinaryLoadedParserSha256"] = native_sha
receipt["ordinaryParserMatchesPublishedPayload"] = True
receipt["complete"] = True
save()
