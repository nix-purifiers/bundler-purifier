# SPDX-License-Identifier: MIT
# Run in a separate selected-SDK process after native offline regeneration.
# Keep syntax and APIs compatible with the original Ruby 1.8.4 runtime.
require "rubygems"
require "pathname"
require "digest/sha2"
require "find"

module PurifierEnvironmentObservation
  def self.fail!(message)
    raise "bundler-purifier: #{message}"
  end

  def self.within(root, path)
    real = File.realpath(path) if File.respond_to?(:realpath)
    real ||= Pathname.new(path).realpath.to_s
    prefix = root + File::SEPARATOR
    fail!("native selected path escapes owned workspace") unless real.index(prefix) == 0
    real[prefix.length..-1]
  end

  def self.legacy?
    !defined?(Gem::VERSION) && defined?(Gem::RubyGemsVersion) && ["1.0.1", "0.9.5"].include?(Gem::RubyGemsVersion) && RUBY_VERSION == "1.8.3"
  end

  def self.runtime_dependency?(dependency)
    legacy? || dependency.type == :runtime
  end

  def self.input_archives(root)
    role = File.join(File.dirname(root), "native-input-archives")
    fail!("missing v03 verified archive role") unless File.directory?(role) && !File.symlink?(role) && Pathname.new(role).realpath.to_s == role
    inventory = File.join(role, "inventory.tsv")
    fail!("invalid v03 archive inventory") unless File.file?(inventory) && !File.symlink?(inventory) && File.size(inventory) <= 1048576
    bytes = File.open(inventory, "rb") { |file| file.read }
    fail!("v03 archive inventory lacks final newline") unless bytes.empty? || bytes[-1, 1] == "\n"
    lines = bytes.empty? ? [] : bytes.split("\n", -1)[0..-2]
    fail!("too many v03 archive rows") if lines.size > 4096
    result = {}
    require "rubygems/exceptions"
    require "rubygems/format"
    lines.each do |line|
      match = /\A([0-9a-f]{64})\t([0-9]+\.gem)\z/.match(line)
      fail!("invalid v03 archive row") unless match
      path = File.join(role, match[2])
      fail!("v03 archive escapes verified role") unless File.file?(path) && !File.symlink?(path) && Pathname.new(path).realpath.to_s.index(role + "/") == 0
      sha = Digest::SHA256.hexdigest(File.open(path, "rb") { |file| file.read })
      fail!("v03 archive bytes changed") unless sha == match[1]
      spec = Gem::Format.from_file_by_path(path).spec
      key = [spec.name, spec.version.to_s, spec.platform.to_s]
      fail!("v03 archive identity conflicts") if result[key] && result[key][1] != sha
      result[key] = [path, sha]
    end
    result
  end

  def self.clauses(requirement)
    legacy? ? requirement.as_list.sort : requirement.requirements.map { |pair| pair[0].to_s + " " + pair[1].to_s }.sort
  end

  def self.dependencies(spec)
    spec.dependencies.map do |dependency|
      requirement = dependency.version_requirements
      clauses = self.clauses(requirement)
      {"name" => dependency.name, "type" => (legacy? ? "runtime" : dependency.type.to_s),
       "requirements" => clauses.sort}
    end.sort_by { |dependency| [dependency["name"], dependency["type"]] }
  end

  def self.identity(spec)
    {"name" => spec.name, "version" => spec.version.to_s,
     "platform" => spec.platform.to_s, "dependencies" => dependencies(spec),
     "requirePaths" => spec.require_paths.dup, "bindir" => spec.bindir}
  end

  def self.observe(root)
    root = Pathname.new(root).realpath.to_s
    fail!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(File.join(root, "Gemfile.lock"))
    gemfile = File.join(root, "Gemfile")
    within(root, gemfile)
    fail!("native Gemfile is not a regular file") unless File.file?(gemfile)
    legacy = legacy?
    fail!("wrong native RubyGems") unless legacy || (defined?(Gem::VERSION) && Gem::VERSION == "1.3.5")
    # Load only freshly regenerated native state. Do not load a codec or the
    # Bundler library before the SDK's selected environment has taken effect.
    environment = File.join(root, "vendor", "gems", legacy ? "environments/default.rb" : "environment.rb")
    within(root, environment)
    # Validate every generated repository path before the SDK environment can
    # evaluate installed gemspecs. A symlink outside the owned root must never
    # become Ruby code executed during observation.
    Find.find(File.join(root, "vendor", "gems")) do |path|
      within(root, path)
      fail!("unsupported special file in native workspace") unless File.file?(path) || File.directory?(path)
    end
    # Select the actual SDK library before generated state adjusts load paths.
    # Bundler itself does not activate a metadata JSON codec.
    gem "bundler", legacy ? "= 0.3.1" : "= 0.8.1"
    require "bundler"
    fail!("wrong native Bundler interface") unless Bundler::VERSION == (legacy ? "0.5.0" : "0.8.1")
    require environment
    specs = Bundler.instance_variable_get(:@bundled_specs)
    fail!("SDK did not expose native selected specifications") unless specs.is_a?(Hash)
    if legacy
      require File.expand_path("native_environment_v03_layout", File.dirname(__FILE__))
      manifest = PurifierNativeV03Layout.configuration(root)
      fail!("unsupported native bundle layout") unless manifest.gem_path.to_s == File.join(root, "vendor", "gems") && manifest.bindir.to_s == File.join(root, "bin")
      fail!("native RubyGems must remain enabled") unless manifest.rubygems
      manifest.sources.each { |source| fail!("unsupported native source kind") unless source.is_a?(Bundler::Source) && ["http", "https", "file"].include?(source.uri.scheme) }
      dependencies = manifest.dependencies
    else
      Bundler.mode = :local
      manifest = Bundler::Bundle.load(File.join(root, "Gemfile"))
      fail!("unsupported native bundle layout") unless manifest.path.to_s == File.join(root, "vendor", "gems")
      fail!("native RubyGems must remain enabled") unless manifest.environment.rubygems?
      dependencies = manifest.environment.dependencies
    end
    original_inputs = input_archives(root) if legacy
    wrappers = legacy ? PurifierNativeV03Layout.validate(root, specs, original_inputs) : []
    roots = dependencies.map do |dependency|
      fail!("unsupported native context selection") if dependency.only || dependency.except
      fail!("unsupported native dependency source") if !legacy && dependency.source
      dependency = dependency.to_gem_dependency if legacy
      selected = specs[dependency.name]
      fail!("native root requirement does not match selection") unless selected && dependency.version_requirements.satisfied_by?(selected.version)
      {"name" => dependency.name,
       "requirements" => clauses(dependency.version_requirements)}
    end
    fail!("duplicate native root requirements") unless roots.map { |dependency| dependency["name"] }.uniq.size == roots.size
    names = specs.values.map { |spec| spec.name }
    fail!("duplicate native selected specifications") unless names.uniq.size == names.size
    generated_payloads = []
    packages = specs.values.map do |spec|
      fail!("native selection is not a Gem::Specification") unless spec.is_a?(Gem::Specification)
      fail!("native selected name conflicts with SDK key") unless specs[spec.name].equal?(spec)
      installed = within(root, spec.full_gem_path)
      within(root, spec.loaded_from)
      repository = File.dirname(File.dirname(spec.loaded_from))
      if legacy
        original = original_inputs[[spec.name, spec.version.to_s, spec.platform.to_s]]
        fail!("selected v03 artifact not in verified input role") unless original
        archive = original[0]
      else
        archive = File.join(repository, "cache", spec.full_name + ".gem")
        within(root, archive)
      end
      require "rubygems/format"
      cached_archive = Gem::Format.from_file_by_path(archive)
      cached = cached_archive.spec
      fail!("native archive and selected specification disagree") unless identity(cached) == identity(spec)
      fail!("native installed specification metadata differs from archive") unless cached.to_ruby == spec.to_ruby
      # Initial cached profile accepts pure or already-projected payloads.
      # Source extension builds need a separate compiler/output attestation.
      fail!("native source extension builds require compiler attestation") unless cached.extensions.empty?
      payload_names = {}
      installed_root = Pathname.new(spec.full_gem_path).realpath.to_s
      cached_archive.file_entries.each do |entry, bytes|
        # Native Gem::Format returns nil for a zero-byte tar entry; its
        # installer writes that as an empty file on the original runtime.
        bytes = "" if bytes.nil? && entry["size"] == 0
        fail!("native archive payload size is invalid") unless bytes.is_a?(String) && bytes.size == entry["size"]
        relative = entry["path"]
        fail!("invalid native archive payload path") unless relative.is_a?(String) && !relative.empty? && relative[0, 1] != "/" && relative.index("\\").nil? && relative.split("/").all? { |part| !part.empty? && part != ".." }
        # Use the same public expansion API as native Installer#extract_files;
        # upstream JSON genuinely includes ./tests/... payload names.
        payload = File.expand_path(File.join(spec.full_gem_path, relative))
        fail!("native archive path escapes installed package") unless payload.index(installed_root + "/") == 0
        payload_identity = [entry["mode"], Digest::SHA256.digest(bytes)]
        # Genuine JSON includes byte/mode-identical ./tests and tests aliases.
        # Preserve the archive identity; conflicting aliases fail closed.
        fail!("conflicting native archive payload aliases") if payload_names[payload] && payload_names[payload] != payload_identity
        payload_names[payload] = payload_identity
        within(root, payload)
        physical = Pathname.new(payload).realpath.to_s
        fail!("native payload escapes installed package role") unless physical.index(installed_root + "/") == 0 && File.file?(physical)
        fail!("native installed payload differs from archive") unless File.open(physical, "rb") { |file| Digest::SHA256.digest(file.read) } == Digest::SHA256.digest(bytes)
        # Genuine RubyGems 1.3.5 Installer#generate_bin adds executable bits
        # to the declared entry point inside the installed gem itself.
        executable = cached.executables.any? { |name| relative == File.join(cached.bindir, name) }
        expected_mode = legacy ? (executable ? 0111 : 0) : (entry["mode"] | (executable ? 0111 : 0))
        fail!("native payload executable mode differs from SDK installation") unless (File.stat(physical).mode & 0111) == (expected_mode & 0111)
      end
      expected_files = payload_names.keys
      # Genuine Gem135 writes this one extra marker via RequirePathsBuilder.
      # Its exact content comes from the native specification's public fields.
      # Original Gem095 has no RequirePathsBuilder; its complete installed
      # file set must match archive payloads without a generated marker.
      gem095 = legacy && Gem::RubyGemsVersion == "0.9.5"
      unless gem095 || (cached.require_paths == ["lib"] && (cached.bindir.nil? || cached.bindir == "bin"))
        marker = File.join(spec.full_gem_path, ".require_paths")
        within(root, marker)
        expected_marker = cached.require_paths.map { |path| path + "\n" }.join
        expected_marker += cached.bindir + "\n" if cached.bindir
        fail!("native generated require-path marker differs from SDK") unless File.open(marker, "rb") { |file| file.read } == expected_marker
        expected_files << File.expand_path(marker)
        generated_payloads << marker
      end
      installed_files = []
      Find.find(spec.full_gem_path) do |path|
        # Native Gem135 extraction writes regular files. Directory symlinks
        # would hide unarchived loadable files from Find's traversal.
        fail!("unsupported symlink in native installed package") if File.symlink?(path)
        installed_files << File.expand_path(path) if File.file?(path)
      end
      fail!("native installed payload file set differs from archive") unless installed_files.sort == expected_files.sort
      spec.dependencies.each do |dependency|
        next unless runtime_dependency?(dependency)
        selected = specs[dependency.name]
        fail!("native runtime dependency closure is incomplete") unless selected
        fail!("native requirement does not match selected dependency") unless dependency.version_requirements.satisfied_by?(selected.version)
      end
      observed = identity(spec).merge("installedPath" => installed,
        "specificationPath" => within(root, spec.loaded_from),
        "sourceKind" => (legacy ? "verified-input" : "verified-cache"),
        "archiveHash" => "sha256-" + [Digest::SHA256.digest(File.open(archive, "rb") { |file| file.read })].pack("m").delete("\n"))
      observed["executables"] = spec.executables if legacy
      observed
    end
    reachable = []
    pending = roots.map { |dependency| dependency["name"] }
    until pending.empty?
      name = pending.pop
      next if reachable.include?(name)
      reachable << name
      selected = specs[name]
      selected.dependencies.each { |dependency| pending << dependency.name if runtime_dependency?(dependency) }
    end
    fail!("native selected closure contains an unrelated package") unless reachable.sort == names.sort
    generated = legacy ? [environment] : [environment, File.join(root, "vendor", "gems", Gem.ruby_engine, Gem::ConfigMap[:ruby_version], "environment.rb")]
    generated += specs.values.map { |spec| spec.loaded_from }
    generated += generated_payloads
    generated += wrappers
    {"packages" => packages.sort_by { |package| package["name"] },
     "generatedPaths" => generated.map { |path| within(root, path) }.sort,
     "rootRequirements" => roots.sort_by { |dependency| dependency["name"] }}
  end
end

if __FILE__ == $0
  raise "usage: native_environment_observe.rb WORKSPACE" unless ARGV.size == 1
  observation = PurifierEnvironmentObservation.observe(ARGV[0])
  # The actual environment has selected the codec now. JSON is an SDK/runtime
  # component and its provenance is bound separately by the host SDK identity.
  require "json"
  STDOUT.write(JSON.generate(observation))
  STDOUT.write("\n")
end
