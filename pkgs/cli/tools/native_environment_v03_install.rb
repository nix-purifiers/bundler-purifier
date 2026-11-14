# SPDX-License-Identifier: MIT
# Genuine artifact-0.3.1 APIs; verified input archives have a separate owned role.
require "rubygems"
require "rubygems/exceptions"
require "rubygems/format"
require "rubygems/source_index"
require "pathname"
require "fileutils"
require "digest/sha2"
raise "unsupported v03 SDK" unless RUBY_VERSION == "1.8.3" && defined?(Gem::RubyGemsVersion) && ["1.0.1", "0.9.5"].include?(Gem::RubyGemsVersion)
gem "bundler", "= 0.3.1"
require "bundler"
raise "wrong v03 client report" unless Bundler::VERSION == "0.5.0"
raise "usage: native v03 install PROJECT ARCHIVE_ROLE" unless ARGV.size == 2
root = Pathname.new(ARGV[0]).realpath.to_s
archive_root = Pathname.new(ARGV[1]).realpath.to_s
raise "invalid v03 archive role" unless archive_root == File.join(File.dirname(root), "native-input-archives")
gemfile = File.join(root, "Gemfile")
raise "Gemfile escapes project role" unless File.file?(gemfile) && Pathname.new(gemfile).realpath.to_s.index(root + "/") == 0
inventory = File.join(archive_root, "inventory.tsv")
raise "invalid bounded v03 archive inventory" unless File.file?(inventory) && !File.symlink?(inventory) && File.size(inventory) <= 1048576
bytes = File.open(inventory, "rb") { |file| file.read }
raise "v03 archive inventory lacks final newline" unless bytes.empty? || bytes[-1, 1] == "\n"
lines = bytes.empty? ? [] : bytes.split("\n", -1)[0..-2]
raise "too many v03 archives" if lines.size > 4096
index = Gem::SourceIndex.new({})
archives = {}
aliases = {}
lines.each do |line|
  match = /\A([0-9a-f]{64})\t([0-9]+\.gem)\z/.match(line)
  raise "invalid v03 archive inventory row" unless match
  archive = File.join(archive_root, match[2])
  raise "v03 archive escapes sealed role" unless File.file?(archive) && !File.symlink?(archive) && Pathname.new(archive).realpath.to_s.index(archive_root + "/") == 0
  sha = Digest::SHA256.hexdigest(File.open(archive, "rb") { |file| file.read })
  raise "v03 archive bytes changed" unless sha == match[1]
  spec = Gem::Format.from_file_by_path(archive).spec
  raise "v03 archive is not a native specification" unless spec.is_a?(Gem::Specification)
  raise "unsafe v03 archive coordinates" unless spec.name =~ /\A[A-Za-z0-9_.-]+\z/ && spec.name != "." && spec.name != ".." && spec.version.to_s =~ /\A[0-9]+(?:\.[0-9]+)*\z/
  next unless Gem::Platform.match(spec.platform)
  key = [spec.name, spec.version.to_s, spec.platform.to_s]
  filename = spec.name + "-" + spec.version.to_s + ".gem"
  raise "v03 native cache platform alias conflicts" if aliases[filename] && aliases[filename] != [key, sha]
  aliases[filename] = [key, sha]
  raise "conflicting v03 native archives" if archives[key] && archives[key][1] != sha
  next if archives[key]
  archives[key] = [archive, sha, spec]
  index.add_spec(spec)
end
raise "metadata codec loaded before selection" if defined?(JSON)
manifest_file = Bundler::ManifestFile.load(gemfile)
raise "unsupported v03 repository layout" unless manifest_file.gem_path.to_s == File.join(root, "vendor", "gems") && manifest_file.bindir.to_s == File.join(root, "bin")
raise "v03 RubyGems must remain enabled" unless manifest_file.rubygems == true
raise "invalid v03 system-gems policy" unless manifest_file.system_gems == true || manifest_file.system_gems == false
manifest_file.dependencies.each do |dependency|
  raise "unsupported v03 contexts" if dependency.only || dependency.except
end
manifest_file.sources.each do |source|
  raise "unsupported v03 source kind" unless source.is_a?(Bundler::Source) && ["http", "https", "file"].include?(source.uri.scheme)
end
requirements = manifest_file.dependencies.map { |dependency| dependency.to_gem_dependency }
root_requirements = requirements.map { |dependency| [dependency.name, dependency.version_requirements.to_s] }
selected = Bundler::Resolver.resolve(requirements, index)
raise "native v03 cached resolver found no complete selection" unless selected
identities = selected.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] }
raise "duplicate native v03 selected names" unless identities.map { |key| key[0] }.uniq.size == identities.size
executable_owners = {}
selected.each do |spec|
  raise "native Gem095 executables require bin payloads" if Gem::RubyGemsVersion == "0.9.5" && !spec.executables.empty? && spec.bindir != "bin"
  spec.executables.each do |name|
    raise "conflicting v03 executable owners" if executable_owners[name]
    executable_owners[name] = spec.name
  end
  raise "source extensions require compiler attestation" unless spec.extensions.empty?
  raise "selected v03 archive not in verified inventory" unless archives[[spec.name, spec.version.to_s, spec.platform.to_s]]
  raise "unsafe v03 require path" unless spec.require_paths.all? { |path| path.is_a?(String) && !path.empty? && path[0, 1] != "/" && path.index("\\").nil? && path.index("\0").nil? && path.split("/").all? { |part| !part.empty? && part != ".." } }
  raise "unsafe v03 bin directory" unless spec.bindir.nil? || (spec.bindir.is_a?(String) && !spec.bindir.empty? && spec.bindir[0, 1] != "/" && spec.bindir.index("\\").nil? && spec.bindir.split("/").all? { |part| !part.empty? && part != ".." })
  raise "unsafe v03 executable name" unless spec.executables.all? { |name| name.is_a?(String) && name =~ /\A[A-Za-z0-9_.-]+\z/ && name != "." && name != ".." }
  payloads = {}
  format = Gem::Format.from_file_by_path(archives[[spec.name, spec.version.to_s, spec.platform.to_s]][0])
  format.file_entries.each do |entry, data|
    path = entry["path"]
    raise "unsafe v03 payload path" unless path.is_a?(String) && !path.empty? && path[0, 1] != "/" && path.index("\\").nil? && path.index("\0").nil? && path.split("/").all? { |part| !part.empty? && part != ".." }
    data = "" if data.nil? && entry["size"] == 0
    raise "invalid v03 payload size" unless data.is_a?(String) && data.size == entry["size"]
    normalized = File.expand_path(path, "/native-payload")
    raise "v03 payload escapes package role" unless normalized.index("/native-payload/") == 0
    value = [entry["mode"], Digest::SHA256.hexdigest(data)]
    raise "conflicting v03 payload aliases" if payloads[normalized] && payloads[normalized] != value
    payloads[normalized] = value
  end
end
cache = File.join(root, "vendor", "gems", "cache")
raise "v03 cache role must be fresh" if File.exist?(File.join(root, "vendor")) || File.symlink?(File.join(root, "vendor"))
FileUtils.mkdir_p(cache)
selected.each do |spec|
  key = [spec.name, spec.version.to_s, spec.platform.to_s]
  archive, sha, original = archives.fetch(key)
  destination = File.join(cache, original.name + "-" + original.version.to_s + ".gem")
  FileUtils.cp(archive, destination)
  raise "staged v03 archive differs" unless Digest::SHA256.hexdigest(File.open(destination, "rb") { |file| file.read }) == sha
end
# The actual SDK executes its own readiness predicate and install path.
# Only its complete selected closure is present, under numeric cache basenames.
manifest_file.install(false)
actual = manifest_file.manifest.gems_for("default")
raise "native v03 installed selection differs" unless actual && actual.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] }.sort == identities.sort
raise "native v03 root requirements changed" unless root_requirements == manifest_file.dependencies.map { |dependency| [dependency.name, dependency.to_gem_dependency.version_requirements.to_s] }
raise "native v03 generated environment missing" unless File.file?(File.join(root, "vendor", "gems", "environments", "default.rb"))
puts "V03-NATIVE|" + RUBY_VERSION + "|" + Gem::RubyGemsVersion + "|" + Bundler::VERSION + "|" + identities.size.to_s
